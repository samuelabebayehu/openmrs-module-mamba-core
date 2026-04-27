DROP PROCEDURE IF EXISTS sp_mamba_flat_encounter_table_insert;

DELIMITER //

CREATE PROCEDURE sp_mamba_flat_encounter_table_insert(
    IN p_flat_table_name  VARCHAR(60),
    IN p_encounter_id     INT,         -- NULL = full-load or incremental-batch; NOT NULL = single encounter
    IN p_incremental_only TINYINT(1)  -- 0 = full load, 1 = batch incremental (re-process modified encounters)
)
BEGIN

    DECLARE batch_size  INT;
    DECLARE batch_start INT;
    DECLARE max_enc_id  INT;

    -- Read batch size from persistent settings so it works in the scheduled ETL session.
    -- Update with: UPDATE _mamba_etl_user_settings SET flat_table_load_batch_size = N;
    --   16 GB RAM + HDD   -> 50000  (reduces lock duration on slow I/O)
    --   16 GB RAM + SSD   -> 200000
    --   >= 32 GB RAM + NVMe -> 500000
    SELECT flat_table_load_batch_size INTO batch_size FROM _mamba_etl_user_settings LIMIT 1;

    -- 1 MB headroom for very wide tables (100+ concept columns); 20000 silently truncates SQL.
    SET SESSION group_concat_max_len = 1048576;

    -- READ COMMITTED eliminates gap/next-key locks on mamba_z_encounter_obs during
    -- INSERT...SELECT, which is the primary cause of lock-wait timeouts at high row counts.
    SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;

    DROP TEMPORARY TABLE IF EXISTS temp_concept_metadata;

    CREATE TEMPORARY TABLE IF NOT EXISTS temp_concept_metadata
    (
        `id`                  INT          NOT NULL,
        `flat_table_name`     VARCHAR(60)  NOT NULL,
        `encounter_type_uuid` CHAR(38)     NOT NULL,
        `column_label`        VARCHAR(255) NOT NULL,
        `concept_uuid`        CHAR(38)     NOT NULL,
        `obs_value_column`    VARCHAR(50),
        `concept_datatype`    VARCHAR(50),
        `concept_answer_obs`  INT,

        INDEX idx_id                  (`id`),
        INDEX idx_column_label        (`column_label`),
        INDEX idx_concept_uuid        (`concept_uuid`),
        INDEX idx_concept_answer_obs  (`concept_answer_obs`),
        INDEX idx_flat_table_name     (`flat_table_name`),
        INDEX idx_encounter_type_uuid (`encounter_type_uuid`)
    );

    INSERT INTO temp_concept_metadata
    SELECT DISTINCT `id`,
                    `flat_table_name`,
                    `encounter_type_uuid`,
                    `column_label`,
                    `concept_uuid`,
                    fn_mamba_get_obs_value_column(`concept_datatype`),
                    `concept_datatype`,
                    `concept_answer_obs`
    FROM `mamba_concept_metadata`
    WHERE `flat_table_name` = p_flat_table_name
      AND `concept_id`      IS NOT NULL
      AND `concept_datatype` IS NOT NULL;

    SELECT GROUP_CONCAT(
        DISTINCT CONCAT(
            'MAX(CASE WHEN `column_label` = ''',
            `column_label`,
            ''' THEN ',
            `obs_value_column`,
            ' END) `',
            `column_label`,
            '`'
        ) ORDER BY `id` ASC
    )
    INTO @column_labels
    FROM temp_concept_metadata;

    SELECT DISTINCT `encounter_type_uuid`
    INTO @encounter_type_uuid
    FROM temp_concept_metadata
    LIMIT 1;

    IF @column_labels IS NOT NULL THEN

        IF p_encounter_id IS NOT NULL THEN
            -- Single-encounter incremental: delete the stale flat row, then re-pivot just that encounter.
            SET @delete_stmt = CONCAT('DELETE FROM `', p_flat_table_name, '` WHERE `encounter_id` = ?');
            PREPARE stmt FROM @delete_stmt;
            SET @enc_id_param = p_encounter_id;
            EXECUTE stmt USING @enc_id_param;
            DEALLOCATE PREPARE stmt;

            CALL sp_mamba_flat_encounter_table_question_concepts_insert(
                p_flat_table_name, p_encounter_id, @encounter_type_uuid, @column_labels, NULL, NULL, 0
            );
            CALL sp_mamba_flat_encounter_table_answer_concepts_insert(
                p_flat_table_name, p_encounter_id, @encounter_type_uuid, @column_labels, NULL, NULL, 0
            );

        ELSEIF p_incremental_only = 1 THEN
            -- Batch incremental: delete ALL modified encounters for this flat table in one shot,
            -- then re-insert all their obs in one pivot query.
            -- Re-fetches ALL obs for modified encounters (not just incremental rows) so the
            -- rebuilt flat row is complete.
            SET @delete_stmt = CONCAT(
                'DELETE FROM `', p_flat_table_name, '` WHERE encounter_id IN ',
                '(SELECT DISTINCT encounter_id FROM mamba_z_encounter_obs ',
                ' WHERE encounter_type_uuid = ''', @encounter_type_uuid, ''' AND incremental_record = 1)'
            );
            PREPARE stmt FROM @delete_stmt;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;

            CALL sp_mamba_flat_encounter_table_question_concepts_insert(
                p_flat_table_name, NULL, @encounter_type_uuid, @column_labels, NULL, NULL, 1
            );
            CALL sp_mamba_flat_encounter_table_answer_concepts_insert(
                p_flat_table_name, NULL, @encounter_type_uuid, @column_labels, NULL, NULL, 1
            );

        ELSE
            -- Full load: process in encounter_id range batches.
            -- Batching limits lock scope per transaction and caps peak memory use.
            SELECT MIN(encounter_id), MAX(encounter_id)
            INTO batch_start, max_enc_id
            FROM mamba_z_encounter_obs
            WHERE encounter_type_uuid = @encounter_type_uuid;

            IF batch_start IS NOT NULL THEN
                WHILE batch_start <= max_enc_id DO

                    CALL sp_mamba_flat_encounter_table_question_concepts_insert(
                        p_flat_table_name, NULL, @encounter_type_uuid, @column_labels,
                        batch_start, batch_start + batch_size - 1, 0
                    );
                    CALL sp_mamba_flat_encounter_table_answer_concepts_insert(
                        p_flat_table_name, NULL, @encounter_type_uuid, @column_labels,
                        batch_start, batch_start + batch_size - 1, 0
                    );

                    SET batch_start = batch_start + batch_size;
                END WHILE;
            END IF;

        END IF;

    END IF;

END //

DELIMITER ;

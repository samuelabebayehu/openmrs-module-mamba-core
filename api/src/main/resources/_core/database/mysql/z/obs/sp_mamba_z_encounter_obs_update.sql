DROP PROCEDURE IF EXISTS sp_mamba_z_encounter_obs_update;

DELIMITER //

CREATE PROCEDURE sp_mamba_z_encounter_obs_update()
BEGIN
    DECLARE v_total_records INT;
    DECLARE v_batch_size INT DEFAULT 1000000; -- batch size
    DECLARE v_offset INT DEFAULT 0;
    DECLARE v_rows_affected INT;
    DECLARE v_temp_table_created BOOLEAN DEFAULT FALSE;

    -- Use a transaction for better error handling and atomicity
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            IF v_temp_table_created THEN
                DROP TEMPORARY TABLE IF EXISTS mamba_temp_value_coded_values;
            END IF;
            -- If an error occurs during a batch that was started but not committed,
            -- the handler's implicit rollback (or explicit if added) will handle it.
            -- Previously committed batches remain committed.
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An error occurred during the update process';
        END;

    -- Start the main transaction for temp table creation and final update
    START TRANSACTION;

    -- Create temporary table with only the needed values
    CREATE TEMPORARY TABLE mamba_temp_value_coded_values
        CHARSET = UTF8MB4 AS
    SELECT DISTINCT m.concept_id AS concept_id, -- Added DISTINCT just in case, though WHERE IN subquery should handle it
                    m.uuid       AS concept_uuid,
                    m.name       AS concept_name
    FROM mamba_dim_concept m
    WHERE concept_id in (SELECT DISTINCT obs_value_coded -- DISTINCT here ensures minimal temp table size
                         FROM mamba_z_encounter_obs
                         WHERE obs_value_coded IS NOT NULL);

    SET v_temp_table_created = TRUE;

    -- Create index to optimize joins
    CREATE INDEX mamba_idx_concept_id ON mamba_temp_value_coded_values (concept_id);

    -- Commit the temporary table creation.
    -- This is important so the temp table is available for subsequent batched transactions.
    COMMIT;

    -- Re-start transaction scope for the first batch, implicitly
    -- Or you could explicitly START TRANSACTION here if preferred before the loop.
    -- START TRANSACTION; -- Optional explicit start for the first batch

    -- Get total count of records in mamba_z_encounter_obs to be processed
    -- (rows that match concepts in the temp table)
    SELECT COUNT(*)
    INTO v_total_records
    FROM mamba_z_encounter_obs z
             INNER JOIN mamba_temp_value_coded_values mtv
                        ON z.obs_value_coded = mtv.concept_id
    WHERE z.obs_value_coded IS NOT NULL;

    -- Process records in batches
    WHILE v_offset < v_total_records DO
            -- Start transaction for the current batch
            START TRANSACTION;

            -- Update in batches using dynamic SQL
            SET @sql = CONCAT('UPDATE mamba_z_encounter_obs z
                   INNER JOIN (
                       SELECT concept_id, concept_name, concept_uuid
                       FROM mamba_temp_value_coded_values mtv
                       ORDER BY mtv.concept_id -- *** Added ORDER BY for stable batch selection ***
                       LIMIT ', v_batch_size, ' OFFSET ', v_offset, '
                   ) AS mtv
                   ON z.obs_value_coded = mtv.concept_id
                   SET z.obs_value_text = mtv.concept_name,
                       z.obs_value_coded_uuid = mtv.concept_uuid
                   WHERE z.obs_value_coded IS NOT NULL'); -- Keep original WHERE for safety
            PREPARE stmt FROM @sql;
            EXECUTE stmt;
            SET v_rows_affected = ROW_COUNT();
            DEALLOCATE PREPARE stmt;

            -- Commit the current batch
            COMMIT;

            -- Start transaction for the next batch
            START TRANSACTION; -- Start transaction for the next iteration

            -- Adaptively adjust offset based on actual rows affected.
            -- While incrementing by batch_size is more standard when limiting the source,
            -- keeping v_rows_affected attempts to align offset with the total count logic.
            -- Be aware this relies on ROW_COUNT() accurately reflecting progress towards v_total_records.
            SET v_offset = v_offset + IF(v_rows_affected > 0, v_rows_affected, v_batch_size);

        END WHILE; -- The last implicit transaction started by START TRANSACTION after the last COMMIT needs to be handled.
    -- The final COMMIT after the loop takes care of this.

    -- The last batch's transaction might still be open if the loop finishes.
    -- The final update for boolean values should also be in a transaction.
    -- Let's explicitly start a transaction for the final step if the loop completed cleanly.

    -- Check if the last batch transaction is open and commit it if needed,
    -- then start a new one for the final update.
    -- A simpler approach is to let the final COMMIT handle the last batch and the final update.

    -- Update boolean values based on text representations
    UPDATE mamba_z_encounter_obs z
    SET obs_value_boolean =
            CASE
                WHEN obs_value_text IN ('FALSE', 'No') THEN 0
                WHEN obs_value_text IN ('TRUE', 'Yes') THEN 1
                ELSE NULL
                END
    WHERE z.obs_value_coded IS NOT NULL
      AND obs_question_concept_id in
          (SELECT DISTINCT concept_id
           FROM mamba_dim_concept c
           WHERE c.datatype = 'Boolean');

    -- Commit the final boolean update (and the last batch's transaction if still open)
    COMMIT;

    -- Clean up temporary resources
    DROP TEMPORARY TABLE IF EXISTS mamba_temp_value_coded_values;

END //

DELIMITER ;
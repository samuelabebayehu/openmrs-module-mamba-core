DROP PROCEDURE IF EXISTS sp_mamba_flat_encounter_table_question_concepts_insert;

DELIMITER //

-- SP inserts all concepts that are questions or have a concept_id value in the Obs table
-- whether their values/answers are coded or non-coded
CREATE PROCEDURE sp_mamba_flat_encounter_table_question_concepts_insert(
    IN p_table_name           VARCHAR(60),
    IN p_encounter_id         INT,
    IN p_encounter_type_uuid  CHAR(38),
    IN p_column_labels        TEXT,
    IN p_min_enc_id           INT,          -- NULL = no range; used for encounter-range batching
    IN p_max_enc_id           INT,          -- NULL = no range; used for encounter-range batching
    IN p_incremental_only     TINYINT(1)   -- 1 = only re-process encounters with incremental_record=1
)
BEGIN
    DECLARE sql_stmt TEXT;

    SET sql_stmt = CONCAT(
        'INSERT INTO `', p_table_name, '` ',
        'SELECT
         o.encounter_id,
         MAX(o.visit_id)          AS visit_id,
         o.person_id,
         MAX(o.encounter_datetime) AS encounter_datetime,
         MAX(o.location_id)        AS location_id,
         ', p_column_labels, '
         FROM mamba_z_encounter_obs o
         INNER JOIN temp_concept_metadata tcm
             ON tcm.concept_uuid = o.obs_question_uuid
         WHERE 1=1 '
    );

    -- Exactly one of these filter modes applies per call
    IF p_encounter_id IS NOT NULL THEN
        SET sql_stmt = CONCAT(sql_stmt, ' AND o.encounter_id = ', p_encounter_id);
    ELSEIF p_min_enc_id IS NOT NULL THEN
        -- Range batch: avoids locking the full table in one shot
        SET sql_stmt = CONCAT(sql_stmt, ' AND o.encounter_id BETWEEN ', p_min_enc_id, ' AND ', p_max_enc_id);
    ELSEIF p_incremental_only = 1 THEN
        -- Incremental batch: all obs for encounters that have at least one new/modified obs row
        SET sql_stmt = CONCAT(sql_stmt,
            ' AND o.encounter_id IN ('
            'SELECT DISTINCT encounter_id FROM mamba_z_encounter_obs '
            'WHERE encounter_type_uuid = ''', p_encounter_type_uuid, ''' AND incremental_record = 1)');
    END IF;

    SET sql_stmt = CONCAT(sql_stmt,
        ' AND o.encounter_type_uuid = ''', p_encounter_type_uuid, '''
          AND tcm.obs_value_column IS NOT NULL
          AND o.obs_group_id IS NULL
          AND o.voided = 0
          GROUP BY o.encounter_id, o.person_id');

    SET @sql = sql_stmt;
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

END //

DELIMITER ;

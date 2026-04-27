DROP PROCEDURE IF EXISTS sp_mamba_flat_encounter_table_answer_concepts_insert;

DELIMITER //

-- Inserts answer concepts (multichoice/coded answers) into flat table.
-- These are concepts that appear as obs_value_coded_uuid (not as question concepts),
-- so we join on the coded answer UUID rather than the question UUID.
CREATE PROCEDURE sp_mamba_flat_encounter_table_answer_concepts_insert(
    IN p_table_name           VARCHAR(60),
    IN p_encounter_id         INT,
    IN p_encounter_type_uuid  CHAR(38),
    IN p_column_labels        TEXT,
    IN p_min_enc_id           INT,          -- NULL = no range; used for encounter-range batching
    IN p_max_enc_id           INT,          -- NULL = no range; used for encounter-range batching
    IN p_incremental_only     TINYINT(1)   -- 1 = only re-process encounters with incremental_record=1
)
BEGIN
    DECLARE sql_stmt     TEXT;
    DECLARE update_columns TEXT;

    SELECT GROUP_CONCAT(
        CONCAT('`', column_label, '` = COALESCE(VALUES(`', column_label, '`), `', column_label, '`)')
    )
    INTO update_columns
    FROM temp_concept_metadata;

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
             ON tcm.concept_uuid = o.obs_value_coded_uuid
         WHERE 1=1 '
    );

    IF p_encounter_id IS NOT NULL THEN
        SET sql_stmt = CONCAT(sql_stmt, ' AND o.encounter_id = ', p_encounter_id);
    ELSEIF p_min_enc_id IS NOT NULL THEN
        SET sql_stmt = CONCAT(sql_stmt, ' AND o.encounter_id BETWEEN ', p_min_enc_id, ' AND ', p_max_enc_id);
    ELSEIF p_incremental_only = 1 THEN
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
          GROUP BY o.encounter_id, o.person_id
          ON DUPLICATE KEY UPDATE ', update_columns);

    SET @sql = sql_stmt;
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

END //

DELIMITER ;

DROP PROCEDURE IF EXISTS sp_mamba_flat_table_incremental_update_encounter;

DELIMITER //

CREATE PROCEDURE sp_mamba_flat_table_incremental_update_encounter()
BEGIN

    DECLARE tbl_name VARCHAR(60);
    DECLARE done INT DEFAULT FALSE;

    -- Iterate per flat table, not per encounter.
    -- The previous per-encounter cursor caused an N+1 problem: temp_concept_metadata was created,
    -- indexed, populated, and GROUP_CONCAT-ed once per modified encounter. With thousands of
    -- modified encounters this dominated runtime. Now we process all modified encounters for a
    -- flat table in a single delete + pivot insert, rebuilding temp_concept_metadata only once
    -- per table.
    DECLARE cursor_flat_tables CURSOR FOR
        SELECT DISTINCT cm.flat_table_name
        FROM mamba_z_encounter_obs eo
        INNER JOIN mamba_concept_metadata cm ON eo.encounter_type_uuid = cm.encounter_type_uuid
        WHERE eo.incremental_record = 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    OPEN cursor_flat_tables;
    computations_loop:
    LOOP
        FETCH cursor_flat_tables INTO tbl_name;

        IF done THEN
            LEAVE computations_loop;
        END IF;

        -- p_incremental_only=1: delete all modified encounters then re-insert all their obs
        CALL sp_mamba_flat_encounter_table_insert(tbl_name, NULL, 1);

    END LOOP computations_loop;
    CLOSE cursor_flat_tables;

END //

DELIMITER ;

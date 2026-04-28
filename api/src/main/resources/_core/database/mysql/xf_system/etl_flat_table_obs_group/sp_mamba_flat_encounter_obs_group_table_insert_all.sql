-- Flatten all Encounters given in Config folder
DROP PROCEDURE IF EXISTS sp_mamba_flat_encounter_obs_group_table_insert_all;

DELIMITER //

CREATE PROCEDURE sp_mamba_flat_encounter_obs_group_table_insert_all()
BEGIN

    DECLARE tbl_name VARCHAR(60);
    DECLARE obs_name CHAR(50);
    DECLARE done_tables    INT DEFAULT 0;
    DECLARE done_obs_names INT DEFAULT 0;

    DECLARE cursor_flat_tables CURSOR FOR
        SELECT DISTINCT flat_table_name FROM mamba_concept_metadata;

    DECLARE cursor_obs_group_tables CURSOR FOR
        SELECT DISTINCT obs_group_concept_name FROM mamba_obs_group;

    -- A single NOT FOUND handler covers both cursors; we track exhaustion
    -- in per-cursor flags so each cursor's loop exits cleanly without running
    -- the body one extra time on the stale-fetch iteration (the old REPEAT…UNTIL
    -- bug that caused the first and last obs_group_name to be processed twice).
    DECLARE CONTINUE HANDLER FOR NOT FOUND
    BEGIN
        SET done_tables    = 1;
        SET done_obs_names = 1;
    END;

    OPEN cursor_flat_tables;
    tables_loop: LOOP
        SET done_tables = 0;
        FETCH cursor_flat_tables INTO tbl_name;
        IF done_tables THEN LEAVE tables_loop; END IF;

        OPEN cursor_obs_group_tables;
        obs_loop: LOOP
            SET done_obs_names = 0;
            FETCH cursor_obs_group_tables INTO obs_name;
            IF done_obs_names THEN LEAVE obs_loop; END IF;

            CALL sp_mamba_flat_encounter_obs_group_table_insert(tbl_name, obs_name, NULL);
        END LOOP obs_loop;
        CLOSE cursor_obs_group_tables;

    END LOOP tables_loop;
    CLOSE cursor_flat_tables;

END //

DELIMITER ;

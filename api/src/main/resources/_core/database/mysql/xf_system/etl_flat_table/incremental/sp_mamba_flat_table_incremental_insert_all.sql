DROP PROCEDURE IF EXISTS sp_mamba_flat_table_incremental_insert_all;

DELIMITER //

CREATE PROCEDURE sp_mamba_flat_table_incremental_insert_all()
BEGIN

 DECLARE tbl_name VARCHAR(60) ;

 DECLARE done INT DEFAULT FALSE;

 DECLARE cursor_flat_tables CURSOR FOR
 SELECT DISTINCT(flat_table_name)
 FROM mamba_concept_metadata md
 WHERE incremental_record = 1;

 DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

 OPEN cursor_flat_tables;
 computations_loop:
 LOOP
 FETCH cursor_flat_tables INTO tbl_name;

 IF done THEN
 LEAVE computations_loop;
 END IF;

 CALL sp_mamba_flat_encounter_table_insert(tbl_name, NULL); -- Insert all OBS/Encounters for this flat table

 END LOOP computations_loop;
 CLOSE cursor_flat_tables;

END //

DELIMITER ;
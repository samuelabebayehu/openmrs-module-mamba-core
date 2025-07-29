DROP PROCEDURE IF EXISTS sp_xf_system_drop_all_stored_functions_in_schema;

DELIMITER //

CREATE PROCEDURE sp_xf_system_drop_all_stored_functions_in_schema(
 IN database_name CHAR(255) 
)
BEGIN
 DELETE FROM `mysql`.`proc` WHERE `type` = 'FUNCTION' AND `db` = database_name; -- works in mysql before v.8

END //

DELIMITER ;
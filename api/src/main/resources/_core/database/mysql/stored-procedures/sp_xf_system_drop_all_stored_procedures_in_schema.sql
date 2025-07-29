DROP PROCEDURE IF EXISTS sp_xf_system_drop_all_stored_procedures_in_schema;

DELIMITER //

CREATE PROCEDURE sp_xf_system_drop_all_stored_procedures_in_schema(
    IN database_name CHAR(255) CHARACTER SET UTF8MB4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    DELETE FROM `mysql`.`proc` WHERE `type` = 'PROCEDURE' AND `db` = database_name; -- works in mysql before v.8

END //

DELIMITER ;
DROP PROCEDURE IF EXISTS sp_mamba_drop_table;

DELIMITER //

CREATE PROCEDURE sp_mamba_drop_table(
    IN table_to_drop VARCHAR(64) CHARACTER SET UTF8MB4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    SET @sql = CONCAT('DROP TABLE IF EXISTS ', table_to_drop);
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

END //

DELIMITER ;
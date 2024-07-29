DROP PROCEDURE IF EXISTS sp_mamba_etl_scheduler_wrapper;

DELIMITER //

CREATE PROCEDURE sp_mamba_etl_scheduler_wrapper()

BEGIN

    DECLARE etl_ever_scheduled TINYINT(1);
    DECLARE incremental_mode TINYINT(1);

    SELECT COUNT(1)
    INTO etl_ever_scheduled
    FROM _mamba_etl_schedule;

    SELECT incremental_mode_switch
    INTO incremental_mode
    FROM _mamba_etl_user_settings;

    IF etl_ever_scheduled = 0 OR incremental_mode = 0 THEN
        CALL sp_mamba_etl_schedule('sp_mamba_data_processing_drop_and_flatten');
    ELSE
        CALL sp_mamba_etl_schedule('sp_mamba_data_processing_increment_and_flatten');
    END IF;

END //

DELIMITER ;
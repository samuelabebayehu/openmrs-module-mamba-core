DROP PROCEDURE IF EXISTS sp_mamba_z_encounter_obs_update;

DELIMITER //

CREATE PROCEDURE sp_mamba_z_encounter_obs_update()
BEGIN
    DECLARE batch_size   INT DEFAULT 1000000;
    DECLARE min_obs_id   INT;
    DECLARE max_obs_id   INT;
    DECLARE batch_start  INT;

    -- Build a lookup of only the coded concepts that actually appear in this dataset.
    -- Keeping this small avoids full-scanning mamba_dim_concept on every batch UPDATE.
    CREATE TEMPORARY TABLE mamba_temp_value_coded_values AS
    SELECT m.concept_id AS concept_id,
           m.uuid       AS concept_uuid,
           m.name       AS concept_name
    FROM mamba_dim_concept m
    WHERE concept_id IN (
        SELECT DISTINCT obs_value_coded
        FROM mamba_z_encounter_obs
        WHERE obs_value_coded IS NOT NULL
    );

    CREATE INDEX mamba_idx_concept_id ON mamba_temp_value_coded_values (concept_id);

    -- ID-range batching: O(n) total work vs the prior OFFSET approach which was O(n²)
    -- because each batch re-scanned from the start of the table up to OFFSET.
    SELECT MIN(obs_id), MAX(obs_id)
    INTO min_obs_id, max_obs_id
    FROM mamba_z_encounter_obs
    WHERE obs_value_coded IS NOT NULL;

    IF min_obs_id IS NOT NULL THEN
        SET batch_start = min_obs_id;
        WHILE batch_start <= max_obs_id DO

            UPDATE mamba_z_encounter_obs z
            INNER JOIN mamba_temp_value_coded_values mtv ON z.obs_value_coded = mtv.concept_id
            SET z.obs_value_text       = mtv.concept_name,
                z.obs_value_coded_uuid = mtv.concept_uuid
            WHERE z.obs_value_coded IS NOT NULL
              AND z.obs_id BETWEEN batch_start AND batch_start + batch_size - 1;

            SET batch_start = batch_start + batch_size;
        END WHILE;
    END IF;

    -- Back-fill obs_value_boolean for Boolean-typed coded obs
    UPDATE mamba_z_encounter_obs z
    SET obs_value_boolean =
        CASE
            WHEN obs_value_text IN ('FALSE', 'No')  THEN 0
            WHEN obs_value_text IN ('TRUE',  'Yes') THEN 1
            ELSE NULL
        END
    WHERE z.obs_value_coded IS NOT NULL
      AND obs_question_concept_id IN (
          SELECT DISTINCT concept_id
          FROM mamba_dim_concept c
          WHERE c.datatype = 'Boolean'
      );

    DROP TEMPORARY TABLE IF EXISTS mamba_temp_value_coded_values;

END //

DELIMITER ;

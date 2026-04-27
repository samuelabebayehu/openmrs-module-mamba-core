DROP PROCEDURE IF EXISTS sp_mamba_z_encounter_obs_update;

DELIMITER //

CREATE PROCEDURE sp_mamba_z_encounter_obs_update()
BEGIN
    DECLARE batch_size      INT DEFAULT 50000;
    DECLARE last_obs_id     INT DEFAULT 0;
    DECLARE next_max_obs_id INT;

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

    -- Keyset-pagination over ONLY coded rows (obs_value_coded IS NOT NULL).
    --
    -- The old approach batched by obs_id RANGE (e.g. obs_id BETWEEN 1 AND 1000000).
    -- That forced a full PK scan of 1M obs_ids per iteration even when most rows had
    -- obs_value_coded = NULL, wasting the majority of each batch on rows that needed
    -- no work and holding a 1M-row write-lock for the full transaction duration.
    --
    -- Here we advance the cursor by asking for the next batch_size CODED rows using
    -- the mamba_idx_obs_value_coded index, then UPDATE only the obs_id range those
    -- rows occupy.  Each iteration is bounded to exactly batch_size coded rows.
    coded_loop: LOOP

        SELECT MAX(obs_id) INTO next_max_obs_id
        FROM (
            SELECT obs_id
            FROM mamba_z_encounter_obs
            WHERE obs_value_coded IS NOT NULL
              AND obs_id > last_obs_id
            ORDER BY obs_id
            LIMIT batch_size
        ) AS next_batch;

        IF next_max_obs_id IS NULL THEN
            LEAVE coded_loop;
        END IF;

        UPDATE mamba_z_encounter_obs z
        INNER JOIN mamba_temp_value_coded_values mtv ON z.obs_value_coded = mtv.concept_id
        SET z.obs_value_text       = mtv.concept_name,
            z.obs_value_coded_uuid = mtv.concept_uuid
        WHERE z.obs_id > last_obs_id
          AND z.obs_id <= next_max_obs_id;

        SET last_obs_id = next_max_obs_id;

    END LOOP coded_loop;

    -- Back-fill obs_value_boolean for Boolean-typed coded obs.
    -- Materialise the boolean concept list so the subquery runs only once.
    CREATE TEMPORARY TABLE mamba_temp_bool_concept_ids AS
    SELECT DISTINCT concept_id
    FROM mamba_dim_concept
    WHERE datatype = 'Boolean';

    CREATE INDEX mamba_idx_bool_concept_id ON mamba_temp_bool_concept_ids (concept_id);

    UPDATE mamba_z_encounter_obs z
    INNER JOIN mamba_temp_bool_concept_ids bc ON z.obs_question_concept_id = bc.concept_id
    SET z.obs_value_boolean =
        CASE
            WHEN z.obs_value_text IN ('FALSE', 'No')  THEN 0
            WHEN z.obs_value_text IN ('TRUE',  'Yes') THEN 1
            ELSE NULL
        END
    WHERE z.obs_value_coded IS NOT NULL;

    DROP TEMPORARY TABLE IF EXISTS mamba_temp_bool_concept_ids;
    DROP TEMPORARY TABLE IF EXISTS mamba_temp_value_coded_values;

END //

DELIMITER ;

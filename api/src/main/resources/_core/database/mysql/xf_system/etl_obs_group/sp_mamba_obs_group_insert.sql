DROP PROCEDURE IF EXISTS sp_mamba_obs_group_insert;

DELIMITER //

CREATE PROCEDURE sp_mamba_obs_group_insert()
BEGIN
    -- The old implementation had three bugs:
    --
    -- 1. total_records was the count of raw obs rows (e.g. 100M), but pagination
    --    was applied to the GROUP BY result (e.g. 500K distinct obs_groups).
    --    This caused ~99 empty OFFSET iterations for every 1 that did real work.
    --
    -- 2. LIMIT … OFFSET on a GROUP BY is O(n²): each batch re-aggregates from the
    --    start of the table up to the offset before discarding earlier groups.
    --
    -- 3. The temp table was dropped and recreated inside every loop iteration.
    --
    -- Fix: materialise the valid obs_group_ids once, then do a single INSERT.
    -- obs_group rows are a small fraction of total obs so no batching is needed.

    CREATE TEMPORARY TABLE mamba_temp_valid_obs_group_ids
    (
        obs_group_id INT NOT NULL,
        PRIMARY KEY (obs_group_id)
    ) AS
    SELECT obs_group_id
    FROM mamba_z_encounter_obs
    WHERE obs_group_id IS NOT NULL
    GROUP BY obs_group_id, person_id, encounter_id
    HAVING COUNT(*) > 1;

    INSERT INTO mamba_obs_group (obs_group_concept_id, obs_group_concept_name, obs_id, obs_group_id)
    SELECT DISTINCT
           o.obs_question_concept_id,
           LEFT(c.auto_table_column_name, 12) AS obs_group_concept_name,
           o.obs_id,
           o.obs_group_id
    FROM mamba_temp_valid_obs_group_ids vg
    INNER JOIN mamba_z_encounter_obs   o ON o.obs_group_id       = vg.obs_group_id
    INNER JOIN mamba_dim_concept       c ON o.obs_question_concept_id = c.concept_id;

    DROP TEMPORARY TABLE IF EXISTS mamba_temp_valid_obs_group_ids;

END //

DELIMITER ;

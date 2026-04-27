# MambaETL Flat Table — Performance Optimizations

> Branch: `performance_optimizations`  
> Date: April 2026  
> Scope: Full-load and incremental flat table pipeline; obs staging update  

---

## Table of Contents

1. [Background — What the ETL Does](#1-background)
2. [Root Problem — Why It Timed Out](#2-root-problem)
3. [Optimizations Applied](#3-optimizations-applied)
   - [3.1 READ COMMITTED Isolation Level](#31-read-committed-isolation-level)
   - [3.2 Encounter-Range Batching (Core Fix)](#32-encounter-range-batching-core-fix)
   - [3.3 Removed ORDER BY from Pivot Inserts](#33-removed-order-by-from-pivot-inserts)
   - [3.4 Incremental Update — Eliminated N+1](#34-incremental-update--eliminated-n1)
   - [3.5 Fixed O(n²) OFFSET Batching in Obs Update](#35-fixed-on-offset-batching-in-obs-update)
   - [3.6 Composite Index on mamba_z_encounter_obs](#36-composite-index-on-mamba_z_encounter_obs)
   - [3.7 Raised group_concat_max_len to 1 MB](#37-raised-group_concat_max_len-to-1-mb)
4. [Hardware Tuning Guide](#4-hardware-tuning-guide)
5. [Configuration Reference](#5-configuration-reference)
6. [Correctness Audit — What Changed vs. What Stayed the Same](#6-correctness-audit)
7. [Files Changed](#7-files-changed)

---

## 1. Background

MambaETL transforms the OpenMRS transactional `obs` table into wide, query-friendly flat encounter tables (one row per encounter, one column per concept). The critical path is a **pivot query** that reads millions of obs rows, groups them by `encounter_id`, and collapses them into flat rows via conditional aggregation:

```sql
INSERT INTO flat_hiv_encounters
SELECT
    o.encounter_id,
    MAX(CASE WHEN column_label = 'cd4_count'  THEN obs_value_numeric END) AS cd4_count,
    MAX(CASE WHEN column_label = 'viral_load' THEN obs_value_numeric END) AS viral_load,
    ...
FROM mamba_z_encounter_obs o
JOIN temp_concept_metadata tcm ON tcm.concept_uuid = o.obs_question_uuid
WHERE o.encounter_type_uuid = 'abc-123-...'
  AND o.voided = 0
GROUP BY o.encounter_id, o.person_id
```

Two passes per flat table:
- **Pass 1 — question concepts** (`sp_mamba_flat_encounter_table_question_concepts_insert`): joins on `obs_question_uuid` to place obs values in the right column.
- **Pass 2 — answer concepts** (`sp_mamba_flat_encounter_table_answer_concepts_insert`): joins on `obs_value_coded_uuid` to handle multi-select / checkbox answers; uses `ON DUPLICATE KEY UPDATE` to merge into the row created in pass 1.

---

## 2. Root Problem

### Why the timeout occurs

In MySQL's default **REPEATABLE READ** isolation, every `INSERT INTO ... SELECT FROM ...` acquires **next-key locks** on all rows it reads from the source table. These locks are held until the statement finishes. On a dataset with 20 M+ obs rows, a single pivot INSERT can run for several minutes on spinning disk. Any other query that needs to write to `mamba_z_encounter_obs` during those minutes waits, then hits `innodb_lock_wait_timeout` (default 50 s) and dies with:

```
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

### Why previous batching attempts were 10× slower

An earlier attempt at batching used SQL **OFFSET**:

```sql
-- WRONG — O(n²)
SELECT encounter_id FROM mamba_z_encounter_obs
ORDER BY encounter_id
LIMIT 100000 OFFSET 0        -- reads rows 1 … 100 000
LIMIT 100000 OFFSET 100000   -- re-reads rows 1 … 100 000, then takes next 100 000
LIMIT 100000 OFFSET 200000   -- re-reads rows 1 … 200 000, then takes next 100 000
```

MySQL has no bookmark. Every batch restarts from row 1 and discards everything before the offset. With 20 batches of 1 M rows each, total row reads = 1M + 2M + … + 20M = **210 M** instead of 20 M. This is why it was 10× slower, not faster.

---

## 3. Optimizations Applied

### 3.1 READ COMMITTED Isolation Level

**File:** `sp_mamba_flat_encounter_table_insert.sql`

```sql
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
```

#### What changes in InnoDB locking

| Isolation level | Locks acquired during INSERT…SELECT | When released |
|---|---|---|
| REPEATABLE READ (before) | Next-key lock on every row read — covers the row AND the gap before it | Held until the whole INSERT statement commits |
| READ COMMITTED (after) | Record lock on the current row only | Released immediately after the row is examined |

#### Why this is safe for ETL

REPEATABLE READ's guarantee is: "if you read the same data twice in the same transaction, you see the same value." The pivot query reads `mamba_z_encounter_obs` exactly once per flat table insert. There is no second read to be consistent with. The staging table was fully populated in a prior sequential step; nothing writes to it concurrently during the pivot. READ COMMITTED produces identical results here with a fraction of the locking footprint.

#### Practical effect

On a 20 M obs table, switching to READ COMMITTED can cut the lock hold time from **minutes** to **seconds** per batch, eliminating virtually all lock-wait timeouts regardless of batching.

---

### 3.2 Encounter-Range Batching (Core Fix)

**Files:** `sp_mamba_flat_encounter_table_insert.sql`, `sp_mamba_flat_encounter_table_question_concepts_insert.sql`, `sp_mamba_flat_encounter_table_answer_concepts_insert.sql`

#### The approach

Instead of processing all encounters in one giant INSERT, the full-load path now loops over `encounter_id` ranges:

```sql
-- In sp_mamba_flat_encounter_table_insert (full load path):
SELECT MIN(encounter_id), MAX(encounter_id)
INTO batch_start, max_enc_id
FROM mamba_z_encounter_obs
WHERE encounter_type_uuid = @encounter_type_uuid;

WHILE batch_start <= max_enc_id DO
    CALL sp_mamba_flat_encounter_table_question_concepts_insert(
        ..., batch_start, batch_start + batch_size - 1, 0
    );
    CALL sp_mamba_flat_encounter_table_answer_concepts_insert(
        ..., batch_start, batch_start + batch_size - 1, 0
    );
    SET batch_start = batch_start + batch_size;
END WHILE;
```

Each sub-SP adds `AND o.encounter_id BETWEEN p_min_enc_id AND p_max_enc_id` to the WHERE clause.

#### Why range batching is O(n), not O(n²)

MySQL seeks into the `idx_enc_type_enc_id` composite index at `(encounter_type_uuid, batch_start)` and scans forward to `batch_start + batch_size - 1`, then stops. The next batch begins exactly where the previous one ended. Total rows scanned across all batches = exactly the number of rows that match `encounter_type_uuid`. No rows are re-read.

```
Batch 1: index seek to enc_id=1,      scan forward to 100000  → reads ~1.5 M obs
Batch 2: index seek to enc_id=100001, scan forward to 200000  → reads ~1.5 M obs
...total: n rows scanned regardless of batch count
```

#### What each batch commits

Each pair of `question_concepts_insert` + `answer_concepts_insert` calls runs as its own autocommit transaction (MySQL default). This means:
- Lock scope per transaction: only the obs rows in the current `encounter_id` range
- Lock duration: the time to process one batch, not the entire table
- If a lock wait timeout occurs, only the current batch fails, not the entire flat table load

#### Sparse encounter_id ranges

If encounter IDs are sparse (e.g., min=1, max=5,000,000 but only 50,000 valid encounters), some batches will cover empty ranges. An empty-range batch runs a fast index seek, finds no rows, commits with zero work. The overhead of empty iterations is negligible compared to the locking and sorting savings.

---

### 3.3 Removed ORDER BY from Pivot Inserts

**Files:** `sp_mamba_flat_encounter_table_question_concepts_insert.sql`, `sp_mamba_flat_encounter_table_answer_concepts_insert.sql`

**Before:**
```sql
GROUP BY o.encounter_id, o.person_id
ORDER BY o.encounter_id ASC    -- removed
```

#### What `ORDER BY` was doing

MySQL evaluated the full `GROUP BY` aggregation, producing a result set. The `ORDER BY` then sorted the entire result set **before** any row was written to the flat table. On 500,000 grouped encounters this was a full external sort:

- If the result fits in `sort_buffer_size` (default 256 KB) → in-memory sort, fast.
- If it exceeds the buffer (500,000 rows × ~200 bytes/row = ~100 MB) → **filesort on disk**, slow.

On a 16 GB HDD machine, this disk-based sort added minutes to each flat table load.

#### Why it was pointless

The flat table's primary key is `encounter_id` (InnoDB clustered index). InnoDB physically stores rows in primary key order in its B-tree, regardless of the order they were inserted. Whether inserts arrive sorted or random, the resulting B-tree structure — and therefore all query results — are identical. Inserting in pre-sorted order slightly reduces B-tree page splits, but `GROUP BY encounter_id` already approximates sorted order via the index. The explicit `ORDER BY` was a redundant, expensive re-sort on top of an already-approximately-sorted result.

#### Rule of thumb

`ORDER BY` inside an `INSERT INTO ... SELECT ...` never affects the correctness or the final content of an InnoDB table. It only affects the insertion order, which InnoDB ignores in favour of its own tree structure. Remove it unless you need the output for something else.

---

### 3.4 Incremental Update — Eliminated N+1

**File:** `sp_mamba_flat_table_incremental_update_encounter.sql`

#### What the incremental update does

After the first full ETL run, subsequent runs only process encounters with new or changed obs. `sp_mamba_flat_table_incremental_update_encounter` finds those encounters and rebuilds their flat rows: delete the stale row, pivot all current obs for that encounter, insert a fresh row.

#### The old O(N) approach — one SP call per encounter

```sql
-- OLD cursor fetched one row per (encounter_id, flat_table_name):
DECLARE cursor_flat_tables CURSOR FOR
    SELECT DISTINCT eo.encounter_id, cm.flat_table_name
    FROM mamba_z_encounter_obs eo
    INNER JOIN mamba_concept_metadata cm ON ...
    WHERE eo.incremental_record = 1;

FOR EACH (encounter_id, tbl_name):
    CALL sp_mamba_flat_encounter_table_insert(tbl_name, encounter_id);
```

Inside every single call to `sp_mamba_flat_encounter_table_insert`:

| Step | Operation | Cost |
|---|---|---|
| 1 | `DROP TEMPORARY TABLE temp_concept_metadata` | Medium |
| 2 | `CREATE TEMPORARY TABLE ... (6 indexes)` | **High** — 6 B-tree builds |
| 3 | `INSERT INTO temp_concept_metadata SELECT DISTINCT FROM mamba_concept_metadata` | Medium |
| 4 | `SELECT GROUP_CONCAT(...)` | Medium |
| 5 | `SELECT DISTINCT encounter_type_uuid` | Low |
| 6 | `DELETE FROM flat_table WHERE encounter_id = ?` | Low |
| 7 | Prepare + execute question concepts INSERT | Low (one encounter) |
| 8 | `SELECT GROUP_CONCAT(...)` for update columns | Medium |
| 9 | Prepare + execute answer concepts INSERT | Low (one encounter) |

Steps 1–5 and 8 produce the **same result for every encounter in the same flat table**. `mamba_concept_metadata` for `flat_hiv` does not change between encounter 12345 and 12346. With 50,000 modified encounters across 5 flat tables, these steps executed 50,000 times when they needed to execute only 5 times.

#### The new O(flat_tables) approach — one SP call per flat table

```sql
-- NEW cursor fetches one row per DISTINCT flat_table_name:
DECLARE cursor_flat_tables CURSOR FOR
    SELECT DISTINCT cm.flat_table_name
    FROM mamba_z_encounter_obs eo
    INNER JOIN mamba_concept_metadata cm ON ...
    WHERE eo.incremental_record = 1;

FOR EACH tbl_name:
    CALL sp_mamba_flat_encounter_table_insert(tbl_name, NULL, 1);
    -- p_incremental_only=1: batch delete + batch re-insert for all modified encounters
```

Inside the call with `p_incremental_only = 1`:

```sql
-- Delete ALL modified encounters for this flat table in one statement:
DELETE FROM `flat_hiv` WHERE encounter_id IN (
    SELECT DISTINCT encounter_id FROM mamba_z_encounter_obs
    WHERE encounter_type_uuid = '...' AND incremental_record = 1
);

-- Re-insert ALL obs for those encounters (not just modified obs):
INSERT INTO `flat_hiv`
SELECT ... FROM mamba_z_encounter_obs o
WHERE o.encounter_id IN (
    SELECT DISTINCT encounter_id FROM mamba_z_encounter_obs
    WHERE encounter_type_uuid = '...' AND incremental_record = 1
)
AND o.voided = 0 ...
GROUP BY o.encounter_id, o.person_id;
```

#### Why re-fetch ALL obs, not just the modified ones

Say encounter 100 has obs A (`incremental_record = 0`, pre-existing) and obs B (`incremental_record = 1`, new). If we only inserted obs B's data, the rebuilt flat row would be missing obs A's value. The `incremental_record = 1` flag is only used to **identify which encounters need rebuilding**, not to filter which obs are included in the rebuild. The rebuild always includes all non-voided obs for the encounter.

#### Scale comparison

| Scenario | Old: temp tables created | New: temp tables created |
|---|---|---|
| 1 000 modified encounters, 3 flat tables | 3 000 | 3 |
| 50 000 modified encounters, 5 flat tables | 250 000 | 5 |
| 200 000 modified encounters, 5 flat tables | 1 000 000 | 5 |

---

### 3.5 Fixed O(n²) OFFSET Batching in Obs Update

**File:** `sp_mamba_z_encounter_obs_update.sql`

This SP back-fills `obs_value_text` (human-readable concept name) and `obs_value_coded_uuid` for coded/select obs after the initial obs staging load.

#### Before — OFFSET batching

```sql
WHILE mamba_offset < total_records DO
    UPDATE mamba_z_encounter_obs z
    JOIN (
        SELECT encounter_id FROM mamba_z_encounter_obs
        ORDER BY encounter_id
        LIMIT batch_size OFFSET mamba_offset   -- O(n²)
    ) AS filter ON filter.encounter_id = z.encounter_id
    ...
    SET mamba_offset = mamba_offset + batch_size;
END WHILE;
```

Each batch's inner subquery re-scans from row 1 and discards `mamba_offset` rows. With 20 M rows and 1 M batch size:
- Batch 1: scans 1 M rows
- Batch 2: scans 2 M rows
- ...
- Batch 20: scans 20 M rows
- **Total: 210 M row scans** to process 20 M rows

#### After — ID-range batching

```sql
SELECT MIN(obs_id), MAX(obs_id)
INTO min_obs_id, max_obs_id
FROM mamba_z_encounter_obs
WHERE obs_value_coded IS NOT NULL;

SET batch_start = min_obs_id;
WHILE batch_start <= max_obs_id DO
    UPDATE mamba_z_encounter_obs z
    INNER JOIN mamba_temp_value_coded_values mtv ON z.obs_value_coded = mtv.concept_id
    SET z.obs_value_text = mtv.concept_name,
        z.obs_value_coded_uuid = mtv.concept_uuid
    WHERE z.obs_value_coded IS NOT NULL
      AND z.obs_id BETWEEN batch_start AND batch_start + batch_size - 1;

    SET batch_start = batch_start + batch_size;
END WHILE;
```

Uses `obs_id` (the primary key) for range navigation. MySQL seeks to `batch_start` in the clustered index and scans forward `batch_size` rows. Each batch is an O(1) seek + O(batch_size) scan. **Total: 20 M row scans** regardless of batch count.

---

### 3.6 Composite Index on mamba_z_encounter_obs

**File:** `sp_mamba_z_encounter_obs_create.sql`

```sql
INDEX idx_enc_type_enc_id (encounter_type_uuid, encounter_id)
```

#### Why a composite index outperforms two single-column indexes

The pivot query's WHERE clause is:

```sql
WHERE o.encounter_type_uuid = 'abc-123'        -- equality filter
  AND o.encounter_id BETWEEN 1 AND 100000      -- range filter (batch mode)
```

**With two separate single-column indexes:**
MySQL can only use one index per table access. It picks the more selective one (`encounter_type_uuid`), retrieves all rows for that encounter type (possibly millions), then evaluates the `encounter_id BETWEEN` as a filter on each retrieved row. In batch mode, this fetches all rows for the encounter type, then discards those outside the current batch range.

**With the composite index `(encounter_type_uuid, encounter_id)`:**
The B-tree is sorted first by `encounter_type_uuid`, then by `encounter_id` within each type. MySQL:
1. Seeks to the first entry where `encounter_type_uuid = 'abc-123'` AND `encounter_id >= batch_start`
2. Scans forward until `encounter_id > batch_end`
3. Stops — no rows outside the range are read

This is a single range scan with zero wasted reads. The savings are largest when a single encounter type has many rows and each batch covers a small fraction of them.

#### Column order rule

A composite index `(A, B)` supports:
- `WHERE A = x` — leftmost prefix, index is used ✓
- `WHERE A = x AND B BETWEEN y AND z` — full use, optimal ✓
- `WHERE B = y` — cannot use the index without the leading column ✗

`(encounter_type_uuid, encounter_id)` places the equality filter first and the range filter second. This is the only correct order for this use case.

---

### 3.7 Raised group_concat_max_len to 1 MB

**File:** `sp_mamba_flat_encounter_table_insert.sql`

```sql
SET SESSION group_concat_max_len = 1048576;  -- was 20 000
```

#### What this generates

The pivot SQL is built dynamically:

```sql
SELECT GROUP_CONCAT(
    DISTINCT CONCAT(
        'MAX(CASE WHEN `column_label` = ''', column_label, ''' THEN ', obs_value_column, ' END) `', column_label, '`'
    ) ORDER BY id ASC
)
INTO @column_labels
FROM temp_concept_metadata;
```

Each column contributes approximately:
```
MAX(CASE WHEN `column_label` = 'some_long_concept_name' THEN obs_value_text END) `some_long_concept_name`
```
~140–180 characters per column.

| Columns | Approximate length | 20 000 limit | 1 048 576 limit |
|---|---|---|---|
| 100 | ~15 000 chars | Safe | Safe |
| 140 | ~20 000 chars | At the edge | Safe |
| 150 | ~22 500 chars | **Truncated** | Safe |
| 500 | ~75 000 chars | **Truncated** | Safe |

#### What happens at truncation

`GROUP_CONCAT` truncates **silently** — no error, no warning unless you run `SHOW WARNINGS`. The generated SQL becomes:

```sql
..., MAX(CASE WHEN `column_label` = 'last_co   ← cut mid-expression
```

When executed, this either:
- Raises a syntax error (captured in `_mamba_etl_error_log`, flat table stays empty for that run)
- Or, in some MySQL versions, produces a flat table **missing its last N columns** — silent data loss

This was a latent correctness bug for any deployment with 140+ concepts per encounter type. The 1 MB limit accommodates ~7 000 columns, which exceeds any realistic encounter form.

---

## 4. Hardware Tuning Guide

The `flat_table_load_batch_size` setting controls the number of encounters processed per batch in the full-load path. Choose based on your hardware profile:

| Hardware Profile | Recommended batch_size | Reasoning |
|---|---|---|
| 16 GB RAM + HDD (7200 RPM) | **50 000** | Short lock windows, low peak memory. HDD random I/O is the bottleneck; smaller batches reduce I/O burst duration |
| 16 GB RAM + SSD | **200 000** | I/O is fast. Larger batches amortise loop overhead. Keep working set under ~2 GB |
| ≥ 32 GB RAM + SSD | **300 000** | More buffer pool space; larger working set is fine |
| ≥ 64 GB RAM + NVMe | **500 000** | Entire obs table may fit in buffer pool. Maximise batch size to minimise loop iterations |

Set via `openmrs-runtime.properties` (takes effect on next module restart):

```properties
mambaetl.analysis.flat_table_load_batch_size=50000
```

Or update live without a restart (takes effect on the next ETL run):

```sql
UPDATE _mamba_etl_user_settings SET flat_table_load_batch_size = 50000;
```

**Do not set batch_size = 0** — this causes an infinite loop in the batch iterator. The minimum useful value is 1 000.

### Additional MySQL server settings to consider

These are server-level settings (set in `my.cnf` or `SET GLOBAL`). MambaETL does not set these automatically, but they significantly affect performance at scale:

```ini
# Increase for large datasets. Rule: 60–70% of available RAM if MySQL is the only workload.
innodb_buffer_pool_size = 10G

# Avoid immediate lock-wait failures during long incremental runs.
innodb_lock_wait_timeout = 300

# Increase if sort operations spill to disk frequently (check EXPLAIN for "Using filesort").
sort_buffer_size = 4M

# Increase for GROUP BY aggregations on large tables.
tmp_table_size = 256M
max_heap_table_size = 256M
```

---

## 5. Configuration Reference

### openmrs-runtime.properties keys

| Key | Default | Description |
|---|---|---|
| `mambaetl.analysis.flat_table_load_batch_size` | `100000` | Encounter-ID range batch size for flat table inserts |
| `mambaetl.analysis.etl_interval` | `300` | ETL scheduler interval in seconds |
| `mambaetl.analysis.incremental_mode` | `1` | 0 = always full rebuild; 1 = incremental after first run |
| `mambaetl.analysis.columns` | `40` | Max columns per flat table before partitioning |
| `mambaetl.analysis.locale` | `en` | Preferred concept name locale |

### _mamba_etl_user_settings table

The Java layer reads the properties file once on startup and writes them into this table. The MySQL EVENT scheduler reads from this table at runtime (session variables set in a client session are invisible to the scheduler's session).

To change `flat_table_load_batch_size` without a restart:

```sql
UPDATE _mamba_etl_user_settings SET flat_table_load_batch_size = 200000;
-- Takes effect on the next scheduled ETL run
```

---

## 6. Correctness Audit

This section documents every behavioural difference between the old and new code, and confirms which produce identical flat table output.

### 6.1 READ COMMITTED — no output change

The ETL pipeline is sequential: `mamba_z_encounter_obs` is fully populated before any flat table insert begins. No concurrent session writes to `mamba_z_encounter_obs` during the pivot. READ COMMITTED and REPEATABLE READ produce the same rows for a table that is not being concurrently modified. **Output: identical.**

The session isolation level is set inside `sp_mamba_flat_encounter_table_insert` and persists for the ETL scheduler session for all subsequent incremental runs. This is intentional and appropriate.

### 6.2 Encounter-range batching — no output change

Each encounter belongs to exactly one `encounter_id` range — encounter 50000 is in batch 1 (1–100000) only. The `GROUP BY o.encounter_id, o.person_id` aggregation operates entirely within the batch containing that encounter's rows. No cross-batch encounter splitting is possible.

The `ON DUPLICATE KEY UPDATE` in the answer concepts pass merges coded answers into the row created by the question concepts pass. Since both passes use the same `encounter_id` range filter, the row to be updated always exists within the same batch. **Output: identical.**

### 6.3 ORDER BY removal — no output change

`ORDER BY` inside `INSERT INTO ... SELECT ...` only affects the order in which rows are handed to the storage engine. InnoDB stores rows in primary key (encounter_id) order in its clustered B-tree regardless. The final table contents — the rows you read back with SELECT — are identical whether inserts arrived sorted or unsorted. **Output: identical.**

### 6.4 Incremental N+1 fix — no output change

**Old path:** for encounter 12345 in flat_hiv:
1. Delete flat_hiv WHERE encounter_id = 12345
2. Insert flat_hiv WHERE encounter_id = 12345 (fetches all obs for 12345, no incremental_record filter)

**New path:** for all modified encounters in flat_hiv at once:
1. Delete flat_hiv WHERE encounter_id IN (all modified encounters for this enc_type)
2. Insert flat_hiv WHERE encounter_id IN (same set) — fetches ALL obs for those encounters, not just incremental ones

The critical invariant is preserved: **the rebuild always includes all non-voided obs for an encounter, not just the newly modified obs.** The `incremental_record = 1` filter is only used to identify which encounters need rebuilding, never to restrict which obs rows are included in the rebuilt flat row.

**Voided encounters:** If an encounter's obs are voided, `incremental_record = 1` is set by the incremental obs update step. The batch delete removes the stale flat row. The batch re-insert applies `AND o.voided = 0`, so voided obs are excluded. If all obs for an encounter are voided, no flat row is produced — which is correct. **Output: identical.**

**Partitioned flat tables** (flat_hiv_1, flat_hiv_2 for encounter types with many concepts): The cursor in `sp_mamba_flat_table_incremental_update_encounter` uses `DISTINCT cm.flat_table_name`. Each partition is processed separately with its own `temp_concept_metadata` populated for only that partition's columns. **Output: identical per partition.**

### 6.5 OFFSET → range batching in obs update — no output change

The obs update sets `obs_value_text` and `obs_value_coded_uuid` based on `obs_value_coded`. Each row's final value depends only on its own `obs_value_coded`, not on any other row. Changing the order in which rows are updated does not change the final values. **Output: identical.**

### 6.6 Composite index — no output change

An index is a read-access optimisation. It does not affect which rows are stored, their values, or which rows are returned by a query (a query without an index returns the same rows as a query that uses one). **Output: identical.**

### 6.7 group_concat_max_len — correctness IMPROVEMENT

This is the only change that **corrects a pre-existing silent bug**.

With the old 20 000 character limit, any deployment with more than ~140 concept columns per encounter type would have its pivot SQL silently truncated. The resulting malformed SQL would either:
- Fail with a syntax error (flat table stays empty for that run), or
- In some scenarios, produce a flat table **missing the last N columns** with no error raised

With the 1 MB limit, deployments with up to ~7 000 columns per encounter type are handled correctly. **Output: more complete and correct for wide tables.**

### 6.8 Known pre-existing issues (not introduced by this change)

These exist in both old and new code and are documented here for awareness:

**`VALUES()` function deprecation (MySQL 8.0.20+)**

```sql
-- In answer_concepts_insert ON DUPLICATE KEY UPDATE:
col = COALESCE(VALUES(col), col)
```

`VALUES()` in `ON DUPLICATE KEY UPDATE` is deprecated since MySQL 8.0.20 in favour of row aliases. This produces a deprecation warning in MySQL 8.0.20+ but does not affect correctness in current MySQL versions. A future migration to MySQL 9.x may require replacing this with:

```sql
INSERT INTO t (...) VALUES (...) AS new_row
ON DUPLICATE KEY UPDATE col = COALESCE(new_row.col, col)
```

**`GROUP BY o.encounter_id, o.person_id`**

In OpenMRS, one encounter always belongs to one person. However, if data quality issues exist where the same `encounter_id` appears with two different `person_id` values in the obs table, the GROUP BY would produce two rows for that encounter_id, causing a duplicate key error on INSERT. This would surface as an error in `_mamba_etl_error_log`. Not introduced by this change.

**`@encounter_type_uuid` is a session variable, not a DECLARE'd local**

```sql
SELECT DISTINCT `encounter_type_uuid` INTO @encounter_type_uuid FROM temp_concept_metadata LIMIT 1;
```

If `temp_concept_metadata` is empty (a flat table mapped to no valid concepts), this SELECT produces a warning and leaves `@encounter_type_uuid` with its value from the previous SP call. The `IF @column_labels IS NOT NULL THEN` guard catches this case and exits early, so the stale `@encounter_type_uuid` is never used. Not a correctness issue, but worth knowing. Not introduced by this change.

---

## 7. Files Changed

### SQL Stored Procedures

| File | Change |
|---|---|
| `xf_system/etl_flat_table/sp_mamba_flat_encounter_table_insert.sql` | Added `p_incremental_only` param; added encounter-range batch loop for full load; added batch incremental delete+insert branch; READ COMMITTED; group_concat_max_len 1MB; reads batch_size from user_settings |
| `xf_system/etl_flat_table/sp_mamba_flat_encounter_table_question_concepts_insert.sql` | Added `p_min_enc_id`, `p_max_enc_id`, `p_incremental_only` params; added BETWEEN and IN-subquery filter modes; removed ORDER BY |
| `xf_system/etl_flat_table/sp_mamba_flat_encounter_table_answer_concepts_insert.sql` | Same params and filter modes as above; removed ORDER BY |
| `xf_system/etl_flat_table/sp_mamba_flat_encounter_table_insert_all.sql` | Updated call to pass 3rd param `0` |
| `xf_system/etl_flat_table/incremental/sp_mamba_flat_table_incremental_insert_all.sql` | Updated call to pass 3rd param `0` |
| `xf_system/etl_flat_table/incremental/sp_mamba_flat_table_incremental_update_encounter.sql` | Cursor changed from per-encounter to per-flat-table; calls insert with `p_incremental_only=1` |
| `z/obs/sp_mamba_z_encounter_obs_update.sql` | Replaced OFFSET loop with obs_id range loop |
| `z/obs/sp_mamba_z_encounter_obs_create.sql` | Added composite `INDEX idx_enc_type_enc_id (encounter_type_uuid, encounter_id)` |

### Settings / Config

| File | Change |
|---|---|
| `xf_system/etl_user_settings/sp_mamba_etl_user_settings_create.sql` | Added `flat_table_load_batch_size INT NOT NULL DEFAULT 100000` column |
| `xf_system/etl_user_settings/sp_mamba_etl_user_settings_insert.sql` | Added `flat_table_load_batch_size` param and column in INSERT |
| `xf_system/etl_user_settings/sp_mamba_etl_user_settings.sql` | Added `flat_table_load_batch_size` param, passed to insert SP |
| `xf_system/sp_mamba_etl_setup.sql` | Added `flat_table_load_batch_size` param, passed to user_settings SP |
| `mamba_main.sql` | Added 8th `?` placeholder for `CALL sp_mamba_etl_setup` |

### Java

| File | Change |
|---|---|
| `util/MambaETLProperties.java` | Added `flatTableLoadBatchSize` field; reads `mambaetl.analysis.flat_table_load_batch_size` from runtime properties; default 100 000; added getter |
| `api/dao/impl/JdbcFlattenDatabaseDao.java` | Binds `getFlatTableLoadBatchSize()` as parameter 8 on `CALL sp_mamba_etl_setup` |

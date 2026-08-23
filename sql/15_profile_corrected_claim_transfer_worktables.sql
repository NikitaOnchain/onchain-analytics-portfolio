-- Profile all currently materialized corrected-cohort interval tables.
--
-- Output grain:
--   One global QA summary row across all matching interval tables.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_chunk_*
--   One row per decoded candidate claim Transfer event. `_TABLE_SUFFIX`
--   identifies its independently materialized interval table.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN. Scalar subqueries read grouped duplicate summaries and return one
--   value each, so they cannot multiply rows.
--
-- Filters:
--   Only two-digit chunk-table suffixes are included.
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate event keys and recipients across interval tables
--   are measured explicitly.

WITH all_chunks AS (
  SELECT
    _TABLE_SUFFIX AS table_suffix,
    chunk_number,
    block_timestamp,
    transaction_hash,
    log_index,
    recipient,
    amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

event_key_counts AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS row_count
  FROM
    all_chunks
  GROUP BY
    transaction_hash,
    log_index
),

recipient_counts AS (
  SELECT
    recipient,
    COUNT(*) AS row_count
  FROM
    all_chunks
  WHERE
    recipient IS NOT NULL
  GROUP BY
    recipient
)

SELECT
  COUNT(DISTINCT table_suffix) AS materialized_chunk_count,
  COUNT(*) AS stored_event_rows,
  COUNT(DISTINCT transaction_hash) AS distinct_transactions,
  COUNT(DISTINCT recipient) AS distinct_recipients,
  (
    SELECT COUNTIF(row_count > 1)
    FROM event_key_counts
  ) AS duplicated_event_keys,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM event_key_counts
  ) AS extra_rows_above_event_grain,
  (
    SELECT COUNTIF(row_count > 1)
    FROM recipient_counts
  ) AS recipients_in_multiple_events,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM recipient_counts
  ) AS extra_rows_above_one_per_recipient,
  COUNTIF(
    transaction_hash IS NULL
    OR log_index IS NULL
    OR block_timestamp IS NULL
    OR recipient IS NULL
    OR amount_raw IS NULL
  ) AS critical_null_rows,
  MIN(block_timestamp) AS first_transfer_timestamp,
  MAX(block_timestamp) AS last_transfer_timestamp,
  SUM(amount_raw) AS total_amount_raw,
  SAFE_DIVIDE(
    SUM(amount_raw),
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS total_amount_arb
FROM
  all_chunks;

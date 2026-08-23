-- Profile all final two-digit claimant-originated ARB Transfer source chunks.
-- Always dry-run before execution.
--
-- Output grain:
--   One global QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_*
--   Intended grain is one positive non-self decoded ARB Transfer event per row.
--
-- Join keys and expected cardinality:
--   No JOIN. Candidate key is (transaction_hash, log_index).
--
-- Filters and time boundaries:
--   Only final two-digit source chunks are included. Their union is intended to
--   cover [2023-03-23, 2023-10-02) UTC without gaps or overlaps.
--
-- Row-multiplication risk:
--   None from JOINs. Cross-chunk duplicate event keys, chunk-number mismatches,
--   source duplicates, critical NULLs, and invalid domain rows are measured.

WITH all_chunks AS (
  SELECT
    _TABLE_SUFFIX AS table_suffix,
    source_chunk_number,
    block_timestamp,
    block_number,
    transaction_hash,
    log_index,
    sender,
    destination,
    amount_raw,
    source_match_rows
  FROM
    `YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_*`
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
)

SELECT
  COUNT(DISTINCT table_suffix) AS materialized_chunk_count,
  COUNT(*) AS stored_event_rows,
  COUNT(DISTINCT CONCAT(
    transaction_hash,
    ':',
    CAST(log_index AS STRING)
  )) AS distinct_event_keys,
  COUNT(*) - COUNT(DISTINCT CONCAT(
    transaction_hash,
    ':',
    CAST(log_index AS STRING)
  )) AS extra_rows_above_event_grain,
  (
    SELECT COUNTIF(row_count > 1)
    FROM event_key_counts
  ) AS duplicated_event_keys,
  COUNT(DISTINCT transaction_hash) AS distinct_transactions,
  COUNT(DISTINCT sender) AS distinct_senders,
  COUNT(DISTINCT destination) AS distinct_destinations,
  COUNTIF(
    block_timestamp IS NULL
    OR block_number IS NULL
    OR transaction_hash IS NULL
    OR log_index IS NULL
    OR sender IS NULL
    OR destination IS NULL
    OR amount_raw IS NULL
  ) AS critical_null_rows,
  COUNTIF(source_match_rows IS NULL OR source_match_rows != 1)
    AS rows_without_exactly_one_source_match,
  COUNTIF(amount_raw <= 0) AS nonpositive_amount_rows,
  COUNTIF(destination = sender) AS self_transfer_rows,
  COUNTIF(source_chunk_number != SAFE_CAST(table_suffix AS INT64))
    AS chunk_suffix_mismatch_rows,
  MIN(block_timestamp) AS first_event_timestamp,
  MAX(block_timestamp) AS last_event_timestamp,
  MIN(block_number) AS first_block_number,
  MAX(block_number) AS last_block_number,
  SUM(amount_raw) AS gross_transfer_raw,
  SUM(amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18)
    AS gross_transfer_arb
FROM
  all_chunks;

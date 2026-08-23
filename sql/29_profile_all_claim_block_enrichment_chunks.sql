-- Profile all materialized block-enriched corrected claim-transfer chunks.
-- Always dry-run before execution.
--
-- Output grain:
--   One global QA summary row across all two-digit enriched chunk tables.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--   Intended grain is one validated claim Transfer event per row.
--
-- Join keys and expected cardinality:
--   No JOIN is used. The intended event key is
--   (transaction_hash, log_index).
--
-- Filters and time boundaries:
--   Only two-digit chunk suffixes are included. Their union is intended to
--   cover the corrected claim cohort from 2023-03-23 through 2023-10-01 UTC.
--
-- Row-multiplication risk:
--   None from JOINs. Duplicate event keys, repeated recipients, missing source
--   matches, and non-one-to-one matches are measured explicitly.

WITH all_chunks AS (
  SELECT
    _TABLE_SUFFIX AS table_suffix,
    chunk_number,
    block_timestamp,
    block_number,
    transaction_hash,
    log_index,
    recipient,
    amount_raw,
    source_match_rows
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
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
  COUNT(DISTINCT CONCAT(transaction_hash, ':', CAST(log_index AS STRING)))
    AS distinct_event_keys,
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
  COUNTIF(
    transaction_hash IS NULL
    OR log_index IS NULL
    OR block_timestamp IS NULL
    OR block_number IS NULL
    OR recipient IS NULL
    OR amount_raw IS NULL
  ) AS critical_null_rows,
  COUNTIF(source_match_rows IS NULL) AS rows_without_source_match,
  COUNTIF(source_match_rows != 1) AS rows_without_exactly_one_source_match,
  COUNTIF(chunk_number != SAFE_CAST(table_suffix AS INT64))
    AS chunk_suffix_mismatch_rows,
  MIN(block_timestamp) AS first_claim_timestamp,
  MAX(block_timestamp) AS last_claim_timestamp,
  MIN(block_number) AS first_claim_block_number,
  MAX(block_number) AS last_claim_block_number,
  SUM(amount_raw) AS total_claimed_raw,
  SUM(amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18) AS total_claimed_arb
FROM
  all_chunks;

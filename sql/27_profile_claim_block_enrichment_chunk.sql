-- Profile the materialized block-enriched corrected claim-transfer chunk 1.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA summary row for enriched corrected cohort chunk 1.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_01
--     Intended grain is one validated claim Transfer event per row.
--
-- Join keys and expected cardinality:
--   No JOIN is used. The intended event key is
--   (transaction_hash, log_index).
--
-- Filters and time boundaries:
--   No additional filter is applied. The materialized table is already limited
--   to corrected chunk 1, covering the half-open source interval from
--   2023-03-23 through 2023-03-27 UTC.
--
-- Row-multiplication risk:
--   None in this query because no JOIN or UNNEST is used. Duplicate event keys
--   and non-one-to-one source matches are reported explicitly.

SELECT
  COUNT(*) AS enriched_rows,
  COUNT(
    DISTINCT CONCAT(transaction_hash, ':', CAST(log_index AS STRING))
  ) AS distinct_claim_event_keys,
  COUNT(*) - COUNT(
    DISTINCT CONCAT(transaction_hash, ':', CAST(log_index AS STRING))
  ) AS duplicate_rows_above_event_grain,
  COUNTIF(transaction_hash IS NULL) AS null_transaction_hash_rows,
  COUNTIF(log_index IS NULL) AS null_log_index_rows,
  COUNTIF(block_timestamp IS NULL) AS null_claim_timestamp_rows,
  COUNTIF(block_number IS NULL) AS null_claim_block_number_rows,
  COUNTIF(recipient IS NULL OR recipient = '') AS null_or_empty_recipient_rows,
  COUNTIF(amount_raw IS NULL) AS null_amount_rows,
  COUNTIF(source_match_rows IS NULL) AS rows_without_source_match,
  COUNTIF(source_match_rows != 1) AS rows_without_exactly_one_source_match,
  MIN(block_timestamp) AS first_claim_timestamp,
  MAX(block_timestamp) AS last_claim_timestamp,
  MIN(block_number) AS first_claim_block_number,
  MAX(block_number) AS last_claim_block_number,
  SUM(amount_raw) AS total_claimed_raw,
  SUM(amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18) AS total_claimed_arb
FROM
  `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_01`;

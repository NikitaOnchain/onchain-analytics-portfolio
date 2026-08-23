-- Profile one materialized claimant-originated ARB Transfer source chunk.
-- Update the table suffix and expected half-open UTC bounds together.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_01
--   Intended grain is one positive non-self decoded ARB Transfer event per row.
--
-- Join keys and expected cardinality:
--   No JOIN. Candidate key is (transaction_hash, log_index).
--
-- Filters and time boundaries:
--   No row filter. The query checks that every row remains inside the expected
--   half-open interval [2023-03-23, 2023-03-27).
--
-- Row-multiplication risk:
--   None in this query. Duplicate keys and non-one-to-one source matches are
--   measured explicitly.

SELECT
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
  COUNTIF(
    block_timestamp < TIMESTAMP('2023-03-23 00:00:00+00')
    OR block_timestamp >= TIMESTAMP('2023-03-27 00:00:00+00')
  ) AS outside_expected_interval_rows,
  MIN(block_timestamp) AS first_event_timestamp,
  MAX(block_timestamp) AS last_event_timestamp,
  MIN(block_number) AS first_block_number,
  MAX(block_number) AS last_block_number,
  SUM(amount_raw) AS gross_transfer_raw,
  SUM(amount_raw) / POW(CAST(10 AS BIGNUMERIC), 18)
    AS gross_transfer_arb
FROM
  `YOUR_DATASET_ID.claimant_arb_transfer_source_chunk_01`;

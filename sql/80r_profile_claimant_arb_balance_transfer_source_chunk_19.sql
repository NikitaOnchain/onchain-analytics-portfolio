-- Profile transfer-derived ARB balance source chunk 19 after materialization.
-- Fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   Exactly one structural QA summary row for source chunk 19.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.retention_arb_transfer_source_chunk_19
--     Intended grain: one decoded ARB Transfer event per
--     (transaction_hash, log_index).
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per final two-digit row.
--
-- Join keys and expected cardinality:
--   No row-producing join is used. A DISTINCT claimant set is consulted with
--   EXISTS semijoins for cohort-relevance QA and cannot multiply source rows.
--
-- Filters and time boundaries:
--   The source table must contain only source_chunk_number = 19 and the exact
--   half-open UTC interval [2023-07-01, 2023-07-16). No output filter hides
--   defects; COUNTIF exposes out-of-domain rows.
--
-- Row-multiplication risk:
--   None. Duplicate event keys are measured explicitly. A later claimant-leg
--   transformation must reconcile any intentional two-leg expansion.

WITH claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

profiled AS (
  SELECT
    source.*,
    COUNT(*) OVER (
      PARTITION BY transaction_hash, log_index
    ) AS event_key_rows
  FROM
    `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_19` AS source
)

SELECT
  COUNT(*) AS source_rows,
  COUNT(DISTINCT FORMAT('%s:%d', transaction_hash, log_index))
    AS distinct_event_keys,
  COUNTIF(event_key_rows > 1) AS rows_on_duplicate_event_keys,
  COUNT(*) - COUNT(DISTINCT FORMAT('%s:%d', transaction_hash, log_index))
    AS extra_rows_above_unique_event_grain,
  COUNTIF(
    block_timestamp IS NULL
    OR block_number IS NULL
    OR transaction_hash IS NULL
    OR transaction_index IS NULL
    OR log_index IS NULL
    OR sender IS NULL
    OR destination IS NULL
    OR amount_raw IS NULL
    OR source_match_rows IS NULL
  ) AS critical_null_rows,
  COUNTIF(source_chunk_number != 19 OR source_chunk_number IS NULL)
    AS invalid_source_chunk_number_rows,
  COUNTIF(
    block_timestamp < TIMESTAMP('2023-07-01 00:00:00+00')
    OR block_timestamp >= TIMESTAMP('2023-07-16 00:00:00+00')
  ) AS out_of_window_rows,
  COUNTIF(
    NOT REGEXP_CONTAINS(sender, r'^0x[0-9a-f]{40}$')
    OR NOT REGEXP_CONTAINS(destination, r'^0x[0-9a-f]{40}$')
  ) AS invalid_address_rows,
  COUNTIF(amount_raw <= 0) AS non_positive_amount_rows,
  COUNTIF(source_match_rows != 1) AS invalid_source_match_rows,
  COUNTIF(
    NOT EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = profiled.sender
    )
    AND NOT EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = profiled.destination
    )
  ) AS non_claimant_related_rows,
  COUNTIF(sender = destination) AS self_transfer_rows,
  COUNTIF(
    EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = profiled.sender
    )
  ) AS claimant_sender_event_rows,
  COUNTIF(
    EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = profiled.destination
    )
  ) AS claimant_destination_event_rows,
  MIN(block_timestamp) AS first_transfer_timestamp,
  MAX(block_timestamp) AS last_transfer_timestamp,
  SUM(amount_raw) AS gross_event_amount_raw
FROM
  profiled;





















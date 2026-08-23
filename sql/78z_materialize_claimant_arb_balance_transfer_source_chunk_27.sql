-- Materialize transfer-derived ARB balance source chunk 27.
-- Fresh-dry-run this exact CTAS immediately before execution.
--
-- Configuration:
--   Source chunk 27, half-open interval [2023-10-09, 2023-10-16) UTC.
--
-- Analytical meaning:
--   A row is a positive ARB Transfer involving at least one validated claim
--   recipient. It is an input to transfer-derived balance reconstruction, not
--   proof that exact airdropped units were retained or sold.
--
-- Output grain:
--   One decoded ARB Transfer event per (transaction_hash, log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per final two-digit row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per source row.
--
-- Join keys and expected cardinality:
--   No row-producing JOIN is used. Sender and destination are tested against a
--   DISTINCT claimant set through EXISTS semijoins. The decoded source is
--   pre-aggregated to its event key and retains source_match_rows.
--
-- Filters and time boundaries:
--   1. Half-open UTC interval [2023-10-09, 2023-10-16)
--   2. Verified ARB token Transfer events not marked removed
--   3. Positive decoded amount
--   4. Sender or destination belongs to the validated cohort
--
-- Row-multiplication risk:
--   None in this event-grain source. A later address-leg transformation may
--   intentionally create up to two claimant legs per event and must reconcile
--   that multiplication explicitly.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_27`
CLUSTER BY
  sender,
  destination
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary claimant-related ARB Transfer events for transfer-derived balance source chunk 27.'
)
AS
WITH claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

source_events AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(transaction_index) AS transaction_index,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[0]'))) AS sender,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS destination,
    ANY_VALUE(SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)) AS amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-10-09 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-10-16 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
)

SELECT
  27 AS source_chunk_number,
  source.block_timestamp,
  source.block_number,
  source.transaction_hash,
  source.transaction_index,
  source.log_index,
  source.sender,
  source.destination,
  source.amount_raw,
  source.source_match_rows
FROM
  source_events AS source
WHERE
  source.amount_raw > 0
  AND (
    EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = source.sender
    )
    OR EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = source.destination
    )
  );

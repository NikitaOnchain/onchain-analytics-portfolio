-- Validate claim-block enrichment for corrected claim-transfer chunk 1.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA summary row for corrected cohort chunk 1.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_chunk_01
--     One validated claim Transfer event per row.
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events
--     One decoded event log per row.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on (transaction_hash, log_index), expected one-to-one. The public
--   source is first aggregated to one row per key while retaining
--   source_match_rows, so duplicate source keys cannot silently multiply claim
--   rows.
--
-- Filters and time boundaries:
--   1. Half-open UTC chunk interval, 2023-03-23 through 2023-03-27
--   2. ARB token contract and standard Transfer event
--   3. TokenDistributor as decoded sender
--   4. Rows that are not marked as removed
--
-- Row-multiplication risk:
--   Controlled by pre-aggregating the public source at the exact event key.
--   `source_keys_with_multiple_rows` and `rows_with_multiple_source_matches`
--   expose any source duplication instead of hiding it.

WITH source_claim_transfers AS (
  SELECT
    transaction_hash,
    log_index,
    ANY_VALUE(block_number) AS block_number,
    ANY_VALUE(block_timestamp) AS block_timestamp,
    ANY_VALUE(LOWER(JSON_VALUE(args, '$[1]'))) AS recipient,
    ANY_VALUE(
      SAFE_CAST(JSON_VALUE(args, '$[2]') AS BIGNUMERIC)
    ) AS amount_raw,
    COUNT(*) AS source_match_rows
  FROM
    `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
  WHERE
    block_timestamp >= TIMESTAMP('2023-03-23 00:00:00+00')
    AND block_timestamp < TIMESTAMP('2023-03-27 00:00:00+00')
    AND address = '0x912ce59144191c1204e64559fe8253a0e49e6548'
    AND event_signature = 'Transfer(address,address,uint256)'
    AND LOWER(JSON_VALUE(args, '$[0]')) =
      '0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9'
    AND removed IS NOT TRUE
  GROUP BY
    transaction_hash,
    log_index
),

enriched AS (
  SELECT
    claim.transaction_hash,
    claim.log_index,
    claim.block_timestamp AS claim_timestamp,
    claim.recipient AS claim_recipient,
    claim.amount_raw AS claim_amount_raw,
    source.block_number,
    source.block_timestamp AS source_timestamp,
    source.recipient AS source_recipient,
    source.amount_raw AS source_amount_raw,
    source.source_match_rows
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_chunk_01` AS claim
  LEFT JOIN
    source_claim_transfers AS source
    USING (transaction_hash, log_index)
)

SELECT
  COUNT(*) AS claim_rows_after_join,
  COUNT(DISTINCT CONCAT(transaction_hash, ':', CAST(log_index AS STRING)))
    AS distinct_claim_event_keys_after_join,
  COUNTIF(source_match_rows = 1) AS rows_with_one_source_match,
  COUNTIF(source_match_rows IS NULL) AS rows_without_source_match,
  COUNTIF(source_match_rows > 1) AS rows_with_multiple_source_matches,
  (
    SELECT COUNTIF(source_match_rows > 1)
    FROM source_claim_transfers
  ) AS source_keys_with_multiple_rows,
  COUNTIF(block_number IS NULL) AS null_enriched_block_number_rows,
  COUNTIF(source_timestamp != claim_timestamp)
    AS timestamp_mismatch_rows,
  COUNTIF(source_recipient != claim_recipient)
    AS recipient_mismatch_rows,
  COUNTIF(source_amount_raw != claim_amount_raw)
    AS amount_mismatch_rows,
  MIN(block_number) AS first_claim_block_number,
  MAX(block_number) AS last_claim_block_number
FROM
  enriched;

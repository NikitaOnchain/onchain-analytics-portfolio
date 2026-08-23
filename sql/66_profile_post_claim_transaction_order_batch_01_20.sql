-- Profile compact exact claim-transaction ordering keys for source chunks 01
-- through 20 and reconcile eligible claim events through 2023-08-16 UTC.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_order_batch_01_20
--     Intended grain is one exact claim transaction per hash.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   claim.transaction_hash = order.claim_transaction_hash, expected many-to-
--   one because a transaction can contain several claim events.
--
-- Filters and time boundaries:
--   Claim coverage is limited to exact claim timestamps before
--   2023-08-16 00:00:00 UTC, matching source batches 01 through 20.
--
-- Row-multiplication risk:
--   The claim-to-order JOIN intentionally repeats an order row for multi-claim
--   transactions. Source uniqueness is checked before coverage interpretation.

WITH order_keys AS (
  SELECT
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_01_20`
),

eligible_claims AS (
  SELECT
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    recipient AS claim_recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND block_timestamp < TIMESTAMP('2023-08-16 00:00:00+00')
),

coverage AS (
  SELECT
    claim.*,
    order_key.claim_receipt_timestamp,
    order_key.claim_receipt_block_number,
    order_key.claim_transaction_sender
  FROM
    eligible_claims AS claim
  LEFT JOIN
    order_keys AS order_key
    USING (claim_transaction_hash)
)

SELECT
  (SELECT COUNT(*) FROM order_keys) AS order_rows,
  (SELECT COUNT(DISTINCT claim_transaction_hash) FROM order_keys)
    AS distinct_order_transaction_hashes,
  (SELECT COUNT(*) - COUNT(DISTINCT claim_transaction_hash) FROM order_keys)
    AS duplicate_rows_above_transaction_grain,
  (SELECT COUNT(*) FROM eligible_claims) AS eligible_claim_events,
  (SELECT COUNT(DISTINCT claim_transaction_hash) FROM eligible_claims)
    AS eligible_distinct_claim_transactions,
  COUNTIF(claim_receipt_timestamp IS NULL) AS claim_events_missing_order_key,
  COUNTIF(claim_receipt_timestamp != claim_timestamp)
    AS claim_timestamp_mismatch_rows,
  COUNTIF(claim_receipt_block_number != claim_block_number)
    AS claim_block_mismatch_rows,
  COUNTIF(claim_transaction_sender != claim_recipient)
    AS delegated_claim_events,
  (SELECT COUNTIF(
    claim_receipt_timestamp IS NULL
    OR claim_receipt_block_number IS NULL
    OR claim_block_hash IS NULL
    OR claim_transaction_hash IS NULL
    OR claim_transaction_index IS NULL
    OR claim_transaction_sender IS NULL
    OR claim_receipt_match_rows IS NULL
    OR claim_block_match_rows IS NULL
  ) FROM order_keys) AS critical_null_order_rows,
  (SELECT COUNTIF(
    claim_receipt_match_rows != 1 OR claim_block_match_rows != 1
  ) FROM order_keys) AS order_rows_without_exactly_one_source_match
FROM
  coverage;

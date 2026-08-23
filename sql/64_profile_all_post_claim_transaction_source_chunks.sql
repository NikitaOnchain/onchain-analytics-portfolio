-- Profile all final two-digit post-claim transaction source chunks and verify
-- exact claim-receipt coverage before full-cohort activity derivation.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One global QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_*
--     Intended grain is one successful top-level transaction per hash per
--     non-overlapping source chunk. Only two-digit suffixes are included.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   Exact claim transaction hash to staged source is many-to-one because a
--   transaction can contain several claim events. Source transaction hashes
--   must remain globally unique across non-overlapping chunks.
--
-- Filters and time boundaries:
--   Only two-digit source and claim chunks are included. Their intended union
--   covers [2023-03-23, 2023-10-02) UTC.
--
-- Row-multiplication risk:
--   No JOIN affects the main source profile. Exact claim coverage is evaluated
--   with EXISTS predicates, which cannot multiply claim rows. Duplicate source
--   transaction hashes and chunk suffix mismatches are measured explicitly.

WITH all_source AS (
  SELECT
    _TABLE_SUFFIX AS table_suffix,
    *
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_source_full_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

claims AS (
  SELECT
    transaction_hash AS claim_transaction_hash,
    LOWER(recipient) AS claim_recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

source_key_counts AS (
  SELECT
    transaction_hash,
    COUNT(*) AS row_count
  FROM
    all_source
  GROUP BY
    transaction_hash
),

claim_coverage AS (
  SELECT
    claim_transaction_hash,
    claim_recipient,
    EXISTS (
      SELECT 1
      FROM all_source AS source
      WHERE source.transaction_hash = claim.claim_transaction_hash
        AND source.is_claim_transaction
    ) AS has_claim_receipt,
    EXISTS (
      SELECT 1
      FROM all_source AS source
      WHERE source.transaction_hash = claim.claim_transaction_hash
        AND source.is_claim_transaction
        AND source.from_address = claim.claim_recipient
    ) AS claim_initiated_by_recipient
  FROM
    claims AS claim
)

SELECT
  COUNT(DISTINCT table_suffix) AS materialized_chunk_count,
  COUNT(*) AS stored_transaction_rows,
  COUNT(DISTINCT transaction_hash) AS distinct_transaction_hashes,
  (
    SELECT COUNTIF(row_count > 1)
    FROM source_key_counts
  ) AS duplicated_transaction_hashes,
  (
    SELECT COALESCE(SUM(IF(row_count > 1, row_count - 1, 0)), 0)
    FROM source_key_counts
  ) AS extra_rows_above_transaction_grain,
  COUNT(DISTINCT IF(
    initiated_by_claim_recipient,
    from_address,
    NULL
  )) AS distinct_claim_recipient_senders,
  COUNTIF(initiated_by_claim_recipient) AS claimant_initiated_rows,
  COUNTIF(is_claim_transaction) AS stored_claim_transaction_rows,
  COUNTIF(NOT initiated_by_claim_recipient AND NOT is_claim_transaction)
    AS rows_without_valid_source_role,
  COUNTIF(
    block_timestamp IS NULL
    OR block_number IS NULL
    OR block_hash IS NULL
    OR transaction_hash IS NULL
    OR transaction_index IS NULL
    OR from_address IS NULL
    OR gas_used IS NULL
  ) AS critical_null_rows,
  COUNTIF(receipt_match_rows IS NULL OR receipt_match_rows != 1)
    AS rows_without_exactly_one_receipt_match,
  COUNTIF(block_match_rows IS NULL OR block_match_rows != 1)
    AS rows_without_exactly_one_block_match,
  COUNTIF(block_timestamp != matched_block_timestamp)
    AS block_timestamp_mismatch_rows,
  COUNTIF(source_chunk_number != SAFE_CAST(table_suffix AS INT64))
    AS chunk_suffix_mismatch_rows,
  (
    SELECT COUNTIF(NOT has_claim_receipt)
    FROM claim_coverage
  ) AS claim_events_missing_exact_receipt,
  (
    SELECT COUNTIF(NOT claim_initiated_by_recipient)
    FROM claim_coverage
  ) AS delegated_claim_events,
  MIN(block_timestamp) AS first_source_timestamp,
  MAX(block_timestamp) AS last_source_timestamp,
  MIN(block_number) AS first_block_number,
  MAX(block_number) AS last_block_number
FROM
  all_source;

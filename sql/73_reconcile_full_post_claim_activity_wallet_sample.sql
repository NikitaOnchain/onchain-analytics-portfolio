-- Select and reconcile a deterministic five-stratum full-cohort post-claim
-- activity wallet sample to the retained compact partial-metrics tables.
-- Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   Stored metrics describe successful top-level Arbitrum transactions
--   initiated by a validated claim recipient after exact claim order. They
--   measure address activity, not retained human usage, protocol engagement,
--   token retention, or sales.
--
-- Output grain:
--   One sampled exact claim event per mutually exclusive activity stratum.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*
--     One active exact claim event per non-overlapping source chunk. Inactive
--     claims intentionally have no partial row.
--
-- Join keys and expected cardinality:
--   Exact claim-event key is (claim_transaction_hash, claim_log_index).
--   A sampled claim can match zero partial rows when inactive or several
--   partial rows when its seven-day window crosses source chunks.
--
-- Filters and time boundaries:
--   Only final two-digit partial-table suffixes are used. Stored partials
--   already apply strict block-aware ordering and half-open elapsed 24-hour
--   and seven-day windows.
--
-- Row-multiplication risk:
--   Partial rows, active-date arrays, and target-address arrays are aggregated
--   independently to exact claim grain before the final one-to-one joins.

WITH labeled AS (
  SELECT
    CASE
      WHEN claim_was_delegated THEN 'Delegated claim'
      WHEN successful_transaction_count_7d = 0
        THEN 'No activity within 7d'
      WHEN successful_transaction_count_24h = 0
        THEN 'Activity after 24h only'
      WHEN successful_transaction_count_7d = 1
        THEN 'One transaction within 7d'
      ELSE 'Multiple transactions within 7d'
    END AS sample_stratum,
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort`
),

sampled AS (
  SELECT
    * EXCEPT (sample_rank)
  FROM (
    SELECT
      *,
      COUNT(*) OVER (PARTITION BY sample_stratum) AS stratum_population,
      ROW_NUMBER() OVER (
        PARTITION BY sample_stratum
        ORDER BY claim_transaction_hash, claim_log_index
      ) AS sample_rank
    FROM
      labeled
  )
  WHERE
    sample_rank = 1
),

sampled_partial AS (
  SELECT
    partial.*
  FROM
    `YOUR_DATASET_ID.post_claim_activity_partial_metrics_source_chunk_*`
      AS partial
  INNER JOIN
    sampled
    USING (claim_transaction_hash, claim_log_index)
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

partial_scalar_controls AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(*) AS matched_partial_rows,
    COUNT(DISTINCT source_chunk_number) AS matched_source_chunks,
    SUM(successful_transaction_count_24h_partial)
      AS recomputed_transaction_count_24h,
    MIN(first_activity_timestamp_24h_partial)
      AS recomputed_first_activity_timestamp_24h,
    SUM(successful_transaction_count_7d_partial)
      AS recomputed_transaction_count_7d,
    MIN(first_activity_timestamp_7d_partial)
      AS recomputed_first_activity_timestamp_7d
  FROM
    sampled_partial
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

partial_metadata_controls AS (
  SELECT
    partial.claim_transaction_hash,
    partial.claim_log_index,
    COUNTIF(
      partial.claim_chunk_number != sample.chunk_number
      OR partial.claim_timestamp != sample.claim_timestamp
      OR partial.claim_block_number != sample.claim_block_number
      OR partial.claim_block_hash != sample.claim_block_hash
      OR partial.claim_transaction_index != sample.claim_transaction_index
      OR partial.claim_recipient != sample.claim_recipient
      OR partial.claim_transaction_sender != sample.claim_transaction_sender
      OR partial.claim_amount_raw != sample.claim_amount_raw
    ) AS partial_metadata_mismatch_rows
  FROM
    sampled_partial AS partial
  INNER JOIN
    sampled AS sample
    USING (claim_transaction_hash, claim_log_index)
  GROUP BY
    partial.claim_transaction_hash,
    partial.claim_log_index
),

partial_date_controls AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(DISTINCT active_date) AS recomputed_active_utc_day_count_7d
  FROM
    sampled_partial,
    UNNEST(active_utc_dates_7d_partial) AS active_date
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

partial_target_controls AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(DISTINCT target_address) AS recomputed_distinct_target_count_7d
  FROM
    sampled_partial,
    UNNEST(target_addresses_7d_partial) AS target_address
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

reconciled AS (
  SELECT
    sample.sample_stratum,
    sample.stratum_population,
    sample.claim_timestamp,
    sample.claim_transaction_hash,
    sample.claim_log_index,
    sample.claim_recipient,
    sample.claim_transaction_sender,
    sample.claim_was_delegated,
    sample.claim_amount_raw,
    sample.successful_transaction_count_24h
      AS stored_transaction_count_24h,
    COALESCE(scalar.recomputed_transaction_count_24h, 0)
      AS recomputed_transaction_count_24h,
    sample.first_activity_timestamp_24h
      AS stored_first_activity_timestamp_24h,
    scalar.recomputed_first_activity_timestamp_24h,
    sample.successful_transaction_count_7d
      AS stored_transaction_count_7d,
    COALESCE(scalar.recomputed_transaction_count_7d, 0)
      AS recomputed_transaction_count_7d,
    sample.active_utc_day_count_7d
      AS stored_active_utc_day_count_7d,
    COALESCE(dates.recomputed_active_utc_day_count_7d, 0)
      AS recomputed_active_utc_day_count_7d,
    sample.distinct_target_count_7d
      AS stored_distinct_target_count_7d,
    COALESCE(targets.recomputed_distinct_target_count_7d, 0)
      AS recomputed_distinct_target_count_7d,
    sample.first_activity_timestamp_7d
      AS stored_first_activity_timestamp_7d,
    scalar.recomputed_first_activity_timestamp_7d,
    COALESCE(scalar.matched_partial_rows, 0) AS matched_partial_rows,
    COALESCE(scalar.matched_source_chunks, 0) AS matched_source_chunks,
    COALESCE(metadata.partial_metadata_mismatch_rows, 0)
      AS partial_metadata_mismatch_rows,
    (
      sample.successful_transaction_count_24h
        != COALESCE(scalar.recomputed_transaction_count_24h, 0)
      OR sample.first_activity_timestamp_24h
        IS DISTINCT FROM scalar.recomputed_first_activity_timestamp_24h
      OR sample.successful_transaction_count_7d
        != COALESCE(scalar.recomputed_transaction_count_7d, 0)
      OR sample.active_utc_day_count_7d
        != COALESCE(dates.recomputed_active_utc_day_count_7d, 0)
      OR sample.distinct_target_count_7d
        != COALESCE(targets.recomputed_distinct_target_count_7d, 0)
      OR sample.first_activity_timestamp_7d
        IS DISTINCT FROM scalar.recomputed_first_activity_timestamp_7d
      OR COALESCE(metadata.partial_metadata_mismatch_rows, 0) != 0
    ) AS reconciliation_mismatch,
    CONCAT(
      'https://arbiscan.io/tx/',
      sample.claim_transaction_hash
    ) AS claim_arbiscan_url
  FROM
    sampled AS sample
  LEFT JOIN
    partial_scalar_controls AS scalar
    USING (claim_transaction_hash, claim_log_index)
  LEFT JOIN
    partial_metadata_controls AS metadata
    USING (claim_transaction_hash, claim_log_index)
  LEFT JOIN
    partial_date_controls AS dates
    USING (claim_transaction_hash, claim_log_index)
  LEFT JOIN
    partial_target_controls AS targets
    USING (claim_transaction_hash, claim_log_index)
)

SELECT
  *
FROM
  reconciled
ORDER BY
  sample_stratum;

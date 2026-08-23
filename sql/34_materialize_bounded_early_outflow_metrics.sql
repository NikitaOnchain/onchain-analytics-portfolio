-- Aggregate the validated bounded early-outflow events for corrected chunk 21
-- to one row per claim recipient.
-- Always dry-run before execution.
--
-- Analytical meaning:
--   Metrics describe positive non-self ARB early outflow. They do not identify
--   sales. `claim_linked_outflow_*` is capped at the claim amount and remains a
--   proxy because ARB is fungible.
--
-- Output grain:
--   One row per validated claim event and unique claim recipient.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21
--     One validated claim event and unique recipient per row.
--   YOUR_DATASET_ID.early_outflow_events_chunk_21
--     One validated positive non-self outflow event per row within seven days.
--
-- Join keys and expected cardinality:
--   LEFT JOIN on the exact claim event key
--   (claim_transaction_hash, claim_log_index), expected one-to-one after the
--   event table is first aggregated to that claim grain. The LEFT JOIN retains
--   claimants with no qualifying outflow as zero-outflow rows.
--
-- Filters and time boundaries:
--   The event table already enforces block-aware post-claim order and the
--   elapsed seven-day half-open window. The 24-hour metrics apply the additional
--   half-open cutoff outflow_timestamp < claim_timestamp + 24 hours.
--
-- Row-multiplication risk:
--   Outflow events intentionally multiply claim rows inside `per_claim`, then
--   collapse to the exact claim event key before the final LEFT JOIN.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.early_outflow_metrics_chunk_21`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary recipient-level bounded ARB early-outflow metrics for corrected claim chunk 21.'
)
AS
WITH claims AS (
  SELECT
    chunk_number,
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    recipient AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_21`
),

per_claim AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNTIF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS positive_outflow_event_count_24h,
    COUNT(DISTINCT IF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      outflow_transaction_hash,
      NULL
    )) AS positive_outflow_transaction_count_24h,
    SUM(IF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      outflow_amount_raw,
      CAST(0 AS BIGNUMERIC)
    )) AS gross_positive_outflow_raw_24h,
    MIN(IF(
      outflow_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR),
      outflow_timestamp,
      NULL
    )) AS first_positive_outflow_timestamp_24h,
    COUNT(*) AS positive_outflow_event_count_7d,
    COUNT(DISTINCT outflow_transaction_hash)
      AS positive_outflow_transaction_count_7d,
    SUM(outflow_amount_raw) AS gross_positive_outflow_raw_7d,
    MIN(outflow_timestamp) AS first_positive_outflow_timestamp_7d
  FROM
    `YOUR_DATASET_ID.early_outflow_events_chunk_21`
  GROUP BY
    claim_transaction_hash,
    claim_log_index
)

SELECT
  claim.chunk_number,
  claim.claim_timestamp,
  claim.claim_block_number,
  claim.claim_transaction_hash,
  claim.claim_log_index,
  claim.claim_recipient,
  claim.claim_amount_raw,
  COALESCE(metric.positive_outflow_event_count_24h, 0)
    AS positive_outflow_event_count_24h,
  COALESCE(metric.positive_outflow_transaction_count_24h, 0)
    AS positive_outflow_transaction_count_24h,
  COALESCE(
    metric.gross_positive_outflow_raw_24h,
    CAST(0 AS BIGNUMERIC)
  ) AS gross_positive_outflow_raw_24h,
  LEAST(
    claim.claim_amount_raw,
    COALESCE(
      metric.gross_positive_outflow_raw_24h,
      CAST(0 AS BIGNUMERIC)
    )
  ) AS claim_linked_outflow_raw_24h,
  SAFE_DIVIDE(
    LEAST(
      claim.claim_amount_raw,
      COALESCE(
        metric.gross_positive_outflow_raw_24h,
        CAST(0 AS BIGNUMERIC)
      )
    ),
    claim.claim_amount_raw
  ) AS claim_linked_outflow_ratio_24h,
  metric.first_positive_outflow_timestamp_24h,
  TIMESTAMP_DIFF(
    metric.first_positive_outflow_timestamp_24h,
    claim.claim_timestamp,
    SECOND
  ) AS seconds_to_first_positive_outflow_24h,
  COALESCE(metric.positive_outflow_event_count_7d, 0)
    AS positive_outflow_event_count_7d,
  COALESCE(metric.positive_outflow_transaction_count_7d, 0)
    AS positive_outflow_transaction_count_7d,
  COALESCE(
    metric.gross_positive_outflow_raw_7d,
    CAST(0 AS BIGNUMERIC)
  ) AS gross_positive_outflow_raw_7d,
  LEAST(
    claim.claim_amount_raw,
    COALESCE(
      metric.gross_positive_outflow_raw_7d,
      CAST(0 AS BIGNUMERIC)
    )
  ) AS claim_linked_outflow_raw_7d,
  SAFE_DIVIDE(
    LEAST(
      claim.claim_amount_raw,
      COALESCE(
        metric.gross_positive_outflow_raw_7d,
        CAST(0 AS BIGNUMERIC)
      )
    ),
    claim.claim_amount_raw
  ) AS claim_linked_outflow_ratio_7d,
  metric.first_positive_outflow_timestamp_7d,
  TIMESTAMP_DIFF(
    metric.first_positive_outflow_timestamp_7d,
    claim.claim_timestamp,
    SECOND
  ) AS seconds_to_first_positive_outflow_7d
FROM
  claims AS claim
LEFT JOIN
  per_claim AS metric
  USING (claim_transaction_hash, claim_log_index);

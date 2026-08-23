-- Reconcile a deterministic five-stratum wallet sample to underlying events.
-- Always dry-run before execution.
--
-- Output grain:
--   One QA summary row containing a bounded JSON representation of five sampled
--   claims and their stored events.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.early_outflow_metrics_full_cohort
--     One validated claim recipient per row.
--   YOUR_DATASET_ID.early_outflow_events_full_cohort
--     One validated positive non-self outflow event per row.
--
-- Join keys and expected cardinality:
--   Correlated event lookup on exact claim event key, expected one-to-many.
--   Aggregates are calculated independently for each selected claimant.
--
-- Filters and time boundaries:
--   The same deterministic five strata as SQL 46 are sampled. The 24-hour
--   reconciliation uses the elapsed half-open cutoff stored by the metrics.
--
-- Row-multiplication risk:
--   Correlated subqueries aggregate events before the one-row summary, so no
--   claim-metric row is multiplied. Mismatch counts expose any disagreement.

WITH sample_candidates AS (
  SELECT '01_zero_outflow' AS sample_type, metric.*
  FROM `YOUR_DATASET_ID.early_outflow_metrics_full_cohort` AS metric
  WHERE positive_outflow_event_count_7d = 0

  UNION ALL

  SELECT '02_after_24h_only' AS sample_type, metric.*
  FROM `YOUR_DATASET_ID.early_outflow_metrics_full_cohort` AS metric
  WHERE positive_outflow_event_count_24h = 0
    AND positive_outflow_event_count_7d > 0

  UNION ALL

  SELECT '03_single_event_within_24h' AS sample_type, metric.*
  FROM `YOUR_DATASET_ID.early_outflow_metrics_full_cohort` AS metric
  WHERE positive_outflow_event_count_24h > 0
    AND positive_outflow_event_count_7d = 1
    AND gross_positive_outflow_raw_7d <= claim_amount_raw

  UNION ALL

  SELECT '04_multiple_events_within_7d' AS sample_type, metric.*
  FROM `YOUR_DATASET_ID.early_outflow_metrics_full_cohort` AS metric
  WHERE positive_outflow_event_count_24h > 0
    AND positive_outflow_event_count_7d > 1
    AND gross_positive_outflow_raw_7d <= claim_amount_raw

  UNION ALL

  SELECT '05_gross_above_claim' AS sample_type, metric.*
  FROM `YOUR_DATASET_ID.early_outflow_metrics_full_cohort` AS metric
  WHERE positive_outflow_event_count_24h > 0
    AND gross_positive_outflow_raw_7d > claim_amount_raw
),

selected_claimants AS (
  SELECT * EXCEPT (sample_rank)
  FROM (
    SELECT
      sample_candidates.*,
      ROW_NUMBER() OVER (
        PARTITION BY sample_type
        ORDER BY claim_timestamp, claim_recipient
      ) AS sample_rank
    FROM sample_candidates
  )
  WHERE sample_rank = 1
),

sample_details AS (
  SELECT
    sample.sample_type,
    sample.claim_recipient,
    sample.claim_timestamp,
    sample.claim_transaction_hash,
    sample.claim_log_index,
    sample.claim_amount_raw,
    sample.positive_outflow_event_count_24h,
    sample.gross_positive_outflow_raw_24h,
    sample.positive_outflow_event_count_7d,
    sample.gross_positive_outflow_raw_7d,
    COUNTIF(
      event.outflow_transaction_hash IS NOT NULL
      AND event.outflow_timestamp < TIMESTAMP_ADD(
        sample.claim_timestamp,
        INTERVAL 24 HOUR
      )
    ) AS stored_event_count_24h,
    COALESCE(SUM(IF(
      event.outflow_timestamp < TIMESTAMP_ADD(
        sample.claim_timestamp,
        INTERVAL 24 HOUR
      ),
      event.outflow_amount_raw,
      CAST(0 AS BIGNUMERIC)
    )), CAST(0 AS BIGNUMERIC)) AS stored_gross_raw_24h,
    COUNT(event.outflow_transaction_hash) AS stored_event_count_7d,
    COALESCE(
      SUM(event.outflow_amount_raw),
      CAST(0 AS BIGNUMERIC)
    ) AS stored_gross_raw_7d,
    ARRAY_AGG(
      IF(
        event.outflow_transaction_hash IS NULL,
        NULL,
        STRUCT(
          event.outflow_timestamp,
          event.outflow_block_number,
          event.outflow_transaction_hash,
          event.outflow_log_index,
          event.destination,
          event.outflow_amount_raw
        )
      )
      IGNORE NULLS
      ORDER BY event.outflow_block_number, event.outflow_log_index
    ) AS events
  FROM
    selected_claimants AS sample
  LEFT JOIN
    `YOUR_DATASET_ID.early_outflow_events_full_cohort` AS event
    USING (claim_transaction_hash, claim_log_index)
  GROUP BY
    sample.sample_type,
    sample.claim_recipient,
    sample.claim_timestamp,
    sample.claim_transaction_hash,
    sample.claim_log_index,
    sample.claim_amount_raw,
    sample.positive_outflow_event_count_24h,
    sample.gross_positive_outflow_raw_24h,
    sample.positive_outflow_event_count_7d,
    sample.gross_positive_outflow_raw_7d
)

SELECT
  COUNT(*) AS selected_claimants,
  COUNT(DISTINCT sample_type) AS selected_strata,
  COUNTIF(
    positive_outflow_event_count_24h != stored_event_count_24h
    OR gross_positive_outflow_raw_24h != stored_gross_raw_24h
    OR positive_outflow_event_count_7d != stored_event_count_7d
    OR gross_positive_outflow_raw_7d != stored_gross_raw_7d
  ) AS sample_metric_reconciliation_mismatch_rows,
  TO_JSON_STRING(ARRAY_AGG(
    STRUCT(
      sample_type,
      claim_recipient,
      claim_timestamp,
      claim_transaction_hash,
      claim_log_index,
      claim_amount_raw,
      positive_outflow_event_count_24h,
      gross_positive_outflow_raw_24h,
      positive_outflow_event_count_7d,
      gross_positive_outflow_raw_7d,
      events
    )
    ORDER BY sample_type
  )) AS sample_json
FROM
  sample_details;

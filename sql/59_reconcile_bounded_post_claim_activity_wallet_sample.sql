-- Reconcile the deterministic five-stratum post-claim activity wallet sample
-- from claim-grain metrics back to underlying transaction events.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One JSON string containing one reconciliation record per sampled claim.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21
--     One claim recipient per row.
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--     One successful post-claim transaction per row.
--
-- Join keys and expected cardinality:
--   Exact claim event key (claim_transaction_hash, claim_log_index), expected
--   one-to-one after event controls are aggregated to claim grain.
--
-- Filters and time boundaries:
--   The same deterministic strata as SQL 58 are used. Stored and recomputed
--   event controls use half-open elapsed 24-hour and seven-day windows.
--
-- Row-multiplication risk:
--   Event rows and a first-ten detail array are aggregated before the LEFT
--   JOIN, preventing event-grain multiplication of sampled claims.

WITH labeled AS (
  SELECT
    CASE
      WHEN claim_was_delegated THEN 'Delegated claim'
      WHEN successful_transaction_count_7d = 0 THEN 'No activity within 7d'
      WHEN successful_transaction_count_24h = 0 THEN 'Activity after 24h only'
      WHEN successful_transaction_count_7d = 1 THEN 'One transaction within 7d'
      ELSE 'Multiple transactions within 7d'
    END AS sample_stratum,
    *
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21`
),

sampled AS (
  SELECT
    * EXCEPT (sample_rank)
  FROM (
    SELECT
      *,
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

event_controls AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNTIF(
      activity_timestamp < TIMESTAMP_ADD(claim_timestamp, INTERVAL 24 HOUR)
    ) AS recomputed_transaction_count_24h,
    COUNT(*) AS recomputed_transaction_count_7d,
    COUNT(DISTINCT DATE(activity_timestamp, 'UTC'))
      AS recomputed_active_utc_day_count_7d,
    COUNT(DISTINCT activity_to_address)
      AS recomputed_distinct_target_count_7d,
    MIN(activity_timestamp) AS recomputed_first_activity_timestamp_7d,
    ARRAY_AGG(STRUCT(
      activity_timestamp,
      activity_block_number,
      activity_transaction_hash,
      activity_transaction_index,
      activity_to_address,
      created_contract_address,
      activity_gas_used
    ) ORDER BY activity_block_number, activity_transaction_index LIMIT 10)
      AS first_ten_activity_transactions
  FROM
    `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

reconciled AS (
  SELECT
    sample.sample_stratum,
    sample.claim_timestamp,
    sample.claim_transaction_hash,
    sample.claim_log_index,
    sample.claim_recipient,
    sample.claim_transaction_sender,
    sample.claim_was_delegated,
    sample.successful_transaction_count_24h,
    COALESCE(event.recomputed_transaction_count_24h, 0)
      AS recomputed_transaction_count_24h,
    sample.successful_transaction_count_7d,
    COALESCE(event.recomputed_transaction_count_7d, 0)
      AS recomputed_transaction_count_7d,
    sample.active_utc_day_count_7d,
    COALESCE(event.recomputed_active_utc_day_count_7d, 0)
      AS recomputed_active_utc_day_count_7d,
    sample.distinct_target_count_7d,
    COALESCE(event.recomputed_distinct_target_count_7d, 0)
      AS recomputed_distinct_target_count_7d,
    sample.first_activity_timestamp_7d,
    event.recomputed_first_activity_timestamp_7d,
    (
      sample.successful_transaction_count_24h
        != COALESCE(event.recomputed_transaction_count_24h, 0)
      OR sample.successful_transaction_count_7d
        != COALESCE(event.recomputed_transaction_count_7d, 0)
      OR sample.active_utc_day_count_7d
        != COALESCE(event.recomputed_active_utc_day_count_7d, 0)
      OR sample.distinct_target_count_7d
        != COALESCE(event.recomputed_distinct_target_count_7d, 0)
      OR sample.first_activity_timestamp_7d
        IS DISTINCT FROM event.recomputed_first_activity_timestamp_7d
    ) AS reconciliation_mismatch,
    event.first_ten_activity_transactions
  FROM
    sampled AS sample
  LEFT JOIN
    event_controls AS event
    USING (claim_transaction_hash, claim_log_index)
)

SELECT
  TO_JSON_STRING(ARRAY_AGG(reconciled ORDER BY sample_stratum))
    AS reconciliation_json
FROM
  reconciled;

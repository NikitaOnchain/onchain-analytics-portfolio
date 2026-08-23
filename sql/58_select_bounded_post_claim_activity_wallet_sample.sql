-- Select one deterministic claim recipient from each bounded post-claim
-- activity QA stratum.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   One JSON string containing one claim-grain row per selected stratum.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21
--   One validated claim recipient per row.
--
-- Join keys and expected cardinality:
--   No JOIN is used.
--
-- Filters and time boundaries:
--   Metrics already use half-open elapsed 24-hour and seven-day windows. Five
--   mutually exclusive strata cover delegated claim, zero activity, activity
--   only after 24 hours, one transaction, and multiple transactions.
--
-- Row-multiplication risk:
--   None. ROW_NUMBER selects one deterministic recipient per stratum.

WITH labeled AS (
  SELECT
    CASE
      WHEN claim_was_delegated THEN 'Delegated claim'
      WHEN successful_transaction_count_7d = 0 THEN 'No activity within 7d'
      WHEN successful_transaction_count_24h = 0 THEN 'Activity after 24h only'
      WHEN successful_transaction_count_7d = 1 THEN 'One transaction within 7d'
      ELSE 'Multiple transactions within 7d'
    END AS sample_stratum,
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    claim_recipient,
    claim_transaction_sender,
    claim_amount_raw,
    successful_transaction_count_24h,
    successful_transaction_count_7d,
    active_utc_day_count_7d,
    distinct_target_count_7d,
    first_activity_timestamp_7d,
    seconds_to_first_activity_7d
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21`
),

ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY sample_stratum
      ORDER BY claim_transaction_hash, claim_log_index
    ) AS sample_rank
  FROM
    labeled
)

SELECT
  TO_JSON_STRING(ARRAY_AGG(STRUCT(
    sample_stratum,
    claim_timestamp,
    claim_transaction_hash,
    claim_log_index,
    claim_recipient,
    claim_transaction_sender,
    claim_amount_raw,
    successful_transaction_count_24h,
    successful_transaction_count_7d,
    active_utc_day_count_7d,
    distinct_target_count_7d,
    first_activity_timestamp_7d,
    seconds_to_first_activity_7d
  ) ORDER BY sample_stratum)) AS sample_json
FROM
  ranked
WHERE
  sample_rank = 1;


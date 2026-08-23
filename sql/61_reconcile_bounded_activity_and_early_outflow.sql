-- Measure transaction- and recipient-level overlap between bounded post-claim
-- transaction activity and positive ARB early outflow for corrected chunk 21.
-- Always dry-run the exact statement before execution.
--
-- Analytical meaning:
--   Overlap means a successful recipient-initiated top-level transaction also
--   contains at least one qualifying positive non-self ARB outflow event. It
--   does not classify the transaction as a sale or identify protocol intent.
--
-- Output grain:
--   One aggregate overlap and QA summary row.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.post_claim_activity_events_chunk_21
--     One successful post-claim top-level transaction per row.
--   YOUR_DATASET_ID.early_outflow_events_chunk_21
--     One qualifying positive non-self ARB Transfer event per row.
--   YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21
--     One unique claim recipient per row.
--   YOUR_DATASET_ID.early_outflow_metrics_chunk_21
--     One unique claim recipient per row.
--
-- Join keys and expected cardinality:
--   Transaction overlap uses (claim_recipient, transaction_hash), expected
--   one-to-one after outflow events are collapsed to transaction grain.
--   Claim-grain overlap uses exact claim event key
--   (claim_transaction_hash, claim_log_index), expected one-to-one.
--
-- Filters and time boundaries:
--   Both event layers already enforce strict ordering and the same half-open
--   seven-elapsed-day window after exact claim.
--
-- Row-multiplication risk:
--   Multiple ARB Transfer events can occur in one top-level transaction, so
--   outflow events are grouped before the transaction-level FULL OUTER JOIN.

WITH activity_transactions AS (
  SELECT
    claim_recipient,
    activity_transaction_hash
  FROM
    `YOUR_DATASET_ID.post_claim_activity_events_chunk_21`
),

outflow_transactions AS (
  SELECT
    claim_recipient,
    outflow_transaction_hash,
    COUNT(*) AS outflow_event_count
  FROM
    `YOUR_DATASET_ID.early_outflow_events_chunk_21`
  GROUP BY
    claim_recipient,
    outflow_transaction_hash
),

transaction_overlap AS (
  SELECT
    activity.activity_transaction_hash,
    outflow.outflow_transaction_hash,
    activity.activity_transaction_hash IS NOT NULL AS has_activity_transaction,
    outflow.outflow_transaction_hash IS NOT NULL AS has_outflow_transaction,
    COALESCE(outflow.outflow_event_count, 0) AS outflow_event_count
  FROM
    activity_transactions AS activity
  FULL OUTER JOIN
    outflow_transactions AS outflow
    ON activity.claim_recipient = outflow.claim_recipient
    AND activity.activity_transaction_hash = outflow.outflow_transaction_hash
),

recipient_overlap AS (
  SELECT
    activity.claim_recipient,
    activity.successful_transaction_count_7d > 0 AS has_activity_7d,
    outflow.positive_outflow_transaction_count_7d > 0 AS has_outflow_7d
  FROM
    `YOUR_DATASET_ID.post_claim_activity_metrics_chunk_21` AS activity
  INNER JOIN
    `YOUR_DATASET_ID.early_outflow_metrics_chunk_21` AS outflow
    USING (claim_transaction_hash, claim_log_index)
),

transaction_summary AS (
  SELECT
    COUNTIF(has_activity_transaction)
      AS activity_claimant_transaction_pairs_7d,
    COUNTIF(has_outflow_transaction)
      AS outflow_claimant_transaction_pairs_7d,
    COUNTIF(has_activity_transaction AND has_outflow_transaction)
      AS overlapping_claimant_transaction_pairs_7d,
    COUNTIF(has_activity_transaction AND NOT has_outflow_transaction)
      AS activity_only_claimant_transaction_pairs_7d,
    COUNTIF(NOT has_activity_transaction AND has_outflow_transaction)
      AS outflow_only_claimant_transaction_pairs_7d,
    COUNT(DISTINCT IF(
      has_activity_transaction,
      activity_transaction_hash,
      NULL
    )) AS distinct_activity_transaction_hashes_7d,
    COUNT(DISTINCT IF(
      has_outflow_transaction,
      outflow_transaction_hash,
      NULL
    )) AS distinct_outflow_transaction_hashes_7d,
    COUNT(DISTINCT IF(
      has_activity_transaction AND has_outflow_transaction,
      activity_transaction_hash,
      NULL
    )) AS distinct_overlapping_transaction_hashes_7d,
    SUM(IF(
      has_activity_transaction AND has_outflow_transaction,
      outflow_event_count,
      0
    )) AS outflow_events_in_overlapping_transactions
  FROM
    transaction_overlap
),

recipient_summary AS (
  SELECT
    COUNT(*) AS recipient_rows,
    COUNT(DISTINCT claim_recipient) AS distinct_recipients,
    COUNTIF(has_activity_7d) AS activity_recipients_7d,
    COUNTIF(has_outflow_7d) AS outflow_recipients_7d,
    COUNTIF(has_activity_7d AND has_outflow_7d) AS both_recipients_7d,
    COUNTIF(has_activity_7d AND NOT has_outflow_7d)
      AS activity_only_recipients_7d,
    COUNTIF(NOT has_activity_7d AND has_outflow_7d)
      AS outflow_only_recipients_7d,
    COUNTIF(NOT has_activity_7d AND NOT has_outflow_7d)
      AS neither_recipients_7d
  FROM
    recipient_overlap
)

SELECT
  transaction_summary.*,
  recipient_summary.*
FROM
  transaction_summary
CROSS JOIN
  recipient_summary;

-- Select a deterministic five-event sample from the late claim interval.
--
-- Output grain:
--   One row per sampled corrected claim-transfer event.
--
-- Source table and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_chunk_21
--   One row per decoded candidate claim Transfer event after excluding the
--   verified post-claim sweep transaction.
--
-- Candidate event key:
--   (transaction_hash, log_index).
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Sampling rule and filters:
--   Rows are ordered deterministically by timestamp, transaction hash, and log
--   index. The first two, middle row, and last two positions are returned.
--
-- Row-multiplication risk:
--   None from JOINs. The five selected positions are distinct because this
--   interval contains more than five rows.

WITH ordered_late_claims AS (
  SELECT
    block_timestamp,
    transaction_hash,
    log_index,
    recipient,
    amount_raw,
    ROW_NUMBER() OVER (
      ORDER BY block_timestamp, transaction_hash, log_index
    ) AS sample_position,
    COUNT(*) OVER () AS interval_event_rows
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_chunk_21`
)

SELECT
  CASE
    WHEN sample_position = 1 THEN 'first'
    WHEN sample_position = 2 THEN 'second'
    WHEN sample_position = DIV(interval_event_rows + 1, 2) THEN 'middle'
    WHEN sample_position = interval_event_rows - 1 THEN 'penultimate'
    WHEN sample_position = interval_event_rows THEN 'last'
  END AS sample_label,
  sample_position,
  interval_event_rows,
  block_timestamp,
  transaction_hash,
  log_index AS transfer_log_index,
  recipient,
  amount_raw,
  SAFE_DIVIDE(
    amount_raw,
    CAST('1000000000000000000' AS BIGNUMERIC)
  ) AS amount_arb
FROM
  ordered_late_claims
WHERE
  sample_position IN (
    1,
    2,
    DIV(interval_event_rows + 1, 2),
    interval_event_rows - 1,
    interval_event_rows
  )
ORDER BY
  sample_position;

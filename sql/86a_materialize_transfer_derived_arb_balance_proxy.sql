-- Materialize claim-grain transfer-derived ARB balance proxies at 7d and 30d.
-- Always fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   One row per validated unique ARB claim recipient.
--
-- Source tables and source grain:
--   corrected_claim_transfers_enriched_chunk_01..21:
--     one validated claim event and unique recipient per row.
--   post_claim_transaction_order_batch_01_20, 21, 22, 23:
--     one compact claim-transaction order row per transaction hash.
--   retention_arb_claimant_transfer_legs:
--     one signed claimant endpoint role per
--     (transaction_hash, log_index, leg_role).
--
-- Join keys and expected cardinality:
--   Claims LEFT JOIN compact order profile many-to-one by
--   claim_transaction_hash, then
--   LEFT JOIN signed legs one-to-many by claim_recipient = claimant_address.
--   Claims are validated unique by recipient and order rows are validated
--   unique by transaction hash. The order profile exposes any unexpected raw
--   duplicate without multiplying signed legs. The final GROUP BY restores
--   claim grain.
--
-- Filters and time boundaries:
--   Claim suffixes are limited to final numeric chunks 01 through 21. Compact
--   order suffixes are frozen to 01_20, 21, 22, and 23. Pre-claim legs are
--   strictly before the exact claim tuple
--   (block_number, transaction_index, log_index). The 7d and 30d balances
--   include every leg with block_timestamp strictly before claim_timestamp +
--   7 or 30 elapsed days. Therefore the exact claim Transfer is excluded from
--   pre-claim balance and included in both post-claim cutoff balances.
--
-- Row-multiplication risk:
--   The recipient-to-leg JOIN intentionally expands each claim to its complete
--   signed ARB Transfer history. Conditional aggregation collapses it back to
--   one row per recipient. The compact order profile prevents an unexpected
--   duplicate order row from multiplying legs while retaining order_match_rows
--   for the separate claim-grain QA query.
--
-- Interpretation:
--   Historical token-balance snapshots are unavailable in the source dataset.
--   These are transfer-derived ARB balance proxies reconstructed from the
--   validated first mint onward. The capped pre-claim-adjusted measure is also
--   a proxy because fungible ARB units cannot be attributed to the airdrop.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.retention_transfer_derived_arb_balance_proxy`
CLUSTER BY
  claim_recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary claim-grain transfer-derived ARB balance proxies at 7 and 30 elapsed days.'
)
AS
WITH claims AS (
  SELECT
    chunk_number AS claim_chunk_number,
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    LOWER(recipient) AS claim_recipient,
    amount_raw AS claim_amount_raw,
    source_match_rows AS claim_source_match_rows
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 21
),

order_keys AS (
  SELECT
    claim_receipt_timestamp,
    claim_receipt_block_number,
    claim_transaction_hash,
    claim_transaction_index,
    claim_receipt_match_rows,
    claim_block_match_rows
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*`
  WHERE
    _TABLE_SUFFIX IN ('01_20', '21', '22', '23')
),

order_key_profile AS (
  SELECT
    claim_transaction_hash,
    ANY_VALUE(claim_receipt_timestamp) AS claim_receipt_timestamp,
    ANY_VALUE(claim_receipt_block_number) AS claim_receipt_block_number,
    ANY_VALUE(claim_transaction_index) AS claim_transaction_index,
    ANY_VALUE(claim_receipt_match_rows) AS claim_receipt_match_rows,
    ANY_VALUE(claim_block_match_rows) AS claim_block_match_rows,
    COUNT(*) AS order_match_rows
  FROM
    order_keys
  GROUP BY
    claim_transaction_hash
),

claims_with_order AS (
  SELECT
    claim.*,
    claim_order.claim_receipt_timestamp,
    claim_order.claim_receipt_block_number,
    claim_order.claim_transaction_index,
    claim_order.claim_receipt_match_rows,
    claim_order.claim_block_match_rows,
    claim_order.order_match_rows
  FROM
    claims AS claim
  LEFT JOIN
    order_key_profile AS claim_order
    USING (claim_transaction_hash)
),

claim_balance_components AS (
  SELECT
    claim.claim_chunk_number,
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_recipient,
    claim.claim_amount_raw,
    claim.claim_source_match_rows,
    claim.claim_receipt_timestamp,
    claim.claim_receipt_block_number,
    claim.claim_receipt_match_rows,
    claim.claim_block_match_rows,
    claim.order_match_rows,
    COUNT(leg.transaction_hash) AS all_history_leg_rows,
    COUNTIF(
      leg.block_number < claim.claim_block_number
      OR (
        leg.block_number = claim.claim_block_number
        AND leg.transaction_index < claim.claim_transaction_index
      )
      OR (
        leg.block_number = claim.claim_block_number
        AND leg.transaction_index = claim.claim_transaction_index
        AND leg.log_index < claim.claim_log_index
      )
    ) AS pre_claim_leg_rows,
    COUNTIF(
      leg.block_timestamp < TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 7 DAY)
    ) AS leg_rows_before_7d_cutoff,
    COUNTIF(
      leg.block_timestamp < TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 30 DAY)
    ) AS leg_rows_before_30d_cutoff,
    COALESCE(SUM(
      IF(
        leg.block_number < claim.claim_block_number
        OR (
          leg.block_number = claim.claim_block_number
          AND leg.transaction_index < claim.claim_transaction_index
        )
        OR (
          leg.block_number = claim.claim_block_number
          AND leg.transaction_index = claim.claim_transaction_index
          AND leg.log_index < claim.claim_log_index
        ),
        leg.signed_amount_raw,
        0
      )
    ), 0) AS pre_claim_arb_balance_raw,
    COALESCE(SUM(
      IF(
        leg.block_timestamp < TIMESTAMP_ADD(
          claim.claim_timestamp, INTERVAL 7 DAY
        ),
        leg.signed_amount_raw,
        0
      )
    ), 0) AS transfer_derived_arb_balance_raw_7d,
    COALESCE(SUM(
      IF(
        leg.block_timestamp < TIMESTAMP_ADD(
          claim.claim_timestamp, INTERVAL 30 DAY
        ),
        leg.signed_amount_raw,
        0
      )
    ), 0) AS transfer_derived_arb_balance_raw_30d,
    COUNTIF(
      leg.transaction_hash = claim.claim_transaction_hash
      AND leg.log_index = claim.claim_log_index
      AND leg.leg_role = 'destination'
    ) AS exact_claim_destination_leg_rows,
    COALESCE(SUM(
      IF(
        leg.transaction_hash = claim.claim_transaction_hash
        AND leg.log_index = claim.claim_log_index
        AND leg.leg_role = 'destination',
        leg.signed_amount_raw,
        0
      )
    ), 0) AS exact_claim_destination_signed_amount_raw
  FROM
    claims_with_order AS claim
  LEFT JOIN
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
    ON claim.claim_recipient = leg.claimant_address
  GROUP BY
    claim.claim_chunk_number,
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_recipient,
    claim.claim_amount_raw,
    claim.claim_source_match_rows,
    claim.claim_receipt_timestamp,
    claim.claim_receipt_block_number,
    claim.claim_receipt_match_rows,
    claim.claim_block_match_rows,
    claim.order_match_rows
),

balance_measures AS (
  SELECT
    *,
    LEAST(
      claim_amount_raw,
      GREATEST(
        CAST(0 AS BIGNUMERIC),
        transfer_derived_arb_balance_raw_7d - pre_claim_arb_balance_raw
      )
    ) AS pre_claim_adjusted_retained_claim_proxy_raw_7d,
    LEAST(
      claim_amount_raw,
      GREATEST(
        CAST(0 AS BIGNUMERIC),
        transfer_derived_arb_balance_raw_30d - pre_claim_arb_balance_raw
      )
    ) AS pre_claim_adjusted_retained_claim_proxy_raw_30d
  FROM
    claim_balance_components
)

SELECT
  *,
  SAFE_DIVIDE(
    transfer_derived_arb_balance_raw_7d,
    claim_amount_raw
  ) AS total_balance_to_claim_ratio_7d,
  SAFE_DIVIDE(
    transfer_derived_arb_balance_raw_30d,
    claim_amount_raw
  ) AS total_balance_to_claim_ratio_30d,
  SAFE_DIVIDE(
    pre_claim_adjusted_retained_claim_proxy_raw_7d,
    claim_amount_raw
  ) AS pre_claim_adjusted_retained_claim_proxy_ratio_7d,
  SAFE_DIVIDE(
    pre_claim_adjusted_retained_claim_proxy_raw_30d,
    claim_amount_raw
  ) AS pre_claim_adjusted_retained_claim_proxy_ratio_30d,
  CASE
    WHEN transfer_derived_arb_balance_raw_7d < 0
      THEN 'invalid: negative balance'
    WHEN transfer_derived_arb_balance_raw_7d = 0 THEN '0%'
    WHEN transfer_derived_arb_balance_raw_7d < claim_amount_raw / 4
      THEN '<25%'
    WHEN transfer_derived_arb_balance_raw_7d < claim_amount_raw * 3 / 4
      THEN '25-75%'
    WHEN transfer_derived_arb_balance_raw_7d <= claim_amount_raw
      THEN '75-100%'
    ELSE '>100%'
  END AS total_balance_to_claim_bucket_7d,
  CASE
    WHEN transfer_derived_arb_balance_raw_30d < 0
      THEN 'invalid: negative balance'
    WHEN transfer_derived_arb_balance_raw_30d = 0 THEN '0%'
    WHEN transfer_derived_arb_balance_raw_30d < claim_amount_raw / 4
      THEN '<25%'
    WHEN transfer_derived_arb_balance_raw_30d < claim_amount_raw * 3 / 4
      THEN '25-75%'
    WHEN transfer_derived_arb_balance_raw_30d <= claim_amount_raw
      THEN '75-100%'
    ELSE '>100%'
  END AS total_balance_to_claim_bucket_30d
FROM
  balance_measures;

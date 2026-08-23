-- Select a deterministic bounded wallet sample from the validated signed-leg
-- layer and expose exact event order around each claim.
-- Always fresh-dry-run this exact read-only statement before execution.
--
-- Output grain:
--   One row per selected claim recipient; exactly five rows unless category
--   candidates collapse to fewer than five distinct recipients.
--
-- Source tables and source grain:
--   retention_arb_claimant_transfer_legs: one claimant endpoint role per event.
--   corrected_claim_transfers_enriched_chunk_01..21: one claim and recipient.
--   post_claim_transaction_order_batch_*: one claim transaction per hash.
--
-- Join keys and expected cardinality:
--   Claims join compact order many-to-one by transaction hash and legs
--   one-to-many by recipient. The claim recipient is validated unique, so the
--   wallet profile remains one row per recipient.
--
-- Filters and time boundaries:
--   Final claim chunks 01..21 and frozen compact order batches only. The sample
--   arrays include up to five latest pre-claim legs, the exact claim-event leg,
--   and up to five earliest strictly post-claim legs inside 7 elapsed days.
--
-- Row-multiplication risk:
--   Candidate categories can nominate the same wallet. ROW_NUMBER deduplicates
--   by address before the final deterministic five-wallet limit.

WITH claims AS (
  SELECT
    block_timestamp AS claim_timestamp,
    block_number AS claim_block_number,
    transaction_hash AS claim_transaction_hash,
    log_index AS claim_log_index,
    LOWER(recipient) AS claim_recipient,
    amount_raw AS claim_amount_raw
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 21
),

order_keys AS (
  SELECT
    claim_transaction_hash,
    claim_transaction_index
  FROM
    `YOUR_DATASET_ID.post_claim_transaction_order_batch_*`
  WHERE
    _TABLE_SUFFIX IN ('01_20', '21', '22', '23')
),

claims_with_order AS (
  SELECT
    claim.*,
    claim_order.claim_transaction_index
  FROM
    claims AS claim
  INNER JOIN
    order_keys AS claim_order
    USING (claim_transaction_hash)
),

wallet_profile AS (
  SELECT
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_recipient,
    claim.claim_amount_raw,
    COUNT(leg.transaction_hash) AS leg_rows,
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
    COUNTIF(leg.is_self_transfer) AS self_transfer_leg_rows,
    SUM(IF(leg.is_self_transfer, leg.signed_amount_raw, 0))
      AS self_transfer_net_signed_amount_raw
  FROM
    claims_with_order AS claim
  LEFT JOIN
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
    ON claim.claim_recipient = leg.claimant_address
  GROUP BY
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_recipient,
    claim.claim_amount_raw
),

pre_claim_candidate AS (
  SELECT
    'pre_claim_legs' AS selection_category,
    1 AS category_priority,
    *
  FROM
    wallet_profile
  WHERE
    pre_claim_leg_rows > 0
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(claim_recipient), claim_recipient
  ) = 1
),

self_transfer_candidate AS (
  SELECT
    'self_transfer' AS selection_category,
    2 AS category_priority,
    *
  FROM
    wallet_profile
  WHERE
    self_transfer_leg_rows > 0
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(claim_recipient), claim_recipient
  ) = 1
),

high_leg_candidate AS (
  SELECT
    'highest_leg_count' AS selection_category,
    3 AS category_priority,
    *
  FROM
    wallet_profile
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY leg_rows DESC, claim_recipient
  ) = 1
),

hash_candidates AS (
  SELECT
    'hash_sample' AS selection_category,
    4 AS category_priority,
    *
  FROM
    wallet_profile
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(claim_recipient), claim_recipient
  ) <= 5
),

candidate_union AS (
  SELECT * FROM pre_claim_candidate
  UNION ALL
  SELECT * FROM self_transfer_candidate
  UNION ALL
  SELECT * FROM high_leg_candidate
  UNION ALL
  SELECT * FROM hash_candidates
),

deduplicated_candidates AS (
  SELECT * EXCEPT (address_rank)
  FROM (
    SELECT
      candidate_union.*,
      ROW_NUMBER() OVER (
        PARTITION BY claim_recipient
        ORDER BY category_priority, selection_category
      ) AS address_rank
    FROM
      candidate_union
  )
  WHERE
    address_rank = 1
),

selected AS (
  SELECT *
  FROM
    deduplicated_candidates
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY
      category_priority,
      FARM_FINGERPRINT(claim_recipient),
      claim_recipient
  ) <= 5
)

SELECT
  selected.selection_category,
  selected.claim_recipient,
  selected.claim_timestamp,
  selected.claim_block_number,
  selected.claim_transaction_hash,
  selected.claim_transaction_index,
  selected.claim_log_index,
  selected.claim_amount_raw,
  selected.leg_rows,
  selected.pre_claim_leg_rows,
  selected.self_transfer_leg_rows,
  selected.self_transfer_net_signed_amount_raw,
  ARRAY_AGG(
    IF(
      leg.block_number < selected.claim_block_number
      OR (
        leg.block_number = selected.claim_block_number
        AND leg.transaction_index < selected.claim_transaction_index
      )
      OR (
        leg.block_number = selected.claim_block_number
        AND leg.transaction_index = selected.claim_transaction_index
        AND leg.log_index < selected.claim_log_index
      ),
      STRUCT(
        leg.block_timestamp AS block_timestamp,
        leg.block_number AS block_number,
        leg.transaction_hash AS transaction_hash,
        leg.transaction_index AS transaction_index,
        leg.log_index AS log_index,
        leg.leg_role AS leg_role,
        leg.counterparty_address AS counterparty_address,
        leg.amount_raw AS amount_raw,
        leg.signed_amount_raw AS signed_amount_raw,
        leg.is_self_transfer AS is_self_transfer
      ),
      NULL
    ) IGNORE NULLS
    ORDER BY
      leg.block_number DESC,
      leg.transaction_index DESC,
      leg.log_index DESC,
      leg.leg_role DESC
    LIMIT 5
  ) AS latest_pre_claim_legs,
  ARRAY_AGG(
    IF(
      leg.transaction_hash = selected.claim_transaction_hash
      AND leg.log_index = selected.claim_log_index,
      STRUCT(
        leg.block_timestamp AS block_timestamp,
        leg.block_number AS block_number,
        leg.transaction_hash AS transaction_hash,
        leg.transaction_index AS transaction_index,
        leg.log_index AS log_index,
        leg.leg_role AS leg_role,
        leg.counterparty_address AS counterparty_address,
        leg.amount_raw AS amount_raw,
        leg.signed_amount_raw AS signed_amount_raw,
        leg.is_self_transfer AS is_self_transfer
      ),
      NULL
    ) IGNORE NULLS
    ORDER BY leg.leg_role
    LIMIT 2
  ) AS exact_claim_event_legs,
  ARRAY_AGG(
    IF(
      leg.block_timestamp < TIMESTAMP_ADD(
        selected.claim_timestamp, INTERVAL 7 DAY
      )
      AND (
        leg.block_number > selected.claim_block_number
        OR (
          leg.block_number = selected.claim_block_number
          AND leg.transaction_index > selected.claim_transaction_index
        )
        OR (
          leg.block_number = selected.claim_block_number
          AND leg.transaction_index = selected.claim_transaction_index
          AND leg.log_index > selected.claim_log_index
        )
      ),
      STRUCT(
        leg.block_timestamp AS block_timestamp,
        leg.block_number AS block_number,
        leg.transaction_hash AS transaction_hash,
        leg.transaction_index AS transaction_index,
        leg.log_index AS log_index,
        leg.leg_role AS leg_role,
        leg.counterparty_address AS counterparty_address,
        leg.amount_raw AS amount_raw,
        leg.signed_amount_raw AS signed_amount_raw,
        leg.is_self_transfer AS is_self_transfer
      ),
      NULL
    ) IGNORE NULLS
    ORDER BY
      leg.block_number,
      leg.transaction_index,
      leg.log_index,
      leg.leg_role
    LIMIT 5
  ) AS earliest_post_claim_legs_7d
FROM
  selected
LEFT JOIN
  `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
  ON selected.claim_recipient = leg.claimant_address
GROUP BY
  selected.selection_category,
  selected.category_priority,
  selected.claim_recipient,
  selected.claim_timestamp,
  selected.claim_block_number,
  selected.claim_transaction_hash,
  selected.claim_transaction_index,
  selected.claim_log_index,
  selected.claim_amount_raw,
  selected.leg_rows,
  selected.pre_claim_leg_rows,
  selected.self_transfer_leg_rows,
  selected.self_transfer_net_signed_amount_raw
ORDER BY
  selected.category_priority,
  selected.claim_recipient;

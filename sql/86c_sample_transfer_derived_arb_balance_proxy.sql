-- Recompute transfer-derived ARB balance proxies for a deterministic wallet
-- sample directly from validated signed legs.
-- Always fresh-dry-run this exact read-only statement before execution.
--
-- Output grain:
--   One row per deterministically selected claim recipient; target nine rows.
--
-- Source tables and source grain:
--   retention_transfer_derived_arb_balance_proxy:
--     one row per validated unique claim recipient.
--   retention_arb_claimant_transfer_legs:
--     one signed claimant endpoint role per
--     (transaction_hash, log_index, leg_role).
--
-- Join keys and expected cardinality:
--   Candidate discovery and recomputation join proxy to legs one-to-many by
--   claim_recipient = claimant_address. Candidate addresses are deduplicated
--   before the final JOIN, and GROUP BY restores one row per selected wallet.
--
-- Filters and time boundaries:
--   Pre-claim uses strict (block_number, transaction_index, log_index) order.
--   The 7d and 30d balances include legs strictly before the corresponding
--   elapsed-time cutoff. Event arrays are independently bounded to three rows
--   per boundary, while the exact claim array is bounded to two endpoint roles.
--
-- Row-multiplication risk:
--   Special candidates can overlap. ROW_NUMBER retains the highest-priority
--   category per address. Bucket candidates exclude special addresses, so the
--   expected selection is four special cases plus five 7d bucket cases.

WITH proxy AS (
  SELECT *
  FROM
    `YOUR_DATASET_ID.retention_transfer_derived_arb_balance_proxy`
),

pre_claim_candidate AS (
  SELECT
    'positive_pre_claim_balance' AS selection_category,
    1 AS category_priority,
    claim_recipient
  FROM
    proxy
  WHERE
    pre_claim_arb_balance_raw > 0
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(claim_recipient), claim_recipient
  ) = 1
),

self_transfer_candidate AS (
  SELECT
    'self_transfer' AS selection_category,
    2 AS category_priority,
    leg.claimant_address AS claim_recipient
  FROM
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
  WHERE
    leg.is_self_transfer
  GROUP BY
    leg.claimant_address
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(leg.claimant_address), leg.claimant_address
  ) = 1
),

highest_leg_candidate AS (
  SELECT
    'highest_leg_count' AS selection_category,
    3 AS category_priority,
    claim_recipient
  FROM
    proxy
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY all_history_leg_rows DESC, claim_recipient
  ) = 1
),

same_block_post_claim_candidate AS (
  SELECT
    'same_block_post_claim' AS selection_category,
    4 AS category_priority,
    claim.claim_recipient
  FROM
    proxy AS claim
  INNER JOIN
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
    ON claim.claim_recipient = leg.claimant_address
    AND claim.claim_block_number = leg.block_number
  WHERE
    leg.transaction_index > claim.claim_transaction_index
    OR (
      leg.transaction_index = claim.claim_transaction_index
      AND leg.log_index > claim.claim_log_index
    )
  GROUP BY
    claim.claim_recipient
  QUALIFY ROW_NUMBER() OVER (
    ORDER BY FARM_FINGERPRINT(claim.claim_recipient), claim.claim_recipient
  ) = 1
),

special_candidate_union AS (
  SELECT * FROM pre_claim_candidate
  UNION ALL
  SELECT * FROM self_transfer_candidate
  UNION ALL
  SELECT * FROM highest_leg_candidate
  UNION ALL
  SELECT * FROM same_block_post_claim_candidate
),

deduplicated_specials AS (
  SELECT * EXCEPT (address_rank)
  FROM (
    SELECT
      special_candidate_union.*,
      ROW_NUMBER() OVER (
        PARTITION BY claim_recipient
        ORDER BY category_priority, selection_category
      ) AS address_rank
    FROM
      special_candidate_union
  )
  WHERE
    address_rank = 1
),

bucket_candidates AS (
  SELECT
    CONCAT('7d_bucket_', claim.total_balance_to_claim_bucket_7d)
      AS selection_category,
    CASE claim.total_balance_to_claim_bucket_7d
      WHEN '0%' THEN 11
      WHEN '<25%' THEN 12
      WHEN '25-75%' THEN 13
      WHEN '75-100%' THEN 14
      WHEN '>100%' THEN 15
      ELSE 16
    END AS category_priority,
    claim.claim_recipient
  FROM
    proxy AS claim
  WHERE
    claim.total_balance_to_claim_bucket_7d IN (
      '0%', '<25%', '25-75%', '75-100%', '>100%'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM deduplicated_specials AS special
      WHERE special.claim_recipient = claim.claim_recipient
    )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY claim.total_balance_to_claim_bucket_7d
    ORDER BY FARM_FINGERPRINT(claim.claim_recipient), claim.claim_recipient
  ) = 1
),

selected AS (
  SELECT * FROM deduplicated_specials
  UNION ALL
  SELECT * FROM bucket_candidates
),

recomputed AS (
  SELECT
    selected.selection_category,
    selected.category_priority,
    claim.claim_recipient,
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_amount_raw,
    claim.all_history_leg_rows AS stored_all_history_leg_rows,
    claim.pre_claim_leg_rows AS stored_pre_claim_leg_rows,
    claim.leg_rows_before_7d_cutoff AS stored_leg_rows_before_7d_cutoff,
    claim.leg_rows_before_30d_cutoff AS stored_leg_rows_before_30d_cutoff,
    claim.pre_claim_arb_balance_raw AS stored_pre_claim_arb_balance_raw,
    claim.transfer_derived_arb_balance_raw_7d
      AS stored_transfer_derived_arb_balance_raw_7d,
    claim.transfer_derived_arb_balance_raw_30d
      AS stored_transfer_derived_arb_balance_raw_30d,
    claim.pre_claim_adjusted_retained_claim_proxy_raw_7d
      AS stored_adjusted_proxy_raw_7d,
    claim.pre_claim_adjusted_retained_claim_proxy_raw_30d
      AS stored_adjusted_proxy_raw_30d,
    claim.total_balance_to_claim_bucket_7d AS stored_bucket_7d,
    claim.total_balance_to_claim_bucket_30d AS stored_bucket_30d,
    COUNT(leg.transaction_hash) AS recomputed_all_history_leg_rows,
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
    ) AS recomputed_pre_claim_leg_rows,
    COUNTIF(
      leg.block_timestamp < TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 7 DAY)
    ) AS recomputed_leg_rows_before_7d_cutoff,
    COUNTIF(
      leg.block_timestamp < TIMESTAMP_ADD(
        claim.claim_timestamp, INTERVAL 30 DAY
      )
    ) AS recomputed_leg_rows_before_30d_cutoff,
    COALESCE(SUM(IF(
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
    )), 0) AS recomputed_pre_claim_arb_balance_raw,
    COALESCE(SUM(IF(
      leg.block_timestamp < TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 7 DAY),
      leg.signed_amount_raw,
      0
    )), 0) AS recomputed_transfer_derived_arb_balance_raw_7d,
    COALESCE(SUM(IF(
      leg.block_timestamp < TIMESTAMP_ADD(
        claim.claim_timestamp, INTERVAL 30 DAY
      ),
      leg.signed_amount_raw,
      0
    )), 0) AS recomputed_transfer_derived_arb_balance_raw_30d,
    COUNTIF(
      leg.transaction_hash = claim.claim_transaction_hash
      AND leg.log_index = claim.claim_log_index
      AND leg.leg_role = 'destination'
    ) AS recomputed_exact_claim_destination_leg_rows,
    COALESCE(SUM(IF(
      leg.transaction_hash = claim.claim_transaction_hash
      AND leg.log_index = claim.claim_log_index
      AND leg.leg_role = 'destination',
      leg.signed_amount_raw,
      0
    )), 0) AS recomputed_exact_claim_destination_signed_amount_raw,
    COALESCE(SUM(IF(leg.is_self_transfer, leg.signed_amount_raw, 0)), 0)
      AS recomputed_self_transfer_net_signed_amount_raw,
    COUNTIF(
      leg.block_timestamp = TIMESTAMP_ADD(claim.claim_timestamp, INTERVAL 7 DAY)
    ) AS legs_exactly_at_7d_cutoff_timestamp,
    COUNTIF(
      leg.block_timestamp = TIMESTAMP_ADD(
        claim.claim_timestamp, INTERVAL 30 DAY
      )
    ) AS legs_exactly_at_30d_cutoff_timestamp,
    ARRAY_AGG(
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
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
      LIMIT 3
    ) AS latest_pre_claim_legs,
    ARRAY_AGG(
      IF(
        leg.transaction_hash = claim.claim_transaction_hash
        AND leg.log_index = claim.claim_log_index,
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
          claim.claim_timestamp, INTERVAL 7 DAY
        ),
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
      LIMIT 3
    ) AS latest_legs_before_7d_cutoff,
    ARRAY_AGG(
      IF(
        leg.block_timestamp >= TIMESTAMP_ADD(
          claim.claim_timestamp, INTERVAL 7 DAY
        ),
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
      LIMIT 3
    ) AS earliest_legs_at_or_after_7d_cutoff,
    ARRAY_AGG(
      IF(
        leg.block_timestamp < TIMESTAMP_ADD(
          claim.claim_timestamp, INTERVAL 30 DAY
        ),
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
      LIMIT 3
    ) AS latest_legs_before_30d_cutoff,
    ARRAY_AGG(
      IF(
        leg.block_timestamp >= TIMESTAMP_ADD(
          claim.claim_timestamp, INTERVAL 30 DAY
        ),
        STRUCT(
          leg.block_timestamp AS block_timestamp,
          leg.block_number AS block_number,
          leg.transaction_hash AS transaction_hash,
          leg.transaction_index AS transaction_index,
          leg.log_index AS log_index,
          leg.leg_role AS leg_role,
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
      LIMIT 3
    ) AS earliest_legs_at_or_after_30d_cutoff
  FROM
    selected
  INNER JOIN
    proxy AS claim
    USING (claim_recipient)
  LEFT JOIN
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs` AS leg
    ON claim.claim_recipient = leg.claimant_address
  GROUP BY
    selected.selection_category,
    selected.category_priority,
    claim.claim_recipient,
    claim.claim_timestamp,
    claim.claim_block_number,
    claim.claim_transaction_hash,
    claim.claim_transaction_index,
    claim.claim_log_index,
    claim.claim_amount_raw,
    claim.all_history_leg_rows,
    claim.pre_claim_leg_rows,
    claim.leg_rows_before_7d_cutoff,
    claim.leg_rows_before_30d_cutoff,
    claim.pre_claim_arb_balance_raw,
    claim.transfer_derived_arb_balance_raw_7d,
    claim.transfer_derived_arb_balance_raw_30d,
    claim.pre_claim_adjusted_retained_claim_proxy_raw_7d,
    claim.pre_claim_adjusted_retained_claim_proxy_raw_30d,
    claim.total_balance_to_claim_bucket_7d,
    claim.total_balance_to_claim_bucket_30d
),

sample_measures AS (
  SELECT
    *,
    LEAST(
      claim_amount_raw,
      GREATEST(
        CAST(0 AS BIGNUMERIC),
        recomputed_transfer_derived_arb_balance_raw_7d
          - recomputed_pre_claim_arb_balance_raw
      )
    ) AS recomputed_adjusted_proxy_raw_7d,
    LEAST(
      claim_amount_raw,
      GREATEST(
        CAST(0 AS BIGNUMERIC),
        recomputed_transfer_derived_arb_balance_raw_30d
          - recomputed_pre_claim_arb_balance_raw
      )
    ) AS recomputed_adjusted_proxy_raw_30d,
    CASE
      WHEN recomputed_transfer_derived_arb_balance_raw_7d < 0
        THEN 'invalid: negative balance'
      WHEN recomputed_transfer_derived_arb_balance_raw_7d = 0 THEN '0%'
      WHEN recomputed_transfer_derived_arb_balance_raw_7d < claim_amount_raw / 4
        THEN '<25%'
      WHEN recomputed_transfer_derived_arb_balance_raw_7d
        < claim_amount_raw * 3 / 4 THEN '25-75%'
      WHEN recomputed_transfer_derived_arb_balance_raw_7d <= claim_amount_raw
        THEN '75-100%'
      ELSE '>100%'
    END AS recomputed_bucket_7d,
    CASE
      WHEN recomputed_transfer_derived_arb_balance_raw_30d < 0
        THEN 'invalid: negative balance'
      WHEN recomputed_transfer_derived_arb_balance_raw_30d = 0 THEN '0%'
      WHEN recomputed_transfer_derived_arb_balance_raw_30d < claim_amount_raw / 4
        THEN '<25%'
      WHEN recomputed_transfer_derived_arb_balance_raw_30d
        < claim_amount_raw * 3 / 4 THEN '25-75%'
      WHEN recomputed_transfer_derived_arb_balance_raw_30d <= claim_amount_raw
        THEN '75-100%'
      ELSE '>100%'
    END AS recomputed_bucket_30d
  FROM
    recomputed
)

SELECT
  *,
  recomputed_all_history_leg_rows = stored_all_history_leg_rows
    AS all_history_leg_rows_match,
  recomputed_pre_claim_leg_rows = stored_pre_claim_leg_rows
    AS pre_claim_leg_rows_match,
  recomputed_leg_rows_before_7d_cutoff = stored_leg_rows_before_7d_cutoff
    AS leg_rows_before_7d_cutoff_match,
  recomputed_leg_rows_before_30d_cutoff = stored_leg_rows_before_30d_cutoff
    AS leg_rows_before_30d_cutoff_match,
  recomputed_pre_claim_arb_balance_raw = stored_pre_claim_arb_balance_raw
    AS pre_claim_balance_match,
  recomputed_transfer_derived_arb_balance_raw_7d
    = stored_transfer_derived_arb_balance_raw_7d AS balance_7d_match,
  recomputed_transfer_derived_arb_balance_raw_30d
    = stored_transfer_derived_arb_balance_raw_30d AS balance_30d_match,
  recomputed_adjusted_proxy_raw_7d = stored_adjusted_proxy_raw_7d
    AS adjusted_proxy_7d_match,
  recomputed_adjusted_proxy_raw_30d = stored_adjusted_proxy_raw_30d
    AS adjusted_proxy_30d_match,
  recomputed_bucket_7d = stored_bucket_7d AS bucket_7d_match,
  recomputed_bucket_30d = stored_bucket_30d AS bucket_30d_match,
  recomputed_exact_claim_destination_leg_rows = 1
    AND recomputed_exact_claim_destination_signed_amount_raw = claim_amount_raw
    AS exact_claim_destination_match,
  recomputed_self_transfer_net_signed_amount_raw = 0
    AS self_transfer_net_zero
FROM
  sample_measures
ORDER BY
  category_priority,
  claim_recipient;

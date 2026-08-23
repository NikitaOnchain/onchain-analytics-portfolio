-- Profile and reconcile the claim-grain transfer-derived ARB balance proxy.
-- Always fresh-dry-run this exact read-only statement before execution.
--
-- Output grain:
--   Exactly one aggregate QA row for the complete validated claim cohort.
--   The two bucket fields are bounded arrays with one row per bucket.
--
-- Source tables and source grain:
--   retention_transfer_derived_arb_balance_proxy:
--     one row per validated unique claim recipient.
--   corrected_claim_transfers_enriched_chunk_01..21:
--     one validated claim event and unique recipient per row.
--   retention_arb_claimant_transfer_legs:
--     one signed claimant endpoint role per
--     (transaction_hash, log_index, leg_role).
--
-- Join keys and expected cardinality:
--   Source claims LEFT JOIN proxy one-to-one by normalized recipient. The
--   proxy-to-source reverse coverage is derived from that reconciliation plus
--   independently profiled row and distinct-key counts. Leg cardinality is
--   reconciled through aggregate counts, so no leg JOIN can multiply QA rows.
--
-- Filters and time boundaries:
--   Claim suffixes are final numeric chunks 01 through 21. The materialized
--   proxy already applies exact pre-claim order and cutoff-exclusive 7d/30d
--   elapsed-time windows; this query validates the stored boundary counters
--   and formulas but does not redefine the windows.
--
-- Row-multiplication risk:
--   The only row-level JOIN is expected one-to-one by unique recipient.
--   Duplicate profiles are computed separately before cross-joining scalar
--   summaries. Bucket arrays contain at most six controlled values.

WITH proxy AS (
  SELECT *
  FROM
    `YOUR_DATASET_ID.retention_transfer_derived_arb_balance_proxy`
),

source_claims AS (
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

recipient_key_profile AS (
  SELECT
    claim_recipient,
    COUNT(*) AS rows_on_recipient
  FROM
    proxy
  GROUP BY
    claim_recipient
),

recipient_key_summary AS (
  SELECT
    COUNTIF(rows_on_recipient > 1) AS duplicated_recipient_keys,
    SUM(IF(rows_on_recipient > 1, rows_on_recipient, 0))
      AS rows_on_duplicated_recipient_keys,
    SUM(rows_on_recipient - 1) AS extra_rows_above_recipient_grain
  FROM
    recipient_key_profile
),

claim_event_key_profile AS (
  SELECT
    claim_transaction_hash,
    claim_log_index,
    COUNT(*) AS rows_on_claim_event
  FROM
    proxy
  GROUP BY
    claim_transaction_hash,
    claim_log_index
),

claim_event_key_summary AS (
  SELECT
    COUNTIF(rows_on_claim_event > 1) AS duplicated_claim_event_keys,
    SUM(rows_on_claim_event - 1) AS extra_rows_above_claim_event_grain
  FROM
    claim_event_key_profile
),

proxy_summary AS (
  SELECT
    COUNT(*) AS proxy_rows,
    COUNT(DISTINCT claim_recipient) AS distinct_proxy_recipients,
    COUNT(DISTINCT FORMAT(
      '%s#%d', claim_transaction_hash, claim_log_index
    )) AS distinct_proxy_claim_event_keys,
    COUNTIF(
      claim_chunk_number IS NULL
      OR claim_timestamp IS NULL
      OR claim_block_number IS NULL
      OR claim_transaction_hash IS NULL
      OR claim_transaction_index IS NULL
      OR claim_log_index IS NULL
      OR claim_recipient IS NULL
      OR claim_amount_raw IS NULL
      OR claim_source_match_rows IS NULL
      OR claim_receipt_timestamp IS NULL
      OR claim_receipt_block_number IS NULL
      OR claim_receipt_match_rows IS NULL
      OR claim_block_match_rows IS NULL
      OR order_match_rows IS NULL
      OR all_history_leg_rows IS NULL
      OR pre_claim_leg_rows IS NULL
      OR leg_rows_before_7d_cutoff IS NULL
      OR leg_rows_before_30d_cutoff IS NULL
      OR pre_claim_arb_balance_raw IS NULL
      OR transfer_derived_arb_balance_raw_7d IS NULL
      OR transfer_derived_arb_balance_raw_30d IS NULL
      OR exact_claim_destination_leg_rows IS NULL
      OR exact_claim_destination_signed_amount_raw IS NULL
      OR pre_claim_adjusted_retained_claim_proxy_raw_7d IS NULL
      OR pre_claim_adjusted_retained_claim_proxy_raw_30d IS NULL
      OR total_balance_to_claim_ratio_7d IS NULL
      OR total_balance_to_claim_ratio_30d IS NULL
      OR pre_claim_adjusted_retained_claim_proxy_ratio_7d IS NULL
      OR pre_claim_adjusted_retained_claim_proxy_ratio_30d IS NULL
      OR total_balance_to_claim_bucket_7d IS NULL
      OR total_balance_to_claim_bucket_30d IS NULL
    ) AS critical_null_rows,
    COUNTIF(
      NOT REGEXP_CONTAINS(claim_recipient, r'^0x[0-9a-f]{40}$')
    ) AS invalid_recipient_rows,
    COUNTIF(claim_amount_raw <= 0) AS non_positive_claim_amount_rows,
    COUNTIF(claim_source_match_rows != 1) AS invalid_claim_source_match_rows,
    COUNTIF(order_match_rows != 1) AS invalid_order_match_rows,
    COUNTIF(
      claim_receipt_match_rows != 1 OR claim_block_match_rows != 1
    ) AS invalid_order_source_match_rows,
    COUNTIF(
      claim_receipt_timestamp != claim_timestamp
      OR claim_receipt_block_number != claim_block_number
    ) AS claim_order_metadata_mismatch_rows,
    COUNTIF(exact_claim_destination_leg_rows != 1)
      AS invalid_exact_claim_destination_leg_rows,
    COUNTIF(
      exact_claim_destination_signed_amount_raw != claim_amount_raw
    ) AS exact_claim_destination_amount_mismatch_rows,
    COUNTIF(all_history_leg_rows < 1) AS claims_without_any_leg_rows,
    COUNTIF(
      pre_claim_leg_rows > leg_rows_before_7d_cutoff
      OR leg_rows_before_7d_cutoff > leg_rows_before_30d_cutoff
      OR leg_rows_before_30d_cutoff > all_history_leg_rows
    ) AS invalid_leg_count_order_rows,
    COUNTIF(pre_claim_arb_balance_raw < 0) AS negative_pre_claim_balance_rows,
    COUNTIF(transfer_derived_arb_balance_raw_7d < 0)
      AS negative_7d_balance_rows,
    COUNTIF(transfer_derived_arb_balance_raw_30d < 0)
      AS negative_30d_balance_rows,
    COUNTIF(
      pre_claim_adjusted_retained_claim_proxy_raw_7d < 0
      OR pre_claim_adjusted_retained_claim_proxy_raw_7d > claim_amount_raw
    ) AS invalid_adjusted_proxy_bounds_7d_rows,
    COUNTIF(
      pre_claim_adjusted_retained_claim_proxy_raw_30d < 0
      OR pre_claim_adjusted_retained_claim_proxy_raw_30d > claim_amount_raw
    ) AS invalid_adjusted_proxy_bounds_30d_rows,
    COUNTIF(
      pre_claim_adjusted_retained_claim_proxy_raw_7d
      != LEAST(
        claim_amount_raw,
        GREATEST(
          CAST(0 AS BIGNUMERIC),
          transfer_derived_arb_balance_raw_7d - pre_claim_arb_balance_raw
        )
      )
    ) AS adjusted_proxy_formula_mismatch_7d_rows,
    COUNTIF(
      pre_claim_adjusted_retained_claim_proxy_raw_30d
      != LEAST(
        claim_amount_raw,
        GREATEST(
          CAST(0 AS BIGNUMERIC),
          transfer_derived_arb_balance_raw_30d - pre_claim_arb_balance_raw
        )
      )
    ) AS adjusted_proxy_formula_mismatch_30d_rows,
    COUNTIF(
      total_balance_to_claim_ratio_7d
      != SAFE_DIVIDE(transfer_derived_arb_balance_raw_7d, claim_amount_raw)
      OR pre_claim_adjusted_retained_claim_proxy_ratio_7d
      != SAFE_DIVIDE(
        pre_claim_adjusted_retained_claim_proxy_raw_7d, claim_amount_raw
      )
    ) AS ratio_formula_mismatch_7d_rows,
    COUNTIF(
      total_balance_to_claim_ratio_30d
      != SAFE_DIVIDE(transfer_derived_arb_balance_raw_30d, claim_amount_raw)
      OR pre_claim_adjusted_retained_claim_proxy_ratio_30d
      != SAFE_DIVIDE(
        pre_claim_adjusted_retained_claim_proxy_raw_30d, claim_amount_raw
      )
    ) AS ratio_formula_mismatch_30d_rows,
    COUNTIF(
      total_balance_to_claim_bucket_7d NOT IN (
        '0%', '<25%', '25-75%', '75-100%', '>100%',
        'invalid: negative balance'
      )
    ) AS invalid_bucket_value_7d_rows,
    COUNTIF(
      total_balance_to_claim_bucket_30d NOT IN (
        '0%', '<25%', '25-75%', '75-100%', '>100%',
        'invalid: negative balance'
      )
    ) AS invalid_bucket_value_30d_rows,
    COUNTIF(
      total_balance_to_claim_bucket_7d != CASE
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
      END
    ) AS bucket_rule_mismatch_7d_rows,
    COUNTIF(
      total_balance_to_claim_bucket_30d != CASE
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
      END
    ) AS bucket_rule_mismatch_30d_rows,
    SUM(claim_amount_raw) AS claimed_amount_raw,
    SUM(exact_claim_destination_signed_amount_raw)
      AS exact_claim_destination_amount_raw,
    SUM(all_history_leg_rows) AS summed_all_history_leg_rows,
    SUM(pre_claim_leg_rows) AS summed_pre_claim_leg_rows,
    SUM(leg_rows_before_7d_cutoff) AS summed_leg_rows_before_7d_cutoff,
    SUM(leg_rows_before_30d_cutoff) AS summed_leg_rows_before_30d_cutoff,
    SUM(pre_claim_arb_balance_raw) AS summed_pre_claim_balance_raw,
    SUM(transfer_derived_arb_balance_raw_7d) AS summed_balance_raw_7d,
    SUM(transfer_derived_arb_balance_raw_30d) AS summed_balance_raw_30d,
    SUM(pre_claim_adjusted_retained_claim_proxy_raw_7d)
      AS summed_adjusted_retained_claim_proxy_raw_7d,
    SUM(pre_claim_adjusted_retained_claim_proxy_raw_30d)
      AS summed_adjusted_retained_claim_proxy_raw_30d,
    COUNTIF(pre_claim_arb_balance_raw > 0) AS positive_pre_claim_balance_rows,
    COUNTIF(pre_claim_arb_balance_raw = 0) AS zero_pre_claim_balance_rows,
    COUNTIF(transfer_derived_arb_balance_raw_7d = 0) AS zero_balance_7d_rows,
    COUNTIF(transfer_derived_arb_balance_raw_30d = 0) AS zero_balance_30d_rows,
    COUNTIF(transfer_derived_arb_balance_raw_7d > claim_amount_raw)
      AS above_claim_balance_7d_rows,
    COUNTIF(transfer_derived_arb_balance_raw_30d > claim_amount_raw)
      AS above_claim_balance_30d_rows
  FROM
    proxy
),

source_claim_reconciliation AS (
  SELECT
    COUNT(*) AS source_claim_rows,
    COUNT(DISTINCT source.claim_recipient) AS distinct_source_recipients,
    COUNT(DISTINCT FORMAT(
      '%s#%d', source.claim_transaction_hash, source.claim_log_index
    )) AS distinct_source_claim_event_keys,
    SUM(source.claim_amount_raw) AS source_claimed_amount_raw,
    COUNTIF(proxy.claim_recipient IS NULL) AS source_claims_missing_proxy,
    COUNTIF(
      proxy.claim_recipient IS NOT NULL
      AND (
        proxy.claim_chunk_number IS DISTINCT FROM source.claim_chunk_number
        OR proxy.claim_timestamp IS DISTINCT FROM source.claim_timestamp
        OR proxy.claim_block_number IS DISTINCT FROM source.claim_block_number
        OR proxy.claim_transaction_hash
          IS DISTINCT FROM source.claim_transaction_hash
        OR proxy.claim_log_index IS DISTINCT FROM source.claim_log_index
        OR proxy.claim_amount_raw IS DISTINCT FROM source.claim_amount_raw
        OR proxy.claim_source_match_rows
          IS DISTINCT FROM source.claim_source_match_rows
      )
    ) AS source_to_proxy_field_mismatch_rows
  FROM
    source_claims AS source
  LEFT JOIN
    proxy
    USING (claim_recipient)
),

leg_summary AS (
  SELECT
    COUNT(*) AS source_leg_rows,
    COUNT(DISTINCT claimant_address) AS distinct_source_leg_claimants,
    COUNT(DISTINCT FORMAT(
      '%s#%d#%s', transaction_hash, log_index, leg_role
    )) AS distinct_source_leg_keys,
    SUM(IF(is_self_transfer, signed_amount_raw, 0))
      AS self_transfer_net_signed_amount_raw
  FROM
    `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs`
),

bucket_7d AS (
  SELECT
    total_balance_to_claim_bucket_7d AS bucket,
    COUNT(*) AS recipient_rows,
    SAFE_DIVIDE(COUNT(*), (SELECT COUNT(*) FROM proxy)) AS recipient_share
  FROM
    proxy
  GROUP BY
    bucket
),

bucket_30d AS (
  SELECT
    total_balance_to_claim_bucket_30d AS bucket,
    COUNT(*) AS recipient_rows,
    SAFE_DIVIDE(COUNT(*), (SELECT COUNT(*) FROM proxy)) AS recipient_share
  FROM
    proxy
  GROUP BY
    bucket
)

SELECT
  proxy_metrics.*,
  recipient_keys.*,
  claim_event_keys.*,
  source_reconciliation.*,
  leg_metrics.*,
  proxy_metrics.proxy_rows - source_reconciliation.source_claim_rows
    + source_reconciliation.source_claims_missing_proxy
    AS proxy_rows_without_source_claim,
  proxy_metrics.summed_all_history_leg_rows - leg_metrics.source_leg_rows
    AS leg_row_reconciliation_difference,
  proxy_metrics.claimed_amount_raw
    - source_reconciliation.source_claimed_amount_raw
    AS claim_amount_reconciliation_difference_raw,
  proxy_metrics.exact_claim_destination_amount_raw
    - proxy_metrics.claimed_amount_raw
    AS exact_claim_destination_difference_raw,
  ARRAY(
    SELECT AS STRUCT bucket, recipient_rows, recipient_share
    FROM bucket_7d
    ORDER BY CASE bucket
      WHEN '0%' THEN 1
      WHEN '<25%' THEN 2
      WHEN '25-75%' THEN 3
      WHEN '75-100%' THEN 4
      WHEN '>100%' THEN 5
      ELSE 6
    END
  ) AS total_balance_to_claim_buckets_7d,
  ARRAY(
    SELECT AS STRUCT bucket, recipient_rows, recipient_share
    FROM bucket_30d
    ORDER BY CASE bucket
      WHEN '0%' THEN 1
      WHEN '<25%' THEN 2
      WHEN '25-75%' THEN 3
      WHEN '75-100%' THEN 4
      WHEN '>100%' THEN 5
      ELSE 6
    END
  ) AS total_balance_to_claim_buckets_30d
FROM
  proxy_summary AS proxy_metrics
CROSS JOIN
  recipient_key_summary AS recipient_keys
CROSS JOIN
  claim_event_key_summary AS claim_event_keys
CROSS JOIN
  source_claim_reconciliation AS source_reconciliation
CROSS JOIN
  leg_summary AS leg_metrics;

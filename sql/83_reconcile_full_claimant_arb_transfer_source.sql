-- Reconcile the complete 29-chunk claimant-related ARB Transfer source.
-- Fresh-dry-run this exact read-only statement before execution.
--
-- Output grain:
--   Exactly one QA summary row for the complete transfer-source layer.
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.retention_arb_transfer_source_chunk_*
--     Intended grain: one decoded ARB Transfer event per
--     (transaction_hash, log_index), split across 29 non-overlapping tables.
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*
--     One validated claim event and unique recipient per final two-digit row.
--   expected_schedule CTE
--     One row per planned source chunk with exact bounds and validated row count.
--
-- Join keys and expected cardinality:
--   table-suffix chunk number -> expected_schedule.chunk_number is many-to-one.
--   Claimant membership uses EXISTS semijoins against a DISTINCT address set and
--   cannot multiply rows. The schedule join must preserve every source row.
--
-- Filters and time boundaries:
--   Only two-digit source-table suffixes 01 through 29 are qualifying inputs.
--   The embedded schedule covers half-open UTC intervals from
--   [2023-03-16, 2023-10-25). Per-row bounds are checked against the interval
--   assigned to the physical table suffix.
--
-- Row-multiplication risk:
--   The schedule join is many-to-one and cannot multiply valid source rows.
--   Duplicate event keys within or across chunks are measured explicitly.
--   Sender/destination claimant-leg expansion is not performed here; its future
--   expected row multiplication is reconciled through direct and derived
--   dual-claimant endpoint counts.

WITH expected_schedule AS (
  SELECT *
  FROM UNNEST([
    STRUCT(1 AS chunk_number, TIMESTAMP('2023-03-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-03-23 00:00:00+00') AS end_utc, 16 AS expected_rows),
    STRUCT(2 AS chunk_number, TIMESTAMP('2023-03-23 00:00:00+00') AS start_utc, TIMESTAMP('2023-03-27 00:00:00+00') AS end_utc, 1300662 AS expected_rows),
    STRUCT(3 AS chunk_number, TIMESTAMP('2023-03-27 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-01 00:00:00+00') AS end_utc, 274645 AS expected_rows),
    STRUCT(4 AS chunk_number, TIMESTAMP('2023-04-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-07 00:00:00+00') AS end_utc, 195359 AS expected_rows),
    STRUCT(5 AS chunk_number, TIMESTAMP('2023-04-07 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-13 00:00:00+00') AS end_utc, 107211 AS expected_rows),
    STRUCT(6 AS chunk_number, TIMESTAMP('2023-04-13 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-16 00:00:00+00') AS end_utc, 95172 AS expected_rows),
    STRUCT(7 AS chunk_number, TIMESTAMP('2023-04-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-19 00:00:00+00') AS end_utc, 67267 AS expected_rows),
    STRUCT(8 AS chunk_number, TIMESTAMP('2023-04-19 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-22 00:00:00+00') AS end_utc, 53003 AS expected_rows),
    STRUCT(9 AS chunk_number, TIMESTAMP('2023-04-22 00:00:00+00') AS start_utc, TIMESTAMP('2023-04-25 00:00:00+00') AS end_utc, 93623 AS expected_rows),
    STRUCT(10 AS chunk_number, TIMESTAMP('2023-04-25 00:00:00+00') AS start_utc, TIMESTAMP('2023-05-01 00:00:00+00') AS end_utc, 82549 AS expected_rows),
    STRUCT(11 AS chunk_number, TIMESTAMP('2023-05-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-05-06 00:00:00+00') AS end_utc, 206526 AS expected_rows),
    STRUCT(12 AS chunk_number, TIMESTAMP('2023-05-06 00:00:00+00') AS start_utc, TIMESTAMP('2023-05-11 00:00:00+00') AS end_utc, 109253 AS expected_rows),
    STRUCT(13 AS chunk_number, TIMESTAMP('2023-05-11 00:00:00+00') AS start_utc, TIMESTAMP('2023-05-21 00:00:00+00') AS end_utc, 101260 AS expected_rows),
    STRUCT(14 AS chunk_number, TIMESTAMP('2023-05-21 00:00:00+00') AS start_utc, TIMESTAMP('2023-06-01 00:00:00+00') AS end_utc, 76433 AS expected_rows),
    STRUCT(15 AS chunk_number, TIMESTAMP('2023-06-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-06-08 00:00:00+00') AS end_utc, 44057 AS expected_rows),
    STRUCT(16 AS chunk_number, TIMESTAMP('2023-06-08 00:00:00+00') AS start_utc, TIMESTAMP('2023-06-16 00:00:00+00') AS end_utc, 51764 AS expected_rows),
    STRUCT(17 AS chunk_number, TIMESTAMP('2023-06-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-06-24 00:00:00+00') AS end_utc, 42341 AS expected_rows),
    STRUCT(18 AS chunk_number, TIMESTAMP('2023-06-24 00:00:00+00') AS start_utc, TIMESTAMP('2023-07-01 00:00:00+00') AS end_utc, 43642 AS expected_rows),
    STRUCT(19 AS chunk_number, TIMESTAMP('2023-07-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-07-16 00:00:00+00') AS end_utc, 77781 AS expected_rows),
    STRUCT(20 AS chunk_number, TIMESTAMP('2023-07-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-08-01 00:00:00+00') AS end_utc, 89357 AS expected_rows),
    STRUCT(21 AS chunk_number, TIMESTAMP('2023-08-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-08-16 00:00:00+00') AS end_utc, 68915 AS expected_rows),
    STRUCT(22 AS chunk_number, TIMESTAMP('2023-08-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-09-01 00:00:00+00') AS end_utc, 69743 AS expected_rows),
    STRUCT(23 AS chunk_number, TIMESTAMP('2023-09-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-09-16 00:00:00+00') AS end_utc, 50907 AS expected_rows),
    STRUCT(24 AS chunk_number, TIMESTAMP('2023-09-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-01 00:00:00+00') AS end_utc, 71813 AS expected_rows),
    STRUCT(25 AS chunk_number, TIMESTAMP('2023-10-01 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-02 00:00:00+00') AS end_utc, 7406 AS expected_rows),
    STRUCT(26 AS chunk_number, TIMESTAMP('2023-10-02 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-09 00:00:00+00') AS end_utc, 33488 AS expected_rows),
    STRUCT(27 AS chunk_number, TIMESTAMP('2023-10-09 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-16 00:00:00+00') AS end_utc, 24148 AS expected_rows),
    STRUCT(28 AS chunk_number, TIMESTAMP('2023-10-16 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-23 00:00:00+00') AS end_utc, 22119 AS expected_rows),
    STRUCT(29 AS chunk_number, TIMESTAMP('2023-10-23 00:00:00+00') AS start_utc, TIMESTAMP('2023-10-25 00:00:00+00') AS end_utc, 11756 AS expected_rows)
  ])
),

expected_schedule_ordered AS (
  SELECT
    expected_schedule.*,
    LAG(end_utc) OVER (ORDER BY chunk_number) AS previous_end_utc
  FROM
    expected_schedule
),

schedule_shape_summary AS (
  SELECT
    COUNT(*) AS embedded_schedule_rows,
    COUNT(DISTINCT chunk_number) AS distinct_schedule_chunk_numbers,
    COUNT(*) - COUNT(DISTINCT chunk_number)
      AS duplicate_schedule_chunk_numbers,
    MIN(chunk_number) AS min_schedule_chunk_number,
    MAX(chunk_number) AS max_schedule_chunk_number,
    COUNTIF(start_utc >= end_utc) AS invalid_schedule_intervals,
    COUNTIF(previous_end_utc IS NOT NULL AND start_utc > previous_end_utc)
      AS schedule_gap_count,
    COUNTIF(previous_end_utc IS NOT NULL AND start_utc < previous_end_utc)
      AS schedule_overlap_count,
    MIN(start_utc) AS schedule_coverage_start_utc,
    MAX(end_utc) AS schedule_coverage_end_utc_exclusive,
    COUNTIF(
      chunk_number = 1
      AND start_utc = TIMESTAMP('2023-03-16 00:00:00+00')
    ) AS matching_planned_start_rows,
    COUNTIF(
      chunk_number = 29
      AND end_utc = TIMESTAMP('2023-10-25 00:00:00+00')
    ) AS matching_planned_end_rows
  FROM
    expected_schedule_ordered
),

claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS recipient
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

source AS (
  SELECT
    SAFE_CAST(_TABLE_SUFFIX AS INT64) AS table_suffix_chunk_number,
    source_chunk_number,
    block_timestamp,
    block_number,
    transaction_hash,
    transaction_index,
    log_index,
    sender,
    destination,
    amount_raw,
    source_match_rows
  FROM
    `YOUR_DATASET_ID.retention_arb_transfer_source_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
),

enriched AS (
  SELECT
    source.*,
    expected.start_utc,
    expected.end_utc,
    expected.expected_rows,
    EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = source.sender
    ) AS sender_is_claimant,
    EXISTS (
      SELECT 1
      FROM claimants
      WHERE recipient = source.destination
    ) AS destination_is_claimant
  FROM
    source
  LEFT JOIN
    expected_schedule AS expected
    ON source.table_suffix_chunk_number = expected.chunk_number
),

row_summary AS (
  SELECT
    COUNT(*) AS source_rows,
    COUNT(DISTINCT table_suffix_chunk_number) AS physical_chunk_count,
    COUNT(DISTINCT source_chunk_number) AS internal_chunk_number_count,
    MIN(table_suffix_chunk_number) AS min_physical_chunk_number,
    MAX(table_suffix_chunk_number) AS max_physical_chunk_number,
    COUNTIF(
      table_suffix_chunk_number IS NULL
      OR source_chunk_number IS NULL
      OR block_timestamp IS NULL
      OR block_number IS NULL
      OR transaction_hash IS NULL
      OR transaction_index IS NULL
      OR log_index IS NULL
      OR sender IS NULL
      OR destination IS NULL
      OR amount_raw IS NULL
      OR source_match_rows IS NULL
    ) AS critical_null_rows,
    COUNTIF(start_utc IS NULL OR end_utc IS NULL) AS rows_without_schedule_match,
    COUNTIF(
      source_chunk_number IS NULL
      OR source_chunk_number != table_suffix_chunk_number
    )
      AS internal_vs_physical_chunk_mismatch_rows,
    COUNTIF(
      block_timestamp < start_utc
      OR block_timestamp >= end_utc
    ) AS out_of_assigned_window_rows,
    COUNTIF(
      NOT REGEXP_CONTAINS(sender, r'^0x[0-9a-f]{40}$')
      OR NOT REGEXP_CONTAINS(destination, r'^0x[0-9a-f]{40}$')
    ) AS invalid_address_rows,
    COUNTIF(amount_raw <= 0) AS non_positive_amount_rows,
    COUNTIF(source_match_rows != 1) AS invalid_source_match_rows,
    COUNTIF(NOT sender_is_claimant AND NOT destination_is_claimant)
      AS non_claimant_related_rows,
    COUNTIF(sender = destination) AS self_transfer_rows,
    COUNTIF(sender_is_claimant) AS claimant_sender_event_rows,
    COUNTIF(destination_is_claimant) AS claimant_destination_event_rows,
    COUNTIF(sender_is_claimant AND destination_is_claimant)
      AS direct_dual_claimant_endpoint_event_rows,
    MIN(block_timestamp) AS first_observed_transfer_timestamp,
    MAX(block_timestamp) AS last_observed_transfer_timestamp,
    SUM(amount_raw) AS gross_event_amount_raw
  FROM
    enriched
),

key_profile AS (
  SELECT
    transaction_hash,
    log_index,
    COUNT(*) AS event_key_rows,
    COUNT(DISTINCT table_suffix_chunk_number) AS physical_chunks_on_key
  FROM
    enriched
  GROUP BY
    transaction_hash,
    log_index
),

key_summary AS (
  SELECT
    COUNT(*) AS distinct_event_keys,
    COUNTIF(event_key_rows > 1) AS duplicated_event_keys,
    SUM(IF(event_key_rows > 1, event_key_rows, 0))
      AS rows_on_duplicate_event_keys,
    SUM(event_key_rows - 1) AS extra_rows_above_unique_event_grain,
    COUNTIF(physical_chunks_on_key > 1) AS event_keys_in_multiple_chunks
  FROM
    key_profile
),

actual_by_table AS (
  SELECT
    table_suffix_chunk_number,
    COUNT(*) AS actual_rows,
    COUNT(DISTINCT source_chunk_number) AS internal_numbers_in_table,
    MIN(source_chunk_number) AS min_internal_chunk_number,
    MAX(source_chunk_number) AS max_internal_chunk_number
  FROM
    source
  GROUP BY
    table_suffix_chunk_number
),

schedule_reconciliation AS (
  SELECT
    expected.chunk_number AS expected_chunk_number,
    expected.expected_rows,
    actual.table_suffix_chunk_number,
    actual.actual_rows,
    actual.internal_numbers_in_table,
    actual.min_internal_chunk_number,
    actual.max_internal_chunk_number
  FROM
    expected_schedule AS expected
  FULL OUTER JOIN
    actual_by_table AS actual
    ON expected.chunk_number = actual.table_suffix_chunk_number
),

schedule_summary AS (
  SELECT
    COUNTIF(expected_chunk_number IS NOT NULL) AS expected_chunk_count,
    SUM(expected_rows) AS expected_total_rows,
    COUNTIF(table_suffix_chunk_number IS NOT NULL) AS observed_chunk_table_count,
    COUNTIF(table_suffix_chunk_number IS NULL) AS missing_expected_chunk_tables,
    COUNTIF(expected_chunk_number IS NULL) AS unexpected_numeric_chunk_tables,
    COUNTIF(
      expected_chunk_number IS NOT NULL
      AND table_suffix_chunk_number IS NOT NULL
      AND actual_rows != expected_rows
    ) AS chunk_tables_with_row_count_mismatch,
    SUM(IFNULL(actual_rows, 0)) AS reconciled_actual_total_rows,
    COUNTIF(
      table_suffix_chunk_number IS NOT NULL
      AND (
        internal_numbers_in_table != 1
        OR min_internal_chunk_number != table_suffix_chunk_number
        OR max_internal_chunk_number != table_suffix_chunk_number
      )
    ) AS chunk_tables_with_internal_number_defects
  FROM
    schedule_reconciliation
)

SELECT
  shape.embedded_schedule_rows,
  shape.distinct_schedule_chunk_numbers,
  shape.duplicate_schedule_chunk_numbers,
  shape.min_schedule_chunk_number,
  shape.max_schedule_chunk_number,
  shape.invalid_schedule_intervals,
  shape.schedule_gap_count,
  shape.schedule_overlap_count,
  shape.schedule_coverage_start_utc,
  shape.schedule_coverage_end_utc_exclusive,
  shape.matching_planned_start_rows,
  shape.matching_planned_end_rows,
  schedule.expected_chunk_count,
  schedule.observed_chunk_table_count,
  schedule.missing_expected_chunk_tables,
  schedule.unexpected_numeric_chunk_tables,
  schedule.chunk_tables_with_row_count_mismatch,
  schedule.chunk_tables_with_internal_number_defects,
  schedule.expected_total_rows,
  schedule.reconciled_actual_total_rows,
  row_metrics.source_rows,
  row_metrics.physical_chunk_count,
  row_metrics.internal_chunk_number_count,
  row_metrics.min_physical_chunk_number,
  row_metrics.max_physical_chunk_number,
  keys.distinct_event_keys,
  keys.duplicated_event_keys,
  keys.rows_on_duplicate_event_keys,
  keys.extra_rows_above_unique_event_grain,
  keys.event_keys_in_multiple_chunks,
  row_metrics.critical_null_rows,
  row_metrics.rows_without_schedule_match,
  row_metrics.internal_vs_physical_chunk_mismatch_rows,
  row_metrics.out_of_assigned_window_rows,
  row_metrics.invalid_address_rows,
  row_metrics.non_positive_amount_rows,
  row_metrics.invalid_source_match_rows,
  row_metrics.non_claimant_related_rows,
  row_metrics.self_transfer_rows,
  row_metrics.claimant_sender_event_rows,
  row_metrics.claimant_destination_event_rows,
  row_metrics.direct_dual_claimant_endpoint_event_rows,
  row_metrics.claimant_sender_event_rows
    + row_metrics.claimant_destination_event_rows
    - row_metrics.source_rows AS derived_dual_claimant_endpoint_event_rows,
  row_metrics.direct_dual_claimant_endpoint_event_rows - (
    row_metrics.claimant_sender_event_rows
    + row_metrics.claimant_destination_event_rows
    - row_metrics.source_rows
  ) AS dual_claimant_endpoint_formula_difference,
  row_metrics.claimant_sender_event_rows
    + row_metrics.claimant_destination_event_rows
    AS expected_claimant_leg_rows,
  row_metrics.first_observed_transfer_timestamp,
  row_metrics.last_observed_transfer_timestamp,
  row_metrics.gross_event_amount_raw
FROM
  row_summary AS row_metrics
CROSS JOIN
  key_summary AS keys
CROSS JOIN
  schedule_summary AS schedule
CROSS JOIN
  schedule_shape_summary AS shape;

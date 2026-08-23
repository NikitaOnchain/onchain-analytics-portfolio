-- Profile current BigQuery working storage before retention-layer materialization.
-- This metadata-only statement does not scan blockchain source tables.
-- Always dry-run the exact statement before execution.
--
-- Output grain:
--   Exactly one storage-summary row for YOUR_DATASET_ID.
--
-- Source and source grain:
--   region-us.INFORMATION_SCHEMA.TABLE_STORAGE_BY_PROJECT
--     One metadata row per current or deleted table or materialized view.
--
-- Join keys and expected cardinality:
--   No JOIN is used.
--
-- Filters and boundaries:
--   Only non-deleted objects in dataset YOUR_DATASET_ID are included.
--
-- Row-multiplication risk:
--   None. The output is a scalar aggregation.

SELECT
  COUNT(*) AS active_table_storage_rows,
  SUM(active_logical_bytes) AS active_logical_bytes,
  SUM(total_logical_bytes) AS total_logical_bytes,
  SUM(IF(
    STARTS_WITH(table_name, 'retention_arb_transfer_source_chunk_'),
    active_logical_bytes,
    0
  )) AS transfer_source_active_logical_bytes,
  SUM(IF(
    STARTS_WITH(table_name, 'corrected_claim_transfers_enriched_chunk_'),
    active_logical_bytes,
    0
  )) AS enriched_claim_active_logical_bytes,
  SUM(IF(
    STARTS_WITH(table_name, 'post_claim_transaction_order_batch_'),
    active_logical_bytes,
    0
  )) AS claim_order_active_logical_bytes,
  MAX(storage_last_modified_time) AS latest_storage_modified_at
FROM
  `region-us`.INFORMATION_SCHEMA.TABLE_STORAGE_BY_PROJECT
WHERE
  table_schema = 'YOUR_DATASET_ID'
  AND deleted IS FALSE;

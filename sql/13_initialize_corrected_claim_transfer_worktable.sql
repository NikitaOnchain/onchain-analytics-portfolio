-- Initialize an expiring BigQuery worktable for global corrected-cohort QA.
-- Dry-run before execution.
--
-- Output grain:
--   No analytical output rows. The created table stores one row per decoded
--   candidate claim Transfer event.
--
-- Source tables:
--   None. This script only creates an empty dataset and table.
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Filters and row-multiplication risk:
--   Not applicable during initialization.
--
-- Storage rule:
--   The worktable expires automatically after 30 days. It is a reproducible
--   QA intermediate, not a permanent public data export.

CREATE SCHEMA IF NOT EXISTS `YOUR_DATASET_ID`
OPTIONS (
  location = 'US',
  default_table_expiration_days = 30
);

CREATE OR REPLACE TABLE `YOUR_DATASET_ID.corrected_claim_transfers` (
  chunk_number INT64,
  block_timestamp TIMESTAMP,
  transaction_hash STRING,
  log_index INT64,
  recipient STRING,
  amount_raw BIGNUMERIC
)
CLUSTER BY
  recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
);

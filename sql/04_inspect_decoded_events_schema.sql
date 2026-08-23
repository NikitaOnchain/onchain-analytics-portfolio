-- Inspect the Arbitrum decoded_events schema before choosing a cohort source.
-- This is a metadata query; it does not scan blockchain event rows.
--
-- Purpose:
--   Determine whether the decoded_events table exposes fields that can support
--   a lower-scan HasClaimed cohort materialization query.
--
-- Output grain:
--   One row per column in the decoded_events table schema.
--
-- Source and source grain:
--   bigquery-public-data.goog_blockchain_arbitrum_one_us.INFORMATION_SCHEMA.COLUMNS
--   One metadata row per column per table in the dataset.
--
-- Join keys and expected cardinality:
--   No JOIN.
--
-- Filter:
--   table_name = 'decoded_events'
--
-- Row-multiplication risk:
--   None. The query reads schema metadata only.
--
-- Official source (accessed 2026-08-11):
--   https://docs.cloud.google.com/blockchain-analytics/docs/schema
--
-- Validation run (2026-08-11):
--   Returned 12 schema columns. The table exposes transaction_hash,
--   log_index, event_hash, event_signature, topics, JSON args, and removed.
--   (transaction_hash, log_index) is the candidate event key to validate.

SELECT
  ordinal_position,
  column_name,
  data_type,
  is_nullable
FROM
  `bigquery-public-data.goog_blockchain_arbitrum_one_us.INFORMATION_SCHEMA.COLUMNS`
WHERE
  table_name = 'decoded_events'
ORDER BY
  ordinal_position;

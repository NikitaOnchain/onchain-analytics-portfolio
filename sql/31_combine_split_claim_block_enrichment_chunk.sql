-- Combine validated split enrichment tables into one final two-digit chunk.
-- Always dry-run before execution.
--
-- Output grain:
--   One validated claim Transfer event per row, identified by
--   (transaction_hash, log_index).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05a
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05b
--   Each source has one event-level row in a non-overlapping half-open subrange.
--
-- Join keys and expected cardinality:
--   No JOIN is used. UNION ALL is intentional because the source intervals do
--   not overlap.
--
-- Filters and time boundaries:
--   No additional filters. The sources cover 2023-04-13 through 2023-04-16 and
--   2023-04-16 through 2023-04-19 UTC respectively.
--
-- Row-multiplication risk:
--   UNION ALL preserves every source row. The final profile must verify event
--   key uniqueness, row count, source-match coverage, and amount.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05`
CLUSTER BY
  recipient
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary corrected ARB claim-transfer chunk enriched with claim block number.'
)
AS
SELECT *
FROM `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05a`
UNION ALL
SELECT *
FROM `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_05b`;

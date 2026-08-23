-- Materialize signed ARB Transfer legs for validated claim recipients.
-- Always fresh-dry-run this exact statement before execution.
--
-- Output grain:
--   One claimant endpoint role per decoded ARB Transfer event, uniquely
--   identified by (transaction_hash, log_index, leg_role).
--
-- Source tables and source grain:
--   YOUR_DATASET_ID.retention_arb_transfer_source_chunk_01..29
--     One reconciled ARB Transfer event per (transaction_hash, log_index).
--   YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_01..21
--     One validated claim event and unique recipient per row.
--
-- Join keys and expected cardinality:
--   source.sender = claimants.claimant_address and
--   source.destination = claimants.claimant_address. The claimant set is
--   DISTINCT, so each endpoint JOIN is many-to-one and cannot multiply a role.
--
-- Filters and time boundaries:
--   Source suffixes are limited to final numeric chunks 01 through 29, covering
--   [2023-03-16, 2023-10-25) UTC. Claim suffixes are limited to final numeric
--   chunks 01 through 21. Only positive, already-reconciled source rows enter.
--
-- Row-multiplication risk:
--   UNION ALL intentionally creates one sender leg, one destination leg, or
--   both. The validated expectation is 3,576,012 legs from 3,472,216 events.
--   A self-transfer creates opposite signed legs for the same claimant and must
--   have exact zero net effect in SQL 85 QA.

CREATE OR REPLACE TABLE
  `YOUR_DATASET_ID.retention_arb_claimant_transfer_legs`
CLUSTER BY
  claimant_address,
  block_number
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
  description = 'Temporary signed claimant-address ARB Transfer legs for transfer-derived balance reconstruction.'
)
AS
WITH claimants AS (
  SELECT DISTINCT
    LOWER(recipient) AS claimant_address
  FROM
    `YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*`
  WHERE
    REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{2}$')
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 21
),

source AS (
  SELECT
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
    AND SAFE_CAST(_TABLE_SUFFIX AS INT64) BETWEEN 1 AND 29
)

SELECT
  source.source_chunk_number,
  source.block_timestamp,
  source.block_number,
  source.transaction_hash,
  source.transaction_index,
  source.log_index,
  claimant.claimant_address,
  'sender' AS leg_role,
  source.destination AS counterparty_address,
  source.amount_raw,
  -source.amount_raw AS signed_amount_raw,
  source.sender = source.destination AS is_self_transfer,
  source.source_match_rows
FROM
  source
INNER JOIN
  claimants AS claimant
  ON source.sender = claimant.claimant_address

UNION ALL

SELECT
  source.source_chunk_number,
  source.block_timestamp,
  source.block_number,
  source.transaction_hash,
  source.transaction_index,
  source.log_index,
  claimant.claimant_address,
  'destination' AS leg_role,
  source.sender AS counterparty_address,
  source.amount_raw,
  source.amount_raw AS signed_amount_raw,
  source.sender = source.destination AS is_self_transfer,
  source.source_match_rows
FROM
  source
INNER JOIN
  claimants AS claimant
  ON source.destination = claimant.claimant_address;

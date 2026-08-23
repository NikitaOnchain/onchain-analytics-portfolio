-- Decode one manually verified HasClaimed log without scanning a source table.
--
-- Purpose:
--   Validate recipient and uint256 amount decoding against a known Arbiscan
--   transaction before applying the logic to the full claim dataset.
--
-- Output grain:
--   One row for one manually verified HasClaimed event.
--
-- Source:
--   SQL literals copied from the first validated BigQuery/Arbiscan sample.
--   No blockchain table is scanned by this query.
--
-- Join keys and row-multiplication risk:
--   No JOIN. No row multiplication.
--
-- Decoding notes:
--   The recipient is the last 20 bytes (40 hex characters) of topics[1].
--   The uint256 amount is larger than INT64, so the final 30 hex characters
--   are split into two 15-character chunks. Each chunk fits INT64 and the two
--   chunks are recombined exactly as a BIGNUMERIC value using base 16^15.
--   This two-chunk method is safe for the observed ARB claim range; it is not
--   a general decoder for every possible uint256 value.
--
-- Expected result:
--   recipient        = 0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f
--   amount_raw       = 1625000000000000000000
--   claim_amount_arb = 1625
--
-- Validation run (2026-08-11):
--   The query returned the expected recipient, raw amount, and 1,625 ARB.
--   The result was manually reconciled to the decoded Arbiscan event.
--   Processed bytes were not shown in the captured result screenshot.

WITH sample AS (
  SELECT
    '0x00000000000000000000000027a1b27b2e8bfdd57a3049415dcf6a63ac11667f'
      AS recipient_topic,
    '0x0000000000000000000000000000000000000000000000581767ba6189c40000'
      AS amount_data
),
hex_parts AS (
  SELECT
    CONCAT('0x', RIGHT(recipient_topic, 40)) AS recipient,
    CAST(CONCAT('0x', SUBSTR(RIGHT(amount_data, 30), 1, 15)) AS INT64)
      AS high_chunk,
    CAST(CONCAT('0x', RIGHT(amount_data, 15)) AS INT64)
      AS low_chunk
  FROM sample
),
decoded AS (
  SELECT
    recipient,
    CAST(high_chunk AS BIGNUMERIC)
      * CAST(1152921504606846976 AS BIGNUMERIC)
      + CAST(low_chunk AS BIGNUMERIC) AS amount_raw
  FROM hex_parts
)
SELECT
  recipient,
  amount_raw,
  amount_raw / CAST(1000000000000000000 AS BIGNUMERIC) AS claim_amount_arb
FROM decoded;

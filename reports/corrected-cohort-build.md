# Corrected Claim-Transfer Cohort Build

## Purpose

Build an inspectable event-level working cohort for global recipient-uniqueness
QA after excluding the verified post-claim sweep transaction.

## Sandbox-compatible method

BigQuery Sandbox rejected DML `INSERT` statements because billing is not
enabled. No billing change is required for this project. The working cohort is
instead split into twenty-one expiring CTAS tables, one for each previously
validated non-overlapping interval. Every table:

- has one row per decoded Transfer event;
- records `chunk_number`, timestamp, transaction hash, log index, recipient,
  and raw amount;
- excludes the verified sweep transaction;
- expires after 30 days;
- is created only after a fresh dry run below the 8 GiB planning target.

The global QA query reads the interval tables through the wildcard
`corrected_claim_transfers_chunk_*`. It measures duplicate event keys, repeated
recipients across intervals, critical nulls, event count, timestamp bounds, and
amount without a JOIN.

## Progress

Chunk 1, 2023-03-23 through 2023-03-27 UTC, was dry-run at an upper-bound
estimate of 4,761,802,120 bytes and materialized on 2026-08-13. The wildcard
profile was dry-run at 85,091,360 bytes and returned:

- 531,821 event rows and distinct event keys;
- 531,821 distinct transactions and recipients;
- zero duplicate event keys, repeated recipients, or critical null rows;
- 995,857,625 ARB.

The result exactly matches the previously saved interval profile. Build
progress was 1 of 21 chunks at this checkpoint.

Chunk 2, 2023-03-27 through 2023-04-01 UTC, was dry-run at an upper-bound
estimate of 4,764,410,872 bytes and materialized on 2026-08-13. It contributed
20,277 event rows and 37,387,125 ARB, exactly matching the saved interval
profile. The cumulative wildcard profile was dry-run at 88,335,680 bytes and
returned:

- 552,098 event rows, event keys, transactions, and recipients;
- zero duplicate event keys, repeated recipients across the two intervals, or
  critical null rows;
- 1,033,244,750 ARB;
- a timestamp range from 2023-03-23 13:01:22 UTC through
  2023-03-31 23:59:55 UTC.

Chunk 3, 2023-04-01 through 2023-04-07 UTC, was dry-run at an upper-bound
estimate of 4,757,091,694 bytes and materialized on 2026-08-13. It contributed
7,917 event rows and 14,883,250 ARB, exactly matching the saved interval
profile. The cumulative wildcard profile was dry-run at 89,602,400 bytes and
returned 560,015 event rows, event keys, transactions, and recipients; zero
duplicate event keys, repeated recipients, or critical null rows; and
1,048,128,000 ARB through 2023-04-06 23:59:35 UTC.

## Final materialization result

Chunks 4 through 21 were materialized on 2026-08-13 under the same controls.
Every fresh CTAS dry run remained below the 8 GiB planning limit, and every
cumulative row and amount total matched the saved non-overlapping interval
profiles. The complete dry-run and interval-result log is stored in
`data/corrected_claim_transfer_ctas_runs.json`.

The final wildcard profile was dry-run at 93,301,920 bytes and returned:

- 21 materialized interval tables;
- 583,137 event rows and distinct `(transaction_hash, log_index)` keys;
- 583,131 distinct transactions;
- 583,137 distinct recipients;
- zero duplicate event keys, repeated recipients, or critical null rows;
- a timestamp range from 2023-03-23 13:01:22 UTC through
  2023-09-24 20:12:52 UTC;
- 1,092,811,500 ARB.

After excluding the manually verified post-claim sweep, event count, recipient
count, timestamp bounds, raw amount, and normalized ARB amount all match the
raw `HasClaimed` profile exactly. This completes global structural QA and
recipient-uniqueness testing for the corrected transfer cohort. Broader manual
wallet sampling and an independent reference for the exact aggregate claimed
amount remain separate readiness checks before analytical metrics are treated
as final.

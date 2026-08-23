# Decoded Events Coverage Validation

Last updated: 2026-08-11

## Question

Can the Arbitrum `decoded_events` table replace raw logs when building the ARB airdrop claimer cohort?

## Data and grain

- Source: `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
- Source grain: one decoded event log per row
- Candidate event key: `(transaction_hash, log_index)`
- Joins: none
- Row-multiplication risk: none

## Checks

1. `sql/05_validate_decoded_claim_event.sql` searched the first claim day for decoded events emitted by the TokenDistributor. It returned zero rows. Its dry-run upper-bound estimate was 1,956,863,267 bytes.
2. `sql/06_check_known_claim_decoded_events.sql` searched the same day for a claim transaction already validated manually on Arbiscan, without filtering the emitting contract address. Its dry-run upper-bound estimate was 1,959,425,015 bytes.

## Finding

The known transaction returned one decoded event: the standard ARB token `Transfer(address,address,uint256)` event. Its arguments matched the previously validated claim:

- sender: TokenDistributor `0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9`
- recipient: `0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f`
- raw amount: `1625000000000000000000`
- normalized amount: `1,625 ARB` using 18 decimals

No decoded `HasClaimed(address,uint256)` row was returned for this transaction. The zero-row TokenDistributor result is therefore evidence of missing custom-event decoding in this sample, not an address-casing problem.

## Analytical impact

`decoded_events` is not validated as a direct source of `HasClaimed` events and must not replace the raw-log cohort on that basis. However, decoded ARB `Transfer` events from the TokenDistributor are a promising lower-cost source for an independent cohort and amount reconciliation.

Before using that transfer-based cohort, its recipient count, transaction/event grain, duplicates, critical `NULL` values, timestamp range, and total amount must be compared with the validated raw-log profile of 583,137 recipients and 1,092,811,500 provisional ARB.

## Transfer sample validation

After the project-scoped MCP server became available, `sql/07_validate_claim_transfer_sample.sql` decoded the first ten ARB transfers sent by the TokenDistributor on the first claim day. Its dry-run upper-bound estimate was 1,969,585,194 bytes.

All ten rows had:

- the ARB token contract as the event emitter;
- the standard `Transfer(address,address,uint256)` event hash and signature;
- the TokenDistributor in `args[0]`;
- a populated recipient in `args[1]`;
- a numeric raw amount in `args[2]` that normalized cleanly using 18 decimals.

The ten rows represented ten distinct transaction hashes and ten distinct recipients. Three rows had a non-zero `log_index`, reinforcing that `(transaction_hash, log_index)` is the appropriate event-grain candidate key. Observed normalized amounts ranged from 875 to 4,000 ARB.

This is a successful structural sample, not full cohort validation. Duplicate, `NULL`, coverage, timestamp, and aggregate reconciliation checks remain required.

## First-day transfer profile

`sql/08_profile_first_day_claim_transfers.sql` profiled all decoded ARB transfers
sent by the TokenDistributor on 2023-03-23 UTC. The dry-run upper-bound estimate
was 1,598,772,128 bytes.

The query returned:

- 422,480 transfer events;
- 422,480 distinct `(transaction_hash, log_index)` candidate keys;
- 422,480 distinct transactions;
- 422,480 distinct recipients;
- no duplicate event keys or recipients with multiple events;
- no critical `NULL`, malformed recipient, or invalid amount rows;
- an observed interval from 2023-03-23 13:01:22 UTC through 23:59:59 UTC;
- 802,591,375 ARB in decoded transfers.

These results support the structural quality of the transfer-based source for
the first claim day. They do not independently establish full coverage or
equivalence to `HasClaimed`.

## First-day aggregate reconciliation

`sql/09_profile_first_day_claim_events.sql` applied the identical UTC window
and `removed IS NOT TRUE` rule to raw `HasClaimed` logs. Its dry-run upper-bound
estimate was 4,434,291,625 bytes.

The raw-event and decoded-transfer profiles matched on every compared
aggregate:

| Check | Raw `HasClaimed` | Decoded ARB `Transfer` | Difference |
| --- | ---: | ---: | ---: |
| Event rows | 422,480 | 422,480 | 0 |
| Distinct transactions | 422,480 | 422,480 | 0 |
| Distinct recipients | 422,480 | 422,480 | 0 |
| Total ARB | 802,591,375 | 802,591,375 | 0 |

Both sources also had the same observed timestamp bounds, from
2023-03-23 13:01:22 UTC through 23:59:59 UTC, and neither profile contained
duplicate candidate event keys, repeated recipients, or critical invalid
values.

This is an exact aggregate match with high confidence. The remaining risk is
that equal aggregates can theoretically hide different individual rows.
Row-level set reconciliation of transaction hash, recipient, and raw amount is
therefore required before the transfer-based source is marked analysis-ready.

## First-day row-level reconciliation

`sql/10_reconcile_first_day_claim_sources.sql` compared distinct
`(transaction_hash, recipient, amount_raw)` tuples in both directions with
`EXCEPT DISTINCT`. `log_index` was excluded because `HasClaimed` and `Transfer`
are separate logs within the same transaction. The query used no joins, so it
had no join-related row-multiplication risk. Its dry-run upper-bound estimate
was 5,950,498,852 bytes.

The result was an exact set match:

- 422,480 raw claim rows and 422,480 distinct raw tuples;
- 422,480 decoded transfer rows and 422,480 distinct transfer tuples;
- zero raw-only tuples;
- zero transfer-only tuples;
- zero duplicate tuples in either source;
- `exact_set_match = true`.

This validates decoded ARB transfers from the TokenDistributor as an equivalent
claim source for the first UTC claim day, with high confidence. The validation
scope is limited to 2023-03-23 UTC; coverage across the remaining claim window
must be assessed before using decoded transfers as the complete cohort source.

## Evidence

- Query: `sql/05_validate_decoded_claim_event.sql`
- Control query: `sql/06_check_known_claim_decoded_events.sql`
- Saved control row: `data/known_claim_decoded_events.json`
- Transfer sample query: `sql/07_validate_claim_transfer_sample.sql`
- Saved transfer sample: `data/claim_transfer_sample.json`
- First-day profile query: `sql/08_profile_first_day_claim_transfers.sql`
- Saved first-day profile: `data/first_day_claim_transfer_profile.json`
- Raw first-day query: `sql/09_profile_first_day_claim_events.sql`
- Saved raw first-day profile: `data/first_day_claim_event_profile.json`
- Saved aggregate reconciliation: `data/first_day_source_reconciliation.json`
- Row-level reconciliation query: `sql/10_reconcile_first_day_claim_sources.sql`
- Saved row-level reconciliation: `data/first_day_row_level_reconciliation.json`
- Manual transaction reference: https://arbiscan.io/tx/0x324f2ef46287a4f51a70e2a17ecd9a68af8f4c94c1eed0da16fa1e20992cb15a

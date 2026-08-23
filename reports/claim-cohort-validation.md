# ARB Claim Cohort Validation

Validation date: 2026-08-11

## Scope and grain

The validation profiles `HasClaimed` logs emitted by the confirmed Arbitrum One `TokenDistributor` from 2023-03-23 through 2023-09-30 UTC. The source grain is one emitted event log. The profiling query returns one aggregate quality-control row and does not join any tables.

Query: `sql/03_profile_claim_cohort.sql`

Saved result: `data/claim_cohort_profile.json`

## Results

| Check | Observed value | Interpretation |
|---|---:|---|
| Claim event rows | 583,137 | Matching decoded `HasClaimed` logs |
| Distinct recipients | 583,137 | One event per recipient in the observed cohort |
| Recipients with multiple events | 0 | No recipient-level duplicates detected |
| Distinct claim transactions | 583,131 | Transaction hash is not unique at event grain |
| Invalid or null recipients | 0 | Recipient decoding passed for all rows |
| Invalid or null amounts | 0 | Amount decoding passed for all rows |
| Null transaction hashes | 0 | Transaction hash is populated for all rows |
| First observed claim | 2023-03-23 13:01:22 UTC | Earliest matching event in the bounded window |
| Last observed claim | 2023-09-24 20:12:52 UTC | Latest matching event in the bounded window |
| Provisional claimed amount | 1,092,811,500 ARB | Requires an independent exact-value reconciliation |

## Findings

The observed recipient grain is clean: event rows equal distinct recipients, no recipient appears more than once, and all critical decoded fields are populated. This supports using the decoded recipient as the candidate key for the claimer cohort.

Transaction hash must not be used as a unique event key. There are six more claim events than distinct transaction hashes. This proves that at least one transaction emitted multiple matching claim events, but the aggregate result does not reveal whether the difference came from one transaction with seven events, six transactions with two events each, or another combination. The affected transactions require a bounded follow-up inspection.

The total claimed amount remains provisional even though all amount values decoded successfully. Recipient count is independently consistent with the 583,137 Arbitrum claimers reported in Dragonfly's 2025 airdrop report hosted by the U.S. Securities and Exchange Commission. An exact independent token-amount reconciliation is still pending.

## Query cost

The run processed and billed 357.92 GB and completed in approximately nine seconds. Google Blockchain Analytics tables use monthly partitions on `block_timestamp`, so the timestamp predicate pruned history outside March through September 2023. The public `logs` table did not provide an index for the contract-address and event-topic filters, so BigQuery still examined the selected monthly partitions.

This run consumed a substantial portion of the BigQuery Sandbox monthly processed-data allowance. The full query should not be rerun casually. A reusable filtered cohort or a smaller confirmed source must be planned before another broad blockchain-table scan.

## Validation status

- Recipient uniqueness: passed.
- Critical-field completeness and decoding: passed.
- Manual validation of one event: passed separately.
- Independent recipient-count comparison: passed.
- Multi-event transaction inspection: pending.
- Exact claimed-amount reconciliation: pending.

## Sources

- [Google Blockchain Analytics schema](https://docs.cloud.google.com/blockchain-analytics/docs/schema)
- [Arbitrum Foundation TokenDistributor source](https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol)
- [Dragonfly State of Airdrops report hosted by the SEC](https://www.sec.gov/files/dragonflys-state-airdrops-report-2025.pdf)
- [BigQuery Sandbox limits](https://docs.cloud.google.com/bigquery/docs/sandbox)

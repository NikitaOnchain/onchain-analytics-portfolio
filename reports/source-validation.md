# ARB Airdrop Source Validation

Last accessed: 2026-08-11

## Validation status

The claim contract and event definition are confirmed from official sources, matched against Google Blockchain Analytics raw logs, checked manually for one sampled transaction in Arbiscan, and reproduced with a literal-only BigQuery decoding test. A broader manual sample is still pending.

## Claim contract

- Network: Arbitrum One
- Contract: `TokenDistributor`
- Address: `0x67a24CE4321aB3aF51c2D0a4801c3E111D88C9d9`
- Lowercase form used in Google Blockchain Analytics: `0x67a24ce4321ab3af51c2d0a4801c3e111d88c9d9`

Arbitrum DAO's finalized AIP-7 states that the DAO airdrop was distributed through the `TokenDistributor` contract and links this address on Arbiscan.

## Claim event

The official Arbitrum Foundation governance repository defines:

```solidity
event HasClaimed(address indexed recipient, uint256 amount);
```

Canonical event signature:

```text
HasClaimed(address,uint256)
```

Computed `topic0`:

```text
0x8629b200ebe43db58ad688b85131d53251f3f3be4c14933b4641aeebacf1c08c
```

The topic was computed as the Keccak-256 hash of the canonical signature. The implementation was checked against the canonical ERC-20 `Transfer(address,address,uint256)` topic before calculating this value.

## Log encoding

- `topics[0]`: `HasClaimed(address,uint256)` signature hash
- `topics[1]`: indexed `recipient`, left-padded to 32 bytes
- `data`: unindexed `amount`, ABI-encoded as `uint256`

Both `claim()` and `claimAndDelegate()` lead to this event because `claimAndDelegate()` calls `claim()`, while `claim()` transfers the tokens and emits `HasClaimed`.

The raw amount is converted into display units only after the distributed token address and token decimals are independently verified below.

## Authoritative sources

- [AIP-7: Arbitrum One Governance Parameter Fixes](https://forum.arbitrum.foundation/t/aip-7-arbitrum-one-governance-parameter-fixes/15920)
- [Arbitrum Foundation governance: TokenDistributor.sol](https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol)
- [Google Blockchain Analytics: Arbitrum schema](https://docs.cloud.google.com/blockchain-analytics/docs/schema)
- [Google Blockchain Analytics: Arbitrum query examples](https://docs.cloud.google.com/blockchain-analytics/docs/example-arbitrum)

## BigQuery log validation

Validation date: 2026-08-11

Query: `sql/01_validate_claim_event.sql`

- Estimated processing: 3.86 GB
- Actual processing and billed volume: 3.71 GB
- Displayed rows: 10
- The returned contract address matched the expected `TokenDistributor`.
- Every displayed `event_topic0` matched the computed `HasClaimed(address,uint256)` topic.
- The displayed sample contained populated recipient topics and raw amount data.

The execution plan's intermediate row counts are not a count of all claim events. The query uses `ORDER BY ... LIMIT 10`, so BigQuery can reduce intermediate top-N candidates before producing the ten displayed rows. A separate aggregate query is required to count claims.

## Manual explorer validation

Validation date: 2026-08-11

Sample transaction:

```text
0x324f2ef46287a4f51a70e2a17ecd9a68af8f4c94c1eed0da16fa1e20992cb15a
```

Arbiscan showed:

- transaction status: success;
- interacted contract: `0x67a24CE4321aB3aF51c2D0a4801c3E111D88C9d9` (`TokenDistributor`);
- decoded event: `HasClaimed(address indexed recipient, uint256 amount)`;
- recipient: `0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f`;
- raw amount: `1625000000000000000000`;
- token transfer display: `1,625 ARB` to the same recipient.

This matches the first BigQuery sample row after removing the 12-byte zero padding from the indexed recipient topic and interpreting the event data as an unsigned integer. The token contract and decimal precision are independently confirmed below.

## SQL decoding validation

Validation date: 2026-08-11

Query: `sql/02_decode_claim_sample.sql`

The literal-only query returned one row at the intended grain of one manually verified `HasClaimed` event:

- recipient: `0x27a1b27b2e8bfdd57a3049415dcf6a63ac11667f`;
- raw amount: `1625000000000000000000`;
- display amount: `1625 ARB`.

All three values matched the decoded Arbiscan event. The query has no source table and no join, so this test has no join-driven row-multiplication risk. The captured result screenshot did not show the job's processed-byte field, so no observed processing volume is recorded for this validation run.

## Distributed token

- Token: Arbitrum (`ARB`)
- Arbitrum One contract: `0x912ce59144191c1204e64559fe8253a0e49e6548`
- Decimals: `18`

The Arbiscan token page identifies this contract and decimal precision. The sampled claim transaction independently displays a transfer of 1,625 ARB from the `TokenDistributor` to the event recipient. The raw event amount therefore converts as:

```text
1625000000000000000000 / 10^18 = 1625 ARB
```

The ARB contract address is also referenced by finalized Arbitrum DAO materials, including the [Arbitrum Research & Development Collective proposal](https://forum.arbitrum.foundation/t/proposal-non-constitutional-establish-the-arbitrum-research-development-collective/19899).

## Remaining validation

1. Expand manual inspection beyond one transaction during cohort QA.
2. Test uniqueness and duplicates at the intended claimer-cohort grain.
3. Reconcile aggregate claim counts and amounts with an independent reference.

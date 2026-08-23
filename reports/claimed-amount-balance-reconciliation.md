# Claimed-Amount Balance Reconciliation

## Question

Can the exact `1,092,811,500 ARB` claimed aggregate be reproduced without
summing `HasClaimed` events or the corrected outbound claim-transfer cohort?

## Method

The alternative calculation uses the TokenDistributor's ARB balance equation:

```text
initial distributor funding
+ positive ARB transfers returned to the distributor
- final verified sweep
= ARB distributed through claims
```

The initial funding and return inflows were read from decoded ERC-20 `Transfer`
events where the ARB TokenDistributor was the recipient. The final sweep was
the separately verified post-claim transfer to the configured sweep receiver.
The calculation does not sum `HasClaimed` events and does not use corrected
outbound claim rows as an arithmetic input.

The incoming-transfer source has decoded-event grain. Its candidate key is
`(transaction_hash, log_index)`. The interval profiles use no JOIN, retain
zero-value events for QA, and sum only positive amounts. Non-overlapping UTC
intervals prevent cross-interval row overlap.

## Results

| Balance component | ARB |
|---|---:|
| Initial positive funding | 1,162,166,000 |
| Positive return inflows after claims started | 93,885.458006064728014866 |
| Final verified sweep | (69,448,385.458006064728014866) |
| **Balance-derived claims** | **1,092,811,500** |

The equation closes exactly at raw-token precision:

```text
1,162,166,000
+ 93,885.458006064728014866
- 69,448,385.458006064728014866
= 1,092,811,500 ARB
```

This also explains why subtracting the final sweep directly from initial
funding would be wrong. The sweep contained both `69,354,500 ARB` of unclaimed
funded allocation and `93,885.458006064728014866 ARB` later transferred back
to the distributor.

Across the return-inflow scan, 71 positive events occurred in 71 transactions.
No duplicate event keys, critical key `NULL` values, or invalid amounts were
observed. The 22 effective interval jobs were fresh-dry-run below the 8 GiB
planning target; the largest estimate was 8,511,515,874 bytes.

## Public-source comparison

Exact-number searches across Arbitrum Foundation materials, governance GitHub,
the governance forum, and the broader web did not identify an independently
published `1,092,811,500 ARB` total as of 2026-08-13.

An Arbitrum governance-forum RFC published immediately after the claim period
reported that 94% of approximately 1.162 billion user-airdrop ARB had been
claimed. The exact onchain rate from the funded allocation is
`94.0323069165678569%`, which is consistent with that public approximation but
does not turn the RFC into an exact-value reference:

https://forum.arbitrum.foundation/t/rfc-reallocate-unclaimed-airdrop-tokens-for-future-incentives/17027

The Arbitrum Foundation separately documents that users and sweeper bots sent
ARB to the token or distributor address. This supports treating the positive
inflows as returned tokens rather than additional airdrop funding:

https://support.arbitrum.io/hc/en-gb/articles/19477765689755-ARB-tokens-sent-to-Arbitrum-Foundation

The final sweep amount, destination, timestamp, successful status, and
`sweep()` call are independently visible in Arbiscan:

https://arbiscan.io/tx/0xa2477f2f1d7824501520a88b50835ad283e7472e0fa5e67005452528bf740175

The initial funding and one returned-transfer row are linked for record-level
traceability:

- https://arbiscan.io/tx/0x62c2c34187fde29352b58edd37b0e69f7a6b7ab34699dca957f88229b501ce7c
- https://arbiscan.io/tx/0x25c7f9fd2b0c7f2c8520c7ea2b132f0e51cb38464fc2f992f5dbb1ad61c3f735

## Assessment

The exact claimed aggregate is validated through three agreeing paths:

1. raw `HasClaimed` events;
2. the corrected outbound ARB Transfer cohort;
3. the distributor balance equation using initial funding, returned inflows,
   and the verified final sweep.

The first two paths match on event count, recipient count, timestamp bounds,
and amount. The third path matches the amount exactly without using either
claim-event sums or outbound claim rows as its arithmetic input. The cohort is
therefore analysis-ready for derived early-outflow and retention metrics.

Required caveat: both exact onchain derivations use Google Blockchain
Analytics as the machine-readable provider. The explorer and public materials
provide record-level and magnitude corroboration, but no independently
published exact aggregate was found.

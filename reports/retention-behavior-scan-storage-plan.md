# Retention and Post-claim Behavior: Scan and Storage Plan

Prepared: 2026-08-20; storage checkpoint updated 2026-08-22  
Status: full ARB Transfer source reconciled; claim-grain balance assembly next

## Purpose

This plan extends the validated 24-hour and seven-day baselines into a
30-day retention and behavior analysis without changing the validated
definitions or rerunning completed cohort, early-outflow, or seven-day
address-activity calculations.

The new phase keeps four analytical concepts separate:

1. **Token retention**: a transfer-derived ARB balance or an explicitly named
   proxy at an elapsed cutoff.
2. **Address activity**: successful top-level transactions initiated by the
   claim recipient.
3. **Protocol engagement**: qualifying address activity mapped to a verified
   protocol category.
4. **Human retention**: not directly observable from the available onchain
   data and therefore not claimed.

## Protected validated inputs

The following results are read-only inputs to the new phase:

- 583,137 unique claim recipients and 1,092,811,500 claimed ARB;
- the validated 24-hour and seven-day early-outflow metrics in
  `data/full_early_outflow_metrics.json`;
- the validated 24-hour and seven-day address-activity metrics in
  `data/post_claim_activity_full_cohort_profile.json`;
- the six existing publication figures and their chart-data QA artifacts.

No completed public-table calculation is rerun unless a new, documented QA
failure proves that the saved result is unsafe to reuse.

## Source inventory and constraints

Google Blockchain Analytics exposes five Arbitrum One tables: `blocks`,
`decoded_events`, `logs`, `receipts`, and `transactions`. It does not expose a
historical ARB balance table. All five tables are monthly partitioned on
`block_timestamp`; addresses are lowercase. Source metadata was checked on
2026-08-22.

The 2026-08-22 metadata checkpoint found 84 expiring tables. Saved table
metadata and the exact 29 transfer-chunk sizes imply 1.84121 GB
(approximately 1.715 GiB) of active logical data, leaving approximately
6.285 GiB before the internal 8 GiB storage target. The 29 reconciled transfer
chunks occupy 819,442,976 bytes. The tables expire between 2026-09-14 and
2026-09-20. The `TABLE_STORAGE_BY_PROJECT` metadata view is not available to
the current Sandbox credentials, so the storage total is a tracked metadata
estimate with a maximum uncertainty of 3,776 bytes rather than a query result.

Project guardrails:

- hard per-query limit: 10 GiB;
- planning target: at most 8 GiB per exact query;
- every exact statement receives a fresh dry run immediately before execution;
- a statement above 8 GiB is split before execution;
- a statement above 10 GiB is never executed;
- active working storage should remain below 8 GiB, leaving at least 2 GiB of
  headroom below the Sandbox storage boundary previously encountered;
- no billing configuration is changed.

## Coverage windows

| Layer | Source coverage | Reason |
|---|---|---|
| Claim cohort | Existing validated 2023-03-23 through 2023-09-24 claim events | Read-only cohort spine |
| Transfer-derived ARB balance | Validated `[2023-03-16, 2023-10-25)` UTC | Covers the independently reconciled first mint/Transfer boundary through the final claim plus 30 elapsed days |
| Symmetric address activity | `[2023-02-21, 2023-10-25)` UTC | Covers 30 elapsed days before the earliest claim and 30 elapsed days after the latest claim |
| Protocol classification | Same transaction coverage as symmetric activity | Keeps target/function classification aligned to exact pre/post rows |

All per-recipient analytical windows are half-open. Pre-claim activity uses
`[claim_timestamp - 30 days, claim order)`. Post-claim activity uses strict
event order after the exact claim transaction and
`[claim_timestamp, claim_timestamp + 30 days)`. The exact claim transaction is
excluded from both activity periods.

## Chunk schedule

The audited canonical schedule contains 34 non-overlapping UTC chunks for
transactions and 29 for ARB transfers. It reuses previously safe calendar
boundaries where possible, but **none of the old byte estimates is reused**.
Every new statement has different selected columns or filters and must receive
a fresh dry run.

Additional transaction-only chunks cover:

- `[2023-02-21, 2023-02-25)`;
- `[2023-02-25, 2023-03-01)`;
- `[2023-03-01, 2023-03-04)`;
- `[2023-03-04, 2023-03-08)`;
- `[2023-03-08, 2023-03-16)`;
- `[2023-03-16, 2023-03-23)`.

The original `[2023-03-01, 2023-03-08)` attempt passed the scan limits but
failed the conservative active-storage projection. It is historical only and
is archived as `storage_projection_blocked`; it is not a canonical chunk and
cannot authorize materialization.

The shared middle schedule uses the 24 validated source intervals from
`[2023-03-23, 2023-10-02)`. Four final chunks cover
`[2023-10-02, 2023-10-09)`, `[2023-10-09, 2023-10-16)`,
`[2023-10-16, 2023-10-23)`, and `[2023-10-23, 2023-10-25)`.

ARB transfer reconstruction starts with `[2023-03-16, 2023-03-23)` and then
uses the shared middle and final schedules. All 29 chunks have now passed
per-chunk QA and full-source reconciliation at 3,472,216 unique event rows.

## Layer 1: transfer-derived ARB balance and retention

### Source grain and transformation

`decoded_events` is filtered to the verified ARB token contract and
`Transfer(address,address,uint256)` events. The source grain is one decoded log
identified by `(transaction_hash, log_index)`. Public duplicates are collapsed
at that key while retaining a `source_match_rows` control.

Each event can create up to two address legs:

- `+amount_raw` for a cohort recipient in the destination role;
- `-amount_raw` for a cohort recipient in the sender role.

This one-to-at-most-two multiplication is intentional. A self-transfer creates
equal positive and negative legs and must reconcile to net zero. Claim-recipient
uniqueness prevents one address leg from matching multiple claims.

Exact event order uses `(block_number, transaction_index, log_index)`. The
claim Transfer itself is excluded from `pre_claim_balance_raw` and included in
the post-claim balance path. Cutoff balances include transfer legs strictly
before `claim_timestamp + 7 days` or `claim_timestamp + 30 days`.

### Planned metrics

- `pre_claim_arb_balance_raw`;
- `transfer_derived_arb_balance_raw_7d`;
- `transfer_derived_arb_balance_raw_30d`;
- total balance-to-claim ratios at 7d and 30d;
- pre-claim-adjusted retained-claim proxy at 7d and 30d, capped to
  `[0, claim_amount]`;
- mutually exclusive total balance-to-claim buckets:
  `0%`, `(0%, 25%)`, `[25%, 75%)`, `[75%, 100%]`, and `>100%`.

The total balance-to-claim ratio is not called exact airdropped-token
retention because ARB is fungible and some wallets held ARB before claiming.
The pre-claim-adjusted measure is also a proxy because unrelated post-claim
inflows and outflows cannot be assigned to specific token units.

### Promotion rule

The public report may use **historical ARB balance** only if all of the
following pass:

1. the first ARB Transfer/mint boundary is proven;
2. decoded Transfer rows reconcile to bounded raw logs;
3. cumulative balances never become negative at event checkpoints;
4. a deterministic wallet sample reconciles event-by-event;
5. at least one independent historical `balanceOf` or equivalent explorer
   balance checkpoint is reproduced.

If item 5 is unavailable, the public metric remains
**transfer-derived ARB balance proxy**.

## Layer 2: symmetric pre/post address activity

The transaction source grain is one successful top-level transaction per
transaction hash. `receipts` supplies success, sender, target and transaction
order; `blocks` supplies block number; `transactions` supplies the bounded
input needed for the function selector. Each public source is pre-aggregated
to its intended key and retains match counts before joining.

For every recipient, calculate the following over 30 elapsed days before and
after the exact claim:

- successful transaction count;
- active UTC-day count;
- distinct target count;
- distinct verified protocol count.

Recipients are split into `previously inactive` (zero qualifying transactions
in the pre window) and `previously active` (one or more). The comparison is
paired at recipient grain. To address calendar-time differences, results are
also summarized by claim week and claim month; overall pre/post differences
are reported alongside the distribution of within-claim-week differences.
Early and late claimers are not assumed to face the same network environment.

## Layer 3: protocol classification

Classification occurs at transaction grain using the top-level target address
and function selector. The required categories are:

- `DEX`;
- `bridge`;
- `lending`;
- `NFT/gaming`;
- `governance`;
- `transfer-only`;
- `other`;
- `unknown`.

`transfer-only` is restricted to a direct top-level ARB token call with a
verified ERC-20 transfer selector and no higher-priority verified protocol
target. A transaction is not inferred to be a protocol interaction merely
because it emitted an ARB Transfer.

The label registry is a versioned public artifact with address, category,
protocol name, chain, evidence URL, evidence type, and access date. Only
official protocol documentation, official deployment repositories, verified
contract source/explorer pages, or another reproducible primary source is
accepted. Conflicts remain `unknown` until resolved.

Coverage is measured as the share of qualifying transaction rows mapped to a
verified non-unknown category. The target is 90–95%, not a forced result.
Unverified residual rows remain `unknown` and their share is published.

## Layer 4: joint behavioral groups

At exact claim-recipient grain and separately for 7d and 30d, define two
binary signals:

- any positive non-self ARB outflow after exact claim order;
- any verified non-transfer protocol activity.

Their cross-product produces `outflow only`, `non-outflow protocol activity
only`, `both`, and `neither`. `Unknown` activity does not become protocol
engagement. This means `neither` is not synonymous with an inactive address.

Each group is compared descriptively on pre-claim activity, claim amount,
transfer-derived balance-to-claim ratio, and retained-claim proxy.

## Robust statistics

Activity depth is summarized with median, P75, P90, and a high-frequency
concentration measure. The high-frequency threshold is the observed P90 count
for the relevant window and segment; ties are retained, so the recipient share
can exceed 10%. Both the recipient share and the share of transaction rows
generated by that group are reported. Means may remain as secondary context,
not the primary depth statistic.

All claim-size comparisons are descriptive. No causal language is supported.

## Storage lifecycle

The pipeline uses bounded, recoverable staging:

1. Materialize one source chunk with 30-day expiration.
2. Run source-grain QA and a bounded reconciliation.
3. Convert it into compact claim-grain partials and, for protocol discovery,
   compact target/function counts.
4. Save the fresh dry-run bytes, row counts, QA result and exact SQL in a
   machine-readable progress artifact.
5. Remove only the recoverable large source chunk after its compact outputs
   and recovery evidence are verified.

The validated cohort, claim-order tables, existing metric tables, compact new
partials, label registry, final claim-grain outputs, QA summaries and
deterministic samples are preserved until the public artifacts are rebuilt.

## QA gates for every new layer

- intended row grain and duplicate count;
- critical `NULL` fields and invalid decoded amounts/addresses;
- exact source match counts and join cardinality;
- expected intentional row multiplication only;
- half-open window and exact event-order checks;
- source-to-partial and partial-to-final row/amount reconciliation;
- non-overlapping chunk coverage and cross-chunk duplicate checks;
- deterministic wallet samples with stored selection rules;
- bounded raw-source validation;
- an independent public or explorer comparison where available.

No retention, protocol, joint-group, or 30-day activity metric is considered
analysis-ready until its corresponding machine-readable QA artifact passes.

## Planned SQL sequence

The next available SQL range is reserved as follows; filenames may be split
further when a fresh dry run requires smaller chunks.

| Range | Purpose |
|---|---|
| 77–82 | first-transfer probe, claimant-related ARB Transfer chunks, source QA and compact balance partials |
| 83–86 | full retention assembly, distribution, deterministic samples and reconciliation |
| 87–91 | symmetric 30-day transaction chunks, compact pre/post partials and calendar-cohort QA |
| 92–95 | target/function discovery, verified label coverage and classified transaction partials |
| 96–99 | joint behavioral groups, robust statistics, chart export and final QA |

## Immediate execution gate

The next technical action is limited to one compact claim-grain balance layer:

1. reuse the four validated compact claim-order batches rather than rescanning
   the removed transaction-source chunks;
2. expand the reconciled Transfer source to signed address legs only inside the
   query, then aggregate directly to one row per unique claim recipient;
3. fresh-dry-run the exact statement and require 3,576,012 legs plus zero net
   effect across all 1,484 self-transfers in follow-up QA.

No data-producing query is authorized by this plan unless its own fresh dry
run is below the configured 10 GiB hard limit.

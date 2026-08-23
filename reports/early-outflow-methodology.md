# Early-Outflow Methodology Draft

## Analytical meaning

`Early outflow` means a positive ARB `Transfer` sent by a claim recipient after
the recipient's claim event. It does not mean a sale. A DEX swap or a transfer
to a reliably labeled exchange address must be demonstrated separately before
using sale-related language.

The initial reporting windows will be:

- 24 hours after each exact claim time, for immediate movement;
- 7 x 24 hours after each exact claim time, for broader early movement.

Both windows are elapsed-time windows, not UTC calendar-day buckets.

## Intended recipient-level metrics

- `gross_positive_outflow`: sum of positive ARB transfers sent in the window;
- `claim_linked_outflow_proxy`: the lesser of gross outflow and claim amount;
- `claim_linked_outflow_ratio`: capped proxy divided by claim amount;
- `seconds_to_first_positive_outflow`;
- count of positive outflow events and transactions.

Gross outflow remains visible because a wallet can send more than its claim
after receiving other ARB. The capped measure is only a conservative
claim-linked proxy. ARB is fungible, so the query cannot prove which specific
token units moved.

Self-transfers and zero-value transfers are excluded from positive outflow.
Destinations remain unclassified until separate evidence supports a DEX,
exchange, bridge, staking, treasury, burn, or other label.

## Grain and joins for the full cohort

The output grain will be one row per claim recipient per measurement window.
The claim cohort has one row per recipient. The ARB Transfer source has one row
per decoded event log, keyed by `(transaction_hash, log_index)`.

The join from claims to outgoing transfers is expected to be one-to-many on
`claim.recipient = transfer.sender`. This intentionally multiplies a claim row
before the final recipient aggregation. Required controls are:

- validate claim-side recipient uniqueness before the join;
- validate decoded-event key uniqueness;
- compare claim recipients before and after a LEFT JOIN;
- aggregate transfer amounts only after filtering positive non-self events;
- retain claimants with no matched positive outflow as zero-outflow rows.

## Event ordering

Timestamp-only ordering is not sufficient for a final full-cohort query because
separate transactions in the same block share a block timestamp. The corrected
working cohort currently stores claim timestamp and claim-transfer log index
but not claim block number.

Before scaling, each claim must be enriched with the `block_number` of its
already validated claim Transfer event using the exact
`(transaction_hash, log_index)` key. Candidate outflows can then be required to
occur in a later block or at a greater log index in the same block. The public
`transactions` table exposes transaction index but not block number, so it
cannot provide the complete ordering key by itself.

## One-recipient validation

The first manually validated claimant received `1,625 ARB` at
2023-03-23 13:01:22 UTC. The 24-hour source query returned four outgoing
Transfer events:

- two zero-value events, which must not count as outflow;
- `10 ARB` at 14:12:53 UTC;
- `1,615 ARB` at 15:49:41 UTC.

The first positive outflow occurred 4,291 seconds after claim. Gross positive
outflow and the capped claim-linked proxy both equal `1,625 ARB`, producing a
ratio of `1.0`. Duplicate event keys, critical `NULL` values, and invalid
amounts were all zero.

This is a methodology check for one recipient, not a cohort-level result. The
two destination addresses remain unclassified, and neither transfer is called
a sale.

## Block-number enrichment checkpoint

The one-to-one enrichment path was validated for corrected cohort chunk 1.
The public source was pre-aggregated at `(transaction_hash, log_index)` before
a LEFT JOIN so duplicate source rows could not silently multiply claims.

The fresh dry run estimated 4,965,233,644 bytes. Execution returned 531,821
claim rows and 531,821 distinct event keys. Every claim had exactly one source
match and a non-null `block_number`; unmatched rows, multiple matches, source
duplicate keys, timestamp mismatches, recipient mismatches, and amount
mismatches were all zero. Claim blocks ranged from 72,829,612 to 74,036,108.

The validated JOIN was then materialized as an expiring chunk-01 table after a
fresh dry run of 4,930,844,487 bytes. The materialized profile processed an
upper-bound estimate of 93,600,496 bytes and returned 531,821 rows at 531,821
distinct event keys, with zero duplicate rows, critical `NULL` values, missing
source matches, or non-one-to-one source matches. It retained the expected
block range and exactly 995,857,625 ARB.

Chunk 1 therefore validates both the enrichment logic and the temporary CTAS
pattern. The next step is to apply it to chunks 2 through 21, with a fresh dry
run and per-chunk QA before any cohort-level early-outflow calculation.

## Full-cohort block enrichment

The same pattern was applied to all 21 corrected claim chunks. Fresh dry runs
for chunks 5 and 13 exceeded the 8 GiB planning target, so neither unsplit query
was executed. Each was divided into two non-overlapping time ranges, profiled
separately, and recombined locally with `UNION ALL`; the final two-digit chunk
tables then matched their original row and amount controls.

The global enriched-cohort profile processed an upper-bound estimate of
107,297,208 bytes. It returned 21 final chunk tables, 583,137 event rows and
distinct event keys, 583,131 transactions, and 583,137 distinct recipients.
Duplicate event keys, repeated recipients, critical `NULL` values, missing
source matches, non-one-to-one source matches, and chunk-suffix mismatches were
all zero. Claim blocks ranged from 72,829,612 to 134,244,706, and the total
remained exactly 1,092,811,500 ARB.

The corrected cohort is therefore ready for bounded early-outflow query design
with block-aware event ordering. No cohort-level early-outflow metric has been
computed yet.

## Bounded chunk-21 validation

A bounded seven-day event table was materialized for corrected claim chunk 21
after a fresh dry run of 5,281,079,230 bytes. It contains 821 unique positive
non-self ARB outflow events in 804 transactions for 610 claim recipients.
Duplicate event keys, critical `NULL` values, source-match failures, nonpositive
amounts, self-transfers, event-order violations, and time-window violations were
all zero. Seven events occurred later in the same block as their claim.

The event table was aggregated locally to 1,209 claim-grain rows, retaining
claimants with no qualifying event. Grain, `NULL`, negative-value, window
monotonicity, capped-proxy domain, and first-outflow timing checks all passed.
Within this bounded chunk, 569 recipients had a positive event within 24 hours
and 610 within seven days. The corresponding event counts were 711 and 821.
The chunk claimed 2,590,750 ARB. Gross positive outflow was
1,007,257.350966486358529813 ARB within 24 hours and
1,138,277.717500594771217579 ARB within seven days; capped claim-linked proxies
were 987,875.785036085206521183 and 1,089,873.668510571146382181 ARB.

A deterministic five-wallet sample covered zero outflow, outflow only after 24
hours, one event, multiple events, and gross outflow above the claim amount.
Event sums reconciled to every sampled wallet's stored metrics. A separate
same-block control found a contract claimant whose claim Transfer had log index
0 and subsequent outflow had log index 3 in the same transaction and block,
with both timestamps equal. This confirms why timestamp-only ordering is not
sufficient.

These numbers validate the method on chunk 21 only. They are not full-cohort
findings, destinations remain unclassified, and none of the transfers is called
a sale.

## Reusable claimant ARB Transfer source

The full source window was divided into 24 non-overlapping half-open UTC
intervals covering 2023-03-23 through 2023-10-02. Each query pre-aggregated the
decoded source at `(transaction_hash, log_index)`, joined `sender` many-to-one
to the 583,137 unique validated claim recipients, and retained only positive
non-self ARB Transfers. Every exact CTAS query was freshly dry-run below the
8 GiB planning target before execution.

Per-chunk QA found zero duplicate event keys, critical `NULL` values,
non-one-to-one decoded-source matches, nonpositive amounts, self-transfers, or
events outside the configured interval. The global profile processed an
upper-bound estimate of 356,969,568 bytes and returned 24 source tables with
1,565,656 unique event keys in 1,531,047 transactions. There were 556,539
distinct claim-recipient senders and zero cross-chunk duplicate event keys or
chunk-suffix mismatches.

The layer contains 2,657,983,755.546300504021225633 ARB of gross transfers.
That value is an input-layer volume, not the airdrop amount and not a sale
metric: claimant wallets can hold or receive ARB from other sources, and the
events have not yet been restricted to each wallet's elapsed post-claim
window. The next transformation joins this local source to the exact enriched
claim event, applies block-and-log ordering, and limits events to the first
24 hours and seven days after claim.

## Full-cohort early-outflow baseline

The staged source was joined locally to the 583,137 unique enriched claims on
`claim_recipient = sender`. Events were retained only when they occurred in a
later block, or later by log index in the same block, and when their timestamp
fell in the half-open interval from claim time through seven elapsed days. The
result contains 764,042 unique early-outflow events in 755,133 transactions for
498,511 claim recipients. Duplicate event keys, critical `NULL` values,
source-match failures, nonpositive amounts, self-transfers, ordering
violations, and window violations were all zero. There were 5,866 valid
same-block events.

The full event layer reproduced the earlier bounded chunk-21 validation
exactly: both subsets contained 821 rows, with zero rows found on only one side
and zero field mismatches. The event table was then aggregated to 583,137
claim-grain rows, retaining claimants with no qualifying event. Grain,
completeness, nonnegative-value, 24-hour-to-seven-day monotonicity,
capped-proxy, and first-outflow timing checks all passed with zero violations.

Within 24 elapsed hours, 459,437 recipients (78.7871%) had at least one
qualifying positive outflow; 123,700 (21.2129%) did not. Within seven elapsed
days, the corresponding counts were 498,511 (85.4878%) and 84,626 (14.5122%).
The capped claim-linked outflow proxy was
798,229,705.906067898468974092 ARB, or 73.0437% of claimed ARB, within 24
hours, and 878,245,366.362363087116052122 ARB, or 80.3657%, within seven days.
The complementary retained-claim proxies were 26.9563% and 19.6343%.

Gross positive outflow was 963,790,977.728862120206425733 ARB within 24 hours
and 1,325,201,504.482288875798676385 ARB within seven days. The latter exceeds
the total airdrop claim amount because wallets can hold or receive ARB from
other sources. For this reason, gross outflow is reported as wallet transfer
activity, while the capped measure is used only as a claim-linked proxy.

Claim rows and claimed amount reconciled exactly to the validated cohort.
Event counts and gross amounts reconciled exactly between event-grain and
claim-grain layers for both windows. A deterministic five-stratum wallet sample
also reconciled with zero mismatches and included the previously manually
validated 1,625 ARB claimant. Destinations remain unclassified, none of these
transfers is labeled a sale, and no independent published benchmark for the
exact full-cohort early-outflow metrics has been identified.

## Chart-ready distributions

The claim-grain table contains 39 observed claim amounts from 625 through
10,250 ARB. Approximate cohort quartiles were 875, 1,250, and 2,250 ARB; these
observed cutpoints define four transparent claim-size segments for the first
segment comparison. The segments are descriptive and do not change the
underlying claim or early-outflow definitions.

First-positive-outflow timing is reported through six mutually exclusive
buckets: within one hour, one to less than six hours, six to less than 24
hours, one to less than three days, three to less than seven days, and no
positive outflow within seven days. The buckets sum to all 583,137 validated
claim recipients. Of these, 354,666 recipients (60.8204%) had their first
positive outflow within one hour, while 84,626 (14.5122%) had no qualifying
positive outflow in the seven-day window.

All four claim-size segments and all six timing buckets reconciled to the
claim-grain row count. Segment claimed amount and capped claim-linked outflow
totals for both elapsed windows matched the source exactly, and no segment or
timing domain checks failed. The small reviewed output is stored in
`data/early_outflow_chart_data.json`, with its QA result stored separately.

The companion Plotly notebook reads only these versioned artifacts, asserts
their QA status, and produces three PNG and SVG figures. It was executed from
top to bottom with five sequential code cells and no error outputs. The chart
titles, subtitles, zero baselines, direct labels, sample size, and fungibility
caveats were inspected in the final exported images.

# Claim Transfer Scan Plan

Last updated: 2026-08-13

## Objective

Validate decoded ARB transfers from the TokenDistributor across the full
observed claim window without exceeding the project-level 10 GiB per-query
guardrail.

## Query and grain

- Query template: `sql/11_profile_claim_transfer_month.sql`
- Source: `bigquery-public-data.goog_blockchain_arbitrum_one_us.decoded_events`
- Source grain: one decoded event log
- Output grain: one QA summary row per configured interval
- Candidate event key: `(transaction_hash, log_index)`
- Joins: none
- Row-multiplication risk: none from joins

The estimate query references all columns required by the future QA profile,
including JSON `args`. A simplified `COUNT(*)` estimate was intentionally not
used because column pruning could understate the scan volume.

## Monthly dry-run discovery

| Month | Estimated bytes | Below 10 GiB hard limit |
| --- | ---: | :---: |
| 2023-03 claim interval | 9,424,506,779 | Yes |
| 2023-04 | 97,216,696 | Yes |
| 2023-05 | 24,656,968,499 | No |
| 2023-06 | 16,957,769,424 | No |
| 2023-07 | 14,633,794,416 | No |
| 2023-08 | 12,337,683,052 | No |
| 2023-09 | 9,209,660,294 | Yes |

May through August cannot be executed as single monthly profiles under the
current guardrail.

## Safe execution plan

The claim window is divided into 21 half-open UTC intervals. Every interval was
dry-run at or below the 8 GiB planning target, leaving headroom below the hard
limit.

| Start | End | Estimated GiB |
| --- | --- | ---: |
| 2023-03-23 | 2023-03-27 | 4.478 |
| 2023-03-27 | 2023-04-01 | 4.478 |
| 2023-04-01 | 2023-04-07 | 4.396 |
| 2023-04-07 | 2023-04-13 | 4.110 |
| 2023-04-13 | 2023-04-19 | 7.799 |
| 2023-04-19 | 2023-04-22 | 4.830 |
| 2023-04-22 | 2023-04-25 | 3.663 |
| 2023-04-25 | 2023-05-01 | 6.613 |
| 2023-05-01 | 2023-05-06 | 5.754 |
| 2023-05-06 | 2023-05-11 | 4.984 |
| 2023-05-11 | 2023-05-21 | 6.216 |
| 2023-05-21 | 2023-06-01 | 6.550 |
| 2023-06-01 | 2023-06-16 | 7.995 |
| 2023-06-16 | 2023-06-24 | 4.345 |
| 2023-06-24 | 2023-07-01 | 3.926 |
| 2023-07-01 | 2023-07-16 | 7.283 |
| 2023-07-16 | 2023-08-01 | 6.586 |
| 2023-08-01 | 2023-08-16 | 5.302 |
| 2023-08-16 | 2023-09-01 | 6.411 |
| 2023-09-01 | 2023-09-16 | 4.371 |
| 2023-09-16 | 2023-10-01 | 4.443 |

The revised planned execution total is approximately 122.98 GB. This is a quota plan,
not an execution record: no interval profiles were run during this stage.

## Control and limitation

Dry-run estimates are time-sensitive because the public table continues to
change. Repeat the dry run immediately before every execution. If an interval
exceeds the 8 GiB planning target or 10 GiB hard limit, split it again before
execution.

Chunk-level summaries can validate counts, duplicates, critical values, time
bounds, and amounts within each interval. They do not by themselves prove
global recipient uniqueness across intervals; that requires a later combined
cohort check.

## Execution progress

The first interval, 2023-03-23 through 2023-03-27 UTC, was dry-run again on
2026-08-13. Its updated upper-bound estimate was 4,725,560,931 bytes, below the
10 GiB hard limit, and the profile was executed.

The interval returned:

- 531,821 transfer events, distinct transactions, and distinct recipients;
- no duplicate event keys or recipients with multiple events;
- no critical `NULL`, malformed recipient, or invalid amount rows;
- an observed event interval from 2023-03-23 13:01:22 UTC through
  2023-03-26 23:59:21 UTC;
- 995,857,625 ARB.

As a reasonableness check, subtracting the separately validated first UTC day
leaves 109,341 recipients and 193,266,250 ARB for 2023-03-24 through
2023-03-26. This is a clean within-interval profile, not yet a global cohort
uniqueness result.

The second interval, 2023-03-27 through 2023-04-01 UTC, was also re-dry-run on
2026-08-13. Its upper-bound estimate was 4,727,140,003 bytes, and its QA profile
returned:

- 20,277 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-03-27 00:00:08 UTC through
  2023-03-31 23:59:55 UTC;
- 37,387,125 ARB.

Across the two non-overlapping completed intervals, additive measures total
552,098 events and 1,033,244,750 ARB. Distinct recipients are not summed because
chunk summaries cannot detect the same recipient appearing in separate
intervals. Execution progress is 2 of 21 intervals.

## April replan after public-table update

Before the planned April execution on 2026-08-13, the required repeat dry run
increased from the earlier 98,143,456-byte estimate to 33,157,283,570 bytes.
The query was not executed because this exceeded the 10 GiB hard limit. This
change is consistent with a public-table update or backfill, although the exact
upstream cause was not independently confirmed.

April was re-split into six intervals:

| Start | End | Latest estimated GiB |
| --- | --- | ---: |
| 2023-04-01 | 2023-04-07 | 4.396 |
| 2023-04-07 | 2023-04-13 | 4.110 |
| 2023-04-13 | 2023-04-19 | 7.799 |
| 2023-04-19 | 2023-04-22 | 4.830 |
| 2023-04-22 | 2023-04-25 | 3.663 |
| 2023-04-25 | 2023-05-01 | 6.613 |

All six were below the 8 GiB planning target when dry-run. The revised plan has
21 intervals and an indicative total of 122.98 GB. Estimates for later
intervals remain time-sensitive and must still be refreshed immediately before
execution.

The revised third interval, 2023-04-01 through 2023-04-07 UTC, was dry-run
again at an upper-bound estimate of 4,721,270,965 bytes and executed on
2026-08-13. It returned:

- 7,917 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-01 00:00:12 UTC through
  2023-04-06 23:59:35 UTC;
- 14,883,250 ARB.

Across the three non-overlapping completed intervals, additive measures total
560,015 events and 1,048,128,000 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 3 of 21 intervals.

The fourth interval, 2023-04-07 through 2023-04-13 UTC, was dry-run again at an
upper-bound estimate of 4,415,487,696 bytes and executed on 2026-08-13. It
returned:

- 3,881 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-07 00:01:01 UTC through
  2023-04-12 23:39:29 UTC;
- 7,267,625 ARB.

Across four non-overlapping completed intervals, additive measures total
563,896 events and 1,055,395,625 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 4 of 21 intervals.

The fifth interval, 2023-04-13 through 2023-04-19 UTC, was dry-run again at an
upper-bound estimate of 8,377,670,130 bytes, below the 8 GiB planning target,
and executed on 2026-08-13. It returned:

- 4,285 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-13 00:24:23 UTC through
  2023-04-18 23:49:14 UTC;
- 8,135,000 ARB.

Across five non-overlapping completed intervals, additive measures total
568,181 events and 1,063,530,625 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 5 of 21 intervals.

The sixth interval, 2023-04-19 through 2023-04-22 UTC, was dry-run again at an
upper-bound estimate of 5,191,680,082 bytes and executed on 2026-08-13. It
returned:

- 1,191 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-19 00:03:28 UTC through
  2023-04-21 23:55:06 UTC;
- 2,323,875 ARB.

Across six non-overlapping completed intervals, additive measures total
569,372 events and 1,065,854,500 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 6 of 21 intervals.

The seventh interval, 2023-04-22 through 2023-04-25 UTC, was dry-run again at
an upper-bound estimate of 3,939,529,690 bytes and executed on 2026-08-13. It
returned:

- 787 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-22 00:07:49 UTC through
  2023-04-24 23:53:40 UTC;
- 1,361,750 ARB.

Across seven non-overlapping completed intervals, additive measures total
570,159 events and 1,067,216,250 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 7 of 21 intervals.

The eighth interval, 2023-04-25 through 2023-05-01 UTC, was dry-run again at an
upper-bound estimate of 7,108,742,481 bytes and executed on 2026-08-13. It
returned:

- 1,350 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-04-25 00:01:22 UTC through
  2023-04-30 23:27:11 UTC;
- 2,393,250 ARB.

Across eight non-overlapping completed intervals, additive measures total
571,509 events and 1,069,609,500 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 8 of 21 intervals.

The ninth interval, 2023-05-01 through 2023-05-06 UTC, was dry-run again at an
upper-bound estimate of 6,106,404,134 bytes and executed on 2026-08-13. It
returned:

- 1,130 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-05-01 00:04:45 UTC through
  2023-05-05 23:41:14 UTC;
- 1,877,375 ARB.

Across nine non-overlapping completed intervals, additive measures total
572,639 events and 1,071,486,875 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 9 of 21 intervals.

The tenth interval, 2023-05-06 through 2023-05-11 UTC, was dry-run again at an
upper-bound estimate of 5,280,361,568 bytes and executed on 2026-08-13. It
returned:

- 660 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-05-06 00:01:25 UTC through
  2023-05-10 23:42:44 UTC;
- 1,454,250 ARB.

Across ten non-overlapping completed intervals, additive measures total
573,299 events and 1,072,941,125 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 10 of 21 intervals.

The eleventh interval, 2023-05-11 through 2023-05-21 UTC, was dry-run again at
an upper-bound estimate of 6,606,991,794 bytes and executed on 2026-08-13. It
returned:

- 1,030 transfer events and within-interval distinct recipients across 1,027
  distinct transactions;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-05-11 00:24:46 UTC through
  2023-05-20 23:50:08 UTC;
- 1,924,250 ARB.

The three-event difference between event rows and distinct transactions proves
that transaction hash alone is not an event-grain key in this interval. It does
not represent duplicated `(transaction_hash, log_index)` keys, which remained
at zero.

Across eleven non-overlapping completed intervals, additive measures total
574,329 events and 1,074,865,375 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 11 of 21 intervals.

The twelfth interval, 2023-05-21 through 2023-06-01 UTC, was dry-run again at
an upper-bound estimate of 6,966,365,344 bytes and executed on 2026-08-13. It
returned:

- 970 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-05-21 00:15:15 UTC through
  2023-05-31 23:32:43 UTC;
- 1,907,625 ARB.

Across twelve non-overlapping completed intervals, additive measures total
575,299 events and 1,076,773,000 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 12 of 21 intervals.

The thirteenth interval, 2023-06-01 through 2023-06-16 UTC, was dry-run again
at an upper-bound estimate of 8,519,040,302 bytes and executed on 2026-08-13.
The estimate was approximately 7.93 GiB, only about 67.6 MiB below the 8 GiB
planning target, so any future rerun requires another fresh estimate. The
profile returned:

- 1,102 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-06-01 00:49:12 UTC through
  2023-06-15 22:55:41 UTC;
- 2,197,000 ARB.

Across thirteen non-overlapping completed intervals, additive measures total
576,401 events and 1,078,970,000 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 13 of 21 intervals.

The fourteenth interval, 2023-06-16 through 2023-06-24 UTC, was dry-run again
at an upper-bound estimate of 4,599,774,271 bytes and executed on 2026-08-13.
It returned:

- 509 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-06-16 00:25:04 UTC through
  2023-06-23 23:30:33 UTC;
- 1,089,000 ARB.

Across fourteen non-overlapping completed intervals, additive measures total
576,910 events and 1,080,059,000 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 14 of 21 intervals.

The fifteenth interval, 2023-06-24 through 2023-07-01 UTC, was dry-run again at
an upper-bound estimate of 4,151,333,052 bytes and executed on 2026-08-13. It
returned:

- 411 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-06-24 00:04:22 UTC through
  2023-06-30 23:48:18 UTC;
- 916,500 ARB.

Across fifteen non-overlapping completed intervals, additive measures total
577,321 events and 1,080,975,500 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 15 of 21 intervals.

The sixteenth interval, 2023-07-01 through 2023-07-16 UTC, was dry-run again at
an upper-bound estimate of 7,757,649,506 bytes and executed on 2026-08-13. It
returned:

- 929 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-07-01 00:20:42 UTC through
  2023-07-15 22:34:23 UTC;
- 1,803,000 ARB.

Across sixteen non-overlapping completed intervals, additive measures total
578,250 events and 1,082,778,500 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 16 of 21 intervals.

The seventeenth interval, 2023-07-16 through 2023-08-01 UTC, was dry-run again
at an upper-bound estimate of 7,010,549,790 bytes and executed on 2026-08-13.
It returned:

- 837 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-07-16 00:18:28 UTC through
  2023-07-31 22:38:04 UTC;
- 1,721,750 ARB.

Across seventeen non-overlapping completed intervals, additive measures total
579,087 events and 1,084,500,250 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 17 of 21 intervals.

The eighteenth interval, 2023-08-01 through 2023-08-16 UTC, was dry-run again
at an upper-bound estimate of 5,633,067,217 bytes and executed on 2026-08-13.
It returned:

- 737 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-08-01 01:17:33 UTC through
  2023-08-15 23:56:35 UTC;
- 1,515,250 ARB.

Across eighteen non-overlapping completed intervals, additive measures total
579,824 events and 1,086,015,500 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 18 of 21 intervals.

The nineteenth interval, 2023-08-16 through 2023-09-01 UTC, was dry-run again
at an upper-bound estimate of 6,824,610,977 bytes and executed on 2026-08-13.
It returned:

- 750 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-08-16 00:04:02 UTC through
  2023-08-31 22:47:22 UTC;
- 1,582,250 ARB.

Across nineteen non-overlapping completed intervals, additive measures total
580,574 events and 1,087,597,750 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 19 of 21 intervals.

The twentieth interval, 2023-09-01 through 2023-09-16 UTC, was dry-run again
at an upper-bound estimate of 4,637,185,017 bytes and executed on 2026-08-13.
It returned:

- 1,354 transfer events, distinct transactions, and within-interval distinct
  recipients;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-09-01 02:13:08 UTC through
  2023-09-15 23:54:26 UTC;
- 2,623,000 ARB.

Across twenty non-overlapping completed intervals, additive measures total
581,928 events and 1,090,220,750 ARB. Cross-interval recipient uniqueness is
still untested. Execution progress is 20 of 21 intervals.

The twenty-first interval, 2023-09-16 through 2023-10-01 UTC, was dry-run again
at an upper-bound estimate of 4,716,582,271 bytes and executed on 2026-08-13.
Its structural profile returned:

- 1,210 transfer events and within-interval distinct recipients across 1,207
  distinct transactions;
- no duplicate event keys, repeated recipients, or critical invalid values;
- an observed event interval from 2023-09-16 00:16:33 UTC through
  2023-09-25 02:20:03 UTC;
- 72,039,135.458006064728014866 ARB.

Across all twenty-one non-overlapping intervals, additive transfer measures
total 583,138 events and 1,162,259,885.458006064728014866 ARB. These totals do
not reconcile to the full raw `HasClaimed` profile of 583,137 events and
1,092,811,500 ARB: the transfer-based scan contains one additional event and
69,448,385.458006064728014866 excess ARB.

The last transfer timestamp is later than the last raw claim timestamp of
2023-09-24 20:12:52 UTC. Therefore, a transfer from the TokenDistributor alone
is not a sufficient full-window claim criterion: the final interval contains
at least one candidate non-claim transfer. Its purpose is not classified until
the exact event and transaction are isolated and manually verified. The
twenty-one interval executions are complete, but full-window reconciliation
and cross-interval recipient uniqueness remain open.

## Isolated reconciliation exception

A separate query scanned only decoded TokenDistributor transfers strictly after
the last raw `HasClaimed` timestamp. It was dry-run at an upper-bound estimate
of 2,201,791,932 bytes and returned exactly one event:

- block: 134,320,927;
- timestamp: 2023-09-25 02:20:03 UTC;
- transaction: `0xa2477f2f1d7824501520a88b50835ad283e7472e0fa5e67005452528bf740175`;
- event log index: 0;
- recipient: `0xf3fc178157fb3c87548baa86f9d24ba38e649b58`;
- amount: 69,448,385.458006064728014866 ARB.

The single event and its amount exactly explain both full-window reconciliation
differences. This proves that the exception has been isolated, but not what the
transaction represents. Its classification remains pending direct transaction
inspection; no sale, claim, recovery, or treasury label is assigned yet.

### Manual transaction verification

Manual verification on 2026-08-13 classified the exception as an unclaimed
token sweep to the contract's configured `sweepReceiver`, with high confidence:

- the successful transaction called `sweep()` on the TokenDistributor;
- its logs contained both the ARB `Transfer` and TokenDistributor `Swept`
  events for the exact isolated amount;
- the recipient matched the transfer recipient, and Arbiscan labeled it
  `Arbitrum Foundation: DAO Treasury`;
- the official TokenDistributor source defines `sweep()` as callable only after
  the claim period, transfers the entire remaining token balance to
  `sweepReceiver`, emits `Swept`, and then destroys the distributor contract.

Sources accessed 2026-08-13:

- https://arbiscan.io/tx/0xa2477f2f1d7824501520a88b50835ad283e7472e0fa5e67005452528bf740175
- https://github.com/ArbitrumFoundation/governance/blob/main/src/TokenDistributor.sol

The corrected transfer-based cohort must exclude this verified sweep
transaction by transaction hash. After that subtraction, transfer event count
and amount reconcile exactly to the raw `HasClaimed` totals. This aggregate
reconciliation does not replace the still-open global recipient-uniqueness
check.

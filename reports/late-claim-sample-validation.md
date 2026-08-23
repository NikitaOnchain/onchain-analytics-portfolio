# Late-Window Claim Sample Validation

## Purpose

Test concrete late claim rows after the full corrected transfer cohort passed
global structural QA. This sample check complements aggregate reconciliation;
it does not replace it.

## Sampling method

The corrected chunk-21 table was sorted by timestamp, transaction hash, and
transfer log index. Five deterministic positions were selected: the first two,
the middle row, and the last two. This avoids discretionary wallet selection
while covering the beginning, middle, and end of the final claim interval.

The sample query has event grain and no JOIN. Three date-bounded raw-log jobs
then decoded `HasClaimed` and used a LEFT JOIN on transaction hash, normalized
recipient, and raw amount. Expected cardinality was one-to-one. The output
reported match counts so unexpected source duplication could not be hidden by
the JOIN.

## Results

All five corrected Transfer events matched exactly one raw `HasClaimed` event
on transaction hash, recipient, amount, and timestamp. The samples covered 875,
1,125, 3,000, and 3,250 ARB amounts and included non-zero Transfer log indexes.
The raw `HasClaimed` log indexes differed from the Transfer log indexes as
expected because they are separate event logs in the same transaction.

The last claim transaction was also inspected independently in Arbiscan. The
explorer showed a successful interaction with the TokenDistributor, a 1,125 ARB
transfer from the distributor to the sampled recipient, and a decoded
`HasClaimed` event for the same recipient and raw amount:

https://arbiscan.io/tx/0xeca14ec78ac551d757437f40c8920c39be5a526695a74e78ed2d29f977d7de02

The other four rows were reconciled between BigQuery sources but were not
separately classified as block-explorer-checked.

## Assessment

No sample-level data-quality issue was found. Confidence is high that the
corrected decoded-Transfer representation remains faithful at the end of the
claim period. Exact independent reconciliation of the full 1,092,811,500 ARB
aggregate remains a separate open check before the cohort is labeled fully
analysis-ready.

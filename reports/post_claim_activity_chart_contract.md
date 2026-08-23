# Post-claim Activity Chart Contract

## Shared scope

- Cohort: 583,137 validated ARB claim recipients from 2023-03-23 through 2023-09-24.
- Activity: successful top-level Arbitrum transactions initiated by the validated claim recipient after exact claim order.
- Windows: elapsed half-open 24-hour and seven-day windows after each exact claim.
- Interpretation limit: address activity is not proof of retained human usage, protocol engagement, token retention, or sales.
- Source artifact: `data/post_claim_activity_chart_data.json`.
- QA artifact: `data/post_claim_activity_chart_data_qa.json`.
- Surface: reproducible Plotly notebook with PNG and SVG exports.
- Palette: one blue root and one gold root plus neutrals; patterns and direct labels provide non-color distinction.

## Figure map

| Figure | Analytical question | Supported takeaway | Form and data sufficiency | Output |
|---|---|---|---|---|
| First activity timing | How quickly did a recipient first initiate a qualifying transaction? | 64.9% did so within one hour; 9.1% had no qualifying activity within seven days. | Horizontal bar chart; six exhaustive, mutually exclusive buckets covering all 583,137 recipients. | `figures/04_first_post_claim_activity_timing.*` |
| Breadth and depth by claim size | Did claim-size groups differ in participation and transaction depth? | Seven-day participation was similar across groups, while transactions per active recipient increased with claim size. | Two-panel categorical comparison; four pre-defined claim-size segments, with zero-based bar axes and exact labels. | `figures/05_post_claim_activity_by_claim_size.*` |
| Seven-day activity intensity | How concentrated were qualifying transactions across activity-count groups? | The 11+ transaction group represented 11.7% of recipients and 66.1% of transaction rows. | Grouped horizontal bar chart; five exhaustive intensity buckets, comparing recipient share and transaction-row share. | `figures/06_post_claim_activity_intensity.*` |

These figures are descriptive. No chart supports a causal claim about airdrop size or user quality.

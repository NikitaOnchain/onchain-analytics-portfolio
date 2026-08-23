# Transfer-derived ARB Balance Proxy Chart Contract

## Shared scope

- Cohort: 583,137 validated ARB claim recipients from 2023-03-23 through 2023-09-24.
- Cutoffs: immediately before 7 and 30 elapsed 24-hour periods after each exact claim.
- Total-balance ratio: transfer-derived total ARB balance at the cutoff divided by the validated claim amount.
- Adjusted proxy: total ARB balance minus positive pre-claim balance, capped to the interval from zero to the claim amount before cohort aggregation.
- Event order: block number, transaction index, and log index for the exact claim boundary; claimant self-transfers net to zero.
- Interpretation limit: neither measure traces fungible claimed units or identifies address activity, protocol engagement, human retention, or sales.
- Source artifact: `data/retention_arb_balance_proxy_chart_data.json`.
- QA artifact: `data/retention_arb_balance_proxy_chart_data_qa.json`.
- Surface: reproducible Plotly notebook with PNG and SVG exports.
- Palette: blue and gold roots plus neutrals; fill patterns, outlines, and direct labels provide non-color distinction.

## Figure map

| Figure | Analytical question | Supported takeaway | Form and data sufficiency | Output |
|---|---|---|---|---|
| Total-balance distribution | How were recipients distributed across total ARB balance-to-claim buckets at 7 and 30 days? | The zero-balance bucket increased from 62.8% at 7 days to 64.4% at 30 days; the 75–100% bucket declined from 15.2% to 9.2%. | Grouped categorical bar chart; five ordered, exhaustive buckets at each cutoff, covering 583,137 recipients per cutoff. | `figures/07_transfer_derived_arb_balance_proxy_distribution.*` |
| Adjusted retained-claim proxy | What share of claimed ARB remained under the capped, pre-claim-adjusted transfer-derived proxy at each cutoff? | The aggregate proxy declined from 21.7% at 7 days to 14.2% at 30 days. | Two-bar discrete-period comparison with a zero baseline and direct labels; a line chart is not used because two cutoffs do not establish a trend. | `figures/08_adjusted_retained_claim_proxy.*` |

The figures are descriptive. The greater-than-100-percent total-balance bucket can reflect additional post-claim ARB inflow; the adjusted aggregate proxy is separately capped per recipient.

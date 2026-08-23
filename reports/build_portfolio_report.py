"""Build the portable public report artifact from validated repository data.

This script does not query BigQuery. It reads the small, versioned JSON outputs
that already passed their documented SQL QA checks, verifies the expected
cohort totals, and writes the canonical report artifact consumed by the
portable Data Analytics report builder.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports"

REPORT_ANALYTICAL_INPUT_SHA256 = {
    "data/claim_cohort_profile.json": "893700a21050cbe7f18183633fe88084fcaa44cdf53b2e134d822d9e77a47fdd",
    "data/early_outflow_chart_data.json": "296a93a7cc87b9fd5a19a004103fae859af13d6edc0649c660eea6e7b235adec",
    "data/early_outflow_chart_data_qa.json": "1a1a8ce6b2833bf552743ca46479ab54d2286f60bc7aed269aacea9ec62f99d6",
    "data/post_claim_activity_chart_data.json": "a047a5be68254637d73fd602bc519fe3df71c147ad9dd1ff5fe590a38df8d01a",
    "data/post_claim_activity_chart_data_qa.json": "4b76c68668967d827feb9046a4604d95458e52b7621e65b33573c7187e251942",
    "data/retention_arb_balance_proxy_chart_data.json": "c20abf421e6177e919a06b0933bdf8149df5c4fc35100f0934c31ec005e8c407",
    "data/retention_arb_balance_proxy_chart_data_qa.json": "f28c6dbc75149cead9030fc4816452a8c25fe02819f23d9572bf42cd2d1d09ba",
    "sql/03_profile_claim_cohort.sql": "aa415900668f19734894026870d1bccc049c037db39e3432075465c5d5859a66",
    "sql/50_export_early_outflow_chart_data.sql": "c88d0c1874c76030e28322949728edea73bb836caa582f890607f1126d84903f",
    "sql/75_export_post_claim_activity_chart_data.sql": "1ef8f6bcd68654977ce121814f340904e9730e4872c6399d28fb4628dbf52820",
    "sql/86b_profile_transfer_derived_arb_balance_proxy.sql": "4c198af07310a322330250cb4d7a63b851ec614b1a36da3237ccc29bbc71c60d",
}
REPORT_ANALYTICAL_INPUTS = list(REPORT_ANALYTICAL_INPUT_SHA256)


def load_json(relative_path: str) -> dict:
    with (ROOT / relative_path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict):
        return value[0]
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object in {relative_path}")
    return value


def load_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def sha256(relative_path: str) -> str:
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    canonical = text.replace("\r\n", "\n").encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def assert_sha256(relative_path: str, expected: str) -> None:
    actual = sha256(relative_path)
    if actual != expected:
        raise ValueError(
            f"SHA-256 mismatch for {relative_path}: expected {expected}, got {actual}"
        )


def pct(value: object) -> float:
    return float(value)


def assert_source_qa(qa: dict, label: str) -> None:
    failed = [name for name, passed in qa["checks"].items() if passed is not True]
    if failed:
        raise ValueError(f"{label} QA failed: {', '.join(failed)}")


if any("symmetric_behavior" in path for path in REPORT_ANALYTICAL_INPUTS):
    raise ValueError("Abandoned symmetric pipeline artifacts cannot feed public v1")

for pinned_path, pinned_hash in REPORT_ANALYTICAL_INPUT_SHA256.items():
    assert_sha256(pinned_path, pinned_hash)

cohort = load_json("data/claim_cohort_profile.json")
early = load_json("data/early_outflow_chart_data.json")
early_qa = load_json("data/early_outflow_chart_data_qa.json")
activity = load_json("data/post_claim_activity_chart_data.json")
activity_qa = load_json("data/post_claim_activity_chart_data_qa.json")
balance = load_json("data/retention_arb_balance_proxy_chart_data.json")
balance_qa = load_json("data/retention_arb_balance_proxy_chart_data_qa.json")

assert_source_qa(early_qa, "Early-outflow chart data")
assert_source_qa(activity_qa, "Post-claim activity chart data")
assert_source_qa(balance_qa, "Transfer-derived ARB balance-proxy chart data")

recipient_count = int(cohort["distinct_recipients"])
claimed_arb = int(cohort["provisional_total_claimed_arb"])
if recipient_count != 583_137:
    raise ValueError(f"Unexpected cohort size: {recipient_count}")
if claimed_arb != 1_092_811_500:
    raise ValueError(f"Unexpected claimed amount: {claimed_arb}")
if early_qa["claim_rows"] != recipient_count:
    raise ValueError("Early-outflow chart denominator does not match the claim cohort")
if activity_qa["claim_rows"] != recipient_count:
    raise ValueError("Activity chart denominator does not match the claim cohort")
if balance_qa["expected"]["claim_recipients_per_cutoff"] != recipient_count:
    raise ValueError("Balance-proxy chart denominator does not match the claim cohort")
if balance_qa["profile"]["bucket_rows"] != 10:
    raise ValueError("Balance-proxy chart data must contain ten bucket rows")
if balance_qa["profile"]["adjusted_proxy_rows"] != 2:
    raise ValueError("Balance-proxy chart data must contain two adjusted-proxy rows")

early_windows = {row["window_label"]: row for row in early["window_summary"]}
activity_windows = {row["window_label"]: row for row in activity["window_summary"]}

headline_cohort = [{"recipients": recipient_count, "claimed_arb": claimed_arb}]
headline_early = [{
    "positive_outflow_rate_24h": pct(
        early_windows["Within 24 hours"]["recipient_positive_outflow_rate"]
    ),
    "positive_outflow_rate_7d": pct(
        early_windows["Within 7 days"]["recipient_positive_outflow_rate"]
    ),
    "claim_linked_outflow_share_24h": pct(
        early_windows["Within 24 hours"]["claim_linked_outflow_share"]
    ),
    "claim_linked_outflow_share_7d": pct(
        early_windows["Within 7 days"]["claim_linked_outflow_share"]
    ),
}]
headline_activity = [{
    "active_recipient_rate_24h": pct(
        activity_windows["Within 24 hours"]["active_recipient_rate"]
    ),
    "active_recipient_rate_7d": pct(
        activity_windows["Within 7 days"]["active_recipient_rate"]
    ),
}]
balance_adjusted_rows = {
    int(row["cutoff_days"]): row
    for row in balance["adjusted_retained_claim_proxy"]
}
headline_balance = [{
    "adjusted_balance_proxy_share_7d": pct(
        balance_adjusted_rows[7]["adjusted_retained_claim_proxy_share"]
    ),
    "adjusted_balance_proxy_share_30d": pct(
        balance_adjusted_rows[30]["adjusted_retained_claim_proxy_share"]
    ),
}]

early_timing = [
    {
        "bucket_order": row["bucket_order"],
        "timing_bucket": row["timing_bucket"],
        "recipient_count": row["recipient_count"],
        "recipient_share": pct(row["recipient_share"]),
    }
    for row in early["first_positive_outflow_timing"]
]

early_composition = []
for row in early["window_summary"]:
    early_composition.extend([
        {
            "window_order": row["window_order"],
            "window_label": row["window_label"],
            "measure": "Claim-linked outflow proxy",
            "share": pct(row["claim_linked_outflow_share"]),
            "arb_amount": pct(row["claim_linked_outflow_arb"]),
            "claimed_arb": pct(row["claimed_arb"]),
        },
        {
            "window_order": row["window_order"],
            "window_label": row["window_label"],
            "measure": "Retained-claim proxy",
            "share": pct(row["retained_claim_proxy_share"]),
            "arb_amount": pct(row["retained_claim_proxy_arb"]),
            "claimed_arb": pct(row["claimed_arb"]),
        },
    ])

activity_timing = [
    {
        "bucket_order": row["bucket_order"],
        "timing_bucket": row["timing_bucket"],
        "recipient_count": row["recipient_count"],
        "recipient_share": pct(row["recipient_share"]),
    }
    for row in activity["first_activity_timing"]
]

activity_segment_rates = []
activity_segment_depth = []
for row in activity["claim_size_segments"]:
    activity_segment_rates.extend([
        {
            "segment_order": row["segment_order"],
            "claim_size_segment": row["claim_size_segment"],
            "window": "Within 24 hours",
            "active_recipient_rate": pct(row["active_recipient_rate_24h"]),
            "active_recipients": row["active_recipients_24h"],
            "recipient_count": row["recipient_count"],
        },
        {
            "segment_order": row["segment_order"],
            "claim_size_segment": row["claim_size_segment"],
            "window": "Within 7 days",
            "active_recipient_rate": pct(row["active_recipient_rate_7d"]),
            "active_recipients": row["active_recipients_7d"],
            "recipient_count": row["recipient_count"],
        },
    ])
    activity_segment_depth.append({
        "segment_order": row["segment_order"],
        "claim_size_segment": row["claim_size_segment"],
        "average_transactions_per_active_recipient_7d": pct(
            row["average_transactions_per_active_recipient_7d"]
        ),
        "average_active_utc_days_per_active_recipient_7d": pct(
            row["average_active_utc_days_per_active_recipient_7d"]
        ),
        "average_distinct_targets_per_active_recipient_7d": pct(
            row["average_distinct_targets_per_active_recipient_7d"]
        ),
        "active_recipients_7d": row["active_recipients_7d"],
    })

activity_intensity = []
for row in activity["activity_intensity_7d"]:
    activity_intensity.extend([
        {
            "bucket_order": row["bucket_order"],
            "transaction_count_bucket": row["transaction_count_bucket"],
            "measure": "Share of recipients",
            "share": pct(row["recipient_share"]),
            "recipient_count": row["recipient_count"],
            "successful_transaction_rows": row["successful_transaction_rows"],
        },
        {
            "bucket_order": row["bucket_order"],
            "transaction_count_bucket": row["transaction_count_bucket"],
            "measure": "Share of successful transactions",
            "share": pct(row["successful_transaction_share"]),
            "recipient_count": row["recipient_count"],
            "successful_transaction_rows": row["successful_transaction_rows"],
        },
    ])

balance_bucket_distribution = [
    {
        "cutoff_order": row["cutoff_order"],
        "cutoff_label": row["cutoff_label"],
        "bucket_order": row["bucket_order"],
        "balance_to_claim_bucket": row["balance_to_claim_bucket"],
        "recipient_count": row["recipient_count"],
        "recipient_share": pct(row["recipient_share"]),
    }
    for row in balance["balance_to_claim_bucket_distribution"]
]

balance_adjusted_proxy = [
    {
        "cutoff_order": row["cutoff_order"],
        "cutoff_label": row["cutoff_label"],
        "adjusted_retained_claim_proxy_arb": pct(
            row["adjusted_retained_claim_proxy_arb"]
        ),
        "adjusted_retained_claim_proxy_share": pct(
            row["adjusted_retained_claim_proxy_share"]
        ),
    }
    for row in balance["adjusted_retained_claim_proxy"]
]

source_manifest = [
    {
        "id": "src_claim_cohort",
        "label": "Validated ARB claim cohort profile",
        "path": "sql/03_profile_claim_cohort.sql",
    },
    {
        "id": "src_early_outflow",
        "label": "Validated full-cohort early-outflow chart aggregates",
        "path": "sql/50_export_early_outflow_chart_data.sql",
    },
    {
        "id": "src_post_claim_activity",
        "label": "Validated full-cohort post-claim activity chart aggregates",
        "path": "sql/75_export_post_claim_activity_chart_data.sql",
    },
    {
        "id": "src_balance_proxy",
        "label": "Validated 7-day and 30-day transfer-derived ARB balance proxies",
        "path": "data/retention_arb_balance_proxy_chart_data.json",
    },
]

source_details = [
    {
        **source_manifest[0],
        "query": {
            "engine": "BigQuery Standard SQL",
            "language": "GoogleSQL",
            "executed_at": "2026-08-11",
            "description": "Profiles the raw HasClaimed event cohort and its data-quality controls.",
            "sql": load_text("sql/03_profile_claim_cohort.sql"),
            "tables_used": [
                "bigquery-public-data.goog_blockchain_arbitrum_one_us.logs"
            ],
            "filters": [
                "TokenDistributor HasClaimed logs only",
                "Claims observed from 23 March through 24 September 2023",
                "At least two log topics so the indexed recipient can be decoded",
            ],
            "metric_definitions": [
                "Claim recipient: the final 20 bytes of indexed topic 1.",
                "Claim amount: uint256 event data normalized from raw units using 18 decimals.",
                "Output grain: one cohort-level QA summary row.",
            ],
        },
    },
    {
        **source_manifest[1],
        "query": {
            "engine": "BigQuery Standard SQL",
            "language": "GoogleSQL",
            "executed_at": "2026-08-15",
            "description": "Exports chart-ready early-outflow aggregates from the validated claim-grain metric table.",
            "sql": load_text("sql/50_export_early_outflow_chart_data.sql"),
            "tables_used": [
                "YOUR_PROJECT_ID.YOUR_DATASET_ID.early_outflow_metrics_full_cohort"
            ],
            "filters": [
                "All 583,137 validated claim recipients",
                "Positive non-self ARB transfers after exact claim order",
                "Half-open elapsed windows of 24 hours and seven days",
            ],
            "metric_definitions": [
                "Positive early outflow counts qualifying outgoing ARB transfers and is not a sales label.",
                "Claim-linked outflow is cumulative positive outflow capped at each recipient's claim amount.",
                "Retained-claim proxy equals claim amount minus capped claim-linked outflow.",
            ],
        },
    },
    {
        **source_manifest[2],
        "query": {
            "engine": "BigQuery Standard SQL",
            "language": "GoogleSQL",
            "executed_at": "2026-08-19",
            "description": "Exports chart-ready address-activity aggregates from the validated claim-grain metric table.",
            "sql": load_text("sql/75_export_post_claim_activity_chart_data.sql"),
            "tables_used": [
                "YOUR_PROJECT_ID.YOUR_DATASET_ID.post_claim_activity_metrics_full_cohort"
            ],
            "filters": [
                "All 583,137 validated claim recipients",
                "Successful top-level Arbitrum transactions initiated after exact claim order",
                "Half-open elapsed windows of 24 hours and seven days",
            ],
            "metric_definitions": [
                "Active recipient: a claim recipient initiating at least one qualifying transaction in the window.",
                "Activity intensity: count of qualifying successful top-level transactions within seven days.",
                "Activity is an address-level signal, not proof of retained human usage or protocol engagement.",
            ],
        },
    },
    {
        **source_manifest[3],
        "query": {
            "engine": "BigQuery Standard SQL",
            "language": "GoogleSQL",
            "executed_at": "2026-08-22",
            "description": (
                "Profiles the claim-grain transfer-derived ARB balance table. "
                "The public chart data and QA files are locally derived, hash-pinned "
                f"to SHA-256 {REPORT_ANALYTICAL_INPUT_SHA256['data/retention_arb_balance_proxy_chart_data.json']} "
                f"and {REPORT_ANALYTICAL_INPUT_SHA256['data/retention_arb_balance_proxy_chart_data_qa.json']}."
            ),
            "sql": load_text(
                "sql/86b_profile_transfer_derived_arb_balance_proxy.sql"
            ),
            "tables_used": [
                "YOUR_PROJECT_ID.YOUR_DATASET_ID.retention_transfer_derived_arb_balance_proxy",
                "YOUR_PROJECT_ID.YOUR_DATASET_ID.retention_arb_claimant_transfer_legs",
                "YOUR_PROJECT_ID.YOUR_DATASET_ID.corrected_claim_transfers_enriched_chunk_*",
            ],
            "filters": [
                "All 583,137 validated unique claim recipients",
                "Signed ARB transfer legs strictly before exact 7-day and 30-day elapsed cutoffs",
                "Pre-claim balance uses exact block, transaction, and log ordering",
                "Claimant self-transfers net to zero",
            ],
            "metric_definitions": [
                "Total-balance ratio: transfer-derived total ARB balance at the cutoff divided by validated claim amount.",
                "Adjusted retained-claim proxy: total balance minus positive pre-claim balance, capped to [0, claim amount] per recipient before aggregation.",
                "The proxy does not trace fungible claimed units and is not a historical balance snapshot.",
            ],
        },
    },
]

cards = [
    {
        "id": "card_recipients",
        "description": "Unique validated recipients in the complete claim cohort.",
        "dataset": "headline_cohort",
        "sourceId": "src_claim_cohort",
        "metrics": [
            {"label": "Claim recipients", "field": "recipients", "format": "compact"}
        ],
    },
    {
        "id": "card_claimed_arb",
        "description": "Total ARB claimed across the validated cohort.",
        "dataset": "headline_cohort",
        "sourceId": "src_claim_cohort",
        "metrics": [
            {"label": "Claimed ARB", "field": "claimed_arb", "format": "compact"}
        ],
    },
    {
        "id": "card_positive_outflow",
        "description": "Recipients with at least one positive non-self ARB outflow.",
        "dataset": "headline_early",
        "sourceId": "src_early_outflow",
        "metrics": [
            {"label": "Positive outflow within 7d", "field": "positive_outflow_rate_7d", "format": "percent"},
            {"label": "Within 24h", "field": "positive_outflow_rate_24h", "format": "percent"},
        ],
    },
    {
        "id": "card_claim_linked_proxy",
        "description": "Capped claim-linked outflow as a share of claimed ARB.",
        "dataset": "headline_early",
        "sourceId": "src_early_outflow",
        "metrics": [
            {"label": "Claim-linked outflow proxy within 7d", "field": "claim_linked_outflow_share_7d", "format": "percent"},
            {"label": "Within 24h", "field": "claim_linked_outflow_share_24h", "format": "percent"},
        ],
    },
    {
        "id": "card_active_recipients",
        "description": "Recipients initiating at least one successful top-level Arbitrum transaction.",
        "dataset": "headline_activity",
        "sourceId": "src_post_claim_activity",
        "metrics": [
            {"label": "Active recipients within 7d", "field": "active_recipient_rate_7d", "format": "percent"},
            {"label": "Within 24h", "field": "active_recipient_rate_24h", "format": "percent"},
        ],
    },
    {
        "id": "card_adjusted_balance_proxy",
        "description": (
            "Capped pre-claim-adjusted transfer-derived balance proxy as a share "
            "of claimed ARB."
        ),
        "dataset": "headline_balance",
        "sourceId": "src_balance_proxy",
        "metrics": [
            {
                "label": "Adjusted balance proxy within 30d",
                "field": "adjusted_balance_proxy_share_30d",
                "format": "percent",
            },
            {
                "label": "Within 7d",
                "field": "adjusted_balance_proxy_share_7d",
                "format": "percent",
            },
        ],
    },
]

charts = [
    {
        "id": "chart_early_timing",
        "title": "First positive ARB outflow after claim",
        "subtitle": "Share of 583,137 validated recipients; elapsed time from exact claim order",
        "type": "horizontalBar",
        "intent": "comparison",
        "question": "How quickly did recipients first move ARB out of the claiming address?",
        "rationale": "Ordered horizontal bars make the long timing labels and mutually exclusive recipient shares easy to compare.",
        "comparisonContext": {"denominator": "583,137 claim recipients", "grain": "recipient", "unit": "share"},
        "dataset": "early_timing",
        "sourceId": "src_early_outflow",
        "encodings": {
            "x": {"field": "timing_bucket", "type": "ordinal", "label": "Timing bucket"},
            "y": {"field": "recipient_share", "type": "quantitative", "format": "percent", "label": "Share of recipients"},
            "tooltip": [
                {"field": "recipient_count", "type": "quantitative", "format": "compact", "label": "Recipients"},
                {"field": "recipient_share", "type": "quantitative", "format": "percent", "label": "Share"},
            ],
        },
        "palette": {"kind": "sequential", "name": "blue"},
        "legend": {"position": "bottom"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Elapsed timing bucket",
        "yAxisTitle": "Share of recipients",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 6,
    },
    {
        "id": "chart_early_composition",
        "title": "Claim-linked outflow and retained-claim proxy",
        "subtitle": "Capped composition of claimed ARB after 24 hours and seven days",
        "type": "horizontalStackedBar100",
        "intent": "composition",
        "question": "What share of claimed ARB is represented by the capped outflow and retained-claim proxies?",
        "rationale": "A normalized stacked bar keeps the common claimed-ARB denominator explicit across both elapsed windows.",
        "comparisonContext": {"denominator": "claimed ARB", "grain": "elapsed window", "normalization": "100%"},
        "dataset": "early_composition",
        "sourceId": "src_early_outflow",
        "encodings": {
            "x": {"field": "window_label", "type": "ordinal", "label": "Elapsed window"},
            "y": {"field": "share", "type": "quantitative", "format": "percent", "label": "Share of claimed ARB"},
            "color": {"field": "measure", "type": "nominal", "label": "Proxy measure"},
            "tooltip": [
                {"field": "share", "type": "quantitative", "format": "percent", "label": "Share"},
                {"field": "arb_amount", "type": "quantitative", "format": "compact", "unit": "ARB", "label": "ARB amount"},
            ],
        },
        "palette": {"kind": "categorical", "name": "blue-gold"},
        "legend": {"position": "bottom", "sort": "spec"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Elapsed window",
        "yAxisTitle": "Share of claimed ARB",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 4,
    },
    {
        "id": "chart_activity_timing",
        "title": "First post-claim activity",
        "subtitle": "Successful top-level Arbitrum transactions initiated by each recipient within seven days",
        "type": "horizontalBar",
        "intent": "comparison",
        "question": "How quickly did claim recipients first initiate another successful Arbitrum transaction?",
        "rationale": "Ordered horizontal bars compare mutually exclusive timing buckets without implying a continuous time series.",
        "comparisonContext": {"denominator": "583,137 claim recipients", "grain": "recipient", "unit": "share"},
        "dataset": "activity_timing",
        "sourceId": "src_post_claim_activity",
        "encodings": {
            "x": {"field": "timing_bucket", "type": "ordinal", "label": "Timing bucket"},
            "y": {"field": "recipient_share", "type": "quantitative", "format": "percent", "label": "Share of recipients"},
            "tooltip": [
                {"field": "recipient_count", "type": "quantitative", "format": "compact", "label": "Recipients"},
                {"field": "recipient_share", "type": "quantitative", "format": "percent", "label": "Share"},
            ],
        },
        "palette": {"kind": "sequential", "name": "blue"},
        "legend": {"position": "bottom"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Elapsed timing bucket",
        "yAxisTitle": "Share of recipients",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 6,
    },
    {
        "id": "chart_activity_segment_rates",
        "title": "Active-recipient rate by claim-size segment",
        "subtitle": "Four observed claim-size groups; 24-hour and seven-day elapsed windows",
        "type": "bar",
        "intent": "comparison",
        "question": "Did basic post-claim participation differ materially by claim size?",
        "rationale": "Grouped bars show the two window rates on a common percentage scale for each claim-size segment.",
        "comparisonContext": {"denominator": "recipients within each claim-size segment", "grain": "segment-window", "unit": "share"},
        "dataset": "activity_segment_rates",
        "sourceId": "src_post_claim_activity",
        "encodings": {
            "x": {"field": "claim_size_segment", "type": "ordinal", "label": "Claim-size segment"},
            "y": {"field": "active_recipient_rate", "type": "quantitative", "format": "percent", "label": "Active-recipient rate"},
            "color": {"field": "window", "type": "nominal", "label": "Elapsed window"},
            "tooltip": [
                {"field": "active_recipients", "type": "quantitative", "format": "compact", "label": "Active recipients"},
                {"field": "recipient_count", "type": "quantitative", "format": "compact", "label": "Segment recipients"},
            ],
        },
        "palette": {"kind": "categorical", "name": "blue-gold"},
        "legend": {"position": "bottom", "sort": "spec"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Claim-size segment",
        "yAxisTitle": "Active-recipient rate",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 8,
    },
    {
        "id": "chart_activity_segment_depth",
        "title": "Seven-day transaction depth by claim-size segment",
        "subtitle": "Average successful transactions per active recipient within seven elapsed days",
        "type": "horizontalBar",
        "intent": "comparison",
        "question": "How did the depth of post-claim activity vary by claim size?",
        "rationale": "Horizontal bars make the ordered segment labels readable and emphasize the monotonic increase in transaction depth.",
        "comparisonContext": {"denominator": "active recipients in each claim-size segment", "grain": "segment", "unit": "transactions per active recipient"},
        "dataset": "activity_segment_depth",
        "sourceId": "src_post_claim_activity",
        "encodings": {
            "x": {"field": "claim_size_segment", "type": "ordinal", "label": "Claim-size segment"},
            "y": {"field": "average_transactions_per_active_recipient_7d", "type": "quantitative", "format": "number", "label": "Average transactions per active recipient"},
            "tooltip": [
                {"field": "active_recipients_7d", "type": "quantitative", "format": "compact", "label": "Active recipients"},
                {"field": "average_active_utc_days_per_active_recipient_7d", "type": "quantitative", "format": "number", "label": "Average active UTC days"},
                {"field": "average_distinct_targets_per_active_recipient_7d", "type": "quantitative", "format": "number", "label": "Average distinct targets"},
            ],
        },
        "palette": {"kind": "sequential", "name": "gold"},
        "legend": {"position": "bottom"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Claim-size segment",
        "yAxisTitle": "Transactions per active recipient",
        "valueFormat": "number",
        "layout": "full",
        "maxRows": 4,
    },
    {
        "id": "chart_activity_intensity",
        "title": "Seven-day activity intensity",
        "subtitle": "Recipient share compared with share of 3.87M qualifying successful transactions",
        "type": "horizontalBar",
        "intent": "comparison",
        "question": "How concentrated were seven-day transaction rows among recipients with different activity intensity?",
        "rationale": "Grouped horizontal bars compare population share with transaction-row share across long intensity labels.",
        "comparisonContext": {"denominator": "all recipients or all seven-day qualifying transactions", "grain": "intensity bucket-measure", "unit": "share"},
        "dataset": "activity_intensity",
        "sourceId": "src_post_claim_activity",
        "encodings": {
            "x": {"field": "transaction_count_bucket", "type": "ordinal", "label": "Seven-day transaction-count bucket"},
            "y": {"field": "share", "type": "quantitative", "format": "percent", "label": "Share"},
            "color": {"field": "measure", "type": "nominal", "label": "Measure"},
            "tooltip": [
                {"field": "recipient_count", "type": "quantitative", "format": "compact", "label": "Recipients"},
                {"field": "successful_transaction_rows", "type": "quantitative", "format": "compact", "label": "Successful transactions"},
            ],
        },
        "palette": {"kind": "categorical", "name": "blue-gold"},
        "legend": {"position": "bottom", "sort": "spec"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Seven-day activity-intensity bucket",
        "yAxisTitle": "Share",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 10,
    },
    {
        "id": "chart_balance_distribution",
        "title": "Transfer-derived total ARB balance relative to claim amount",
        "subtitle": "Five exhaustive recipient buckets at seven-day and 30-day elapsed cutoffs",
        "type": "bar",
        "intent": "comparison",
        "question": "How were recipients distributed across total ARB balance-to-claim buckets at each cutoff?",
        "rationale": "Grouped bars compare the same ordered, exhaustive balance buckets at the two discrete cutoffs.",
        "comparisonContext": {
            "denominator": "583,137 claim recipients per cutoff",
            "grain": "cutoff-bucket",
            "unit": "share",
        },
        "dataset": "balance_bucket_distribution",
        "sourceId": "src_balance_proxy",
        "encodings": {
            "x": {
                "field": "balance_to_claim_bucket",
                "type": "ordinal",
                "label": "Total balance relative to claim amount",
            },
            "y": {
                "field": "recipient_share",
                "type": "quantitative",
                "format": "percent",
                "label": "Share of recipients",
            },
            "color": {
                "field": "cutoff_label",
                "type": "nominal",
                "label": "Elapsed cutoff",
            },
            "tooltip": [
                {
                    "field": "recipient_count",
                    "type": "quantitative",
                    "format": "compact",
                    "label": "Recipients",
                },
                {
                    "field": "recipient_share",
                    "type": "quantitative",
                    "format": "percent",
                    "label": "Share",
                },
            ],
        },
        "palette": {"kind": "categorical", "name": "blue-gold"},
        "legend": {"position": "bottom", "sort": "spec"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Total balance relative to claim amount",
        "yAxisTitle": "Share of recipients",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 10,
    },
    {
        "id": "chart_balance_adjusted_proxy",
        "title": "Pre-claim-adjusted ARB balance proxy",
        "subtitle": "Capped share of claimed ARB at two discrete elapsed cutoffs",
        "type": "bar",
        "intent": "comparison",
        "question": "What share of claimed ARB remained under the capped, pre-claim-adjusted transfer-derived proxy?",
        "rationale": "Two zero-based bars compare discrete cutoffs without implying a continuous trend.",
        "comparisonContext": {
            "denominator": "1,092,811,500 claimed ARB",
            "grain": "elapsed cutoff",
            "unit": "share",
        },
        "dataset": "balance_adjusted_proxy",
        "sourceId": "src_balance_proxy",
        "encodings": {
            "x": {
                "field": "cutoff_label",
                "type": "ordinal",
                "label": "Elapsed cutoff",
            },
            "y": {
                "field": "adjusted_retained_claim_proxy_share",
                "type": "quantitative",
                "format": "percent",
                "label": "Share of claimed ARB",
            },
            "tooltip": [
                {
                    "field": "adjusted_retained_claim_proxy_arb",
                    "type": "quantitative",
                    "format": "compact",
                    "unit": "ARB",
                    "label": "Adjusted proxy",
                },
                {
                    "field": "adjusted_retained_claim_proxy_share",
                    "type": "quantitative",
                    "format": "percent",
                    "label": "Share",
                },
            ],
        },
        "palette": {"kind": "sequential", "name": "blue"},
        "labels": {"values": "auto"},
        "xAxisTitle": "Elapsed cutoff",
        "yAxisTitle": "Share of claimed ARB",
        "valueFormat": "percent",
        "layout": "full",
        "maxRows": 2,
    },
]

blocks = [
    {
        "id": "title",
        "type": "markdown",
        "body": (
            "# ARB Airdrop: Early Outflow, Address Activity and Transfer-Derived Balance Proxies\n\n"
            "By **Nikita Onchain** · [Source repository](https://github.com/NikitaOnchain/onchain-analytics-portfolio)"
        ),
    },
    {
        "id": "technical_summary",
        "type": "markdown",
        "body": (
            "## Technical summary\n\n"
            "Fast ARB redistribution and broad address-level activity coexist in the validated claim cohort. "
            "Within seven elapsed days, 85.5% of recipients had positive early outflow and 90.9% initiated another successful Arbitrum transaction. "
            "Separately, 62.8% had a zero transfer-derived ARB balance at seven days, increasing to 64.4% at 30 days; the capped pre-claim-adjusted balance proxy declined from 21.7% to 14.2% of claimed ARB. "
            "These measures describe token movement, address activity, and transfer-derived balance separately. They do not establish sales, protocol engagement, human retention, or causal airdrop quality."
        ),
    },
    {
        "id": "headline_metrics",
        "type": "metric-strip",
        "cardIds": [
            "card_recipients",
            "card_claimed_arb",
            "card_positive_outflow",
            "card_claim_linked_proxy",
            "card_active_recipients",
            "card_adjusted_balance_proxy",
        ],
    },
    {
        "id": "early_outflow_finding",
        "type": "markdown",
        "sourceId": "src_early_outflow",
        "body": (
            "## Most recipients moved ARB early, but the measure is not a sales estimate\n\n"
            "Within 24 elapsed hours, **459,437 recipients (78.8%)** had at least one positive non-self ARB outflow; within seven days, the count reached **498,511 (85.5%)**. The first qualifying outflow occurred within one hour for **354,666 recipients (60.8%)**, while **84,626 (14.5%)** had no qualifying positive outflow in the first seven days.\n\n"
            "The timing indicates rapid redistribution from claiming addresses. Destination and swap classification are not part of this baseline, so the result must be described as **early outflow**, not selling."
        ),
    },
    {"id": "early_timing_chart", "type": "chart", "chartId": "chart_early_timing"},
    {
        "id": "proxy_finding",
        "type": "markdown",
        "sourceId": "src_early_outflow",
        "body": (
            "## The capped claim-linked proxy reached 80.4% of claimed ARB within seven days\n\n"
            "Cumulative positive outflow can exceed a claim because ARB is fungible and wallets may hold or receive ARB from other sources. To bound the claim-related signal, the analysis caps each recipient's cumulative positive outflow at that recipient's claim amount. The resulting claim-linked outflow proxy represented **73.0% of claimed ARB within 24 hours** and **80.4% within seven days**. The complementary retained-claim proxies were **27.0%** and **19.6%**.\n\n"
            "This is a balance-style proxy, not token-unit tracing: it does not prove which ARB units moved or remained."
        ),
    },
    {"id": "early_composition_chart", "type": "chart", "chartId": "chart_early_composition"},
    {
        "id": "balance_distribution_finding",
        "type": "markdown",
        "sourceId": "src_balance_proxy",
        "body": (
            "## Zero transfer-derived balances became slightly more common by day 30\n\n"
            "At the seven-day cutoff, **365,994 recipients (62.8%)** had a zero transfer-derived ARB balance; at 30 days, the count was **375,348 (64.4%)**. The **75–100%** bucket fell from **88,386 recipients (15.2%)** to **53,530 (9.2%)**.\n\n"
            "The total-balance buckets include pre-claim holdings and later ARB inflows. The **greater-than-100%** bucket therefore does not imply retained airdrop units; it can reflect additional ARB received after claim."
        ),
    },
    {
        "id": "balance_distribution_chart",
        "type": "chart",
        "chartId": "chart_balance_distribution",
    },
    {
        "id": "balance_adjusted_finding",
        "type": "markdown",
        "sourceId": "src_balance_proxy",
        "body": (
            "## The adjusted balance proxy declined from 21.7% at seven days to 14.2% at 30 days\n\n"
            "The capped pre-claim-adjusted proxy represented **237.176 million ARB (21.7% of claimed ARB)** at seven days and **155.286 million ARB (14.2%)** at 30 days. For the **4,710 recipients (0.8%)** with a positive transfer-derived balance before claim, that positive amount is removed before each recipient's proxy is capped between zero and the claim amount.\n\n"
            "This adjustment reduces obvious pre-claim contamination but cannot trace fungible claimed units. It is a transfer-derived balance proxy, not exact token retention or evidence that the same human remained active."
        ),
    },
    {
        "id": "balance_adjusted_chart",
        "type": "chart",
        "chartId": "chart_balance_adjusted_proxy",
    },
    {
        "id": "activity_breadth_finding",
        "type": "markdown",
        "sourceId": "src_post_claim_activity",
        "body": (
            "## Address-level activity was broader than the early-outflow signal\n\n"
            "A recipient is active when the claiming address initiates at least one successful top-level Arbitrum transaction after exact claim order. By this definition, **482,559 recipients (82.8%)** were active within 24 hours and **530,248 (90.9%)** within seven days. First activity occurred within one hour for **378,291 recipients (64.9%)**; **52,889 (9.1%)** had no qualifying activity within seven days.\n\n"
            "This measures transaction initiation by an address. It does not identify the human behind the address, the protocol used, token retention, or economic intent."
        ),
    },
    {"id": "activity_timing_chart", "type": "chart", "chartId": "chart_activity_timing"},
    {
        "id": "claim_size_finding",
        "type": "markdown",
        "sourceId": "src_post_claim_activity",
        "body": (
            "## Claim size was associated with activity depth more than participation breadth\n\n"
            "Seven-day active-recipient rates were tightly grouped across the four observed claim-size segments, ranging from **90.0% to 91.3%**. Transaction depth varied much more: active recipients averaged **4.33** seven-day transactions in the 625–875 ARB segment and **12.05** in the 2,500–10,250 ARB segment.\n\n"
            "The descriptive pattern suggests that larger claims were associated with more intensive address activity, not materially broader basic participation. It does not establish that claim size caused later activity; recipients may differ on pre-airdrop characteristics that are not controlled here."
        ),
    },
    {"id": "activity_segment_rate_chart", "type": "chart", "chartId": "chart_activity_segment_rates"},
    {
        "id": "claim_size_depth_note",
        "type": "markdown",
        "sourceId": "src_post_claim_activity",
        "body": (
            "The participation chart shows the narrow spread in seven-day active-recipient rates. "
            "The next chart isolates transaction depth among active recipients, where the separation by claim-size segment is much larger."
        ),
    },
    {"id": "activity_segment_depth_chart", "type": "chart", "chartId": "chart_activity_segment_depth"},
    {
        "id": "activity_intensity_finding",
        "type": "markdown",
        "sourceId": "src_post_claim_activity",
        "body": (
            "## A small high-frequency group generated most seven-day transactions\n\n"
            "The **68,422 recipients with 11 or more qualifying transactions** represented **11.7% of the cohort** but produced **2,560,456 transactions, or 66.1% of all seven-day transaction rows**. By contrast, the 2–5 transaction group was the largest recipient group at **40.4%**, yet contributed **17.5%** of transaction rows.\n\n"
            "Breadth and depth therefore answer different questions: the active-recipient rate shows how widely activity occurred, while the intensity distribution shows that most observed transaction volume came from a much smaller set of addresses."
        ),
    },
    {"id": "activity_intensity_chart", "type": "chart", "chartId": "chart_activity_intensity"},
    {
        "id": "scope",
        "type": "markdown",
        "sourceId": "src_claim_cohort",
        "body": (
            "## The validated cohort contains 583,137 unique recipients and 1.093B claimed ARB\n\n"
            "The cohort covers observed `HasClaimed(address,uint256)` events from **23 March through 24 September 2023**. Each report row ultimately resolves to one validated claim event and one unique recipient. The cohort contains **583,137 claim events and recipients**, **583,131 distinct claim transactions**, and **1,092,811,500 claimed ARB**. Transaction hash alone is therefore not a unique event-grain key."
        ),
    },
    {
        "id": "definitions",
        "type": "markdown",
        "body": (
            "## Metric definitions keep transfer behavior separate from address activity\n\n"
            "- **Positive early outflow:** a positive, non-self ARB transfer from the recipient after exact claim order, measured in half-open elapsed windows of 24 hours and seven days.\n"
            "- **Claim-linked outflow proxy:** cumulative qualifying outflow capped at the recipient's claim amount.\n"
            "- **Retained-claim proxy:** claim amount minus the capped claim-linked outflow proxy.\n"
            "- **Transfer-derived total ARB balance proxy:** net signed ARB transfer legs at an exact cutoff, including pre-claim holdings, the claim transfer, and later inflows and outflows.\n"
            "- **Pre-claim-adjusted balance proxy:** transfer-derived total balance minus positive pre-claim balance, capped between zero and claim amount per recipient before aggregation.\n"
            "- **Post-claim activity:** a successful top-level Arbitrum transaction initiated by the claim recipient after exact claim order, measured in the same elapsed windows.\n"
            "- **Active recipient:** a recipient with at least one qualifying post-claim transaction in the stated window."
        ),
    },
    {
        "id": "methodology",
        "type": "markdown",
        "body": (
            "## Reproducibility depends on claim-grain tables and explicit event ordering\n\n"
            "The claim cohort was decoded from raw Arbitrum logs and reconciled against decoded distributor-to-recipient ARB transfers. Event-level source tables were materialized in bounded BigQuery Sandbox chunks, then reduced to one row per validated claim recipient before chart aggregation. Claim and later-event order keys prevent same-block events that precede the claim from entering the elapsed windows.\n\n"
            "The chart queries aggregate the claim-grain metric tables without row-level joins, so they do not multiply recipients. Versioned SQL documents source grain, join cardinality, time filters, and row-multiplication risk. The published charts are rebuilt from small versioned JSON artifacts and require no new BigQuery scan.\n\n"
            "For the 7-day/30-day balance layer, incoming and outgoing ARB transfer legs are signed at claimant endpoints; exact block, transaction, and log order separates pre-claim legs, and cutoff windows include only events strictly before each elapsed boundary. Self-transfers net to zero."
        ),
    },
    {
        "id": "limitations",
        "type": "markdown",
        "body": (
            "## Internal QA is strong, but interpretation remains intentionally bounded\n\n"
            "Duplicate, critical-null, metric-domain, layer-reconciliation, bounded-subset, and deterministic wallet-sample checks passed for the full-cohort baselines. Chart totals reconcile exactly to their source metric tables. The cohort count was also compared with an independent public reference.\n\n"
            "Important limitations remain:\n\n"
            "- Destination labels and DEX swaps are not classified, so early outflow is not a sales estimate.\n"
            "- Fungibility prevents exact attribution of specific airdropped token units.\n"
            "- Historical token-balance snapshots were unavailable; the 7-day/30-day result is reconstructed from validated transfer legs and is explicitly named a proxy.\n"
            "- Total balance above 100% of claim amount can reflect later inflow, while the adjusted aggregate proxy is capped per recipient.\n"
            "- Address activity is not proof of retained human usage, protocol engagement, or token retention.\n"
            "- The claim-size comparisons are descriptive and do not control for recipient selection or prior behavior.\n"
            "- No independent public benchmark was identified for the exact full-cohort early-outflow or post-claim activity metrics."
        ),
    },
    {
        "id": "next_steps",
        "type": "markdown",
        "body": (
            "## Recommended next steps\n\n"
            "1. Classify verified DEX swaps and reliably labeled exchange destinations before making any statement about sales behavior.\n"
            "2. Break post-claim transactions into protocol and action categories to distinguish simple address activity from sustained ecosystem engagement.\n"
            "3. Add a longer-window sensitivity analysis only after preserving the same claim grain, event-order rules, and QA controls."
        ),
    },
    {
        "id": "further_questions",
        "type": "markdown",
        "body": (
            "## Further questions\n\n"
            "- What share of early outflow can be linked to verified swaps, bridges, centralized exchanges, or transfers between addresses controlled by the same entity?\n"
            "- Which protocols and transaction types account for the observed seven-day activity?\n"
            "- How sensitive are the reported proxy measures to alternative, equally explicit transfer and destination definitions?"
        ),
    },
]

artifact = {
    "surface": "report",
    "manifest": {
        "version": 1,
        "surface": "report",
        "title": "ARB Airdrop: Early Outflow, Address Activity and Transfer-Derived Balance Proxies",
        "description": "A reproducible technical analysis of ARB early outflow, address activity, and transfer-derived balance proxies through 30 days after claim.",
        "generatedAt": "2026-08-23",
        "filters": [],
        "cards": cards,
        "charts": charts,
        "tables": [],
        "sources": source_manifest,
        "blocks": blocks,
    },
    "snapshot": {
        "version": 1,
        "generatedAt": "2026-08-23",
        "status": "ready",
        "datasets": {
            "headline_cohort": headline_cohort,
            "headline_early": headline_early,
            "headline_activity": headline_activity,
            "headline_balance": headline_balance,
            "early_timing": early_timing,
            "early_composition": early_composition,
            "activity_timing": activity_timing,
            "activity_segment_rates": activity_segment_rates,
            "activity_segment_depth": activity_segment_depth,
            "activity_intensity": activity_intensity,
            "balance_bucket_distribution": balance_bucket_distribution,
            "balance_adjusted_proxy": balance_adjusted_proxy,
        },
        "accessIssues": [],
    },
    "sources": source_details,
    "package_info": {
        "author": "Nikita Onchain",
        "report_role": "Public technical portfolio case study",
    },
}

output_path = REPORTS / "arb_airdrop_report_artifact.json"
output_path.write_text(
    json.dumps(artifact, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
print(output_path)

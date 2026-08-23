"""Validate the public ARB airdrop portfolio case entirely offline.

The validator reads tracked repository files and local Git state. It performs
no BigQuery, RPC, browser automation, dependency installation, or network call.
It does not inspect Git identity, credentials, remotes, or private checkpoints.
"""

from __future__ import annotations

import ast
import hashlib
import json
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_REPOSITORY_URL = "https://github.com/NikitaOnchain/onchain-analytics-portfolio"
STALE_REPOSITORY_SLUG = "NikitaOnchain" + "/arb-airdrop-analysis"
REQUIRED_ANALYTICAL_INPUTS = {
    "data/claim_cohort_profile.json",
    "data/early_outflow_chart_data.json",
    "data/early_outflow_chart_data_qa.json",
    "data/post_claim_activity_chart_data.json",
    "data/post_claim_activity_chart_data_qa.json",
    "data/retention_arb_balance_proxy_chart_data.json",
    "data/retention_arb_balance_proxy_chart_data_qa.json",
    "sql/03_profile_claim_cohort.sql",
    "sql/50_export_early_outflow_chart_data.sql",
    "sql/75_export_post_claim_activity_chart_data.sql",
    "sql/86b_profile_transfer_derived_arb_balance_proxy.sql",
}
TEXT_SUFFIXES = {
    ".gitignore", ".html", ".ipynb", ".json", ".md", ".mjs",
    ".ps1", ".psm1", ".py", ".sql", ".txt", ".yaml", ".yml",
}


def load_json(relative_path: str):
    with (ROOT / relative_path).open(encoding="utf-8") as handle:
        return json.load(handle)


def sha256(relative_path: str) -> str:
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    canonical = text.replace("\r\n", "\n").encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def run_git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=check, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def git_paths(*args: str) -> list[str]:
    return [line for line in run_git(*args).stdout.splitlines() if line]


def literal_assignment(source: str, name: str):
    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise ValueError(f"Assignment {name} was not found")


def actual_builder_inputs(source: str) -> tuple[set[str], set[str]]:
    tree = ast.parse(source)
    analytical: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
            continue
        if node.func.id not in {"load_json", "load_text"} or not node.args:
            continue
        argument = node.args[0]
        if not isinstance(argument, ast.Constant) or not isinstance(argument.value, str):
            continue
        analytical.add(argument.value)
    return analytical, set()


class ReportHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.html_lang: str | None = None
        self.document_title_parts: list[str] = []
        self.h1_parts: list[str] = []
        self.links: list[str] = []
        self.external_resources: list[str] = []
        self._in_title = False
        self._in_h1 = False

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = dict(attrs)
        if tag == "html":
            self.html_lang = attributes.get("lang")
        elif tag == "title":
            self._in_title = True
        elif tag == "h1":
            self._in_h1 = True
        elif tag == "a" and attributes.get("href"):
            self.links.append(attributes["href"])
        if tag in {"script", "img", "link", "iframe", "source"}:
            resource = attributes.get("src") or attributes.get("href")
            if resource and re.match(r"(?i)https?://|//", resource):
                self.external_resources.append(resource)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        elif tag == "h1":
            self._in_h1 = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.document_title_parts.append(data)
        if self._in_h1:
            self.h1_parts.append(data)


def scan_privacy(paths: list[str]) -> tuple[list[dict[str, object]], int]:
    private_project = re.compile("codex" + r"-bq-sbx-[a-z0-9-]+", re.IGNORECASE)
    private_dataset = re.compile("arb" + "_airdrop" + "_work", re.IGNORECASE)
    patterns = {
        "windows_user_path": re.compile(r"(?i)[A-Z]:[\\/]Users[\\/][^\\/\s\"'<>]+"),
        "absolute_workspace_path": re.compile(r"(?i)[A-Z]:[\\/](?:web3[\\/]arb-airdrop-analysis|plan[ ]gpt)(?:[\\/]|\b)"),
        "private_bigquery_project": private_project,
        "private_bigquery_dataset": private_dataset,
        "bigquery_job_id": re.compile(r"(?i)\bbquxjob_[a-z0-9_]+\b"),
        "unredacted_job_id_field": re.compile(r'(?i)"job_id"\s*:\s*"(?!REDACTED_JOB_ID|YOUR_|<)[^"\r\n]+"'),
        "email": re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"),
        "oauth_token": re.compile(r"(?i)\bya29\.[A-Za-z0-9._-]{12,}"),
        "bearer_token": re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._-]{16,}"),
        "private_key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        "google_api_key": re.compile(r"\bAIza[A-Za-z0-9_-]{30,}\b"),
        "aws_access_key": re.compile(r"\bAKIA[A-Z0-9]{16}\b"),
        "github_token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
        "openai_style_key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
        "credential_assignment": re.compile(
            r'''(?ix)["'](?:access_token|refresh_token|client_secret|private_key)["']
            \s*[:=]\s*["'](?!REDACTED|YOUR_|<)[^"']{8,}["']'''
        ),
    }
    findings: list[dict[str, object]] = []
    synthetic_fixture_matches = 0
    for relative_path in paths:
        path = ROOT / relative_path
        if not path.is_file():
            continue
        suffix = ".gitignore" if relative_path == ".gitignore" else path.suffix.lower()
        if suffix not in TEXT_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for category, pattern in patterns.items():
            count = len(pattern.findall(text))
            if not count:
                continue
            if relative_path.startswith("tests/fixtures/") and re.search(r"(?i)synthetic|fixture|fake|example", text):
                synthetic_fixture_matches += count
                continue
            findings.append({"path": relative_path, "category": category, "count": count})
    return findings, synthetic_fixture_matches


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("invalid PNG signature or IHDR")
    return struct.unpack(">II", data[16:24])


def markdown_local_links(text: str) -> set[str]:
    paths: set[str] = set()
    for raw in re.findall(r"!?(?:\[[^\]]*\])\(([^)]+)\)", text):
        target = raw.strip().strip("<>").split("#", 1)[0]
        if not target or re.match(r"(?i)https?://|mailto:", target):
            continue
        paths.add(unquote(target).replace("\\", "/"))
    return paths


def main() -> None:
    checks: dict[str, bool] = {}
    defects: list[str] = []

    def check(name: str, passed: bool) -> None:
        checks[name] = bool(passed)
        if not passed:
            defects.append(name)

    tracked = git_paths("ls-files")
    tracked_set = set(tracked)
    unstaged = git_paths("diff", "--name-only")
    untracked = git_paths("ls-files", "--others", "--exclude-standard")

    internal_paths = sorted(
        path for path in tracked
        if path in {"AGENTS.md", "STATUS.md"}
        or path.lower().endswith(".bak")
        or "checkpoint" in Path(path).name.lower()
        or "build_progress" in Path(path).name.lower()
        or path in {
            "data/public_v1_release_inclusion_manifest.json",
            "data/public_v1_report_delivery_receipt.json",
            "data/public_v1_report_share_readiness_audit.json",
            "reports/public_v1_balance_proxy_integration_plan.md",
            "scripts/build_public_v1_release_manifest.py",
        }
    )
    check("internal_release_and_checkpoint_paths_are_absent", not internal_paths)

    reference_pattern = re.compile(
        r"(?i)(?:[A-Za-z0-9_./-]*(?:checkpoint|build_progress)[A-Za-z0-9_./-]*\.json"
        r"|public_v1_release_inclusion_manifest\.json"
        r"|public_v1_corrective_release_[A-Za-z0-9_.-]*"
        r"|public_v1_report_(?:delivery_receipt|share_readiness_audit)\.json)"
    )
    internal_references: list[dict[str, object]] = []
    stale_repository_references: list[str] = []
    repository_url_files: list[str] = []
    for relative_path in tracked:
        path = ROOT / relative_path
        suffix = ".gitignore" if relative_path == ".gitignore" else path.suffix.lower()
        if not path.is_file() or suffix not in TEXT_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if relative_path not in {".gitignore", "scripts/validate_public_v1_report.py"}:
            matches = reference_pattern.findall(text)
            if matches:
                internal_references.append({"path": relative_path, "count": len(matches)})
        if STALE_REPOSITORY_SLUG.lower() in text.lower():
            stale_repository_references.append(relative_path)
        if EXPECTED_REPOSITORY_URL in text:
            repository_url_files.append(relative_path)
    check("internal_checkpoint_references_are_absent", not internal_references)
    check("stale_repository_slug_is_absent", not stale_repository_references)
    check(
        "canonical_repository_url_is_in_report_sources",
        {
            "reports/build_portfolio_report.py",
            "reports/arb_airdrop_report_artifact.json",
            "reports/arb_airdrop_report.html",
        } <= set(repository_url_files),
    )

    builder_path = "reports/build_portfolio_report.py"
    builder_text = (ROOT / builder_path).read_text(encoding="utf-8")
    actual_inputs, _ = actual_builder_inputs(builder_text)
    pinned_inputs = literal_assignment(builder_text, "REPORT_ANALYTICAL_INPUT_SHA256")
    pinned_input_paths = set(pinned_inputs)
    missing_inputs = sorted(path for path in pinned_input_paths if not (ROOT / path).is_file())
    input_hash_mismatches = sorted(
        path for path, expected in pinned_inputs.items()
        if (ROOT / path).is_file() and sha256(path) != expected
    )
    check("builder_inputs_match_pinned_input_map", actual_inputs == pinned_input_paths)
    check("required_analytical_inputs_are_declared", REQUIRED_ANALYTICAL_INPUTS == pinned_input_paths)
    check("builder_inputs_exist", not missing_inputs)
    check("builder_input_hashes_match", not input_hash_mismatches)
    check("symmetric_pipeline_is_not_a_report_input", not any("symmetric" in path.lower() for path in actual_inputs))

    expected_figures = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "figures").iterdir()
        if path.suffix.lower() in {".png", ".svg"}
    }
    check("all_sixteen_figures_exist", len(expected_figures) == 16 and expected_figures <= tracked_set)

    json_failures: list[str] = []
    notebook_error_outputs: dict[str, int] = {}
    notebook_absolute_outputs: dict[str, int] = {}
    for relative_path in tracked:
        if not relative_path.endswith((".json", ".ipynb")):
            continue
        try:
            parsed = load_json(relative_path)
        except (json.JSONDecodeError, UnicodeDecodeError):
            json_failures.append(relative_path)
            continue
        if relative_path.endswith(".ipynb"):
            errors = 0
            absolute_outputs = 0
            for cell in parsed.get("cells", []):
                for output in cell.get("outputs", []):
                    errors += int(output.get("output_type") == "error")
                    output_text = "".join(output.get("text", []))
                    output_text += "".join(output.get("data", {}).get("text/plain", []))
                    absolute_outputs += int(bool(re.search(r"(?i)[A-Z]:[\\/]", output_text)))
            notebook_error_outputs[relative_path] = errors
            notebook_absolute_outputs[relative_path] = absolute_outputs
    check("all_json_and_notebooks_parse", not json_failures)
    check("notebook_error_outputs_are_absent", sum(notebook_error_outputs.values()) == 0)
    check("notebook_absolute_paths_are_absent", sum(notebook_absolute_outputs.values()) == 0)

    png_profiles: dict[str, dict[str, int]] = {}
    png_failures: list[str] = []
    svg_profiles: dict[str, dict[str, object]] = {}
    svg_failures: list[str] = []
    for relative_path in sorted(expected_figures):
        if relative_path.endswith(".png"):
            try:
                width, height = png_dimensions(ROOT / relative_path)
                if width <= 0 or height <= 0:
                    raise ValueError("non-positive dimensions")
                png_profiles[relative_path] = {"width": width, "height": height}
            except ValueError:
                png_failures.append(relative_path)
        elif relative_path.endswith(".svg"):
            try:
                root = ET.parse(ROOT / relative_path).getroot()
                svg_profiles[relative_path] = {"tag": root.tag, "viewBox": root.attrib.get("viewBox")}
            except ET.ParseError:
                svg_failures.append(relative_path)
    check("png_signatures_and_dimensions_pass", len(png_profiles) == 8 and not png_failures)
    check("svg_xml_parsing_passes", len(svg_profiles) == 8 and not svg_failures)

    powershell_failures: list[str] = []
    for relative_path in (path for path in tracked if path.endswith((".ps1", ".psm1"))):
        command = "$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$tokens,[ref]$errors)>$null;if($errors.Count){exit 1}"
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-Command", command, str(ROOT / relative_path)],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if result.returncode:
            powershell_failures.append(relative_path)
    check("tracked_powershell_files_parse", not powershell_failures)

    cohort_raw = load_json("data/claim_cohort_profile.json")
    cohort = cohort_raw[0] if isinstance(cohort_raw, list) else cohort_raw
    early = load_json("data/early_outflow_chart_data.json")
    activity = load_json("data/post_claim_activity_chart_data.json")
    balance = load_json("data/retention_arb_balance_proxy_chart_data.json")
    artifact = load_json("reports/arb_airdrop_report_artifact.json")
    locale_qa = load_json("data/public_v1_report_locale_qa.json")
    artifact_text = json.dumps(artifact, ensure_ascii=False)
    html_text = (ROOT / "reports/arb_airdrop_report.html").read_text(encoding="utf-8")
    readme_text = (ROOT / "README.md").read_text(encoding="utf-8")
    report_manifest = artifact["manifest"]
    datasets = artifact["snapshot"]["datasets"]

    recipient_count = int(cohort["distinct_recipients"])
    claimed_arb = int(cohort["provisional_total_claimed_arb"])
    check("canonical_claim_cohort_values_match", recipient_count == 583137 and claimed_arb == 1092811500)
    check(
        "report_artifact_structure_is_complete",
        artifact.get("surface") == "report"
        and artifact["snapshot"].get("status") == "ready"
        and len(report_manifest["charts"]) == 8
        and len(report_manifest["cards"]) == 6
        and len(report_manifest["blocks"]) == 25,
    )

    early_windows = {row["window_label"]: row for row in early["window_summary"]}
    activity_windows = {row["window_label"]: row for row in activity["window_summary"]}
    check("headline_early_matches_source", datasets["headline_early"] == [{
        "positive_outflow_rate_24h": float(early_windows["Within 24 hours"]["recipient_positive_outflow_rate"]),
        "positive_outflow_rate_7d": float(early_windows["Within 7 days"]["recipient_positive_outflow_rate"]),
        "claim_linked_outflow_share_24h": float(early_windows["Within 24 hours"]["claim_linked_outflow_share"]),
        "claim_linked_outflow_share_7d": float(early_windows["Within 7 days"]["claim_linked_outflow_share"]),
    }])
    check("headline_activity_matches_source", datasets["headline_activity"] == [{
        "active_recipient_rate_24h": float(activity_windows["Within 24 hours"]["active_recipient_rate"]),
        "active_recipient_rate_7d": float(activity_windows["Within 7 days"]["active_recipient_rate"]),
    }])
    expected_balance_buckets = [
        {
            "cutoff_order": row["cutoff_order"],
            "cutoff_label": row["cutoff_label"],
            "bucket_order": row["bucket_order"],
            "balance_to_claim_bucket": row["balance_to_claim_bucket"],
            "recipient_count": row["recipient_count"],
            "recipient_share": float(row["recipient_share"]),
        }
        for row in balance["balance_to_claim_bucket_distribution"]
    ]
    check("balance_bucket_dataset_matches_source", datasets["balance_bucket_distribution"] == expected_balance_buckets)
    check("balance_bucket_counts_reconcile", {
        cutoff: sum(
            row["recipient_count"]
            for row in balance["balance_to_claim_bucket_distribution"]
            if row["cutoff_days"] == cutoff
        )
        for cutoff in (7, 30)
    } == {7: recipient_count, 30: recipient_count})

    required_public_numbers = [
        "583,137", "1,092,811,500", "459,437", "498,511", "482,559",
        "530,248", "365,994", "375,348", "21.7%", "14.2%",
    ]
    check("readme_contains_all_headline_values", all(value in readme_text for value in required_public_numbers))
    check("artifact_contains_all_headline_values", all(value.replace(",", "") in artifact_text.replace(",", "") for value in required_public_numbers))
    check("html_contains_all_headline_values", all(value.replace(",", "") in html_text.replace(",", "") for value in required_public_numbers))

    expected_svg_labels = {
        "figures/01_first_positive_outflow_timing.svg": ["60.8%", "14.5%"],
        "figures/02_positive_outflow_rate_by_claim_size.svg": [
            label
            for row in early["claim_size_segments"]
            for label in (
                f'{row["recipient_positive_outflow_rate_24h"]:.1%}',
                f'{row["recipient_positive_outflow_rate_7d"]:.1%}',
            )
        ],
        "figures/03_claim_linked_outflow_composition.svg": ["73.0%", "80.4%"],
        "figures/04_first_post_claim_activity_timing.svg": ["64.9%", "9.1%"],
        "figures/05_post_claim_activity_by_claim_size.svg": ["90.0%", "91.3%"],
        "figures/06_post_claim_activity_intensity.svg": ["11.7%", "66.1%"],
        "figures/07_transfer_derived_arb_balance_proxy_distribution.svg": ["62.8%", "64.4%"],
        "figures/08_adjusted_retained_claim_proxy.svg": ["21.7%", "14.2%"],
    }
    svg_label_failures = [
        path for path, labels in expected_svg_labels.items()
        if not all(label in (ROOT / path).read_text(encoding="utf-8") for label in labels)
    ]
    check("figure_svg_headline_labels_match_sources", not svg_label_failures)

    parser = ReportHTMLParser()
    parser.feed(html_text)
    title = "".join(parser.document_title_parts).strip()
    h1_values = [value.strip() for value in parser.h1_parts if value.strip()]
    locale_marker = 'data-public-v1-report-locale="en-US"'
    check(
        "html_language_and_titles_are_english",
        parser.html_lang == "en" and title == report_manifest["title"] and report_manifest["title"] in h1_values,
    )
    check("public_html_has_no_cyrillic", re.search(r"[\u0400-\u04ff]", html_text) is None)
    check("html_is_self_contained", not parser.external_resources)
    check("html_has_semantic_fallback", 'data-portable-fallback="true"' in html_text)
    check("html_has_packaged_reader", 'data-data-analytics-portable-artifact="true"' in html_text)
    check(
        "english_locale_guard_is_unique_and_early",
        html_text.count(locale_marker) == 1
        and 0 <= html_text.find(locale_marker) < html_text.find('id="data-analytics-portable-reader-runtime-source"'),
    )
    check(
        "locale_qa_matches_current_html",
        locale_qa.get("status") == "passed"
        and locale_qa.get("html_sha256") == sha256("reports/arb_airdrop_report.html")
        and locale_qa.get("formatter_examples", {}).get("compact_recipients") == "583.14K"
        and locale_qa.get("formatter_examples", {}).get("compact_claimed_arb") == "1.09B"
        and locale_qa.get("formatter_examples", {}).get("percent_example") == "85.5%"
        and locale_qa.get("formatter_examples", {}).get("date_example") == "Aug 23, 2026",
    )

    readme_links = markdown_local_links(readme_text)
    missing_readme_links = sorted(path for path in readme_links if not (ROOT / path).is_file())
    check("readme_local_links_exist", not missing_readme_links)

    privacy_findings, synthetic_fixture_matches = scan_privacy(tracked)
    public_privacy_findings, _ = scan_privacy([
        "README.md", "reports/arb_airdrop_report_artifact.json", "reports/arb_airdrop_report.html",
    ])
    check("tracked_repository_privacy_scan_passes", not privacy_findings)
    check("public_report_privacy_scan_passes", not public_privacy_findings)

    unstaged_diff_check = run_git("diff", "--check", check=False)
    staged_diff_check = run_git("diff", "--cached", "--check", check=False)
    check("git_diff_formatting_checks_pass", not unstaged_diff_check.stdout and not staged_diff_check.stdout)
    check("working_tree_has_no_unstaged_or_untracked_files", not unstaged and not untracked)

    summary = {
        "schema_version": "1.0.0",
        "scope": "Offline validation of the public ARB airdrop portfolio case.",
        "status": "passed" if not defects else "failed",
        "checks": checks,
        "defect_counters": {
            "failed_checks": len(defects),
            "internal_paths": len(internal_paths),
            "internal_references": len(internal_references),
            "stale_repository_references": len(stale_repository_references),
            "missing_builder_inputs": len(missing_inputs),
            "builder_input_hash_mismatches": len(input_hash_mismatches),
            "json_parse_failures": len(json_failures),
            "notebook_error_outputs": sum(notebook_error_outputs.values()),
            "notebook_absolute_path_outputs": sum(notebook_absolute_outputs.values()),
            "png_failures": len(png_failures),
            "svg_failures": len(svg_failures),
            "powershell_parse_failures": len(powershell_failures),
            "privacy_findings": len(privacy_findings),
            "public_report_privacy_findings": len(public_privacy_findings),
            "missing_readme_links": len(missing_readme_links),
        },
        "inventory": {
            "tracked_files": len(tracked),
            "analytical_inputs": len(pinned_input_paths),
            "figures": len(expected_figures),
            "notebooks": len(notebook_error_outputs),
        },
        "repository_url": EXPECTED_REPOSITORY_URL,
        "repository_url_files": sorted(repository_url_files),
        "notebook_validation": {
            "error_outputs": notebook_error_outputs,
            "absolute_path_outputs": notebook_absolute_outputs,
        },
        "figure_validation": {
            "png": png_profiles,
            "svg": svg_profiles,
            "headline_label_failures": svg_label_failures,
        },
        "privacy": {
            "findings": privacy_findings,
            "synthetic_fixture_matches_classified": synthetic_fixture_matches,
        },
        "failed_checks": defects,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if defects:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env node

/**
 * Pin the portable public-v1 report reader to English display conventions.
 *
 * The shared portable reader intentionally uses the browser's default locale
 * when it calls Intl formatters. That is unsuitable for this English-language
 * portfolio report because a Russian browser renders compact values as
 * "583,14 тыс." and "1,09 млрд" even though the document declares lang="en".
 *
 * Run this local-only finalizer after the canonical portable packager. It adds
 * a small, deterministic guard before the reader starts, preserves explicitly
 * requested locales, and emits machine-readable QA. It performs no network or
 * data-platform operations and does not alter the embedded artifact payload.
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const DEFAULT_HTML = "reports/arb_airdrop_report.html";
const DEFAULT_QA = "data/public_v1_report_locale_qa.json";
const LOCALE_MARKER = 'data-public-v1-report-locale="en-US"';

export const LOCALE_GUARD_JS = `(() => {
  "use strict";

  const defaultLocale = "en-US";
  const defaultTimeZone = "UTC";
  const localeOrDefault = (locales) => locales == null ? defaultLocale : locales;
  const dateOptions = (options) => ({
    ...(options ?? {}),
    timeZone: options?.timeZone ?? defaultTimeZone,
  });

  const wrapIntlConstructor = (name, normalizeOptions = (options) => options) => {
    const NativeConstructor = Intl[name];
    if (typeof NativeConstructor !== "function") return;
    function EnglishDefault(locales, options) {
      return new NativeConstructor(localeOrDefault(locales), normalizeOptions(options));
    }
    Object.setPrototypeOf(EnglishDefault, NativeConstructor);
    EnglishDefault.prototype = NativeConstructor.prototype;
    Intl[name] = EnglishDefault;
  };

  const wrapLocaleMethod = (prototype, name, normalizeOptions = (options) => options) => {
    const nativeMethod = prototype?.[name];
    if (typeof nativeMethod !== "function") return;
    Object.defineProperty(prototype, name, {
      configurable: true,
      writable: true,
      value(locales, options) {
        return nativeMethod.call(this, localeOrDefault(locales), normalizeOptions(options));
      },
    });
  };

  wrapIntlConstructor("NumberFormat");
  wrapIntlConstructor("DateTimeFormat", dateOptions);
  wrapLocaleMethod(Number.prototype, "toLocaleString");
  wrapLocaleMethod(Date.prototype, "toLocaleString", dateOptions);
  wrapLocaleMethod(Date.prototype, "toLocaleDateString", dateOptions);
  wrapLocaleMethod(Date.prototype, "toLocaleTimeString", dateOptions);
})();`;

const LOCALE_GUARD_TAG = `<script ${LOCALE_MARKER}>${LOCALE_GUARD_JS}</script>`;

function parseArguments(argv) {
  const parsed = {
    html: DEFAULT_HTML,
    qaOutput: DEFAULT_QA,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") return { help: true };
    if (argument !== "--html" && argument !== "--qa-output") {
      throw new Error(`Unexpected argument: ${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${argument}`);
    if (argument === "--html") parsed.html = value;
    if (argument === "--qa-output") parsed.qaOutput = value;
    index += 1;
  }
  return parsed;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function applyLocaleGuard(html) {
  if (!html.includes('<html lang="en"')) {
    throw new Error('Portable report must declare <html lang="en"> before locale finalization.');
  }
  const markerCount = html.split(LOCALE_MARKER).length - 1;
  if (markerCount > 1) throw new Error("Portable report contains duplicate English-locale guards.");
  if (markerCount === 1) return html;
  const headMarker = "<head>\n";
  if (!html.includes(headMarker)) throw new Error("Portable report <head> marker was not found.");
  return html.replace(headMarker, `${headMarker}${LOCALE_GUARD_TAG}\n`);
}

function verifyFormatterBehavior() {
  // The guard is deliberately self-contained and does not access the DOM, so
  // the exact browser-side code can be exercised in Node without a network.
  Function(LOCALE_GUARD_JS)();
  return {
    resolved_number_locale: Intl.NumberFormat().resolvedOptions().locale,
    resolved_date_locale: Intl.DateTimeFormat().resolvedOptions().locale,
    compact_recipients: new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 2,
      notation: "compact",
    }).format(583137),
    compact_claimed_arb: new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 2,
      notation: "compact",
    }).format(1092811500),
    percent_example: new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 1,
      style: "percent",
    }).format(0.855),
    date_example: new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeZone: "UTC",
    }).format(new Date("2026-08-23T00:00:00Z")),
    number_to_locale_string: (583137).toLocaleString(undefined, {
      maximumFractionDigits: 2,
      notation: "compact",
    }),
  };
}

function run({ html: htmlPath, qaOutput: qaOutputPath }) {
  const absoluteHtml = resolve(htmlPath);
  const absoluteQa = resolve(qaOutputPath);
  const original = readFileSync(absoluteHtml, "utf8");
  const originalPayloadMatch = original.match(
    /<template id="data-analytics-portable-artifact-payload-source"[\s\S]*?<\/template>/,
  );
  if (!originalPayloadMatch) throw new Error("Embedded portable artifact payload was not found.");

  const finalized = applyLocaleGuard(original);
  const finalizedPayloadMatch = finalized.match(
    /<template id="data-analytics-portable-artifact-payload-source"[\s\S]*?<\/template>/,
  );
  const payloadPreserved = finalizedPayloadMatch?.[0] === originalPayloadMatch[0];
  if (!payloadPreserved) throw new Error("Locale finalization changed the embedded artifact payload.");

  const guardIndex = finalized.indexOf(LOCALE_MARKER);
  const runtimeIndex = finalized.indexOf('id="data-analytics-portable-reader-runtime-source"');
  const loaderIndex = finalized.indexOf('data-data-analytics-portable-loader="true"');
  const guardPrecedesReader = guardIndex >= 0 && guardIndex < runtimeIndex && guardIndex < loaderIndex;
  if (!guardPrecedesReader) throw new Error("English-locale guard does not precede the portable reader.");

  writeFileSync(absoluteHtml, finalized, "utf8");

  const formatterExamples = verifyFormatterBehavior();
  const expectedExamples = {
    resolved_number_locale: "en-US",
    resolved_date_locale: "en-US",
    compact_recipients: "583.14K",
    compact_claimed_arb: "1.09B",
    percent_example: "85.5%",
    date_example: "Aug 23, 2026",
    number_to_locale_string: "583.14K",
  };
  const checks = {
    html_declares_english_language: finalized.includes('<html lang="en"'),
    locale_guard_is_unique: finalized.split(LOCALE_MARKER).length - 1 === 1,
    locale_guard_precedes_reader: guardPrecedesReader,
    embedded_artifact_payload_is_unchanged: payloadPreserved,
    compact_recipients_uses_english_suffix: formatterExamples.compact_recipients === "583.14K",
    compact_claimed_arb_uses_english_suffix: formatterExamples.compact_claimed_arb === "1.09B",
    percent_uses_english_decimal_separator: formatterExamples.percent_example === "85.5%",
    generated_date_uses_english_month: formatterExamples.date_example === "Aug 23, 2026",
    number_to_locale_string_uses_english_suffix:
      formatterExamples.number_to_locale_string === "583.14K",
    formatter_examples_match_expected:
      JSON.stringify(formatterExamples) === JSON.stringify(expectedExamples),
    no_cyrillic_text_in_final_html: !/[\u0400-\u04ff]/u.test(finalized),
  };
  const failedChecks = Object.entries(checks)
    .filter(([, passed]) => !passed)
    .map(([name]) => name);
  const qa = {
    schema_version: "1.0.0",
    generated_at: "2026-08-23",
    scope: "Public-v1 portable report English-locale finalization.",
    status: failedChecks.length === 0 ? "passed" : "failed",
    locale: "en-US",
    time_zone: "UTC",
    html: htmlPath.replaceAll("\\", "/"),
    html_sha256: sha256(finalized),
    formatter_examples: formatterExamples,
    checks,
    defect_counters: {
      failed_checks: failedChecks.length,
      cyrillic_findings: (finalized.match(/[\u0400-\u04ff]/gu) ?? []).length,
      payload_mutations: payloadPreserved ? 0 : 1,
      external_operations: 0,
    },
    failed_checks: failedChecks,
    external_operations: {
      bigquery: 0,
      rpc: 0,
      metadata_network: 0,
      execute_or_resume: 0,
      billing_or_configuration_changes: 0,
    },
  };
  mkdirSync(dirname(absoluteQa), { recursive: true });
  writeFileSync(absoluteQa, `${JSON.stringify(qa, null, 2)}\n`, "utf8");
  if (failedChecks.length > 0) {
    throw new Error(`English-locale QA failed: ${failedChecks.join(", ")}`);
  }
  return qa;
}

function usage() {
  return [
    "Usage: node scripts/finalize_public_v1_report_locale.mjs [options]",
    "",
    "Options:",
    `  --html <path>       Portable HTML path (default: ${DEFAULT_HTML}).`,
    `  --qa-output <path>  Machine-readable QA path (default: ${DEFAULT_QA}).`,
  ].join("\n");
}

const isMain = process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  try {
    const parsed = parseArguments(process.argv.slice(2));
    if (parsed.help) {
      process.stdout.write(`${usage()}\n`);
    } else {
      const result = run(parsed);
      process.stdout.write(`${JSON.stringify({ status: result.status, html_sha256: result.html_sha256 })}\n`);
    }
  } catch (error) {
    process.stderr.write(`${JSON.stringify({ status: "failed", error: error.message })}\n`);
    process.exitCode = 1;
  }
}

export { applyLocaleGuard, run };

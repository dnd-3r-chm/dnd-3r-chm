import { readFile, writeFile } from "node:fs/promises";

const reportPath = new URL("../feedback-entry-validation.json", import.meta.url);
const outputPath = new URL("../feedback-entry-online-check.json", import.meta.url);
const validationText = await readFile(reportPath, "utf8");
const rows = JSON.parse(validationText.replace(/^\uFEFF/, ""));
const concurrency = 16;
const timeoutMs = 15_000;
const results = new Array(rows.length);
let nextIndex = 0;

async function check(row) {
  const startedAt = Date.now();
  const url = new URL(row.Href);
  if (url.searchParams.get("page_ref") !== row.PageRef) {
    return { ...row, online: false, status: null, error: "page_ref_mismatch_before_request", elapsed_ms: 0, attempts: 0 };
  }
  let lastFailure = "unknown_failure";
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetch(url, {
          method: "GET",
          redirect: "follow",
          signal: controller.signal,
          headers: { "user-agent": "dnd3r-feedback-url-check/1.0" },
        });
        const contentType = response.headers.get("content-type") || "";
        const body = await response.text();
        const hasAppShell = /<title>DND 3R/i.test(body) && /<script/i.test(body);
        const online = response.status === 200 && contentType.includes("text/html") && hasAppShell;
        if (online || attempt === 3) {
          return {
            ...row,
            online,
            status: response.status,
            content_type: contentType,
            has_app_shell: hasAppShell,
            error: online ? "" : "unexpected_response",
            elapsed_ms: Date.now() - startedAt,
            attempts: attempt,
          };
        }
        lastFailure = `unexpected_response:${response.status}`;
      } finally {
        clearTimeout(timer);
      }
    } catch (error) {
      lastFailure = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      if (attempt === 3) {
        return {
          ...row,
          online: false,
          status: null,
          error: lastFailure,
          elapsed_ms: Date.now() - startedAt,
          attempts: attempt,
        };
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 250 * attempt));
  }
  return { ...row, online: false, status: null, error: lastFailure, elapsed_ms: Date.now() - startedAt, attempts: 3 };
}

async function worker() {
  while (true) {
    const index = nextIndex++;
    if (index >= rows.length) return;
    results[index] = await check(rows[index]);
    if ((index + 1) % 250 === 0 || index + 1 === rows.length) {
      process.stdout.write(`checked ${index + 1}/${rows.length}\n`);
    }
  }
}

await Promise.all(Array.from({ length: concurrency }, () => worker()));
await writeFile(outputPath, JSON.stringify(results, null, 2), "utf8");

const failures = results.filter((row) => !row.online);
const statusCounts = results.reduce((counts, row) => {
  const key = row.status === null ? "error" : String(row.status);
  counts[key] = (counts[key] || 0) + 1;
  return counts;
}, {});

console.log(JSON.stringify({
  total: results.length,
  online: results.length - failures.length,
  failed: failures.length,
  status_counts: statusCounts,
  report: outputPath.pathname,
  sample_failures: failures.slice(0, 20).map((row) => ({ file: row.File, page_ref: row.PageRef, status: row.status, error: row.error })),
}, null, 2));

if (failures.length > 0) process.exitCode = 2;

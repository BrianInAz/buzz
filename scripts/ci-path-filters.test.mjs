import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
  new URL("../.github/workflows/ci.yml", import.meta.url),
  "utf8",
);
const filters = extractPathFilters(workflow);

test("mobile, documentation, and Beads changes do not select Desktop", () => {
  for (const file of [
    "mobile/lib/features/profile/presence_cache_provider.dart",
    "docs/ios-peer-presence-hydration.md",
    ".beads/issues.jsonl",
  ]) {
    assert.equal(
      matchesFilter(file, filters.desktop),
      false,
      `${file} must not select the Desktop filter`,
    );
  }
});

test("Desktop frontend and Tauri paths remain independently classified", () => {
  assert.equal(matchesFilter("desktop/src/main.tsx", filters.desktop), true);
  assert.equal(
    matchesFilter("desktop/src-tauri/src/main.rs", filters.desktop),
    false,
  );
  assert.equal(
    matchesFilter("desktop/src-tauri/src/main.rs", filters["desktop-rust"]),
    true,
  );
  assert.equal(matchesFilter("pnpm-lock.yaml", filters.desktop), true);
});

test("Desktop filter has no standalone negative rule under some semantics", () => {
  assert.equal(
    filters.desktop.some((pattern) => pattern.startsWith("!")),
    false,
    "a standalone negative rule matches every unrelated file when the action uses predicate-quantifier: some",
  );
});

function extractPathFilters(source) {
  const lines = source.split("\n");
  const filtersMarker = lines.findIndex((line) => line.trim() === "filters: |");
  assert.notEqual(filtersMarker, -1, "CI workflow must configure path filters");

  const markerIndent = indentation(lines[filtersMarker]);
  const filterIndent = markerIndent + 2;
  const ruleIndent = filterIndent + 2;
  const parsed = {};
  let currentFilter;

  for (const line of lines.slice(filtersMarker + 1)) {
    if (line.trim() === "") continue;
    const indent = indentation(line);
    if (indent <= markerIndent) break;

    if (indent === filterIndent) {
      const match = line.trim().match(/^([a-z][a-z-]*):$/);
      assert.ok(match, `invalid path filter declaration: ${line.trim()}`);
      currentFilter = match[1];
      parsed[currentFilter] = [];
      continue;
    }

    if (indent === ruleIndent && currentFilter !== undefined) {
      const match = line.trim().match(/^- '([^']+)'$/);
      assert.ok(match, `invalid path filter rule: ${line.trim()}`);
      parsed[currentFilter].push(match[1]);
      continue;
    }

    assert.fail(`unexpected path filter syntax: ${line.trim()}`);
  }

  assert.ok(parsed.desktop, "Desktop path filter must exist");
  assert.ok(parsed["desktop-rust"], "Desktop Rust path filter must exist");
  return parsed;
}

function matchesFilter(file, patterns) {
  return patterns.some((pattern) => matchesPattern(file, pattern));
}

function matchesPattern(file, pattern) {
  if (pattern.startsWith("!")) {
    return !matchesPositivePattern(file, pattern.slice(1));
  }
  return matchesPositivePattern(file, pattern);
}

function matchesPositivePattern(file, pattern) {
  const negativeSegment = pattern.match(/^(.+)\/!\(([^)]+)\)\/\*\*$/);
  if (negativeSegment !== null) {
    const prefix = `${negativeSegment[1]}/`;
    if (!file.startsWith(prefix)) return false;
    const firstSegment = file.slice(prefix.length).split("/", 1)[0];
    const excluded = negativeSegment[2].split("|");
    return firstSegment.length > 0 && !excluded.includes(firstSegment);
  }

  if (pattern.endsWith("/**")) {
    const prefix = pattern.slice(0, -3);
    return file === prefix || file.startsWith(`${prefix}/`);
  }

  assert.equal(
    pattern.includes("*"),
    false,
    `contract matcher does not support pattern: ${pattern}`,
  );
  return file === pattern;
}

function indentation(line) {
  return line.length - line.trimStart().length;
}

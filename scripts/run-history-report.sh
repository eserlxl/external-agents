#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# run-history-report.sh — READ-ONLY analytics over the append-only run index (index.jsonl).
#
# Aggregates the per-run records scripts/run-agent.sh appends into cross-run trends: run/success
# counts, the error_class distribution, the agy fallback rate, driver-measured sec/bytes summaries,
# and best-effort tokens/cost aggregates. It NEVER writes to (or rewrites) the index — strictly
# read-only over an append-only file.
#
# The decisive rule: `signals.tokens` / `signals.cost` aggregates count ONLY present (numeric) values;
# an `unavailable` value is EXCLUDED from the aggregate (and reported as an `unavailable` count),
# never counted as 0 (which would understate the true average). The full metric set + JSON output
# shape are documented in README "Run-history analytics" and docs/run-record-contract.md.
#
# Usage:  run-history-report.sh [--json] [--agent A] [--project P] [--since TS] [--until TS] [INDEX]
#   --json       emit the machine-readable JSON document (default: a human-readable table)
#   --agent A    aggregate only rows whose resolved agent == A
#   --project P  aggregate only rows whose project namespace == P
#   --since TS   aggregate only rows with timestamp >= TS (UTC ISO-8601, lexicographic)
#   --until TS   aggregate only rows with timestamp <= TS (UTC ISO-8601, lexicographic)
#   INDEX        path to index.jsonl (default: ${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/index.jsonl)
# Filters compose (logical AND); an absent/empty filter selects everything. They scope WHICH rows are
# aggregated — the metric set, both backends, and value-equivalence are otherwise unchanged.
#
# Metrics are computed by jq (preferred) or python3 (fallback); the two backends produce
# value-equivalent JSON (numeric formatting of whole-number floats may differ — consumers parse JSON,
# not bytes).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

WANT_JSON=0
INDEX=""
F_AGENT=""; F_PROJECT=""; F_SINCE=""; F_UNTIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) WANT_JSON=1; shift;;
    --agent)   [ $# -ge 2 ] || { echo "run-history-report: $1 needs a value" >&2; exit 2; }; F_AGENT="$2";   shift 2;;
    --project) [ $# -ge 2 ] || { echo "run-history-report: $1 needs a value" >&2; exit 2; }; F_PROJECT="$2"; shift 2;;
    --since)   [ $# -ge 2 ] || { echo "run-history-report: $1 needs a value" >&2; exit 2; }; F_SINCE="$2";   shift 2;;
    --until)   [ $# -ge 2 ] || { echo "run-history-report: $1 needs a value" >&2; exit 2; }; F_UNTIL="$2";   shift 2;;
    -h|--help) sed -n '5,25p' "$ROOT/scripts/run-history-report.sh"; exit 0;;
    -*) echo "run-history-report: unknown flag: $1" >&2; exit 2;;
    *)  INDEX="$1"; shift;;
  esac
done
[ -n "$INDEX" ] || INDEX="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/index.jsonl"
if [ ! -f "$INDEX" ]; then
  echo "run-history-report: no run index at $INDEX" >&2
  exit 1
fi

# compute_metrics INDEX [AGENT PROJECT SINCE UNTIL] -> the metrics JSON (compact, one document).
# The four filters scope WHICH rows are aggregated (logical AND; empty = no constraint). Both backends
# apply the IDENTICAL keep predicate immediately after a row parses, so value-equivalence is preserved.
# jq preferred, python3 fallback.
compute_metrics() {
  local idx="$1" fa="${2:-}" fp="${3:-}" fs="${4:-}" fu="${5:-}"
  if command -v jq >/dev/null 2>&1; then
    # Read line-by-line and drop any blank/unparseable line (fromjson?), so a torn append in the
    # append-only index degrades exactly as the python3 backend does (skip the bad row) instead of
    # aborting the whole report — the two backends stay value-equivalent over a corrupt index.
    jq -n -R --arg fa "$fa" --arg fp "$fp" --arg fs "$fs" --arg fu "$fu" '
      [inputs | fromjson? // empty
        | select(($fa == "" or .agent == $fa)
             and ($fp == "" or .project == $fp)
             and ($fs == "" or (.timestamp // "") >= $fs)
             and ($fu == "" or (.timestamp // "") <= $fu))]
      | def r6: (. * 1000000 | round) / 1000000;
      (map(.error_class // (if .rc == 0 then "ok" else "unknown" end)))            as $cls
      | (map(.sec    | numbers))                                                   as $sec
      | (map(.bytes  | numbers))                                                   as $byt
      | (map(.signals.tokens | numbers))                                           as $tok
      | (map(.signals.cost | strings | ltrimstr("$") | (try tonumber catch empty))) as $cost
      | (map(select(.fallback == true)) | length)                                 as $fbc
      | ($cls | map(select(. == "ok")) | length)                                  as $okc
      | length                                                                     as $n
      | {
          runs: $n,
          ok: $okc,
          failed: ($n - $okc),
          success_rate: (if $n > 0 then ($okc / $n | r6) else 0 end),
          error_class: ($cls | group_by(.) | map({key: .[0], value: length}) | from_entries),
          fallback: { count: $fbc, rate: (if $n > 0 then ($fbc / $n | r6) else 0 end) },
          sec:   (if ($sec | length) > 0 then { min: ($sec | min), max: ($sec | max), mean: (($sec | add) / ($sec | length) | r6) } else { min: null, max: null, mean: null } end),
          bytes: (if ($byt | length) > 0 then { min: ($byt | min), max: ($byt | max), mean: (($byt | add) / ($byt | length) | r6) } else { min: null, max: null, mean: null } end),
          tokens: { counted: ($tok | length), unavailable: ($n - ($tok | length)), sum: ($tok | add // 0), mean: (if ($tok | length) > 0 then (($tok | add) / ($tok | length) | r6) else null end) },
          cost:   { counted: ($cost | length), unavailable: ($n - ($cost | length)), sum: ($cost | add // 0 | r6) }
        }
    ' "$idx"
  elif command -v python3 >/dev/null 2>&1; then
    FA="$fa" FP="$fp" FS="$fs" FU="$fu" python3 - "$idx" <<'PY'
import json, os, sys
from collections import Counter
FA = os.environ.get("FA", ""); FP = os.environ.get("FP", "")
FS = os.environ.get("FS", ""); FU = os.environ.get("FU", "")
def keep(r):
    # IDENTICAL predicate to the jq backend: AND of the four filters; empty filter = no constraint.
    if FA and r.get("agent") != FA:
        return False
    if FP and r.get("project") != FP:
        return False
    ts = r.get("timestamp") or ""
    if FS and ts < FS:
        return False
    if FU and ts > FU:
        return False
    return True
rows = []
with open(sys.argv[1]) as f:
    for ln in f:
        ln = ln.strip()
        if not ln:
            continue
        try:
            row = json.loads(ln)
        except Exception:
            continue
        if keep(row):
            rows.append(row)
n = len(rows)
def isnum(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)
def eff(r):
    ec = r.get("error_class")
    return ec if ec is not None else ("ok" if r.get("rc") == 0 else "unknown")
def costnum(r):
    c = (r.get("signals") or {}).get("cost")
    if isinstance(c, str) and c != "unavailable":
        try:
            return float(c.lstrip("$"))
        except ValueError:
            return None
    return None
def r6(x):
    return round(x, 6)
def stats(xs):
    return {"min": min(xs), "max": max(xs), "mean": r6(sum(xs) / len(xs))} if xs else {"min": None, "max": None, "mean": None}
cls = [eff(r) for r in rows]
sec = [r.get("sec") for r in rows if isnum(r.get("sec"))]
byt = [r.get("bytes") for r in rows if isnum(r.get("bytes"))]
tok = [(r.get("signals") or {}).get("tokens") for r in rows if isnum((r.get("signals") or {}).get("tokens"))]
cost = [v for v in (costnum(r) for r in rows) if v is not None]
fbc = sum(1 for r in rows if r.get("fallback") is True)
okc = sum(1 for c in cls if c == "ok")
out = {
    "runs": n,
    "ok": okc,
    "failed": n - okc,
    "success_rate": r6(okc / n) if n else 0,
    "error_class": dict(sorted(Counter(cls).items())),
    "fallback": {"count": fbc, "rate": r6(fbc / n) if n else 0},
    "sec": stats(sec),
    "bytes": stats(byt),
    "tokens": {"counted": len(tok), "unavailable": n - len(tok), "sum": sum(tok) if tok else 0, "mean": r6(sum(tok) / len(tok)) if tok else None},
    "cost": {"counted": len(cost), "unavailable": n - len(cost), "sum": r6(sum(cost)) if cost else 0},
}
print(json.dumps(out, separators=(",", ":")))
PY
  else
    echo "run-history-report: need jq or python3 to aggregate the index" >&2
    return 3
  fi
}

# render_table JSON -> a human-readable summary derived from the metrics JSON.
render_table() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print("external-agents run history (%d runs)" % d["runs"])
print("  ok / failed     : %d / %d  (success rate %s)" % (d["ok"], d["failed"], d["success_rate"]))
print("  error classes   : " + ", ".join("%s=%d" % (k, v) for k, v in d["error_class"].items()))
print("  agy fallback    : %d (%s)" % (d["fallback"]["count"], d["fallback"]["rate"]))
print("  sec (min/max/avg): %s / %s / %s" % (d["sec"]["min"], d["sec"]["max"], d["sec"]["mean"]))
print("  bytes(min/max/avg): %s / %s / %s" % (d["bytes"]["min"], d["bytes"]["max"], d["bytes"]["mean"]))
print("  tokens          : sum %s over %d run(s) (%d unavailable, excluded)" % (d["tokens"]["sum"], d["tokens"]["counted"], d["tokens"]["unavailable"]))
print("  cost            : sum %s over %d run(s) (%d unavailable, excluded)" % (d["cost"]["sum"], d["cost"]["counted"], d["cost"]["unavailable"]))
PY
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '
      "external-agents run history (\(.runs) runs)",
      "  ok / failed     : \(.ok) / \(.failed)  (success rate \(.success_rate))",
      "  error classes   : \(.error_class | to_entries | map("\(.key)=\(.value)") | join(", "))",
      "  agy fallback    : \(.fallback.count) (\(.fallback.rate))",
      "  sec (min/max/avg): \(.sec.min) / \(.sec.max) / \(.sec.mean)",
      "  bytes(min/max/avg): \(.bytes.min) / \(.bytes.max) / \(.bytes.mean)",
      "  tokens          : sum \(.tokens.sum) over \(.tokens.counted) run(s) (\(.tokens.unavailable) unavailable, excluded)",
      "  cost            : sum \(.cost.sum) over \(.cost.counted) run(s) (\(.cost.unavailable) unavailable, excluded)"'
  else
    printf '%s\n' "$1"
  fi
}

metrics_json="$(compute_metrics "$INDEX" "$F_AGENT" "$F_PROJECT" "$F_SINCE" "$F_UNTIL")" || exit $?
if [ "$WANT_JSON" = "1" ]; then
  printf '%s\n' "$metrics_json"
else
  render_table "$metrics_json"
fi

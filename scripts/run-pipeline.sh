#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# run-pipeline.sh — sequential agent PIPELINE over scripts/run-agent.sh (Phase 9.4).
#
# Runs an ordered list of agents in sequence; stage N+1's prompt is seeded from stage N's REDACTED
# artifact (the driver-redacted transcript, never raw output). All stages share ONE pipeline run_id
# and write to per-stage subdirs under one pipeline output dir, and each stage applies the driver's
# FULL safety model (containment, --yes, redaction, single-argv/stdin prompt) — the pipeline is never
# a back door around a single run. See docs/orchestration.md.
#
# Usage:  run-pipeline.sh --pipeline a,b,c --prompt P [--target DIR] [--read-only|--write] [--yes]
#                         [--continue] [other run-agent args...]
#   --pipeline a,b,c   comma-separated ordered agent list (the run order)
#   --continue         run every stage even if one fails (default: stop at the first failed stage)
#   --summary-json     also print one final JSON line: per-stage control-plane facts + completed/total
#   everything else is passed through to scripts/run-agent.sh per stage
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"

CONTINUE=0
PIPELINE=""
PROMPT=""
SUMMARY_JSON=0
PASS=()   # everything except --pipeline/--prompt/--continue/--summary-json is passed through to run-agent.sh per stage
while [ $# -gt 0 ]; do
  case "$1" in
    --continue) CONTINUE=1; shift;;
    --summary-json) SUMMARY_JSON=1; shift;;
    --pipeline) [ $# -ge 2 ] || { echo "run-pipeline: $1 needs a value" >&2; exit 2; }; PIPELINE="$2"; shift 2;;
    --prompt)   [ $# -ge 2 ] || { echo "run-pipeline: $1 needs a value" >&2; exit 2; }; PROMPT="$2"; shift 2;;
    -h|--help)  sed -n '5,18p' "$0"; exit 0;;
    *) PASS+=("$1"); shift;;
  esac
done
[ -n "$PIPELINE" ] || { echo "run-pipeline: --pipeline a,b,c is required" >&2; exit 2; }
[ -n "$PROMPT" ]   || { echo "run-pipeline: --prompt is required" >&2; exit 2; }

# One pipeline run_id + one pipeline output dir (per-stage subdirs) shared by every stage.
PIPE_ID="${EXTERNAL_AGENTS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo pipe)-$$}"
PIPE_DIR="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/pipeline-$PIPE_ID"
mkdir -p "$PIPE_DIR" || { echo "run-pipeline: cannot create $PIPE_DIR" >&2; exit 1; }

IFS=',' read -r -a stages <<<"$PIPELINE"
total="${#stages[@]}"
seed="$PROMPT"
stage_no=0
completed=0
rc_final=0
SUMMARY=()   # one content-free line per stage (agent/class/rc/sec/bytes) — never any transcript text
JROWS=()     # parallel structured per-stage rows (stage|agent|class|rc|sec|bytes) for --summary-json
for ag in ${stages[@]+"${stages[@]}"}; do
  [ -n "$ag" ] || continue
  stage_no=$((stage_no + 1))
  sdir="$PIPE_DIR/$stage_no-$ag"
  # Seed this stage's prompt via a file (one prompt, injection-safe): base + the prior stage's
  # REDACTED artifact. --out isolates each stage's records under the pipeline dir.
  pf="$(mktemp)"; printf '%s' "$seed" >"$pf"
  EXTERNAL_AGENTS_RUN_ID="$PIPE_ID" bash "$RUN" --agent "$ag" --prompt-file "$pf" --out "$sdir" ${PASS[@]+"${PASS[@]}"} >/dev/null 2>&1
  rc=$?
  rm -f "$pf"
  # Per-stage content-plane facts (class/rc/sec/bytes) from the record — never the transcript.
  facts="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("%s|%s|%s|%s" % (d.get("error_class","?"),d.get("rc","?"),d.get("sec","?"),d.get("bytes","?")))
except Exception:
    print("?|?|?|?")' "$sdir/$ag.meta.json" 2>/dev/null || echo "?|?|?|?")"
  IFS='|' read -r ec rc_f sec_f bytes_f <<<"$facts"
  [ "$ec" = "ok" ] && completed=$((completed + 1))
  SUMMARY+=("  stage $stage_no/$total  $ag  class=$ec rc=$rc_f sec=$sec_f bytes=$bytes_f")
  JROWS+=("$stage_no|$ag|$ec|$rc_f|$sec_f|$bytes_f")
  printf 'run-pipeline: stage %d/%d %s -> %s\n' "$stage_no" "$total" "$ag" "${ec:-rc=$rc}"
  if [ "$ec" != "ok" ]; then
    rc_final=1
    if [ "$CONTINUE" != "1" ]; then
      printf 'run-pipeline: stopping at stage %d (%s) — pass --continue to run the rest\n' "$stage_no" "$ag"
      break
    fi
  fi
  # Seed the NEXT stage from THIS stage's redacted artifact (the driver already redacted <agent>.md).
  art="$(cat "$sdir/$ag.md" 2>/dev/null || true)"
  seed="$PROMPT

--- prior stage ($ag) output (redacted) ---
$art"
done
# Deterministic, content-free outcome summary (mirrors the fan-out summary discipline): per-stage
# control-plane facts plus the completed-through-stage-K verdict — never any transcript text.
echo "run-pipeline: outcome summary (control-plane only — agent/class/rc/sec/bytes, no transcript text):"
printf '%s\n' ${SUMMARY[@]+"${SUMMARY[@]}"}
printf 'run-pipeline: completed-through-stage %d/%d (run_id %s, out %s)\n' "$completed" "$total" "$PIPE_ID" "$PIPE_DIR"
# Opt-in machine-readable summary (--summary-json): ONE final JSON line of control-plane facts only
# (per-stage stage/agent/class/rc/sec/bytes + completed_through/total/rc) — never any transcript text.
# Additive, mirroring run-agent.sh --json: the default output above is byte-identical when the flag is absent.
if [ "$SUMMARY_JSON" = "1" ]; then
  if command -v python3 >/dev/null 2>&1; then
    RID="$PIPE_ID" PDIR="$PIPE_DIR" TOT="$total" DONE="$completed" RCF="$rc_final" \
      python3 - ${JROWS[@]+"${JROWS[@]}"} <<'PY'
import json, os, sys
def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None
stages = []
for a in sys.argv[1:]:
    stage, agent, cls, rc, sec, byts = (a.split("|") + [""] * 6)[:6]
    stages.append({"stage": num(stage), "agent": agent, "class": cls,
                   "rc": num(rc), "sec": num(sec), "bytes": num(byts)})
doc = {"run_id": os.environ["RID"], "out": os.environ["PDIR"],
       "total": int(os.environ["TOT"]), "completed_through": int(os.environ["DONE"]),
       "rc": int(os.environ["RCF"]), "stages": stages}
print(json.dumps(doc, separators=(",", ":")))
PY
  else
    echo "run-pipeline: --summary-json needs python3 (not on PATH) — skipped" >&2
  fi
fi
exit "$rc_final"

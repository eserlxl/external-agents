#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/tests/live-smoke.sh — OPT-IN live smoke harness.
#
# Unlike tests/run.sh (which is fully offline and CLI-free), this harness MAY
# launch the real external agent CLIs (agy / codex / claude / cursor) to verify
# that the driver actually round-trips against them. It is therefore gated behind
# a single explicit arming switch and is NEVER part of the offline CI gate.
#
# ARMING SWITCH — EXTERNAL_AGENTS_LIVE  (the single opt-in for ALL live work):
#   unset or 0 : skip every live step, launch nothing, exit 0  (the default).
#   1          : arm the harness — discover reachable agents and run live checks.
#
# This mirrors the existing EXTERNAL_AGENTS_* convention (EXTERNAL_AGENTS_OUT,
# EXTERNAL_AGENTS_AGY_QUOTA_CMD, …). Run from anywhere:  bash tests/live-smoke.sh
set -uo pipefail

# --- arming gate: the one switch that decides whether ANY live work runs --------
# Read it BEFORE resolving anything else so an unarmed run is a pure no-op.
LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
if [ "$LIVE" != "1" ]; then
  echo "live smoke skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"
[ -x "$RUN" ] || { echo "live smoke: driver not found at $RUN" >&2; exit 1; }

echo "external-agents live smoke: armed (EXTERNAL_AGENTS_LIVE=1)"

# Optional --agent <name> selector scopes the smoke to one agent (default: every
# reachable agent). A short read-only prompt keeps each live invocation cheap.
WANT_AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) WANT_AGENT="${2:-}"; shift 2;;
    *) echo "live smoke: unknown arg: $1" >&2; exit 2;;
  esac
done
SMOKE_PROMPT="${EXTERNAL_AGENTS_LIVE_PROMPT:-Reply with the single word: ok}"
# Each argv-coverage run only needs run_one's pre-launch argv record, so a short timeout
# keeps the (mode x prompt-source) matrix light while still exercising the real run path.
SMOKE_TIMEOUT="${EXTERNAL_AGENTS_LIVE_TIMEOUT:-60}"

# live_argv_record OUTDIR AGENT — print the masked launch-argv record run_one writes for
# AGENT under OUTDIR ($OUTDIR/<agent>.argv): the resolved argv with the prompt shown as
# <PROMPT>, secret/PII-free.
live_argv_record() {
  cat "$1/$2.argv" 2>/dev/null
}

# argv_equiv AGENT MODE SRC — prove the LIVE launch argv matches what --dry-run shows for
# ONE (mode, prompt-source) pair, so every build_argv resolution path is covered:
#   MODE = read-only | read-write   (--read-only enforced argv vs --write argv)
#   SRC  = prompt | prompt-file      (literal --prompt vs --prompt-file resolution)
# One live run against a throwaway target makes run_one write the masked argv record; that
# record must be byte-identical to the --dry-run argv for the same invocation. The record
# never holds the prompt (it is masked) — and --prompt vs --prompt-file resolve to the SAME
# masked argv — so this is a content-free correctness check across all paths. A write run
# uses a disposable, non-cwd target with --yes. Returns non-zero on mismatch.
argv_equiv() {  # agent mode src
  local a="$1" mode="$2" src="$3" tgt out rec dry pf modeflag
  tgt="$(mktemp -d)"; out="$(mktemp -d)"
  case "$mode" in read-write) modeflag=--write;; *) modeflag=--read-only;; esac
  local yes=(); [ "$mode" = "read-write" ] && yes=(--yes)
  local pargs=()
  if [ "$src" = "prompt-file" ]; then
    pf="$(mktemp)"; printf '%s' "$SMOKE_PROMPT" >"$pf"; pargs=(--prompt-file "$pf")
  else
    pargs=(--prompt "$SMOKE_PROMPT")
  fi
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent "$a" "$modeflag" "${yes[@]}" \
    --target "$tgt" --timeout "$SMOKE_TIMEOUT" "${pargs[@]}" >/dev/null 2>&1
  rec="$(live_argv_record "$out/$(basename "$tgt")" "$a")"
  dry="$("$RUN" --agent "$a" "$modeflag" "${yes[@]}" --target "$tgt" --dry-run \
    "${pargs[@]}" 2>/dev/null | sed -nE "s/^  $a +//p")"
  [ "$src" = "prompt-file" ] && rm -f "$pf"
  rm -rf "$tgt" "$out"
  if [ -n "$rec" ] && [ "$rec" = "$dry" ]; then
    echo "live smoke: $a [$mode/$src]  live argv == dry-run argv"
    return 0
  fi
  echo "live smoke: $a [$mode/$src]  FAIL: live argv != dry-run argv (live=[$rec] dry=[$dry])" >&2
  return 1
}

# Scope the harness to reachable agents and skip the rest with a clear per-agent line.
# Discovery is the driver's machine-readable --discover surface (same agent_bin /
# command -v probe as --check), so the harness never re-implements detection. Absence
# is NEVER a failure: an environment with no agent CLIs on PATH still exits 0.
discovered="$("$RUN" --discover 2>/dev/null)"
reachable=()
while read -r a state _; do
  [ -n "$a" ] || continue
  if [ "$state" = "present" ]; then
    reachable+=("$a")
  else
    echo "live smoke: $a skipped (not reachable on PATH)"
  fi
done <<EOF
$discovered
EOF

# Apply the optional --agent scope to the reachable set.
verify=()
if [ -n "$WANT_AGENT" ]; then
  for a in ${reachable[@]+"${reachable[@]}"}; do
    [ "$a" = "$WANT_AGENT" ] && verify=("$a")
  done
  [ "${#verify[@]}" -gt 0 ] || echo "live smoke: $WANT_AGENT skipped (not reachable on PATH)"
else
  verify=(${reachable[@]+"${reachable[@]}"})
fi

if [ "${#verify[@]}" -eq 0 ]; then
  echo "live smoke: no reachable agents to verify — nothing to do (exit 0)"
  exit 0
fi
echo "live smoke: verifying ${verify[*]}"

# Per-agent live checks. Phase 2.2 verifies argv equivalence across every (mode,
# prompt-source) build_argv path; non-mutation and transcript-success checks are added
# by the later Phase 2 sub-phases.
fails=0
for a in "${verify[@]}"; do
  for mode in read-only read-write; do
    for src in prompt prompt-file; do
      argv_equiv "$a" "$mode" "$src" || fails=$((fails + 1))
    done
  done
done
if [ "$fails" -gt 0 ]; then
  echo "live smoke: $fails (agent, mode, prompt-source) case(s) failed argv equivalence" >&2
  exit 1
fi
echo "live smoke: argv equivalence verified for ${verify[*]} (read-only+read-write x prompt+prompt-file)"
exit 0

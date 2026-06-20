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
#
# Sourceable: every step lives in a function and main() runs ONLY when this script is
# executed directly, so tests/run.sh can source it to unit-test the helpers offline.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"

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

# make_sandbox — create a fresh DISPOSABLE sandbox tree and print its path. The tree is a
# git repo with one seed commit, seeded from tests/fixtures (a committed minimal project)
# when present, else a single generated file. It is created under $TMPDIR and is GUARANTEED
# outside the plugin tree, so a read-only run targets a throwaway, never the real repo. The
# caller removes it (rm -rf) when done.
make_sandbox() {
  local seed="$ROOT/tests/fixtures" sb
  sb="$(mktemp -d)" || return 1
  # Hard invariant: never hand back a path inside the plugin tree.
  case "$sb/" in "$ROOT/"*)
    echo "make_sandbox: refusing a sandbox inside the plugin tree ($sb)" >&2
    rm -rf "$sb"; return 1;;
  esac
  if [ -d "$seed" ] && [ -n "$(ls -A "$seed" 2>/dev/null)" ]; then
    cp -R "$seed/." "$sb/"
  else
    printf 'seed file for the read-only live-smoke sandbox\n' >"$sb/SEED.txt"
  fi
  ( cd "$sb" && git init -q && git add -A \
      && git -c user.email=smoke@local -c user.name=smoke commit -qm "sandbox seed" ) >/dev/null 2>&1
  printf '%s' "$sb"
}

# tree_changes SANDBOX — print the paths that changed in the git-backed SANDBOX since its
# seed commit, one porcelain line per path; EMPTY output means byte-identical (no mutation).
# The seed commit is the implicit "before" snapshot and `git status --porcelain` is the
# "after" compare, mirroring the driver's own post-write verification (scripts/run-agent.sh).
# Untracked additions appear too (as '?? path'), so an agent that *adds* a file is detected.
tree_changes() {  # sandbox
  git -C "$1" status --porcelain 2>/dev/null
}

# enforced_readonly AGENT — true when AGENT's read-only mode is HARD-enforced by the CLI
# (codex -s read-only / claude --allowedTools / cursor --mode plan). agy read-only is only
# best-effort (--sandbox), so it is reported separately, never asserted (next sub-phase).
enforced_readonly() {  # agent
  case "$1" in codex|claude|cursor) return 0;; *) return 1;; esac
}

# non_mutation_check AGENT — run AGENT read-only against a fresh disposable sandbox and
# assert the tree is byte-identical afterward. For an ENFORCED agent any change is a HARD
# failure (returns 1). The tree_changes snapshot catches the mutation regardless of whether
# the CLI's own enforcement held, so this independently proves the read-only guarantee.
non_mutation_check() {  # agent
  local a="$1" sb out changes
  sb="$(make_sandbox)" || { echo "live smoke: $a  FAIL: could not create sandbox" >&2; return 1; }
  out="$(mktemp -d)"
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent "$a" --read-only --target "$sb" \
    --timeout "$SMOKE_TIMEOUT" --prompt "$SMOKE_PROMPT" >/dev/null 2>&1
  changes="$(tree_changes "$sb")"
  rm -rf "$sb" "$out"
  if [ -z "$changes" ]; then
    echo "live smoke: $a [read-only]  no mutation (tree byte-identical)"
    return 0
  fi
  echo "live smoke: $a [read-only]  FAIL: enforced read-only mutated the tree:" >&2
  printf '%s\n' "$changes" >&2
  return 1
}

# agy_mutation_report — run agy read-only against a fresh sandbox and REPORT whether the tree
# changed, explicitly labelled best-effort. agy read-only relies on --sandbox, which is NOT a
# hard write barrier (see scripts/run-agent.sh), so a change is recorded as an OBSERVED, not
# enforced, outcome and NEVER fails the harness. Always returns 0.
agy_mutation_report() {
  local sb out changes
  sb="$(make_sandbox)" || { echo "live smoke: agy [read-only]  best-effort: could not create sandbox (skipped)"; return 0; }
  out="$(mktemp -d)"
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent agy --read-only --target "$sb" \
    --timeout "$SMOKE_TIMEOUT" --prompt "$SMOKE_PROMPT" >/dev/null 2>&1
  changes="$(tree_changes "$sb")"
  rm -rf "$sb" "$out"
  if [ -z "$changes" ]; then
    echo "live smoke: agy [read-only]  best-effort: tree unchanged (observed, not enforced)"
  else
    echo "live smoke: agy [read-only]  best-effort: tree CHANGED (agy --sandbox is best-effort, not enforced):"
    printf '%s\n' "$changes"
  fi
  return 0
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
  # Secret-safety guard: the record masks the prompt to <PROMPT>, so it must NEVER contain
  # the literal prompt (which could carry a secret). A leak is a hard failure, not a diff.
  case "$rec" in *"$SMOKE_PROMPT"*)
    echo "live smoke: $a [$mode/$src]  FAIL: argv record leaked the prompt text" >&2
    return 1;;
  esac
  if [ -n "$rec" ] && [ "$rec" = "$dry" ]; then
    echo "live smoke: $a [$mode/$src]  live argv == dry-run argv"
    return 0
  fi
  echo "live smoke: $a [$mode/$src]  FAIL: live argv != dry-run argv (live=[$rec] dry=[$dry])" >&2
  return 1
}

# main — the live run. Runs ONLY when this script is executed directly (see the guard at the
# bottom); sourcing the file for unit tests defines the helpers above without running this.
main() {
  local LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
  if [ "$LIVE" != "1" ]; then
    echo "live smoke skipped (set EXTERNAL_AGENTS_LIVE=1)"
    return 0
  fi
  [ -x "$RUN" ] || { echo "live smoke: driver not found at $RUN" >&2; return 1; }
  echo "external-agents live smoke: armed (EXTERNAL_AGENTS_LIVE=1)"

  # Optional flags: --agent <name> scopes to one agent (default: every reachable agent);
  # --read-only narrows the argv matrix to read-only cases (non-mutation always runs).
  local WANT_AGENT="" RO_ONLY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) WANT_AGENT="${2:-}"; shift 2;;
      --read-only) RO_ONLY=1; shift;;
      *) echo "live smoke: unknown arg: $1" >&2; return 2;;
    esac
  done
  local argv_modes=(read-only read-write)
  [ "$RO_ONLY" = "1" ] && argv_modes=(read-only)

  # Scope the harness to reachable agents and skip the rest with a clear per-agent line.
  # Discovery is the driver's machine-readable --discover surface (same agent_bin /
  # command -v probe as --check), so the harness never re-implements detection. Absence
  # is NEVER a failure: an environment with no agent CLIs on PATH still exits 0.
  local discovered a state reachable=()
  discovered="$("$RUN" --discover 2>/dev/null)"
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
  local verify=()
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
    return 0
  fi
  echo "live smoke: verifying ${verify[*]}"

  # Per-agent live checks: (1) argv equivalence across every (mode, prompt-source)
  # build_argv path, and (2) read-only non-mutation — enforced agents (codex/claude/cursor)
  # must leave the tree byte-identical; any change is a hard failure. (agy read-only is
  # best-effort and reported separately by the next sub-phase. Transcript-success too.)
  local fails=0 mode src
  for a in "${verify[@]}"; do
    for mode in ${argv_modes[@]+"${argv_modes[@]}"}; do
      for src in prompt prompt-file; do
        argv_equiv "$a" "$mode" "$src" || fails=$((fails + 1))
      done
    done
    if enforced_readonly "$a"; then
      non_mutation_check "$a" || fails=$((fails + 1))
    elif [ "$a" = "agy" ]; then
      agy_mutation_report   # best-effort: reports a change, never fails the run
    fi
  done
  if [ "$fails" -gt 0 ]; then
    echo "live smoke: $fails live check(s) failed for ${verify[*]}" >&2
    return 1
  fi
  echo "live smoke: all live checks passed for ${verify[*]} (argv equivalence + enforced read-only non-mutation)"
  return 0
}

# Run main only when executed directly (not when sourced to unit-test the helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi

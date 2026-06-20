#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/lib/capture.sh — before/after evidence capture for the E2E recipes.
#
# Sourceable library: it records uniform evidence for one E2E run into a throwaway evidence
# directory (under EXTERNAL_AGENTS_OUT), so every recipe produces inspectable artifacts whose
# fields match the driver's actual outputs (see docs/e2e-recipe.md). It launches nothing itself —
# the recipe drives run-agent.sh; these helpers only read the fixture + the driver's run files.
#
# shellcheck disable=SC2329  # sourced library: helpers are invoked by recipes + tests/run.sh

# e2e_capture_pre FIXTURE EVIDENCE_DIR — record the fixture's pre-run baseline: short HEAD sha
# and a (clean) git status --porcelain, so the after-state is comparable against a known point.
e2e_capture_pre() {  # fixture evidence_dir
  local fx="$1" ev="$2"
  mkdir -p "$ev" 2>/dev/null || return 1
  git -C "$fx" rev-parse --short HEAD >"$ev/pre.sha" 2>/dev/null
  git -C "$fx" status --porcelain >"$ev/pre.status" 2>/dev/null
}

# e2e_capture_argv RUN AGENT MODEFLAG FIXTURE EVIDENCE_DIR [PROMPT] — record the resolved
# (prompt-masked) launch argv via run-agent.sh --dry-run, WITHOUT launching a CLI. This is the
# same masked argv run_one records for a real run, so the evidence is identical either way.
e2e_capture_argv() {  # run agent modeflag fixture evidence_dir prompt
  local run="$1" agent="$2" modeflag="$3" fx="$4" ev="$5" prompt="${6:-review this code}"
  mkdir -p "$ev" 2>/dev/null || return 1
  "$run" --agent "$agent" "$modeflag" --target "$fx" --dry-run --prompt "$prompt" 2>/dev/null \
    | sed -nE "s/^  $agent +//p" >"$ev/argv"
}

# e2e_capture_post FIXTURE PROJ AGENT EVIDENCE_DIR — after a real run, record the driver's own
# evidence fields: the masked argv record, rc/sec/bytes, the transcript path, and the fixture's
# post-run git state (status --porcelain + diff --stat) — aligned to the driver's collect-loop
# and post-write outputs. PROJ is the driver's per-project out dir ($EXTERNAL_AGENTS_OUT/<proj>).
e2e_capture_post() {  # fixture proj agent evidence_dir
  local fx="$1" proj="$2" agent="$3" ev="$4"
  mkdir -p "$ev" 2>/dev/null || return 1
  cp "$proj/$agent.argv" "$ev/argv" 2>/dev/null
  {
    printf 'rc=%s\n'         "$(cat "$proj/$agent.rc" 2>/dev/null || echo '?')"
    printf 'sec=%s\n'        "$(cat "$proj/$agent.sec" 2>/dev/null || echo '?')"
    printf 'bytes=%s\n'      "$(wc -c <"$proj/$agent.md" 2>/dev/null | tr -d ' ')"
    printf 'transcript=%s\n' "$proj/$agent.md"
  } >"$ev/run.txt"
  git -C "$fx" status --porcelain    >"$ev/post.status"   2>/dev/null
  git -C "$fx" --no-pager diff --stat >"$ev/post.diffstat" 2>/dev/null
}

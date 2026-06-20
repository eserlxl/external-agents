#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Focused, offline tests for the external-agents plugin.
#
# Everything here is deterministic and CLI-free: run-agent.sh is exercised only
# through --dry-run (argv resolution), --list (config parsing), and early-exit
# error/safety paths, so NO external agent CLI (agy/codex/claude/cursor) is ever
# launched. Run from anywhere:  bash tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing: $3";; esac; }
# assert_exit DESC EXPECTED ACTUAL
assert_exit() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }

# dry DESC NEEDLE -- <run-agent args...>
# Captures `run-agent.sh --dry-run ...` stdout and asserts NEEDLE is present.
dry() {
  local desc="$1" needle="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(bash "$RUN" --dry-run "$@" --prompt 'hello world' 2>/dev/null)"
  assert_contains "$desc" "$out" "$needle"
}

# mk_restricted_bin DIR — populate DIR/bin with the shell utilities run-agent.sh needs
# but NO agent CLIs and NO jq, so a run under PATH=DIR/bin forces the python3 config
# backend and reports every agent missing. Shared by the parity / --check / malformed tests.
mk_restricted_bin() {
  mkdir -p "$1/bin"
  local t s
  for t in bash env python3 grep dirname basename cat sed sort tr cut wc paste date mktemp git head tail; do
    s="$(command -v "$t" 2>/dev/null)" && ln -s "$s" "$1/bin/$t" 2>/dev/null || true
  done
}

echo "== run-agent.sh --dry-run argv resolution (agents.json tier mapping) =="
# Per-CLI read-only enforcement is published in docs/threat-model.md (agy best-effort via
# --sandbox vs codex/claude/cursor enforced); Phase 6.4 asserts that matrix against this argv.
dry "agy read-only -> --sandbox"                 "--sandbox"                     -- --agent agy    --read-only --effort medium
dry "agy read-only -> mapped Gemini model"       "Gemini 3.5 Flash (Medium)"     -- --agent agy    --read-only --effort medium
dry "agy write -> skip-permissions"              "--dangerously-skip-permissions" -- --agent agy    --write     --effort medium
dry "codex read-only -> -s read-only"            "-s read-only"                  -- --agent codex  --read-only --effort high
dry "codex high -> model_reasoning_effort"       'model_reasoning_effort="high"' -- --agent codex  --read-only --effort high
dry "codex write -> -s workspace-write"          "-s workspace-write"            -- --agent codex  --write     --effort high
dry "claude write -> permission-mode acceptEdits" "--permission-mode acceptEdits" -- --agent claude --write     --effort high
dry "claude high -> --effort high"               "--effort high"                 -- --agent claude --write     --effort high
dry "claude read-only -> allowedTools"           "--allowedTools"                -- --agent claude --read-only --effort high
dry "cursor read-only -> --mode plan"            "--mode plan"                   -- --agent cursor --read-only --effort medium
dry "cursor read-only -> composer-2.5"           "composer-2.5"                  -- --agent cursor --read-only --effort medium
dry "cursor write -> --force"                    "--force"                       -- --agent cursor --write     --effort medium
dry "cursor binary is cursor-agent"              "cursor-agent"                  -- --agent cursor --write     --effort medium

echo "== enforcement-matrix accuracy (docs/threat-model.md vs driver read-only argv) =="
# For each agent the read-only mechanism the driver actually emits must also be the one the
# published matrix documents — so docs/threat-model.md cannot silently drift from the driver.
TM="$ROOT/docs/threat-model.md"
matrix_row() {  # agent  mechanism-token
  local a="$1" mech="$2" ro
  ro="$(bash "$RUN" --agent "$a" --read-only --effort medium --dry-run --prompt x 2>/dev/null)"
  case "$ro" in *"$mech"*) : ;; *) bad "matrix: $a read-only argv emits '$mech'" "driver argv changed"; return;; esac
  if grep -qF -- "$mech" "$TM"; then ok "matrix: doc documents '$mech' for $a (driver agrees)"
  else bad "matrix: doc documents '$mech' for $a" "doc/driver drift"; fi
}
matrix_row agy    "--sandbox"
matrix_row codex  "-s read-only"
matrix_row claude "--allowedTools"
matrix_row cursor "--mode plan"

# agy read-only honesty: the best-effort NOTE must be emitted, and nothing may claim agy
# read-only is "enforced" (that is reserved for codex/claude/cursor).
agy_note="$(bash "$RUN" --agent agy --read-only --effort medium --dry-run --prompt x 2>&1 >/dev/null)"
assert_contains "agy read-only emits the best-effort NOTE" "$agy_note" "best-effort"
agy_all="$(bash "$RUN" --agent agy --read-only --effort medium --dry-run --prompt x 2>&1)"
case "$agy_all" in *[Ee]nforced*) bad "agy read-only is not over-claimed as enforced" "found an 'enforced' claim in agy output";; *) ok "agy read-only is not over-claimed as enforced";; esac

echo "== jq / python3 config-backend parity (--list byte-identical) =="
out_jq="$(bash "$RUN" --list 2>/dev/null)"
tdir="$(mktemp -d)"
mk_restricted_bin "$tdir"
# Restricted PATH hides jq but keeps python3 -> forces the python backend.
out_py="$(PATH="$tdir/bin" "$tdir/bin/bash" "$RUN" --list 2>/dev/null)"
rm -rf "$tdir"
if [ -n "$out_jq" ] && [ -n "$out_py" ]; then
  if [ "$out_jq" = "$out_py" ]; then
    ok "jq and python3 --list output identical"
  else
    bad "jq and python3 --list output identical" "backends diverged"
  fi
else
  printf '  skip jq/python3 parity (could not run both backends in this environment)\n'
fi

echo "== per-agent jq/python3 dry-run parity (model/effort/fallback ops under both backends) =="
# Parity gate: every cfg op must produce byte-identical output across the jq and python3 backends;
# when a query type changes, update both backends in run-agent.sh and these parity blocks together.
pdir="$(mktemp -d)"; mk_restricted_bin "$pdir"
parity_dry() {  # agent  effort  [extra env assignment]
  local a="$1" e="$2" env="${3:-}" oj op
  oj="$(env ${env:+$env} bash "$RUN" --agent "$a" --read-only --effort "$e" --dry-run --prompt p 2>/dev/null)"
  op="$(env ${env:+$env} PATH="$pdir/bin" "$pdir/bin/bash" "$RUN" --agent "$a" --read-only --effort "$e" --dry-run --prompt p 2>/dev/null)"
  if [ -z "$oj" ] || [ -z "$op" ]; then printf '  skip %s/%s parity (a backend unavailable)\n' "$a" "$e"; return; fi
  if [ "$oj" = "$op" ]; then ok "dry-run parity: $a $e (jq == python3)"; else bad "dry-run parity: $a $e" "backends diverged"; fi
}
for a in codex claude cursor; do for e in low medium high xhigh; do parity_dry "$a" "$e"; done; done
# agy low/medium have no fallback -> deterministic. agy high/xhigh carry a fallback, so force the
# quota CLI to fail in BOTH backends so both deterministically fall back (isolating cfg-op parity
# from environment quota state).
parity_dry agy low; parity_dry agy medium
parity_dry agy high  "EXTERNAL_AGENTS_AGY_QUOTA_CMD=false"
parity_dry agy xhigh "EXTERNAL_AGENTS_AGY_QUOTA_CMD=false"
rm -rf "$pdir"

echo "== agents.json schema validation (draft-07 contract) =="
if python3 -c 'import jsonschema' 2>/dev/null; then
  # schema_check FILE -> "OK" if FILE validates against schema/agents.schema.json, else "REJECTED".
  schema_check() {
    python3 - "$ROOT/schema/agents.schema.json" "$1" <<'PY' 2>/dev/null
import json, sys, jsonschema
schema = json.load(open(sys.argv[1])); cfg = json.load(open(sys.argv[2]))
try:
    jsonschema.validate(cfg, schema); print("OK")
except jsonschema.ValidationError:
    print("REJECTED")
PY
  }
  assert_contains "shipped agents.json validates against the schema" "$(schema_check "$ROOT/agents.json")" "OK"
  # Negative fixtures: each deliberately invalid config must be REJECTED by the schema.
  nfx="$(mktemp)"
  printf '%s' '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":{"low":{}}}}}' >"$nfx"
  assert_contains "schema rejects a tier missing model"        "$(schema_check "$nfx")" "REJECTED"
  printf '%s' '{"default_tier":5,"agents":{"agy":{"enabled":true,"tiers":{"low":{"model":"m"}}}}}' >"$nfx"
  assert_contains "schema rejects wrong-typed default_tier"    "$(schema_check "$nfx")" "REJECTED"
  printf '%s' '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":"oops"}}}' >"$nfx"
  assert_contains "schema rejects non-object tiers"            "$(schema_check "$nfx")" "REJECTED"
  printf '%s' '{"default_tier":"medium","agents":{"codex":{"enabled":true,"tiers":{"high":{"model":"m","fallback":"g"}}}}}' >"$nfx"
  assert_contains "schema rejects fallback on a non-agy agent" "$(schema_check "$nfx")" "REJECTED"
  rm -f "$nfx"
else
  printf '  skip schema validation (python3 jsonschema not installed)\n'
fi

echo "== effort + write-mode safety gates (early exit, no agent launched) =="
# Traceability to docs/threat-model.md "Threats and mitigating controls":
#   containment (target inside/containing plugin) -> "Plugin tree" row
#   non-cwd write requires --yes                  -> "Target tree / wrong non-cwd target" row
#   --read-only/--write mutual exclusion          -> "Target tree / read-only degrades to write" row
#   post-write git verification + non-git warning -> "Target tree / no inspect-or-revert path" row
#   symlink bypass collapsed by pwd -P            -> "Plugin tree" row (pwd -P resolution)
bash "$RUN" --agent codex --effort bogus --dry-run --prompt x >/dev/null 2>&1
assert_exit "unknown --effort tier exits 2" 2 "$?"

# Write target == the plugin tree itself -> refused before any launch.
bash "$RUN" --agent codex --target "$ROOT" --prompt x >/dev/null 2>&1
assert_exit "write into plugin tree exits 2" 2 "$?"

# Write target that *contains* the plugin tree (e.g. a monorepo root) -> also refused,
# so external agents can't be pointed at sibling repos. Real write mode (no --dry-run).
bash "$RUN" --agent codex --target "$(dirname "$ROOT")" --prompt x >/dev/null 2>&1
assert_exit "write target containing the plugin exits 2" 2 "$?"
cont_err="$(bash "$RUN" --agent codex --target "$(dirname "$ROOT")" --prompt x 2>&1 >/dev/null)"
assert_contains "containment gate is explained" "$cont_err" "contains the plugin tree"

# A subdir INSIDE the plugin tree is refused with the documented message (not just exit 2).
in_err="$(bash "$RUN" --agent codex --target "$ROOT/scripts" --prompt x 2>&1 >/dev/null)"; in_rc=$?
assert_exit     "write into a plugin subdir exits 2"  2 "$in_rc"
assert_contains "inside-plugin refusal is explained"  "$in_err" "refusing to write inside the plugin tree"

# A symlink that resolves into the plugin tree must not bypass containment: pwd -P collapses
# it to the real path before the check (scripts/run-agent.sh resolves TARGET via pwd -P).
sl="$(mktemp -d)"; ln -s "$ROOT" "$sl/link" 2>/dev/null
if [ -L "$sl/link" ]; then
  sl_err="$(bash "$RUN" --agent codex --target "$sl/link" --prompt x 2>&1 >/dev/null)"; sl_rc=$?
  assert_exit     "symlinked target into the plugin is refused (exit 2)" 2 "$sl_rc"
  assert_contains "symlink bypass collapsed by pwd -P"                   "$sl_err" "plugin tree"
else
  printf '  skip symlink-bypass test (could not create symlink)\n'
fi
rm -rf "$sl"

# Write target outside cwd without --yes -> refused before any launch.
otherdir="$(mktemp -d)"
bash "$RUN" --agent codex --target "$otherdir" --prompt x >/dev/null 2>&1
assert_exit "non-cwd write without --yes exits 2" 2 "$?"
rmdir "$otherdir" 2>/dev/null || true

# --timeout must be a positive integer, validated up front (before any launch).
bash "$RUN" --agent codex --dry-run --timeout abc --prompt x >/dev/null 2>&1
assert_exit "--timeout abc exits 2" 2 "$?"
bash "$RUN" --agent codex --dry-run --timeout 0 --prompt x >/dev/null 2>&1
assert_exit "--timeout 0 exits 2" 2 "$?"
bash "$RUN" --agent codex --dry-run --timeout 30 --prompt x >/dev/null 2>&1
assert_exit "valid --timeout 30 accepted" 0 "$?"

echo "== version lockstep (plugin.json == SKILL.md == README badge) =="
pv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
sv="$(grep -oE '^  version: "[^"]+"' "$ROOT/skills/external-agents/SKILL.md" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
rvraw="$(grep -oE 'badge/version-.*-informational' "$ROOT/README.md" | head -1 | sed -E 's#badge/version-(.*)-informational#\1#')"
# Reverse the shields.io message escaping ('--'->'-', '__'->'_').
rv="$(printf '%s' "$rvraw" | sed -e 's/--/-/g' -e 's/__/_/g')"
if [ "$pv" = "$sv" ] && [ "$pv" = "$rv" ]; then
  ok "all version strings agree ($pv)"
else
  bad "all version strings agree" "plugin.json=$pv SKILL.md=$sv README=$rv"
fi

out="$(bash "$RUN" --version 2>/dev/null)"
assert_contains "run-agent.sh --version prints the plugin version" "$out" "$pv"
out="$(bash "$RUN" -V 2>/dev/null)"
assert_contains "run-agent.sh -V prints the plugin version" "$out" "$pv"

echo "== bump-version.sh version compute (--dry-run, no writes) =="
BV="$ROOT/scripts/bump-version.sh"
core="${pv%%-*}"   # current release core, pre-release suffix stripped
IFS=. read -r _ma _mi _pa <<<"$core"
if [ -n "${_pa:-}" ]; then
  exp_patch="$_ma.$_mi.$((_pa + 1))"
  exp_minor="$_ma.$((_mi + 1)).0"
  exp_major="$((_ma + 1)).0.0"
  # ALLOW_DIRTY=1 bypasses the dirty-tree guard; --dry-run modifies nothing.
  assert_contains "bump patch -> $exp_patch" "$(ALLOW_DIRTY=1 bash "$BV" patch --dry-run 2>/dev/null)" "-> $exp_patch"
  assert_contains "bump minor -> $exp_minor" "$(ALLOW_DIRTY=1 bash "$BV" minor --dry-run 2>/dev/null)" "-> $exp_minor"
  assert_contains "bump major -> $exp_major" "$(ALLOW_DIRTY=1 bash "$BV" major --dry-run 2>/dev/null)" "-> $exp_major"
  assert_contains "explicit X.Y.Z target"   "$(ALLOW_DIRTY=1 bash "$BV" 2.5.0 --dry-run 2>/dev/null)" "-> 2.5.0"
  assert_contains "explicit pre-release"     "$(ALLOW_DIRTY=1 bash "$BV" 2.0.0-rc.1 --dry-run 2>/dev/null)" "-> 2.0.0-rc.1"
else
  printf '  skip bump-version compute (could not parse current version %s)\n' "$pv"
fi

echo "== agy quota-aware fallback model pick (--dry-run, stubbed quota) =="
PRIMARY="Claude Sonnet 4.6 (Thinking)"   # agy 'high' tier primary model
FALLBACK="Gemini 3.5 Flash (High)"       # agy 'high' tier Gemini fallback
stub="$(mktemp)"
# agy_pick JSON -> resolved agy --dry-run argv, with the quota CLI stubbed to emit JSON.
agy_pick() {
  printf '%s' "$1" >"$stub"
  EXTERNAL_AGENTS_AGY_QUOTA_CMD="cat $stub" bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>/dev/null
}
assert_contains "agy quota available keeps primary" \
  "$(agy_pick "{\"models\":[{\"label\":\"$PRIMARY\",\"remainingPercentage\":0.5,\"isExhausted\":false}]}")" "$PRIMARY"
assert_contains "agy quota exhausted -> fallback" \
  "$(agy_pick "{\"models\":[{\"label\":\"$PRIMARY\",\"isExhausted\":true}]}")" "$FALLBACK"
assert_contains "agy label-not-found -> fallback" \
  "$(agy_pick '{"models":[]}')" "$FALLBACK"
assert_contains "agy quota CLI unavailable -> fallback" \
  "$(EXTERNAL_AGENTS_AGY_QUOTA_CMD=false bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>/dev/null)" "$FALLBACK"
# Graceful degradation (Phase 2.5): an unconfirmable quota must yield the 'unknown' NOTE and the
# Gemini fallback, and NEVER the unconfirmed primary — deterministic and offline-reproducible.
deg_out="$(EXTERNAL_AGENTS_AGY_QUOTA_CMD=false bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>/dev/null)"
deg_note="$(EXTERNAL_AGENTS_AGY_QUOTA_CMD=false bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>&1 >/dev/null)"
assert_contains "degradation: unconfirmable quota emits the 'unknown' NOTE" "$deg_note" "is unknown"
case "$deg_out" in *"$PRIMARY"*) bad "degradation: the unconfirmed primary is never selected" "primary '$PRIMARY' resolved without quota confirmation";; *) ok "degradation: the unconfirmed primary is never selected";; esac
rm -f "$stub"

echo "== per-agent fan-out record fields (stub fan-out, no live CLI) =="
# The collect loop builds a control-plane record per agent ($OUT/<a>.record): tab-delimited
# agent/model/tier/effort/mode/rc/sec/bytes/fallback. Assert the fields for a multi-agent shape
# using stub agents (no real CLI), including the agy fallback flag and that NO transcript text leaks.
if command -v timeout >/dev/null 2>&1; then
  recstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "stub response"\n' >"$recstub/$b"; chmod +x "$recstub/$b"; done
  rectgt="$(mktemp -d)"; recodir="$(mktemp -d)"
  PATH="$recstub:$PATH" EXTERNAL_AGENTS_OUT="$recodir" \
    bash "$RUN" --agent all --effort high --read-only --target "$rectgt" --prompt x >/dev/null 2>&1
  recproj="$recodir/$(basename "$rectgt")"
  codex_rec="$(tr '\t' '|' <"$recproj/codex.record" 2>/dev/null)"
  assert_contains "record: codex agent field"  "$codex_rec" "codex|"
  assert_contains "record: codex tier=high"     "$codex_rec" "|high|"
  assert_contains "record: codex mode=readonly" "$codex_rec" "|readonly|"
  case "$codex_rec" in *"|0") ok "record: codex fallback-taken=0";; *) bad "record: codex fallback-taken=0" "got [$codex_rec]";; esac
  agy_rec="$(tr '\t' '|' <"$recproj/agy.record" 2>/dev/null)"
  case "$agy_rec" in *"|1") ok "record: agy fallback-taken=1 at the high tier (IDE closed)";; *) bad "record: agy fallback-taken=1 at the high tier" "got [$agy_rec]";; esac
  case "$agy_rec" in *"stub response"*) bad "record: control-plane only (no transcript text)" "transcript leaked into the record";; *) ok "record: control-plane only (no transcript text)";; esac
  # A multi-agent shape yields one record per enabled agent.
  recn=0; for a in agy codex cursor; do [ -f "$recproj/$a.record" ] && recn=$((recn + 1)); done
  assert_exit "record: one record per fan-out agent (3)" 3 "$recn"
  rm -rf "$recstub" "$rectgt" "$recodir"
else
  printf '  skip per-agent record test (timeout unavailable)\n'
fi

echo "== per-run metadata record (.meta.json) presence + resolved values (stub fan-out) =="
# Every run writes one structured JSON metadata record per agent ($OUT/<a>.meta.json) next to its
# transcript. Assert it is produced with the declared fields and post-fallback resolved values
# (incl. the agy quota fallback -> fallback:true at the high tier with the IDE closed), carrying NO
# transcript text — all offline with stub agents (no real CLI).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  mstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "stub transcript text"\n' >"$mstub/$b"; chmod +x "$mstub/$b"; done
  mtgt="$(mktemp -d)"; modir="$(mktemp -d)"
  PATH="$mstub:$PATH" EXTERNAL_AGENTS_OUT="$modir" \
    bash "$RUN" --agent all --effort high --read-only --target "$mtgt" --prompt x >/dev/null 2>&1
  mproj="$modir/$(basename "$mtgt")"
  # (1) one meta.json per enabled agent (3).
  metan=0; for a in agy codex cursor; do [ -f "$mproj/$a.meta.json" ] && metan=$((metan + 1)); done
  assert_exit "meta: one record per fan-out agent (3)" 3 "$metan"
  # (2) codex record: well-formed, all declared keys, resolved values, numeric rc/bytes, fallback:false.
  cmeta="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("INVALID"); sys.exit(0)
req = {"agent","model","tier","effort","mode","target","rc","sec","bytes","fallback","timestamp"}
if not req <= set(d): print("MISSING"); sys.exit(0)
if d["agent"] != "codex" or d["tier"] != "high" or d["mode"] != "readonly": print("WRONG_VALUES"); sys.exit(0)
if d["fallback"] is not False: print("BAD_FALLBACK"); sys.exit(0)
if not isinstance(d["rc"], int) or not isinstance(d["bytes"], int): print("BAD_NUMS"); sys.exit(0)
print("OK")
' "$mproj/codex.meta.json" 2>/dev/null)"
  assert_contains "meta: codex record well-formed with resolved values" "$cmeta" "OK"
  # (3) agy record: the quota fallback swapped the primary at the high tier (IDE closed) -> fallback:true (boolean).
  ameta="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("INVALID"); sys.exit(0)
print("OK" if d.get("fallback") is True else "NOT_TRUE")
' "$mproj/agy.meta.json" 2>/dev/null)"
  assert_contains "meta: agy fallback:true at the high tier (IDE closed)" "$ameta" "OK"
  # (4) control-plane only — the stub transcript text never reaches the record.
  case "$(cat "$mproj/codex.meta.json" 2>/dev/null)" in
    *"stub transcript text"*) bad "meta: record carries no transcript text" "transcript leaked into meta.json";;
    *)                        ok  "meta: record carries no transcript text";;
  esac
  rm -rf "$mstub" "$mtgt" "$modir"
else
  printf '  skip per-run metadata record test (timeout/python3 unavailable)\n'
fi

echo "== run index (index.jsonl) growth + row content (stub runs, no live CLI) =="
# The driver appends one JSON-Lines row per agent per run to <base>/index.jsonl. Assert it grows by
# the expected count, a fan-out shares one run_id (a later single run gets a distinct one), rows carry
# the resolved model/tier/mode/rc and a fallback boolean (agy quota fallback -> true), and no
# transcript text leaks — all offline with stub agents.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  istub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "stub transcript text"\n' >"$istub/$b"; chmod +x "$istub/$b"; done
  itgt="$(mktemp -d)"; ibase="$(mktemp -d)"
  # Run 1: a 3-agent fan-out -> 3 rows.  Run 2: a single agent -> +1 row (growth, distinct run_id).
  PATH="$istub:$PATH" EXTERNAL_AGENTS_OUT="$ibase" \
    bash "$RUN" --agent all --effort high --read-only --target "$itgt" --prompt x >/dev/null 2>&1
  PATH="$istub:$PATH" EXTERNAL_AGENTS_OUT="$ibase" \
    bash "$RUN" --agent codex --effort high --read-only --target "$itgt" --prompt y >/dev/null 2>&1
  ival="$(python3 -c '
import json, sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
rows = [json.loads(l) for l in lines]
if len(rows) != 4: print("BAD_COUNT"); sys.exit(0)
req = {"run_id","timestamp","project","agent","model","tier","effort","mode","target","rc","sec","bytes","fallback"}
if any(not req <= set(r) for r in rows): print("MISSING_KEYS"); sys.exit(0)
fan = rows[:3]
if len({r["run_id"] for r in fan}) != 1: print("FANOUT_RUNID"); sys.exit(0)
if rows[3]["run_id"] == fan[0]["run_id"]: print("SINGLE_RUNID"); sys.exit(0)
cx = [r for r in fan if r["agent"] == "codex"][0]
if cx["model"] != "gpt-5.5" or cx["tier"] != "high" or cx["mode"] != "readonly" or cx["rc"] != 0: print("WRONG_RESOLVED"); sys.exit(0)
if any(not isinstance(r["fallback"], bool) for r in rows): print("BAD_FALLBACK"); sys.exit(0)
if [r for r in fan if r["agent"] == "agy"][0]["fallback"] is not True: print("AGY_FALLBACK"); sys.exit(0)
print("OK")
' "$ibase/index.jsonl" 2>/dev/null)"
  assert_contains "index: grows by row-per-agent with resolved fields + run_id grouping" "$ival" "OK"
  case "$(cat "$ibase/index.jsonl" 2>/dev/null)" in
    *"stub transcript text"*) bad "index: rows carry no transcript text" "transcript leaked into the index";;
    *)                        ok  "index: rows carry no transcript text";;
  esac
  rm -rf "$istub" "$itgt" "$ibase"
else
  printf '  skip run-index test (timeout/python3 unavailable)\n'
fi

echo "== signal extraction over fixture transcripts (present / absent, no live CLI) =="
# Feed captured fixture transcripts (one with token+cost lines, one with neither) through the REAL
# run_one -> extract_signal path via a stub that cats the fixture, and assert the per-run record's
# signals: present -> the parsed values (tokens a number, cost verbatim); absent -> "unavailable".
# The fixtures are committed here and written to disk so the cat-stub reads them VERBATIM (no shell
# expansion of the literal '$' in the cost line).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  sigdir="$(mktemp -d)"
  printf '%s\n' 'reviewed the change. total tokens: 1543 and total cost: $0.0421 — done' >"$sigdir/present.txt"
  printf '%s\n' 'I reviewed the code and found no issues. Looks good, ship it.'           >"$sigdir/absent.txt"
  cat >"$sigdir/codex" <<'STUBEOF'
#!/usr/bin/env bash
cat "$SIG_FIXTURE"
STUBEOF
  chmod +x "$sigdir/codex"
  sig_signals() {  # fixture-path -> the meta.json "signals" object as compact JSON
    local fix="$1" tgt odir
    tgt="$(mktemp -d)"; odir="$(mktemp -d)"
    SIG_FIXTURE="$fix" PATH="$sigdir:$PATH" EXTERNAL_AGENTS_OUT="$odir" \
      bash "$RUN" --agent codex --read-only --target "$tgt" --prompt x >/dev/null 2>&1
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["signals"], separators=(",",":")))' \
      "$odir/$(basename "$tgt")/codex.meta.json" 2>/dev/null
    rm -rf "$tgt" "$odir"
  }
  pres="$(sig_signals "$sigdir/present.txt")"
  assert_contains "signals: present fixture extracts a numeric token count" "$pres" '"tokens":1543'
  assert_contains "signals: present fixture extracts the cost verbatim"     "$pres" '"cost":"$0.0421"'
  absn="$(sig_signals "$sigdir/absent.txt")"
  assert_contains "signals: absent fixture -> tokens unavailable" "$absn" '"tokens":"unavailable"'
  assert_contains "signals: absent fixture -> cost unavailable"   "$absn" '"cost":"unavailable"'
  rm -rf "$sigdir"
else
  printf '  skip signal-extraction fixture test (timeout/python3 unavailable)\n'
fi

echo "== cross-agent summary block (stub fan-out, no live CLI) =="
# A --agent all fan-out prints a compact summary block (one row per agent + expected columns).
# Assert its shape with stub agents, plus the write-mode target-wide note on a write fan-out.
if command -v timeout >/dev/null 2>&1; then
  sumstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "resp"\n' >"$sumstub/$b"; chmod +x "$sumstub/$b"; done
  sumtgt="$(mktemp -d)"; sumodir="$(mktemp -d)"
  sum_out="$(PATH="$sumstub:$PATH" EXTERNAL_AGENTS_OUT="$sumodir" bash "$RUN" --agent all --effort high --read-only --target "$sumtgt" --prompt x 2>/dev/null)"
  assert_contains "summary: header block present"      "$sum_out" "fan-out summary"
  assert_contains "summary: expected columns (agent…)" "$sum_out" "agent"
  assert_contains "summary: fallback column present"   "$sum_out" "fallback"
  sumblock="$(printf '%s\n' "$sum_out" | sed -n '/fan-out summary/,/^$/p')"
  for a in agy codex cursor; do assert_contains "summary: row for $a" "$sumblock" "$a"; done
  case "$sum_out" in *target-wide*) bad "summary: no target-wide note on a read-only fan-out" "note appeared";; *) ok "summary: no target-wide note on a read-only fan-out";; esac
  rm -rf "$sumstub" "$sumtgt" "$sumodir"
  # Write fan-out: the target-wide note IS present (the write-mode code path shape).
  wsumstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho resp\n' >"$wsumstub/$b"; chmod +x "$wsumstub/$b"; done
  wsumtgt="$(mktemp -d)"; wsumodir="$(mktemp -d)"
  ( cd "$wsumtgt" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  wsum_out="$(PATH="$wsumstub:$PATH" EXTERNAL_AGENTS_OUT="$wsumodir" bash "$RUN" --agent all --write --yes --target "$wsumtgt" --prompt x 2>/dev/null)"
  assert_contains "summary: write fan-out notes target-wide verification" "$wsum_out" "target-wide"
  rm -rf "$wsumstub" "$wsumtgt" "$wsumodir"
else
  printf '  skip summary-block test (timeout unavailable)\n'
fi

echo "== fan-out agreement signal (stub fan-out, no live CLI) =="
# The summary closes with a deterministic all-ok / mixed / all-fail agreement (from the success
# tally) plus a read-only no-mutation line on a git target. Assert each shape with stub agents.
if command -v timeout >/dev/null 2>&1; then
  agtgt="$(mktemp -d)"
  agok="$(mktemp -d)"; for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho resp\n' >"$agok/$b"; chmod +x "$agok/$b"; done
  agod="$(mktemp -d)"
  assert_contains "agreement: all-ok rendered" \
    "$(PATH="$agok:$PATH" EXTERNAL_AGENTS_OUT="$agod" bash "$RUN" --agent all --read-only --target "$agtgt" --prompt x 2>/dev/null)" "agreement: all-ok"
  agf="$(mktemp -d)"; for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\nexit 1\n' >"$agf/$b"; chmod +x "$agf/$b"; done
  afod="$(mktemp -d)"
  assert_contains "agreement: all-fail rendered" \
    "$(PATH="$agf:$PATH" EXTERNAL_AGENTS_OUT="$afod" bash "$RUN" --agent all --read-only --target "$agtgt" --prompt x 2>/dev/null)" "agreement: all-fail"
  agm="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho resp\n' >"$agm/codex"; printf '#!/usr/bin/env bash\nexit 1\n' >"$agm/agy"; printf '#!/usr/bin/env bash\nexit 1\n' >"$agm/cursor-agent"; chmod +x "$agm"/*
  amod="$(mktemp -d)"
  assert_contains "agreement: mixed rendered" \
    "$(PATH="$agm:$PATH" EXTERNAL_AGENTS_OUT="$amod" bash "$RUN" --agent all --read-only --target "$agtgt" --prompt x 2>/dev/null)" "agreement: mixed"
  nmgt="$(mktemp -d)"; ( cd "$nmgt" && git init -q && echo s >s.txt && git add . && git -c user.email=t@t -c user.name=t commit -qm s )
  nmod="$(mktemp -d)"
  assert_contains "agreement: read-only no-mutation (all unchanged)" \
    "$(PATH="$agok:$PATH" EXTERNAL_AGENTS_OUT="$nmod" bash "$RUN" --agent all --read-only --target "$nmgt" --prompt x 2>/dev/null)" "all agents left the tree unchanged"
  rm -rf "$agtgt" "$agok" "$agod" "$agf" "$afod" "$agm" "$amod" "$nmgt" "$nmod"
else
  printf '  skip agreement-signal test (timeout unavailable)\n'
fi

echo "== opt-in JSON run summary (--json) shape validation (stub fan-out) =="
# The --json document must be well-formed and carry the declared keys (run-level + per-agent), only
# when --json is set, and never any transcript content. Validate the shape with python3.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  jstub="$(mktemp -d)"; for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "resp text"\n' >"$jstub/$b"; chmod +x "$jstub/$b"; done
  jtgt="$(mktemp -d)"; jod="$(mktemp -d)"
  json_doc="$(PATH="$jstub:$PATH" EXTERNAL_AGENTS_OUT="$jod" bash "$RUN" --agent all --effort high --read-only --json --target "$jtgt" --prompt x 2>/dev/null | tail -1)"
  jval="$(printf '%s' "$json_doc" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("INVALID:", e); sys.exit(0)
if not {"mode","tier","ok","fail","count","agreement","agents"}.issubset(d): print("MISSING_TOP"); sys.exit(0)
if not isinstance(d["agents"], list) or not d["agents"]: print("NO_AGENTS"); sys.exit(0)
ak = {"agent","model","tier","effort","mode","rc","sec","bytes","fallback"}
if any(not ak.issubset(a) for a in d["agents"]): print("MISSING_AGENT_KEYS"); sys.exit(0)
if d["count"] != len(d["agents"]): print("COUNT_MISMATCH"); sys.exit(0)
print("OK")
' 2>/dev/null)"
  assert_contains "JSON: emitted summary validates (well-formed + required keys)" "$jval" "OK"
  case "$json_doc" in *"resp text"*) bad "JSON: carries no transcript content" "transcript leaked into the JSON";; *) ok "JSON: carries no transcript content";; esac
  nojson="$(PATH="$jstub:$PATH" EXTERNAL_AGENTS_OUT="$jod" bash "$RUN" --agent all --read-only --target "$jtgt" --prompt x 2>/dev/null)"
  case "$nojson" in *'"agreement"'*) bad "JSON: absent without --json" "JSON document appeared without the flag";; *) ok "JSON: absent without --json";; esac
  rm -rf "$jstub" "$jtgt" "$jod"
else
  printf '  skip JSON summary validation (timeout/python3 unavailable)\n'
fi

echo "== transcript secret-redaction (stub agent, real redact path) =="
# run_stub_transcript TEXT FILEVAR -> stdout = the driver's echoed (redacted) transcript;
# the persisted (redacted) transcript file content is written to the path FILEVAR (a disk
# write so it survives the command-substitution subshell). A stub 'codex' emits TEXT, so the
# REAL run_one -> redact -> persist -> echo path runs offline (no network / real CLI).
run_stub_transcript() {
  local text="$1" filevar="$2" sdir tgt odir
  sdir="$(mktemp -d)"; tgt="$(mktemp -d)"; odir="$(mktemp -d)"
  cat >"$sdir/codex" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$STUB_TEXT"
STUBEOF
  chmod +x "$sdir/codex"
  STUB_TEXT="$text" PATH="$sdir:$PATH" EXTERNAL_AGENTS_OUT="$odir" \
    bash "$RUN" --agent codex --read-only --target "$tgt" --prompt x 2>/dev/null
  cat "$odir/$(basename "$tgt")/codex.md" 2>/dev/null >"$filevar"
  rm -rf "$sdir" "$tgt" "$odir"
}
if command -v timeout >/dev/null 2>&1; then
  SECRET="sk-ABCDEFGHIJKLMNOPQRSTUV0123456789"
  rf="$(mktemp)"
  red_out="$(run_stub_transcript "leaking $SECRET in agent output" "$rf")"
  red_file="$(cat "$rf")"; rm -f "$rf"
  case "$red_out"  in *"$SECRET"*) bad "redaction: raw secret absent from echoed transcript" "leaked to stdout";; *) ok "redaction: raw secret absent from echoed transcript";; esac
  assert_contains "redaction: placeholder present in echoed transcript"  "$red_out"  "<REDACTED>"
  case "$red_file" in *"$SECRET"*) bad "redaction: raw secret absent from persisted transcript" "leaked to disk";; *) ok "redaction: raw secret absent from persisted transcript";; esac
  assert_contains "redaction: placeholder present in persisted transcript" "$red_file" "<REDACTED>"
else
  printf '  skip redaction tests (timeout unavailable)\n'
fi

echo "== redaction false-positive guard (ordinary content survives) =="
if command -v timeout >/dev/null 2>&1; then
  rf="$(mktemp)"
  PROSE="the quick brown fox v0.6.0 sk-short reads files and exits 0 cleanly"
  fp_out="$(run_stub_transcript "$PROSE" "$rf")"
  fp_file="$(cat "$rf")"; rm -f "$rf"
  case "$fp_out"  in *"<REDACTED>"*) bad "guard: ordinary prose not over-redacted (echo)" "redaction fired on safe text";; *) ok "guard: ordinary prose not over-redacted (echo)";; esac
  assert_contains "guard: ordinary words pass through unchanged" "$fp_out" "the quick brown fox"
  assert_contains "guard: short token sk-short survives (length-bounded)" "$fp_out" "sk-short"
  assert_contains "guard: version string survives" "$fp_out" "v0.6.0"
  case "$fp_file" in *"<REDACTED>"*) bad "guard: ordinary content not over-redacted (persisted)" "redaction fired on disk";; *) ok "guard: ordinary content not over-redacted (persisted)";; esac
else
  printf '  skip redaction guard tests (timeout unavailable)\n'
fi

echo "== transcript redaction assurance (both surfaces, mixed token shapes) =="
# Threat-model assurance distinct from the Phase 1.3 sk- test: a planted Bearer token and a
# TOKEN= assignment must be masked in BOTH the persisted file and the stdout echo at once.
if command -v timeout >/dev/null 2>&1; then
  rf="$(mktemp)"
  raw_btok="ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
  raw_kval="hunter2secretdeploykeyvalue"
  asr_out="$(run_stub_transcript "auth Bearer $raw_btok and DEPLOY_TOKEN=$raw_kval end" "$rf")"
  asr_file="$(cat "$rf")"; rm -f "$rf"
  case "$asr_out"  in *"$raw_btok"*) bad "assurance: Bearer token masked in echo" "leaked to stdout";; *) ok "assurance: Bearer token masked in echo";; esac
  case "$asr_file" in *"$raw_btok"*) bad "assurance: Bearer token masked in persisted file" "leaked to disk";; *) ok "assurance: Bearer token masked in persisted file";; esac
  case "$asr_out"  in *"$raw_kval"*) bad "assurance: TOKEN= value masked in echo" "leaked to stdout";; *) ok "assurance: TOKEN= value masked in echo";; esac
  case "$asr_file" in *"$raw_kval"*) bad "assurance: TOKEN= value masked in persisted file" "leaked to disk";; *) ok "assurance: TOKEN= value masked in persisted file";; esac
  assert_contains "assurance: placeholder present after masking" "$asr_out" "<REDACTED>"
else
  printf '  skip redaction assurance tests (timeout unavailable)\n'
fi

echo "== redaction no-false-positive assurance (realistic transcript unchanged) =="
# A realistic agent transcript (function names, file:line refs, a short commit hash, a PR
# number) must pass through the collect path with nothing masked.
if command -v timeout >/dev/null 2>&1; then
  rf="$(mktemp)"
  REVIEW="Reviewed run-agent.sh:611 build_argv() looks correct; see commit a1b2c3d and PR #42. No issues."
  na_out="$(run_stub_transcript "$REVIEW" "$rf")"
  na_file="$(cat "$rf")"; rm -f "$rf"
  case "$na_out"  in *"<REDACTED>"*) bad "no-false-positive: realistic transcript unchanged (echo)" "over-redacted";; *) ok "no-false-positive: realistic transcript unchanged (echo)";; esac
  case "$na_file" in *"<REDACTED>"*) bad "no-false-positive: realistic transcript unchanged (persisted)" "over-redacted";; *) ok "no-false-positive: realistic transcript unchanged (persisted)";; esac
  assert_contains "no-false-positive: review content preserved verbatim" "$na_out" "build_argv() looks correct"
else
  printf '  skip redaction no-false-positive assurance (timeout unavailable)\n'
fi

echo "== post-write git verification + non-git warning (stub agent, write mode) =="
# A stub 'codex' makes a small edit, so the driver's real write path runs offline: a git target
# must print the verification block; a non-git target must warn and suppress the block.
if command -v timeout >/dev/null 2>&1; then
  wstub="$(mktemp -d)"
  cat >"$wstub/codex" <<'STUBEOF'
#!/usr/bin/env bash
printf 'did the edit\n'
printf 'agent-marker\n' >> agent_edit.txt
STUBEOF
  chmod +x "$wstub/codex"
  # (a) git target -> verification block on stdout.
  gtgt="$(mktemp -d)"; godir="$(mktemp -d)"
  ( cd "$gtgt" && git init -q && git config user.email t@t && git config user.name t && echo seed >seed.txt && git add . && git commit -qm seed )
  gout="$(PATH="$wstub:$PATH" EXTERNAL_AGENTS_OUT="$godir" bash "$RUN" --agent codex --write --yes --target "$gtgt" --prompt x 2>/dev/null)"
  assert_contains "post-write verification header on a git target" "$gout" "git changes after write"
  # (b) non-git target -> no-baseline warning (stderr) and NO verification block (stdout).
  ntgt="$(mktemp -d)"; nodir="$(mktemp -d)"
  nerr="$(PATH="$wstub:$PATH" EXTERNAL_AGENTS_OUT="$nodir" bash "$RUN" --agent codex --write --yes --target "$ntgt" --prompt x 2>&1 >/dev/null)"
  nout="$(PATH="$wstub:$PATH" EXTERNAL_AGENTS_OUT="$nodir" bash "$RUN" --agent codex --write --yes --target "$ntgt" --prompt x 2>/dev/null)"
  assert_contains "non-git target warns: no baseline to diff/revert" "$nerr" "no baseline to diff or revert"
  case "$nout" in *"git changes after write"*) bad "non-git target suppresses the verification block" "block appeared without a git baseline";; *) ok "non-git target suppresses the verification block";; esac
  rm -rf "$wstub" "$gtgt" "$godir" "$ntgt" "$nodir"
else
  printf '  skip post-write verification test (timeout unavailable)\n'
fi

echo "== live argv record == masked --dry-run argv (stub agent, real launch path) =="
# run_one writes $OUT/<a>.argv (the launch argv with the prompt masked) before launching.
# The live harness compares that record against the --dry-run argv to prove the live launch
# argv is correct; this asserts they are byte-identical offline (stub codex, no real CLI).
if command -v timeout >/dev/null 2>&1; then
  astub="$(mktemp -d)"; atgt="$(mktemp -d)"; aodir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntrue\n' >"$astub/codex"; chmod +x "$astub/codex"
  # Real (non-dry) launch through run_one -> writes the masked argv record.
  PATH="$astub:$PATH" EXTERNAL_AGENTS_OUT="$aodir" \
    bash "$RUN" --agent codex --read-only --target "$atgt" --prompt 'top secret prompt text' >/dev/null 2>&1
  argv_rec="$(cat "$aodir/$(basename "$atgt")/codex.argv" 2>/dev/null)"
  # The masked --dry-run argv for the SAME invocation, with the '  codex ' label stripped.
  argv_dry="$(bash "$RUN" --agent codex --read-only --target "$atgt" --dry-run --prompt 'top secret prompt text' 2>/dev/null | sed -nE 's/^  codex +//p')"
  if [ -n "$argv_rec" ] && [ "$argv_rec" = "$argv_dry" ]; then
    ok "live argv record equals the masked --dry-run argv"
  else
    bad "live argv record equals the masked --dry-run argv" "record=[$argv_rec] dry=[$argv_dry]"
  fi
  case "$argv_rec" in *"top secret prompt text"*) bad "live argv record masks the prompt (no leak)" "prompt text leaked into the record";; *) ok "live argv record masks the prompt (no leak)";; esac
  assert_contains "live argv record uses the <PROMPT> placeholder" "$argv_rec" "<PROMPT>"
  rm -rf "$astub" "$atgt" "$aodir"
else
  printf '  skip live-argv-record test (timeout unavailable)\n'
fi

echo "== live argv record secret-safety (a secret-bearing prompt never leaks) =="
# Even when the prompt embeds a secret-shaped token, the argv record masks the whole prompt
# at PROMPT_IDX to <PROMPT> — so neither the secret nor the prompt text reaches the record,
# and no other argv token (flags/model/target) carries sensitive data.
if command -v timeout >/dev/null 2>&1; then
  sstub="$(mktemp -d)"; stgt="$(mktemp -d)"; sodir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntrue\n' >"$sstub/codex"; chmod +x "$sstub/codex"
  SEKRIT="sk-LIVESMOKE0123456789ABCDEFGHIJ"
  PATH="$sstub:$PATH" EXTERNAL_AGENTS_OUT="$sodir" \
    bash "$RUN" --agent codex --read-only --target "$stgt" --prompt "please use token $SEKRIT now" >/dev/null 2>&1
  srec="$(cat "$sodir/$(basename "$stgt")/codex.argv" 2>/dev/null)"
  assert_contains "secret-bearing prompt is masked at PROMPT_IDX (<PROMPT>)" "$srec" "<PROMPT>"
  case "$srec" in *"$SEKRIT"*) bad "argv record carries no secret from the prompt" "secret leaked into the argv record";; *) ok "argv record carries no secret from the prompt";; esac
  case "$srec" in *"please use token"*) bad "argv record carries no prompt text" "prompt text leaked into the argv record";; *) ok "argv record carries no prompt text";; esac
  # Every non-prompt token is a flag/model/target — the record is exactly the resolved
  # codex read-only argv with <PROMPT> as the sole payload slot.
  assert_contains "argv record is the resolved codex read-only argv" "$srec" "codex exec -s read-only"
  rm -rf "$sstub" "$stgt" "$sodir"
else
  printf '  skip argv-record secret-safety test (timeout unavailable)\n'
fi

echo "== live-smoke sandbox fixture (disposable, git-backed, outside the plugin tree) =="
# Source the live harness — it guards main() behind a direct-execution check, so sourcing
# only defines its helper functions — then assert make_sandbox returns a seeded git tree
# that is NEVER inside the plugin tree (a read-only live run must target a throwaway).
# shellcheck source=/dev/null  # dynamic absolute-path source, not followed by shellcheck
. "$ROOT/tests/live-smoke.sh"
sb="$(make_sandbox)"
if [ -n "$sb" ] && [ -d "$sb" ]; then
  case "$sb/" in
    "$ROOT/"*) bad "sandbox path is never inside the plugin tree" "got $sb under $ROOT";;
    *)         ok "sandbox path is never inside the plugin tree";;
  esac
  if [ -d "$sb/.git" ]; then ok "sandbox is a git repo"; else bad "sandbox is a git repo" "no .git in $sb"; fi
  if [ -f "$sb/sample.py" ]; then ok "sandbox seeded from tests/fixtures"; else bad "sandbox seeded from tests/fixtures" "fixture sample.py not copied"; fi
  if [ -z "$(git -C "$sb" status --porcelain 2>/dev/null)" ]; then ok "fresh sandbox tree is clean"; else bad "fresh sandbox tree is clean" "unexpected dirty state in a fresh sandbox"; fi
  rm -rf "$sb"
else
  bad "make_sandbox produced a sandbox" "no path returned"
fi

echo "== live-smoke non-mutation snapshot (detects a change, clean when none) =="
# tree_changes diffs a git-backed sandbox against its seed commit. It must report clean for
# an untouched sandbox and name the changed path after a deliberately injected edit/addition.
# (make_sandbox/tree_changes were sourced from the harness in the block above.)
sb2="$(make_sandbox)"
if [ -n "$sb2" ] && [ -d "$sb2" ]; then
  if [ -z "$(tree_changes "$sb2")" ]; then ok "snapshot reports clean for an untouched sandbox"; else bad "snapshot reports clean for an untouched sandbox" "unexpected changes"; fi
  printf 'injected\n' >>"$sb2/sample.py"                      # deliberate edit of a tracked file
  case "$(tree_changes "$sb2")" in *sample.py*) ok "snapshot detects a tracked-file edit";; *) bad "snapshot detects a tracked-file edit" "edit not reported";; esac
  printf 'new\n' >"$sb2/INJECTED.txt"                          # deliberate untracked addition
  case "$(tree_changes "$sb2")" in *INJECTED.txt*) ok "snapshot detects an added file";; *) bad "snapshot detects an added file" "addition not reported";; esac
  rm -rf "$sb2"
else
  bad "make_sandbox produced a sandbox for the snapshot test" "no path returned"
fi

echo "== live-smoke enforced read-only non-mutation (stub agent, no real CLI) =="
# non_mutation_check runs an enforced agent read-only against a fresh sandbox and asserts the
# tree is byte-identical. A well-behaved stub leaves it clean (pass); a misbehaving stub that
# writes into the sandbox is caught by the tree_changes snapshot as a hard failure — proving
# the harness independently enforces non-mutation, not just trusting the CLI.
if command -v timeout >/dev/null 2>&1; then
  nmstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntrue\n' >"$nmstub/codex"; chmod +x "$nmstub/codex"
  if PATH="$nmstub:$PATH" non_mutation_check codex >/dev/null 2>&1; then ok "enforced read-only: clean stub reports no mutation"; else bad "enforced read-only: clean stub reports no mutation" "false mutation reported"; fi
  printf '#!/usr/bin/env bash\necho rogue > ROGUE.txt\n' >"$nmstub/codex"; chmod +x "$nmstub/codex"
  if PATH="$nmstub:$PATH" non_mutation_check codex >/dev/null 2>&1; then bad "enforced read-only: a mutation is a hard failure" "mutation not caught"; else ok "enforced read-only: a mutation is a hard failure"; fi
  rm -rf "$nmstub"
else
  printf '  skip enforced non-mutation test (timeout unavailable)\n'
fi

echo "== live-smoke agy read-only best-effort report (mutation never fails) =="
# agy read-only is best-effort (--sandbox), so agy_mutation_report only REPORTS whether the
# tree changed and never fails the harness — a clean run and a mutating run both return 0,
# both labelled best-effort, so agy is never over-claimed as enforced.
if command -v timeout >/dev/null 2>&1; then
  agstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntrue\n' >"$agstub/agy"; chmod +x "$agstub/agy"
  ag_clean="$(PATH="$agstub:$PATH" agy_mutation_report 2>&1)"; ag_clean_rc=$?
  assert_exit     "agy best-effort: a clean run does not fail"        0 "$ag_clean_rc"
  assert_contains "agy best-effort: clean run is labelled best-effort" "$ag_clean" "best-effort"
  assert_contains "agy best-effort: clean run reports unchanged"       "$ag_clean" "unchanged"
  printf '#!/usr/bin/env bash\necho oops > MUT.txt\n' >"$agstub/agy"; chmod +x "$agstub/agy"
  ag_mut="$(PATH="$agstub:$PATH" agy_mutation_report 2>&1)"; ag_mut_rc=$?
  assert_exit     "agy best-effort: a mutation does NOT fail the harness" 0 "$ag_mut_rc"
  assert_contains "agy best-effort: mutation labelled best-effort"        "$ag_mut" "best-effort"
  assert_contains "agy best-effort: mutation reported as a change"        "$ag_mut" "CHANGED"
  case "$ag_mut" in *[Ee]nforced*not*|*not*enforced*) ok "agy best-effort: never claimed as enforced";; *[Ee]nforced*) bad "agy best-effort: never claimed as enforced" "claimed enforced";; *) ok "agy best-effort: never claimed as enforced";; esac
  rm -rf "$agstub"
else
  printf '  skip agy best-effort report test (timeout unavailable)\n'
fi

echo "== bump-version.sh lockstep write (mktemp fixture, real repo untouched) =="
ft="$(mktemp -d)"
mkdir -p "$ft/scripts" "$ft/.claude-plugin" "$ft/skills/external-agents"
cp "$ROOT/scripts/bump-version.sh" "$ft/scripts/"
cp "$ROOT/.claude-plugin/plugin.json" "$ft/.claude-plugin/"
cp "$ROOT/CHANGELOG.md" "$ROOT/README.md" "$ft/"
cp "$ROOT/skills/external-agents/SKILL.md" "$ft/skills/external-agents/"
# ALLOW_DIRTY=1 so the dirty-tree guard self-skips wherever mktemp lands.
ALLOW_DIRTY=1 bash "$ft/scripts/bump-version.sh" 1.2.3 >/dev/null 2>&1
assert_exit "bump-version.sh write run succeeds" 0 "$?"
assert_contains "bump write: plugin.json -> 1.2.3" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ft/.claude-plugin/plugin.json" 2>/dev/null)" "1.2.3"
grep -q '^  version: "1.2.3"' "$ft/skills/external-agents/SKILL.md"; assert_exit "bump write: SKILL.md frontmatter synced" 0 "$?"
grep -q 'version-1.2.3-informational' "$ft/README.md"; assert_exit "bump write: README badge synced" 0 "$?"
grep -q '## \[1.2.3\]' "$ft/CHANGELOG.md"; assert_exit "bump write: CHANGELOG entry added" 0 "$?"
rm -rf "$ft"

echo "== dual-manifest decision lock (bumper references no .codex-plugin) =="
# Phase 7.1 removed the dead .codex-plugin/plugin.json reference — the repo ships only
# .claude-plugin/plugin.json. Lock that decision with a grep regression guard (mirroring the
# shellcheck-regression guard below): the bumper must not reference a non-existent .codex-plugin
# manifest again, which neither shellcheck nor the lockstep tests would otherwise catch.
if grep -q 'codex-plugin' "$ROOT/scripts/bump-version.sh"; then
  bad "bumper references no non-existent .codex-plugin manifest" "found a .codex-plugin reference in scripts/bump-version.sh"
else
  ok "bumper references no non-existent .codex-plugin manifest"
fi

echo "== --check preflight (diagnostic; restricted PATH, no agent CLIs) =="
# Run --check with a PATH that holds the shell utilities but NONE of the agent CLIs,
# so every candidate (agy/codex/claude/cursor) must be reported missing and the exit
# code must reflect it. Reuses the restricted-bin technique from the parity test above.
cdir="$(mktemp -d)"
mk_restricted_bin "$cdir"
chk_out="$(PATH="$cdir/bin" "$cdir/bin/bash" "$RUN" --check 2>&1)"; chk_rc=$?
rm -rf "$cdir"
assert_contains "--check prints the preflight header"        "$chk_out" "external-agents preflight:"
assert_contains "--check probes cursor as the cursor-agent binary" "$chk_out" "need cursor-agent on PATH"
assert_exit     "--check exits non-zero when agent CLIs are missing" 1 "$chk_rc"

echo "== --discover machine-readable reachable-agent set (restricted PATH) =="
# The live-smoke harness scopes itself to installed agents via run-agent.sh --discover.
# Under a restricted PATH with NO agent CLIs, every candidate must report 'missing' in
# the documented "<agent> present|missing <bin>" shape, and the call must stay offline.
disc_dir="$(mktemp -d)"
mk_restricted_bin "$disc_dir"
disc_out="$(PATH="$disc_dir/bin" "$disc_dir/bin/bash" "$RUN" --discover 2>/dev/null)"; disc_rc=$?
rm -rf "$disc_dir"
assert_exit     "--discover exits 0"                            0 "$disc_rc"
assert_contains "--discover reports agy missing"                "$disc_out" "agy missing"
assert_contains "--discover names cursor's cursor-agent binary" "$disc_out" "cursor missing cursor-agent"
# Shape: exactly one '<agent> present|missing <bin>' line per known agent (4).
disc_lines="$(printf '%s\n' "$disc_out" | grep -cE '^(agy|codex|claude|cursor) (present|missing) ')"
assert_exit     "--discover emits one shaped line per agent (4)" 4 "$disc_lines"

echo "== agents.json malformed-config resilience (degrade, never crash) =="
# (1) Hard-malformed: "agents" is an array, not an object -> rejected with a clear
#     message and exit 2 (conf_problem) before any agent is resolved.
mfx="$(mktemp)"
printf '%s' '{"default_tier":"medium","agents":[]}' >"$mfx"
mc_out="$(bash "$RUN" --conf "$mfx" --list 2>&1)"; mc_rc=$?
assert_exit     "malformed agents-as-array exits 2"      2 "$mc_rc"
assert_contains "malformed agents-as-array is explained" "$mc_out" '"agents" must be a JSON object'
# (2) Soft-malformed: a tier value is a string, not an object. Both config backends
#     must type-guard it to an empty model and render --list identically (no crash).
sfx="$(mktemp)"
printf '%s' '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":{"low":"oops"}}}}' >"$sfx"
sc_jq="$(bash "$RUN" --conf "$sfx" --list 2>/dev/null)"; sc_jq_rc=$?
sdir="$(mktemp -d)"; mk_restricted_bin "$sdir"
sc_py="$(PATH="$sdir/bin" "$sdir/bin/bash" "$RUN" --conf "$sfx" --list 2>/dev/null)"; sc_py_rc=$?
rm -rf "$sdir"
assert_exit "soft-malformed config: jq backend still exits 0"     0 "$sc_jq_rc"
assert_exit "soft-malformed config: python backend still exits 0" 0 "$sc_py_rc"
if [ -n "$sc_jq" ] && [ -n "$sc_py" ]; then
  if [ "$sc_jq" = "$sc_py" ]; then ok "jq/python3 degrade identically on a malformed tier"
  else bad "jq/python3 degrade identically on a malformed tier" "backends diverged"; fi
else
  printf '  skip soft-malformed parity (could not run both backends)\n'
fi
# (3) No agent enabled -> --agent all is refused with exit 2.
nfx="$(mktemp)"
printf '%s' '{"default_tier":"medium","agents":{"agy":{"enabled":false,"tiers":{}}}}' >"$nfx"
bash "$RUN" --conf "$nfx" --agent all --dry-run --prompt x >/dev/null 2>&1
assert_exit "no enabled agents: --agent all exits 2" 2 "$?"
rm -f "$mfx" "$sfx" "$nfx"

# Per-fixture degradation parity: each degenerate config must degrade IDENTICALLY across the
# jq and python3 backends (same --list output), not merely "not crash".
ddir="$(mktemp -d)"; mk_restricted_bin "$ddir"
degrade_parity() {  # desc  json
  local desc="$1" json="$2" f oj op
  f="$(mktemp)"; printf '%s' "$json" >"$f"
  oj="$(bash "$RUN" --conf "$f" --list 2>/dev/null)"
  op="$(PATH="$ddir/bin" "$ddir/bin/bash" "$RUN" --conf "$f" --list 2>/dev/null)"
  rm -f "$f"
  if [ "$oj" = "$op" ]; then ok "degrade parity: $desc (jq == python3)"; else bad "degrade parity: $desc" "backends diverged"; fi
}
degrade_parity "non-object agent value" '{"default_tier":"medium","agents":{"agy":"oops"}}'
degrade_parity "non-object tiers"       '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":"oops"}}}'
degrade_parity "non-string model"       '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":{"low":{"model":5}}}}}'
degrade_parity "missing tier"           '{"default_tier":"medium","agents":{"agy":{"enabled":true,"tiers":{}}}}'
rm -rf "$ddir"

echo "== --prompt-file resolution (stdin / file / missing / empty) =="
# All via --dry-run so no agent launches; the prompt is resolved before the dry-run print.
pf_stdin="$(printf 'from stdin' | bash "$RUN" --agent codex --dry-run --prompt-file - 2>/dev/null)"; pf_stdin_rc=$?
assert_exit     "--prompt-file - reads stdin (exit 0)"  0 "$pf_stdin_rc"
assert_contains "--prompt-file - resolves a codex argv" "$pf_stdin" "codex"
pf="$(mktemp)"; printf 'task from a file' >"$pf"
bash "$RUN" --agent codex --dry-run --prompt-file "$pf" >/dev/null 2>&1
assert_exit "--prompt-file FILE reads the file (exit 0)" 0 "$?"
rm -f "$pf"
bash "$RUN" --agent codex --dry-run --prompt-file /no/such/prompt/file >/dev/null 2>&1
assert_exit "--prompt-file missing file exits 2" 2 "$?"
bash "$RUN" --agent codex --dry-run --prompt-file /dev/null >/dev/null 2>&1
assert_exit "--prompt-file empty prompt exits 2" 2 "$?"

echo "== --read-only / --write mutual exclusion (safety guard) =="
# A read-only intent must never silently degrade into a write run (external agents
# could then mutate the tree) — both flag orders must be refused with exit 2.
bash "$RUN" --agent codex --read-only --write --dry-run --prompt x >/dev/null 2>&1
assert_exit "--read-only then --write exits 2" 2 "$?"
mx_err="$(bash "$RUN" --agent codex --write --read-only --dry-run --prompt x 2>&1 >/dev/null)"; mx_rc=$?
assert_exit     "--write then --read-only exits 2"    2 "$mx_rc"
assert_contains "mutual-exclusion error is explained" "$mx_err" "mutually exclusive"

echo "== bump-version.sh relative bump from a pre-release current version =="
# Exercises the suffix-stripping branch: a relative bump must strip the -rc/+meta
# suffix off the current version before incrementing (instead of crashing on split).
prf="$(mktemp -d)"
mkdir -p "$prf/scripts" "$prf/.claude-plugin"
cp "$ROOT/scripts/bump-version.sh" "$prf/scripts/"
cp "$ROOT/CHANGELOG.md" "$ROOT/README.md" "$prf/"
printf '%s\n' '{"name":"external-agents","version":"2.0.0-rc.1"}' >"$prf/.claude-plugin/plugin.json"
# ALLOW_DIRTY=1 so the dirty-tree guard self-skips wherever mktemp lands; --dry-run writes nothing.
assert_contains "bump patch from 2.0.0-rc.1 -> 2.0.1" \
  "$(ALLOW_DIRTY=1 bash "$prf/scripts/bump-version.sh" patch --dry-run 2>/dev/null)" "-> 2.0.1"
assert_contains "bump minor from 2.0.0-rc.1 -> 2.1.0" \
  "$(ALLOW_DIRTY=1 bash "$prf/scripts/bump-version.sh" minor --dry-run 2>/dev/null)" "-> 2.1.0"
rm -rf "$prf"

echo "== bump-version.sh aborts on non-UTF-8 (no partial bump) =="
# The strict-UTF-8 preflight must abort BEFORE the manifest is rewritten, so one bad
# byte can never leave version drift across files.
uft="$(mktemp -d)"
mkdir -p "$uft/scripts" "$uft/.claude-plugin"
cp "$ROOT/scripts/bump-version.sh" "$uft/scripts/"
printf '%s\n' '{"name":"external-agents","version":"1.0.0"}' >"$uft/.claude-plugin/plugin.json"
printf 'changelog \xff bad byte\n' >"$uft/CHANGELOG.md"   # invalid UTF-8 byte
uft_err="$(ALLOW_DIRTY=1 bash "$uft/scripts/bump-version.sh" patch 2>&1 >/dev/null)"; uft_rc=$?
assert_exit     "non-UTF-8 target aborts the bump (exit 1)" 1 "$uft_rc"
assert_contains "non-UTF-8 abort is explained"             "$uft_err" "not valid UTF-8"
uft_ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$uft/.claude-plugin/plugin.json" 2>/dev/null)"
assert_contains "plugin.json version unchanged after abort" "$uft_ver" "1.0.0"
rm -rf "$uft"

echo "== E2E fixture generator (deterministic git fixture, offline self-check) =="
# The E2E recipes drive real agents against a throwaway git fixture. Source the fixture lib
# (sourceable: defines helpers only) and assert e2e_make_fixture deterministically produces a
# git repo with the known seed file and exactly one initial commit, outside the plugin tree.
# shellcheck source=/dev/null  # dynamic absolute-path source, not followed by shellcheck
. "$ROOT/tests/e2e/lib/fixture.sh"
fx="$(e2e_make_fixture)"
if [ -n "$fx" ] && [ -d "$fx" ]; then
  case "$fx/" in
    "$ROOT/"*) bad "E2E fixture is outside the plugin tree" "got $fx under $ROOT";;
    *)         ok "E2E fixture is outside the plugin tree";;
  esac
  if [ -d "$fx/.git" ]; then ok "E2E fixture is a git repo"; else bad "E2E fixture is a git repo" "no .git in $fx"; fi
  if [ -f "$fx/$E2E_FIXTURE_SEED" ]; then ok "E2E fixture has the known seed file ($E2E_FIXTURE_SEED)"; else bad "E2E fixture has the known seed file" "missing $E2E_FIXTURE_SEED"; fi
  if [ "$(e2e_fixture_commit_count "$fx")" = "1" ]; then ok "E2E fixture has exactly one initial commit"; else bad "E2E fixture has exactly one initial commit" "got $(e2e_fixture_commit_count "$fx") commits"; fi
  if [ -z "$(git -C "$fx" status --porcelain 2>/dev/null)" ]; then ok "E2E fixture starts clean"; else bad "E2E fixture starts clean" "unexpected dirty state"; fi
  # e2e_fixture_reset must restore the fixture to its initial commit (drop edits + untracked).
  printf '%s\n' "$E2E_FIXTURE_MARKER" >>"$fx/$E2E_FIXTURE_SEED"   # deterministic edit
  printf 'junk\n' >"$fx/untracked.txt"                            # untracked addition
  e2e_fixture_reset "$fx"
  if [ -z "$(git -C "$fx" status --porcelain 2>/dev/null)" ] && [ ! -f "$fx/untracked.txt" ]; then
    ok "e2e_fixture_reset restores the fixture to its initial commit"
  else
    bad "e2e_fixture_reset restores the fixture to its initial commit" "fixture still dirty after reset"
  fi
  rm -rf "$fx"
else
  bad "e2e_make_fixture produced a fixture" "no path returned"
fi

echo "== E2E evidence capture (dry-run records argv + pre-state, no CLI) =="
# The capture lib records uniform before/after evidence. Offline, with a --dry-run invocation,
# it must record the resolved (masked) argv and the fixture's pre-run state without launching a CLI.
# shellcheck source=/dev/null  # dynamic absolute-path source, not followed by shellcheck
. "$ROOT/tests/e2e/lib/capture.sh"
cfx="$(e2e_make_fixture)"
cev="$(mktemp -d)/ev"
if [ -n "$cfx" ] && [ -d "$cfx" ]; then
  e2e_capture_pre "$cfx" "$cev"
  e2e_capture_argv "$RUN" codex --read-only "$cfx" "$cev" "look at the seed file"
  if [ -s "$cev/pre.sha" ]; then ok "capture records the pre-run fixture sha"; else bad "capture records the pre-run fixture sha" "no pre.sha"; fi
  if [ -f "$cev/pre.status" ] && [ ! -s "$cev/pre.status" ]; then ok "capture records a clean pre-run status"; else bad "capture records a clean pre-run status" "pre.status missing or non-empty"; fi
  argv_rec="$(cat "$cev/argv" 2>/dev/null)"
  assert_contains "capture records the resolved read-only argv (no CLI)" "$argv_rec" "codex exec -s read-only"
  assert_contains "captured argv masks the prompt" "$argv_rec" "<PROMPT>"
  case "$argv_rec" in *"look at the seed file"*) bad "captured argv carries no prompt text" "prompt leaked";; *) ok "captured argv carries no prompt text";; esac
  rm -rf "$cfx" "$cev"
else
  bad "e2e_make_fixture produced a fixture for capture" "no path"
fi

echo "== shellcheck (regression guard) =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT/scripts/run-agent.sh" "$ROOT/scripts/bump-version.sh" >/dev/null 2>&1; then
    ok "scripts/*.sh are shellcheck-clean"
  else
    bad "scripts/*.sh are shellcheck-clean" "run: shellcheck scripts/run-agent.sh scripts/bump-version.sh"
  fi
else
  printf '  skip shellcheck (not installed)\n'
fi

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

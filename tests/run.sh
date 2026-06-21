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
SKIP=0
# skip DESC — record a skipped block so the summary surfaces coverage that did not run.
skip() { SKIP=$((SKIP + 1)); printf '  skip %s\n' "$1"; }

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
# Includes mkdir + timeout so a full stub fan-out (which mkdir's $OUT/$INDEX_BASE and
# launches agents under timeout) also runs cleanly under the forced python3 backend — used
# by the JSON-emitter parity test below.
mk_restricted_bin() {
  mkdir -p "$1/bin"
  local t s
  for t in bash env python3 grep dirname basename cat sed sort tr cut wc paste date mktemp git head tail mkdir rm timeout; do
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

echo "== argv prompt placement: the prompt is a single verbatim argv element for EVERY agent =="
# The injection oracle below proves single-element placement only for codex. Generalize it to all four
# agents so a future argv_<name> regression that splits, duplicates, or drops the prompt (the prompt is
# set at PROMPT_IDX by each argv_<name> builder) is caught for agy/claude/cursor too. Recording stub per
# agent (named at its ADAPTER_BIN), real run (no --dry-run), assert the prompt appears EXACTLY once.
if command -v timeout >/dev/null 2>&1; then
  pp_prompt='benign multi word prompt ; echo x ; nomatch-*-glob'
  pp_check() {  # agent  binary
    local a="$1" bin="$2" d od tg rec n
    d="$(mktemp -d)"; od="$(mktemp -d)"; tg="$(mktemp -d)"; rec="$d/argv.txt"
    # shellcheck disable=SC2016  # the $@/$x below are the literal recording-stub body, not shell expansions here
    printf '#!/usr/bin/env bash\nfor x in "$@"; do printf "ARG=%%s\\n" "$x" >>"%s"; done\n' "$rec" >"$d/$bin"; chmod +x "$d/$bin"
    PATH="$d:$PATH" EXTERNAL_AGENTS_OUT="$od" bash "$RUN" --agent "$a" --read-only --effort medium --target "$tg" --prompt "$pp_prompt" >/dev/null 2>&1
    n="$(grep -cFx -- "ARG=$pp_prompt" "$rec" 2>/dev/null)"; [ -n "$n" ] || n=0
    if [ "$n" = "1" ]; then ok "argv placement: $a passes the prompt as exactly one verbatim argv element"
    else bad "argv placement: $a passes the prompt as exactly one verbatim argv element" "found $n matching argv element(s) (expected 1); argv: $(tr '\n' '|' <"$rec" 2>/dev/null)"; fi
    rm -rf "$d" "$od" "$tg"
  }
  pp_check agy agy
  pp_check codex codex
  pp_check claude claude
  pp_check cursor cursor-agent
else
  skip "argv prompt-placement oracle (timeout unavailable)"
fi

echo "== per-agent per-tier model resolution (dry-run resolved model == agents.json tier model) =="
# Pin tier->model resolution for EVERY agent x tier so a resolver regression (a wrong model for a tier)
# fails offline. The expectation is read DYNAMICALLY from agents.json so an intentional model bump
# updates both sides at once, not a brittle literal. agy high/xhigh carry a quota fallback, so force the
# quota CLI to fail and expect the Gemini 'fallback' deterministically.
if command -v jq >/dev/null 2>&1; then
  mr_check() {  # agent tier [env-assignment]
    local a="$1" t="$2" env="${3:-}" exp got
    exp="$(jq -r --arg a "$a" --arg t "$t" '.agents[$a].tiers[$t] | (.fallback // .model)' "$ROOT/agents.json")"
    got="$(env ${env:+$env} bash "$RUN" --agent "$a" --read-only --effort "$t" --dry-run --prompt x 2>/dev/null)"
    case "$got" in
      *"$exp"*) ok "model resolution: $a/$t resolves '$exp'";;
      *)        bad "model resolution: $a/$t resolves '$exp'" "resolved argv lacks the configured tier model";;
    esac
  }
  for t in low medium high xhigh; do
    mr_check codex  "$t"
    mr_check cursor "$t"
    mr_check claude "$t"   # disabled, but an explicit --agent claude still resolves its tier in dry-run
  done
  mr_check agy low; mr_check agy medium
  mr_check agy high  "EXTERNAL_AGENTS_AGY_QUOTA_CMD=false"
  mr_check agy xhigh "EXTERNAL_AGENTS_AGY_QUOTA_CMD=false"
else
  skip "per-tier model resolution (jq unavailable)"
fi

echo "== cloud API advisor agents (read-only; argv via scripts/api-client.py; no network) =="
# The api-kind agents (claude-api/openai/gemini/openrouter) are READ-ONLY cloud advisors driven by the
# bundled stdlib client. Pin their --dry-run argv shape + provider/model resolution, the all-api
# read-only auto-mode, write-mode argv invariance, --check/--discover presence, jq/python3 parity, and
# that a MISSING key is classified `auth` BEFORE any network call. Nothing here reaches the network.
dry "claude-api -> bundled client"              "scripts/api-client.py"                 -- --agent claude-api --read-only --effort high
dry "claude-api -> --provider anthropic"        "--provider anthropic"                  -- --agent claude-api --read-only --effort high
dry "claude-api high -> opus model + effort"    "--model claude-opus-4-8 --effort high" -- --agent claude-api --read-only --effort high
dry "openai -> --provider openai"               "--provider openai"                     -- --agent openai     --read-only --effort medium
dry "gemini -> --provider gemini (no effort)"   "--provider gemini --model gemini-3.1-pro --prompt" -- --agent gemini --read-only --effort high
dry "openrouter -> --provider openrouter slug"  "--provider openrouter --model anthropic/claude-sonnet-4-6" -- --agent openrouter --read-only --effort medium
# An API-only run with NO mode flag defaults to read-only (the write gates can't apply to an API call).
api_ro="$(bash "$RUN" --dry-run --agent claude-api --effort medium --prompt x 2>/dev/null)"
assert_contains "api-only run defaults to read-only mode" "$api_ro" "mode=readonly"
# An api agent's argv is mode-agnostic: identical under an explicit --write (still the read-only client).
api_wr="$(bash "$RUN" --dry-run --agent claude-api --write --effort high --prompt x 2>/dev/null)"
assert_contains "api agent argv is identical under --write" "$api_wr" "--provider anthropic --model claude-opus-4-8 --effort high"
# --discover scopes the tree-running live-smoke/e2e harnesses to CLIs, so api advisors are OMITTED from
# it (they have no filesystem access; a live call is a real API request). They stay visible via --check.
api_disc="$(bash "$RUN" --discover 2>/dev/null)"
for a in claude-api openai gemini openrouter; do
  if printf '%s\n' "$api_disc" | grep -q "^$a "; then bad "discover omits api advisor '$a'" "api agent appeared in --discover"; else ok "discover omits api advisor '$a'"; fi
done
if command -v python3 >/dev/null 2>&1; then
  # --check reports the api key SOURCE (info-only) and never decrypts (no `pass show`, no gpg prompt).
  api_chk="$(bash "$RUN" --check --agent claude-api 2>/dev/null || true)"
  assert_contains "check reports claude-api key env (info-only)" "$api_chk" "ANTHROPIC_API_KEY"
fi
# jq vs python3 config-backend parity for an api agent's resolved argv (force python3 via a jq-less PATH).
if command -v jq >/dev/null 2>&1; then
  apr="$(mktemp -d)"; mk_restricted_bin "$apr"
  for e in low medium high xhigh; do
    apj="$(bash "$RUN" --dry-run --agent claude-api --read-only --effort "$e" --prompt x 2>/dev/null | sed -nE 's/^  claude-api +//p')"
    app="$(PATH="$apr/bin" bash "$RUN" --dry-run --agent claude-api --read-only --effort "$e" --prompt x 2>/dev/null | sed -nE 's/^  claude-api +//p')"
    if [ -n "$apj" ] && [ "$apj" = "$app" ]; then ok "api parity: claude-api/$e (jq == python3)"; else bad "api parity: claude-api/$e" "jq=[$apj] py=[$app]"; fi
  done
  rm -rf "$apr"
else
  skip "api dry-run parity (jq unavailable — both backends would be python3)"
fi
# A missing-key api run fails at key resolution BEFORE any network call; the driver classifies the
# auth-shaped stderr as error_class=auth. Keys are unset + `pass` disabled so this is deterministic and
# offline even on a machine with real keys exported.
if command -v python3 >/dev/null 2>&1; then
  authtg="$(mktemp -d)"; authod="$(mktemp -d)"
  env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY -u OPENROUTER_API_KEY \
    EXTERNAL_AGENTS_NO_PASS=1 EXTERNAL_AGENTS_OUT="$authod" \
    bash "$RUN" --agent claude-api --read-only --effort medium --target "$authtg" --prompt 'x' >/dev/null 2>&1
  authec="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["error_class"])' "$authod/$(basename "$authtg")/claude-api.meta.json" 2>/dev/null)"
  assert_contains "api missing-key run classifies as auth (offline; no network)" "$authec" "auth"
  rm -rf "$authtg" "$authod"
else
  skip "api missing-key auth oracle (python3 unavailable)"
fi

echo "== api-client.py CLI exit-code contract (offline; no network) =="
# api-client.py's pre-network argument/key validation defines the exit codes run-agent.sh
# classify_outcome maps to error classes (4 -> auth, 5 -> transient, 3 -> unknown). The suite
# otherwise only checks the argv run-agent.sh BUILDS for an api agent — it never runs api-client.py
# itself — so pin those exit codes directly. Every case exits BEFORE any http_post (no network),
# and keys are unset + `pass` disabled so it is deterministic even with real keys exported.
if command -v python3 >/dev/null 2>&1; then
  AC="$ROOT/scripts/api-client.py"
  EXTERNAL_AGENTS_NO_PASS=1 python3 "$AC" --provider openai --model m --prompt '' >/dev/null 2>&1
  assert_exit "api-client.py: empty prompt -> exit 2" 2 "$?"
  EXTERNAL_AGENTS_NO_PASS=1 python3 "$AC" --provider openai --prompt hi >/dev/null 2>&1
  assert_exit "api-client.py: missing --model -> exit 2" 2 "$?"
  env -u OPENAI_API_KEY EXTERNAL_AGENTS_NO_PASS=1 python3 "$AC" --provider openai --model m --prompt hi >/dev/null 2>&1
  assert_exit "api-client.py: missing key -> exit 4 (auth, before any network call)" 4 "$?"
  python3 "$AC" --provider nope --model m --prompt hi >/dev/null 2>&1
  assert_exit "api-client.py: invalid --provider -> exit 2" 2 "$?"
else
  skip "api-client.py CLI exit-code contract (python3 unavailable)"
fi

echo "== api-client.py http_post HTTP-status -> exit-code mapping (offline; urlopen stubbed) =="
# http_post maps a provider's HTTP failure to the exit code that drives run-agent.sh's error taxonomy
# AND bounded-retry policy: 401/403 -> 4 (auth, NEVER retried), 429/>=500 -> 5 (transient, retryable),
# any other status -> 3 (unknown), and a URLError -> 5. Pin that status->class contract by loading the
# module and stubbing urllib.request.urlopen — no network is ever reached.
if command -v python3 >/dev/null 2>&1; then
  httpmap="$(python3 - "$ROOT/scripts/api-client.py" <<'PY'
import importlib.util, io, sys, urllib.error
spec = importlib.util.spec_from_file_location("apiclient", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def he(code): return urllib.error.HTTPError("https://x", code, "msg", {}, io.BytesIO(b"detail"))
cases = [
    ("http_post: HTTP 401 -> exit 4 (auth)",      he(401), 4),
    ("http_post: HTTP 403 -> exit 4 (auth)",      he(403), 4),
    ("http_post: HTTP 429 -> exit 5 (transient)", he(429), 5),
    ("http_post: HTTP 500 -> exit 5 (transient)", he(500), 5),
    ("http_post: HTTP 418 -> exit 3 (unknown)",   he(418), 3),
    ("http_post: URLError -> exit 5 (transient)", urllib.error.URLError("down"), 5),
]
for desc, exc, want in cases:
    m.urllib.request.urlopen = (lambda e: (lambda *a, **k: (_ for _ in ()).throw(e)))(exc)
    try:
        m.http_post("https://example.invalid", {"content-type": "application/json"}, {"x": 1}, 1)
        got = 0
    except SystemExit as e:
        got = e.code
    print(("PASS " if got == want else "FAIL ") + desc + ("" if got == want else " (got %r want %r)" % (got, want)))
PY
)"
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok "${line#PASS }";;
      "FAIL "*) bad "${line#FAIL }";;
    esac
  done <<< "$httpmap"
else
  skip "api-client.py http_post status->exit mapping (python3 unavailable)"
fi

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

echo "== enforcement-class doc-drift guard (registry ADAPTER_ENFORCEMENT == threat-model matrix) =="
# Phase 9.2 made the read-only enforcement class a registry field (ADAPTER_ENFORCEMENT). Tie it to the
# published matrix in docs/threat-model.md so the two cannot silently drift: for EVERY agent the
# registry's class must equal the matrix's enforcement column. Intentionally fails if they disagree.
ec_reg_line="$(grep -E '^declare -A ADAPTER_ENFORCEMENT=' "$ROOT/scripts/run-agent.sh" | head -1)"
ecdrift=""
# Derive the agent set from the registry line so a newly registered agent (e.g. an api advisor) is
# auto-covered here, not just by the bidirectional set-equality guard below.
ec_all="$(printf '%s' "$ec_reg_line" | grep -oE '\[[a-z][a-z0-9-]*\]=' | sed -E 's/\[([a-z0-9-]+)\]=/\1/')"
# shellcheck disable=SC2086 # ec_all is a whitespace-separated agent list; iterate each.
for a in $ec_all; do
  reg="$(printf '%s' "$ec_reg_line" | grep -oE "\[$a\]=\"[a-z-]+\"" | sed -E 's/.*="([a-z-]+)"/\1/')"
  mrow="$(grep -E "^\| ${a}[[:space:]]" "$ROOT/docs/threat-model.md" | head -1)"
  mcol="$(printf '%s' "$mrow" | awk -F'|' '{print $4}')"
  case "$mcol" in
    *best-effort*) mat="best-effort";;
    *enforced*)    mat="enforced";;
    *)             mat="?";;
  esac
  if [ -z "$reg" ] || [ "$reg" != "$mat" ]; then ecdrift="$ecdrift $a(reg=$reg,matrix=$mat)"; fi
done
if [ -z "$ecdrift" ]; then
  ok "enforcement drift: registry enforcement classes match the threat-model matrix"
else
  bad "enforcement drift: registry enforcement classes match the threat-model matrix" "mismatch:$ecdrift"
fi

echo "== enforcement-matrix bidirectional coverage (registry agent set == matrix agent set) =="
# The per-agent drift guard above checks each KNOWN agent's class but iterates a fixed list, so a
# newly registered agent with no matrix row, or an orphan matrix row for a non-existent agent, would
# slip past it. Derive BOTH sets dynamically and assert they are equal so neither side can over-claim:
# every ADAPTER_ENFORCEMENT key must have exactly one matrix row and every matrix row must be a
# declared agent. Intentionally fails red on either a missing row or an orphan row.
reg_agents="$(printf '%s' "$ec_reg_line" | grep -oE '\[[a-z][a-z0-9-]*\]=' | sed -E 's/\[([a-z0-9-]+)\]=/\1/' | sort -u)"
mat_agents="$(awk '
  /^## Per-CLI read-only enforcement matrix/ {insec=1; next}
  insec && /^## / {insec=0}
  insec && /^\|/ {
    split($0, c, "|"); a=c[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", a);
    if (a ~ /^[a-z][a-z0-9-]*$/ && a != "agent") print a
  }' "$ROOT/docs/threat-model.md" | sort -u)"
if [ -n "$reg_agents" ] && [ "$reg_agents" = "$mat_agents" ]; then
  ok "enforcement bidirectional: registry agent set == threat-model matrix agent set"
else
  reg_one="$(printf '%s' "$reg_agents" | tr '\n' ' ')"
  mat_one="$(printf '%s' "$mat_agents" | tr '\n' ' ')"
  bad "enforcement bidirectional: registry agent set == threat-model matrix agent set" "reg=[$reg_one] matrix=[$mat_one]"
fi

echo "== agent-inventory doc-drift guard (README agent set == agents.json) =="
# The user-facing README must document exactly the configured agent inventory. The headline dispatch
# badge enumerates the agent set; pin it (and the prose) to agents.json keys so a README that omits a
# configured agent, or names a removed/renamed one, fails offline — drift no enforcement guard catches
# (those pin registry<->threat-model, never README). Intentionally fails red on either side's drift.
inv_json="$(jq -r '.agents | keys[]' "$ROOT/agents.json" 2>/dev/null | sort -u)"
badge_raw="$(grep -oE 'badge/dispatch-[^)]*\.svg' "$ROOT/README.md" | head -1)"
badge_agents="$(printf '%s' "$badge_raw" | sed -E 's#badge/dispatch-##; s#-[0-9A-Fa-f]{6}\.svg$##' | sed 's/%20%C2%B7%20/\n/g' | sed 's/--/-/g' | sort -u)"
if [ -n "$inv_json" ] && [ "$inv_json" = "$badge_agents" ]; then
  ok "agent-inventory: README dispatch badge names exactly the agents.json agent set"
else
  ij="$(printf '%s' "$inv_json" | tr '\n' ' ')"; ba="$(printf '%s' "$badge_agents" | tr '\n' ' ')"
  bad "agent-inventory: README dispatch badge names exactly the agents.json agent set" "agents.json=[$ij] badge=[$ba]"
fi
for a in $inv_json; do
  if grep -qw -- "$a" "$ROOT/README.md"; then ok "agent-inventory: README documents configured agent '$a'"
  else bad "agent-inventory: README documents configured agent '$a'" "configured in agents.json but absent from README"; fi
done

echo "== extensibility-doc consistency guard (docs/extensibility.md vs registry symbols) =="
# The add-an-agent walkthrough must reference the REAL registry symbols (a renamed/removed symbol must
# not leave a stale walkthrough) and frame the registry-only claim as offline-proven (fixture-agent
# oracle), never live-verified. No enforcement guard pins this doc to the driver.
EX="$ROOT/docs/extensibility.md"
ex_sym_ok=1
if ! { grep -qE '^ADAPTER_AGENTS=\(' "$ROOT/scripts/run-agent.sh" && grep -qF 'ADAPTER_AGENTS' "$EX"; }; then ex_sym_ok=0; fi
for sym in ADAPTER_BIN ADAPTER_ENFORCEMENT; do
  if ! { grep -qE "^declare -A $sym=\(" "$ROOT/scripts/run-agent.sh" && grep -qF "$sym" "$EX"; }; then ex_sym_ok=0; fi
done
if ! { grep -qE '^argv_cursor\(\)' "$ROOT/scripts/run-agent.sh" && grep -qE 'argv_<agent>|argv_cursor' "$EX"; }; then ex_sym_ok=0; fi
if [ "$ex_sym_ok" = 1 ]; then
  ok "extensibility-doc: walkthrough references the real registry symbols (ADAPTER_*/argv_<agent>)"
else
  bad "extensibility-doc: walkthrough references the real registry symbols (ADAPTER_*/argv_<agent>)" "doc/registry symbol drift"
fi
if grep -qiE 'offline|fixture-agent|policy-decoupling' "$EX" && ! grep -qi 'live-verified' "$EX"; then
  ok "extensibility-doc: registry-only claim is offline-proven, not live-verified"
else
  bad "extensibility-doc: registry-only claim is offline-proven, not live-verified" "doc over-claims live verification"
fi

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
  skip "jq/python3 parity (could not run both backends in this environment)"
fi

echo "== per-agent jq/python3 dry-run parity (model/effort/fallback ops under both backends) =="
# Parity gate: every cfg op must produce byte-identical output across the jq and python3 backends;
# when a query type changes, update both backends in run-agent.sh and these parity blocks together.
pdir="$(mktemp -d)"; mk_restricted_bin "$pdir"
parity_dry() {  # agent  effort  [extra env assignment]
  local a="$1" e="$2" env="${3:-}" oj op
  # Without jq the ambient-PATH "jq" backend silently falls back to python3, making the parity vacuous
  # (both sides python3). Skip rather than report a false pass — mirroring the other parity blocks.
  command -v jq >/dev/null 2>&1 || { skip "dry-run parity: $a $e (jq unavailable — both backends would be python3)"; return; }
  oj="$(env ${env:+$env} bash "$RUN" --agent "$a" --read-only --effort "$e" --dry-run --prompt p 2>/dev/null)"
  op="$(env ${env:+$env} PATH="$pdir/bin" "$pdir/bin/bash" "$RUN" --agent "$a" --read-only --effort "$e" --dry-run --prompt p 2>/dev/null)"
  if [ -z "$oj" ] || [ -z "$op" ]; then skip "$a/$e parity (a backend unavailable)"; return; fi
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

echo "== registry-argv parity (agent × {read-only, write} × {jq, python3}; Phase 9.2 byte-identical) =="
# The Phase 9.2 registry refactor must produce byte-identical --dry-run argv across the jq and python3
# config backends for EVERY agent in BOTH modes — the regression contract that lets the adapter
# boundary move safely. (The per-agent parity block above covers read-only × tiers; this adds the
# WRITE mode for all four agents.) Stub PATH + dual backend, no live CLI. --model fixes the model (and
# skips agy's quota check); a temp target + --yes clear the write-mode gates.
rapd="$(mktemp -d)"; mk_restricted_bin "$rapd"   # python3, NO jq -> forces JSON_BACKEND=py
ratgt="$(mktemp -d)"
ra_parity() {  # agent  modeflag
  local a="$1" mf="$2" oj op
  # Without jq the ambient-PATH backend is python3 too, making the byte-identity check vacuous; skip
  # rather than report a false pass (the restricted backend below already forces python3).
  command -v jq >/dev/null 2>&1 || { skip "registry-argv $a $mf parity (jq unavailable — both backends would be python3)"; return; }
  oj="$(bash "$RUN" --agent "$a" "$mf" --yes --effort high --model TESTMODEL --target "$ratgt" --dry-run --prompt p 2>/dev/null)"
  op="$(PATH="$rapd/bin" "$rapd/bin/bash" "$RUN" --agent "$a" "$mf" --yes --effort high --model TESTMODEL --target "$ratgt" --dry-run --prompt p 2>/dev/null)"
  if [ -z "$oj" ] || [ -z "$op" ]; then skip "registry-argv $a $mf parity (a backend produced no argv)"; return; fi
  if [ "$oj" = "$op" ]; then ok "registry-argv parity: $a $mf (jq == python3)"; else bad "registry-argv parity: $a $mf" "jq=[$oj] py=[$op]"; fi
}
for a in agy codex claude cursor; do
  ra_parity "$a" "--read-only"
  ra_parity "$a" "--write"
done
rm -rf "$rapd" "$ratgt"

# make_fixture_driver DIR — write a COPY of the driver into DIR/run-agent.sh with a fixture agent
# added ONLY via the registry boundary (ADAPTER_AGENTS/BIN/ENFORCEMENT + a thin argv_fixture builder)
# — the exact, localized two-edit add (no policy code touched) — plus DIR/agents.json (--conf). Shared
# by the Phase 9.3 fixture oracles below. fixbin is the fixture's CLI; tier medium -> model fix-mid.
make_fixture_driver() {
  local d="$1"
  python3 - "$RUN" "$d/run-agent.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace("ADAPTER_AGENTS=(agy codex claude cursor claude-api openai gemini openrouter)", "ADAPTER_AGENTS=(agy codex claude cursor claude-api openai gemini openrouter fixture)")
src = src.replace('[openrouter]="python3" )', '[openrouter]="python3" [fixture]="fixbin" )')
src = src.replace('[openrouter]="enforced" )', '[openrouter]="enforced" [fixture]="enforced" )')
builder = (
    'argv_fixture() {\n'
    '  local m="$1"\n'
    '  if [ "$MODE" = "readonly" ]; then ARGV=(fixbin --plan -C "$TARGET"); else ARGV=(fixbin --apply -C "$TARGET"); fi\n'
    '  [ -n "$m" ] && ARGV+=(--model "$m")\n'
    '  ARGV+=(-- "$PROMPT"); PROMPT_IDX=$(( ${#ARGV[@]} - 1 ))\n'
    '}\n'
)
marker = "# --- build one agent's argv"
src = src.replace(marker, builder + marker, 1)
open(sys.argv[2], "w").write(src)
PY
  cat >"$d/agents.json" <<'JSON'
{ "default_tier": "medium",
  "agents": { "fixture": { "enabled": true, "tiers": {
    "low": { "model": "fix-small" }, "medium": { "model": "fix-mid" },
    "high": { "model": "fix-big" }, "xhigh": { "model": "fix-max" } } } } }
JSON
}

echo "== fixture-agent extensibility oracle (registry entry + agents.json, no policy edits; both backends) =="
# Phase 9's signal: an agent added ONLY via a registry entry + an agents.json block (no policy edits)
# resolves its tier, builds correct read-only/write argv, and is reported present by --check/--discover.
if command -v python3 >/dev/null 2>&1; then
  fxd="$(mktemp -d)"; make_fixture_driver "$fxd"
  fxrestr="$(mktemp -d)"; mk_restricted_bin "$fxrestr"   # python3, NO jq -> forces the python3 backend
  fx_check() {  # label bashbin pathprefix
    local lbl="$1" bb="$2" pp="$3" stub wtgt ro wr disc chk
    stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho fix\n' >"$stub/fixbin"; chmod +x "$stub/fixbin"
    wtgt="$(mktemp -d)"
    ro="$(PATH="$stub:$pp" "$bb" "$fxd/run-agent.sh" --conf "$fxd/agents.json" --agent fixture --read-only --dry-run --prompt x 2>/dev/null)"
    wr="$(PATH="$stub:$pp" "$bb" "$fxd/run-agent.sh" --conf "$fxd/agents.json" --agent fixture --write --yes --target "$wtgt" --dry-run --prompt x 2>/dev/null)"
    disc="$(PATH="$stub:$pp" "$bb" "$fxd/run-agent.sh" --conf "$fxd/agents.json" --discover 2>/dev/null)"
    chk="$(PATH="$stub:$pp" "$bb" "$fxd/run-agent.sh" --conf "$fxd/agents.json" --agent fixture --check 2>/dev/null)"
    rm -rf "$stub" "$wtgt"
    assert_contains "fixture[$lbl]: read-only argv shape (--plan)"           "$ro"   "fixbin --plan -C"
    assert_contains "fixture[$lbl]: read-only resolves the medium-tier model" "$ro"   "fix-mid"
    assert_contains "fixture[$lbl]: write argv shape (--apply)"               "$wr"   "fixbin --apply -C"
    assert_contains "fixture[$lbl]: --discover reports it present"            "$disc" "fixture present"
    assert_contains "fixture[$lbl]: --check reports it present"               "$chk"  "ok   fixture"
  }
  fx_check jq "bash" "$PATH"
  fx_check py "$fxrestr/bin/bash" "$fxrestr/bin"
  rm -rf "$fxrestr" "$fxd"
else
  skip "fixture-agent extensibility oracle (python3 unavailable)"
fi

echo "== fixture-agent record/index/argv artifacts (agent-agnostic emitters; no emitter change) =="
# Prove the record/index/argv emitters are agent-agnostic: the fixture agent's REAL stub run emits
# fixture.meta.json (standard fields), an index.jsonl row, and a masked fixture.argv byte-identical to
# its --dry-run argv — none of which the emitters know about "fixture". Reuses make_fixture_driver.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  nad="$(mktemp -d)"; make_fixture_driver "$nad"
  nastub="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho "fixture stub output"\n' >"$nastub/fixbin"; chmod +x "$nastub/fixbin"
  natgt="$(mktemp -d)"; naod="$(mktemp -d)"
  na_dry="$(PATH="$nastub:$PATH" bash "$nad/run-agent.sh" --conf "$nad/agents.json" --agent fixture --read-only --target "$natgt" --dry-run --prompt x 2>/dev/null | sed -nE 's/^  fixture +//p')"
  PATH="$nastub:$PATH" EXTERNAL_AGENTS_OUT="$naod" bash "$nad/run-agent.sh" --conf "$nad/agents.json" --agent fixture --read-only --target "$natgt" --prompt x >/dev/null 2>&1
  naproj="$naod/$(basename "$natgt")"
  if [ -f "$naproj/fixture.meta.json" ]; then
    nam="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
req = {"agent","model","tier","effort","mode","target","rc","sec","bytes","fallback","timestamp","error_class","signals"}
print("OK" if (req <= set(d) and d["agent"] == "fixture" and d["model"] == "fix-mid" and d["mode"] == "readonly") else "BAD %s" % d)
' "$naproj/fixture.meta.json" 2>/dev/null)"
    assert_contains "new-agent: fixture.meta.json emitted with standard fields + agent=fixture" "$nam" "OK"
  else
    bad "new-agent: fixture.meta.json emitted with standard fields + agent=fixture" "no meta.json for the fixture agent"
  fi
  if [ -f "$naod/index.jsonl" ] && grep -q '"agent":"fixture"' "$naod/index.jsonl"; then
    ok "new-agent: index.jsonl row emitted for the fixture agent"
  else
    bad "new-agent: index.jsonl row emitted for the fixture agent" "no fixture row in index.jsonl"
  fi
  na_live="$(cat "$naproj/fixture.argv" 2>/dev/null)"
  if [ -n "$na_live" ] && [ "$na_live" = "$na_dry" ]; then
    ok "new-agent: masked fixture.argv == --dry-run argv"
  else
    bad "new-agent: masked fixture.argv == --dry-run argv" "live=[$na_live] dry=[$na_dry]"
  fi
  case "$na_live" in *"<PROMPT>"*) ok "new-agent: fixture.argv masks the prompt";; *) bad "new-agent: fixture.argv masks the prompt" "no <PROMPT> placeholder";; esac
  rm -rf "$nad" "$nastub" "$natgt" "$naod"
else
  skip "fixture-agent record/index/argv oracle (timeout/python3 unavailable)"
fi

echo "== policy-decoupling guard (generic policy functions are agent-agnostic; registry is authoritative) =="
# The registry (ADAPTER_AGENTS/BIN/ENFORCEMENT) is the single authoritative agent set. The GENERIC
# policy functions — the dispatcher, the agy quota helper, redaction, and the record emitters — must
# NOT hard-code the four agent names, or a registry-declared agent would be silently excluded. (The
# per-agent argv builders and extract_signal's signal-capability hook are intentionally per-agent.)
# The guard fails if any of these functions regains a four-agent literal.
pd_src="$ROOT/scripts/run-agent.sh"
pd_body() { awk -v fn="$1() {" 'index($0,fn)==1{f=1} f{print} f&&/^}/{exit}' "$pd_src"; }
pd_bad=""
for fn in build_argv agy_model_status redact write_meta_json append_index_row; do
  if pd_body "$fn" | grep -qE 'agy\|codex\|claude\|cursor|\(agy codex claude cursor'; then
    pd_bad="$pd_bad $fn"
  fi
done
if [ -z "$pd_bad" ]; then
  ok "policy-decoupling: dispatcher / quota / redaction / record emitters are agent-agnostic"
else
  bad "policy-decoupling: generic policy functions are agent-agnostic" "four-agent literal in:$pd_bad"
fi
# The agent-set array literal lives in exactly ONE place — the ADAPTER_AGENTS registry declaration.
pd_reg="$(grep -cE '^ADAPTER_AGENTS=\(agy codex claude cursor claude-api openai gemini openrouter\)' "$pd_src")"
if [ "$pd_reg" = "1" ]; then
  ok "policy-decoupling: the agent-set array literal lives once, in the ADAPTER_AGENTS registry"
else
  bad "policy-decoupling: the agent-set array literal lives once, in the ADAPTER_AGENTS registry" "ADAPTER_AGENTS count: $pd_reg"
fi

echo "== pipeline per-stage safety + artifacts (gates enforced every stage; argv == dry-run; redaction) =="
# run-pipeline.sh invokes the FULL driver per stage, so every stage independently enforces the
# containment / non-cwd --yes gates, redaction, and the per-run records — the pipeline is never a back
# door. Prove it: (a) a write pipeline to a non-cwd target WITHOUT --yes is refused at stage 1; (b) each
# stage's masked argv == its --dry-run argv; (c) a secret a stage emits is redacted in its artifact AND
# in the seed to the next stage.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  PIPE="$ROOT/scripts/run-pipeline.sh"
  psstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "codex-out"\n'  >"$psstub/codex";  chmod +x "$psstub/codex"
  printf '#!/usr/bin/env bash\necho "claude-out"\n' >"$psstub/claude"; chmod +x "$psstub/claude"
  pstgt="$(mktemp -d)"
  # (a) the non-cwd --yes gate is enforced at the pipeline stage: write to a non-cwd target WITHOUT --yes.
  psbase="$(mktemp -d)"
  psout="$(PATH="$psstub:$PATH" EXTERNAL_AGENTS_OUT="$psbase" bash "$PIPE" --pipeline codex,claude --prompt p --write --target "$pstgt" 2>&1)"
  assert_contains "pipeline: non-cwd write WITHOUT --yes refused at stage 1 (gate enforced per stage)" "$psout" "completed-through-stage 0"
  rm -rf "$psbase"
  # (b) with --yes the pipeline proceeds; each stage records meta/argv and the masked argv == its dry-run argv.
  psbase="$(mktemp -d)"
  PATH="$psstub:$PATH" EXTERNAL_AGENTS_OUT="$psbase" bash "$PIPE" --pipeline codex,claude --prompt p --write --yes --target "$pstgt" >/dev/null 2>&1
  pspd="$(find "$psbase" -maxdepth 1 -type d -name 'pipeline-*' | head -1)"
  ps_ok=1
  for s in 1-codex 2-claude; do
    psa="${s#*-}"
    { [ -f "$pspd/$s/$psa.meta.json" ] && [ -f "$pspd/$s/$psa.argv" ]; } || ps_ok=0
    pslive="$(cat "$pspd/$s/$psa.argv" 2>/dev/null)"
    psdry="$(PATH="$psstub:$PATH" bash "$RUN" --agent "$psa" --write --yes --target "$pstgt" --dry-run --prompt p 2>/dev/null | sed -nE "s/^  ${psa} +//p")"
    { [ -n "$pslive" ] && [ "$pslive" = "$psdry" ]; } || ps_ok=0
  done
  if [ "$ps_ok" = "1" ]; then
    ok "pipeline: each stage records meta/argv and masked argv == its --dry-run argv"
  else
    bad "pipeline: each stage records meta/argv and masked argv == its --dry-run argv" "stage record/argv mismatch"
  fi
  rm -rf "$psbase"
  # (c) redaction per stage: a stage that emits a secret has it masked in its artifact AND in the seed.
  rdstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "leak sk-AAAAAAAAAAAAAAAAAAAAAAAA"\n' >"$rdstub/codex"; chmod +x "$rdstub/codex"
  printf '#!/usr/bin/env bash\necho "S2:$*"\n' >"$rdstub/claude"; chmod +x "$rdstub/claude"
  rdbase="$(mktemp -d)"
  PATH="$rdstub:$PATH" EXTERNAL_AGENTS_OUT="$rdbase" bash "$PIPE" --pipeline codex,claude --prompt p --read-only --target "$pstgt" >/dev/null 2>&1
  rdpd="$(find "$rdbase" -maxdepth 1 -type d -name 'pipeline-*' | head -1)"
  s1md="$(cat "$rdpd/1-codex/codex.md" 2>/dev/null)"
  s2md="$(cat "$rdpd/2-claude/claude.md" 2>/dev/null)"
  case "$s1md" in *"<REDACTED>"*) ok "pipeline: stage 1 secret masked in its artifact";; *) bad "pipeline: stage 1 secret masked in its artifact" "no <REDACTED> in stage 1 .md";; esac
  case "$s1md" in *"sk-AAAAAAAA"*) bad "pipeline: stage 1 raw secret not persisted" "raw secret leaked in stage 1 .md";; *) ok "pipeline: stage 1 raw secret not persisted";; esac
  case "$s2md" in *"sk-AAAAAAAA"*) bad "pipeline: stage 2 seed carries no raw secret (seeded from redacted)" "raw secret reached stage 2";; *) ok "pipeline: stage 2 seed carries no raw secret (seeded from redacted)";; esac
  rm -rf "$rdstub" "$rdbase" "$psstub" "$pstgt"
else
  skip "pipeline per-stage safety oracle (timeout/python3 unavailable)"
fi

echo "== stub-driven pipeline oracle (ordered dispatch + redacted-output seeding; both backends) =="
# An N-stage pipeline of stub agents: assert (1) ordered dispatch (stage 1..N in the specified order),
# (2) stage N+1's prompt is seeded from stage N's REDACTED artifact (the next stub echoes the prior
# stage's marker), and (3) each stage records its artifacts — under jq AND a python3-only PATH.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  PIPE="$ROOT/scripts/run-pipeline.sh"
  plrestr="$(mktemp -d)"; mk_restricted_bin "$plrestr"   # python3, NO jq -> forces JSON_BACKEND=py
  pl_check() {  # label  bashbin  pathprefix
    local lbl="$1" bb="$2" pp="$3" stub base tgt pd out order recs a s
    stub="$(mktemp -d)"
    printf '#!/usr/bin/env bash\necho "CODEX_MARK $*"\n'  >"$stub/codex";        chmod +x "$stub/codex"
    printf '#!/usr/bin/env bash\necho "CLAUDE_MARK $*"\n' >"$stub/claude";       chmod +x "$stub/claude"
    printf '#!/usr/bin/env bash\necho "CURSOR_MARK $*"\n' >"$stub/cursor-agent"; chmod +x "$stub/cursor-agent"
    base="$(mktemp -d)"; tgt="$(mktemp -d)"
    out="$(PATH="$stub:$pp" EXTERNAL_AGENTS_OUT="$base" "$bb" "$PIPE" --pipeline codex,claude,cursor --prompt BASEP --read-only --target "$tgt" 2>&1)"
    pd="$(find "$base" -maxdepth 1 -type d -name 'pipeline-*' | head -1)"
    order="$(printf '%s\n' "$out" | grep -oE 'stage [0-9]+/3 (codex|claude|cursor)' | paste -sd',' -)"
    assert_contains "pipeline[$lbl]: ordered dispatch (codex->claude->cursor)" "$order" "stage 1/3 codex,stage 2/3 claude,stage 3/3 cursor"
    assert_contains "pipeline[$lbl]: stage 2 seeded from stage 1's redacted artifact" "$(cat "$pd/2-claude/claude.md" 2>/dev/null)" "CODEX_MARK"
    assert_contains "pipeline[$lbl]: stage 3 seeded from stage 2's redacted artifact" "$(cat "$pd/3-cursor/cursor.md" 2>/dev/null)" "CLAUDE_MARK"
    recs=0
    for s in 1-codex 2-claude 3-cursor; do
      a="${s#*-}"
      { [ -f "$pd/$s/$a.meta.json" ] && [ -f "$pd/$s/$a.argv" ] && [ -f "$pd/$s/$a.md" ]; } && recs=$((recs + 1))
    done
    assert_exit "pipeline[$lbl]: all 3 stages recorded meta/argv/md" 3 "$recs"
    rm -rf "$stub" "$base" "$tgt"
  }
  pl_check jq "bash" "$PATH"
  pl_check py "$plrestr/bin/bash" "$plrestr/bin"
  rm -rf "$plrestr"
else
  skip "stub-driven pipeline oracle (timeout/python3 unavailable)"
fi

echo "== pipeline edge oracles (--continue completed-through-K, empty-token skip, same-agent ordering) =="
# The pipeline oracle above covers the happy path. Pin three edges of scripts/run-pipeline.sh:
# (a) a mid-pipeline failure STOPS without --continue but RUNS every stage with --continue, and the
# completed-through-K verdict counts only the ok stages; (b) an empty/whitespace stage token (a,,b) is
# skipped (run-pipeline.sh:52); (c) the same agent twice runs as two ordered stages. Stub-driven, CLI-free.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  pe_stub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n'  >"$pe_stub/codex";        chmod +x "$pe_stub/codex"        # fails -> ec unknown
  printf '#!/usr/bin/env bash\necho ok\n' >"$pe_stub/claude";       chmod +x "$pe_stub/claude"       # ok
  printf '#!/usr/bin/env bash\necho ok\n' >"$pe_stub/cursor-agent"; chmod +x "$pe_stub/cursor-agent" # ok (cursor)
  pe_run() {  # args... -> pipeline stdout (fixed prompt/mode/target appended)
    local tg ob; tg="$(mktemp -d)"; ob="$(mktemp -d)"
    PATH="$pe_stub:$PATH" EXTERNAL_AGENTS_OUT="$ob" bash "$ROOT/scripts/run-pipeline.sh" "$@" --prompt p --read-only --target "$tg" 2>&1
    rm -rf "$tg" "$ob"
  }
  # (a) failure-then-success: stop without --continue; run-through with --continue (K counts ok only)
  pe_stop="$(pe_run --pipeline codex,claude)"
  assert_contains "pipeline edge: stops at the first failed stage without --continue" "$pe_stop" "stopping at stage 1"
  assert_contains "pipeline edge: completed-through 0/2 when stage 1 fails (no --continue)" "$pe_stop" "completed-through-stage 0/2"
  pe_cont="$(pe_run --continue --pipeline codex,claude)"
  case "$pe_cont" in *"stopping at stage"*) bad "pipeline edge: --continue runs past a failed stage" "stopped despite --continue";; *) ok "pipeline edge: --continue runs past a failed stage (no stop)";; esac
  assert_contains "pipeline edge: --continue completed-through 1/2 (only the ok stage counts)" "$pe_cont" "completed-through-stage 1/2"
  # (b) empty/whitespace token skipped (claude,,cursor -> two stages, empty dropped)
  pe_empty="$(pe_run --pipeline claude,,cursor)"
  assert_contains "pipeline edge: empty token skipped -> stage 1 claude" "$pe_empty" "stage 1/3 claude"
  assert_contains "pipeline edge: empty token skipped -> stage 2 cursor" "$pe_empty" "stage 2/3 cursor"
  assert_contains "pipeline edge: empty token skipped -> both ok stages counted (2/3)" "$pe_empty" "completed-through-stage 2/3"
  # (c) same agent twice -> two ordered stages
  pe_twice="$(pe_run --pipeline claude,claude)"
  assert_contains "pipeline edge: same agent twice -> stage 1/2 claude" "$pe_twice" "stage 1/2 claude"
  assert_contains "pipeline edge: same agent twice -> stage 2/2 claude" "$pe_twice" "stage 2/2 claude"
  rm -rf "$pe_stub"
else
  skip "pipeline edge oracles (timeout/python3 unavailable)"
fi

echo "== pipeline outcome summary is content-free (control-plane facts only, no transcript text) =="
# The deterministic pipeline outcome summary (per-stage agent/class/rc/sec/bytes + completed-through-
# stage-K) must carry control-plane facts ONLY — never transcript text, mirroring the fan-out summary.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  posstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "PIPE_TRANSCRIPT_LEAK_MARKER body"\n' >"$posstub/codex";  chmod +x "$posstub/codex"
  printf '#!/usr/bin/env bash\necho "PIPE_TRANSCRIPT_LEAK_MARKER body"\n' >"$posstub/claude"; chmod +x "$posstub/claude"
  posbase="$(mktemp -d)"; postgt="$(mktemp -d)"
  posout="$(PATH="$posstub:$PATH" EXTERNAL_AGENTS_OUT="$posbase" bash "$ROOT/scripts/run-pipeline.sh" --pipeline codex,claude --prompt p --read-only --target "$postgt" 2>&1)"
  rm -rf "$posstub" "$posbase" "$postgt"
  assert_contains "pipeline summary: per-stage control-plane facts present"        "$posout" "class=ok rc=0 sec="
  assert_contains "pipeline summary: deterministic completed-through-stage verdict" "$posout" "completed-through-stage 2/2"
  case "$posout" in
    *PIPE_TRANSCRIPT_LEAK_MARKER*) bad "pipeline summary: carries NO transcript text" "a transcript marker leaked into the pipeline output";;
    *)                             ok  "pipeline summary: carries NO transcript text";;
  esac
else
  skip "pipeline outcome summary content-free oracle (timeout/python3 unavailable)"
fi

echo "== pipeline --summary-json: additive machine-readable outcome (control-plane only, not forwarded) =="
# --summary-json adds ONE final JSON line of per-stage control-plane facts (stage/agent/class/rc/sec/
# bytes) + completed_through/total/rc — never transcript text — and is INTERCEPTED at the pipeline level
# (NOT forwarded to the per-stage run-agent, which would reject an unknown flag and fail every stage).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  sjstub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "PIPE_TRANSCRIPT_LEAK_MARKER body"\n' >"$sjstub/codex";  chmod +x "$sjstub/codex"
  printf '#!/usr/bin/env bash\necho "PIPE_TRANSCRIPT_LEAK_MARKER body"\n' >"$sjstub/claude"; chmod +x "$sjstub/claude"
  sjbase="$(mktemp -d)"; sjtgt="$(mktemp -d)"
  sj_run() {  # run_id args... -> pipeline stdout (fixed pipeline/prompt/mode/target appended)
    local rid="$1"; shift
    PATH="$sjstub:$PATH" EXTERNAL_AGENTS_RUN_ID="$rid" EXTERNAL_AGENTS_OUT="$sjbase" \
      bash "$ROOT/scripts/run-pipeline.sh" "$@" --pipeline codex,claude --prompt p --read-only --target "$sjtgt" 2>&1
  }
  sj_out="$(sj_run sj1 --summary-json)"
  sj_json="$(printf '%s\n' "$sj_out" | tail -1)"
  sj_shape="$(printf '%s' "$sj_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("BADJSON", e); raise SystemExit
need = {"run_id", "out", "total", "completed_through", "rc", "stages"}
st = d.get("stages", [])
ok = (need <= set(d) and isinstance(st, list) and len(st) == 2
      and d["total"] == 2 and d["completed_through"] == 2
      and all({"stage", "agent", "class", "rc", "sec", "bytes"} <= set(s) for s in st)
      and st[0]["agent"] == "codex" and st[0]["stage"] == 1 and st[0]["class"] == "ok"
      and st[1]["agent"] == "claude" and st[1]["stage"] == 2)
print("OK" if ok else "FAIL " + json.dumps(d))' 2>&1)"
  assert_contains "pipeline --summary-json: well-formed doc with per-stage control-plane rows" "$sj_shape" "OK"
  case "$sj_json" in
    *PIPE_TRANSCRIPT_LEAK_MARKER*) bad "pipeline --summary-json: carries NO transcript text" "transcript marker leaked into the JSON";;
    *)                             ok  "pipeline --summary-json: carries NO transcript text";;
  esac
  assert_contains "pipeline --summary-json: not forwarded to stages (both ran ok, 2/2)" "$sj_out" "completed-through-stage 2/2"
  # Additive: without the flag the last line is the human verdict, never a JSON object.
  sj_plain="$(sj_run sj2 | tail -1)"
  case "$sj_plain" in
    '{'*) bad "pipeline --summary-json: absent without the flag (additive)" "a JSON line appeared without --summary-json";;
    *)    ok  "pipeline --summary-json: absent without the flag (additive)";;
  esac
  rm -rf "$sjstub" "$sjbase" "$sjtgt"
else
  skip "pipeline --summary-json oracle (timeout/python3 unavailable)"
fi

echo "== stub-driven consensus oracle (representative panels; deterministic; both backends) =="
# Run stub panels with controlled per-agent exit codes (pinned to an exact agent set via --conf, so
# no live CLI can join) and assert the deterministic consensus verdict for each — all-agree, majority,
# minority, all-fail, and an even-panel tie — under jq AND a python3-only PATH.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  cnrestr="$(mktemp -d)"; mk_restricted_bin "$cnrestr"   # python3, NO jq -> forces JSON_BACKEND=py
  cn3conf="$(mktemp)"; printf '%s' '{"default_tier":"medium","agents":{"codex":{"enabled":true,"tiers":{"medium":{"model":"m"}}},"agy":{"enabled":true,"tiers":{"medium":{"model":"m"}}},"cursor":{"enabled":true,"tiers":{"medium":{"model":"m"}}}}}' >"$cn3conf"
  cn2conf="$(mktemp)"; printf '%s' '{"default_tier":"medium","agents":{"codex":{"enabled":true,"tiers":{"medium":{"model":"m"}}},"agy":{"enabled":true,"tiers":{"medium":{"model":"m"}}}}}' >"$cn2conf"
  cn_verdict() {  # bashbin pathprefix conf codex_rc agy_rc [cursor_rc] -> the consensus verdict word
    local bb="$1" pp="$2" cf="$3" rc_c="$4" rc_a="$5" rc_u="${6:-}" sd tg out v
    sd="$(mktemp -d)"; tg="$(mktemp -d)"; out="$(mktemp -d)"
    printf '#!/usr/bin/env bash\necho ok\nexit %s\n' "$rc_c" >"$sd/codex"; chmod +x "$sd/codex"
    printf '#!/usr/bin/env bash\necho ok\nexit %s\n' "$rc_a" >"$sd/agy";   chmod +x "$sd/agy"
    [ -n "$rc_u" ] && { printf '#!/usr/bin/env bash\necho ok\nexit %s\n' "$rc_u" >"$sd/cursor-agent"; chmod +x "$sd/cursor-agent"; }
    v="$(PATH="$sd:$pp" EXTERNAL_AGENTS_OUT="$out" EXTERNAL_AGENTS_AGY_QUOTA_CMD=false "$bb" "$RUN" --agent all --read-only --consensus --conf "$cf" --target "$tg" --prompt x 2>/dev/null | sed -nE 's/.*consensus: ([a-z-]+) .*/\1/p')"
    rm -rf "$sd" "$tg" "$out"
    printf '%s' "$v"
  }
  for be in jq py; do
    if [ "$be" = "jq" ]; then
      command -v jq >/dev/null 2>&1 || { skip "consensus oracle ($be backend: jq unavailable)"; continue; }
      cnbb="bash"; cnpp="$PATH"
    else
      cnbb="$cnrestr/bin/bash"; cnpp="$cnrestr/bin"
    fi
    assert_contains "consensus[$be]: all-agree (3/3) -> consensus" "$(cn_verdict "$cnbb" "$cnpp" "$cn3conf" 0 0 0)" "consensus"
    assert_contains "consensus[$be]: majority (2/3) -> consensus"  "$(cn_verdict "$cnbb" "$cnpp" "$cn3conf" 0 0 1)" "consensus"
    assert_contains "consensus[$be]: minority (1/3) -> no-quorum"  "$(cn_verdict "$cnbb" "$cnpp" "$cn3conf" 0 1 1)" "no-quorum"
    assert_contains "consensus[$be]: all-fail (0/3) -> none"       "$(cn_verdict "$cnbb" "$cnpp" "$cn3conf" 1 1 1)" "none"
    assert_contains "consensus[$be]: tie (1/2) -> no-quorum"       "$(cn_verdict "$cnbb" "$cnpp" "$cn2conf" 0 1)"   "no-quorum"
  done
  rm -rf "$cnrestr"; rm -f "$cn3conf" "$cn2conf"
else
  skip "stub-driven consensus oracle (timeout/python3 unavailable)"
fi

echo "== orchestration.md consensus wording matches the tested verdict (no-quorum = tie OR minority) =="
# no-quorum fires for ANY non-majority non-zero success (run-agent.sh else branch; tested above for
# minority 1/3 and tie 1/2). README points to docs/orchestration.md as the canonical consensus
# reference, so its no-quorum definition must not silently re-drift to a tie-only description.
if grep -qiE 'no-quorum.*minorit|minorit.*no-quorum' "$ROOT/docs/orchestration.md"; then
  ok "orchestration.md: no-quorum documents the minority case (not tie-only)"
else
  bad "orchestration.md: no-quorum documents the minority case (not tie-only)" "no-quorum still described as tie-only"
fi

echo "== --json consensus field: additive + byte-identical across config backends (Phase 9.5) =="
# The consensus verdict is an ADDITIVE --json field: present only under --consensus (the doc is
# byte-for-byte unchanged without it, per-agent rows unchanged), byte-identical across config backends,
# and emitted by the jq fallback branch too.
if command -v jq >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  cjstub="$(mktemp -d)"
  for cjb in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho resp\n' >"$cjstub/$cjb"; chmod +x "$cjstub/$cjb"; done
  cjrb="$(mktemp -d)"; mk_restricted_bin "$cjrb"   # python3, NO jq -> py config backend (--json emitter still python3)
  cj_doc() {  # bashbin pathprefix consensus(0|1) -> the --json doc (last line); wall-clock "sec" masked
    local bb="$1" pp="$2" cflag="$3" tg od extra=()
    [ "$cflag" = "1" ] && extra=(--consensus)
    tg="$(mktemp -d)"; od="$(mktemp -d)"
    # Mask the timing-dependent "sec" to a valid-JSON 0 (the two runs can straddle a 1s boundary) so the
    # cross-backend byte comparison + the agents[] parse are deterministic.
    EXTERNAL_AGENTS_AGY_QUOTA_CMD=false PATH="$cjstub:$pp" EXTERNAL_AGENTS_OUT="$od" \
      "$bb" "$RUN" --agent all --effort high --read-only --json ${extra[@]+"${extra[@]}"} --target "$tg" --prompt x 2>/dev/null | tail -1 | sed -E 's#"sec": *[0-9]+#"sec":0#g'
    rm -rf "$tg" "$od"
  }
  cj_a="$(cj_doc "bash" "$PATH" 1)"
  cj_b="$(cj_doc "$cjrb/bin/bash" "$cjrb/bin" 1)"
  if [ -n "$cj_a" ] && [ "$cj_a" = "$cj_b" ]; then
    ok "--json consensus: byte-identical across config backends (with --consensus)"
  else
    bad "--json consensus: byte-identical across config backends (with --consensus)" "a=[$cj_a] b=[$cj_b]"
  fi
  case "$cj_a" in *'"consensus":'*) ok "--json consensus: field present with --consensus";; *) bad "--json consensus: field present with --consensus" "no consensus field in --json";; esac
  cj_plain="$(cj_doc "bash" "$PATH" 0)"
  case "$cj_plain" in *'"consensus":'*) bad "--json consensus: field ABSENT without --consensus (additive)" "consensus field leaked without the flag";; *) ok "--json consensus: field ABSENT without --consensus (additive)";; esac
  ag_with="$(printf '%s' "$cj_a" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["agents"]))' 2>/dev/null)"
  ag_without="$(printf '%s' "$cj_plain" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["agents"]))' 2>/dev/null)"
  if [ -n "$ag_with" ] && [ "$ag_with" = "$ag_without" ]; then
    ok "--json consensus: per-agent row shape unchanged by the flag"
  else
    bad "--json consensus: per-agent row shape unchanged by the flag" "agents[] differ"
  fi
  # jq --json fallback branch (python3 ABSENT, jq present) must also emit the field.
  jqonly="$(mktemp -d)"; mkdir -p "$jqonly/bin"
  for cjt in bash env jq grep dirname basename cat sed sort tr cut wc paste date mktemp git head tail mkdir rm timeout; do cjs="$(command -v "$cjt" 2>/dev/null)" && ln -s "$cjs" "$jqonly/bin/$cjt"; done
  tgj="$(mktemp -d)"; odj="$(mktemp -d)"
  jqjson="$(EXTERNAL_AGENTS_AGY_QUOTA_CMD=false PATH="$cjstub:$jqonly/bin" "$jqonly/bin/bash" "$RUN" --agent all --effort high --read-only --json --consensus --target "$tgj" --prompt x 2>/dev/null)"
  rm -rf "$jqonly" "$tgj" "$odj" "$cjstub" "$cjrb"
  case "$jqjson" in *'"consensus"'*) ok "--json consensus: jq emitter fallback branch includes the field";; *) bad "--json consensus: jq emitter fallback branch includes the field" "jq --json branch missing consensus";; esac
else
  skip "--json consensus parity (jq/python3/timeout unavailable)"
fi

echo "== interface/driver separation leak guard (interface files contain no driving logic) =="
# The interface layer (commands/external-agents.md, skills/external-agents/SKILL.md) is THIN: it
# resolves intent and HANDS OFF to the driver — it must NOT reimplement driving logic. Assert neither
# file contains a driver-INTERNAL function name (the signature of copied/reimplemented logic). The
# interface MAY invoke run-agent.sh (the hand-off) and describe flags in prose — only reimplementation
# is a leak. Fails if driving logic is added to either interface file.
leak_found=""
for ifile in commands/external-agents.md skills/external-agents/SKILL.md; do
  for fn in build_argv run_one format_masked_argv agent_bin classify_outcome write_meta_json append_index_row extract_signal agy_model_status; do
    grep -qF "$fn" "$ROOT/$ifile" && leak_found="$leak_found $ifile:$fn"
  done
done
if [ -z "$leak_found" ]; then
  ok "interface separation: no driver-internal logic leaked into the interface files"
else
  bad "interface separation: no driver-internal logic leaked into the interface files" "driving logic in:$leak_found"
fi
# Positive: both interface files DO hand off to the driver (so the guard is checking real, wired files).
if grep -qF 'run-agent.sh' "$ROOT/skills/external-agents/SKILL.md" && grep -qF 'run-agent.sh' "$ROOT/commands/external-agents.md"; then
  ok "interface separation: both interface files hand off to scripts/run-agent.sh"
else
  bad "interface separation: both interface files hand off to scripts/run-agent.sh" "an interface file does not reference the driver"
fi

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
  # Phase 9.3: a NEW agent (not one of the built-in four) must validate via the additionalProperties
  # path, using the no-fallback tier shape — proving the registry/agents.json extensibility contract.
  printf '%s' '{"default_tier":"medium","agents":{"fixture":{"enabled":true,"tiers":{"low":{"model":"fix-small"},"medium":{"model":"fix-mid"}}}}}' >"$nfx"
  assert_contains "schema accepts a new (non-built-in) agent block via additionalProperties" "$(schema_check "$nfx")" "OK"
  printf '%s' '{"default_tier":"medium","agents":{"fixture":{"enabled":true,"tiers":{"high":{"model":"m","fallback":"g"}}}}}' >"$nfx"
  assert_contains "schema rejects a fallback on a new (non-agy) agent" "$(schema_check "$nfx")" "REJECTED"
  rm -f "$nfx"
else
  skip "schema validation (python3 jsonschema not installed)"
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
  skip "symlink-bypass test (could not create symlink)"
fi
rm -rf "$sl"

# A relative-path target that normalizes into the plugin tree, and a trailing-slash variant, must
# also be refused: the gate resolves the target via cd + pwd -P, so path-string form cannot fail open.
rel_parent="$(dirname "$ROOT")"; rel_base="$(basename "$ROOT")"
rel_err="$( (cd "$rel_parent" && bash "$RUN" --agent codex --target "./$rel_base/scripts" --prompt x) 2>&1 >/dev/null)"; rel_rc=$?
assert_exit     "relative-path target into the plugin is refused (exit 2)" 2 "$rel_rc"
assert_contains "relative-path containment is explained"                   "$rel_err" "plugin tree"
ts_err="$(bash "$RUN" --agent codex --target "$ROOT/scripts/" --prompt x 2>&1 >/dev/null)"; ts_rc=$?
assert_exit     "trailing-slash target into the plugin is refused (exit 2)" 2 "$ts_rc"
assert_contains "trailing-slash containment is explained"                   "$ts_err" "plugin tree"

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

echo "== prompt injection safety (prompt is one verbatim argv element, never eval'd) =="
# threat-model.md "Prompt integrity": the task text must reach the agent as a SINGLE argv element and
# never be shell-evaluated. The <PROMPT>-masking assertions prove the dry-run DISPLAY masks it; this
# proves the RUNTIME contract. Drive a stub agent that records its argv, pass a prompt full of shell
# metacharacters incl. command-substitution/backtick sentinels, and assert (a) no sentinel command
# ran (no driver-side eval/expansion) and (b) the agent got the prompt as ONE verbatim argv element.
if command -v timeout >/dev/null 2>&1; then
  injdir="$(mktemp -d)"; injtgt="$(mktemp -d)"; injod="$(mktemp -d)"
  injrec="$injdir/argv.txt"; injsent="$injdir/SENTINEL"
  cat >"$injdir/codex" <<INJEOF
#!/usr/bin/env bash
printf 'ARGC=%s\n' "\$#" >"$injrec"
for a in "\$@"; do printf 'ARG=%s\n' "\$a" >>"$injrec"; done
INJEOF
  chmod +x "$injdir/codex"
  # shellcheck disable=SC2016  # the metacharacters below are LITERAL injection-test payloads, not expansions
  inj_sub='$(touch '"$injsent"')'
  # shellcheck disable=SC2016
  inj_bt='`touch '"$injsent"'`'
  inj_prompt="benign $inj_sub $inj_bt ; echo injected ; nomatch-*-glob"
  PATH="$injdir:$PATH" EXTERNAL_AGENTS_OUT="$injod" bash "$RUN" --agent codex --read-only --target "$injtgt" --prompt "$inj_prompt" >/dev/null 2>&1
  if [ -e "$injsent" ]; then bad "injection: command-substitution/backtick in prompt never executes" "sentinel created -> driver evaluated the prompt"; else ok "injection: command-substitution/backtick in prompt never executes"; fi
  if grep -qF -- "$inj_prompt" "$injrec" 2>/dev/null; then ok "injection: prompt reaches the agent as a single verbatim argv element"; else bad "injection: prompt reaches the agent as a single verbatim argv element" "recorded argv: $(tr '\n' '|' <"$injrec" 2>/dev/null)"; fi
  rm -rf "$injdir" "$injtgt" "$injod"
else
  skip "prompt injection oracle (timeout unavailable)"
fi

echo "== version lockstep (plugin.json == SKILL.md == README badge == CHANGELOG) =="
pv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
sv="$(grep -oE '^  version: "[^"]+"' "$ROOT/skills/external-agents/SKILL.md" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
rvraw="$(grep -oE 'badge/version-.*-informational' "$ROOT/README.md" | head -1 | sed -E 's#badge/version-(.*)-informational#\1#')"
# Reverse the shields.io message escaping ('--'->'-', '__'->'_').
rv="$(printf '%s' "$rvraw" | sed -e 's/--/-/g' -e 's/__/_/g')"
cv="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | sed -E 's/.*\[([0-9.]+)\].*/\1/')"
if [ "$pv" = "$sv" ] && [ "$pv" = "$rv" ] && [ "$pv" = "$cv" ]; then
  ok "all version strings agree ($pv)"
else
  bad "all version strings agree" "plugin.json=$pv SKILL.md=$sv README=$rv CHANGELOG=$cv"
fi

out="$(bash "$RUN" --version 2>/dev/null)"
assert_contains "run-agent.sh --version prints the plugin version" "$out" "$pv"
out="$(bash "$RUN" -V 2>/dev/null)"
assert_contains "run-agent.sh -V prints the plugin version" "$out" "$pv"

echo "== CHANGELOG.md Keep a Changelog structure (preamble + newest dated entry + change-type subsections) =="
# CHANGELOG.md must keep the Keep a Changelog + SemVer preamble and a newest dated '## [X.Y.Z] - DATE'
# entry carrying a change-type subsection. The bumper writes this shape, but no guard pins it, so a
# manual edit could silently break the published changelog structure.
CL="$ROOT/CHANGELOG.md"
if grep -qiF 'keep a changelog' "$CL" && grep -qiF 'semantic versioning' "$CL"; then
  ok "changelog: Keep a Changelog + SemVer preamble present"
else
  bad "changelog: Keep a Changelog + SemVer preamble present" "preamble missing"
fi
if grep -qm1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}' "$CL"; then
  ok "changelog: newest entry is a dated '## [X.Y.Z] - YYYY-MM-DD' header"
else
  bad "changelog: newest entry is a dated '## [X.Y.Z] - YYYY-MM-DD' header" "no dated version header"
fi
cl_sub="$(awk '/^## \[[0-9]/{n++} n==1 && /^### (Added|Changed|Fixed|Removed|Deprecated|Security)/{print; exit}' "$CL")"
if [ -n "$cl_sub" ]; then
  ok "changelog: newest entry carries a change-type subsection (### Added/Changed/Fixed/...)"
else
  bad "changelog: newest entry carries a change-type subsection" "no ### change-type subsection in the newest entry"
fi

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
  skip "bump-version compute (could not parse current version $pv)"
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

echo "== agy never spends quota: read-only quota command, wakeup never invoked =="
# The agy fallback decision consults the quota CLI READ-ONLY (`antigravity-usage --json`); it must
# NEVER call the quota-SPENDING `wakeup`. Pin both halves offline (mirroring the live probe's *wakeup*
# rejection): (1) the driver's default resolved quota command is the read-only --json query with no
# `wakeup` token; (2) no ACTIVE (non-comment) driver line invokes `wakeup` anywhere.
qc_line="$(grep -E '^AGY_QUOTA_CMD=' "$ROOT/scripts/run-agent.sh" | head -1)"
assert_contains "never-spend-quota: default quota command is the read-only --json query" "$qc_line" "antigravity-usage --json"
case "$qc_line" in *wakeup*) bad "never-spend-quota: default quota command has no 'wakeup' token" "wakeup in resolved quota command: $qc_line";; *) ok "never-spend-quota: default quota command has no 'wakeup' token";; esac
qc_active_wakeup="$(grep -vE '^[[:space:]]*#' "$ROOT/scripts/run-agent.sh" | grep -nE 'wakeup' | head -1)"
if [ -z "$qc_active_wakeup" ]; then ok "never-spend-quota: no active driver line invokes 'wakeup'"; else bad "never-spend-quota: no active driver line invokes 'wakeup'" "active wakeup reference: $qc_active_wakeup"; fi

echo "== per-agent fan-out record fields (stub fan-out, no live CLI) =="
# The collect loop builds a control-plane record per agent ($OUT/<a>.record): tab-delimited
# agent/model/tier/effort/mode/rc/sec/bytes/fallback. Assert the fields for a multi-agent shape
# using stub agents (no real CLI), including the agy fallback flag and that NO transcript text leaks.
if command -v timeout >/dev/null 2>&1; then
  recstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "stub response"\n' >"$recstub/$b"; chmod +x "$recstub/$b"; done
  rectgt="$(mktemp -d)"; recodir="$(mktemp -d)"
  # EXTERNAL_AGENTS_AGY_QUOTA_CMD=false forces the quota check to fail (IDE closed / quota
  # unconfirmable) so the agy high-tier fallback fires deterministically, regardless of whether a
  # real antigravity-usage is installed on PATH (matches the parity/degradation blocks above).
  PATH="$recstub:$PATH" EXTERNAL_AGENTS_OUT="$recodir" EXTERNAL_AGENTS_AGY_QUOTA_CMD=false \
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
  skip "per-agent record test (timeout unavailable)"
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
  # Force the agy high-tier fallback deterministically (IDE closed / quota unconfirmable) so the
  # fallback:true assertion holds on machines that do have a real antigravity-usage on PATH.
  PATH="$mstub:$PATH" EXTERNAL_AGENTS_OUT="$modir" EXTERNAL_AGENTS_AGY_QUOTA_CMD=false \
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
  # (5) Phase 4.1: pin the EXACT meta.json key set + per-field JSON types, so adding, removing, or
  # retyping a field in write_meta_json fails the offline suite (complements the schema drift guard).
  meta_contract="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
top = {"agent","model","tier","effort","mode","target","rc","sec","bytes","fallback","timestamp","error_class","attempts","retried","signals"}
errs = []
if set(d) != top: errs.append("top-keys " + repr(sorted(set(d) ^ top)))
if set(d.get("signals", {})) != {"tokens", "cost"}: errs.append("signals-keys")
def isnum(x): return isinstance(x, (int, float)) and not isinstance(x, bool)
for k in ("agent","model","tier","effort","mode","target","timestamp","error_class"):
    if not isinstance(d.get(k), str): errs.append("type:" + k)
for k in ("rc","sec","bytes","attempts"):
    if not isnum(d.get(k)): errs.append("type:" + k)
for k in ("fallback","retried"):
    if not isinstance(d.get(k), bool): errs.append("type:" + k)
sg = d.get("signals", {})
if not (isnum(sg.get("tokens")) or isinstance(sg.get("tokens"), str)): errs.append("type:signals.tokens")
if not isinstance(sg.get("cost"), str): errs.append("type:signals.cost")
print("OK" if not errs else "FAIL " + "; ".join(errs))
' "$mproj/codex.meta.json" 2>/dev/null)"
  assert_contains "meta: exact key set + per-field JSON types pinned (add/remove/retype fails)" "$meta_contract" "OK"
  rm -rf "$mstub" "$mtgt" "$modir"
else
  skip "per-run metadata record test (timeout/python3 unavailable)"
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
  # Force the agy high-tier fallback deterministically (IDE closed / quota unconfirmable) so the
  # agy fallback:true row holds regardless of a real antigravity-usage being installed on PATH.
  PATH="$istub:$PATH" EXTERNAL_AGENTS_OUT="$ibase" EXTERNAL_AGENTS_AGY_QUOTA_CMD=false \
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
  # Phase 4.1: pin the row contract — every line is ONE valid JSON object = the run_id/timestamp/project
  # prefix PLUS the embedded per-run meta record (no row is a bare prefix or a partial/invalid object).
  irow="$(python3 -c '
import json, sys
prefix = {"run_id", "timestamp", "project"}
meta = {"agent","model","tier","effort","mode","target","rc","sec","bytes","fallback","error_class","attempts","retried","signals"}
n = 0
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln: continue
    try:
        r = json.loads(ln)
    except Exception:
        print("INVALID_JSON"); sys.exit(0)
    if not isinstance(r, dict): print("NOT_OBJECT"); sys.exit(0)
    if not prefix <= set(r): print("NO_PREFIX"); sys.exit(0)
    if not meta <= set(r): print("NO_META"); sys.exit(0)
    n += 1
print("OK %d" % n if n > 0 else "EMPTY")
' "$ibase/index.jsonl" 2>/dev/null)"
  assert_contains "index: each line is one valid JSON object = prefix + embedded meta record" "$irow" "OK"
  # Append-only: a further run APPENDS — the prior content is a byte-unchanged prefix, +1 row.
  ipre="$(cat "$ibase/index.jsonl")"
  PATH="$istub:$PATH" EXTERNAL_AGENTS_OUT="$ibase" bash "$RUN" --agent codex --effort high --read-only --target "$itgt" --prompt z >/dev/null 2>&1
  ipost="$(cat "$ibase/index.jsonl")"
  if [ "${ipost:0:${#ipre}}" = "$ipre" ] && [ "$(printf '%s\n' "$ipost" | grep -c .)" = "5" ]; then
    ok "index: append-only — a re-run appends one row, prior rows byte-unchanged"
  else
    bad "index: append-only — a re-run appends one row, prior rows byte-unchanged" "prior content changed or wrong row count"
  fi
  rm -rf "$istub" "$itgt" "$ibase"
else
  skip "run-index test (timeout/python3 unavailable)"
fi

echo "== signal extraction over fixture transcripts (present / absent, no live CLI) =="
# Feed captured fixture transcripts (one with token+cost lines, one with neither) through the REAL
# run_one -> extract_signal path via a stub that cats the fixture, and assert the per-run record's
# signals: present -> the parsed values (tokens a number, cost verbatim); absent -> "unavailable".
# The fixtures are committed here and written to disk so the cat-stub reads them VERBATIM (no shell
# expansion of the literal '$' in the cost line).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  sigdir="$(mktemp -d)"
  # shellcheck disable=SC2016  # the literal '$0.0421' is fixture cost text; it must NOT expand.
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
  # shellcheck disable=SC2016  # the needle '"cost":"$0.0421"' is a literal JSON string; it must NOT expand.
  assert_contains "signals: present fixture extracts the cost verbatim"     "$pres" '"cost":"$0.0421"'
  absn="$(sig_signals "$sigdir/absent.txt")"
  assert_contains "signals: absent fixture -> tokens unavailable" "$absn" '"tokens":"unavailable"'
  assert_contains "signals: absent fixture -> cost unavailable"   "$absn" '"cost":"unavailable"'
  rm -rf "$sigdir"
else
  skip "signal-extraction fixture test (timeout/python3 unavailable)"
fi

echo "== extract_signal is registry-driven (any ADAPTER_AGENTS member gets the recognizer, no hard-coded list) =="
# Registry-only invariant guard: extract_signal must gate on ADAPTER_AGENTS membership, NOT a hard-coded
# agent list, so a registry-only-added agent gets signal extraction with no emitter/policy edit — while
# an UNREGISTERED agent still gets no signal (the conservative gate). Source just the function and drive
# it with a synthetic agent name that is/ isn't in a test-set ADAPTER_AGENTS.
es_fn="$(mktemp)"; sed -n '/^extract_signal() {/,/^}/p' "$ROOT/scripts/run-agent.sh" >"$es_fn"
es_tx="$(mktemp)"
# shellcheck disable=SC2016  # the literal '$0.12' is fixture cost text; it must NOT expand
printf 'work done. total tokens: 4242 and total cost: $0.12\n' >"$es_tx"
es_tok="$(bash -c 'ADAPTER_AGENTS=(agy codex claude cursor newagent); . "$1"; extract_signal "$2" newagent tokens' _ "$es_fn" "$es_tx" 2>/dev/null)"
es_unreg="$(bash -c 'ADAPTER_AGENTS=(agy codex claude cursor); . "$1"; extract_signal "$2" newagent tokens' _ "$es_fn" "$es_tx" 2>/dev/null)"
rm -f "$es_fn" "$es_tx"
if [ "$es_tok" = "4242" ]; then ok "extract_signal: a registry-listed agent (in ADAPTER_AGENTS) gets the shared recognizer"
else bad "extract_signal: a registry-listed agent gets the shared recognizer" "expected 4242, got '$es_tok' — extract_signal is not registry-driven (hard-coded list?)"; fi
if [ -z "$es_unreg" ]; then ok "extract_signal: a NON-registry agent gets no signal (conservative gate preserved)"
else bad "extract_signal: a NON-registry agent gets no signal" "expected empty, got '$es_unreg'"; fi

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
  skip "summary-block test (timeout unavailable)"
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
  skip "agreement-signal test (timeout unavailable)"
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
  skip "JSON summary validation (timeout/python3 unavailable)"
fi

echo "== jq / python3 JSON-emitter parity (meta.json, index row, --json doc byte-identical) =="
# The cfg parity block above gates only the config READ ops. The driver also has three JSON
# EMITTERS — write_meta_json (<a>.meta.json), append_index_row (index.jsonl), and the --json
# summary — each with a jq branch and a python3 branch. They are exercised only under whichever
# backend is present (jq on CI), so a one-sided edit to either branch could diverge uncaught.
# Gate it: run ONE stubbed --agent all fan-out under jq, and again under a python3-only PATH, then
# assert the emitted JSON matches across backends. AGY_QUOTA_CMD=false in both forces agy to fall
# back deterministically, isolating emitter parity from live quota state (mirrors the cfg block).
if command -v jq >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  estub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "resp text"\n' >"$estub/$b"; chmod +x "$estub/$b"; done
  erb="$(mktemp -d)"; mk_restricted_bin "$erb"   # python3, NO jq -> forces JSON_BACKEND=py
  # Mask the run-unique fields (target path, timestamp, run_id, project) AND the wall-clock "sec"
  # (timing-dependent: the two backend runs can straddle a 1-second boundary) so only the structural
  # JSON shape + resolved values are compared across the two backends.
  emask() { sed -E -e 's#"target":"[^"]*"#"target":"T"#g' -e 's#"timestamp":"[^"]*"#"timestamp":"TS"#g' \
                   -e 's#"run_id":"[^"]*"#"run_id":"RID"#g' -e 's#"project":"[^"]*"#"project":"P"#g' \
                   -e 's#"sec": *[0-9]+#"sec":0#g'; }
  emit_run() {  # tag  pathprefix  bashbin
    local tag="$1" pp="$2" bb="$3" etgt eod eproj
    etgt="$(mktemp -d)"; eod="$(mktemp -d)"
    EXTERNAL_AGENTS_AGY_QUOTA_CMD=false PATH="$estub:$pp" EXTERNAL_AGENTS_OUT="$eod" \
      "$bb" "$RUN" --agent all --effort high --read-only --json --target "$etgt" --prompt x >"$eod/stdout" 2>/dev/null
    eproj="$eod/$(basename "$etgt")"
    emask <"$eproj/codex.meta.json" >"$estub/$tag.meta" 2>/dev/null
    grep '"agent":"codex"' "$eod/index.jsonl" 2>/dev/null | emask >"$estub/$tag.row"
    tail -1 "$eod/stdout" | emask >"$estub/$tag.json" 2>/dev/null
    rm -rf "$etgt" "$eod"
  }
  emit_run jq "$PATH"      "bash"
  emit_run py "$erb/bin"   "$erb/bin/bash"
  if [ -s "$estub/jq.meta" ] && [ -s "$estub/py.meta" ]; then
    if [ "$(cat "$estub/jq.meta")" = "$(cat "$estub/py.meta")" ]; then ok "emitter parity: .meta.json identical (jq == python3)"; else bad "emitter parity: .meta.json identical (jq == python3)" "backends diverged"; fi
    if [ "$(cat "$estub/jq.row")"  = "$(cat "$estub/py.row")"  ]; then ok "emitter parity: index.jsonl row identical (jq == python3)"; else bad "emitter parity: index.jsonl row identical (jq == python3)" "backends diverged"; fi
    if [ "$(cat "$estub/jq.json")" = "$(cat "$estub/py.json")" ]; then ok "emitter parity: --json doc identical (jq == python3)"; else bad "emitter parity: --json doc identical (jq == python3)" "backends diverged"; fi
  else
    skip "JSON-emitter parity (a backend produced no record in this environment)"
  fi
  rm -rf "$estub" "$erb"
else
  skip "JSON-emitter parity (jq/python3/timeout unavailable)"
fi

echo "== run-record schema conformance (stub fan-out records validate vs run-record.schema.json; both backends) =="
# Every emitted meta.json and index.jsonl row must conform to the published draft-07 schema. Run a
# stub --agent all fan-out under jq AND under a python3-only PATH, then validate each emitted record
# against schema/run-record.schema.json with python3 jsonschema. Offline; no live CLI.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  scstub="$(mktemp -d)"
  for b in agy codex cursor-agent; do printf '#!/usr/bin/env bash\necho "resp text"\n' >"$scstub/$b"; chmod +x "$scstub/$b"; done
  screstr="$(mktemp -d)"; mk_restricted_bin "$screstr"   # python3, NO jq -> forces JSON_BACKEND=py
  sc_run() {  # pathprefix  bashbin -> "OK <n>" if every meta.json + index row validates, else "FAIL ..."
    local pp="$1" bb="$2" sctgt scod
    sctgt="$(mktemp -d)"; scod="$(mktemp -d)"
    EXTERNAL_AGENTS_AGY_QUOTA_CMD=false PATH="$scstub:$pp" EXTERNAL_AGENTS_OUT="$scod" \
      "$bb" "$RUN" --agent all --effort high --read-only --target "$sctgt" --prompt x >/dev/null 2>&1
    SC_SCHEMA="$ROOT/schema/run-record.schema.json" SC_OUT="$scod" SC_PROJ="$(basename "$sctgt")" python3 - <<'PY'
import json, os, glob
from jsonschema import Draft7Validator
v = Draft7Validator(json.load(open(os.environ["SC_SCHEMA"])))
proj = os.path.join(os.environ["SC_OUT"], os.environ["SC_PROJ"])
n = 0; errs = []
for f in sorted(glob.glob(os.path.join(proj, "*.meta.json"))):
    try:
        rec = json.load(open(f))
    except Exception as ex:
        errs.append("meta parse %s: %s" % (os.path.basename(f), ex)); continue
    e = list(v.iter_errors(rec))
    if e: errs.append("meta %s: %s" % (os.path.basename(f), e[0].message))
    else: n += 1
idx = os.path.join(os.environ["SC_OUT"], "index.jsonl")
if os.path.exists(idx):
    for ln in open(idx):
        ln = ln.strip()
        if not ln: continue
        try:
            row = json.loads(ln)
        except Exception as ex:
            errs.append("row parse: %s" % ex); continue
        e = list(v.iter_errors(row))
        if e: errs.append("row %s: %s" % (row.get("agent", "?"), e[0].message))
        else: n += 1
print("FAIL " + "; ".join(errs) if errs else "OK %d" % n)
PY
    rm -rf "$sctgt" "$scod"
  }
  sc_jq="$(sc_run "$PATH" "bash")"
  sc_py="$(sc_run "$screstr/bin" "$screstr/bin/bash")"
  rm -rf "$scstub" "$screstr"
  case "$sc_jq" in "OK "[1-9]*) ok "schema conformance: jq-backend records validate ($sc_jq)";;     *) bad "schema conformance: jq-backend records validate" "$sc_jq";; esac
  case "$sc_py" in "OK "[1-9]*) ok "schema conformance: python3-backend records validate ($sc_py)";; *) bad "schema conformance: python3-backend records validate" "$sc_py";; esac
else
  skip "run-record schema conformance (timeout/python3/jsonschema unavailable)"
fi

echo "== run-record schema <-> emitter drift guard (write_meta_json field set == schema properties) =="
# Modeled on the enforcement-matrix guard: the record field set lives in TWO places — the emitter
# (write_meta_json in scripts/run-agent.sh) and the published schema (schema/run-record.schema.json).
# A future rename/retype/drop could change one without the other. Assert the emitter's emitted key set
# equals the schema's record + signals property names, so the contract cannot silently rot. Offline.
if command -v python3 >/dev/null 2>&1; then
  drift_emit="$(awk '/^write_meta_json\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/scripts/run-agent.sh" \
    | grep -oE '"[a-z_]+":' | tr -d '":' | sort -u | paste -sd' ' -)"
  drift_schema="$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
ks=list(s["definitions"]["record"]["properties"])+list(s["definitions"]["signals"]["properties"])
print(" ".join(sorted(set(ks))))' "$ROOT/schema/run-record.schema.json" 2>/dev/null)"
  if [ -n "$drift_emit" ] && [ "$drift_emit" = "$drift_schema" ]; then
    ok "schema drift: write_meta_json field set equals the schema's record+signals properties"
  else
    bad "schema drift: write_meta_json field set equals the schema's record+signals properties" \
        "emitter=[$drift_emit] schema=[$drift_schema]"
  fi
else
  skip "run-record schema drift guard (python3 unavailable)"
fi

echo "== content-free field-name denylist (no record/schema field may name transcript/prompt/secret content) =="
# The drift guard above pins the field SET (emitter == schema), but a content-bearing field added to
# BOTH the emitter and the schema together would keep that guard green while leaking content. This
# denylist makes the content-free guarantee a red test independent of drift: no meta.json emitter or
# schema field name may name transcript/prompt/secret/response content. Names only, never values.
cf_deny='prompt|transcript|response|secret|password|passwd|stdout|stderr|content|free.?text|body'
cf_emit_names="$(awk '/^write_meta_json\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/scripts/run-agent.sh" | grep -oE '"[a-z_]+":' | tr -d '":' | sort -u)"
cf_hit="$(printf '%s\n' "$cf_emit_names" | grep -iE "$cf_deny" || true)"
if command -v python3 >/dev/null 2>&1; then
  cf_schema_names="$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
ks=list(s["definitions"]["record"]["properties"])+list(s["definitions"]["signals"]["properties"])
print("\n".join(sorted(set(ks))))' "$ROOT/schema/run-record.schema.json" 2>/dev/null)"
  cf_hit="$cf_hit
$(printf '%s\n' "$cf_schema_names" | grep -iE "$cf_deny" || true)"
fi
cf_hit="$(printf '%s' "$cf_hit" | grep -v '^$' || true)"
if [ -z "$cf_hit" ]; then
  ok "content-free denylist: no meta.json/schema field name carries transcript/prompt/secret content"
else
  bad "content-free denylist: no meta.json/schema field name carries transcript/prompt/secret content" "forbidden field(s): $(printf '%s' "$cf_hit" | tr '\n' ' ')"
fi

echo "== run-record doc <-> schema drift guard (run-record-contract.md fields == schema record+signals+index) =="
# Mirrors the emitter<->schema guard above: the field-by-field reference in docs/run-record-contract.md
# must document EXACTLY the schema's documentable leaf fields — record scalars, signals.tokens/cost, and
# the index-row run_id/project — so the published contract doc cannot silently drift from the schema.
if command -v python3 >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # literal backtick/regex, not a shell expansion
  docdrift_doc="$(grep -oE '^\| `[a-z_.]+`' "$ROOT/docs/run-record-contract.md" | tr -d '|` ' | sort -u | paste -sd' ' -)"
  docdrift_schema="$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
rec=set(s["definitions"]["record"]["properties"])
sig=set(s["definitions"]["signals"]["properties"])
allp=set()
def walk(n):
    if isinstance(n, dict):
        for k in (n.get("properties") or {}):
            allp.add(k)
        for key in ("allOf", "oneOf", "anyOf"):
            for x in n.get(key, []) or []:
                walk(x)
        for x in (n.get("definitions") or {}).values():
            walk(x)
walk(s)
extra = allp - rec - sig - {"signals"}
leaf = (rec - {"signals"}) | {"signals." + k for k in sig} | extra
print(" ".join(sorted(leaf)))' "$ROOT/schema/run-record.schema.json" 2>/dev/null)"
  if [ -n "$docdrift_doc" ] && [ "$docdrift_doc" = "$docdrift_schema" ]; then
    ok "doc drift: run-record-contract.md documents exactly the schema's record+signals+index fields"
  else
    bad "doc drift: run-record-contract.md documents exactly the schema's record+signals+index fields" \
        "doc=[$docdrift_doc] schema=[$docdrift_schema]"
  fi
else
  skip "run-record doc drift guard (python3 unavailable)"
fi

echo "== run-record additive-only schema-stability guard (no removed/renamed field, no new required) =="
# main-planning §5 mandates an ADDITIVE-ONLY run-record contract: new optional fields may be added, but
# no field may be removed or renamed and no field may become newly required (older rows must stay valid).
# Pin the schema's structural shape to a committed baseline so a breaking delta fails offline. The other
# drift guards pin the field SET (emitter/doc equality); this is the ONLY guard on the REQUIRED set and
# on additive-only deltas. To update the baseline after an intentional ADDITIVE change, add the new leaf
# field name to ADDITIVE_BASELINE_LEAF below — never remove one, and never add to ADDITIVE_BASELINE_REQUIRED.
ADDITIVE_BASELINE_LEAF="agent attempts bytes effort error_class fallback mode model project rc retried run_id sec signals.cost signals.tokens target tier timestamp"
ADDITIVE_BASELINE_REQUIRED="agent bytes cost effort fallback mode model project rc run_id sec signals target tier timestamp tokens"
if command -v python3 >/dev/null 2>&1; then
  addsel="$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
rec=set(s["definitions"]["record"]["properties"]); sig=set(s["definitions"]["signals"]["properties"])
allp=set(); req=set()
def walk(n):
    if isinstance(n, dict):
        for k in (n.get("properties") or {}): allp.add(k)
        for r in (n.get("required") or []): req.add(r)
        for key in ("allOf","oneOf","anyOf"):
            for x in n.get(key,[]) or []: walk(x)
        for x in (n.get("definitions") or {}).values(): walk(x)
walk(s)
extra=allp-rec-sig-{"signals"}
leaf=(rec-{"signals"}) | {"signals."+k for k in sig} | extra
print(" ".join(sorted(leaf))); print(" ".join(sorted(req)))' "$ROOT/schema/run-record.schema.json" 2>/dev/null)"
  add_leaf_now="$(printf '%s\n' "$addsel" | sed -n '1p')"
  add_req_now="$(printf '%s\n' "$addsel" | sed -n '2p')"
  add_removed=""
  for f in $ADDITIVE_BASELINE_LEAF; do case " $add_leaf_now " in *" $f "*) : ;; *) add_removed="$add_removed $f";; esac; done
  add_newreq=""
  for f in $add_req_now; do case " $ADDITIVE_BASELINE_REQUIRED " in *" $f "*) : ;; *) add_newreq="$add_newreq $f";; esac; done
  if [ -z "$add_removed" ] && [ -z "$add_newreq" ]; then
    ok "additive-only: no run-record field removed/renamed and no field newly required vs the committed baseline"
  else
    bad "additive-only: no run-record field removed/renamed and no field newly required vs the committed baseline" "removed/renamed:[$add_removed ] newly-required:[$add_newreq ]"
  fi
else
  skip "run-record additive-only schema-stability guard (python3 unavailable)"
fi

echo "== error-class + bounded-retry failure injection (stub agents; both backends) =="
# Inject failures with stub agents and assert the recorded error_class + retry behaviour: (a) a
# transient 5xx, (b) an auth-shaped failure (never retried even with RETRY_MAX>0), (c) a sleep past a
# short --timeout, and (d) a transient retried exactly N times (attempts=N+1). Run under jq AND a
# python3-only PATH. Plus (e) a safety gate refuses BEFORE launch, so a safety-refusal is never
# retried, and classify_outcome maps a gate refusal to that class. Offline; no live CLI.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  firestr="$(mktemp -d)"; mk_restricted_bin "$firestr"   # python3, NO jq -> forces JSON_BACKEND=py
  fisl="$(command -v sleep 2>/dev/null || true)"; [ -n "$fisl" ] && ln -s "$fisl" "$firestr/bin/sleep" 2>/dev/null   # stub (c) needs sleep
  fi_run() {  # bashbin  pathprefix  stub-body  retry-max  timeout -> "<class> <attempts> <retried>"
    local bb="$1" pp="$2" body="$3" rmax="$4" tmo="$5" d od tg
    d="$(mktemp -d)"; od="$(mktemp -d)"; tg="$(mktemp -d)"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$d/codex"; chmod +x "$d/codex"
    PATH="$d:$pp" EXTERNAL_AGENTS_OUT="$od" EXTERNAL_AGENTS_RETRY_MAX="$rmax" EXTERNAL_AGENTS_RETRY_BACKOFF=0 \
      "$bb" "$RUN" --agent codex --effort high --read-only --timeout "$tmo" --target "$tg" --prompt x >/dev/null 2>&1
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(d.get("error_class"), d.get("attempts"), d.get("retried"))' \
      "$od/$(basename "$tg")/codex.meta.json" 2>/dev/null
    rm -rf "$d" "$od" "$tg"
  }
  for be in jq py; do
    if [ "$be" = "jq" ]; then
      command -v jq >/dev/null 2>&1 || { skip "failure injection (jq backend: jq unavailable)"; continue; }
      fibb="bash"; fipp="$PATH"
    else
      fibb="$firestr/bin/bash"; fipp="$firestr/bin"
    fi
    assert_contains "fi[$be]: 503 non-zero -> transient"                   "$(fi_run "$fibb" "$fipp" 'echo "HTTP 503 service temporarily unavailable" >&2; exit 1' 0 30)" "transient"
    assert_contains "fi[$be]: auth-shaped -> auth, not retried"            "$(fi_run "$fibb" "$fipp" 'echo "authentication failed" >&2; exit 1' 2 30)" "auth 1 False"
    assert_contains "fi[$be]: sleeps past --timeout -> timeout"            "$(fi_run "$fibb" "$fipp" 'sleep 5' 0 1)" "timeout"
    assert_contains "fi[$be]: transient RETRY_MAX=2 -> attempts 3, retried" "$(fi_run "$fibb" "$fipp" 'echo "rate limit exceeded" >&2; exit 1' 2 30)" "transient 3 True"
  done
  # (e) a pre-launch safety gate refuses (exit 2) without launching, so a safety-refusal is never retried.
  fi_sr="$(bash "$RUN" --agent codex --read-only --write --target . --prompt x 2>&1)"; fi_sr_rc=$?
  assert_exit     "fi: a safety gate refuses before launch (exit 2)" 2 "$fi_sr_rc"
  assert_contains "fi: gate refusal reported, agent never launched"  "$fi_sr" "mutually exclusive"
  ficf="$firestr/cf.sh"; sed -n '/^classify_outcome() {/,/^}/p' "$ROOT/scripts/run-agent.sh" >"$ficf"
  fi_srclass="$(bash -c '. "$0"; classify_outcome GATE 2 /dev/null' "$ficf")"
  assert_contains "fi: classify_outcome maps a gate refusal to safety-refusal" "$fi_srclass" "safety-refusal"
  rm -rf "$firestr"
else
  skip "failure-injection oracles (timeout/python3 unavailable)"
fi

echo "== retry timeout opt-in (timeout retried ONLY with EXTERNAL_AGENTS_RETRY_ON_TIMEOUT=1) =="
# The failure-injection block above classifies a timeout but never exercises the opt-in retry gate.
# Per scripts/run-agent.sh the retryable set is { transient (always), timeout (opt-in) }: a timeout is
# retried ONLY when EXTERNAL_AGENTS_RETRY_ON_TIMEOUT=1, even with RETRY_MAX>0. Pin both arms offline.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  tostub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$tostub/codex"; chmod +x "$tostub/codex"
  to_meta() {  # ron_to-value -> "<class> <attempts> <retried>"
    local ron="$1" od tg; od="$(mktemp -d)"; tg="$(mktemp -d)"
    PATH="$tostub:$PATH" EXTERNAL_AGENTS_OUT="$od" EXTERNAL_AGENTS_RETRY_MAX=2 EXTERNAL_AGENTS_RETRY_BACKOFF=0 EXTERNAL_AGENTS_RETRY_ON_TIMEOUT="$ron" \
      bash "$RUN" --agent codex --effort high --read-only --timeout 1 --target "$tg" --prompt x >/dev/null 2>&1
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("error_class"), d.get("attempts"), d.get("retried"))' "$od/$(basename "$tg")/codex.meta.json" 2>/dev/null
    rm -rf "$od" "$tg"
  }
  assert_contains "retry timeout: NOT retried without opt-in (RETRY_MAX=2, off -> 1 attempt)" "$(to_meta 0)" "timeout 1 False"
  assert_contains "retry timeout: retried WITH opt-in (RETRY_ON_TIMEOUT=1 -> attempts 3)"     "$(to_meta 1)" "timeout 3 True"
  rm -rf "$tostub"
else
  skip "retry timeout opt-in oracle (timeout/python3 unavailable)"
fi

echo "== closed-set classification coverage: contract + unknown (the untested classes) =="
# classify_outcome (scripts/run-agent.sh) maps to a CLOSED set; the failure-injection block above
# covers ok/safety-refusal/timeout/transient/auth. Pin the remaining two: a malformed agent output ->
# "contract", and an unclassified non-zero exit -> "unknown". Classification is computed once in shell
# (backend-independent by construction), so one backend suffices. Offline; no live CLI.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  cc_meta() {  # stub-body -> error_class
    local body="$1" d od tg; d="$(mktemp -d)"; od="$(mktemp -d)"; tg="$(mktemp -d)"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$d/codex"; chmod +x "$d/codex"
    PATH="$d:$PATH" EXTERNAL_AGENTS_OUT="$od" bash "$RUN" --agent codex --effort high --read-only --timeout 30 --target "$tg" --prompt x >/dev/null 2>&1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error_class"))' "$od/$(basename "$tg")/codex.meta.json" 2>/dev/null
    rm -rf "$d" "$od" "$tg"
  }
  assert_contains "classification: malformed agent output -> contract"   "$(cc_meta 'echo "malformed response" >&2; exit 1')" "contract"
  assert_contains "classification: unclassified non-zero exit -> unknown" "$(cc_meta 'echo "?!?" >&2; exit 7')"            "unknown"
else
  skip "closed-set classification coverage (timeout/python3 unavailable)"
fi

echo "== run-history analytics trends oracle (committed synthetic index; both backends; read-only) =="
# Aggregate scripts/run-history-report.sh over a COMMITTED synthetic index fixture and assert exact
# values under jq AND a python3-only PATH: run/ok/fail counts, error_class distribution, fallback
# rate, sec/bytes summaries, and the tokens/cost aggregates with the "unavailable" rows EXCLUDED
# (counted, never zeroed). Then assert the fixture is byte-identical after the analytic runs.
if command -v python3 >/dev/null 2>&1; then
  RH="$ROOT/scripts/run-history-report.sh"
  TFIX="$ROOT/tests/fixtures/synthetic-index.jsonl"
  rh_check() {  # metrics-json -> "OK" if every expected aggregate matches, else "FAIL <json>"
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
ok = (
  d["runs"] == 6 and d["ok"] == 3 and d["failed"] == 3 and abs(d["success_rate"] - 0.5) < 1e-9
  and d["error_class"] == {"ok": 3, "transient": 1, "auth": 1, "timeout": 1}
  and d["fallback"]["count"] == 2 and abs(d["fallback"]["rate"] - 1.0 / 3) < 1e-6
  and d["sec"]["min"] == 1 and d["sec"]["max"] == 10 and abs(d["sec"]["mean"] - 31.0 / 6) < 1e-5
  and d["bytes"]["min"] == 50 and d["bytes"]["max"] == 500 and abs(d["bytes"]["mean"] - 1550.0 / 6) < 1e-5
  and d["tokens"]["counted"] == 3 and d["tokens"]["unavailable"] == 3 and d["tokens"]["sum"] == 6000 and abs(d["tokens"]["mean"] - 2000) < 1e-9
  and d["cost"]["counted"] == 3 and d["cost"]["unavailable"] == 3 and abs(d["cost"]["sum"] - 1.0) < 1e-6
)
print("OK" if ok else "FAIL " + json.dumps(d))
' "$1"
  }
  if command -v jq >/dev/null 2>&1; then
    assert_contains "trends[jq]: exact aggregates over synthetic index" "$(rh_check "$(bash "$RH" --json "$TFIX" 2>/dev/null)")" "OK"
  else
    skip "trends oracle (jq backend: jq unavailable)"
  fi
  trestr="$(mktemp -d)"; mk_restricted_bin "$trestr"   # python3, NO jq -> forces the python3 backend
  assert_contains "trends[py]: exact aggregates over synthetic index" "$(rh_check "$(PATH="$trestr/bin" "$trestr/bin/bash" "$RH" --json "$TFIX" 2>/dev/null)")" "OK"
  # Read-only: the committed fixture must be byte-identical after the analytic runs under both backends.
  rh_before="$(cksum "$TFIX")"
  bash "$RH" --json "$TFIX" >/dev/null 2>&1
  PATH="$trestr/bin" "$trestr/bin/bash" "$RH" --json "$TFIX" >/dev/null 2>&1
  rh_after="$(cksum "$TFIX")"
  rm -rf "$trestr"
  if [ "$rh_before" = "$rh_after" ]; then
    ok "trends: synthetic index byte-identical after the analytic (read-only)"
  else
    bad "trends: synthetic index byte-identical after the analytic (read-only)" "checksum changed"
  fi
else
  skip "run-history analytics trends oracle (python3 unavailable)"
fi

echo "== run-history analytics filters (--agent/--project/--since/--until; both backends; AND-compose) =="
# The report scopes WHICH rows are aggregated via four AND-composed filters over existing per-row
# fields (agent/project/timestamp); an absent/empty filter selects everything. Both backends apply the
# IDENTICAL keep predicate, so the filtered run-count is value-equivalent across jq and python3.
if command -v python3 >/dev/null 2>&1; then
  RHF="$ROOT/scripts/run-history-report.sh"
  ffix="$(mktemp -d)"; FIDX="$ffix/index.jsonl"
  printf '%s\n' \
    '{"run_id":"a","timestamp":"2026-06-01T00:00:00Z","project":"proj-a","agent":"agy","rc":0,"sec":2,"bytes":100,"error_class":"ok"}' \
    '{"run_id":"a","timestamp":"2026-06-01T00:00:00Z","project":"proj-a","agent":"codex","rc":0,"sec":4,"bytes":200,"error_class":"ok"}' \
    '{"run_id":"b","timestamp":"2026-06-10T00:00:00Z","project":"proj-b","agent":"codex","rc":1,"sec":6,"bytes":50,"error_class":"transient"}' >"$FIDX"
  frestr="$(mktemp -d)"; mk_restricted_bin "$frestr"   # python3, NO jq -> forces the python3 backend
  f_eq() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi; }
  f_runs() {  # backend(jq|py) filter-args... -> the "runs" count of the filtered aggregate
    local be="$1"; shift
    if [ "$be" = py ]; then PATH="$frestr/bin" "$frestr/bin/bash" "$RHF" --json "$@" "$FIDX" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["runs"])'
    else bash "$RHF" --json "$@" "$FIDX" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["runs"])'; fi
  }
  for be in jq py; do
    if [ "$be" = jq ] && ! command -v jq >/dev/null 2>&1; then skip "filters[jq] (jq unavailable)"; continue; fi
    f_eq "filters[$be]: global aggregates all rows"           3 "$(f_runs "$be")"
    f_eq "filters[$be]: --agent codex scopes to that agent"   2 "$(f_runs "$be" --agent codex)"
    f_eq "filters[$be]: --project proj-a scopes to project"   2 "$(f_runs "$be" --project proj-a)"
    f_eq "filters[$be]: --since excludes earlier rows"        1 "$(f_runs "$be" --since 2026-06-05T00:00:00Z)"
    f_eq "filters[$be]: --until excludes later rows"          2 "$(f_runs "$be" --until 2026-06-05T00:00:00Z)"
    f_eq "filters[$be]: agent+project AND-compose"            1 "$(f_runs "$be" --agent codex --project proj-b)"
    f_eq "filters[$be]: empty --agent selects everything"     3 "$(f_runs "$be" --agent '')"
  done
  # Read-only: the index fixture must be byte-identical after a filtered analytic run.
  f_before="$(cksum "$FIDX")"; bash "$RHF" --json --agent codex "$FIDX" >/dev/null 2>&1; f_after="$(cksum "$FIDX")"
  f_eq "filters: index byte-identical after a filtered analytic (read-only)" "$f_before" "$f_after"
  rm -rf "$ffix" "$frestr"
else
  skip "run-history analytics filters oracle (python3 unavailable)"
fi

echo "== arg parsing: a value-taking flag with no value exits 2, never hangs (regression) =="
# Regression for 8499333: a value-taking flag passed as the FINAL arg made `shift 2` a no-op (bash
# leaves the positional parameters unchanged when the shift count exceeds $#), so the
# `while [ $# -gt 0 ]` arg loop spun forever. Each affected flag must now exit 2 (a clean usage error),
# never hang — a `timeout` kill (exit 124) is the regression signal. Offline, no CLI, no network.
vf_rc() {  # script-relpath flag -> exit code of `<script> <flag>` (no value), killed at 5s if it hangs
  timeout 5 bash "$ROOT/scripts/$1" "$2" >/dev/null 2>&1; printf '%s' "$?"
}
for vf in "run-history-report.sh:--since" "run-history-report.sh:--agent" \
          "run-history-report.sh:--project" "run-history-report.sh:--until" \
          "run-pipeline.sh:--pipeline" "run-pipeline.sh:--prompt" \
          "run-history-maintain.sh:--base" \
          "run-agent.sh:--agent" "run-agent.sh:--prompt" \
          "run-agent.sh:--target" "run-agent.sh:--timeout"; do
  vf_scr="${vf%%:*}"; vf_flg="${vf##*:}"
  assert_exit "missing value flag exits 2, never hangs: $vf_scr $vf_flg" 2 "$(vf_rc "$vf_scr" "$vf_flg")"
done

echo "== run-history malformed-row tolerance (jq/python3 parity on a torn append; read-only) =="
# A crashed/torn append can leave the append-only index with a final unparseable line. Both backends
# must skip it and still report (the header's "value-equivalent JSON" contract) — never abort. This is
# the regression guard for the jq backend, which used `jq -s` (whole-file slurp that aborts on ANY
# malformed line) before being switched to a line-by-line `inputs | fromjson?` slurp.
if command -v python3 >/dev/null 2>&1; then
  RHM="$ROOT/scripts/run-history-report.sh"
  mbase="$(mktemp -d)"
  printf '%s\n' '{"error_class":"ok","rc":0,"sec":3,"bytes":100,"signals":{"tokens":50}}' >"$mbase/index.jsonl"
  printf '%s\n' '{"error_class":"ok","rc":0,"sec":5,"bytes":' >>"$mbase/index.jsonl"   # torn final line
  m_runs() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runs"))' 2>/dev/null; }
  mrestr="$(mktemp -d)"; mk_restricted_bin "$mrestr"   # python3, NO jq -> forces the python3 backend
  m_py="$(PATH="$mrestr/bin" "$mrestr/bin/bash" "$RHM" --json "$mbase/index.jsonl" 2>/dev/null)"; m_py_rc=$?
  m_runs_py="$(m_runs "$m_py")"
  assert_exit     "malformed[py]: report still exits 0 over a torn index" 0 "$m_py_rc"
  assert_contains "malformed[py]: the valid row is still counted (runs=1)" "$m_runs_py" "1"
  if command -v jq >/dev/null 2>&1; then
    m_jq="$(bash "$RHM" --json "$mbase/index.jsonl" 2>/dev/null)"; m_jq_rc=$?
    m_runs_jq="$(m_runs "$m_jq")"
    assert_exit     "malformed[jq]: report still exits 0 over a torn index (no abort)" 0 "$m_jq_rc"
    assert_contains "malformed[jq]: the valid row is still counted (runs=1)" "$m_runs_jq" "1"
    if [ "$m_runs_jq" = "$m_runs_py" ]; then
      ok "malformed: jq and python3 agree on runs over a torn index (value-equivalent)"
    else
      bad "malformed: jq and python3 agree on runs over a torn index" "jq=$m_runs_jq py=$m_runs_py"
    fi
  else
    skip "malformed[jq] tolerance (jq unavailable)"
  fi
  rm -rf "$mrestr" "$mbase"
else
  skip "run-history malformed-row tolerance oracle (python3 unavailable)"
fi

echo "== additive-field tolerance: analytics + maintenance tolerate legacy rows (missing optional fields) =="
# The additive-only run-record contract means an OLD index row predating error_class/attempts/retried/
# signals must still aggregate and maintain cleanly — absence is never an error. The synthetic fixture
# rows all carry the newer fields; feed a legacy-shaped row (only the original control-plane scalars)
# alongside a modern row and assert the report counts BOTH (exit 0) and maintenance tolerates it (exit 0).
if command -v python3 >/dev/null 2>&1; then
  legdir="$(mktemp -d)"; legidx="$legdir/index.jsonl"
  printf '%s\n' '{"run_id":"old1","timestamp":"2026-01-01T00:00:00Z","project":"p","agent":"codex","model":"m","tier":"high","effort":"high","mode":"readonly","target":"/t","rc":0,"sec":3,"bytes":120,"fallback":false}'  >"$legidx"
  # shellcheck disable=SC2016  # literal JSON row; the $-prefixed cost string is fixture data, not a shell expansion
  printf '%s\n' '{"run_id":"new1","timestamp":"2026-06-01T00:00:00Z","project":"p","agent":"codex","model":"m","tier":"high","effort":"high","mode":"readonly","target":"/t","rc":1,"sec":4,"bytes":130,"fallback":false,"error_class":"transient","attempts":2,"retried":true,"signals":{"tokens":900,"cost":"$0.05"}}' >>"$legidx"
  leg_json="$(bash "$ROOT/scripts/run-history-report.sh" --json "$legidx" 2>/dev/null)"; leg_rc=$?
  leg_runs="$(printf '%s' "$leg_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runs"))' 2>/dev/null)"
  assert_exit     "additive-tolerance[report]: legacy row aggregates without error (exit 0)" 0 "$leg_rc"
  assert_contains "additive-tolerance[report]: legacy + modern rows both counted (runs=2)"   "$leg_runs" "2"
  EXTERNAL_AGENTS_OUT="$legdir" bash "$ROOT/scripts/run-history-maintain.sh" --force >/dev/null 2>&1
  assert_exit "additive-tolerance[maintain]: tolerates a legacy row (exit 0)" 0 "$?"
  rm -rf "$legdir"
else
  skip "additive-field tolerance oracle (python3 unavailable)"
fi

echo "== run-history recoverability + rotation oracle (backup/restore content-identity; offline) =="
# Drill the RUNBOOK.md backup/restore + rotation procedures over a committed fixture in a DISPOSABLE
# base (under mktemp, never the repo): back up -> corrupt -> restore -> assert content-identical (+
# schema conformance); then rotate and assert the archive holds the rows and the fresh index keeps
# appending. No row loss; all writes stay under the temp base.
if command -v python3 >/dev/null 2>&1; then
  RFIX="$ROOT/tests/fixtures/recoverability-index.jsonl"
  rbase="$(mktemp -d)"; mkdir -p "$rbase/archive"
  cp "$RFIX" "$rbase/index.jsonl"
  rorig="$(cksum "$rbase/index.jsonl")"
  cp -p "$rbase/index.jsonl" "$rbase/archive/index-backup.jsonl"   # backup (RUNBOOK: cp)
  printf 'CORRUPTED GARBAGE\n' >"$rbase/index.jsonl"               # corrupt
  cp -p "$rbase/archive/index-backup.jsonl" "$rbase/index.jsonl"   # restore (RUNBOOK: cp back, byte-for-byte)
  if [ "$rorig" = "$(cksum "$rbase/index.jsonl")" ]; then
    ok "recover: restored index is content-identical to the original (checksum)"
  else
    bad "recover: restored index is content-identical to the original (checksum)" "checksum differs"
  fi
  if cmp -s "$RFIX" "$rbase/index.jsonl"; then
    ok "recover: restored index byte-matches the committed fixture"
  else
    bad "recover: restored index byte-matches the committed fixture" "cmp differs"
  fi
  if python3 -c 'import jsonschema' >/dev/null 2>&1; then
    rconf="$(SC_SCHEMA="$ROOT/schema/run-record.schema.json" python3 -c '
import json, os, sys
from jsonschema import Draft7Validator
v = Draft7Validator(json.load(open(os.environ["SC_SCHEMA"])))
bad = 0
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln:
        continue
    if list(v.iter_errors(json.loads(ln))):
        bad += 1
print("OK" if bad == 0 else "FAIL %d" % bad)' "$rbase/index.jsonl" 2>/dev/null)"
    assert_contains "recover: restored rows conform to the run-record schema" "$rconf" "OK"
  else
    skip "recover: schema conformance (jsonschema unavailable)"
  fi
  # Rotation case: force-rotate, the archive holds all rows, the fresh index keeps appending.
  rbefore="$(wc -l <"$rbase/index.jsonl" | tr -d ' ')"
  EXTERNAL_AGENTS_OUT="$rbase" bash "$ROOT/scripts/run-history-maintain.sh" --force >/dev/null 2>&1
  rarc="$(find "$rbase/archive" -name 'index-2*.jsonl' 2>/dev/null | sort -r | head -1)"
  rarc_rows="$(wc -l <"$rarc" 2>/dev/null | tr -d ' ')"
  if [ -n "$rbefore" ] && [ "$rarc_rows" = "$rbefore" ]; then
    ok "rotation: archive holds all rotated rows (no loss, $rarc_rows rows)"
  else
    bad "rotation: archive holds all rotated rows (no loss)" "archive=$rarc_rows before=$rbefore"
  fi
  printf '{"appended":1}\n' >>"$rbase/index.jsonl"
  if [ "$(wc -l <"$rbase/index.jsonl" | tr -d ' ')" = "1" ]; then
    ok "rotation: fresh index keeps appending after rotation"
  else
    bad "rotation: fresh index keeps appending after rotation" "unexpected row count"
  fi
  case "$rbase/" in
    "$ROOT/"*) bad "rotation: writes stay outside the repo" "temp base is inside the repo";;
    *)         ok "rotation: writes stay outside the repo";;
  esac
  rm -rf "$rbase"
else
  skip "recoverability + rotation oracle (python3 unavailable)"
fi

echo "== run-history prune keeps newest by mtime (same-second rotation collision; offline) =="
# Regression: KEEP-based prune must keep the most-RECENT archives. A same-second rotation names the
# second file index-<ts>.1.jsonl, which sorts BEFORE the base index-<ts>.jsonl lexicographically, so a
# name sort would keep the older and prune the newer. Pre-create a collision pair with disagreeing
# name/mtime order (the `.1` file NEWER by mtime), rotate once with KEEP=2, and assert the mtime-newer
# archive survives while the oldest is pruned.
pbase="$(mktemp -d)"; mkdir -p "$pbase/archive"
pts=20260101T000000Z
touch -d '2026-01-01T00:00:00Z' "$pbase/archive/index-$pts.jsonl"
touch -d '2026-01-01T00:00:30Z' "$pbase/archive/index-$pts.1.jsonl"
printf '{"rc":0}\n' >"$pbase/index.jsonl"
EXTERNAL_AGENTS_ARCHIVE_KEEP=2 bash "$ROOT/scripts/run-history-maintain.sh" --base "$pbase" --force >/dev/null 2>&1
if [ -e "$pbase/archive/index-$pts.1.jsonl" ]; then
  ok "prune: keeps the mtime-newer collision archive (index-<ts>.1.jsonl survives)"
else
  bad "prune: keeps the mtime-newer collision archive" "the newer .1 archive was pruned (name-sort bug)"
fi
if [ -e "$pbase/archive/index-$pts.jsonl" ]; then
  bad "prune: drops the oldest archive past KEEP" "the oldest archive survived (KEEP=2 over 3 archives)"
else
  ok "prune: drops the oldest archive past KEEP (mtime order)"
fi
rm -rf "$pbase"

echo "== run-history rotation threshold boundary (empty/missing no-op; rotate strictly > MAX) =="
# The rotation oracles above use --force, which BYPASSES the threshold decision. This pins the trigger
# itself (scripts/run-history-maintain.sh): a missing or empty index is NEVER rotated, and a row/byte
# threshold rotates strictly ABOVE the maximum (> MAX via -gt), not at or below it. Offline; temp base.
RHMB="$ROOT/scripts/run-history-maintain.sh"
tb_arc_count() { find "$1/archive" -name 'index-2*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }
tb1="$(mktemp -d)"   # (1) missing index -> no-op
EXTERNAL_AGENTS_INDEX_MAX_ROWS=2 bash "$RHMB" --base "$tb1" >/dev/null 2>&1; tb1_rc=$?
assert_exit     "threshold: missing index is a no-op (exit 0)" 0 "$tb1_rc"
assert_contains "threshold: missing index creates no archive" "$(tb_arc_count "$tb1")" "0"
tb2="$(mktemp -d)"; : >"$tb2/index.jsonl"   # (2) empty index -> never rotated
EXTERNAL_AGENTS_INDEX_MAX_ROWS=2 bash "$RHMB" --base "$tb2" >/dev/null 2>&1
assert_contains "threshold: empty index is never rotated (no archive)" "$(tb_arc_count "$tb2")" "0"
tb3="$(mktemp -d)"; printf '{"rc":0}\n{"rc":0}\n' >"$tb3/index.jsonl"   # (3) rows == MAX -> no rotation
EXTERNAL_AGENTS_INDEX_MAX_ROWS=2 bash "$RHMB" --base "$tb3" >/dev/null 2>&1
assert_contains "threshold: rows == MAX does not rotate (strict > boundary)" "$(tb_arc_count "$tb3")" "0"
tb4="$(mktemp -d)"; printf '{"rc":0}\n{"rc":0}\n{"rc":0}\n' >"$tb4/index.jsonl"   # (4) rows > MAX -> rotate
EXTERNAL_AGENTS_INDEX_MAX_ROWS=2 bash "$RHMB" --base "$tb4" >/dev/null 2>&1
tb4_arc="$(find "$tb4/archive" -name 'index-2*.jsonl' 2>/dev/null | sort -r | head -1)"
tb4_arc_rows="$(wc -l <"$tb4_arc" 2>/dev/null | tr -d ' ')"
tb4_fresh_rows="$(wc -l <"$tb4/index.jsonl" 2>/dev/null | tr -d ' ')"
if [ "$tb4_arc_rows" = "3" ] && [ "$tb4_fresh_rows" = "0" ]; then
  ok "threshold: rows > MAX rotates (3 rows archived, fresh index emptied)"
else
  bad "threshold: rows > MAX rotates" "archive=$tb4_arc_rows fresh=$tb4_fresh_rows"
fi
rm -rf "$tb1" "$tb2" "$tb3" "$tb4"

echo "== run-history-maintain containment (repo working tree untouched by any lifecycle op) =="
# The rotation oracles assert the temp BASE path is outside the repo. This is the stronger, EMPIRICAL
# containment guard: snapshot the repo's tracked working tree, run maintain (rotate + prune) under a
# temp base, and assert the tracked tree is unchanged — catching any stray write to a hardcoded repo
# path that an outside-base path check would miss. Compares git status before/after, so a pre-existing
# uncommitted edit (e.g. this test file mid-run) is identical on both sides and never a false failure.
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cbase="$(mktemp -d)"; printf '{"rc":0}\n{"rc":0}\n{"rc":0}\n' >"$cbase/index.jsonl"
  c_before="$(git -C "$ROOT" status --porcelain --untracked-files=no)"
  EXTERNAL_AGENTS_INDEX_MAX_ROWS=2 EXTERNAL_AGENTS_ARCHIVE_KEEP=1 bash "$ROOT/scripts/run-history-maintain.sh" --base "$cbase" --force >/dev/null 2>&1
  c_after="$(git -C "$ROOT" status --porcelain --untracked-files=no)"
  if [ "$c_before" = "$c_after" ]; then
    ok "containment: run-history-maintain leaves the repo's tracked working tree unchanged"
  else
    bad "containment: run-history-maintain leaves the repo's tracked working tree unchanged" "git status changed during maintain"
  fi
  rm -rf "$cbase"
else
  skip "run-history-maintain containment guard (git unavailable / not a work tree)"
fi

echo "== Phase 8 resilience field parity + schema (error_class/attempts/retried; both backends) =="
# Consolidation: the Phase 8.2 resilience fields must be PRESENT, correctly TYPED, parity-identical
# across jq/python3, AND schema-valid. The emitter-parity block compares the whole record, but a field
# dropped from BOTH backends would still compare equal there — so assert these fields explicitly.
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  p8stub="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "resp"\n' >"$p8stub/codex"; chmod +x "$p8stub/codex"
  p8restr="$(mktemp -d)"; mk_restricted_bin "$p8restr"   # python3, NO jq -> forces the python3 backend
  p8_fields() {  # bashbin pathprefix -> "<error_class> <attempts> <retried> <types> <schema>"
    local bb="$1" pp="$2" tg od
    tg="$(mktemp -d)"; od="$(mktemp -d)"
    PATH="$p8stub:$pp" EXTERNAL_AGENTS_OUT="$od" "$bb" "$RUN" --agent codex --effort high --read-only --target "$tg" --prompt x >/dev/null 2>&1
    P8_SCHEMA="$ROOT/schema/run-record.schema.json" python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
ec = d.get("error_class"); at = d.get("attempts"); rt = d.get("retried")
types = isinstance(ec, str) and isinstance(at, int) and isinstance(rt, bool)
sok = "schema-skip"
try:
    from jsonschema import Draft7Validator
    v = Draft7Validator(json.load(open(os.environ["P8_SCHEMA"])))
    sok = "schema-ok" if not list(v.iter_errors(d)) else "schema-bad"
except ImportError:
    pass
print(ec, at, rt, "types-ok" if types else "types-bad", sok)
' "$od/$(basename "$tg")/codex.meta.json" 2>/dev/null
    rm -rf "$tg" "$od"
  }
  if python3 -c 'import jsonschema' >/dev/null 2>&1; then p8exp="ok 1 False types-ok schema-ok"; else p8exp="ok 1 False types-ok schema-skip"; fi
  p8jq="$(p8_fields "bash" "$PATH")"
  p8py="$(p8_fields "$p8restr/bin/bash" "$p8restr/bin")"
  rm -rf "$p8stub" "$p8restr"
  assert_contains "phase8 parity: jq backend resilience fields present, typed, schema-valid"     "$p8jq" "$p8exp"
  assert_contains "phase8 parity: python3 backend resilience fields present, typed, schema-valid" "$p8py" "$p8exp"
  if [ "$p8jq" = "$p8py" ]; then
    ok "phase8 parity: resilience fields identical across jq/python3"
  else
    bad "phase8 parity: resilience fields identical across jq/python3" "jq=[$p8jq] py=[$p8py]"
  fi
else
  skip "Phase 8 resilience field parity (jq/python3/timeout unavailable)"
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
  skip "redaction tests (timeout unavailable)"
fi

echo "== transcript redaction: per-pattern coverage (each redact() rule has a synthetic-fixture oracle) =="
# redact() in scripts/run-agent.sh masks several length-bounded secret-shaped patterns; the block
# above only exercises sk-. Give EACH rule a synthetic fixture so narrowing any one pattern fails
# offline. Synthetic tokens only — never a real secret; matched values are never printed.
if command -v timeout >/dev/null 2>&1; then
  red_case() {  # label  synthetic-token
    local label="$1" tok="$2" out file rf
    rf="$(mktemp)"
    out="$(run_stub_transcript "leak $tok here" "$rf")"
    file="$(cat "$rf")"; rm -f "$rf"
    if printf '%s' "$out"  | grep -qF -- "$tok"; then bad "redaction[$label]: raw token absent from echoed transcript"    "leaked to stdout"; return; fi
    if printf '%s' "$file" | grep -qF -- "$tok"; then bad "redaction[$label]: raw token absent from persisted transcript" "leaked to disk";   return; fi
    assert_contains "redaction[$label]: placeholder present after masking" "$out" "<REDACTED>"
  }
  red_case "pk-token"     "pk-ABCDEFGHIJKLMNOPQRSTUV0123456789"
  red_case "gh-token"     "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  red_case "github_pat"   "github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  red_case "xox-slack"    "xoxb-ABCDEFGHIJ-KLMNOPQRSTUV"
  red_case "aws-akia"     "AKIAABCDEFGHIJKLMNOP"
  red_case "bearer"       "Bearer ABCDEFGHIJKLMNOPQRSTUVWX0123456789"
  red_case "assignment"   "API_SECRET=abcdef0123456789xyz"
  red_case "high-entropy" "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123456789KLMN"
else
  skip "per-pattern redaction tests (timeout unavailable)"
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
  skip "redaction guard tests (timeout unavailable)"
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
  skip "redaction assurance tests (timeout unavailable)"
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
  skip "redaction no-false-positive assurance (timeout unavailable)"
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
  skip "post-write verification test (timeout unavailable)"
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
  skip "live-argv-record test (timeout unavailable)"
fi

echo "== driver argv matrix: masked launch argv == --dry-run argv across modes × prompt sources =="
# The live argv_equiv matrix (tests/live-smoke.sh) proves, per agent, that the REAL launch argv equals
# the --dry-run argv across read-only/read-write × --prompt/--prompt-file. Pin the same coverage OFFLINE
# (stub codex, no real CLI) so a regression that drops a mode or a prompt source from the argv path
# fails the gate — not only the single read-only/--prompt case the block above covers. Each case also
# re-asserts the prompt is masked to <PROMPT> in the record (no secret leak via either prompt source).
if command -v timeout >/dev/null 2>&1; then
  amx_stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\ntrue\n' >"$amx_stub/codex"; chmod +x "$amx_stub/codex"
  amx_pf="$(mktemp)"; printf '%s' "MATRIX-PROMPT-SECRET" >"$amx_pf"
  amx_check() {  # mode-flag yes-flag prompt-source label
    local modeflag="$1" yes="$2" src="$3" label="$4" tgt out rec dry
    local p=() pargs=()
    [ -n "$yes" ] && p=("$yes")
    if [ "$src" = "prompt-file" ]; then pargs=(--prompt-file "$amx_pf"); else pargs=(--prompt "MATRIX-PROMPT-SECRET"); fi
    tgt="$(mktemp -d)"; out="$(mktemp -d)"
    PATH="$amx_stub:$PATH" EXTERNAL_AGENTS_OUT="$out" \
      bash "$RUN" --agent codex "$modeflag" "${p[@]}" --target "$tgt" --timeout 30 "${pargs[@]}" >/dev/null 2>&1
    rec="$(cat "$out/$(basename "$tgt")/codex.argv" 2>/dev/null)"
    dry="$(bash "$RUN" --agent codex "$modeflag" "${p[@]}" --target "$tgt" --dry-run "${pargs[@]}" 2>/dev/null | sed -nE 's/^  codex +//p')"
    if [ -n "$rec" ] && [ "$rec" = "$dry" ]; then ok "argv-matrix: $label  launch == dry-run"; else bad "argv-matrix: $label launch == dry-run" "rec=[$rec] dry=[$dry]"; fi
    case "$rec" in *"MATRIX-PROMPT-SECRET"*) bad "argv-matrix: $label prompt masked (no leak)" "prompt text leaked into the argv record";; *) ok "argv-matrix: $label prompt masked (no leak)";; esac
    rm -rf "$tgt" "$out"
  }
  amx_check --read-only ""     prompt      "read-only/--prompt"
  amx_check --read-only ""     prompt-file "read-only/--prompt-file"
  amx_check --write     --yes  prompt      "read-write/--prompt"
  amx_check --write     --yes  prompt-file "read-write/--prompt-file"
  rm -f "$amx_pf"; rm -rf "$amx_stub"
  unset -f amx_check
else
  skip "driver argv matrix oracle (timeout unavailable)"
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
  skip "argv-record secret-safety test (timeout unavailable)"
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
  skip "enforced non-mutation test (timeout unavailable)"
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
  skip "agy best-effort report test (timeout unavailable)"
fi

echo "== live-smoke verdict helpers (offline unit tests of the pass/fail logic) =="
# The pure helpers that decide a live run's verdict (enforced_readonly / mutation_outcome /
# transcript_ok, sourced from tests/live-smoke.sh in the sandbox-fixture block above) are otherwise
# only exercised during an opt-in live run. Pin their verdicts offline so a regression fails the gate.
# enforced_readonly: codex/claude/cursor are HARD-enforced (0); agy is best-effort only (non-zero).
for a in codex claude cursor; do
  if enforced_readonly "$a"; then ok "enforced_readonly: $a is enforced"; else bad "enforced_readonly: $a is enforced" "returned non-zero"; fi
done
if enforced_readonly agy; then bad "enforced_readonly: agy is best-effort (not enforced)" "returned 0"; else ok "enforced_readonly: agy is best-effort (not enforced)"; fi
# mutation_outcome: an enforced agent hard-fails on any change; agy reports but never fails.
mutation_outcome codex ""        >/dev/null 2>&1; assert_exit "mutation_outcome: enforced + no change -> ok (0)" 0 "$?"
mutation_outcome codex "M f.txt" >/dev/null 2>&1; assert_exit "mutation_outcome: enforced + change -> fail (1)"  1 "$?"
mutation_outcome agy ""          >/dev/null 2>&1; assert_exit "mutation_outcome: agy + no change -> ok (0)"      0 "$?"
mutation_outcome agy "M f.txt"   >/dev/null 2>&1; assert_exit "mutation_outcome: agy + change -> still ok (0)"   0 "$?"
# transcript_ok: success only when rc==0 AND the transcript carries bytes.
vproj="$(mktemp -d)"
printf '0\n' >"$vproj/codex.rc"; printf 'some response\n' >"$vproj/codex.md"
transcript_ok "$vproj" codex >/dev/null 2>&1; assert_exit "transcript_ok: rc=0 + bytes>0 -> ok (0)" 0 "$?"
printf '1\n' >"$vproj/codex.rc"
transcript_ok "$vproj" codex >/dev/null 2>&1; assert_exit "transcript_ok: rc!=0 -> fail (1)" 1 "$?"
printf '0\n' >"$vproj/codex.rc"; : >"$vproj/codex.md"
transcript_ok "$vproj" codex >/dev/null 2>&1; assert_exit "transcript_ok: empty transcript -> fail (1)" 1 "$?"
rm -rf "$vproj"

echo "== live-smoke status-record shape (stub AGENT_STATUS, no real CLI) =="
# Pin the deterministic shape of $LIVE_OUT/status.txt (and its content-free provenance sibling) that
# write_status_record emits: one '<agent>  <status>' line per KNOWN_AGENTS entry, fixed order, only
# vocabulary tokens, a stable two-field format, and NO transcript/secret text. Drive the sourced
# helper with a synthetic AGENT_STATUS map and a temp LIVE_OUT (never the real $HOME) — launches no CLI.
srdir="$(mktemp -d)"
(
  # shellcheck disable=SC2034  # LIVE_OUT is read by write_status_record via dynamic scope
  LIVE_OUT="$srdir/live-smoke"
  # shellcheck disable=SC2034  # AGENT_STATUS is read by write_status_record via dynamic scope
  declare -A AGENT_STATUS=( [agy]=live-verified [codex]=failed [claude]=skipped-not-reachable [cursor]=skipped-scoped-out )
  write_status_record >/dev/null 2>&1
)
srf="$srdir/live-smoke/status.txt"
sr_lines="$(wc -l <"$srf" 2>/dev/null | tr -d ' ')"
assert_exit "status-record: one line per known agent (4)" 4 "${sr_lines:-0}"
sr_order="$(awk '{printf "%s ", $1}' "$srf" 2>/dev/null | sed 's/ $//')"
assert_contains "status-record: agents in KNOWN_AGENTS order" "$sr_order" "agy codex claude cursor"
sr_bad="$(awk '{print $2}' "$srf" 2>/dev/null | grep -vxE 'live-verified|failed|reachable|skipped-not-reachable|skipped-scoped-out|skipped-not-opted-in|unknown' | head -1)"
if [ -z "$sr_bad" ]; then ok "status-record: only documented vocabulary tokens"; else bad "status-record: only documented vocabulary tokens" "non-vocabulary token: $sr_bad"; fi
if awk 'NF!=2{exit 1}' "$srf" 2>/dev/null; then ok "status-record: two-field deterministic format"; else bad "status-record: two-field deterministic format" "a line was not '<agent> <status>'"; fi
if grep -qiE 'token|api[_-]?key|secret|bearer|password|stub response|stub transcript|[0-9]+%|remainingPercentage' "$srdir"/live-smoke/*.txt 2>/dev/null; then
  bad "status-record: control-plane only (no transcript/secret text)" "secret/transcript-shaped text leaked into the record set"
else
  ok "status-record: control-plane only (no transcript/secret text)"
fi
rm -rf "$srdir"

echo "== install-smoke helpers (offline unit tests; sourced, no remote, no agent CLI) =="
# install-smoke.sh is sourceable so its release-verification helpers can be unit-tested offline,
# mirroring the live-smoke helper tests above. No agent CLI is launched (--version prints the version,
# --check is a presence preflight) and the clone is a LOCAL clone of $ROOT — fully offline.
# shellcheck source=/dev/null  # dynamic absolute-path source, not followed by shellcheck
. "$ROOT/tests/install-smoke.sh"
if command -v git >/dev/null 2>&1; then
  is_iv="$(installed_version "$ROOT")"
  case "$is_iv" in
    [0-9]*.[0-9]*.[0-9]*) ok "install-smoke: installed_version lifts a semver from --version ($is_iv)";;
    *)                    bad "install-smoke: installed_version lifts a semver from --version" "got '$is_iv'";;
  esac
  is_nt="$(newest_tag)"
  if [ -n "$is_nt" ]; then
    is_pt="$(previous_tag)"
    if [ -z "$is_pt" ] || [ "$(printf '%s\n%s\n' "$is_pt" "$is_nt" | sort -V | tail -1)" = "$is_nt" ]; then
      ok "install-smoke: newest_tag orders >= previous_tag by version ($is_pt <= $is_nt)"
    else
      bad "install-smoke: newest_tag orders >= previous_tag by version" "newest=$is_nt previous=$is_pt"
    fi
    is_co="$(mktemp -d)"
    is_vout="$(clone_at_tag "$is_nt" "$is_co/co" && verify_install "$is_co/co" 2>&1)"; is_vrc=$?
    assert_exit     "install-smoke: verify_install passes on a local clone at $is_nt (offline)" 0 "$is_vrc"
    assert_contains "install-smoke: verify_install ran the --check presence preflight"          "$is_vout" "presence preflight"
    rm -rf "$is_co"
  else
    skip "install-smoke: tag helpers (no vX.Y.Z tag in this checkout)"
  fi
else
  skip "install-smoke: helper unit tests (git unavailable)"
fi

echo "== agy quota-schema evidence is sanitised (keys/types only, no value/account-id) =="
# quota_probe writes $LIVE_OUT/agy-quota-schema.txt as a content-free drift detector for the keys
# agy_model_status reads — key NAMES, types, and array item-key NAMES only, NEVER a percentage value
# or account identifier. Drive the REAL writer offline (sourced quota_probe, synthetic quota payload
# via AGY_QUOTA_CMD) with a payload carrying a percentage and an account-id-shaped value, and assert
# neither leaks; an empty/unusable payload must be recorded as 'unavailable' (degraded, non-failing).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  qs_lo="$(mktemp -d)"; qs_json="$(mktemp)"
  printf '%s' '{"label":"acct-SECRET-9999","models":[{"label":"Claude","remainingPercentage":37.5,"isExhausted":false}]}' >"$qs_json"
  LIVE_OUT="$qs_lo/live-smoke" AGY_QUOTA_CMD="cat $qs_json" EXTERNAL_AGENTS_AGY_QUOTA_CMD="cat $qs_json" \
    quota_probe >/dev/null 2>&1 || true
  qs_shape="$(cat "$qs_lo/live-smoke/agy-quota-schema.txt" 2>/dev/null)"
  assert_contains "quota-schema: records the read key names (drift detector)" "$qs_shape" "remainingPercentage"
  assert_contains "quota-schema: records array item-key names"                 "$qs_shape" "item-keys="
  case "$qs_shape" in *37.5*)             bad "quota-schema: no percentage VALUE leaks"   "percentage value 37.5 leaked into evidence";;  *) ok "quota-schema: no percentage VALUE leaks";;  esac
  case "$qs_shape" in *acct-SECRET-9999*) bad "quota-schema: no account identifier leaks" "account id leaked into evidence";;             *) ok "quota-schema: no account identifier leaks";; esac
  qs_lo2="$(mktemp -d)"
  LIVE_OUT="$qs_lo2/live-smoke" AGY_QUOTA_CMD="true" EXTERNAL_AGENTS_AGY_QUOTA_CMD="true" \
    quota_probe >/dev/null 2>&1 || true
  qs_empty="$(cat "$qs_lo2/live-smoke/agy-quota-schema.txt" 2>/dev/null)"
  assert_contains "quota-schema: empty quota output -> 'unavailable'" "$qs_empty" "unavailable"
  rm -f "$qs_json"; rm -rf "$qs_lo" "$qs_lo2"
else
  skip "agy quota-schema sanitisation oracle (timeout/python3 unavailable)"
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

echo "== release tag-gate oracle (RELEASING.md tag==version check; throwaway git fixture, real tags untouched) =="
# Extracts the canonical tag-check snippet from RELEASING.md "Verify the tag matches the version"
# and runs it against a DISPOSABLE git repo (under mktemp) in three states: a matching tag passes
# (exit 0, OK), a mismatched tag fails (exit 1, MISMATCH naming the expected version), and no
# exact-match tag reports a clear <none> diagnostic. RELEASING.md stays the single source of the
# check; this block is the offline regression guard. No tag is ever created on the real repository.
if command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  tg="$(mktemp -d)"
  awk '/^## Verify the tag matches the version/{f=1} f&&/^```bash/{c=1;next} c&&/^```/{exit} c{print}' "$ROOT/RELEASING.md" >"$tg/gate.sh"
  if [ -s "$tg/gate.sh" ]; then
    mkdir -p "$tg/.claude-plugin"
    printf '{\n  "version": "9.9.9"\n}\n' >"$tg/.claude-plugin/plugin.json"
    (
      cd "$tg" || exit 0
      git init -q
      git config user.email t@example.invalid; git config user.name t
      git config commit.gpgsign false; git config tag.gpgSign false
      git add -A; git commit -qm init
      { bash gate.sh; echo "RC=$?"; } >none.out 2>&1   # no exact-match tag yet
      git tag -a v9.9.9 -m x
      { bash gate.sh; echo "RC=$?"; } >ok.out 2>&1     # tag == v<version>
      git tag -d v9.9.9 >/dev/null; git tag -a v0.0.1 -m x
      { bash gate.sh; echo "RC=$?"; } >mis.out 2>&1    # tag != v<version>
    ) >/dev/null 2>&1
    none_out="$(cat "$tg/none.out" 2>/dev/null)"
    ok_out="$(cat "$tg/ok.out" 2>/dev/null)"
    mis_out="$(cat "$tg/mis.out" 2>/dev/null)"
    assert_contains "tag-gate: no exact-match tag reports <none>" "$none_out" "<none>"
    assert_contains "tag-gate: no-tag case exits non-zero"        "$none_out" "RC=1"
    assert_contains "tag-gate: matching tag v9.9.9 passes (OK)"   "$ok_out"   "OK: tag v9.9.9"
    assert_contains "tag-gate: matching tag exits 0"              "$ok_out"   "RC=0"
    assert_contains "tag-gate: mismatched tag reports MISMATCH"   "$mis_out"  "MISMATCH"
    assert_contains "tag-gate: mismatch names expected v9.9.9"    "$mis_out"  "!= v9.9.9"
    assert_contains "tag-gate: mismatch case exits non-zero"      "$mis_out"  "RC=1"
  else
    bad "release tag-gate oracle: could not extract the check from RELEASING.md" "snippet under '## Verify the tag matches the version' not found"
  fi
  rm -rf "$tg"
else
  skip "release tag-gate oracle (git/python3 unavailable)"
fi

echo "== plugin packaging oracle (required files + manifest fields + version lockstep; offline) =="
# A release must ship a LOADABLE plugin, not just a working driver. Assert the install-critical
# files exist, that .claude-plugin/plugin.json parses under BOTH jq and python3 (dual-backend
# parity, mirroring the agents.json schema block), that every required manifest field is present
# and non-empty, and that the manifest version equals the lockstep version. Offline, no CLI.
# MANIFEST_REQUIRED_FIELDS is the SINGLE SOURCE of the install-critical field set, shared by the
# distribution-manifest oracle and the field-contract negative-path assertion below so they cannot drift.
MANIFEST="$ROOT/.claude-plugin/plugin.json"
MANIFEST_REQUIRED_FIELDS=(name version description homepage repository license)
# manifest_field_gap MANIFEST_PATH — the SINGLE shared required-field check used by the packaging,
# negative-path, and distribution oracles below. Prints a space-prefixed list of
# MANIFEST_REQUIRED_FIELDS that are absent/empty in MANIFEST_PATH (empty output == all present), so
# removing a required field is caught identically wherever it is used (no per-oracle drift).
manifest_field_gap() {
  local mp="$1" k gap="" val
  for k in "${MANIFEST_REQUIRED_FIELDS[@]}"; do
    val="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("ok" if v not in (None,"") else "")' "$mp" "$k" 2>/dev/null)"
    [ "$val" = "ok" ] || gap="$gap $k"
  done
  printf '%s' "$gap"
}
pkg_required_files=(
  ".claude-plugin/plugin.json"
  "commands/external-agents.md"
  "skills/external-agents/SKILL.md"
  "scripts/run-agent.sh"
  "agents.json"
  "schema/agents.schema.json"
)
pkg_missing=""
for f in "${pkg_required_files[@]}"; do
  [ -f "$ROOT/$f" ] || pkg_missing="$pkg_missing $f"
done
if [ -z "$pkg_missing" ]; then
  ok "packaging: all required plugin files present"
else
  bad "packaging: all required plugin files present" "missing:$pkg_missing"
fi
# Dual-backend parse parity: both jq and python3 must read the same manifest version.
pkg_pv_py="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST" 2>/dev/null)"
assert_exit "packaging: plugin.json parses under python3" 0 "$?"
if command -v jq >/dev/null 2>&1; then
  pkg_pv_jq="$(jq -r .version "$MANIFEST" 2>/dev/null)"
  assert_exit "packaging: plugin.json parses under jq" 0 "$?"
  if [ "$pkg_pv_py" = "$pkg_pv_jq" ]; then
    ok "packaging: jq and python3 read the same manifest version"
  else
    bad "packaging: jq and python3 read the same manifest version" "py=$pkg_pv_py jq=$pkg_pv_jq"
  fi
else
  skip "packaging: jq parse parity (jq unavailable)"
fi
# Every required field present and non-empty — via the shared manifest_field_gap helper.
pkg_field_gap="$(manifest_field_gap "$MANIFEST")"
if [ -z "$pkg_field_gap" ]; then
  ok "packaging: all required manifest fields present and non-empty (${MANIFEST_REQUIRED_FIELDS[*]})"
else
  bad "packaging: all required manifest fields present and non-empty" "empty/absent:$pkg_field_gap"
fi
# Manifest version must equal the lockstep version (SKILL.md frontmatter is the lockstep anchor).
pkg_sv="$(grep -oE '^  version: "[^"]+"' "$ROOT/skills/external-agents/SKILL.md" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -n "$pkg_pv_py" ] && [ "$pkg_pv_py" = "$pkg_sv" ]; then
  ok "packaging: manifest version equals the lockstep version ($pkg_pv_py)"
else
  bad "packaging: manifest version equals the lockstep version" "plugin.json=$pkg_pv_py SKILL.md=$pkg_sv"
fi

echo "== manifest field-contract (negative path + CONTRIBUTING.md set parity) =="
# MANIFEST_REQUIRED_FIELDS (the packaging oracle's single source) is the install-critical contract.
# (a) Prove the oracle CATCHES a removed field: drop one from a copy of plugin.json and assert the
# gap check flags it. (b) Prove CONTRIBUTING.md documents EXACTLY that set (machine-readable marker)
# so the doc and the test cannot drift apart.
mf_tmp="$(mktemp)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("homepage",None); json.dump(d,open(sys.argv[2],"w"))' "$MANIFEST" "$mf_tmp" 2>/dev/null
mf_gap="$(manifest_field_gap "$mf_tmp")"
rm -f "$mf_tmp"
case " $mf_gap " in
  *" homepage "*) ok "manifest field-contract: removing a required field is caught (homepage flagged)";;
  *)              bad "manifest field-contract: removing a required field is caught" "gap='$mf_gap'";;
esac
# Set parity: the CONTRIBUTING.md marker must list exactly MANIFEST_REQUIRED_FIELDS.
mf_doc="$(sed -nE 's/.*install-critical-manifest-fields = ([a-z,]+).*/\1/p' "$ROOT/CONTRIBUTING.md" | head -1)"
mf_doc_sorted="$(printf '%s' "$mf_doc" | tr ',' '\n' | grep -v '^$' | sort -u)"
mf_src_sorted="$(printf '%s\n' "${MANIFEST_REQUIRED_FIELDS[@]}" | sort -u)"
if [ -n "$mf_doc_sorted" ] && [ "$mf_doc_sorted" = "$mf_src_sorted" ]; then
  ok "manifest field-contract: CONTRIBUTING.md lists exactly the required field set"
else
  bad "manifest field-contract: CONTRIBUTING.md lists exactly the required field set" \
      "doc=[$(printf '%s' "$mf_doc_sorted" | paste -sd' ' -)] src=[$(printf '%s' "$mf_src_sorted" | paste -sd' ' -)]"
fi

echo "== distribution-manifest oracle (listing fields well-formed + license/version consistency) =="
# The marketplace/listing contract INSIDE .claude-plugin/plugin.json: homepage/repository must be
# URL-shaped, license must be SPDX-ish AND equal the SPDX-License-Identifier in the LICENSE file, and
# the version must equal the lockstep version. A MISSING listing field is empty -> fails its shape
# check, so this oracle also catches an omitted field. Reuses MANIFEST (the packaging oracle's shared
# source). Offline, no CLI.
# Presence half: shared with the packaging oracle via the manifest_field_gap helper, so the two
# oracles cannot diverge on which fields are required.
dist_gap="$(manifest_field_gap "$MANIFEST")"
if [ -z "$dist_gap" ]; then
  ok "distribution: required manifest fields present (shared field check)"
else
  bad "distribution: required manifest fields present (shared field check)" "gap:$dist_gap"
fi
dist_home="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("homepage",""))' "$MANIFEST" 2>/dev/null)"
dist_repo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repository",""))' "$MANIFEST" 2>/dev/null)"
dist_lic="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("license",""))' "$MANIFEST" 2>/dev/null)"
case "$dist_home" in https://*|http://*) ok "distribution: homepage is URL-shaped ($dist_home)";; *) bad "distribution: homepage is URL-shaped" "got '$dist_home'";; esac
case "$dist_repo" in https://*|http://*) ok "distribution: repository is URL-shaped ($dist_repo)";; *) bad "distribution: repository is URL-shaped" "got '$dist_repo'";; esac
if printf '%s' "$dist_lic" | grep -qE '^[A-Za-z0-9.+-]+$'; then
  ok "distribution: license is an SPDX-ish identifier ($dist_lic)"
else
  bad "distribution: license is an SPDX-ish identifier" "got '$dist_lic'"
fi
# License consistency: manifest license must equal the SPDX-License-Identifier in the LICENSE file.
dist_spdx="$(grep -oE 'SPDX-License-Identifier:[[:space:]]*[A-Za-z0-9.+-]+' "$ROOT/LICENSE" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//')"
if [ -n "$dist_lic" ] && [ "$dist_lic" = "$dist_spdx" ]; then
  ok "distribution: manifest license matches the LICENSE SPDX identifier ($dist_lic)"
else
  bad "distribution: manifest license matches the LICENSE SPDX identifier" "manifest='$dist_lic' LICENSE='$dist_spdx'"
fi
dist_pv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST" 2>/dev/null)"
dist_sv="$(grep -oE '^  version: "[^"]+"' "$ROOT/skills/external-agents/SKILL.md" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -n "$dist_pv" ] && [ "$dist_pv" = "$dist_sv" ]; then
  ok "distribution: manifest version equals the lockstep version ($dist_pv)"
else
  bad "distribution: manifest version equals the lockstep version" "plugin.json=$dist_pv SKILL.md=$dist_sv"
fi

echo "== shared field-assertion alignment (packaging + distribution catch a removed field) =="
# Both oracles derive their required-field check from the single manifest_field_gap helper over
# MANIFEST_REQUIRED_FIELDS, so a removed field cannot pass one oracle while failing the other.
# (1) The shared helper flags removal of EVERY required field. (2) End-to-end, dropping 'license' is
# caught by both the packaging gap check and the distribution license-consistency check.
align_miss=""
for k in "${MANIFEST_REQUIRED_FIELDS[@]}"; do
  at="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop(sys.argv[2],None); json.dump(d,open(sys.argv[3],"w"))' "$MANIFEST" "$k" "$at" 2>/dev/null
  g="$(manifest_field_gap "$at")"
  rm -f "$at"
  case " $g " in *" $k "*) ;; *) align_miss="$align_miss $k";; esac
done
if [ -z "$align_miss" ]; then
  ok "shared alignment: the shared field check flags removal of every required field"
else
  bad "shared alignment: the shared field check flags removal of every required field" "not-caught:$align_miss"
fi
# End-to-end consistency: drop 'license' and confirm BOTH oracles' checks fail on the same manifest.
alt="$(mktemp)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("license",None); json.dump(d,open(sys.argv[2],"w"))' "$MANIFEST" "$alt" 2>/dev/null
align_pkg_gap="$(manifest_field_gap "$alt")"
align_lic="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("license",""))' "$alt" 2>/dev/null)"
rm -f "$alt"
align_pkg_caught=no; case " $align_pkg_gap " in *" license "*) align_pkg_caught=yes;; esac
align_dist_caught=no; [ -z "$align_lic" ] && align_dist_caught=yes
if [ "$align_pkg_caught" = "yes" ] && [ "$align_dist_caught" = "yes" ]; then
  ok "shared alignment: removing 'license' is caught by BOTH the packaging and distribution oracles"
else
  bad "shared alignment: removing 'license' is caught by BOTH oracles" "pkg=$align_pkg_caught dist=$align_dist_caught"
fi

echo "== dual-manifest decision lock (bumper references no .codex-plugin) =="
# Phase 7.1 removed the dead .codex-plugin/plugin.json reference — the repo ships only
# .claude-plugin/plugin.json. Lock that decision with a grep regression guard (mirroring the
# regression guard in the shellcheck block below): the bumper must not reference a non-existent
# .codex-plugin manifest again, which neither shellcheck nor the lockstep tests would otherwise catch.
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
# Every registry agent is reported per its KIND under the restricted PATH, derived from the registry so
# a new agent is covered for free. A cli agent's CLI binary is absent -> MISS. An api agent runs on the
# python3 runtime (which the restricted bin DOES provide) + the bundled client -> present (ok); --check
# never verifies its key, so a present-but-unconfigured api agent is correct, not missing.
chk_reg="$(grep -oE '^ADAPTER_AGENTS=\([^)]*\)' "$ROOT/scripts/run-agent.sh" | sed -E 's/^ADAPTER_AGENTS=\(//; s/\)$//')"
chk_kind_line="$(grep -E '^declare -A ADAPTER_KIND=' "$ROOT/scripts/run-agent.sh" | head -1)"
# shellcheck disable=SC2086 # chk_reg is a whitespace-separated agent list; iterate each.
for a in $chk_reg; do
  if printf '%s' "$chk_kind_line" | grep -qE "\[$a\]=\"api\""; then
    if printf '%s\n' "$chk_out" | grep -qE "ok +$a "; then ok "--check reports api agent '$a' present (python3 runtime) under the restricted PATH"
    else bad "--check reports api agent '$a' present under the restricted PATH" "no ok line for api agent '$a'"; fi
  else
    if printf '%s\n' "$chk_out" | grep -qE "MISS +$a "; then ok "--check reports '$a' missing under the restricted PATH"
    else bad "--check reports '$a' missing under the restricted PATH" "no MISS line for agent '$a'"; fi
  fi
done
# Phase 2.2: the antigravity-usage info line is a `command -v` PATH probe (resolving the same binary as
# the runtime AGY_QUOTA_CMD), info-only and NON-SPENDING. (a) absent (the restricted run above) reports
# "not on PATH"; (b) present, via a stub that writes a sentinel IF EXECUTED, reports "present" yet the
# sentinel stays absent — proving --check probes (command -v) and never spends quota.
assert_contains "--check: antigravity-usage absent -> info-only 'not on PATH'" "$chk_out" "info agy-qta antigravity-usage not on PATH"
agqd="$(mktemp -d)"; mk_restricted_bin "$agqd"
agqsent="$agqd/SPENT"
printf '#!/usr/bin/env bash\ntouch "%s"\necho spent\n' "$agqsent" >"$agqd/bin/antigravity-usage"; chmod +x "$agqd/bin/antigravity-usage"
agqout="$(PATH="$agqd/bin" "$agqd/bin/bash" "$RUN" --check 2>&1)"
assert_contains "--check: antigravity-usage present -> info-only 'present'" "$agqout" "info agy-qta antigravity-usage present"
if [ -e "$agqsent" ]; then
  bad "--check: antigravity-usage probe spends NO quota (command -v only, never executed)" "the quota CLI was executed by --check"
else
  ok "--check: antigravity-usage probe spends NO quota (command -v only, never executed)"
fi
rm -rf "$agqd"

echo "== --check pass semantics (scoped agent present -> 0 missing, exit 0) =="
# The documented pass criterion (0 missing / exit 0) must be test-backed, not only the missing case
# above. Scope --check to one agent and put its stub binary on PATH (command -v only — the stub is
# never executed); with the JSON reader present too, --check must report 0 missing and exit 0.
prdir="$(mktemp -d)"
printf '#!/usr/bin/env bash\ntrue\n' >"$prdir/codex"; chmod +x "$prdir/codex"
pres_out="$(PATH="$prdir:$PATH" bash "$RUN" --agent codex --check 2>&1)"; pres_rc=$?
rm -rf "$prdir"
assert_contains "--check reports the scoped agent present (ok line)"          "$pres_out" "ok   codex"
assert_contains "--check reports 0 missing when the scoped agent is present"  "$pres_out" "0 missing"
assert_exit     "--check exits 0 when the scoped agent and reader are present" 0 "$pres_rc"

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

echo "== --check / --discover clean stderr with no --agent (empty associative-subscript regression) =="
# Bare --check / --discover (AGENT unset) must not index the ADAPTER_BIN associative array with an
# empty subscript, which bash rejects with 'bad array subscript' (the `:-` default cannot suppress a
# subscript-evaluation error). Capture STDERR only — the diagnostic output goes to stdout — so the
# error leak is caught regardless of which agent CLIs happen to be installed.
ck_err="$(bash "$RUN" --check 2>&1 >/dev/null)"
if printf '%s\n' "$ck_err" | grep -q 'bad array subscript'; then
  bad "--check (no --agent): no 'bad array subscript' on stderr" "$ck_err"
else
  ok "--check (no --agent): no 'bad array subscript' on stderr"
fi
ds_err="$(bash "$RUN" --discover 2>&1 >/dev/null)"
if printf '%s\n' "$ds_err" | grep -q 'bad array subscript'; then
  bad "--discover (no --agent): no 'bad array subscript' on stderr" "$ds_err"
else
  ok "--discover (no --agent): no 'bad array subscript' on stderr"
fi

echo "== auth-contract consistency (README per-agent contract <-> driver agents/bins; presence-only) =="
# (1) The documented per-agent auth-prerequisite contract (README "Per-agent auth prerequisites") must
# stay consistent with the driver's known agent set + agent_bin mapping. (2) --check/--discover must
# remain PRESENCE-ONLY: a `command -v` probe, never EXECUTING the agent binary (which is how an
# auth/network call would happen). Fully offline; no agent CLI is ever launched.
# Driver's agents + resolved binaries via the machine-readable --discover surface (restricted PATH).
ac_dir="$(mktemp -d)"; mk_restricted_bin "$ac_dir"
ac_disc="$(PATH="$ac_dir/bin" "$ac_dir/bin/bash" "$RUN" --discover 2>/dev/null)"
rm -rf "$ac_dir"
# README contract rows for the four non-optional agents -> "<agent> <binary>"; each must match a
# driver --discover line "<agent> <present|missing> <binary>". (Backticks below are literal markdown
# table delimiters, not command substitution — hence the SC2016 disable.)
# shellcheck disable=SC2016
ac_rows="$(grep -E '^\| `(agy|codex|claude|cursor)` ' "$ROOT/README.md" | sed -E 's/^\| `([a-z]+)` *\| `([a-z-]+)`.*/\1 \2/')"
ac_mismatch=""
while read -r a bin; do
  [ -n "$a" ] || continue
  printf '%s\n' "$ac_disc" | grep -qE "^$a (present|missing) $bin( |$)" || ac_mismatch="$ac_mismatch $a:$bin"
done <<< "$ac_rows"
if [ -z "$ac_mismatch" ]; then
  ok "auth-contract: documented agents match the driver's agent_bin mapping"
else
  bad "auth-contract: documented agents match the driver's agent_bin mapping" "mismatch:$ac_mismatch"
fi
# Set equality: the documented agent set equals the driver's agent set (contract can't omit/add one).
# shellcheck disable=SC2016
ac_doc="$(grep -oE '^\| `(agy|codex|claude|cursor)` ' "$ROOT/README.md" | grep -oE '(agy|codex|claude|cursor)' | sort -u)"
ac_drv="$(printf '%s\n' "$ac_disc" | grep -oE '^(agy|codex|claude|cursor)' | sort -u)"
if [ -n "$ac_doc" ] && [ "$ac_doc" = "$ac_drv" ]; then
  ok "auth-contract: documented agent set equals the driver's agent set"
else
  bad "auth-contract: documented agent set equals the driver's agent set" \
      "doc=[$(printf '%s' "$ac_doc" | paste -sd' ' -)] drv=[$(printf '%s' "$ac_drv" | paste -sd' ' -)]"
fi
# Presence-only boundary: a stub that writes a sentinel WHEN EXECUTED must stay un-executed by
# --check / --discover (they may only command -v it). This fails if either is changed to run the CLI.
po_dir="$(mktemp -d)"; po_sentinel="$po_dir/EXECUTED"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$po_sentinel" >"$po_dir/codex"; chmod +x "$po_dir/codex"
po_chk="$(PATH="$po_dir:$PATH" bash "$RUN" --agent codex --check 2>&1)"
po_chk_exec=0; [ -e "$po_sentinel" ] && po_chk_exec=1
rm -f "$po_sentinel"
po_disc="$(PATH="$po_dir:$PATH" bash "$RUN" --agent codex --discover 2>&1)"
po_disc_exec=0; [ -e "$po_sentinel" ] && po_disc_exec=1
rm -rf "$po_dir"
assert_contains "presence-only: --check reports the stub agent present"     "$po_chk"  "ok   codex"
assert_contains "presence-only: --discover reports the stub agent present"  "$po_disc" "codex present"
assert_exit     "presence-only: --check never executed the agent binary"    0 "$po_chk_exec"
assert_exit     "presence-only: --discover never executed the agent binary" 0 "$po_disc_exec"

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
  skip "soft-malformed parity (could not run both backends)"
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

echo "== e2e edit-non-git recipe oracle (stub-driven, offline) =="
# Drive the non-git write recipe against a stub agent: the driver must WARN there is no git baseline
# and SUPPRESS the post-write verification block. The stub keeps it offline; EXTERNAL_AGENTS_LIVE=1 arms it.
if command -v timeout >/dev/null 2>&1; then
  eng="$(mktemp -d)"; engd="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "edited\\n"\nprintf "%%s\\n" "%s" >> notes.txt\n' \
    "$E2E_FIXTURE_MARKER" >"$eng/codex"; chmod +x "$eng/codex"
  eng_out="$(PATH="$eng:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$engd" \
    bash "$ROOT/tests/e2e/edit-non-git.sh" codex 2>&1)"; eng_rc=$?
  assert_exit     "edit-non-git recipe: marker write -> pass (exit 0)" 0 "$eng_rc"
  assert_contains "edit-non-git recipe: no-baseline warning captured"  "$eng_out" "no-baseline warning captured"
  assert_contains "edit-non-git recipe: post-write block suppressed"   "$eng_out" "post-write block correctly suppressed"
  assert_contains "edit-non-git recipe: marker-content asserted"        "$eng_out" "marker-content: notes.txt contains the expected"
  rm -rf "$eng" "$engd"
  # Negative: a stub that writes nothing must fail the strengthened marker oracle.
  engn="$(mktemp -d)"; engnd="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "did nothing\\n"\n' >"$engn/codex"; chmod +x "$engn/codex"
  PATH="$engn:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$engnd" \
    bash "$ROOT/tests/e2e/edit-non-git.sh" codex >/dev/null 2>&1
  assert_exit "edit-non-git recipe: no write -> fail (non-zero)" 1 "$?"
  rm -rf "$engn" "$engnd"
else
  skip "e2e edit-non-git recipe oracle (timeout unavailable)"
fi

echo "== e2e review-readonly recipe oracle (stub-driven, offline) =="
# Drive the read-only review recipe against a stub agent: a clean stub (no writes) must PASS with
# the enforced no-mutation verdict; a rogue stub that writes into the fixture must FAIL the recipe,
# proving the recipe independently enforces non-mutation rather than trusting the CLI sandbox.
if command -v timeout >/dev/null 2>&1; then
  rro_ok="$(mktemp -d)"; rro_okd="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "looks good\\n"\n' >"$rro_ok/codex"; chmod +x "$rro_ok/codex"
  rro_out="$(PATH="$rro_ok:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$rro_okd" \
    bash "$ROOT/tests/e2e/review-readonly.sh" codex 2>&1)"; rro_rc=$?
  assert_exit     "review-readonly recipe: clean read-only -> pass (exit 0)" 0 "$rro_rc"
  assert_contains "review-readonly recipe: no-mutation verdict reported"      "$rro_out" "no-mutation: fixture unchanged"
  rm -rf "$rro_ok" "$rro_okd"
  rro_bad="$(mktemp -d)"; rro_badd="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "looks good\\n"\nprintf "rogue\\n" > ROGUE.txt\n' >"$rro_bad/codex"; chmod +x "$rro_bad/codex"
  rro_berr="$(PATH="$rro_bad:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$rro_badd" \
    bash "$ROOT/tests/e2e/review-readonly.sh" codex 2>&1)"; rro_brc=$?
  assert_exit     "review-readonly recipe: enforced mutation -> fail (non-zero)" 1 "$rro_brc"
  assert_contains "review-readonly recipe: mutation flagged as a hard failure"   "$rro_berr" "enforced read-only MUTATED"
  rm -rf "$rro_bad" "$rro_badd"
else
  skip "e2e review-readonly recipe oracle (timeout unavailable)"
fi

echo "== e2e edit-readwrite recipe oracle (stub-driven, offline) =="
# Drive the full read-write recipe against a stub agent (no real CLI). A stub that appends the exact
# marker to the seed file must PASS the recipe; a stub appending wrong content must FAIL the
# strengthened marker oracle. EXTERNAL_AGENTS_LIVE=1 arms the recipe; the stub keeps it offline.
# ($E2E_FIXTURE_MARKER / $E2E_FIXTURE_SEED were sourced from the fixture lib above.)
if command -v timeout >/dev/null 2>&1; then
  erw_good="$(mktemp -d)"; erw_god="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "did the edit\\n"\nprintf "%%s\\n" "%s" >> "%s"\n' \
    "$E2E_FIXTURE_MARKER" "$E2E_FIXTURE_SEED" >"$erw_good/codex"; chmod +x "$erw_good/codex"
  erw_out="$(PATH="$erw_good:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$erw_god" \
    bash "$ROOT/tests/e2e/edit-readwrite.sh" codex 2>&1)"; erw_rc=$?
  assert_exit     "edit-readwrite recipe: correct marker -> pass (exit 0)" 0 "$erw_rc"
  assert_contains "edit-readwrite recipe: marker-content asserted"          "$erw_out" "marker-content: seed file contains the expected"
  rm -rf "$erw_good" "$erw_god"
  erw_bad="$(mktemp -d)"; erw_bod="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "did the edit\\n"\nprintf "%%s\\n" "WRONG-CONTENT" >> "%s"\n' \
    "$E2E_FIXTURE_SEED" >"$erw_bad/codex"; chmod +x "$erw_bad/codex"
  PATH="$erw_bad:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$erw_bod" \
    bash "$ROOT/tests/e2e/edit-readwrite.sh" codex >/dev/null 2>&1
  assert_exit "edit-readwrite recipe: wrong content -> fail (non-zero)" 1 "$?"
  rm -rf "$erw_bad" "$erw_bod"
else
  skip "e2e edit-readwrite recipe oracle (timeout unavailable)"
fi

echo "== e2e recipes dispatch under multiple stub agents (enforced + best-effort, offline) =="
# The per-recipe oracles above each drive a single 'codex' stub, so a regression dropping an agent
# from a recipe would still pass. Prove reachable-set BREADTH: every recipe dispatches under an
# ENFORCED agent (codex) AND the BEST-EFFORT agy, and the enforced-vs-best-effort non-mutation
# distinction holds — an enforced agent that writes during a read-only run HARD-FAILS, while agy only
# reports it. EXTERNAL_AGENTS_AGY_QUOTA_CMD=false keeps agy off any real quota CLI; all stubs offline.
if command -v timeout >/dev/null 2>&1; then
  matpl="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\n'                                     >"$matpl/clean"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\nprintf "%%s\\n" "%s" >> "%s"\n'        "$E2E_FIXTURE_MARKER" "$E2E_FIXTURE_SEED" >"$matpl/seed"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\nprintf "%%s\\n" "%s" >> notes.txt\n'   "$E2E_FIXTURE_MARKER" >"$matpl/notes"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\nprintf "rogue\\n" > ROGUE.txt\n'       >"$matpl/rogue"
  ma_dispatch() {  # recipe agent bin template expect-rc label
    local recipe="$1" agent="$2" bin="$3" tpl="$4" exp="$5" label="$6" d o
    d="$(mktemp -d)"; o="$(mktemp -d)"
    cp "$matpl/$tpl" "$d/$bin"; chmod +x "$d/$bin"
    PATH="$d:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$o" EXTERNAL_AGENTS_AGY_QUOTA_CMD=false \
      bash "$ROOT/tests/e2e/$recipe.sh" "$agent" >/dev/null 2>&1
    assert_exit "multi-agent: $label" "$exp" "$?"
    rm -rf "$d" "$o"
  }
  ma_dispatch review-readonly codex codex clean 0 "review-readonly dispatches under enforced codex (clean)"
  ma_dispatch review-readonly agy   agy   clean 0 "review-readonly dispatches under best-effort agy (clean)"
  ma_dispatch edit-readwrite  codex codex seed  0 "edit-readwrite dispatches under enforced codex (marker)"
  ma_dispatch edit-readwrite  agy   agy   seed  0 "edit-readwrite dispatches under best-effort agy (marker)"
  ma_dispatch edit-non-git    codex codex notes 0 "edit-non-git dispatches under enforced codex (marker)"
  ma_dispatch edit-non-git    agy   agy   notes 0 "edit-non-git dispatches under best-effort agy (marker)"
  ma_dispatch review-readonly codex codex rogue 1 "enforced codex read-only mutation -> hard fail"
  ma_dispatch review-readonly agy   agy   rogue 0 "best-effort agy read-only mutation -> reported, not failed"
  rm -rf "$matpl"
  unset -f ma_dispatch
else
  skip "e2e multi-agent dispatch oracle (timeout unavailable)"
fi

echo "== e2e run-e2e.sh dispatch (stub-driven, offline) =="
# Drive run-e2e.sh's discover-then-dispatch path against a mode-aware stub agent: a read-only argv
# means no writes (review-readonly stays clean); a write argv appends the marker to seed.txt/notes.txt
# (edit-readwrite/edit-non-git pass). Prove it discovers the stub and dispatches all three recipes.
if command -v timeout >/dev/null 2>&1; then
  rstub="$(mktemp -d)"; re2ed="$(mktemp -d)"
  cat >"$rstub/codex" <<'STUBEOF'
#!/usr/bin/env bash
printf 'stub ran\n'
case "$*" in
  *"-s read-only"*|*"--allowedTools"*|*"--mode plan"*|*"--sandbox"*) : ;;  # any agent's read-only argv -> no write
  *)
    [ -f seed.txt ]  && printf '%s\n' "$STUB_MARKER" >> seed.txt
    [ -f notes.txt ] && printf '%s\n' "$STUB_MARKER" >> notes.txt
    ;;
esac
exit 0
STUBEOF
  # Shadow ALL four real agent CLIs (this host has them on PATH) with the same mode-aware stub, so
  # run-e2e.sh's own discovery reaches only stubs — never a real CLI — while the full toolchain stays.
  for b in agy claude cursor-agent; do cp "$rstub/codex" "$rstub/$b"; done
  chmod +x "$rstub/codex" "$rstub/agy" "$rstub/claude" "$rstub/cursor-agent"
  re2e_out="$(PATH="$rstub:$PATH" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$re2ed" \
    STUB_MARKER="$E2E_FIXTURE_MARKER" bash "$ROOT/tests/e2e/run-e2e.sh" 2>&1)"; re2e_rc=$?
  assert_exit     "run-e2e.sh: stub-driven full dispatch -> exit 0"   0 "$re2e_rc"
  assert_contains "run-e2e.sh: discovers reachable agents + dispatches" "$re2e_out" "reachable agents:"
  for r in review-readonly edit-readwrite edit-non-git; do
    assert_contains "run-e2e.sh: dispatched recipe '$r'" "$re2e_out" "running recipe '$r'"
  done
  rm -rf "$rstub" "$re2ed"
else
  skip "e2e run-e2e.sh dispatch (timeout unavailable)"
fi

echo "== e2e run-e2e.sh no-reachable-agents path (armed, restricted PATH) =="
# Armed (EXTERNAL_AGENTS_LIVE=1) but with NO agent CLI on PATH, run-e2e.sh must exit 0 with a clear
# "no reachable agents" message — absence is a clean no-op, never a failure or a launch. Reuses the
# restricted-bin technique (shell utils present, no agent CLIs), so discovery finds nothing reachable.
nrdir="$(mktemp -d)"; mk_restricted_bin "$nrdir"; nrod="$(mktemp -d)"
nr_out="$(PATH="$nrdir/bin" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$nrod" \
  "$nrdir/bin/bash" "$ROOT/tests/e2e/run-e2e.sh" 2>&1)"; nr_rc=$?
rm -rf "$nrdir" "$nrod"
assert_exit     "run-e2e.sh: armed + no agent CLIs -> exit 0" 0 "$nr_rc"
assert_contains "run-e2e.sh: reports no reachable agents"      "$nr_out" "no reachable agents"

echo "== e2e recipes: uniform skip-when-absent (armed, no agent CLIs -> exit 0) =="
# run-e2e.sh's no-reachable path is asserted above; prove EACH recipe is uniformly skip-when-absent too
# — armed (EXTERNAL_AGENTS_LIVE=1) but with NO agent CLI on PATH, every recipe must exit 0 with a clear
# "no agents to run" line, never a failure or a launch. Reuses the restricted-bin technique so discovery
# finds nothing reachable (shell utils present, no agent CLIs).
for r in review-readonly edit-readwrite edit-non-git; do
  swa_dir="$(mktemp -d)"; mk_restricted_bin "$swa_dir"; swa_out="$(mktemp -d)"
  swa_msg="$(PATH="$swa_dir/bin" EXTERNAL_AGENTS_LIVE=1 EXTERNAL_AGENTS_OUT="$swa_out" \
    "$swa_dir/bin/bash" "$ROOT/tests/e2e/$r.sh" 2>&1)"; swa_rc=$?
  rm -rf "$swa_dir" "$swa_out"
  assert_exit     "skip-when-absent: $r armed + no CLIs -> exit 0" 0 "$swa_rc"
  assert_contains "skip-when-absent: $r reports no agents to run"   "$swa_msg" "no agents to run"
done

echo "== e2e recipe dispatch drift guard (run-e2e.sh list == recipe files) =="
# run-e2e.sh hardcodes the recipes it dispatches (`for recipe in ...`); a recipe file added without
# updating that list — or removed while still listed — would be silently never run. Assert the
# dispatch token set equals the set of tests/e2e/*.sh recipe basenames (excluding run-e2e.sh itself).
disp="$(grep -oE 'for recipe in [^;]+' "$ROOT/tests/e2e/run-e2e.sh" | sed -E 's/^for recipe in +//')"
disp_sorted="$(printf '%s' "$disp" | tr ' ' '\n' | grep -v '^$' | sort -u)"
files_sorted="$(for f in "$ROOT"/tests/e2e/*.sh; do b="$(basename "$f")"; [ "$b" = "run-e2e.sh" ] && continue; printf '%s\n' "${b%.sh}"; done | sort -u)"
if [ -n "$disp_sorted" ] && [ "$disp_sorted" = "$files_sorted" ]; then
  ok "e2e dispatch list matches the recipe files ($(printf '%s' "$disp"))"
else
  bad "e2e dispatch list matches the recipe files" "dispatch=[$(printf '%s' "$disp_sorted" | paste -sd' ' -)] files=[$(printf '%s' "$files_sorted" | paste -sd' ' -)]"
fi

echo "== opt-in gate: live/e2e harnesses are offline no-ops without the arming switch =="
# The live-smoke + e2e recipe scripts must launch NOTHING and exit 0 when EXTERNAL_AGENTS_LIVE is
# unset — the invariant that keeps the real agent CLIs out of the offline gate. Run each with the
# switch cleared (and a hermetic EXTERNAL_AGENTS_OUT so live-smoke's status record never touches
# $HOME) and assert the documented skip line plus exit 0.
optin_out="$(mktemp -d)"
optin_covered=()
optin_gate() {  # script-relpath  skip-needle
  local rel="$1" needle="$2" out rc
  out="$(env -u EXTERNAL_AGENTS_LIVE EXTERNAL_AGENTS_OUT="$optin_out" bash "$ROOT/$rel" 2>/dev/null)"; rc=$?
  assert_exit     "opt-in gate: $rel exits 0 without the switch" 0 "$rc"
  assert_contains "opt-in gate: $rel prints its skip line"       "$out" "$needle"
  optin_covered+=("$rel")
}
optin_gate "tests/live-smoke.sh"          "live smoke skipped (set EXTERNAL_AGENTS_LIVE=1)"
optin_gate "tests/e2e/run-e2e.sh"         "e2e recipes skipped (set EXTERNAL_AGENTS_LIVE=1)"
optin_gate "tests/e2e/review-readonly.sh" "e2e review-readonly skipped (set EXTERNAL_AGENTS_LIVE=1)"
optin_gate "tests/e2e/edit-readwrite.sh"  "e2e edit-readwrite skipped (set EXTERNAL_AGENTS_LIVE=1)"
optin_gate "tests/e2e/edit-non-git.sh"    "e2e edit-non-git skipped (set EXTERNAL_AGENTS_LIVE=1)"
# Completeness: the no-op proof must cover EVERY live/e2e entry point on disk (tests/live-smoke.sh +
# tests/e2e/*.sh, excluding the lib/ helpers) — so a newly added live script or recipe variant cannot
# silently escape the opt-in gate. Mirrors the e2e recipe dispatch drift guard.
optin_disk="$( { echo "tests/live-smoke.sh"; for f in "$ROOT"/tests/e2e/*.sh; do echo "tests/e2e/$(basename "$f")"; done; } | sort -u )"
optin_cov_sorted="$(printf '%s\n' "${optin_covered[@]}" | sort -u)"
if [ "$optin_cov_sorted" = "$optin_disk" ]; then
  ok "opt-in gate: no-op proof covers every live/e2e entry point on disk (${#optin_covered[@]})"
else
  bad "opt-in gate: no-op proof covers every live/e2e entry point on disk" \
      "covered=[$(printf '%s' "$optin_cov_sorted" | paste -sd' ' -)] disk=[$(printf '%s' "$optin_disk" | paste -sd' ' -)]"
fi
rm -rf "$optin_out"

echo "== docs/e2e-recipe.md offline-oracle coverage lock =="
# This sweep added stub-driven offline coverage of the e2e recipe oracles, so the recipe doc must say
# so (mirroring the dual-manifest decision lock above) — otherwise it could silently drift back to
# claiming those oracles are only verifiable against a live CLI.
if grep -qi 'stub' "$ROOT/docs/e2e-recipe.md" && grep -qF 'oracle logic' "$ROOT/docs/e2e-recipe.md"; then
  ok "docs/e2e-recipe.md documents the offline stub-driven oracle coverage"
else
  bad "docs/e2e-recipe.md documents the offline stub-driven oracle coverage" "doc drifted: missing the stub-driven offline oracle note"
fi

echo "== Phase 8 opt-in live hooks stay outside the required offline gate =="
# Phase 8.2 added an opt-in live error_class hook to tests/live-smoke.sh (recorded ONLY when armed).
# Re-assert the offline boundary WITH that hook present: (1) an unarmed live-smoke.sh run writes NO
# error-class.txt (the Phase 8 hook is gated behind EXTERNAL_AGENTS_LIVE), and (2) the required CI job
# gained only the OFFLINE run-record schema step — no live CLI / live harness reference.
p8out="$(mktemp -d)"
env -u EXTERNAL_AGENTS_LIVE EXTERNAL_AGENTS_OUT="$p8out" bash "$ROOT/tests/live-smoke.sh" >/dev/null 2>&1; p8rc=$?
assert_exit "phase8 gate: unarmed live-smoke exits 0" 0 "$p8rc"
if [ -f "$p8out/live-smoke/error-class.txt" ]; then
  bad "phase8 gate: unarmed live-smoke writes NO error-class.txt (Phase 8 hook gated)" "error-class.txt was written without the arming switch"
else
  ok "phase8 gate: unarmed live-smoke writes NO error-class.txt (Phase 8 hook gated)"
fi
rm -rf "$p8out"
ci_yml8="$ROOT/.github/workflows/ci.yml"
if [ -f "$ci_yml8" ]; then
  ci_active8="$(grep -vE '^[[:space:]]*#' "$ci_yml8")"
  if printf '%s\n' "$ci_active8" | grep -qF 'run-record.schema.json'; then
    ok "phase8 gate: required CI job validates the run-record schema (offline step present)"
  else
    bad "phase8 gate: required CI job validates the run-record schema (offline step present)" "ci.yml has no run-record schema step"
  fi
  if printf '%s\n' "$ci_active8" | grep -qE 'live-smoke\.sh|run-e2e\.sh|EXTERNAL_AGENTS_LIVE|antigravity-usage|cursor-agent'; then
    bad "phase8 gate: no live CLI/harness in the required job (with Phase 8 steps present)" "ci.yml active lines reference a live harness/CLI"
  else
    ok "phase8 gate: no live CLI/harness in the required job (with Phase 8 steps present)"
  fi
else
  bad "phase8 gate: ci.yml present" "missing .github/workflows/ci.yml"
fi

echo "== ci.yml required-job offline boundary (no live harness in the required gate) =="
# P0-01: the required CI check job is offline-by-design — it must NEVER invoke the opt-in live harness
# (tests/live-smoke.sh), the e2e recipes (tests/e2e/, run-e2e.sh), or arm EXTERNAL_AGENTS_LIVE, which
# would spend real quota and ship the tree to third-party providers on every push/PR. The in-file
# boundary warning names the harness on purpose, so parse only ACTIVE (non-comment) lines. Any live
# verification must live in a SEPARATE, non-required workflow file — never folded into this gate.
ci_yml="$ROOT/.github/workflows/ci.yml"
if [ -f "$ci_yml" ]; then
  ci_active="$(grep -vE '^[[:space:]]*#' "$ci_yml")"
  if printf '%s\n' "$ci_active" | grep -qE 'live-smoke\.sh|run-e2e\.sh|tests/e2e/|EXTERNAL_AGENTS_LIVE'; then
    bad "ci-boundary: required job has no live-harness reference" \
        "ci.yml active lines reference a live harness / arming switch: $(printf '%s\n' "$ci_active" | grep -nE 'live-smoke\.sh|run-e2e\.sh|tests/e2e/|EXTERNAL_AGENTS_LIVE' | paste -sd';' -)"
  else
    ok "ci-boundary: required job has no live-harness reference"
  fi
  # Positive check: ci.yml IS the offline gate (it runs the CLI-free suite), so a live workflow is a
  # distinct file rather than a step folded into this required job.
  if printf '%s\n' "$ci_active" | grep -qF 'tests/run.sh'; then
    ok "ci-boundary: required job runs the offline suite (tests/run.sh)"
  else
    bad "ci-boundary: required job runs the offline suite (tests/run.sh)" "ci.yml no longer runs the offline suite"
  fi
else
  bad "ci-boundary: .github/workflows/ci.yml present" "missing .github/workflows/ci.yml"
fi

echo "== shellcheck (regression guard) =="
if command -v shellcheck >/dev/null 2>&1; then
  # Lint the driver scripts AND the test harness itself — the harness is the largest body of
  # shell in the repo, so a shellcheck regression there must not go uncaught.
  if shellcheck "$ROOT/scripts/run-agent.sh" "$ROOT/scripts/bump-version.sh" \
                "$ROOT/tests/run.sh" "$ROOT/tests/live-smoke.sh" \
                "$ROOT"/tests/e2e/*.sh "$ROOT"/tests/e2e/lib/*.sh >/dev/null 2>&1; then
    ok "scripts/*.sh and tests/*.sh are shellcheck-clean"
  else
    bad "scripts/*.sh and tests/*.sh are shellcheck-clean" "run: shellcheck scripts/*.sh tests/run.sh tests/live-smoke.sh tests/e2e/*.sh tests/e2e/lib/*.sh"
  fi
else
  skip "shellcheck (not installed)"
fi

echo
echo "tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

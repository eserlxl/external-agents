#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/scripts/run-agent.sh — dispatch ONE prompt to external coding
# agent CLIs (agy / codex / claude / cursor) as autonomous sub-agents, then collect
# each agent's response. This generalises council/run-council.sh from a fixed,
# read-only evaluation panel to an arbitrary task the agents may carry out in
# the working tree.
#
# The runner only knows how to *drive* each cli. The prompt is always passed as a
# single argv element (never eval'd, never word-split), so it is injection-safe:
#
#   READ-WRITE  (default — agents MAY edit files / run tools in the target):
#     agy     agy -p PROMPT --add-dir DIR --dangerously-skip-permissions [--model M]
#     codex   codex exec -s workspace-write -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] PROMPT
#     claude  claude -p PROMPT --permission-mode acceptEdits [--model M] [--effort E]
#             NOTE: acceptEdits auto-accepts file EDITS but denies other shell
#             commands non-interactively. For tasks that must build / test / run
#             commands, pass --claude-perm bypassPermissions.
#     cursor  cursor-agent -p --force --trust --workspace DIR [--model M] -- PROMPT
#             NOTE: -p is headless print mode; --force (alias --yolo) auto-approves
#             write + shell tools; --trust avoids the non-interactive workspace-trust
#             prompt. The binary is `cursor-agent`, not `cursor` (the IDE).
#
#   READ-ONLY  (--read-only — agents observe and report; codex/claude/cursor are HARD
#               read-only, agy is best-effort):
#     agy     agy -p PROMPT --sandbox --add-dir DIR [--model M]
#             NOTE: agy --sandbox restricts the terminal but does NOT block agy's
#             file-edit tools, so agy read-only is best-effort, NOT enforced. Use
#             codex/claude/cursor for a hard guarantee, or point --target at a throwaway copy.
#     codex   codex exec -s read-only -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] PROMPT
#     claude  claude -p PROMPT --allowedTools Read Grep Glob [--model M] [--effort E]
#     cursor  cursor-agent -p --mode plan --trust --workspace DIR [--model M] -- PROMPT
#             NOTE: --mode plan is Cursor's enforced read-only/planning mode (analyze,
#             propose plans, no edits) — a hard guarantee, like codex/claude.
#
#   (agy and claude run with cwd=DIR; codex takes -C DIR; cursor takes --workspace DIR.)
#
# EFFORT TIERS.  The caller picks ONE semantic effort level — low | medium | high |
# xhigh — and agents.json maps that tier to the right (model, native effort) for
# EACH agent. So a single `--effort high` resolves, per agent, to e.g.:
#     agy    -> Claude Sonnet 4.6 (Thinking)         (agy bakes the tier into the model; quota-checked)
#     codex  -> gpt-5.5   model_reasoning_effort=high
#     claude -> claude-opus-4-8   --effort high
#     cursor -> composer-2.5                         (cursor bakes the tier into the model)
# With no --effort the config's default_tier is used. A per-run --model overrides
# only the resolved model; the native effort still comes from the tier. Reading
# agents.json needs `jq` (preferred) or `python3` on PATH.
#
# AGY QUOTA-AWARE FALLBACK.  An agy tier may add a "fallback" model: its limited
# 3rd-party primary (e.g. Claude Opus 4.6 (Thinking)) is used ONLY when the free
# `antigravity-usage --json` CLI confirms remaining quota; if it is exhausted OR
# unconfirmable (Antigravity IDE closed / not logged in), the larger-limit Gemini
# fallback is used instead — so scarce 3rd-party / Opus quota is never spent without a
# positive check. agy-only; a per-run --model override skips it. Open the Antigravity
# IDE (or run `antigravity-usage login`) to enable the 3rd-party tiers.
#
# Usage:
#   run-agent.sh --agent <agy|codex|claude|cursor|all> (--prompt "..." | --prompt-file F | --prompt-file -)
#                [--target DIR] [--read-only | --write] [--effort TIER] [--model M]
#                [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
#                [--list] [--check] [--discover] [--dry-run] [-h | --help]
#
# --agent all  fans out to every agent ENABLED in agents.json, in parallel.
# Transcripts land under --out (default ~/.external-agents/logs/<project>/<agent>.md)
# AND are echoed to stdout so the caller (Claude) sees every response inline.
#
# SAFETY: in the default read-write mode the agents can modify whatever is under
# --target. Point --target at the tree you actually want changed, and NEVER at a
# tree containing private IP you would not ship to an external provider (agy,
# codex, and cursor are external services). Use --read-only when you only want analysis.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd -P)"

AGENT=""
PROMPT=""
PROMPT_FILE=""
TARGET="$(pwd)"
MODE="write"                 # write (default) | readonly
MODE_SET=""                  # set once --read-only/--write is given explicitly
EFFORT=""                    # requested effort TIER (low|medium|high|xhigh); blank -> default_tier
MODEL=""                     # per-run model override; else the tier's model / cli default
CLAUDE_PERM="acceptEdits"    # claude write-mode permission mode
OUT=""                       # default resolved after TARGET
OUT_SET=""                   # set when --out is given explicitly (chooses the run-index base)
CONF="$PLUGIN_ROOT/agents.json"
TIMEOUT=1800
YES=0
LIST=0
CHECK=0
DISCOVER=0
DRYRUN=0
VERSION=0
JSON=0

usage() {
  cat <<'EOF'
run-agent.sh — dispatch ONE prompt to external coding agent CLIs
(agy / codex / claude / cursor) as autonomous sub-agents, then collect each response.

Usage:
  run-agent.sh --agent <agy|codex|claude|cursor|all> (--prompt "..." | --prompt-file F | --prompt-file -)
               [--target DIR] [--read-only | --write] [--effort TIER] [--model M]
               [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
               [--list] [--check] [--dry-run] [-h | --help]

  --agent       agy | codex | claude | cursor | all  (all = every agent enabled in agents.json)
  --prompt      the task/prompt (single argv element; never word-split)
  --prompt-file read the prompt from a file, or - for stdin
  --target DIR  directory the agents work in (default: cwd)
  --write       read-write mode: agents MAY edit files / run tools (DEFAULT)
  --read-only   agents observe and report, never mutate (the council's config)
  --effort TIER effort level / model tier: low | medium | high | xhigh.
                Maps, per agent, to the (model, native effort) defined in agents.json.
                Optional; blank uses the config's default_tier.
  --model M     model override (wins over the tier's model; effort still from the tier)
  --claude-perm claude write-mode permission mode (default: acceptEdits)
  --timeout S   per-agent timeout in seconds (default: 1800)
  --out DIR     transcript dir (default: ~/.external-agents/logs/<project>)
  --conf FILE   agent config JSON (default: <plugin>/agents.json)
  --list        print the parsed agent config (tiers + enabled) and exit
  --check       preflight: report the JSON reader and whether each candidate CLI is on PATH
  --discover    print one machine-readable line per agent: "<a> <present|missing> <bin>"
  --json        also emit a machine-readable JSON run summary (opt-in; default output unchanged)
  --dry-run     print each agent's resolved launch argv without running it
  --version, -V print the external-agents plugin version and exit
  --yes, -y     confirm a write run whose --target is not the current directory

SAFETY: in the default --write mode the agents can modify whatever is under --target.
Never point --target at private IP you would not ship to an external provider.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --agent) AGENT="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --read-only|--readonly)
      [ -n "$MODE_SET" ] && [ "$MODE" != "readonly" ] && { echo "run-agent: --read-only and --write are mutually exclusive" >&2; exit 2; }
      MODE="readonly"; MODE_SET=1; shift;;
    --write)
      [ -n "$MODE_SET" ] && [ "$MODE" != "write" ] && { echo "run-agent: --read-only and --write are mutually exclusive" >&2; exit 2; }
      MODE="write"; MODE_SET=1; shift;;
    --effort) EFFORT="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --claude-perm) CLAUDE_PERM="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --out) OUT="$2"; OUT_SET=1; shift 2;;
    --conf) CONF="$2"; shift 2;;
    --list) LIST=1; shift;;
    --check) CHECK=1; shift;;
    --discover) DISCOVER=1; shift;;
    --json) JSON=1; shift;;
    -y|--yes) YES=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    --version|-V) VERSION=1; shift;;
    *) echo "run-agent: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# --- --version: print the plugin version and exit (needs no agents.json) ----------
if [ "$VERSION" = "1" ]; then
  _pj="$PLUGIN_ROOT/.claude-plugin/plugin.json"
  if   command -v jq      >/dev/null 2>&1; then _ver="$(jq -r '.version // empty' "$_pj" 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then _ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$_pj" 2>/dev/null)"
  else _ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$_pj" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"; fi
  echo "external-agents run-agent.sh ${_ver:-(unknown)}"
  exit 0
fi

# --- JSON config backend  (jq preferred, python3 fallback) ------------------------
# All reads of agents.json funnel through cfg() so the two backends stay co-located
# and obviously parallel. Ops:
#   default_tier            -> the global default tier (may be empty)
#   agents                  -> newline list of ALL agent names (insertion order)
#   enabled                 -> newline list of enabled agent names
#   tiers  <agent>          -> newline list of that agent's tier names
#   all_tiers               -> newline union of every agent's tier names (first-seen order)
#   model    <agent> <tier> -> model string    (empty if unset / tier absent)
#   effort   <agent> <tier> -> effort string   (empty if unset / tier absent)
#   fallback <agent> <tier> -> fallback model  (empty if unset; agy quota-aware backup)
JSON_BACKEND=""
if command -v jq >/dev/null 2>&1; then JSON_BACKEND="jq"
elif command -v python3 >/dev/null 2>&1; then JSON_BACKEND="py"; fi

cfg_jq() {
  local op="${1:-}"; shift || true
  local a="${1:-}" t="${2:-}"
  # Every query type-guards non-object agent/tier values and emits scalars only via
  # `strings`, so jq degrades exactly like the python backend (never crashing on a
  # hand-edited, structurally-invalid config) and the two stay byte-identical.
  case "$op" in
    default_tier) jq -r '.default_tier | strings' "$CONF";;
    agents_type)  jq -r 'if type=="object" then (if has("agents") then (.agents|type) else "absent" end) else "non-object" end' "$CONF";;
    agents)       jq -r 'if (.agents|type)=="object" then (.agents|keys_unsorted[]) else empty end' "$CONF";;
    enabled)      jq -r 'if (.agents|type)=="object" then (.agents|to_entries[]|select((.value|type)=="object")|select(.value.enabled==true)|.key) else empty end' "$CONF";;
    tiers)        jq -r --arg a "$a" '(.agents // {})[$a] as $v | if ($v|type)!="object" then empty elif ($v.tiers|type)!="object" then empty else ($v.tiers|keys_unsorted[]) end' "$CONF";;
    all_tiers)    jq -r '[ (.agents // {}) | (if type=="object" then .[] else empty end) | (if type=="object" then (if (.tiers|type)=="object" then (.tiers|keys_unsorted[]) else empty end) else empty end) ] | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end) | .[]' "$CONF";;
    model)        jq -r --arg a "$a" --arg t "$t" '(.agents // {})[$a] as $v | if ($v|type)!="object" then empty elif ($v.tiers|type)!="object" then empty elif ($v.tiers[$t]|type)!="object" then empty else ($v.tiers[$t].model|strings) end' "$CONF";;
    effort)       jq -r --arg a "$a" --arg t "$t" '(.agents // {})[$a] as $v | if ($v|type)!="object" then empty elif ($v.tiers|type)!="object" then empty elif ($v.tiers[$t]|type)!="object" then empty else ($v.tiers[$t].effort|strings) end' "$CONF";;
    fallback)     jq -r --arg a "$a" --arg t "$t" '(.agents // {})[$a] as $v | if ($v|type)!="object" then empty elif ($v.tiers|type)!="object" then empty elif ($v.tiers[$t]|type)!="object" then empty else ($v.tiers[$t].fallback|strings) end' "$CONF";;
    *)            return 2;;
  esac
}

cfg_py() {
  python3 - "$CONF" "$@" <<'PY'
import json, sys
try:
    conf = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(conf, dict):
    sys.exit(1)
op = sys.argv[2] if len(sys.argv) > 2 else ""
a  = sys.argv[3] if len(sys.argv) > 3 else None
t  = sys.argv[4] if len(sys.argv) > 4 else None
_agents_raw = conf.get("agents")
agents = _agents_raw if isinstance(_agents_raw, dict) else {}
def ag(name):
    v = agents.get(name)
    return v if isinstance(v, dict) else {}
def tiers_of(name):
    v = ag(name).get("tiers")
    return v if isinstance(v, dict) else {}
def tier(name, key):
    v = tiers_of(name).get(key)
    return v if isinstance(v, dict) else {}
def jtype(v):  # JSON type names, matching jq's `type`
    if isinstance(v, bool):          return "boolean"
    if isinstance(v, dict):          return "object"
    if isinstance(v, list):          return "array"
    if isinstance(v, str):           return "string"
    if isinstance(v, (int, float)):  return "number"
    if v is None:                    return "null"
    return "unknown"
def strval(v):  # mirror jq `| strings`: emit only genuine JSON strings, else empty
    return v if isinstance(v, str) else ""
out = []
if op == "default_tier":
    out = [strval(conf.get("default_tier"))]
elif op == "agents_type":
    out = ["absent" if "agents" not in conf else jtype(conf.get("agents"))]
elif op == "agents":
    out = list(agents.keys())
elif op == "enabled":
    out = [k for k, v in agents.items() if isinstance(v, dict) and v.get("enabled") is True]
elif op == "tiers":
    out = list(tiers_of(a).keys())
elif op == "all_tiers":
    seen = []
    for v in agents.values():
        if not isinstance(v, dict):
            continue
        ts = v.get("tiers")
        if not isinstance(ts, dict):
            continue
        for k in ts:
            if k not in seen:
                seen.append(k)
    out = seen
elif op == "model":
    out = [strval(tier(a, t).get("model"))]
elif op == "effort":
    out = [strval(tier(a, t).get("effort"))]
elif op == "fallback":
    out = [strval(tier(a, t).get("fallback"))]
else:
    sys.exit(2)
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
}

cfg() {
  case "$JSON_BACKEND" in
    jq) cfg_jq "$@";;
    py) cfg_py "$@";;
    *)  return 3;;
  esac
}

# --- adapter registry (Phase 9.2): the single declarative source of per-agent facts --------------
# ADAPTER_BIN / ADAPTER_ENFORCEMENT own the per-agent POLICY data (CLI binary, read-only enforcement
# class); the thin per-CLI argv builders (argv_<agent>, below) own ONLY the argv shape. The rest of the
# driver derives its agent set, agent_bin, and the best-effort read-only NOTE from this registry, so
# adding an agent does not touch policy code. Declared here (before every consumer) on purpose.
ADAPTER_AGENTS=(agy codex claude cursor)   # the known agent set, in canonical (deterministic) order
declare -A ADAPTER_BIN=( [agy]="agy" [codex]="codex" [claude]="claude" [cursor]="cursor-agent" )
declare -A ADAPTER_ENFORCEMENT=( [agy]="best-effort" [codex]="enforced" [claude]="enforced" [cursor]="enforced" )

# The CLI binary an agent name maps to — derived from the registry (ADAPTER_BIN). Identical to the
# name for agy/codex/claude; the cursor agent's binary is `cursor-agent` (NOT `cursor`, the IDE). An
# unknown name maps to itself (the pre-registry behaviour).
agent_bin() { printf '%s' "${ADAPTER_BIN[$1]:-$1}"; }

# --- agy quota-aware fallback -----------------------------------------------------
# agy is Google's Antigravity. Bare `agy` has no scriptable quota, but the free CLI
# `antigravity-usage --json` (npm i -g antigravity-usage; the same tool council uses)
# reports per-model `remainingPercentage` (0..1) + `isExhausted`, keyed by the exact
# `agy models` label. It needs the Antigravity IDE open (or `antigravity-usage login`).
# Read-only — we never call the quota-spending `wakeup`.
#
# agy_model_status <model-label> -> available | exhausted | unknown
#   available : antigravity confirms remaining quota >= AGY_MIN_REMAINING %
#   exhausted : isExhausted, or remaining below the threshold
#   unknown   : CLI absent / IDE closed / unauthenticated / unparseable
# The caller treats anything other than "available" as a reason to use the fallback,
# so scarce 3rd-party / Opus quota is never spent without a positive confirmation.
AGY_QUOTA_CMD="${EXTERNAL_AGENTS_AGY_QUOTA_CMD:-antigravity-usage --json}"
AGY_QUOTA_TIMEOUT="${EXTERNAL_AGENTS_AGY_QUOTA_TIMEOUT:-20}"
AGY_MIN_REMAINING="${EXTERNAL_AGENTS_AGY_MIN_REMAINING:-5}"   # % remaining below which we fall back
agy_model_status() {  # <model-label>
  command -v python3 >/dev/null 2>&1 || { printf 'unknown'; return; }
  local out
  # shellcheck disable=SC2086 # AGY_QUOTA_CMD is "cmd + flags"; intentional word-split.
  out="$(timeout "$AGY_QUOTA_TIMEOUT" $AGY_QUOTA_CMD 2>/dev/null)" || { printf 'unknown'; return; }
  [ -n "$out" ] || { printf 'unknown'; return; }
  # Pass the JSON via env, NOT stdin: `python3 - <<'PY'` already consumes stdin for the
  # program, so json.load(sys.stdin) would read the (exhausted) heredoc, not the data.
  AGY_QUOTA_JSON="$out" python3 - "$1" "$AGY_MIN_REMAINING" <<'PY'
import json, os, sys
label, thr = sys.argv[1], float(sys.argv[2])
try:
    data = json.loads(os.environ.get("AGY_QUOTA_JSON", ""))
except Exception:
    print("unknown"); raise SystemExit
if not isinstance(data, dict):
    print("unknown"); raise SystemExit
for m in data.get("models", []):
    if isinstance(m, dict) and m.get("label") == label:
        if m.get("isExhausted"):
            print("exhausted"); raise SystemExit
        rp = m.get("remainingPercentage")
        if isinstance(rp, bool) or not isinstance(rp, (int, float)):
            # Label found but no usable number is NOT positive confirmation of remaining
            # quota -> treat as unknown so the caller falls back (never spend Opus blind).
            print("unknown"); raise SystemExit
        print("exhausted" if rp * 100 < thr else "available"); raise SystemExit
print("unknown")  # label not found in the antigravity output
PY
}

# Why the configured agents.json can't be read, or "" if it's fine.
conf_problem() {
  [ -n "$JSON_BACKEND" ] || { printf '%s' "reading $CONF needs 'jq' or 'python3' on PATH (neither found)"; return; }
  [ -f "$CONF" ]         || { printf '%s' "config '$CONF' not found"; return; }
  cfg default_tier >/dev/null 2>&1 || { printf '%s' "'$CONF' is not a readable JSON object"; return; }
  # Reject the most common structural mistake up front (a clear message on BOTH
  # backends) instead of silently resolving to "no agents" downstream.
  local at; at="$(cfg agents_type 2>/dev/null)"
  case "$at" in
    object|absent) printf '';;
    *) printf '%s' "'$CONF': \"agents\" must be a JSON object (found: ${at:-?})";;
  esac
}
require_conf() { local p; p="$(conf_problem)"; [ -z "$p" ] || { echo "run-agent: $p" >&2; exit 2; }; }

# --- which agents will run?  ('all' resolved against the config below) -------------
RUN=()

# --- preflight (--check): diagnostic; tolerates a missing/broken config -----------
if [ "$CHECK" = "1" ]; then
  echo "external-agents preflight:"
  missing=0
  if [ -n "$JSON_BACKEND" ]; then
    jtool="jq"; [ "$JSON_BACKEND" = "py" ] && jtool="python3"
    printf '  ok   %-7s %s (reads %s)\n' "$jtool" "$(command -v "$jtool")" "$(basename "$CONF")"
  else
    printf '  MISS %-7s need jq or python3 on PATH to read %s\n' "json" "$(basename "$CONF")"; missing=$((missing + 1))
  fi
  # A scoped --agent <name> probes just that agent; 'all'/unset probes the whole registry set.
  if [ -n "${ADAPTER_BIN[$AGENT]:-}" ]; then cand=("$AGENT"); else cand=("${ADAPTER_AGENTS[@]}"); fi
  seen=""
  for a in "${cand[@]}"; do
    case ",$seen," in *",$a,"*) continue;; esac; seen="$seen,$a"
    bin="$(agent_bin "$a")"
    if command -v "$bin" >/dev/null 2>&1; then
      printf '  ok   %-7s %s\n' "$a" "$(command -v "$bin")"
    elif [ "$bin" != "$a" ]; then
      printf '  MISS %-7s need %s on PATH\n' "$a" "$bin"; missing=$((missing + 1))
    else
      printf '  MISS %-7s not on PATH\n' "$a"; missing=$((missing + 1))
    fi
  done
  # antigravity-usage powers agy's quota-aware fallback. Optional/info-only: when absent
  # or the IDE is closed, agy's 3rd-party tiers simply fall back to their Gemini backup.
  case " ${cand[*]} " in
    *" agy "*)
      # Probe via PATH only, exactly as the runtime quota call resolves AGY_QUOTA_CMD —
      # a binary in ~/.local/bin but off PATH is unreachable at run time, so don't claim it.
      if command -v antigravity-usage >/dev/null 2>&1; then
        printf '  info agy-qta antigravity-usage present (agy 3rd-party fallback active; needs Antigravity IDE open / login)\n'
      else
        printf '  info agy-qta antigravity-usage not on PATH — agy high/xhigh always use the Gemini fallback (npm i -g antigravity-usage)\n'
      fi;;
  esac
  echo "external-agents: $missing missing"
  [ "$missing" -eq 0 ]; exit $?
fi

# --- discovery (--discover): machine-readable reachable-agent set for a harness ---
# Like --check, but emits ONE parseable line per candidate agent so a caller (e.g.
# tests/live-smoke.sh) can scope itself to the installed set without parsing the
# human-readable preflight. Format:  "<agent> <present|missing> <bin-or-path>".
# Presence (command -v via agent_bin) is the cheap, offline signal; live auth is left
# to the harness. Config-independent, like --check, so it never needs agents.json.
if [ "$DISCOVER" = "1" ]; then
  # A scoped --agent <name> lists just that agent; 'all'/unset lists the whole registry set.
  if [ -n "${ADAPTER_BIN[$AGENT]:-}" ]; then dcand=("$AGENT"); else dcand=("${ADAPTER_AGENTS[@]}"); fi
  dseen=""
  for a in "${dcand[@]}"; do
    case ",$dseen," in *",$a,"*) continue;; esac; dseen="$dseen,$a"
    bin="$(agent_bin "$a")"
    if command -v "$bin" >/dev/null 2>&1; then
      printf '%s present %s\n' "$a" "$(command -v "$bin")"
    else
      printf '%s missing %s\n' "$a" "$bin"
    fi
  done
  exit 0
fi

# Everything past here needs a readable agents.json.
require_conf
DEFAULT_TIER="$(cfg default_tier)"

# --- --list: print the parsed config (tiers + enabled) and exit -------------------
if [ "$LIST" = "1" ]; then
  echo "external-agents config ($CONF):"
  echo "  default tier: ${DEFAULT_TIER:-(none)}"
  any=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    any=1
    en="disabled"; cfg enabled | grep -qxF -- "$a" && en="enabled"
    printf '  %-7s [%s]\n' "$a" "$en"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      mm="$(cfg model "$a" "$t")"; ee="$(cfg effort "$a" "$t")"; fbl="$(cfg fallback "$a" "$t")"
      disp="${mm:-(cli default)}"; [ -n "$fbl" ] && disp="$disp  (fallback: $fbl)"
      if [ -n "$ee" ]; then printf '    %-7s -> %-28s effort=%s\n' "$t" "$disp" "$ee"
      else                  printf '    %-7s -> %s\n' "$t" "$disp"; fi
    done < <(cfg tiers "$a")
  done < <(cfg agents)
  [ "$any" = "1" ] || echo "  (no agents configured)"
  exit 0
fi

# Resolve 'all' to the enabled set; otherwise the single named agent.
if [ "$AGENT" = "all" ]; then
  while IFS= read -r a; do [ -n "$a" ] && RUN+=("$a"); done < <(cfg enabled)
  [ "${#RUN[@]}" -gt 0 ] || { echo "run-agent: --agent all but no agents enabled in $CONF" >&2; exit 2; }
elif [ -n "$AGENT" ]; then
  if [ -n "${ADAPTER_BIN[$AGENT]:-}" ]; then
    RUN=("$AGENT")
  else
    agent_hint="$(IFS='|'; printf '%s' "${ADAPTER_AGENTS[*]}")"   # registry-derived: agy|codex|claude|cursor
    echo "run-agent: unknown agent '$AGENT' (want $agent_hint|all)" >&2; exit 2
  fi
fi

# --- validate the run request -----------------------------------------------------
[ -n "$AGENT" ] || { echo "run-agent: --agent is required (agy|codex|claude|cursor|all)" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "run-agent: --target '$TARGET' is not a directory" >&2; exit 2; }

# A non-numeric or zero --timeout would otherwise defer to an opaque per-agent
# `timeout` failure at launch; reject it once, up front, with a clear message.
case "$TIMEOUT" in
  ''|*[!0-9]*) echo "run-agent: --timeout must be a positive integer of seconds (got '$TIMEOUT')" >&2; exit 2;;
esac
[ "$TIMEOUT" -gt 0 ] || { echo "run-agent: --timeout must be a positive integer of seconds (got '$TIMEOUT')" >&2; exit 2; }

# The requested effort level is a model TIER. Blank --effort -> config default_tier.
TIER="${EFFORT:-$DEFAULT_TIER}"
# Validate only a USER-supplied --effort (to catch typos). A stale default_tier never
# hard-aborts the run: it falls through to the per-agent fallback note below. Match the
# tier as a FIXED string (grep -F), not a regex, so e.g. --effort '.*' can't slip past.
if [ -n "$EFFORT" ] && ! cfg all_tiers | grep -qxF -- "$EFFORT"; then
  echo "run-agent: unknown effort tier '$EFFORT'" >&2
  echo "  valid tiers in $CONF: $(cfg all_tiers | paste -sd '|' -)" >&2
  echo "  (--effort must name a tier defined in $CONF; --model overrides only the model within a valid tier)" >&2
  exit 2
fi
# A running agent with no mapping for the requested tier falls back to its cli default.
if [ -n "$TIER" ] && [ -z "$MODEL" ]; then
  for a in "${RUN[@]}"; do
    cfg tiers "$a" | grep -qxF -- "$TIER" || echo "run-agent: NOTE — '$a' has no '$TIER' tier in $CONF; using its cli-default model/effort." >&2
  done
fi

# Resolve physically (pwd -P) so symlinked targets/installs can't slip past the
# prefix checks below — the kernel resolves cd "$TARGET" physically at launch anyway.
TARGET="$(cd "$TARGET" && pwd -P)"
INVOKED_FROM="$(pwd -P)"

# Write-mode safety gates (skipped for --dry-run, which launches nothing).
if [ "$MODE" = "write" ] && [ "$DRYRUN" = "0" ]; then
  # 1. Keep writing agents out of the plugin's own tree, in BOTH directions:
  #    target inside the plugin, or target an ancestor that contains the plugin
  #    (e.g. the monorepo root, which would also expose every sibling repo).
  case "$TARGET/" in "$PLUGIN_ROOT/"*) echo "run-agent: refusing to write inside the plugin tree ($PLUGIN_ROOT). Use --target or --read-only." >&2; exit 2;; esac
  case "$PLUGIN_ROOT/" in "$TARGET/"*) echo "run-agent: refusing to write with --target '$TARGET' — it contains the plugin tree (and likely sibling repos). Narrow --target or use --read-only." >&2; exit 2;; esac
  # 2. A write target that isn't the directory you launched from is the classic
  #    foot-gun (wrong tree, monorepo root, private IP). Require an explicit --yes.
  if [ "$TARGET" != "$INVOKED_FROM" ] && [ "$YES" = "0" ]; then
    {
      echo "run-agent: write run on a non-cwd target needs confirmation."
      echo "  target : $TARGET"
      echo "  agents : ${RUN[*]}  (agy/codex/cursor ship this whole tree to EXTERNAL providers)"
      echo "  re-run with --yes once you've confirmed the scope, or use --read-only."
    } >&2
    exit 2
  fi
fi

# Resolve the prompt (literal --prompt, a file, or stdin via --prompt-file -).
if [ -n "$PROMPT_FILE" ]; then
  if [ "$PROMPT_FILE" = "-" ]; then PROMPT="$(cat)"; else
    [ -f "$PROMPT_FILE" ] || { echo "run-agent: --prompt-file '$PROMPT_FILE' not found" >&2; exit 2; }
    PROMPT="$(cat "$PROMPT_FILE")"
  fi
fi
[ -n "$PROMPT" ] || { echo "run-agent: empty prompt (pass --prompt or --prompt-file)" >&2; exit 2; }

# project id mirrors run-council.sh: a sub-dir of a repo nests under <repo>/<leaf>.
LEAF="$(basename "$TARGET")"
TOP="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
if   [ -n "$TOP" ] && [ "$TARGET" != "$TOP" ]; then PROJECT="$(basename "$TOP")/$LEAF"
elif [ -n "$TOP" ]; then PROJECT="$(basename "$TOP")"
else PROJECT="$LEAF"; fi
[ -z "$OUT" ] && OUT="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/$PROJECT"
if [ "$DRYRUN" = "0" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"; fi
# Run index (Phase 5.2): an append-only JSON-Lines history under the transcript base — the
# EXTERNAL_AGENTS_OUT base (default ~/.external-agents/logs), or the explicit --out dir when given.
# RUN_ID groups the agents of this one invocation (a --agent all fan-out shares it).
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo run)-$$"
if [ -n "$OUT_SET" ]; then INDEX_BASE="$OUT"; else INDEX_BASE="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"; fi
INDEX="$INDEX_BASE/index.jsonl"

# agy --sandbox is best-effort, NOT a hard write barrier (see header) — warn so a
# read-only run is never mistaken for an enforced guarantee.
if [ "$MODE" = "readonly" ]; then
  for a in "${RUN[@]}"; do [ "${ADAPTER_ENFORCEMENT[$a]:-}" = "best-effort" ] && { echo "run-agent: NOTE — agy read-only relies on --sandbox, which is best-effort and may still permit writes. For a hard guarantee use codex/claude/cursor, or target a throwaway copy." >&2; break; }; done
fi
# A write run with no git baseline has no diff/revert recovery path — warn.
if [ "$MODE" = "write" ] && [ "$DRYRUN" = "0" ] && [ -z "$TOP" ]; then
  echo "run-agent: NOTE — --target is not a git repo; no baseline to diff or revert after writes. Consider 'git init' or a backup first." >&2
fi

# Per-CLI argv builders (Phase 9.2) — each sets ARGV[] and PROMPT_IDX for ONE agent, byte-identical to the pre-9.2
# inline case. They consume the resolved model/effort ($1/$2) plus the globals MODE/PROMPT/TARGET/
# CLAUDE_PERM; the agy quota fallback has already resolved $1 by the time argv_agy runs.
argv_agy() {
  local m="$1"
  ARGV=(agy -p "$PROMPT" --add-dir "$TARGET"); PROMPT_IDX=2
  [ "$MODE" = "readonly" ] && ARGV+=(--sandbox) || ARGV+=(--dangerously-skip-permissions)
  [ -n "$m" ] && ARGV+=(--model "$m")
}
argv_codex() {
  local m="$1" e="$2"
  if [ "$MODE" = "readonly" ]; then ARGV=(codex exec -s read-only -C "$TARGET" --skip-git-repo-check)
  else ARGV=(codex exec -s workspace-write -C "$TARGET" --skip-git-repo-check); fi
  [ -n "$m" ] && ARGV+=(-m "$m")
  [ -n "$e" ] && ARGV+=(-c "model_reasoning_effort=\"$e\"")
  ARGV+=("$PROMPT"); PROMPT_IDX=$(( ${#ARGV[@]} - 1 ))
}
argv_claude() {
  local m="$1" e="$2"
  if [ "$MODE" = "readonly" ]; then ARGV=(claude -p "$PROMPT" --allowedTools Read Grep Glob)
  else ARGV=(claude -p "$PROMPT" --permission-mode "$CLAUDE_PERM"); fi
  PROMPT_IDX=2
  [ -n "$m" ] && ARGV+=(--model "$m")
  [ -n "$e" ] && ARGV+=(--effort "$e")
}
argv_cursor() {
  # cursor-agent: -p headless print mode; the prompt is the trailing positional after `--`, which ends
  # option parsing so a prompt starting with '-' can't be read as a flag. --trust avoids the
  # non-interactive workspace-trust prompt; readonly -> --mode plan (enforced), write -> --force.
  local m="$1"
  if [ "$MODE" = "readonly" ]; then ARGV=(cursor-agent -p --mode plan --trust --workspace "$TARGET")
  else ARGV=(cursor-agent -p --force --trust --workspace "$TARGET"); fi
  [ -n "$m" ] && ARGV+=(--model "$m")
  ARGV+=(-- "$PROMPT"); PROMPT_IDX=$(( ${#ARGV[@]} - 1 ))
}

# --- build one agent's argv  (model/effort resolved from the tier) ----------------
build_argv() {  # agent ; sets global ARGV[], RESOLVED_MODEL, FALLBACK_TAKEN, PROMPT_IDX
  local a="$1" m e fb st
  [ -n "${ADAPTER_BIN[$a]:-}" ] || { echo "run-agent: unknown agent '$a'" >&2; return 1; }
  m="${MODEL:-$(cfg model "$a" "$TIER")}"
  e="$(cfg effort "$a" "$TIER")"
  FALLBACK_TAKEN=0          # set to 1 below iff the agy quota fallback swaps the primary model
  # Quota-aware model pick (control-plane policy; only agy tiers carry a 'fallback'): use the limited
  # 3rd-party primary ONLY when its quota is positively confirmed available; on exhausted OR unknown
  # (IDE closed / antigravity-usage unavailable) drop to the larger-limit Gemini fallback, so scarce
  # 3rd-party / Opus quota is never spent unconfirmed. A --model override is explicit intent and skips it.
  fb="$(cfg fallback "$a" "$TIER")"
  if [ -z "$MODEL" ] && [ -n "$m" ] && [ -n "$fb" ]; then
    st="$(agy_model_status "$m")"
    case "$st" in
      available) ;;
      unknown) echo "run-agent: NOTE — agy quota for '$m' is unknown (open the Antigravity IDE or run 'antigravity-usage login' to enable it); using fallback '$fb'." >&2; m="$fb"; FALLBACK_TAKEN=1;;
      *)       echo "run-agent: NOTE — agy '$m' is $st per antigravity-usage; using fallback '$fb'." >&2; m="$fb"; FALLBACK_TAKEN=1;;
    esac
  fi
  ARGV=()
  "argv_$a" "$m" "$e"       # dispatch to the thin per-CLI argv builder (byte-identical to pre-9.2)
  RESOLVED_MODEL="$m"       # the model actually used (post-fallback for agy); may be empty (cli default)
  return 0
}

# redact — best-effort, length-bounded masking of secret-shaped tokens in transcript
# text (stdin -> stdout). NOT a guarantee of total secret removal (see README Safety):
# masks known token prefixes (sk-/pk-, gh*_/github_pat_, xox*-, AKIA…), Bearer tokens,
# KEY=/TOKEN=/SECRET=/PASSWORD= assignments, and a generic long high-entropy run.
redact() {
  sed -E \
    -e 's/(sk|pk)-[A-Za-z0-9_-]{20,}/\1-<REDACTED>/g' \
    -e 's/(gh[posru]|github_pat)_[A-Za-z0-9_]{20,}/\1_<REDACTED>/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/xox-<REDACTED>/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA<REDACTED>/g' \
    -e 's#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/-]{20,}#\1<REDACTED>#g' \
    -e 's/(([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD))[[:space:]]*[=:][[:space:]]*)[^[:space:]]{8,}/\1<REDACTED>/Ig' \
    -e 's#[A-Za-z0-9+/]{40,}={0,2}#<REDACTED>#g'
}

# format_masked_argv — render the current ARGV[] (built by build_argv) as a single line
# with the prompt token at PROMPT_IDX shown as <PROMPT> and any space-bearing token
# single-quoted. BOTH the --dry-run printer and run_one's launch record call this, so a
# recorded live argv is byte-identical to the --dry-run argv by construction — and the
# record never contains the prompt text (secret/PII safe).
format_masked_argv() {
  local i tok line=""
  for i in "${!ARGV[@]}"; do
    tok="${ARGV[$i]}"
    if [ "$i" = "$PROMPT_IDX" ]; then tok="<PROMPT>"
    else case "$tok" in *[[:space:]]*) tok="'$tok'";; esac
    fi
    line="$line $tok"
  done
  printf '%s' "${line# }"
}

# write_meta_json FILE agent model tier effort mode target rc sec bytes fallback timestamp tokens cost error_class attempts retried
# Emit the Phase 5.1 per-run metadata record as ONE JSON object (safe escaping via the same
# jq/python3 backend the config reads through). It carries ONLY control-plane facts the driver
# resolved at launch/collect — never transcript text — so it never leaks an agent's free-text or
# the prompt. `fallback` is passed as "1"/"0" and rendered as a JSON boolean; rc/sec/bytes render
# as JSON numbers (falling back to the raw string if non-numeric). `tokens`/`cost` are the Phase 5.3
# best-effort signals: a numeric token count renders as a number, the cost string is kept verbatim,
# and the literal "unavailable" passes through unchanged (never a fabricated number).
# The emitted field set + JSON types are the published contract in schema/run-record.schema.json
# (a tests/run.sh drift guard fails if this emitter's keys and the schema's properties diverge).
write_meta_json() {
  local file="$1"; shift
  case "$JSON_BACKEND" in
    py)
      python3 - "$@" >"$file" <<'PY'
import json, sys
a = sys.argv[1:]
def num(x):
    try: return int(x)
    except (ValueError, TypeError): return x
def sig(x):
    return int(x) if x.isdigit() else x   # numeric token count -> number; "unavailable"/cost kept as-is
print(json.dumps({
    "agent": a[0], "model": a[1], "tier": a[2], "effort": a[3], "mode": a[4],
    "target": a[5], "rc": num(a[6]), "sec": num(a[7]), "bytes": num(a[8]),
    "fallback": a[9] == "1", "timestamp": a[10], "error_class": a[13],
    "attempts": num(a[14]), "retried": a[15] == "1",
    "signals": {"tokens": sig(a[11]), "cost": a[12]},
}, separators=(",", ":")))
PY
      ;;
    jq)
      jq -nc \
        --arg agent "$1" --arg model "$2" --arg tier "$3" --arg effort "$4" --arg mode "$5" \
        --arg target "$6" --arg rc "$7" --arg sec "$8" --arg bytes "$9" --arg fb "${10}" --arg ts "${11}" \
        --arg tok "${12}" --arg cost "${13}" --arg ec "${14}" --arg att "${15}" --arg rt "${16}" \
        '{agent:$agent, model:$model, tier:$tier, effort:$effort, mode:$mode, target:$target,
          rc:($rc|tonumber? // $rc), sec:($sec|tonumber? // $sec), bytes:($bytes|tonumber? // $bytes),
          fallback:($fb=="1"), timestamp:$ts, error_class:$ec,
          attempts:($att|tonumber? // $att), retried:($rt=="1"),
          signals:{tokens:($tok|if test("^[0-9]+$") then tonumber else . end), cost:$cost}}' >"$file"
      ;;
  esac
}

# extract_signal TRANSCRIPT AGENT SIGNAL -> the best-effort signal value, or empty if none recognized.
# Phase 5.3 cost/latency extraction: capability-aware per agent (currently a shared, conservative
# recognizer for every known agent — the per-agent case is the hook for future agent-specific rules),
# matching ONLY tightly-anchored shapes so ordinary transcript prose is never mistaken for a metric.
# The caller maps an empty result to the explicit "unavailable" marker — never a fabricated number.
extract_signal() {
  local file="$1" agent="$2" signal="$3" line
  [ -f "$file" ] || return 0
  case "$agent" in agy|codex|claude|cursor) : ;; *) return 0;; esac
  case "$signal" in
    tokens)
      line="$(grep -ioE '(tokens[[:space:]]+used|total[[:space:]]+tokens)[[:space:]]*[:=][[:space:]]*[0-9]+|[0-9]+[[:space:]]+tokens' "$file" 2>/dev/null | head -1)"
      [ -n "$line" ] && printf '%s' "$line" | grep -oE '[0-9]+' | head -1
      ;;
    cost)
      line="$(grep -ioE '(total[[:space:]]+)?cost[[:space:]]*[:=][[:space:]]*\$[0-9]+(\.[0-9]+)?' "$file" 2>/dev/null | head -1)"
      [ -n "$line" ] && printf '%s' "$line" | grep -oE '\$[0-9]+(\.[0-9]+)?' | head -1
      ;;
  esac
}

# append_index_row INDEX META RUN_ID PROJECT
# Append ONE JSON-Lines row to the run index: the agent's per-run metadata record augmented with the
# run id (groups a fan-out) and the project namespace. Append-only and control-plane only (the meta
# record already is), so the index never accrues transcript text. No-op if the meta record is absent.
# Read-only cross-run trends over this index are produced by scripts/run-history-report.sh; bounded
# rotation/retention (atomic-rename to a timestamped archive) is performed by scripts/run-history-maintain.sh;
# backup/restore of this index (content-identical) is documented in RUNBOOK.md.
append_index_row() {
  local index="$1" meta="$2" run_id="$3" project="$4"
  [ -f "$meta" ] || return 0
  case "$JSON_BACKEND" in
    py)
      RUN_ID="$run_id" PROJECT="$project" python3 - "$meta" >>"$index" <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
row = {"run_id": os.environ.get("RUN_ID", ""), "timestamp": d.get("timestamp", ""),
       "project": os.environ.get("PROJECT", "")}
row.update(d)
print(json.dumps(row, separators=(",", ":")))
PY
      ;;
    jq)
      jq -c --arg run_id "$run_id" --arg project "$project" \
        '{run_id:$run_id, timestamp:.timestamp, project:$project} + .' "$meta" >>"$index"
      ;;
  esac
}

# --- error taxonomy (Phase 8.2) ---------------------------------------------------
# A run's outcome is classified into ONE of a CLOSED set of error classes so a caller can tell a
# recoverable failure from a permanent one. This comment is the canonical map; it MUST agree with the
# "Error classification" subsection in README.md and docs/threat-model.md.
#
#   class           meaning                                                         retryable?
#   ok              the run succeeded (rc 0); not an error                          n/a (success)
#   safety-refusal  a driver pre-launch gate refused: containment, the non-cwd      NEVER — retrying
#                   --yes confirmation, --read-only/--write exclusion, or an        repeats the same
#                   invalid --timeout. A deliberate guard, not a transient state.   deliberate refusal
#   timeout         the run exceeded --timeout (the timeout wrapper killed it)      retryable (opt-in)
#   transient       a recoverable external failure (network blip, provider 5xx /   retryable
#                   rate-limit shaped)
#   auth            the agent is unauthenticated / its credentials were rejected    NO (re-auth first)
#   contract        the agent broke the expected contract (malformed/empty output)  NO
#   unknown         an unclassified non-zero exit                                   NO (conservative)
#
# Retryable subset = { transient (always), timeout (opt-in) }. safety-refusal is NEVER retryable.
#
# classify_outcome GATE RC ERRFILE -> exactly one class from the closed set above.
#   GATE non-empty -> a pre-launch safety gate refused (classified before launch) -> safety-refusal.
#   else the class is derived from rc + a conservative, anchored stderr signal. Computed ONCE in shell
#   and handed to the emitter so the jq and python3 backends cannot diverge.
classify_outcome() {
  local gate="$1" rc="$2" errf="${3:-}" err="" errl=""
  [ -n "$gate" ] && { printf 'safety-refusal'; return 0; }
  [ "$rc" = "0" ] && { printf 'ok'; return 0; }
  [ "$rc" = "124" ] && { printf 'timeout'; return 0; }   # timeout(1) exits 124 when it kills the child
  [ -f "$errf" ] && err="$(cat "$errf" 2>/dev/null)"
  errl="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')"
  case "$errl" in
    *unauthorized*|*"authentication failed"*|*"not logged in"*|*"invalid api key"*|*"please log in"*)
      printf 'auth'; return 0;;
  esac
  case "$errl" in
    *"rate limit"*|*"rate-limit"*|*"429"*|*"503"*|*"502"*|*"504"*|*"service unavailable"*|*"temporarily unavailable"*|*"connection reset"*|*econnreset*|*"timed out"*|*"try again"*|*"network error"*)
      printf 'transient'; return 0;;
  esac
  case "$errl" in
    *malformed*|*"unexpected response"*|*"protocol error"*|*"parse error"*|*"invalid response"*|*"empty response"*)
      printf 'contract'; return 0;;
  esac
  printf 'unknown'
}

run_one() {  # agent  (cwd=TARGET) — stdout->$OUT/<a>.md (redacted), stderr->.err, rc/.sec, .meta.json
  local a="$1" t0 t1 rc ts bytes reff tok cost ec
  local rmax="${EXTERNAL_AGENTS_RETRY_MAX:-0}" rbackoff="${EXTERNAL_AGENTS_RETRY_BACKOFF:-1}"
  local ron_to="${EXTERNAL_AGENTS_RETRY_ON_TIMEOUT:-0}" attempt=0 retried=0 retryable
  build_argv "$a" || return 1
  # Record the resolved launch argv with the prompt masked — identical to --dry-run — so a
  # live run's exact argv can be verified without ever persisting the prompt text.
  format_masked_argv >"$OUT/$a.argv"
  # Record the control-plane facts build_argv resolved (post-fallback model, whether the agy
  # quota fallback was taken) so the collect loop builds the per-agent record without re-parsing.
  printf '%s' "$RESOLVED_MODEL"  >"$OUT/$a.model"
  printf '%s' "$FALLBACK_TAKEN"  >"$OUT/$a.fallback"
  t0=$(date +%s 2>/dev/null || echo 0)
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"   # first-attempt launch time, UTC ISO-8601
  # Phase 8.2 — bounded retry/backoff: re-run ONLY a retryable outcome (transient; timeout opt-in via
  # EXTERNAL_AGENTS_RETRY_ON_TIMEOUT=1) up to EXTERNAL_AGENTS_RETRY_MAX times (default 0 = no retry),
  # waiting EXTERNAL_AGENTS_RETRY_BACKOFF seconds between attempts. A safety-refusal cannot occur here
  # (the gates refuse before launch) so it is never retried by construction. Each attempt overwrites
  # the transcript; the LAST attempt's transcript/rc/class is the recorded outcome.
  while : ; do
    attempt=$((attempt + 1))
    # Pipe stdout through redact so a secret-shaped token never persists to disk or echo;
    # rc is the agent's (PIPESTATUS[0]), not redact's.
    ( cd "$TARGET" && timeout "$TIMEOUT" "${ARGV[@]}" ) 2>"$OUT/$a.err" | redact >"$OUT/$a.md"
    rc=${PIPESTATUS[0]}
    ec="$(classify_outcome "" "$rc" "$OUT/$a.err")"
    retryable=0
    case "$ec" in
      transient) retryable=1;;
      timeout)   [ "$ron_to" = "1" ] && retryable=1;;
    esac
    if [ "$retryable" = "1" ] && [ "$attempt" -le "$rmax" ]; then
      retried=1
      if [ "$rbackoff" != "0" ]; then sleep "$rbackoff" 2>/dev/null || true; fi
      continue
    fi
    break
  done
  t1=$(date +%s 2>/dev/null || echo 0)
  echo "$rc" >"$OUT/$a.rc"; echo "$((t1 - t0))" >"$OUT/$a.sec"
  # Phase 5.1 — durable, structured per-run metadata record: one JSON object per agent next to its
  # transcript, built ONLY from values resolved here (post-fallback model, run mode, target, rc/sec/
  # bytes, fallback flag, launch timestamp) — never the transcript — so the run's resolution is
  # inspectable without re-parsing free-text output. `bytes` matches the collect loop's measure.
  bytes=$(wc -c <"$OUT/$a.md" 2>/dev/null | tr -d ' '); [ -n "$bytes" ] || bytes=0
  reff="$(cfg effort "$a" "$TIER")"
  # Phase 5.3 — best-effort cost/latency signals from the (redacted) transcript; absent -> "unavailable".
  tok="$(extract_signal "$OUT/$a.md" "$a" tokens)";  [ -n "$tok" ]  || tok="unavailable"
  cost="$(extract_signal "$OUT/$a.md" "$a" cost)";   [ -n "$cost" ] || cost="unavailable"
  # error_class was classified in the retry loop above (the last attempt's outcome). append_index_row
  # inherits error_class/attempts/retried via the record spread. attempts/retried are additive fields.
  write_meta_json "$OUT/$a.meta.json" "$a" "${RESOLVED_MODEL:-(cli default)}" "${TIER:-(none)}" \
    "${reff:-(none)}" "$MODE" "$TARGET" "$rc" "$((t1 - t0))" "$bytes" "$FALLBACK_TAKEN" "$ts" "$tok" "$cost" "$ec" "$attempt" "$retried"
}

# --- dry-run: print resolved argv and exit ----------------------------------------
if [ "$DRYRUN" = "1" ]; then
  echo "external-agents dry-run  (mode=$MODE  tier=${TIER:-(none)}  target=$TARGET)"
  for a in "${RUN[@]}"; do
    build_argv "$a" || continue
    printf '  %-7s %s\n' "$a" "$(format_masked_argv)"
  done
  exit 0
fi

# --- run (parallel for 'all') -----------------------------------------------------
echo "external-agents: $AGENT on $PROJECT ($TARGET)  mode=$MODE  tier=${TIER:-(none)}  timeout=${TIMEOUT}s" >&2
PIDS=()
for a in "${RUN[@]}"; do
  bmodel="${MODEL:-$(cfg model "$a" "$TIER")}"
  # agy tiers with a fallback resolve their model at launch via the quota check, so the
  # primary shown here may be swapped for the Gemini fallback — mark it (build_argv's NOTE
  # reports the actual pick). Skip the marker when --model pins the model explicitly.
  [ "$a" = "agy" ] && [ -z "$MODEL" ] && [ -n "$(cfg fallback "$a" "$TIER")" ] && bmodel="$bmodel (quota-checked)"
  printf '  -> %-7s model=%-26s effort=%s\n' "$a" "$bmodel" "$(cfg effort "$a" "$TIER")" >&2
  run_one "$a" & PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done

# --- collect: echo every transcript to stdout, summarise to stderr ----------------
# RECORDS[] holds one per-agent result record (tab-delimited control-plane facts:
# agent, model, tier, effort, mode, rc, sec, bytes, fallback), built ONLY from values already
# resolved at launch/collect time — run_one's .model/.fallback sidecars, the config, and the run
# files — never from the transcript. The summary/JSON views render these.
ok=0; fail=0
RECORDS=()
for a in "${RUN[@]}"; do
  rc="$(cat "$OUT/$a.rc" 2>/dev/null || echo '?')"
  sec="$(cat "$OUT/$a.sec" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$OUT/$a.md" 2>/dev/null | tr -d ' ')
  rmodel="$(cat "$OUT/$a.model" 2>/dev/null)"
  rfb="$(cat "$OUT/$a.fallback" 2>/dev/null)"; [ -n "$rfb" ] || rfb=0
  reff="$(cfg effort "$a" "$TIER")"
  rec="$a"$'\t'"${rmodel:-(cli default)}"$'\t'"${TIER:-(none)}"$'\t'"${reff:-(none)}"$'\t'"$MODE"$'\t'"$rc"$'\t'"$sec"$'\t'"${bytes:-0}"$'\t'"$rfb"
  RECORDS+=("$rec")
  printf '%s\n' "$rec" >"$OUT/$a.record"
  echo "===== $a (rc=$rc ${sec}s ${bytes:-0} bytes) ====="
  cat "$OUT/$a.md" 2>/dev/null
  if [ "$rc" != "0" ] || [ "${bytes:-0}" -lt 1 ]; then
    echo "----- $a stderr -----"; redact <"$OUT/$a.err" 2>/dev/null
  fi
  echo
  if [ "$rc" = "0" ] && [ "${bytes:-0}" -gt 0 ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done
# Deterministic outcome agreement from the per-agent success tally (used by both the human summary
# and the opt-in JSON). all-ok = every agent succeeded; all-fail = none did; else mixed.
if [ "$fail" -eq 0 ]; then AGREEMENT="all-ok"; elif [ "$ok" -eq 0 ]; then AGREEMENT="all-fail"; else AGREEMENT="mixed"; fi
# Cross-agent summary: a compact digest with one row per fan-out agent, rendered from the Phase
# 4.1 records — beside (not instead of) the verbatim transcripts above. Fan-out only; single-agent
# runs print no summary, and the transcript echo + the stderr tally are unchanged.
if [ "${#RUN[@]}" -gt 1 ]; then
  echo "===== fan-out summary ====="
  printf '  %-7s %-3s %-26s %-7s %5s %8s %s\n' agent rc model tier sec bytes fallback
  for rec in "${RECORDS[@]}"; do
    IFS=$'\t' read -r s_a s_model s_tier _ _ s_rc s_sec s_bytes s_fb <<<"$rec"
    printf '  %-7s %-3s %-26s %-7s %5s %8s %s\n' "$s_a" "$s_rc" "$s_model" "$s_tier" "$s_sec" "$s_bytes" "$s_fb"
  done
  # On a write fan-out every agent shares ONE target tree, so the post-write git verification
  # below is TARGET-WIDE — it cannot attribute a change to a specific agent. Say so explicitly.
  [ "$MODE" = "write" ] && echo "  note: write fan-out — the 'git changes after write' block is target-wide (all agents share one tree), not per-agent attribution."
  # For a read-only fan-out on a git target, surface whether the shared tree is unchanged — every
  # agent's read-only mode should leave it byte-identical (agy is best-effort). Deterministic and
  # content-free, generalising the post-write git check to read-only.
  if [ "$MODE" = "readonly" ] && [ -n "$TOP" ]; then
    if [ -z "$(git -C "$TARGET" status --porcelain 2>/dev/null)" ]; then
      echo "  no-mutation: all agents left the tree unchanged (read-only)"
    else
      echo "  no-mutation: the tree is NOT clean after a read-only fan-out (agy is best-effort, or pre-existing changes — inspect 'git status')"
    fi
  fi
  # Render the deterministic outcome agreement (computed above) — an OUTCOME signal, not semantic
  # content agreement (which needs a confirmed schema).
  case "$AGREEMENT" in
    all-ok)   echo "  agreement: all-ok ($ok/$((ok + fail)) agents succeeded)";;
    all-fail) echo "  agreement: all-fail (0/$((ok + fail)) agents succeeded)";;
    *)        echo "  agreement: mixed ($ok ok, $fail failed)";;
  esac
  echo
fi
# After a write run, PRODUCE the verification (not just recommend it): show what
# actually changed in the target's git tree so the caller can inspect before trusting.
if [ "$MODE" = "write" ] && [ -n "$TOP" ]; then
  echo "===== git changes after write (in $TARGET) ====="
  git -C "$TARGET" status --porcelain 2>/dev/null
  git -C "$TARGET" --no-pager diff --stat 2>/dev/null
  echo
fi
# Opt-in JSON run summary (--json) — emitted in ADDITION to the default output above (which stays
# byte-for-byte unchanged when --json is absent). One object per agent built from the Phase 4.1
# RECORDS (control-plane facts only — NO transcript content), plus the agreement signal and an
# outcome count. Built with python3/jq for safe escaping; records are fed in tab-delimited.
if [ "$JSON" = "1" ]; then
  if   command -v python3 >/dev/null 2>&1; then
    printf '%s\n' ${RECORDS[@]+"${RECORDS[@]}"} | python3 -c '
import json, sys
def num(x): return int(x) if x.lstrip("-").isdigit() else x
agents = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    f = (line.split("\t") + [""] * 9)[:9]
    agents.append({"agent": f[0], "model": f[1], "tier": f[2], "effort": f[3], "mode": f[4],
                   "rc": num(f[5]), "sec": num(f[6]), "bytes": num(f[7]), "fallback": f[8] == "1"})
print(json.dumps({"mode": sys.argv[1], "tier": sys.argv[2], "ok": int(sys.argv[3]),
                  "fail": int(sys.argv[4]), "count": len(agents), "agreement": sys.argv[5],
                  "agents": agents}))
' "$MODE" "${TIER:-}" "$ok" "$fail" "$AGREEMENT"
  elif command -v jq >/dev/null 2>&1; then
    printf '%s\n' ${RECORDS[@]+"${RECORDS[@]}"} \
      | jq -R 'split("\t") | {agent:.[0], model:.[1], tier:.[2], effort:.[3], mode:.[4], rc:(.[5]|tonumber? // .[5]), sec:(.[6]|tonumber? // .[6]), bytes:(.[7]|tonumber? // .[7]), fallback:(.[8]=="1")}' \
      | jq -s --arg mode "$MODE" --arg tier "${TIER:-}" --argjson ok "$ok" --argjson fail "$fail" --arg agreement "$AGREEMENT" \
          '{mode:$mode, tier:$tier, ok:$ok, fail:$fail, count:length, agreement:$agreement, agents:.}'
  fi
fi
# Append one run-index row per agent (Phase 5.2) from its per-run metadata record — a durable,
# cross-run history without walking the transcript tree. Best-effort: a write failure never fails the
# run (the transcripts and per-run records still stand).
mkdir -p "$INDEX_BASE" 2>/dev/null || true
for a in "${RUN[@]}"; do append_index_row "$INDEX" "$OUT/$a.meta.json" "$RUN_ID" "$PROJECT"; done
echo "external-agents: $ok ok, $fail failed  (transcripts in $OUT)" >&2
[ "$fail" -eq 0 ]

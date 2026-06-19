#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/scripts/run-agent.sh — dispatch ONE prompt to external coding
# agent CLIs (agy / codex / claude) as autonomous sub-agents, then collect each
# agent's response. This generalises council/run-council.sh from a fixed,
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
#
#   READ-ONLY  (--read-only — agents observe and report; codex/claude are HARD
#               read-only, agy is best-effort):
#     agy     agy -p PROMPT --sandbox --add-dir DIR [--model M]
#             NOTE: agy --sandbox restricts the terminal but does NOT block agy's
#             file-edit tools, so agy read-only is best-effort, NOT enforced. Use
#             codex/claude for a hard guarantee, or point --target at a throwaway copy.
#     codex   codex exec -s read-only -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] PROMPT
#     claude  claude -p PROMPT --allowedTools Read Grep Glob [--model M] [--effort E]
#
#   (agy and claude run with cwd=DIR; codex takes -C DIR.)
#
# EFFORT TIERS.  The caller picks ONE semantic effort level — low | medium | high |
# xhigh — and agents.json maps that tier to the right (model, native effort) for
# EACH agent. So a single `--effort high` resolves, per agent, to e.g.:
#     agy    -> Gemini 3.5 Flash (High)              (agy bakes the tier into the model)
#     codex  -> gpt-5.5   model_reasoning_effort=high
#     claude -> claude-opus-4-8   --effort high
# With no --effort the config's default_tier is used. A per-run --model overrides
# only the resolved model; the native effort still comes from the tier. Reading
# agents.json needs `jq` (preferred) or `python3` on PATH.
#
# Usage:
#   run-agent.sh --agent <agy|codex|claude|all> (--prompt "..." | --prompt-file F | --prompt-file -)
#                [--target DIR] [--read-only | --write] [--effort TIER] [--model M]
#                [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
#                [--list] [--check] [--dry-run] [-h | --help]
#
# --agent all  fans out to every agent ENABLED in agents.json, in parallel.
# Transcripts land under --out (default ~/.external-agents/logs/<project>/<agent>.md)
# AND are echoed to stdout so the caller (Claude) sees every response inline.
#
# SAFETY: in the default read-write mode the agents can modify whatever is under
# --target. Point --target at the tree you actually want changed, and NEVER at a
# tree containing private IP you would not ship to an external provider (agy and
# codex are external services). Use --read-only when you only want analysis.
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
CONF="$PLUGIN_ROOT/agents.json"
TIMEOUT=1800
YES=0
LIST=0
CHECK=0
DRYRUN=0

usage() {
  cat <<'EOF'
run-agent.sh — dispatch ONE prompt to external coding agent CLIs
(agy / codex / claude) as autonomous sub-agents, then collect each response.

Usage:
  run-agent.sh --agent <agy|codex|claude|all> (--prompt "..." | --prompt-file F | --prompt-file -)
               [--target DIR] [--read-only | --write] [--effort TIER] [--model M]
               [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
               [--list] [--check] [--dry-run] [-h | --help]

  --agent       agy | codex | claude | all  (all = every agent enabled in agents.json)
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
  --dry-run     print each agent's resolved launch argv without running it
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
    --out) OUT="$2"; shift 2;;
    --conf) CONF="$2"; shift 2;;
    --list) LIST=1; shift;;
    --check) CHECK=1; shift;;
    -y|--yes) YES=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    *) echo "run-agent: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# --- JSON config backend  (jq preferred, python3 fallback) ------------------------
# All reads of agents.json funnel through cfg() so the two backends stay co-located
# and obviously parallel. Ops:
#   default_tier            -> the global default tier (may be empty)
#   agents                  -> newline list of ALL agent names (insertion order)
#   enabled                 -> newline list of enabled agent names
#   tiers  <agent>          -> newline list of that agent's tier names
#   all_tiers               -> newline union of every agent's tier names (first-seen order)
#   model  <agent> <tier>   -> model string  (empty if unset / tier absent)
#   effort <agent> <tier>   -> effort string (empty if unset / tier absent)
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
  case "$AGENT" in
    agy|codex|claude) cand=("$AGENT");;
    *)                cand=(agy codex claude);;   # 'all' or unset -> check every known cli
  esac
  seen=""
  for a in "${cand[@]}"; do
    case ",$seen," in *",$a,"*) continue;; esac; seen="$seen,$a"
    if command -v "$a" >/dev/null 2>&1; then
      printf '  ok   %-7s %s\n' "$a" "$(command -v "$a")"
    else
      printf '  MISS %-7s not on PATH\n' "$a"; missing=$((missing + 1))
    fi
  done
  echo "external-agents: $missing missing"
  [ "$missing" -eq 0 ]; exit $?
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
      mm="$(cfg model "$a" "$t")"; ee="$(cfg effort "$a" "$t")"
      if [ -n "$ee" ]; then printf '    %-7s -> %-28s effort=%s\n' "$t" "${mm:-(cli default)}" "$ee"
      else                  printf '    %-7s -> %s\n' "$t" "${mm:-(cli default)}"; fi
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
  case "$AGENT" in agy|codex|claude) RUN=("$AGENT");; *) echo "run-agent: unknown agent '$AGENT' (want agy|codex|claude|all)" >&2; exit 2;; esac
fi

# --- validate the run request -----------------------------------------------------
[ -n "$AGENT" ] || { echo "run-agent: --agent is required (agy|codex|claude|all)" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "run-agent: --target '$TARGET' is not a directory" >&2; exit 2; }

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
      echo "  agents : ${RUN[*]}  (agy/codex ship this whole tree to EXTERNAL providers)"
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

# agy --sandbox is best-effort, NOT a hard write barrier (see header) — warn so a
# read-only run is never mistaken for an enforced guarantee.
if [ "$MODE" = "readonly" ]; then
  for a in "${RUN[@]}"; do [ "$a" = "agy" ] && { echo "run-agent: NOTE — agy read-only relies on --sandbox, which is best-effort and may still permit writes. For a hard guarantee use codex/claude, or target a throwaway copy." >&2; break; }; done
fi
# A write run with no git baseline has no diff/revert recovery path — warn.
if [ "$MODE" = "write" ] && [ "$DRYRUN" = "0" ] && [ -z "$TOP" ]; then
  echo "run-agent: NOTE — --target is not a git repo; no baseline to diff or revert after writes. Consider 'git init' or a backup first." >&2
fi

# --- build one agent's argv  (model/effort resolved from the tier) ----------------
build_argv() {  # agent ; sets global ARGV[]
  local a="$1" m e
  m="${MODEL:-$(cfg model "$a" "$TIER")}"
  e="$(cfg effort "$a" "$TIER")"
  ARGV=()
  case "$a" in
    agy)
      ARGV=(agy -p "$PROMPT" --add-dir "$TARGET"); PROMPT_IDX=2
      [ "$MODE" = "readonly" ] && ARGV+=(--sandbox) || ARGV+=(--dangerously-skip-permissions)
      [ -n "$m" ] && ARGV+=(--model "$m");;
    codex)
      if [ "$MODE" = "readonly" ]; then ARGV=(codex exec -s read-only -C "$TARGET" --skip-git-repo-check)
      else ARGV=(codex exec -s workspace-write -C "$TARGET" --skip-git-repo-check); fi
      [ -n "$m" ] && ARGV+=(-m "$m")
      [ -n "$e" ] && ARGV+=(-c "model_reasoning_effort=\"$e\"")
      ARGV+=("$PROMPT"); PROMPT_IDX=$(( ${#ARGV[@]} - 1 ));;
    claude)
      if [ "$MODE" = "readonly" ]; then ARGV=(claude -p "$PROMPT" --allowedTools Read Grep Glob)
      else ARGV=(claude -p "$PROMPT" --permission-mode "$CLAUDE_PERM"); fi
      PROMPT_IDX=2
      [ -n "$m" ] && ARGV+=(--model "$m")
      [ -n "$e" ] && ARGV+=(--effort "$e");;
    *) echo "run-agent: unknown agent '$a'" >&2; return 1;;
  esac
  return 0
}

run_one() {  # agent  (cwd=TARGET) — stdout->$OUT/<a>.md, stderr->.err, rc/.sec
  local a="$1" t0 t1 rc
  build_argv "$a" || return 1
  t0=$(date +%s 2>/dev/null || echo 0)
  ( cd "$TARGET" && timeout "$TIMEOUT" "${ARGV[@]}" ) >"$OUT/$a.md" 2>"$OUT/$a.err"
  rc=$?
  t1=$(date +%s 2>/dev/null || echo 0)
  echo "$rc" >"$OUT/$a.rc"; echo "$((t1 - t0))" >"$OUT/$a.sec"
}

# --- dry-run: print resolved argv and exit ----------------------------------------
if [ "$DRYRUN" = "1" ]; then
  echo "external-agents dry-run  (mode=$MODE  tier=${TIER:-(none)}  target=$TARGET)"
  for a in "${RUN[@]}"; do
    build_argv "$a" || continue
    line=""
    for i in "${!ARGV[@]}"; do
      tok="${ARGV[$i]}"
      if [ "$i" = "$PROMPT_IDX" ]; then tok="<PROMPT>"
      else case "$tok" in *[[:space:]]*) tok="'$tok'";; esac
      fi
      line="$line $tok"
    done
    printf '  %-7s %s\n' "$a" "${line# }"
  done
  exit 0
fi

# --- run (parallel for 'all') -----------------------------------------------------
echo "external-agents: $AGENT on $PROJECT ($TARGET)  mode=$MODE  tier=${TIER:-(none)}  timeout=${TIMEOUT}s" >&2
PIDS=()
for a in "${RUN[@]}"; do
  printf '  -> %-7s model=%-26s effort=%s\n' "$a" "${MODEL:-$(cfg model "$a" "$TIER")}" "$(cfg effort "$a" "$TIER")" >&2
  run_one "$a" & PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done

# --- collect: echo every transcript to stdout, summarise to stderr ----------------
ok=0; fail=0
for a in "${RUN[@]}"; do
  rc="$(cat "$OUT/$a.rc" 2>/dev/null || echo '?')"
  sec="$(cat "$OUT/$a.sec" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$OUT/$a.md" 2>/dev/null | tr -d ' ')
  echo "===== $a (rc=$rc ${sec}s ${bytes:-0} bytes) ====="
  cat "$OUT/$a.md" 2>/dev/null
  if [ "$rc" != "0" ] || [ "${bytes:-0}" -lt 1 ]; then
    echo "----- $a stderr -----"; cat "$OUT/$a.err" 2>/dev/null
  fi
  echo
  if [ "$rc" = "0" ] && [ "${bytes:-0}" -gt 0 ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done
# After a write run, PRODUCE the verification (not just recommend it): show what
# actually changed in the target's git tree so the caller can inspect before trusting.
if [ "$MODE" = "write" ] && [ -n "$TOP" ]; then
  echo "===== git changes after write (in $TARGET) ====="
  git -C "$TARGET" status --porcelain 2>/dev/null
  git -C "$TARGET" --no-pager diff --stat 2>/dev/null
  echo
fi
echo "external-agents: $ok ok, $fail failed  (transcripts in $OUT)" >&2
[ "$fail" -eq 0 ]

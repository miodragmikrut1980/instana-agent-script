#!/usr/bin/env bash
# repro.sh — validate an instana-repro-manifest, print the plan and (with --apply) install the agents.
#
#   ./repro.sh MANIFEST.json              validate + plan only (same as --dry-run)
#   ./repro.sh --dry-run MANIFEST.json    validate + plan only
#   ./repro.sh --apply MANIFEST.json      install the agents, then run the verify steps
#   ./repro.sh --apply --yes MANIFEST     skip the "type the case id" confirmation
#
# Phase 1 scope: agents on a "local" or "ssh" Linux host. The backend (install.sh) is only
# planned, never executed. Requires: bash, jq (+ ssh/scp for provider ssh).
#
# The agent key is NEVER read from the manifest or passed as an argument:
#   export INSTANA_AGENT_KEY=...   (or leave it empty if the agent config has secrets.AGENT_KEY)
# Over ssh it is sent through stdin, so it does not appear in any process list.
#
# Env overrides: BACKEND_DIR, AGENT_DIR, REPRO_LOG_DIR (default ./repro-logs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-$ROOT/skripta/instana-backend-skripta}"
AGENT_DIR="${AGENT_DIR:-$ROOT}"

ERRORS=0
WARNINGS=0
fail() { printf '  FAIL  %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
warn() { printf '  WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
pass() { printf '  ok    %s\n' "$*"; }
die()  { printf '%s\n' "$*" >&2; exit 2; }

usage() {
  printf 'Usage: %s [--dry-run | --apply [--yes]] MANIFEST.json\n' "$(basename "$0")"
  printf '  default / --dry-run  validate the manifest and print the plan; nothing is executed\n'
  printf '  --apply              install the agents (local or ssh) and run the verify steps\n'
  printf '  --yes                with --apply: skip the confirmation prompt\n'
  printf '  The agent key comes only from the environment: INSTANA_AGENT_KEY\n'
}

MODE="plan"
SAW_DRY=0
SAW_APPLY=0
ASSUME_YES=0
MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) SAW_DRY=1; MODE="plan"; shift ;;
    --apply)   SAW_APPLY=1; MODE="apply"; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) MANIFEST="$1"; shift ;;
  esac
done

[[ -n "$MANIFEST" ]] || { usage >&2; exit 2; }
[[ "$SAW_DRY" -eq 1 && "$SAW_APPLY" -eq 1 ]] && die '--dry-run and --apply cannot be combined.'
[[ "$ASSUME_YES" -eq 1 && "$MODE" != "apply" ]] && die '--yes only makes sense with --apply.'
command -v jq >/dev/null 2>&1 || die 'jq is required.'
[[ -f "$MANIFEST" ]] || die "File not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "Not valid JSON: $MANIFEST"

MDIR="$(cd "$(dirname "$MANIFEST")" && pwd)"
resolve() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$MDIR" "$1" ;; esac; }
fmt_epoch() { date -u -r "$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }

printf '\nManifest: %s   mode: %s\n\n' "$MANIFEST" "$MODE"

# ---- 1. envelope -----------------------------------------------------------
printf '1. Manifest\n'
if jq -e '.schema == "instana-repro-manifest" and .schema_version == 1' "$MANIFEST" >/dev/null; then
  pass 'schema instana-repro-manifest v1'
else
  fail 'schema must be "instana-repro-manifest" with schema_version 1'
fi

if jq -e '[.. | objects | keys[]] | map(select(test("key|pass|secret|token"; "i"))) | length == 0' "$MANIFEST" >/dev/null; then
  pass 'no secret-like keys in the manifest'
else
  fail 'manifest contains a key/password/secret/token field; secrets belong in the referenced config files or env vars'
fi

CASE_ID="$(jq -r '.case.id // empty' "$MANIFEST")"
if [[ "$CASE_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  pass "case id: $CASE_ID"
else
  fail 'case.id is required and may contain only letters, digits, dot, underscore and dash'
fi

TTL="$(jq -r '.case.ttl_hours // empty' "$MANIFEST")"
if [[ "$TTL" =~ ^[0-9]+$ ]] && [[ "$TTL" -ge 1 && "$TTL" -le 168 ]]; then
  pass "ttl_hours: $TTL"
else
  fail 'case.ttl_hours must be an integer from 1 to 168'
fi

HAS_BACKEND=0
jq -e '(.backend // null) != null' "$MANIFEST" >/dev/null && HAS_BACKEND=1
AGENT_COUNT="$(jq -r '(.agents // []) | length' "$MANIFEST")"
if [[ "$HAS_BACKEND" -eq 0 && "$AGENT_COUNT" -eq 0 ]]; then
  fail 'manifest needs a backend, at least one agent, or both'
fi

# ---- 2. backend ------------------------------------------------------------
printf '\n2. Backend\n'
BACKEND_CFG=""
BACKEND_DOMAIN=""
if [[ "$HAS_BACKEND" -eq 1 ]]; then
  BACKEND_CFG="$(resolve "$(jq -r '.backend.config // empty' "$MANIFEST")")"
  if [[ -f "$BACKEND_CFG" ]]; then
    if jq -e '.schema == "instana-installer-input" and .schema_version == 1' "$BACKEND_CFG" >/dev/null 2>&1; then
      pass "config: $BACKEND_CFG"
      BACKEND_DOMAIN="$(jq -r '.parameters.BASE_DOMAIN // empty' "$BACKEND_CFG")"
      cfg_ver="$(jq -r '.parameters.BACKEND_VERSION // empty' "$BACKEND_CFG")"
      man_ver="$(jq -r '.versions.backend // empty' "$MANIFEST")"
      if [[ -n "$man_ver" && -n "$cfg_ver" && "$man_ver" != "$cfg_ver" ]]; then
        warn "versions.backend ($man_ver) differs from BACKEND_VERSION in the config ($cfg_ver); the config wins"
      fi
    else
      fail "$BACKEND_CFG is not an instana-installer-input v1 file"
    fi
  else
    fail "backend config not found: $BACKEND_CFG"
  fi
  [[ -f "$BACKEND_DIR/install.sh" ]] && pass "installer: $BACKEND_DIR/install.sh" || fail "install.sh not found in $BACKEND_DIR"
  warn 'backend is planned only; --apply does not run install.sh in Phase 1'
else
  pass 'no backend (SaaS case)'
fi

# ---- 3. agents -------------------------------------------------------------
printf '\n3. Agents\n'
[[ -f "$AGENT_DIR/agent-install.sh" ]] && pass "installer: $AGENT_DIR/agent-install.sh" || fail "agent-install.sh not found in $AGENT_DIR"

if [[ -n "$(jq -r '.versions.agent // empty' "$MANIFEST")" ]]; then
  warn 'versions.agent is informational in Phase 1; agent-install.sh has no version option yet'
fi

AG_NAME=(); AG_CFG=(); AG_PROV=(); AG_USER=(); AG_HOST=(); AG_PORT=(); AG_IDF=()
AG_BTYPE=(); AG_AHOST=(); AG_HASKEY=()

i=0
while [[ "$i" -lt "$AGENT_COUNT" ]]; do
  row="$(jq -r --argjson i "$i" '.agents[$i] | [(.name // ""), (.target // ""), (.config // ""), (.where.provider // ""), (.where.user // ""), (.where.host // ""), (.where.port // ""), (.where.identity_file // "")] | map(tostring) | join("|")' "$MANIFEST")"
  IFS='|' read -r a_name a_target a_config a_prov a_user a_host a_port a_idf <<EOF
$row
EOF
  printf ' agent[%s] %s\n' "$i" "${a_name:-<unnamed>}"
  if [[ -z "$a_name" ]]; then fail "agents[$i].name is required"; fi

  case "$a_target" in
    host) ;;
    docker|k8s) fail "agents[$i].target '$a_target' is not supported yet (host only)" ;;
    *) fail "agents[$i].target must be host (got '${a_target}')" ;;
  esac

  a_cfg="$(resolve "$a_config")"
  a_btype=""
  a_ahost=""
  a_haskey=0
  if [[ -n "$a_config" && -f "$a_cfg" ]]; then
    if jq -e '.schema == "instana-agent-input" and .schema_version == 1' "$a_cfg" >/dev/null 2>&1; then
      pass "config: $a_cfg"
      a_btype="$(jq -r '.parameters.BACKEND_TYPE // empty' "$a_cfg")"
      a_ahost="$(jq -r '.parameters.HOST // empty' "$a_cfg")"
      [[ -n "$(jq -r '.secrets.AGENT_KEY // empty' "$a_cfg")" ]] && a_haskey=1
    else
      fail "$a_cfg is not an instana-agent-input v1 file"
    fi
  else
    fail "agents[$i].config not found: ${a_config:-<empty>}"
  fi

  case "$a_prov" in
    ssh)
      if [[ -z "$a_host" ]]; then
        fail "agents[$i].where.host is required for ssh"
      elif [[ ! "$a_host" =~ ^[A-Za-z0-9._-]+$ ]]; then
        fail "agents[$i].where.host may contain only letters, digits, dot, underscore and dash (no IPv6 literals)"
      else
        pass "where: ssh ${a_user:-ubuntu}@$a_host${a_port:+ port $a_port}"
      fi
      if [[ -n "$a_user" && ! "$a_user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        fail "agents[$i].where.user contains invalid characters"
      fi
      if [[ -n "$a_port" && ! "$a_port" =~ ^[0-9]+$ ]]; then
        fail "agents[$i].where.port must be a number"
      fi ;;
    local) pass 'where: this machine (sudo)' ;;
    *) fail "agents[$i].where.provider must be ssh or local (got '${a_prov}')" ;;
  esac

  if [[ "$HAS_BACKEND" -eq 1 && "$a_btype" == "saas" ]]; then
    warn "agent '$a_name' is BACKEND_TYPE=saas but the manifest also defines a backend"
  fi
  if [[ "$HAS_BACKEND" -eq 0 && "$a_btype" == "selfhosted" ]]; then
    warn "agent '$a_name' is selfhosted but the manifest has no backend"
  fi
  if [[ "$a_btype" == "selfhosted" && -z "$a_ahost" ]]; then
    if [[ -n "$BACKEND_DOMAIN" ]]; then
      warn "agent '$a_name' HOST is empty; set it to the backend BASE_DOMAIN ($BACKEND_DOMAIN) before a real run"
    else
      warn "agent '$a_name' HOST is empty"
    fi
  fi

  AG_NAME+=("$a_name"); AG_CFG+=("$a_cfg"); AG_PROV+=("$a_prov"); AG_USER+=("${a_user:-ubuntu}")
  AG_HOST+=("$a_host"); AG_PORT+=("$a_port"); AG_IDF+=("$a_idf")
  AG_BTYPE+=("$a_btype"); AG_AHOST+=("$a_ahost"); AG_HASKEY+=("$a_haskey")
  i=$((i + 1))
done

# ---- 4. verify -------------------------------------------------------------
printf '\n4. Verify\n'
VERIFY="$(jq -r '(.verify // []) | .[]' "$MANIFEST")"
for v in $VERIFY; do
  case "$v" in
    agent-status|connectivity|visible-in-ui) pass "$v" ;;
    *) fail "unknown verify step: $v" ;;
  esac
done

# ---- plan ------------------------------------------------------------------
RDIR="instana-repro-${CASE_ID}"
if [[ "$MODE" == "apply" ]]; then printf '\nPlan\n'; else printf '\nPlan (nothing is executed)\n'; fi
step=1
if [[ "$HAS_BACKEND" -eq 1 ]]; then
  printf ' %s. backend    cd %s && ./install.sh --config %s   [not executed in Phase 1]\n' "$step" "$BACKEND_DIR" "$BACKEND_CFG"
  step=$((step + 1))
fi
i=0
while [[ "$i" -lt "$AGENT_COUNT" ]]; do
  if [[ "${AG_PROV[$i]}" == "ssh" ]]; then
    printf ' %s. agent %-8s ssh %s@%s: copy agent-install.sh + %s to ~/%s\n' "$step" "${AG_NAME[$i]}" "${AG_USER[$i]}" "${AG_HOST[$i]}" "$(basename "${AG_CFG[$i]}")" "$RDIR"
    step=$((step + 1))
    printf ' %s. agent %-8s ssh %s@%s: sudo -n -E bash ./agent-install.sh --config %s   (key via stdin)\n' "$step" "${AG_NAME[$i]}" "${AG_USER[$i]}" "${AG_HOST[$i]}" "$(basename "${AG_CFG[$i]}")"
  else
    printf ' %s. agent %-8s in ~/%s: sudo -n -E bash %s/agent-install.sh --config %s   (key from env)\n' "$step" "${AG_NAME[$i]}" "$RDIR" "$AGENT_DIR" "${AG_CFG[$i]}"
  fi
  step=$((step + 1))
  i=$((i + 1))
done
for v in $VERIFY; do
  case "$v" in
    agent-status)   printf ' %s. verify     sudo ./agent-install.sh --status on each agent host (exit 1 if not running)\n' "$step" ;;
    connectivity)   printf ' %s. verify     sudo ./agent-install.sh --connectivity on each agent host (exit 1 on failure or 403)\n' "$step" ;;
    visible-in-ui)  printf ' %s. verify     manual: host appears in the Instana UI\n' "$step" ;;
    *) continue ;;
  esac
  step=$((step + 1))
done
printf ' %s. teardown   within %sh of start\n' "$step" "${TTL:-?}"
[[ "$HAS_BACKEND" -eq 1 ]] && printf '                 backend: ./install.sh --destroy\n'
[[ "$AGENT_COUNT" -gt 0 ]] && printf '                 agents: no uninstall option in agent-install.sh yet; delete the VM\n'

if [[ "$ERRORS" -ne 0 ]]; then
  printf '\nResult: %s error(s), %s warning(s)\n\n' "$ERRORS" "$WARNINGS"
  exit 1
fi

if [[ "$MODE" == "plan" ]]; then
  printf '\nResult: %s error(s), %s warning(s)\n\n' "$ERRORS" "$WARNINGS"
  exit 0
fi

# =============================================================================
#  --apply
# =============================================================================
printf '\nPre-flight for --apply\n'
PF=0
pf_fail() { printf '  FAIL  %s\n' "$*"; PF=$((PF + 1)); }

if [[ "$AGENT_COUNT" -eq 0 ]]; then pf_fail 'no agents in the manifest; Phase 1 --apply only installs agents'; fi

need_ssh=0
i=0
while [[ "$i" -lt "$AGENT_COUNT" ]]; do
  n="${AG_NAME[$i]}"
  [[ "${AG_PROV[$i]}" == "ssh" ]] && need_ssh=1
  if [[ "${AG_BTYPE[$i]}" == "selfhosted" && -z "${AG_AHOST[$i]}" ]]; then
    pf_fail "agent '$n' is selfhosted with an empty HOST; the installer would prompt. Fill in HOST in its config."
  fi
  if [[ "${AG_HASKEY[$i]}" -eq 0 && -z "${INSTANA_AGENT_KEY:-}" ]]; then
    pf_fail "agent '$n' has no secrets.AGENT_KEY; export INSTANA_AGENT_KEY first (the key is never read from the manifest)"
  fi
  cb="$(basename "${AG_CFG[$i]}")"
  if [[ ! "$cb" =~ ^[A-Za-z0-9._-]+$ ]]; then
    pf_fail "agent '$n' config file name '$cb' has characters that are not allowed (letters, digits, . _ -)"
  fi
  if [[ "${AG_PROV[$i]}" == "local" ]] && ! command -v sudo >/dev/null 2>&1; then
    pf_fail "agent '$n': sudo not found"
  fi
  i=$((i + 1))
done
if [[ "$need_ssh" -eq 1 ]]; then
  command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1 || pf_fail 'ssh and scp are required for provider ssh'
fi
if [[ "$PF" -ne 0 ]]; then
  printf '\nNothing was executed. Fix the %s problem(s) above.\n\n' "$PF"
  exit 1
fi
printf '  ok    all agents can be applied\n'

EXPIRES="$(fmt_epoch "$(( $(date +%s) + TTL * 3600 ))")"
printf '\nThis will install %s agent(s) for case %s. Suggested expiry: %s.\n' "$AGENT_COUNT" "$CASE_ID" "$EXPIRES"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  [[ -t 0 ]] || die 'No terminal for the confirmation; pass --yes to run non-interactively.'
  printf 'Type the case id (%s) to continue: ' "$CASE_ID"
  read -r answer
  [[ "$answer" == "$CASE_ID" ]] || { printf 'Aborted.\n'; exit 1; }
fi

umask 077
LOGDIR="${REPRO_LOG_DIR:-$PWD/repro-logs}/${CASE_ID}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
printf 'Logs (mode 600): %s\n\n' "$LOGDIR"

RESULTS=()
FAILED=0
record() {  # agent step PASS|FAIL
  RESULTS+=("$1|$2|$3")
  if [[ "$3" == "FAIL" ]]; then FAILED=$((FAILED + 1)); fi
  printf '  %-4s  %-10s %s\n' "$3" "$1" "$2"
}

# Per-agent context, set by prepare_agent.
CUR_PROV=""; CUR_TARGET=""; CUR_WD=""; CUR_CFG=""; CUR_CFGNAME=""
CUR_RC_INSTALL=""; CUR_RC_STATUS=""; CUR_RC_CONN=""
SSHO=(); SCPO=()

prepare_agent() {
  local i="$1" idf port
  CUR_PROV="${AG_PROV[$i]}"
  CUR_CFG="${AG_CFG[$i]}"
  CUR_CFGNAME="$(basename "$CUR_CFG")"
  CUR_WD="$HOME/$RDIR"
  CUR_TARGET="${AG_USER[$i]}@${AG_HOST[$i]}"
  SSHO=(-o BatchMode=yes -o ConnectTimeout=15)
  SCPO=(-q -o BatchMode=yes -o ConnectTimeout=15)
  port="${AG_PORT[$i]}"
  idf="${AG_IDF[$i]}"
  if [[ -n "$port" ]]; then SSHO+=(-p "$port"); SCPO+=(-P "$port"); fi
  if [[ -n "$idf" ]]; then idf="${idf/#\~/$HOME}"; SSHO+=(-i "$idf"); SCPO+=(-i "$idf"); fi
  CUR_RC_INSTALL="bash -c 'cd ~/$RDIR && IFS= read -r K && printf \"y\\n\" | INSTANA_AGENT_KEY=\"\$K\" sudo -n -E bash ./agent-install.sh --config $CUR_CFGNAME'"
  CUR_RC_STATUS="bash -c 'cd ~/$RDIR && sudo -n bash ./agent-install.sh --status'"
  CUR_RC_CONN="bash -c 'cd ~/$RDIR && sudo -n bash ./agent-install.sh --connectivity'"
}

step_prepare_dir() {  # $1 log
  if [[ "$CUR_PROV" == "local" ]]; then
    mkdir -p "$CUR_WD" >"$1" 2>&1
  else
    ssh -n "${SSHO[@]}" "$CUR_TARGET" "mkdir -p ~/$RDIR" >"$1" 2>&1 \
      && scp "${SCPO[@]}" "$AGENT_DIR/agent-install.sh" "$CUR_CFG" "$CUR_TARGET:$RDIR/" >>"$1" 2>&1
  fi
}

step_install() {  # $1 log
  if [[ "$CUR_PROV" == "local" ]]; then
    ( cd "$CUR_WD" && printf 'y\n' | INSTANA_AGENT_KEY="${INSTANA_AGENT_KEY:-}" \
        sudo -n -E bash "$AGENT_DIR/agent-install.sh" --config "$CUR_CFG" ) >"$1" 2>&1
  else
    printf '%s\n' "${INSTANA_AGENT_KEY:-}" | ssh "${SSHO[@]}" "$CUR_TARGET" "$CUR_RC_INSTALL" >"$1" 2>&1
  fi
}

step_verify() {  # $1 kind (status|conn) $2 log
  local flag="--status" rc="$CUR_RC_STATUS"
  if [[ "$1" == "conn" ]]; then flag="--connectivity"; rc="$CUR_RC_CONN"; fi
  if [[ "$CUR_PROV" == "local" ]]; then
    ( cd "$CUR_WD" && sudo -n bash "$AGENT_DIR/agent-install.sh" "$flag" ) >"$2" 2>&1
  else
    ssh -n "${SSHO[@]}" "$CUR_TARGET" "$rc" >"$2" 2>&1
  fi
}

i=0
while [[ "$i" -lt "$AGENT_COUNT" ]]; do
  n="${AG_NAME[$i]}"
  printf 'Agent %s (%s)\n' "$n" "${AG_PROV[$i]}"
  prepare_agent "$i"

  if step_prepare_dir "$LOGDIR/$n-prepare.log"; then
    record "$n" "prepare" "PASS"
    if step_install "$LOGDIR/$n-install.log"; then
      record "$n" "install" "PASS"
      for v in $VERIFY; do
        case "$v" in
          agent-status)
            if step_verify status "$LOGDIR/$n-status.log"; then record "$n" "status" "PASS"; else record "$n" "status" "FAIL"; fi ;;
          connectivity)
            if step_verify conn "$LOGDIR/$n-connectivity.log"; then record "$n" "connectivity" "PASS"; else record "$n" "connectivity" "FAIL"; fi ;;
        esac
      done
    else
      record "$n" "install" "FAIL"
    fi
  else
    record "$n" "prepare" "FAIL"
  fi
  printf '\n'
  i=$((i + 1))
done

case " $VERIFY " in *" visible-in-ui "*) printf 'Manual check: each agent host should appear in the Instana UI within about a minute.\n' ;; esac
printf 'Step logs: %s\n' "$LOGDIR"
printf 'Teardown: delete the VM(s) by %s (agent-install.sh has no uninstall option).\n' "$EXPIRES"
[[ "$HAS_BACKEND" -eq 1 ]] && printf 'Backend was not installed. Run install.sh --config %s yourself if the case needs it.\n' "$BACKEND_CFG"

printf '\nResult: %s step(s) failed, %s warning(s)\n\n' "$FAILED" "$WARNINGS"
[[ "$FAILED" -eq 0 ]]

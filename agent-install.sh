#!/usr/bin/env bash
# =============================================================================
# Instana Agent Installer — agent-install.sh
# Interaktivni installer za Instana Host Agent na Linux-u.
# Generise configuration.yaml i instalira agenta.
#
# UPOTREBA:
#   ./agent-install.sh                      — interaktivni wizard
#   ./agent-install.sh --dry-run            — plan bez izmena
#   ./agent-install.sh --config FILE        — ucitaj parametre iz JSON fajla
#   ./agent-install.sh --profile NAME       — ucitaj predefinisani profil
#   ./agent-install.sh --status             — prikazi status agenta (exit 1 ako nije instaliran ili ne radi)
#   ./agent-install.sh --connectivity       — test konekcije bez menija (exit 1 ako neki endpoint ne radi ili je 403)
#   ./agent-install.sh --edit               — edituj configuration.yaml
#   ./agent-install.sh --support-bundle     — generisi support bundle ZIP
#   ./agent-install.sh --help
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
#  Konstante                                                                   #
# --------------------------------------------------------------------------- #
readonly SCRIPT_VERSION="1.0.0"
readonly AGENT_CONFIG_DIR="/opt/instana/agent/etc/instana"
readonly AGENT_CONFIG_FILE="${AGENT_CONFIG_DIR}/configuration.yaml"
readonly BACKEND_CFG_FILE="${AGENT_CONFIG_DIR}/com.instana.agent.main.sender.Backend.cfg"
readonly AGENT_CFG_FILE="${AGENT_CONFIG_DIR}/com.instana.agent.main.config.Agent.cfg"
readonly MVN_SETTINGS_FILE="/opt/instana/agent/etc/mvn-settings.xml"
readonly AGENT_LOG_FILE="/opt/instana/agent/data/log/agent.log"
readonly AGENT_SERVICE="instana-agent"
readonly STATE_FILE=".agent-install-state.json"
readonly PROFILES_DIR="$(dirname "$0")/profiles"
readonly LOG_FILE="agent-install-$(date +%Y%m%d-%H%M%S).log"

# SaaS endpointi za host agent, prema tabeli "Endpoints for the host and cloud service agents"
# u Instana dokumentaciji. Format: "Naziv|endpoint-host". Isti spisak je u agent-config-generator.html.
readonly SAAS_REGIONS=(
  "AWS US - Oregon (red)|ingress-red-saas.instana.io"
  "AWS US - Ohio (pumpkin)|ingress-pumpkin-saas.instana.io"
  "GCP US - Oregon (orange)|ingress-orange-saas.instana.io"
  "GCP US - South Carolina (coral)|ingress-coral-saas.instana.io"
  "AWS Europe - Dublin (blue)|ingress-blue-saas.instana.io"
  "AWS Europe - Frankfurt (emerald)|ingress-emerald-saas.instana.io"
  "GCP Europe - Belgium (green)|ingress-green-saas.instana.io"
  "AWS APAC - Tokyo (mizu)|ingress-mizu-saas.instana.io"
  "AWS APAC - Mumbai (teal)|ingress-teal-saas.instana.io"
  "AWS LATAM - Sao Paulo (yellow)|ingress-yellow-saas.instana.io"
)

# --------------------------------------------------------------------------- #
#  Boje i formatiranje                                                         #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'
  BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
else
  RED=''; YEL=''; GRN=''; CYN=''; BLD=''; DIM=''; RST=''
fi

log()  { printf "${DIM}[%s]${RST} %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf "${GRN}✓ %s${RST}\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YEL}⚠ %s${RST}\n" "$*" | tee -a "$LOG_FILE"; }
err()  { printf "${RED}✗ %s${RST}\n" "$*" | tee -a "$LOG_FILE"; }
hdr()  { printf "\n${BLD}${CYN}%s${RST}\n\n" "$*"; }
sep()  { printf "${DIM}"; printf '─%.0s' {1..60}; printf "${RST}\n"; }

# --------------------------------------------------------------------------- #
#  Argumenti                                                                   #
# --------------------------------------------------------------------------- #
DRY_RUN=0
CONFIG_FILE=""
PROFILE_NAME=""
MODE="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --config)        CONFIG_FILE="$2"; shift 2 ;;
    --profile)       PROFILE_NAME="$2"; shift 2 ;;
    --status)        MODE="status"; shift ;;
    --connectivity)  MODE="connectivity"; shift ;;
    --edit)          MODE="edit"; shift ;;
    --support-bundle) MODE="bundle"; shift ;;
    --help|-h)       MODE="help"; shift ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
#  Help                                                                        #
# --------------------------------------------------------------------------- #
show_help() {
  printf "\n${BLD}Instana Agent Installer v%s${RST}\n\n" "${SCRIPT_VERSION}"
  printf "${BLD}USAGE${RST}\n"
  printf "  ./agent-install.sh [OPTIONS]\n\n"
  printf "${BLD}OPTIONS${RST}\n"
  printf "  %-22s %s\n" "(no options)"      "Interactive wizard — asks questions one by one"
  printf "  %-22s %s\n" "--dry-run"          "Show plan without changing anything"
  printf "  %-22s %s\n" "--config FILE"      "Load parameters from a JSON file (generated by"
  printf "  %-22s %s\n" ""                   "agent-config-generator.html or --export-config)"
  printf "  %-22s %s\n" "--profile NAME"     "Load a predefined profile from profiles/ directory"
  printf "  %-22s %s\n" "--status"           "Show current agent status, version, connectivity (exit 1 if not installed or not running)"
  printf "  %-22s %s\n" "--connectivity"     "Test backend and repositories, no menu (exit 1 on any failure or 403)"
  printf "  %-22s %s\n" "--edit"             "Edit configuration.yaml interactively"
  printf "  %-22s %s\n" "--support-bundle"   "Generate a ZIP bundle for support (masked keys)"
  printf "  %-22s %s\n" "--help"             "Show this help"
  printf "\n${BLD}EXAMPLES${RST}\n"
  printf "  # Interactive install\n"
  printf "  ./agent-install.sh\n\n"
  printf "  # Dry run with config file\n"
  printf "  ./agent-install.sh --config my-config.json --dry-run\n\n"
  printf "  # Install using IBM MQ profile\n"
  printf "  ./agent-install.sh --profile ibm-mq\n\n"
  printf "  # Check agent health\n"
  printf "  ./agent-install.sh --status\n\n"
  printf "  # Generate support bundle\n"
  printf "  ./agent-install.sh --support-bundle\n\n"
  printf "${BLD}CONFIG FILE${RST}\n"
  printf "  Generate at: agent-config-generator.html (works offline, in browser)\n"
  printf "  Or export current config: ./agent-install.sh -> Edit existing configuration -> e (Export to JSON)\n\n"
}

# --------------------------------------------------------------------------- #
#  Utility funkcije                                                            #
# --------------------------------------------------------------------------- #
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This operation requires root. Run with: sudo $0 $*"
    exit 1
  fi
}

# Za opcije menija koje pisu u konfiguraciju: proveri pre pitanja (da se kljuc ne kuca uzalud).
# Fajl koji ne postoji prolazi, jer to svaka opcija vec javlja posebnom porukom.
need_writable() {
  [[ ! -f "$1" || -w "$1" ]] && return 0
  err "No write permission for $1 — run with: sudo ./agent-install.sh"
  return 1
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}:${VERSION_ID:-0}"
  else
    echo "unknown:0"
  fi
}

detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then echo "apt"
  elif command -v yum &>/dev/null; then echo "yum"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v zypper &>/dev/null; then echo "zypper"
  else echo "unknown"; fi
}

# portable sed -i: works on both Linux (sed -i) and macOS (sed -i '')
sed_i() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

agent_is_installed() {
  command -v instana-agent &>/dev/null || \
  [[ -d /opt/instana/agent ]] || \
  systemctl list-unit-files --quiet "${AGENT_SERVICE}.service" 2>/dev/null | grep -q "${AGENT_SERVICE}"
}

agent_is_running() {
  systemctl is-active --quiet "${AGENT_SERVICE}" 2>/dev/null
}

# Cita vrednost iz konfiguracionog YAML fajla (jednostavno grep, ne pravi YAML parser)
yaml_get() {
  local key="$1" file="${2:-$AGENT_CONFIG_FILE}"
  [[ -f "$file" ]] || return 1
  grep -m1 "^[[:space:]]*${key}[[:space:]]*:" "$file" | sed "s/.*${key}[[:space:]]*:[[:space:]]*//" | tr -d "'\""
}

# TCP provera porta: nc ako postoji, inace bash /dev/tcp (nc nije na cistom Debianu)
tcp_open() {
  local host="$1" port="$2"
  if command -v nc &>/dev/null; then
    nc -z -w5 "$host" "$port" 2>/dev/null
  else
    timeout 5 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null
  fi
}

# Cita vrednost iz .cfg fajla (format key=value), npr. Backend.cfg / Agent.cfg
cfg_get() {
  local key="${1//./\\.}" file="$2"
  [[ -f "$file" ]] || return 1
  grep -m1 "^[[:space:]]*${key}[[:space:]]*=" "$file" | sed 's/^[^=]*=[[:space:]]*//'
}

# Postavlja key=value u .cfg fajlu: brise postojece (i zakomentarisane) linije za taj kljuc, pa dodaje novu
cfg_set() {
  local key="$1" value="$2" file="$3"
  sed_i "/^[#[:space:]]*${key//./\\.}[[:space:]]*=/d" "$file"
  if [[ -n "$(tail -c1 "$file")" ]]; then printf '\n' >> "$file"; fi
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

# APM/INFRASTRUCTURE/AWS -> vrednost za -m parametar instalera (apm|infra|aws)
agent_mode_flag() {
  case "${1:-APM}" in
    INFRASTRUCTURE) echo "infra" ;;
    AWS)            echo "aws" ;;
    *)              echo "apm" ;;
  esac
}

# Maskira API kljuceve u tekstu za logove i bundle
mask_key() {
  echo "$1" | sed 's/\(.\{4\}\).*/\1••••••••/'
}

ask() {
  # ask VARNAME "Prompt" [default] [validator_fn]
  local varname="$1" prompt="$2" default="${3:-}" validator="${4:-}"
  local val=""
  while true; do
    if [[ -n "$default" ]]; then
      printf "${BLD}%s${RST} ${DIM}[%s]${RST}: " "$prompt" "$default"
    else
      printf "${BLD}%s${RST}: " "$prompt"
    fi
    read -r val
    val="${val:-$default}"
    if [[ -z "$val" && -n "$validator" ]]; then
      err "Value required."; continue
    fi
    if [[ -n "$validator" && -n "$val" ]]; then
      local check; check=$($validator "$val" 2>&1) || true
      if [[ "$check" == "ok" ]]; then
        break
      elif [[ -n "$check" ]]; then
        err "$check"; continue
      fi
    fi
    break
  done
  printf -v "$varname" '%s' "$val"
}

# Skida razmake/tabove/\r iz kljuca i proverava znakove. Rezultat u $CLEAN_KEY; return 1 ako ne lici na kljuc.
clean_key() {
  CLEAN_KEY=$(printf '%s' "$1" | tr -d '[:space:]')
  if [[ ! "$CLEAN_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    err "Key contains characters that are not valid in an agent key (letters, digits, - and _ only). Paste only the key."
    return 1
  fi
  if (( ${#CLEAN_KEY} < 16 || ${#CLEAN_KEY} > 40 )); then
    warn "Key length is ${#CLEAN_KEY} — unusual for an agent key (expected ~22). Check you copied the whole key."
  fi
}

ask_secret() {
  local varname="$1" prompt="$2"
  local val="" char stars=""
  # Non-interactive: accept key from INSTANA_AGENT_KEY env var
  if [[ "$varname" == "AGENT_KEY" && -n "${INSTANA_AGENT_KEY:-}" ]]; then
    clean_key "$INSTANA_AGENT_KEY" || exit 1
    printf -v "$varname" '%s' "$CLEAN_KEY"
    return
  fi
  while true; do
    val=""
    stars=""
    printf "${BLD}%s${RST} ${DIM}(type, then Enter)${RST}: " "$prompt"
    # Read character by character — shows * for each char, works on macOS
    local eof=0
    while IFS= read -r -s -n1 char || { eof=1; false; }; do
      # Enter pressed
      [[ -z "$char" ]] && break
      # Backspace
      if [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
        if [[ -n "$val" ]]; then
          val="${val%?}"
          stars="${stars%?}"
          printf '\b \b'
        fi
      else
        val+="$char"
        stars+="*"
        printf '*'
      fi
    done
    echo
    if [[ -n "$val" ]]; then
      clean_key "$val" && { val="$CLEAN_KEY"; break; }
      [[ $eof -eq 1 ]] && exit 1
      continue
    fi
    if [[ $eof -eq 1 ]]; then
      err "No input (EOF). Set INSTANA_AGENT_KEY env var for non-interactive use."
      exit 1
    fi
    err "Value required."
  done
  printf -v "$varname" '%s' "$val"
}

ask_choice() {
  # ask_choice VARNAME "Prompt" option1 option2 ...
  local varname="$1" prompt="$2"; shift 2
  local options=("$@") val=""
  echo -e "${BLD}${prompt}${RST}"
  for i in "${!options[@]}"; do
    printf "  ${CYN}%d)${RST} %s\n" "$((i+1))" "${options[$i]}"
  done
  while true; do
    printf "Choose [1-%d]: " "${#options[@]}"
    read -r val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= ${#options[@]} )); then
      printf -v "$varname" '%s' "${options[$((val-1))]}"
      break
    fi
    err "Enter a number between 1 and ${#options[@]}."
  done
}

ask_yesno() {
  local prompt="$1" default="${2:-y}"
  local val
  local hint; [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  printf "${BLD}%s${RST} ${DIM}[%s]${RST}: " "$prompt" "$hint"
  read -r val; val="${val:-$default}"
  [[ "$val" =~ ^[yY] ]]
}

# --------------------------------------------------------------------------- #
#  Pre-installation checks                                                     #
# --------------------------------------------------------------------------- #
run_prechecks() {
  local backend_host="$1" backend_port="${2:-443}"
  hdr "Pre-installation checks"
  local fail=0

  # Java
  if command -v java &>/dev/null; then
    local jver; jver=$(java -version 2>&1 | head -1)
    ok "Java found: ${jver}"
  else
    warn "Java not found. The agent ships with its own JVM — this is OK if you use the packaged agent."
  fi

  # curl / wget
  if command -v curl &>/dev/null; then
    ok "curl available"
  elif command -v wget &>/dev/null; then
    ok "wget available (curl preferred)"
  else
    err "Neither curl nor wget found — cannot download agent"; (( fail++ ))
  fi

  # systemd
  if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
    ok "systemd available"
  else
    warn "systemd not found — you will need to start the agent manually"
  fi

  # /opt/instana writable or root
  if [[ $EUID -eq 0 ]]; then
    ok "Running as root"
  else
    warn "Not running as root — install step will require sudo"
  fi

  # Disk space: need at least 2 GB in /opt
  local free_kb; free_kb=$(df /opt 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if (( free_kb >= 2097152 )); then
    ok "Disk space: $((free_kb/1024)) MB free in /opt"
  else
    warn "Low disk space: $((free_kb/1024)) MB free in /opt (recommended: 2+ GB)"
  fi

  # Backend connectivity
  if [[ -n "$backend_host" ]]; then
    printf "Checking connectivity to %s:%s ... " "$backend_host" "$backend_port"
    if curl -s --connect-timeout 5 --max-time 10 \
        -o /dev/null -w "%{http_code}" \
        "https://${backend_host}:${backend_port}" &>/dev/null; then
      ok "Backend reachable"
    elif tcp_open "$backend_host" "$backend_port"; then
      ok "Backend port open (TCP)"
    else
      warn "Cannot reach ${backend_host}:${backend_port} — check firewall/proxy settings"
    fi
  fi

  # Existing agent?
  if agent_is_installed; then
    warn "Instana agent already installed — this will update/reconfigure it"
  fi

  if (( fail > 0 )); then
    err "${fail} pre-check(s) failed. Fix them before proceeding."
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
#  Auto-detect running services                                                #
# --------------------------------------------------------------------------- #
detect_services() {
  hdr "Detecting running services"
  local found=()

  _check_port() {
    local port="$1" name="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
      ok "${name} detected on port ${port}"
      found+=("$name:$port")
    fi
  }

  _check_proc() {
    local pattern="$1" name="$2"
    if pgrep -f "$pattern" &>/dev/null; then
      ok "${name} process found"
      found+=("$name")
    fi
  }

  _check_port 3306  "MySQL"
  _check_port 5432  "PostgreSQL"
  _check_port 27017 "MongoDB"
  _check_port 6379  "Redis"
  _check_port 9200  "Elasticsearch"
  _check_port 1414  "IBM MQ"
  _check_port 9092  "Kafka"
  _check_port 15672 "RabbitMQ (management)"
  _check_port 80    "HTTP server"
  _check_port 443   "HTTPS server"
  _check_proc "nginx"   "NGINX"
  _check_proc "httpd"   "Apache HTTPd"
  _check_proc "tomcat"  "Apache Tomcat"

  if [[ ${#found[@]} -eq 0 ]]; then
    log "No well-known services detected on standard ports."
  else
    echo ""
    echo -e "${YEL}Found ${#found[@]} service(s). Consider enabling their sensors in configuration.yaml.${RST}"
    echo -e "Use ${BLD}agent-config-generator.html${RST} in your browser to generate the config."
  fi
  echo ""
}

# --------------------------------------------------------------------------- #
#  Generisanje configuration.yaml                                              #
# --------------------------------------------------------------------------- #
# configuration.yaml sadrzi samo dokumentovane sekcije: zona i host tagovi.
# Key/host/port idu preko installera (-a, -e), proxy u Backend.cfg (apply_backend_proxy),
# a mode preko installera (-m) / Agent.cfg.
generate_yaml() {
  local zone="${1:-}" tag_env="${2:-}" tag_team="${3:-}"
  local yaml_file="${4:-configuration.yaml}"
  local sq="'"

  log "Generating ${yaml_file}..."

  {
    echo "# Instana Agent configuration"
    echo "# Generated by agent-install.sh on $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Documentation: IBM Instana docs, \"Configuring host agents by using the agent configuration file\""
    echo ""

    if [[ -n "$zone" ]]; then
      echo "com.instana.plugin.generic.hardware:"
      echo "  enabled: true"
      echo "  availability-zone: '${zone//$sq/$sq$sq}'"
      echo ""
    fi

    if [[ -n "$tag_env" || -n "$tag_team" ]]; then
      echo "com.instana.plugin.host:"
      echo "  tags:"
      [[ -n "$tag_env"  ]] && echo "    - 'environment=${tag_env//$sq/$sq$sq}'"
      [[ -n "$tag_team" ]] && echo "    - 'team=${tag_team//$sq/$sq$sq}'"
      echo ""
    fi

  } > "$yaml_file"
  chmod 0600 "$yaml_file"
  append_sensors_yaml "$yaml_file"

  ok "Generated: ${yaml_file}"
}

# Dodaje senzore iz SENSORS_JSON (blok "sensors" iz profila/--config) u configuration.yaml.
# Podrzano: ibmmq, mysql, mariadb, postgresql, mongodb, mssql (samo local lista), redis (isti izlaz kao agent-config-generator.html).
append_sensors_yaml() {
  local yaml_file="$1"
  [[ -n "${SENSORS_JSON:-}" && "${SENSORS_JSON}" != "{}" ]] || return 0

  local unsupported
  unsupported=$(printf '%s' "$SENSORS_JSON" | jq -r 'keys - ["ibmmq","mysql","mariadb","postgresql","mongodb","mssql","redis"] | join(", ")')
  [[ -z "$unsupported" ]] || warn "Sensors not supported by installer (use agent-config-generator.html): ${unsupported}"

  printf '%s' "$SENSORS_JSON" | jq -r '
    def q: "\u0027" + (tostring | gsub("\u0027"; "\u0027\u0027")) + "\u0027";
    ( .ibmmq // empty
      | "com.instana.plugin.ibmmq:", "  queueManagers:",
        ( .queueManagers[]?
          | "    \(.name | q):",
            (if .host then "      host: \(.host | q)" else empty end),
            (if .channel then "      channel: \(.channel | q)" else empty end),
            (if .port then "      port: \(.port | q)" else empty end),
            (if .username then "      username: \(.username | q)" else empty end),
            (if .password then "      password: \(.password | q)" else empty end) ),
        "" ),
    ( .mysql // empty
      | "com.instana.plugin.mysql:",
        "  user: \((.user // "instana") | q)",
        "  password: \((.password // "") | q)", "" ),
    ( .mariadb // empty
      | "com.instana.plugin.mariadb:",
        "  user: \((.user // "instana") | q)",
        "  password: \((.password // "") | q)", "" ),
    ( .postgresql // empty
      | "com.instana.plugin.postgresql:",
        "  user: \((.user // "instana") | q)",
        "  password: \((.password // "") | q)",
        (if .database then "  database: \(.database | q)" else empty end), "" ),
    ( .mongodb // empty
      | "com.instana.plugin.mongodb:",
        (if .user then "  user: \(.user | q)" else empty end),
        (if .password then "  password: \(.password | q)" else empty end),
        (if .source then "  source: \(.source | q)" else empty end), "" ),
    ( .mssql // empty
      | "com.instana.plugin.mssql:", "  local:",
        ( .local[]?
          | . as $o
          | ([ ("instance","user","password","port") as $k | select($o | has($k)) | "\($k): \($o[$k] | q)" ]) as $f
          | range(0; $f | length) as $i
          | (if $i == 0 then "    - " else "      " end) + $f[$i] ),
        "" ),
    ( .redis // empty
      | "com.instana.plugin.redis:",
        "  password: \((.password // "") | q)", "" )
  ' >> "$yaml_file"
}

# Postavlja availability-zone u configuration.yaml (sekcija com.instana.plugin.generic.hardware)
set_zone_in_yaml() {
  local zone="$1" file="$2" sq="'"
  local zq="${zone//$sq/$sq$sq}"
  if grep -q "^[[:space:]]*availability-zone:" "$file"; then
    sed_i "s|^\([[:space:]]*\)availability-zone:.*|\1availability-zone: '${zq}'|" "$file"
  elif grep -q "^com.instana.plugin.generic.hardware:" "$file"; then
    sed_i "/^com.instana.plugin.generic.hardware:/a\\
  availability-zone: '${zq}'" "$file"
  else
    printf "\ncom.instana.plugin.generic.hardware:\n  enabled: true\n  availability-zone: '%s'\n" "$zq" >> "$file"
  fi
}

# Proxy za komunikaciju agent -> backend ide u Backend.cfg (proxy.type/host/port/user/password/dns)
apply_backend_proxy() {
  local host="${1:-}" port="${2:-}" user="${3:-}" pass="${4:-}"
  [[ -n "$host" ]] || return 0

  local ptype="${PROXY_TYPE:-http}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[dry-run]${RST} Would write to ${BACKEND_CFG_FILE}:"
    echo -e "${DIM}[dry-run]${RST}   proxy.type=${ptype}  proxy.host=${host}  proxy.port=${port:-<unset>}  proxy.dns=true"
    if [[ -n "$user" ]]; then
      echo -e "${DIM}[dry-run]${RST}   proxy.user=${user}  proxy.password=<hidden>"
    fi
    apply_maven_proxy "$ptype" "$host" "$port" "$user" "$pass"
    return 0
  fi

  if [[ ! -f "$BACKEND_CFG_FILE" ]]; then
    warn "${BACKEND_CFG_FILE} not found — proxy not applied"
    return 0
  fi

  cp "$BACKEND_CFG_FILE" "${BACKEND_CFG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cfg_set proxy.type "$ptype" "$BACKEND_CFG_FILE"
  cfg_set proxy.host "$host" "$BACKEND_CFG_FILE"
  if [[ -n "$port" ]]; then cfg_set proxy.port "$port" "$BACKEND_CFG_FILE"; fi
  if [[ -n "$user" ]]; then cfg_set proxy.user "$user" "$BACKEND_CFG_FILE"; fi
  if [[ -n "$pass" ]]; then cfg_set proxy.password "$pass" "$BACKEND_CFG_FILE"; fi
  cfg_set proxy.dns true "$BACKEND_CFG_FILE"
  ok "Proxy written to ${BACKEND_CFG_FILE}"
  apply_maven_proxy "$ptype" "$host" "$port" "$user" "$pass"
}

# Proxy za preuzimanje sensora/update-a (Maven) ide u mvn-settings.xml, <proxies> sekcija.
# Dokumentacija: "the <proxies> section must be present and not commented out".
# Menja se samo blok <proxies>...</proxies> (zajedno sa okolnim <!-- --> ako je zakomentarisan).
apply_maven_proxy() {
  local ptype="$1" host="$2" port="$3" user="$4" pass="$5"
  local f="$MVN_SETTINGS_FILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[dry-run]${RST} Would activate <proxies> in ${f}: protocol=${ptype} host=${host} port=${port:-<unset>}"
    return 0
  fi
  if [[ ! -f "$f" ]]; then
    warn "${f} not found — Maven proxy not set (dynamic agent updates may not work behind the proxy)"
    return 0
  fi
  if ! grep -q '^[[:space:]]*<proxies>[[:space:]]*$' "$f"; then
    warn "No <proxies> block found in ${f} — set it manually (see Instana docs: Setting up an agent proxy)"
    return 0
  fi

  cp "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  local tmp; tmp=$(mktemp)
  MVN_P_TYPE="$ptype" MVN_P_HOST="$host" MVN_P_PORT="$port" MVN_P_USER="$user" MVN_P_PASS="$pass" \
  awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function flush_held() { if (held != "") { print held; held = "" } }
    /^[[:space:]]*<!--[[:space:]]*$/ && !inblock { flush_held(); held = $0; next }
    /^[[:space:]]*<proxies>[[:space:]]*$/ && !inblock {
      held = ""; inblock = 1
      print "  <proxies>"
      print "    <proxy>"
      print "      <id>agent-proxy</id>"
      print "      <active>true</active>"
      print "      <protocol>" esc(ENVIRON["MVN_P_TYPE"]) "</protocol>"
      if (ENVIRON["MVN_P_USER"] != "") print "      <username>" esc(ENVIRON["MVN_P_USER"]) "</username>"
      if (ENVIRON["MVN_P_PASS"] != "") print "      <password>" esc(ENVIRON["MVN_P_PASS"]) "</password>"
      print "      <host>" esc(ENVIRON["MVN_P_HOST"]) "</host>"
      if (ENVIRON["MVN_P_PORT"] != "") print "      <port>" esc(ENVIRON["MVN_P_PORT"]) "</port>"
      print "    </proxy>"
      print "  </proxies>"
      next
    }
    inblock && /^[[:space:]]*<\/proxies>[[:space:]]*$/ { inblock = 0; skipclose = 1; next }
    inblock { next }
    skipclose { skipclose = 0; if ($0 ~ /^[[:space:]]*-->[[:space:]]*$/) next }
    { flush_held(); print }
    END { flush_held() }
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  ok "Maven proxy activated in ${f}"
  [[ "$ptype" == socks* ]] && warn "mvn-settings.xml protocol set to '${ptype}' — verify that sensor updates work (Instana docs show only 'http' here)"
  return 0
}

# Test dostupnosti: backend + repozitorijumi, kroz proxy iz Backend.cfg ako je podesen (isto sto koristi agent).
# Svaki HTTP odgovor (i 401/403/404) znaci da je veza i TLS prosla; kod greske se tumaci po curl exit kodu.
# Rezultat za neinteraktivne tokove (--connectivity): broj neuspelih provera; funkcija i dalje uvek vraca 0 (set -e u meniju).
CONN_FAILS=0
test_connectivity() {
  CONN_FAILS=0
  command -v curl &>/dev/null || { warn "curl not found — cannot test connectivity"; CONN_FAILS=1; return 0; }
  local bhost bport ptype phost pport puser ppass
  bhost=$(cfg_get host "$BACKEND_CFG_FILE" 2>/dev/null || true)
  bport=$(cfg_get port "$BACKEND_CFG_FILE" 2>/dev/null || true); bport="${bport:-443}"
  ptype=$(cfg_get proxy.type "$BACKEND_CFG_FILE" 2>/dev/null || true)
  phost=$(cfg_get proxy.host "$BACKEND_CFG_FILE" 2>/dev/null || true)
  pport=$(cfg_get proxy.port "$BACKEND_CFG_FILE" 2>/dev/null || true)
  puser=$(cfg_get proxy.user "$BACKEND_CFG_FILE" 2>/dev/null || true)
  ppass=$(cfg_get proxy.password "$BACKEND_CFG_FILE" 2>/dev/null || true)
  if [[ -z "$bhost" ]]; then
    warn "No backend host configured in ${BACKEND_CFG_FILE} — run option 3 first"
    CONN_FAILS=1
    return 0
  fi

  local -a pargs=()
  local cfgin=""
  if [[ -n "$phost" ]]; then
    local scheme="http"
    # proxy.dns=true: ime se razresava na proxy-ju (socks4a / socks5h)
    case "${ptype:-http}" in socks4) scheme="socks4a" ;; socks5) scheme="socks5h" ;; esac
    pargs=(--proxy "${scheme}://${phost}${pport:+:$pport}")
    if [[ -n "$puser" ]]; then
      local _u="${puser//\\/\\\\}" _p="${ppass//\\/\\\\}"
      cfgin=$(printf 'proxy-user = "%s:%s"' "${_u//\"/\\\"}" "${_p//\"/\\\"}")
    fi
    log "Testing through proxy: ${ptype:-http}://${phost}${pport:+:$pport}${puser:+ (user ${puser})}"
  else
    log "No proxy configured — testing direct connection"
  fi

  local -a targets=("${bhost}:${bport}|Backend (agent data)"
    "artifact-public.instana.io:443|Sensor and agent updates"
    "packages.instana.io:443|Agent packages"
    "setup.instana.io:443|Installer script")
  [[ "$bhost" == *-saas.instana.io ]] && targets+=("containers.instana.io:443|Agent images")

  local errfile; errfile=$(mktemp)
  local t hp label out rc errtxt code ver reason fails=0 first=1
  for t in "${targets[@]}"; do
    hp="${t%%|*}"; label="${t##*|}"
    rc=0
    out=$(printf '%s\n' "$cfgin" | curl -K - -sS -o /dev/null --http2 --connect-timeout 10 --max-time 25 \
      ${pargs[@]+"${pargs[@]}"} -w '%{http_code} h%{http_version}' "https://${hp}/" 2>"$errfile") || rc=$?
    errtxt=$(tr '\n' ' ' < "$errfile")
    if [[ $rc -eq 0 ]]; then
      code="${out%% *}"; ver="${out##* h}"
      ok "${hp} — ${label} (HTTP ${code}, h${ver})"
      if [[ $first -eq 1 && "$ver" != "2" ]]; then
        warn "Backend answered with HTTP/${ver}, the agent uses HTTP/2 — a proxy that terminates TLS must support ALPN h2"
      fi
    else
      fails=$((fails + 1))
      if [[ "$errtxt" =~ CONNECT\ tunnel\ failed,\ response\ ([0-9]+) ]]; then
        case "${BASH_REMATCH[1]}" in
          407) reason="proxy requires authentication (check proxy.user / proxy.password)" ;;
          403) reason="proxy policy blocks this host — ask for it to be allowed" ;;
          *)   reason="proxy refused CONNECT (HTTP ${BASH_REMATCH[1]})" ;;
        esac
      else
        case "$rc" in
          5)  reason="cannot resolve proxy host name" ;;
          6)  reason="cannot resolve host name (DNS)" ;;
          7)  if [[ -n "$phost" ]]; then reason="cannot connect to proxy ${phost}${pport:+:$pport}"
              else reason="connection refused or blocked (firewall)"; fi ;;
          28) reason="timeout — traffic is probably dropped by a firewall or the proxy is unreachable" ;;
          35|51|58|60|77|83) reason="TLS error — a proxy with TLS inspection may be using a certificate this host does not trust" ;;
          *)  reason="curl exit ${rc}: ${errtxt}" ;;
        esac
      fi
      err "${hp} — ${label}: ${reason}"
    fi
    first=0
  done
  rm -f "$errfile"
  CONN_FAILS=$fails

  if [[ $fails -eq 0 ]]; then
    ok "All endpoints reachable"
  else
    warn "${fails} endpoint(s) failed"
  fi
}

# --------------------------------------------------------------------------- #
#  Instalacija agenta                                                          #
# --------------------------------------------------------------------------- #
# Na apt sistemima installer pravi /usr/share/keyrings/instana-agent.gpg pomocu `gpg --dearmor`.
# Cist Debian nema gpg: installer tada preskace verifikaciju paketa i apt javlja "not signed".
ensure_gpg() {
  [[ "$1" == "apt" ]] || return 0
  command -v gpg &>/dev/null && return 0
  log "gpg not found — installing it so package signatures can be verified..."
  if apt-get install -y -qq gpg >/dev/null 2>&1; then
    ok "gpg installed"
  else
    warn "Could not install gpg — Instana package signatures will NOT be verified (apt-get install gpg)"
  fi
}

install_agent() {
  local agent_key="$1" backend_host="$2" backend_port="$3" update_mode="$4" agent_mode="${5:-APM}"

  local pkg_mgr; pkg_mgr=$(detect_pkg_manager)
  local mode_flag; mode_flag=$(agent_mode_flag "$agent_mode")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[dry-run]${RST} Would download installer from https://setup.instana.io/agent"
    echo -e "${DIM}[dry-run]${RST} Would run: setup_instana_agent.sh -a <key> -t ${update_mode} -m ${mode_flag} -e ${backend_host}:${backend_port}"
    echo -e "${DIM}[dry-run]${RST} Would copy configuration.yaml to ${AGENT_CONFIG_FILE}"
    echo -e "${DIM}[dry-run]${RST} Would enable and start ${AGENT_SERVICE} service"
    return 0
  fi

  hdr "Installing Instana Agent"

  ensure_gpg "$pkg_mgr"

  log "Downloading installer script..."
  curl -fsSL -o /tmp/setup_instana_agent.sh https://setup.instana.io/agent
  chmod +x /tmp/setup_instana_agent.sh

  log "Running installer (this may take 1-2 minutes)..."
  /tmp/setup_instana_agent.sh \
    -a "${agent_key}" \
    -t "${update_mode}" \
    -m "${mode_flag}" \
    -e "${backend_host}:${backend_port}" \
    2>&1 | tee -a "$LOG_FILE"

  ok "Agent package installed"
}

apply_config() {
  local yaml_file="${1:-configuration.yaml}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[dry-run]${RST} Would copy ${yaml_file} → ${AGENT_CONFIG_FILE}"
    return 0
  fi

  if [[ ! -f "$yaml_file" ]]; then
    warn "No ${yaml_file} found — agent will use default configuration"
    return 0
  fi

  # Nema aktivnih sekcija (samo komentari) — ne diraj default configuration.yaml
  if ! grep -qv '^[[:space:]]*\(#.*\)\?$' "$yaml_file"; then
    log "No zone/tags to apply — keeping default ${AGENT_CONFIG_FILE}"
    return 0
  fi

  # Backup existing config
  if [[ -f "$AGENT_CONFIG_FILE" ]]; then
    local backup="${AGENT_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$AGENT_CONFIG_FILE" "$backup"
    log "Backed up existing config to: ${backup}"
  fi

  install -D -m 0640 "$yaml_file" "$AGENT_CONFIG_FILE"
  ok "Applied configuration: ${AGENT_CONFIG_FILE}"
}

# Posle restarta ceka backend handshake u agent.log (do 90s) i upozorava na 403 Forbidden.
# Servis moze biti RUNNING i port dostupan, a backend ipak odbija kljuc.
# $1 = broj linija loga pre restarta (gleda se samo novi deo)
check_backend_auth() {
  local start="${1:-0}" i fresh
  log "Waiting for backend handshake (up to 90s)..."
  for ((i = 0; i < 45; i++)); do
    fresh=""
    if [[ -f "$AGENT_LOG_FILE" ]]; then
      fresh=$(tail -n +"$((start + 1))" "$AGENT_LOG_FILE" 2>/dev/null || true)
    fi
    # Bez `printf | grep -q`: grep -q izlazi na prvom poklapanju, printf dobije SIGPIPE i pipefail
    # vrati gresku kad je novi deo loga veliki (to je krilo 403 i prikazivalo "accepted").
    if [[ "$fresh" == *'Connected using HTTP/2'* ]]; then
      sleep 3   # 403 stize ~300 ms posle konekcije
      fresh=$(tail -n +"$((start + 1))" "$AGENT_LOG_FILE" 2>/dev/null || true)
      if [[ "$fresh" == *'Forbidden (403)'* ]]; then
        warn "Backend rejected the agent key (403 Forbidden) — the host will NOT appear in the UI."
        printf "  Fix the key: run ${BLD}sudo ./agent-install.sh${RST} → Edit existing configuration → option 4\n"
      else
        ok "Backend accepted the connection"
      fi
      return 0
    fi
    sleep 2
  done
  warn "No backend handshake seen in 90s — check: sudo tail -f ${AGENT_LOG_FILE}"
}

restart_agent() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${DIM}[dry-run]${RST} Would restart ${AGENT_SERVICE} service"
    return 0
  fi

  local log_lines=0
  if [[ -f "$AGENT_LOG_FILE" ]]; then log_lines=$(wc -l < "$AGENT_LOG_FILE"); fi

  log "Restarting ${AGENT_SERVICE}..."
  systemctl enable --quiet "${AGENT_SERVICE}" 2>/dev/null || true
  systemctl restart "${AGENT_SERVICE}"
  sleep 3

  if agent_is_running; then
    ok "Agent is running"
    check_backend_auth "$log_lines"
  else
    err "Agent failed to start. Check: sudo journalctl -u ${AGENT_SERVICE} -n 50"
    return 1
  fi
}

# --------------------------------------------------------------------------- #
#  Status prikaz                                                               #
# --------------------------------------------------------------------------- #
# STATUS_OK=0 kad agent nije instaliran ili ne radi; show_status i dalje vraca 0 (poziva se i posle instalacije pod set -e).
STATUS_OK=1
show_status() {
  hdr "Instana Agent Status"

  if ! agent_is_installed; then
    warn "Instana Agent is not installed."
    echo -e "Install with: ${BLD}./agent-install.sh${RST}"
    STATUS_OK=0
    return 0
  fi

  # Service status
  if agent_is_running; then
    local uptime; uptime=$(systemctl show "${AGENT_SERVICE}" --property=ActiveEnterTimestamp \
      | cut -d= -f2 | sed 's/  */ /g' || echo "unknown")
    ok "Service: RUNNING (since ${uptime})"
  else
    err "Service: STOPPED"
    STATUS_OK=0
    echo -e "Start with: ${BLD}sudo systemctl start ${AGENT_SERVICE}${RST}"
  fi

  # Version
  if [[ -f /opt/instana/agent/bin/instana-agent ]]; then
    local ver; ver=$(/opt/instana/agent/bin/instana-agent --version 2>/dev/null | head -1 || echo "unknown")
    log "Version: ${ver}"
  fi

  # Config
  if [[ -f "$AGENT_CONFIG_FILE" ]]; then
    ok "Config: ${AGENT_CONFIG_FILE}"
    local zone
    zone=$(yaml_get "availability-zone" "$AGENT_CONFIG_FILE" 2>/dev/null || true)
    log "  Zone: ${zone:-not set}"
  else
    warn "No configuration.yaml found at ${AGENT_CONFIG_FILE}"
  fi
  if [[ -f "$BACKEND_CFG_FILE" ]]; then
    log "  Backend host: $(cfg_get host "$BACKEND_CFG_FILE" || true)"
    log "  Backend port: $(cfg_get port "$BACKEND_CFG_FILE" || true)"
    log "  Agent mode:   $(cfg_get mode "$AGENT_CFG_FILE" 2>/dev/null || echo APM)"
  fi

  # Backend connectivity
  local host; host=$(cfg_get host "$BACKEND_CFG_FILE" 2>/dev/null || true)
  local port; port=$(cfg_get port "$BACKEND_CFG_FILE" 2>/dev/null || true)
  port="${port:-443}"
  if [[ -n "$host" ]]; then
    printf "Checking backend connectivity (%s:%s) ... " "$host" "$port"
    if tcp_open "$host" "$port"; then
      ok "Reachable"
    else
      warn "Cannot reach ${host}:${port}"
    fi
  fi

  # Recent log
  echo ""
  log "Last 10 lines from ${AGENT_LOG_FILE}:"
  sep
  if [[ -f "$AGENT_LOG_FILE" ]]; then
    tail -10 "$AGENT_LOG_FILE" | while IFS= read -r _l; do printf '%b  %s%b\n' "$DIM" "$_l" "$RST"; done
  else
    echo -e "  ${DIM}(log not found)${RST}"
  fi
  sep
  echo -e "Full log: ${BLD}sudo tail -f ${AGENT_LOG_FILE}${RST}"
}

# --------------------------------------------------------------------------- #
#  Edit mode                                                                   #
# --------------------------------------------------------------------------- #
show_edit_menu() {
  hdr "Instana Agent Manager"

  local _installed=1
  agent_is_installed || _installed=0

  while true; do
    echo ""
    sep
    if [[ "$_installed" -eq 0 ]]; then
      echo -e "  Agent status: ${YEL}NOT INSTALLED${RST}"
    elif agent_is_running; then
      echo -e "  Agent status: ${GRN}RUNNING${RST}"
    else
      echo -e "  Agent status: ${RED}STOPPED${RST}"
    fi
    sep
    echo ""
    echo -e "  ${CYN}1)${RST} Show current configuration (configuration.yaml + Backend.cfg)"
    echo -e "  ${CYN}2)${RST} Edit configuration.yaml in \$EDITOR"
    echo -e "  ${CYN}3)${RST} Change backend host/port"
    echo -e "  ${CYN}4)${RST} Change agent key"
    echo -e "  ${CYN}5)${RST} Change zone name"
    echo -e "  ${CYN}6)${RST} Restart agent"
    echo -e "  ${CYN}7)${RST} View recent logs (last 50 lines)"
    echo -e "  ${CYN}8)${RST} Check backend connectivity"
    echo -e "  ${CYN}9)${RST} Restore last backup"
    echo -e "  ${CYN}e)${RST} Export config to JSON (for agent-config-generator.html)"
    echo -e "  ${CYN}0)${RST} Exit"
    echo ""
    printf "Choice: "
    read -r choice

    # Resolve active config file: system path if installed, else local dry-run output
    local _cf="${AGENT_CONFIG_FILE}"
    [[ ! -f "$_cf" ]] && _cf="./configuration.yaml"

    case "$choice" in
      1)
        echo ""
        sep
        printf "  ${BLD}Summary${RST}\n"
        printf "  Zone:     %s\n" "$(yaml_get "availability-zone" "$_cf" 2>/dev/null || true)"
        printf "  Backend:  %s:%s\n" "$(cfg_get host "$BACKEND_CFG_FILE" 2>/dev/null || true)" "$(cfg_get port "$BACKEND_CFG_FILE" 2>/dev/null || true)"
        printf "  Mode:     %s\n" "$(cfg_get mode "$AGENT_CFG_FILE" 2>/dev/null || echo APM)"
        printf "  Key:      %s\n" "$(mask_key "$(cfg_get key "$BACKEND_CFG_FILE" 2>/dev/null || true)")"
        _dropin="/etc/systemd/system/${AGENT_SERVICE}.service.d/10-environment.conf"
        if [[ -f "$_dropin" ]]; then
          printf "  Resources (%s):\n" "$_dropin"
          grep '^Environment=' "$_dropin" | sed 's/^/    /' || true
        fi
        sep
        if [[ -f "$_cf" ]]; then
          sep
          printf "  %s\n" "$_cf"
          sep
          cat "$_cf"
          sep
        else
          warn "No config file found. Run a dry-run first: ${BLD}./agent-install.sh --dry-run${RST}"
        fi
        if [[ -f "$BACKEND_CFG_FILE" ]]; then
          printf "  %s (key/password masked)\n" "$BACKEND_CFG_FILE"
          sep
          sed 's/^\([[:space:]]*\(key\|proxy\.password\)[[:space:]]*=\).*/\1<MASKED>/' "$BACKEND_CFG_FILE"
          sep
        fi
        ;;
      2)
        need_writable "$_cf" || continue
        local editor="${EDITOR:-nano}"
        if [[ -f "$_cf" ]]; then
          cp "$_cf" "${_cf}.bak.$(date +%Y%m%d-%H%M%S)"
          "$editor" "$_cf"
          if [[ "$_installed" -eq 1 ]] && ask_yesno "Restart agent to apply changes?" "y"; then
            restart_agent
          fi
        else
          warn "No config file found. Run a dry-run first: ${BLD}./agent-install.sh --dry-run${RST}"
        fi
        ;;
      3)
        need_writable "$BACKEND_CFG_FILE" || continue
        ask backend_host "New backend host" ""
        ask backend_port "New backend port" "443"
        if [[ -f "$BACKEND_CFG_FILE" ]]; then
          cp "$BACKEND_CFG_FILE" "${BACKEND_CFG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
          cfg_set host "$backend_host" "$BACKEND_CFG_FILE"
          cfg_set port "$backend_port" "$BACKEND_CFG_FILE"
          ok "Backend updated to ${backend_host}:${backend_port} in ${BACKEND_CFG_FILE}"
          if [[ "$_installed" -eq 1 ]] && ask_yesno "Restart agent to apply?" "y"; then restart_agent; fi
        else
          warn "Backend.cfg not found (${BACKEND_CFG_FILE}) — agent is not installed."
        fi
        ;;
      4)
        need_writable "$BACKEND_CFG_FILE" || continue
        ask_secret new_key "New agent key"
        if [[ -f "$BACKEND_CFG_FILE" ]]; then
          cp "$BACKEND_CFG_FILE" "${BACKEND_CFG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
          cfg_set key "$new_key" "$BACKEND_CFG_FILE"
          ok "Agent key updated ($(mask_key "$new_key")) in ${BACKEND_CFG_FILE}"
          if [[ "$_installed" -eq 1 ]] && ask_yesno "Restart agent to apply?" "y"; then restart_agent; fi
        else
          warn "Backend.cfg not found (${BACKEND_CFG_FILE}) — agent is not installed."
        fi
        ;;
      5)
        need_writable "$_cf" || continue
        ask new_zone "New zone name" ""
        if [[ -f "$_cf" ]]; then
          cp "$_cf" "${_cf}.bak.$(date +%Y%m%d-%H%M%S)"
          set_zone_in_yaml "$new_zone" "$_cf"
          ok "Zone updated to: ${new_zone} in ${_cf}"
          if [[ "$_installed" -eq 1 ]] && ask_yesno "Restart agent to apply?" "y"; then restart_agent; fi
        else
          warn "No config file found. Run a dry-run first: ${BLD}./agent-install.sh --dry-run${RST}"
        fi
        ;;
      6)
        [[ "$_installed" -eq 0 ]] && { warn "Agent not installed — cannot restart."; continue; }
        require_root
        restart_agent
        ;;
      7)
        [[ "$_installed" -eq 0 ]] && { warn "Agent not installed — no log file."; continue; }
        echo ""
        if [[ -f "$AGENT_LOG_FILE" ]]; then
          tail -50 "$AGENT_LOG_FILE"
        else
          warn "Log not found: ${AGENT_LOG_FILE}"
        fi
        ;;
      8)
        test_connectivity
        # Veza moze da prolazi i kad backend odbija kljuc: pogledaj poslednji handshake u logu
        if [[ -f "$AGENT_LOG_FILE" ]]; then
          local _last; _last=$(grep -E 'Connected using HTTP/2|Forbidden \(403\)' "$AGENT_LOG_FILE" 2>/dev/null | tail -1 || true)
          if [[ "$_last" == *"Forbidden (403)"* ]]; then
            warn "Last backend response in agent.log: 403 Forbidden — check the agent key (option 4)"
          elif [[ -n "$_last" ]]; then
            ok "Last backend handshake in agent.log: connected"
          else
            log "No backend handshake found in agent.log yet"
          fi
        fi
        ;;
      9)
        # Find last backup — works against system path or local file
        local _bdir
        [[ -f "$AGENT_CONFIG_FILE" ]] && _bdir="$AGENT_CONFIG_FILE" || _bdir="./configuration.yaml"
        local last_backup; last_backup=$(ls -t "${_bdir}.bak."* 2>/dev/null | head -1 || echo "")
        if [[ -n "$last_backup" ]]; then
          echo "Last backup: ${last_backup}"
          if ask_yesno "Restore this backup?" "n"; then
            cp "$last_backup" "$_bdir"
            ok "Restored from ${last_backup}"
            if [[ "$_installed" -eq 1 ]] && ask_yesno "Restart agent to apply?" "y"; then restart_agent; fi
          fi
        else
          warn "No backups found"
        fi
        ;;
      e|E)
        # Export config to JSON — reads system path if installed, else ./configuration.yaml
        local _src="${AGENT_CONFIG_FILE}"
        [[ ! -f "$_src" ]] && _src="./configuration.yaml"
        local out="instana-config-export-$(date +%Y%m%d-%H%M%S).json"
        local bh; bh=$(cfg_get host "$BACKEND_CFG_FILE" 2>/dev/null || true)
        local bp; bp=$(cfg_get port "$BACKEND_CFG_FILE" 2>/dev/null || true)
        local ak; ak=$(cfg_get key "$BACKEND_CFG_FILE" 2>/dev/null || true)
        local zn; zn=$(yaml_get "availability-zone" "$_src" 2>/dev/null || true)
        local am; am=$(cfg_get mode "$AGENT_CFG_FILE" 2>/dev/null || true)
        local ph; ph=$(cfg_get proxy.host "$BACKEND_CFG_FILE" 2>/dev/null || true)
        local pp; pp=$(cfg_get proxy.port "$BACKEND_CFG_FILE" 2>/dev/null || true)
        local te; te=$(grep -m1 "^[[:space:]]*-[[:space:]]*'\?environment=" "$_src" 2>/dev/null | sed "s/.*environment=//; s/'*[[:space:]]*\$//" || true)
        local tt; tt=$(grep -m1 "^[[:space:]]*-[[:space:]]*'\?team=" "$_src" 2>/dev/null | sed "s/.*team=//; s/'*[[:space:]]*\$//" || true)
        if [[ -z "$bh" && -z "$ak" && -z "$zn" ]]; then
          warn "No configuration found (${BACKEND_CFG_FILE} / ${_src})"
          printf "  Install the agent first, or run: ${BLD}./agent-install.sh --dry-run${RST}\n"
        else
          # Use printf instead of heredoc — heredoc competes with piped stdin in the read loop
          # Write to temp first, then move — ensures 0600 before key is written
          local _tmp; _tmp=$(mktemp)
          chmod 0600 "$_tmp"
          printf '{\n  "schema": "instana-agent-input",\n  "schema_version": 1,\n  "parameters": {\n    "HOST": "%s",\n    "PORT": "%s",\n    "UPDATE_MODE": "dynamic",\n    "AGENT_MODE": "%s",\n    "ZONE": "%s",\n    "TAG_ENV": "%s",\n    "TAG_TEAM": "%s",\n    "PROXY_HOST": "%s",\n    "PROXY_PORT": "%s"\n  },\n  "secrets": {\n    "AGENT_KEY": "%s"\n  },\n  "sensors": {}\n}\n' \
            "${bh:-}" "${bp:-443}" "${am:-APM}" "${zn:-}" "${te:-}" "${tt:-}" \
            "${ph:-}" "${pp:-}" "${ak:-}" > "$_tmp"
          mv "$_tmp" "$out"
          ok "Exported to: ${out} (permissions: 0600)"
          printf "  Load with: ${BLD}./agent-install.sh --config %s${RST}\n" "$out"
        fi
        ;;
      0) echo "Bye."; exit 0 ;;
      *) warn "Unknown choice: ${choice}" ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
#  Support bundle                                                              #
# --------------------------------------------------------------------------- #
generate_support_bundle() {
  hdr "Generating Support Bundle"

  local bundle_dir; bundle_dir=$(mktemp -d)
  local bundle_name="instana-support-bundle-$(date +%Y%m%d-%H%M%S)"
  local bundle_zip="${bundle_name}.zip"

  log "Collecting system info..."

  # System info
  {
    echo "=== System Info ==="
    uname -a
    echo ""
    echo "=== OS Release ==="
    cat /etc/os-release 2>/dev/null || echo "(not found)"
    echo ""
    echo "=== Disk Usage ==="
    df -h /opt 2>/dev/null || df -h /
    echo ""
    echo "=== Memory ==="
    free -h 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== CPU ==="
    nproc && lscpu 2>/dev/null | grep -E "Model name|CPU\(s\)|Architecture" || true
    echo ""
    echo "=== Java ==="
    java -version 2>&1 || echo "(not found)"
  } > "${bundle_dir}/system-info.txt"
  ok "System info collected"

  # Agent configuration (masked)
  if [[ -f "$AGENT_CONFIG_FILE" ]]; then
    sed 's/\(key:\s*\).*/\1<MASKED>/g; s/\(password:\s*\).*/\1<MASKED>/g' \
      "$AGENT_CONFIG_FILE" > "${bundle_dir}/configuration.yaml"
    ok "Configuration collected (keys masked)"
  else
    echo "(no configuration.yaml found)" > "${bundle_dir}/configuration.yaml"
  fi
  if [[ -f "$BACKEND_CFG_FILE" ]]; then
    sed 's/^\([[:space:]]*\(key\|proxy\.password\|proxy\.user\)[[:space:]]*=\).*/\1<MASKED>/' \
      "$BACKEND_CFG_FILE" > "${bundle_dir}/Backend.cfg"
    ok "Backend.cfg collected (key/proxy credentials masked)"
  fi
  if [[ -f "$AGENT_CFG_FILE" ]]; then
    cp "$AGENT_CFG_FILE" "${bundle_dir}/Agent.cfg"
  fi

  # Agent log (last 500 lines, masked)
  if [[ -f "$AGENT_LOG_FILE" ]]; then
    tail -500 "$AGENT_LOG_FILE" | \
      sed 's/key=[A-Za-z0-9_-]\{8,\}/key=<MASKED>/g' \
      > "${bundle_dir}/agent.log"
    ok "Agent log collected (last 500 lines, keys masked)"
  fi

  # Service status
  {
    echo "=== systemctl status ==="
    systemctl status "${AGENT_SERVICE}" 2>&1 || true
    echo ""
    echo "=== journalctl (last 50 lines) ==="
    journalctl -u "${AGENT_SERVICE}" -n 50 2>/dev/null || true
  } > "${bundle_dir}/service-status.txt"
  ok "Service status collected"

  # Network info
  {
    echo "=== Listening ports ==="
    ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "(ss/netstat not available)"
    echo ""
    echo "=== Backend connectivity test ==="
    local host; host=$(cfg_get host "$BACKEND_CFG_FILE" 2>/dev/null || true)
    local port; port=$(cfg_get port "$BACKEND_CFG_FILE" 2>/dev/null || true)
    port="${port:-443}"
    if [[ -n "$host" ]]; then
      echo "Testing ${host}:${port}:"
      tcp_open "$host" "$port" && echo "REACHABLE" || echo "UNREACHABLE"
    fi
  } > "${bundle_dir}/network.txt"
  ok "Network info collected"

  # Detected processes
  {
    echo "=== Running processes (relevant) ==="
    ps aux | grep -E "instana|java|mysql|postgres|nginx|httpd|tomcat|mq" | grep -v grep || true
  } > "${bundle_dir}/processes.txt"

  # Pack into zip
  if command -v zip &>/dev/null; then
    zip -qr "${bundle_zip}" -j "${bundle_dir}"/ 2>/dev/null || \
      tar czf "${bundle_name}.tar.gz" -C "${bundle_dir}" .
    rm -rf "${bundle_dir}"
    ok "Support bundle ready: ${bundle_zip}"
  else
    tar czf "${bundle_name}.tar.gz" -C "${bundle_dir}" .
    rm -rf "${bundle_dir}"
    ok "Support bundle ready: ${bundle_name}.tar.gz"
  fi

  echo ""
  echo -e "Send this bundle to Instana Support along with your case number."
  echo -e "No credentials or full keys are included."
}

# --------------------------------------------------------------------------- #
#  Load JSON config file                                                       #
# --------------------------------------------------------------------------- #
load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || { err "Config file not found: ${file}"; exit 1; }
  if ! command -v jq &>/dev/null; then
    warn "jq not found — attempting auto-install..."
    local pkg_mgr; pkg_mgr=$(detect_pkg_manager)
    case "$pkg_mgr" in
      apt)    sudo apt-get install -y -qq jq >/dev/null 2>&1 ;;
      yum)    sudo yum install -y -q jq >/dev/null 2>&1 ;;
      dnf)    sudo dnf install -y -q jq >/dev/null 2>&1 ;;
      zypper) sudo zypper install -y -q jq >/dev/null 2>&1 ;;
    esac
    command -v jq &>/dev/null || { err "Could not install jq automatically. Run: sudo apt-get install -y jq"; exit 1; }
    ok "jq installed"
  fi

  log "Loading config from: ${file}"
  BACKEND_HOST=$(jq -r '.parameters.HOST // empty' "$file")
  BACKEND_PORT=$(jq -r '.parameters.PORT // "443"' "$file")
  SAAS_REGION=$(jq -r '.parameters.SAAS_REGION // empty' "$file")
  if [[ -n "$SAAS_REGION" ]]; then
    BACKEND_HOST="${SAAS_REGION%%:*}"
    BACKEND_PORT="${SAAS_REGION##*:}"
  fi
  UPDATE_MODE=$(jq -r '.parameters.UPDATE_MODE // "dynamic"' "$file")
  AGENT_MODE=$(jq -r '.parameters.AGENT_MODE // "APM"' "$file")
  ZONE=$(jq -r '.parameters.ZONE // empty' "$file")
  TAG_ENV=$(jq -r '.parameters.TAG_ENV // empty' "$file")
  TAG_TEAM=$(jq -r '.parameters.TAG_TEAM // empty' "$file")
  PROXY_TYPE=$(jq -r '.parameters.PROXY_TYPE // "http"' "$file")
  case "$PROXY_TYPE" in http|socks4|socks5) ;; *) err "PROXY_TYPE must be http, socks4 or socks5 (got: ${PROXY_TYPE})"; exit 1 ;; esac
  PROXY_HOST=$(jq -r '.parameters.PROXY_HOST // empty' "$file")
  PROXY_PORT=$(jq -r '.parameters.PROXY_PORT // empty' "$file")
  PROXY_USER=$(jq -r '.parameters.PROXY_USER // empty' "$file")
  PROXY_PASS=$(jq -r '.secrets.PROXY_PASS // empty' "$file")
  AGENT_KEY=$(jq -r '.secrets.AGENT_KEY // empty' "$file")
  SENSORS_JSON=$(jq -c '.sensors // {}' "$file")
  ok "Config loaded from ${file}"
}

# --------------------------------------------------------------------------- #
#  Load profil                                                                 #
# --------------------------------------------------------------------------- #
load_profile() {
  local name="$1"
  local pfile="${PROFILES_DIR}/${name}.json"
  [[ -f "$pfile" ]] || { err "Profile not found: ${pfile}"; exit 1; }
  load_config_file "$pfile"
  ok "Profile loaded: ${name}"
}

# --------------------------------------------------------------------------- #
#  Interaktivni wizard                                                         #
# --------------------------------------------------------------------------- #
interactive_wizard() {
  hdr "Instana Agent Installer v${SCRIPT_VERSION}"
  printf "Tip: open ${BLD}agent-config-generator.html${RST} in your browser for a visual wizard.\n\n"

  # Ako agent već postoji — ponudi edit umesto reinstall
  if agent_is_installed; then
    printf "${YEL}Instana Agent is already installed.${RST}\n"
    ask_choice install_action "What do you want to do?" \
      "Edit existing configuration" \
      "Reinstall / reconfigure" \
      "Exit"
    case "$install_action" in
      "Edit"*)  show_edit_menu; return ;;
      "Exit") exit 0 ;;
    esac
    echo ""
  fi

  # ── Pitanje 1: Backend ──────────────────────────────────────────────────────
  printf "${BLD}Backend${RST} — where does the agent report to?\n"
  printf "  (your region: Instana UI → More → About Instana)\n"
  local _n=${#SAAS_REGIONS[@]} _i _r
  for ((_i = 0; _i < _n; _i++)); do
    _r="${SAAS_REGIONS[_i]}"
    printf "  ${CYN}%d)${RST} SaaS — %s  (%s)\n" "$((_i + 1))" "${_r%%|*}" "${_r##*|}"
  done
  printf "  ${CYN}%d)${RST} Self-hosted — enter host manually\n" "$((_n + 1))"
  local bchoice
  while true; do
    printf "Choose [1-%d]: " "$((_n + 1))"; read -r bchoice
    if [[ "$bchoice" =~ ^[0-9]+$ ]] && (( bchoice >= 1 && bchoice <= _n )); then
      BACKEND_HOST="${SAAS_REGIONS[bchoice-1]##*|}"; BACKEND_PORT="443"; break
    elif [[ "$bchoice" == "$((_n + 1))" ]]; then
      ask BACKEND_HOST "Backend host" "" validate_host
      ask BACKEND_PORT "Port" "443" validate_port; break
    else
      err "Enter 1–$((_n + 1))."
    fi
  done
  echo ""

  # ── Pitanje 2: Agent key ────────────────────────────────────────────────────
  printf "${BLD}Agent key${RST} — Instana UI → Settings → Agents → Install Agents\n"
  ask_secret AGENT_KEY "Agent key"
  echo ""

  # ── Pitanje 3: Zone (brzo, opciono) ─────────────────────────────────────────
  ask ZONE "Zone name (optional, press Enter to skip)" ""
  echo ""

  # Defaults za sve ostalo
  AGENT_MODE="${AGENT_MODE:-APM}"
  UPDATE_MODE="${UPDATE_MODE:-dynamic}"
  PROXY_TYPE="${PROXY_TYPE:-http}"
  PROXY_HOST="${PROXY_HOST:-}"
  PROXY_PORT="${PROXY_PORT:-}"

  # ── Pre-checks ───────────────────────────────────────────────────────────────
  run_prechecks "$BACKEND_HOST" "$BACKEND_PORT"
  detect_services

  # ── Plan ─────────────────────────────────────────────────────────────────────
  hdr "Installation Plan"
  sep
  printf "  Backend:   %s:%s\n" "$BACKEND_HOST" "$BACKEND_PORT"
  printf "  Agent key: %s\n" "$(mask_key "$AGENT_KEY")"
  printf "  Mode:      %s\n" "$AGENT_MODE"
  printf "  Updates:   %s\n" "$UPDATE_MODE"
  [[ -n "$ZONE" ]] && printf "  Zone:      %s\n" "$ZONE"
  echo ""
  printf "  Actions:\n"
  printf "    [+] Generate configuration.yaml\n"
  printf "    [+] Download and run Instana Agent installer\n"
  printf "    [+] Copy config → %s\n" "$AGENT_CONFIG_FILE"
  printf "    [+] Enable and start %s service\n" "$AGENT_SERVICE"
  [[ "$DRY_RUN" -eq 1 ]] && printf "\n  ${YEL}DRY RUN — no changes will be made${RST}\n"
  sep
  echo ""
  printf "Need proxy or advanced settings? Use ${BLD}agent-config-generator.html${RST} in your\nbrowser to build a full config, then run: ${BLD}./agent-install.sh --config file.json${RST}\n\n"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    ask_yesno "Proceed?" "y" || { echo "Aborted."; exit 0; }
    require_root
  fi

  # ── Execute ───────────────────────────────────────────────────────────────────
  generate_yaml "$ZONE" "" ""

  if [[ "$DRY_RUN" -eq 0 ]]; then
    install_agent "$AGENT_KEY" "$BACKEND_HOST" "$BACKEND_PORT" "$UPDATE_MODE" "$AGENT_MODE"
    apply_config "configuration.yaml"
    apply_backend_proxy "$PROXY_HOST" "$PROXY_PORT" "${PROXY_USER:-}" "${PROXY_PASS:-}"
    restart_agent
    hdr "Done!"
    show_status
    printf "\nNext steps:\n"
    printf "  • Check Instana UI → Infrastructure — agent should appear within 1 min\n"
    printf "  • Logs: ${BLD}sudo tail -f %s${RST}\n" "$AGENT_LOG_FILE"
    printf "  • Edit: ${BLD}sudo ./agent-install.sh${RST} → Edit existing configuration\n"
    printf "  • Support bundle: ${BLD}./agent-install.sh --support-bundle${RST}\n"
  else
    hdr "Dry run complete — no changes made."
    printf "Generated ${BLD}configuration.yaml${RST} (review before use):\n\n"
    cat configuration.yaml
    apply_backend_proxy "$PROXY_HOST" "$PROXY_PORT" "${PROXY_USER:-}" "${PROXY_PASS:-}"
  fi
}

# Validatori za interaktivni unos
validate_host() {
  [[ -n "$1" ]] && echo "ok" || echo "Host is required"
}
validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) && echo "ok" || echo "Port must be 1–65535"
}

# --------------------------------------------------------------------------- #
#  Main dispatch                                                               #
# --------------------------------------------------------------------------- #
case "$MODE" in
  help)
    show_help ;;
  status)
    show_status
    [[ "$STATUS_OK" -eq 1 ]] || exit 1 ;;
  connectivity)
    test_connectivity
    _conn_rc=0
    [[ "$CONN_FAILS" -eq 0 ]] || _conn_rc=1
    # Veza moze da prolazi i kad backend odbija kljuc: pogledaj poslednji handshake u logu
    if [[ -f "$AGENT_LOG_FILE" ]]; then
      _last=$(grep -E 'Connected using HTTP/2|Forbidden \(403\)' "$AGENT_LOG_FILE" 2>/dev/null | tail -1 || true)
      if [[ "$_last" == *"Forbidden (403)"* ]]; then
        err "Last backend response in agent.log: 403 Forbidden — check the agent key"
        _conn_rc=1
      elif [[ -n "$_last" ]]; then
        ok "Last backend handshake in agent.log: connected"
      else
        log "No backend handshake found in agent.log yet"
      fi
    fi
    exit "$_conn_rc" ;;
  edit)
    show_edit_menu ;;
  bundle)
    generate_support_bundle ;;
  install)
    # If config file specified, load it first
    [[ -n "$CONFIG_FILE" ]] && load_config_file "$CONFIG_FILE"
    [[ -n "$PROFILE_NAME" ]] && load_profile "$PROFILE_NAME"

    # If a config/profile was loaded, ask only for missing required values
    if [[ -n "$CONFIG_FILE" || -n "$PROFILE_NAME" ]]; then
      hdr "Instana Agent Installer v${SCRIPT_VERSION}"
      [[ -n "$PROFILE_NAME" ]] && log "Profile: ${PROFILE_NAME}"
      [[ -n "$CONFIG_FILE"  ]] && log "Config:  ${CONFIG_FILE}"
      echo ""

      # Ask only for what's missing
      if [[ -z "${BACKEND_HOST:-}" ]]; then
        ask_choice _bt "Backend type" "SaaS (IBM hosted)" "Self-hosted (your own server)"
        if [[ "$_bt" == "SaaS"* ]]; then
          local _opts=() _r
          for _r in "${SAAS_REGIONS[@]}"; do _opts+=("${_r%%|*}  —  ${_r##*|}"); done
          log "Your region: Instana UI → More → About Instana"
          ask_choice _sr "SaaS region" "${_opts[@]}"
          BACKEND_HOST="${_sr##*—  }"
          BACKEND_PORT="443"
        else
          ask BACKEND_HOST "Backend hostname or IP" "" validate_host
          ask BACKEND_PORT "Backend port" "443" validate_port
        fi
      fi

      if [[ -z "${AGENT_KEY:-}" ]]; then
        echo -e "Find your key: Instana UI → Settings → Agents → Install Agents"
        ask_secret AGENT_KEY "Agent key"
      fi

      # Show what will be used (from profile + what was just entered)
      echo ""
      sep
      printf "  Backend:  %s:%s\n" "${BACKEND_HOST}" "${BACKEND_PORT:-443}"
      printf "  Mode:     %s\n" "${AGENT_MODE:-APM}"
      printf "  Updates:  %s\n" "${UPDATE_MODE:-dynamic}"
      [[ -n "${ZONE:-}" ]] && printf "  Zone:     %s\n" "${ZONE}"
      [[ -n "$PROFILE_NAME" ]] && printf "  Profile:  %s\n" "${PROFILE_NAME}"
      [[ "$DRY_RUN" -eq 1 ]] && printf "  %s\n" "DRY RUN — no changes will be made"
      sep
      echo ""

      # Generate YAML and run (same path for both profile and config-file)
      if [[ "$DRY_RUN" -eq 0 ]]; then
        ask_yesno "Proceed?" "y" || { echo "Aborted."; exit 0; }
        require_root
      fi
      generate_yaml "${ZONE:-}" "${TAG_ENV:-}" "${TAG_TEAM:-}"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        install_agent "${AGENT_KEY}" "${BACKEND_HOST}" "${BACKEND_PORT:-443}" "${UPDATE_MODE:-dynamic}" "${AGENT_MODE:-APM}"
        apply_config "configuration.yaml"
        apply_backend_proxy "${PROXY_HOST:-}" "${PROXY_PORT:-}" "${PROXY_USER:-}" "${PROXY_PASS:-}"
        restart_agent
        hdr "Done!"
        show_status
        printf "\nNext steps:\n"
        printf "  • Check Instana UI → Infrastructure — agent should appear within 1 min\n"
        printf "  • Logs: ${BLD}sudo tail -f %s${RST}\n" "$AGENT_LOG_FILE"
        printf "  • Edit: ${BLD}sudo ./agent-install.sh${RST} → Edit existing configuration\n"
        printf "  • Support bundle: ${BLD}./agent-install.sh --support-bundle${RST}\n"
      else
        hdr "Dry run complete — no changes made."
        printf "Generated ${BLD}configuration.yaml${RST} (review before use):\n\n"
        cat configuration.yaml
        apply_backend_proxy "${PROXY_HOST:-}" "${PROXY_PORT:-}" "${PROXY_USER:-}" "${PROXY_PASS:-}"
        printf "\n\nInstall command:\n"
        echo "  curl -o /tmp/setup_instana_agent.sh https://setup.instana.io/agent \\"
        printf "    && sudo bash /tmp/setup_instana_agent.sh -a '<KEY>' -t %s -m %s -e %s:%s\n" \
          "${UPDATE_MODE:-dynamic}" "$(agent_mode_flag "${AGENT_MODE:-APM}")" "${BACKEND_HOST}" "${BACKEND_PORT:-443}"
      fi

    # If we have all params from file (no missing values at all), skip wizard entirely
    elif [[ -n "${BACKEND_HOST:-}" && -n "${AGENT_KEY:-}" ]]; then
      hdr "Instana Agent Installer v${SCRIPT_VERSION}"
      log "Parameters loaded from file — skipping wizard"
      printf "  Backend:  %s:%s\n" "${BACKEND_HOST}" "${BACKEND_PORT:-443}"
      printf "  Mode:     %s\n" "${AGENT_MODE:-APM}"
      printf "  Updates:  %s\n" "${UPDATE_MODE:-dynamic}"
      [[ -n "${ZONE:-}" ]] && printf "  Zone:     %s\n" "${ZONE}"
      echo ""
      if [[ "$DRY_RUN" -eq 0 ]]; then
        ask_yesno "Proceed?" "y" || exit 0
        require_root
      fi
      generate_yaml "${ZONE:-}" "${TAG_ENV:-}" "${TAG_TEAM:-}"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        install_agent "${AGENT_KEY}" "${BACKEND_HOST}" "${BACKEND_PORT:-443}" "${UPDATE_MODE:-dynamic}" "${AGENT_MODE:-APM}"
        apply_config "configuration.yaml"
        apply_backend_proxy "${PROXY_HOST:-}" "${PROXY_PORT:-}" "${PROXY_USER:-}" "${PROXY_PASS:-}"
        restart_agent
        show_status
      else
        hdr "Dry run complete."
        cat configuration.yaml
        apply_backend_proxy "${PROXY_HOST:-}" "${PROXY_PORT:-}" "${PROXY_USER:-}" "${PROXY_PASS:-}"
        printf "\n\nInstall command:\n"
        echo "  curl -o /tmp/setup_instana_agent.sh https://setup.instana.io/agent \\"
        printf "    && sudo bash /tmp/setup_instana_agent.sh -a '<KEY>' -t %s -m %s -e %s:%s\n" \
          "${UPDATE_MODE:-dynamic}" "$(agent_mode_flag "${AGENT_MODE:-APM}")" "${BACKEND_HOST}" "${BACKEND_PORT:-443}"
      fi
    else
      interactive_wizard
    fi
    ;;
esac

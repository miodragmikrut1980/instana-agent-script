#!/usr/bin/env bash
# Checks the pieces repro.sh --apply relies on for provider ssh. Installs nothing.
#   ./ssh-selftest-check.sh [host] [user] [identity_file]
set -u
HOST="${1:-localhost}"
USERN="${2:-$(id -un)}"
KEYF="${3:-$HOME/.ssh/repro_selftest}"
F=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; F=1; }
SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -i "$KEYF")
SCPO=(-q -o BatchMode=yes -o ConnectTimeout=15 -i "$KEYF")

printf 'ssh self-test: %s@%s (key %s)\n' "$USERN" "$HOST" "$KEYF"
[[ -f "$KEYF" ]] || { bad "identity file not found: $KEYF"; exit 1; }

if ssh -n "${SSHO[@]}" "$USERN@$HOST" true 2>/dev/null; then ok 'ssh login (BatchMode, no password)'
else bad 'ssh login: is sshd running, is the public key in ~/.ssh/authorized_keys, is the host key in known_hosts?'; exit 1; fi

if ssh -n "${SSHO[@]}" "$USERN@$HOST" 'sudo -n true' 2>/dev/null; then ok 'passwordless sudo (sudo -n)'
else bad 'sudo -n needs a password for this user'; fi

T="$(mktemp)"; printf 'x\n' > "$T"
if scp "${SCPO[@]}" "$T" "$USERN@$HOST:repro-selftest.tmp" 2>/dev/null; then ok 'scp upload to the home directory'
else bad 'scp upload'; fi
ssh -n "${SSHO[@]}" "$USERN@$HOST" 'rm -f ~/repro-selftest.tmp' 2>/dev/null
rm -f "$T"

# Same shape as the install command in repro.sh: key arrives on stdin, then sudo -n -E keeps it.
REMOTE='bash -c '\''IFS= read -r K && INSTANA_AGENT_KEY="$K" sudo -n -E printenv INSTANA_AGENT_KEY'\'''
GOT="$(printf '%s\n' 'SELFTEST_VALUE_123' | ssh "${SSHO[@]}" "$USERN@$HOST" "$REMOTE" 2>/dev/null || true)"
if [[ "$GOT" == 'SELFTEST_VALUE_123' ]]; then ok 'key via stdin survives sudo -n -E'
else bad "key via stdin did not survive sudo -n -E (got: '${GOT:-<empty>}'); check sudoers env_reset / SETENV"; fi

[[ "$F" -eq 0 ]] && printf '\nAll checks passed.\n' || printf '\nSome checks failed.\n'
exit "$F"

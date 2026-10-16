#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '  [OK]   %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s (expected: %s, actual: %s)\n' "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

sudo -v || exit 1
SSH_CONFIG=$(sudo sshd -T) || exit 1
UFW_CONFIG=$(sudo ufw status verbose) || exit 1
get_ssh() { awk -v key="$1" '$1 == key {print $2}' <<< "$SSH_CONFIG"; }

printf 'Server audit: %s, %s\n' "$(hostname -f)" "$(date '+%Y-%m-%d %H:%M')"
echo '[1] SSH service'
check 'Root login disabled' no "$(get_ssh permitrootlogin)"
check 'Password authentication disabled' no "$(get_ssh passwordauthentication)"
PORTS=$(get_ssh port)
NONSTANDARD=yes
[[ -z "$PORTS" ]] && NONSTANDARD=no
grep -qx '22' <<< "$PORTS" && NONSTANDARD=no
check 'SSH listens on a nonstandard port' yes "$NONSTANDARD"
check 'MaxAuthTries equals 3' 3 "$(get_ssh maxauthtries)"

echo '[2] Firewall'
check 'UFW is active' active "$(awk '/^Status:/ {print $2}' <<< "$UFW_CONFIG")"
check 'Default incoming policy is deny' deny "$(sed -n 's/^Default: \([^ ]*\) (incoming).*/\1/p' <<< "$UFW_CONFIG")"

echo '[3] User accounts'
awk -F: '$3 >= 1000 && $3 < 65534 {printf "    %s (uid=%s)\n", $1, $3}' /etc/passwd
printf 'Passed: %s, failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

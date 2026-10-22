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

echo '[4] Web server'
check 'Nginx service is active' active "$(systemctl is-active nginx || true)"
NGINX_SYNTAX=no
if sudo nginx -t >/dev/null 2>&1; then NGINX_SYNTAX=yes; fi
check 'Nginx configuration is valid' yes "$NGINX_SYNTAX"

CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
case "$CERT_MIN_DAYS" in
    ''|*[!0-9]*) printf 'Invalid CERT_MIN_DAYS\n' >&2; exit 1 ;;
esac
[[ ${#CERT_MIN_DAYS} -le 5 && "$CERT_MIN_DAYS" -le 36500 ]] || { printf 'CERT_MIN_DAYS is too large\n' >&2; exit 1; }
CERT_OK=no
if openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend "$((10#$CERT_MIN_DAYS * 86400))" >/dev/null 2>&1; then CERT_OK=yes; fi
check "Certificate valid for at least ${CERT_MIN_DAYS} days" yes "$CERT_OK"

WEB_PERMISSIONS=unsafe
if WORLD_WRITABLE=$(find /var/www/devops-site -perm -o+w -print 2>/dev/null) &&
   [[ -z "$WORLD_WRITABLE" ]] &&
   [[ "$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)" == 600 ]]; then
    WEB_PERMISSIONS=safe
fi
check 'No world-writable site paths and TLS key mode 600' safe "$WEB_PERMISSIONS"

echo '[5] Containerization'
check 'Docker service is active' active "$(systemctl is-active docker || true)"
DB_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || true)
check 'PostgreSQL container is healthy' healthy "$DB_HEALTH"
PRIVATE_PORTS=no
if SOCKETS=$(ss -H -tln 2>/dev/null); then
    if awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/ {bad=1} END {exit bad}' <<< "$SOCKETS"; then
        PRIVATE_PORTS=yes
    fi
fi
check 'Ports 5000 and 5432 listen only on loopback if present' yes "$PRIVATE_PORTS"
check 'App environment file mode is 600' 600 "$(stat -c '%a' /home/devops/app/.env 2>/dev/null || true)"

printf 'Passed: %s, failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

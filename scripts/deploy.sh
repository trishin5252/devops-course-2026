#!/usr/bin/env bash
# Publish the committed site over a single non-interactive SSH connection.
set -euo pipefail

die() { printf 'Deploy error: %s\n' "$*" >&2; exit 1; }
DRY_RUN=false
case "${1:-}" in
    '') [[ $# -eq 0 ]] || die 'Usage: deploy.sh [--dry-run]' ;;
    --dry-run) [[ $# -eq 1 ]] || die 'Usage: deploy.sh [--dry-run]'; DRY_RUN=true ;;
    *) die 'Usage: deploy.sh [--dry-run]' ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" || die 'Not inside a Git repository'
LOCAL_DIR="${ROOT}/site/"
REMOTE='devops'
REMOTE_DIR='/var/www/devops-site/'
SITE_URL='https://devops.local'
CA_CERT="${HOME}/devops.crt"

[[ -f "${LOCAL_DIR}index.html" ]] || die 'site/index.html is missing; nothing was synchronized'
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || die 'Commit or preserve all working-tree and staged changes before deployment'
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
command -v rsync >/dev/null || die 'rsync is required on the host'
command -v ssh >/dev/null || die 'ssh is required on the host'

args=(-avz --delete --chmod=D755,F644 -e 'ssh -o BatchMode=yes -o ConnectTimeout=5')
if "$DRY_RUN"; then args+=(--dry-run); fi
if ! rsync "${args[@]}" "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}"; then
    die 'rsync failed'
fi

if "$DRY_RUN"; then
    printf 'Dry run for commit %s; server unchanged\n' "$COMMIT"
    exit 0
fi

command -v curl >/dev/null || die 'curl is required for the HTTPS check'
[[ -r "$CA_CERT" ]] || die "Trusted certificate is not readable: ${CA_CERT}"
if ! curl --fail --silent --show-error --max-time 10 --cacert "$CA_CERT" --output /dev/null "$SITE_URL"; then
    die 'HTTPS availability or certificate validation failed after synchronization'
fi
printf 'Deployed commit %s; HTTPS check passed\n' "$COMMIT"

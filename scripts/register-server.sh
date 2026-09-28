#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <name> <hostname> [description] [monitor_url]" >&2
  exit 1
fi

NAME="$1"
HOSTNAME="$2"
DESCRIPTION="${3:-}"
MONITOR_URL="${4:-http://10.0.0.23:3000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env.local}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi

ADMIN_API_KEY="$(awk -F= '/^ADMIN_API_KEY=/{print $2}' "$ENV_FILE")"

if [[ -z "$ADMIN_API_KEY" ]]; then
  echo "ADMIN_API_KEY not found in $ENV_FILE" >&2
  exit 1
fi

curl -sS -X POST "$MONITOR_URL/api/servers" \
  -H "Content-Type: application/json" \
  -H "x-admin-key: $ADMIN_API_KEY" \
  -d "$(printf '{"name":"%s","hostname":"%s","description":"%s"}' "$NAME" "$HOSTNAME" "$DESCRIPTION")"

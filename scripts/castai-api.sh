#!/usr/bin/env bash
# Calls the CAST AI REST API.
# Usage: scripts/castai-api.sh METHOD /v1/path [json-body]
# Key from env or ~/.castai/api-token.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: scripts/castai-api.sh GET|POST|PUT|PATCH|DELETE /v1/... [json-body]" >&2
  exit 2
fi
METHOD="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
URLPATH="$2"
BODY="${3:-}"
API="${CASTAI_API_URL:-https://api.cast.ai}"

# never print the key
if [ -z "${CASTAI_API_KEY:-}" ]; then
  if [ -s "${HOME}/.castai/api-token" ]; then
    CASTAI_API_KEY="$(tr -d '[:space:]' < "${HOME}/.castai/api-token")"
  else
    echo "ERROR: CASTAI_API_KEY unset and ~/.castai/api-token missing" >&2
    exit 1
  fi
fi

case "${URLPATH}" in /*) ;; *) URLPATH="/${URLPATH}" ;; esac

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

# key via stdin header file
args=(-sS -X "${METHOD}" -o "${out}" -w '%{http_code}' -H 'Accept: application/json' -H @-)
if [ -n "${BODY}" ]; then
  args+=(-H 'Content-Type: application/json' --data "${BODY}")
fi
code="$(printf 'X-API-Key: %s\n' "${CASTAI_API_KEY}" | curl "${args[@]}" "${API}${URLPATH}")"

if jq -e . "${out}" >/dev/null 2>&1; then
  jq . "${out}"
else
  cat "${out}"; echo
fi

if [ "${code}" -ge 400 ] 2>/dev/null; then
  echo "HTTP ${code} ${METHOD} ${URLPATH}" >&2
  exit 1
fi

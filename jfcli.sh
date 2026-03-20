#!/usr/bin/env bash

export JF_NAME="psazuse" JFROG_CLI_LOG_LEVEL="DEBUG" 
export JF_RT_URL="https://${JF_NAME}.jfrog.io" RT_REPO_VIRTUAL="py-bpr-virtual" 
export RT_REPO_DEV_LOCAL="py-bpr-dev-local" RT_REPO_QA_LOCAL="py-bpr-qa-local" RT_REPO_PROD_LOCAL="py-bpr-prod-local" RT_REPO_REMOTE="pypi-remote"

export BUILD_NAME="py-bpr-app" BUILD_ID="cmd.$(date '+%Y-%m-%d-%H-%M')" 

export JFROG_CLI_LOG_LEVEL="DEBUG" MODULE_NAME="py-artifacts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "${SCRIPT_DIR}"
REQUIREMENTS_TXT="${REQUIREMENTS_TXT:-${SCRIPT_DIR}/requirements.txt}"
BAD_DEPS_DIR="${SCRIPT_DIR}/.jfrog/bad-deps"
PROMOTE_CHECKOUT_DIR="${PROMOTE_CHECKOUT_DIR:-${SCRIPT_DIR}/.jfrog/promote-checkout}"

# Parse Artifactory api/build JSON → table (.buildInfo.statuses or .statuses). Requires jq.
__format_build_status_ts() {
  local raw="${1:-}"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    printf '%s' '—'
    return
  fi
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$raw"
    return
  fi
  local sec=$((raw / 1000)) out=""
  if out="$(date -r "$sec" -u +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"; then
    printf '%s' "$out"
    return
  fi
  if out="$(date -u -d "@$sec" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null)"; then
    printf '%s' "$out"
    return
  fi
  printf '%s' "$raw"
}

__write_build_statuses_table() {
  local json_file="$1" out_file="$2"
  {
    printf '%s\n' "+-----------------------------+------------------------------------------+------------------------------------------+----------------------+"
    printf '%s\n' "| Timestamp (UTC)             | Status                                   | Comment                                  | User                 |"
    printf '%s\n' "+-----------------------------+------------------------------------------+------------------------------------------+----------------------+"
    local ts_raw status comment user fts line
    while IFS=$'\t' read -r ts_raw status comment user || [[ -n "${ts_raw:-}" ]]; do
      if [[ -z "${ts_raw:-}" && -z "${status:-}" && -z "${comment:-}" ]]; then
        continue
      fi
      fts="$(__format_build_status_ts "$ts_raw")"
      line="$(printf '| %-27s | %-40s | %-40s | %-20s |' "${fts:0:27}" "${status:0:40}" "${comment:0:40}" "${user:0:20}")"
      printf '%s\n' "$line"
    done < <(
      jq -r '
        (.buildInfo // .).statuses // []
        | .[]
        | [
            (if .timestamp == null or .timestamp == "" then "" else (.timestamp | tostring) end),
            (.status // ""),
            (.comment // ""),
            (.user // "")
          ]
        | @tsv
      ' "$json_file"
    )
    printf '%s\n' "+-----------------------------+------------------------------------------+------------------------------------------+----------------------+"
  } >"$out_file"
}

rm -rf .jfrog
jf pipc --repo-deploy="${RT_REPO_VIRTUAL}" --repo-resolve="${RT_REPO_VIRTUAL}"

jf pip install -r "${REQUIREMENTS_TXT}"

# Exact closure of requirements.txt (direct + transitive) for build-add-dependencies only.
mkdir -p "${BAD_DEPS_DIR}"
jf pip download -r "${REQUIREMENTS_TXT}" -d "${BAD_DEPS_DIR}"

# python3 -m compileall .
# python3 -m unittest tests/test_helloworld.py

printf '\n*** Build publish: name: %s ID: %s ***\n\n' "${BUILD_NAME}" "${BUILD_ID}"
jf rt bag "${BUILD_NAME}" "${BUILD_ID}"
jf rt bce "${BUILD_NAME}" "${BUILD_ID}"
# Dependencies: only wheels/sdists from requirements.txt + transitive (not whole virtual repo).
jf rt bad "${BUILD_NAME}" "${BUILD_ID}" "${BAD_DEPS_DIR}/*" --module="${MODULE_NAME}"
jf rt bp "${BUILD_NAME}" "${BUILD_ID}" --detailed-summary=true

sleep 2
printf '\n*** Build promote: %s → %s ***\n\n' "${RT_REPO_VIRTUAL}" "${RT_REPO_QA_LOCAL}"
jf rt bpr "${BUILD_NAME}" "${BUILD_ID}" "${RT_REPO_QA_LOCAL}" \
  --status="Promoting build DEV to QA" \
  --include-dependencies \
  --copy

sleep 2
printf '\n*** Build promote: %s → %s ***\n\n' "${RT_REPO_VIRTUAL}" "${RT_REPO_PROD_LOCAL}"
jf rt bpr "${BUILD_NAME}" "${BUILD_ID}" "${RT_REPO_PROD_LOCAL}" \
  --status="Promoting build QA to PROD" \
  --include-dependencies \
  --copy

sleep 2

# ---------------------------------------------------------------------------
# Build promotion query + checkout (artifacts associated with this build in QA)
# ---------------------------------------------------------------------------
printf '\n*** Build promotion query: %s / %s ***\n\n' "${BUILD_NAME}" "${BUILD_ID}"
mkdir -p "${PROMOTE_CHECKOUT_DIR}/files"

BUILD_INFO_JSON="${PROMOTE_CHECKOUT_DIR}/build-info.json"
SEARCH_JSON="${PROMOTE_CHECKOUT_DIR}/promoted-artifacts-search.json"
SUMMARY_TABLE="${PROMOTE_CHECKOUT_DIR}/promotion-summary.txt"
STATUSES_TABLE="${PROMOTE_CHECKOUT_DIR}/build-statuses.txt"

# Path must be its own argument; do not merge with -sf (CLI error: "Could not find argument in curl command").
jf rt curl -sf "api/build/${BUILD_NAME}/${BUILD_ID}" > "${BUILD_INFO_JSON}" \
  || printf 'WARN: api/build curl failed; JSON may be empty\n'

if [[ -s "${BUILD_INFO_JSON}" ]] && command -v jq >/dev/null 2>&1 && jq empty "${BUILD_INFO_JSON}" 2>/dev/null; then
  printf '\n*** Build statuses (parsed from %s) ***\n' "${BUILD_INFO_JSON}"
  __write_build_statuses_table "${BUILD_INFO_JSON}" "${STATUSES_TABLE}"
  cat "${STATUSES_TABLE}"
elif [[ -s "${BUILD_INFO_JSON}" ]] && command -v jq >/dev/null 2>&1; then
  printf 'WARN: %s is not valid JSON; skip status table\n' "${BUILD_INFO_JSON}"
elif [[ -s "${BUILD_INFO_JSON}" ]]; then
  printf 'WARN: jq not installed; install jq to parse statuses (brew install jq)\n'
else
  printf 'WARN: skip status parse (no build-info JSON)\n'
fi

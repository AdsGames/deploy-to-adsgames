#!/bin/bash

# Syncs a game's adsgames.json to the play service. Local achievement icons are
# uploaded to the game bucket under a content hash, and their paths replaced
# with the public URL. Needs jq, curl and (for icons) gcloud.

set -euo pipefail

BUCKET="www-adsgames-net-data-prod"
CACHE_CONTROL="public, max-age=31536000, immutable"

play_url() {
  case "$1" in
    prod) echo "https://play.adsgames.net" ;;
    dev) echo "https://play.beta.adsgames.net" ;;
    *)
      echo "::error::Unknown environment $1, use dev or prod" >&2
      return 1
      ;;
  esac
}

if [ -z "${PROJECT_ID:-}" ]; then
  echo "Missing env PROJECT_ID"
  exit 1
fi

MANIFEST="${MANIFEST:-adsgames.json}"
DRY_RUN="${DRY_RUN:-false}"
ENVIRONMENTS="${ENVIRONMENTS:-dev prod}"

if [ ! -f "${MANIFEST}" ]; then
  echo "No manifest at ${MANIFEST}, nothing to sync"
  exit 0
fi

if [ -z "${API_KEY:-}" ]; then
  # Pull requests from forks get no secrets, so checks can not fail on that
  if [ "${DRY_RUN}" = "true" ]; then
    echo "::warning::No API key, skipping the manifest check for ${MANIFEST}"
    exit 0
  fi
  echo "Missing env API_KEY"
  exit 1
fi

if ! BODY=$(jq -c 'del(."$schema")' "${MANIFEST}"); then
  echo "::error file=${MANIFEST}::${MANIFEST} is not valid JSON"
  exit 1
fi

# Icons are relative to the manifest
MANIFEST_DIR=$(dirname "${MANIFEST}")

while IFS= read -r ICON; do
  case "${ICON}" in
    http://* | https://*) continue ;;
  esac

  FILE="${MANIFEST_DIR}/${ICON}"
  if [ ! -f "${FILE}" ]; then
    echo "::error file=${MANIFEST}::Icon ${ICON} not found at ${FILE}"
    exit 1
  fi

  EXT=$(echo "${ICON##*.}" | tr '[:upper:]' '[:lower:]')
  case "${EXT}" in
    png | jpg | jpeg | webp | gif | svg) ;;
    *)
      echo "::error file=${MANIFEST}::Icon ${ICON} must be png, jpg, webp, gif or svg"
      exit 1
      ;;
  esac

  # Content addressed, so a changed icon gets a new URL and caches never go stale
  HASH=$(sha256sum "${FILE}" | cut -c1-16)
  OBJECT="games/${PROJECT_ID}/achievements/${HASH}.${EXT}"
  URL="https://storage.googleapis.com/${BUCKET}/${OBJECT}"

  if [ "${DRY_RUN}" != "true" ]; then
    echo "Uploading ${ICON} to ${OBJECT}"
    gcloud storage cp --cache-control="${CACHE_CONTROL}" "${FILE}" "gs://${BUCKET}/${OBJECT}"
  fi

  BODY=$(jq -c --arg icon "${ICON}" --arg url "${URL}" \
    '.achievements |= map(if .icon == $icon then .icon = $url else . end)' <<<"${BODY}")
done < <(jq -r '[.achievements // [] | .[].icon // empty] | unique | .[]' "${MANIFEST}")

QUERY=""
MODE="Syncing"
DONE="Synced"
if [ "${DRY_RUN}" = "true" ]; then
  QUERY="?dryRun=true"
  MODE="Checking"
  DONE="Checked"
fi

for ENVIRONMENT in ${ENVIRONMENTS}; do
  BASE_URL=$(play_url "${ENVIRONMENT}")
  echo "${MODE} ${MANIFEST} for ${PROJECT_ID} on ${ENVIRONMENT} (${BASE_URL})"

  RESPONSE=$(
    curl -sS -X PUT \
      -w '\n%{http_code}' \
      --data-binary "${BODY}" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${API_KEY}" \
      "${BASE_URL}/games/${PROJECT_ID}/manifest${QUERY}"
  )
  STATUS=$(tail -n1 <<<"${RESPONSE}")
  OUTPUT=$(sed '$d' <<<"${RESPONSE}")

  if [ "${STATUS}" != "200" ]; then
    MESSAGE=$(jq -r '.error // empty' <<<"${OUTPUT}" 2>/dev/null || true)
    echo "::error file=${MANIFEST}::${ENVIRONMENT} rejected the manifest (${STATUS}): ${MESSAGE:-${OUTPUT}}"
    exit 1
  fi

  SUMMARY=$(jq -r '"\(.leaderboards) leaderboards, \(.achievements) achievements"' <<<"${OUTPUT}")
  echo "${ENVIRONMENT}: ${SUMMARY}"

  # Archiving hides definitions, so make it visible in the run
  for KIND in leaderboards achievements; do
    ARCHIVED=$(jq -r --arg kind "${KIND}" '.archived[$kind] | join(", ")' <<<"${OUTPUT}")
    RESTORED=$(jq -r --arg kind "${KIND}" '.restored[$kind] | join(", ")' <<<"${OUTPUT}")
    if [ -n "${ARCHIVED}" ]; then
      echo "::warning file=${MANIFEST}::${ENVIRONMENT}: archives ${KIND} missing from the manifest: ${ARCHIVED}"
    fi
    if [ -n "${RESTORED}" ]; then
      echo "::notice file=${MANIFEST}::${ENVIRONMENT}: restores archived ${KIND}: ${RESTORED}"
    fi
  done

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### ${DONE} manifest: ${PROJECT_ID} on ${ENVIRONMENT}"
      echo
      echo "${SUMMARY}"
      jq -r '
        [ (.archived.leaderboards[] | "- Archived leaderboard `\(.)`"),
          (.archived.achievements[] | "- Archived achievement `\(.)`"),
          (.restored.leaderboards[] | "- Restored leaderboard `\(.)`"),
          (.restored.achievements[] | "- Restored achievement `\(.)`") ] | .[]' <<<"${OUTPUT}"
      echo
    } >>"${GITHUB_STEP_SUMMARY}"
  fi
done

#!/bin/bash

set -eo pipefail

# Deploys need zip, jq and gcloud, which only the Linux runners all have.
# Build on any OS, upload the build as an artifact, deploy from Linux.
if [ -n "${RUNNER_OS}" ] && [ "${RUNNER_OS}" != "Linux" ]; then
  echo "This action runs on Linux runners only, not ${RUNNER_OS}."
  echo "Build on ${RUNNER_OS}, upload the build with actions/upload-artifact,"
  echo "then deploy it from an ubuntu job. See the README."
  exit 1
fi

if [ -z "${VERSION}" ]; then
  # Tag pushes check out shallow, so git describe may not see the tag
  if [ "${GITHUB_REF_TYPE}" = "tag" ] && [ -n "${GITHUB_REF_NAME}" ]; then
    echo "No version provided, using tag ${GITHUB_REF_NAME}"
    VERSION="${GITHUB_REF_NAME}"
  else
    echo "No version provided, using git describe"
    VERSION=$(git describe --tags --always)
  fi
fi

if [ -z "${PLATFORM}" ]; then
  echo "Missing env PLATFORM"
  exit 1
fi

case "${PLATFORM}" in
  WEB | WINDOWS | LINUX | MAC) ;;
  *)
    echo "Unknown platform ${PLATFORM}, use one of WEB, WINDOWS, LINUX or MAC"
    exit 1
    ;;
esac

if [ -z "${PROJECT_ID}" ]; then
  echo "Missing env PROJECT_ID"
  exit 1
fi

if [ -z "${ENTRY}" ]; then
  echo "Missing env ENTRY"
  exit 1
fi

if [ -z "${API_KEY}" ]; then
  echo "Missing env API_KEY"
  exit 1
fi

if [ -z "${BUILD_DIR}" ]; then
  echo "Missing env BUILD_DIR"
  exit 1
fi

if [ ! -d "${BUILD_DIR}" ]; then
  echo "Build dir ${BUILD_DIR} does not exist"
  exit 1
fi

BUCKET="www-adsgames-net-data-prod"
API_URL="https://www.adsgames.net"

# Each platform gets its own archive, e.g. jimfarm-v1.0.0-windows.zip
PLATFORM_NAME=$(echo "${PLATFORM}" | tr '[:upper:]' '[:lower:]')
ZIP_NAME="${PROJECT_ID}-${VERSION}-${PLATFORM_NAME}.zip"

# Builds are uploaded to a version-scoped path, so they never change and can be
# cached forever.
CACHE_CONTROL="public, max-age=31536000, immutable"

echo -e "Deploying ${PROJECT_ID} version ${VERSION} for platform ${PLATFORM}"

# Base url
URL="https://storage.googleapis.com/${BUCKET}/games/${PROJECT_ID}"

# Deploy to GCS (bucket is public via uniform bucket-level access)
if [ "${PLATFORM}" = "WEB" ]; then
  echo -e "Deploying web build"
  DEST="gs://${BUCKET}/games/${PROJECT_ID}/${VERSION}/"

  # Content types are auto-detected per file extension; cache-control is applied
  # to every object. The destination is version-scoped and always new, so a
  # plain copy is used instead of rsync to skip the destination listing.
  gcloud storage cp --recursive \
    --cache-control="${CACHE_CONTROL}" \
    "${BUILD_DIR%/}/*" "${DEST}"

  # WebAssembly must be served as application/wasm for streaming compilation;
  # gcloud's extension detection does not guarantee this.
  gcloud storage objects update --content-type="application/wasm" \
    "${DEST}**.wasm" 2>/dev/null || true

  URL="${URL}/${VERSION}/${ENTRY}"
else
  echo -e "Deploying downloadable build"

  # Zip outside the build dir so the archive does not end up inside itself
  ZIP_PATH="${RUNNER_TEMP:-/tmp}/${ZIP_NAME}"
  rm -f "${ZIP_PATH}"
  (cd "${BUILD_DIR}" && zip -r -q "${ZIP_PATH}" .)

  gcloud storage cp \
    --cache-control="${CACHE_CONTROL}" \
    --content-type="application/zip" \
    "${ZIP_PATH}" "gs://${BUCKET}/games/${PROJECT_ID}/${ZIP_NAME}"
  URL="${URL}/${ZIP_NAME}"
fi

# Build payload
DATA=$(jq -nc \
  --arg gameId "${PROJECT_ID}" \
  --arg version "${VERSION}" \
  --arg platform "${PLATFORM}" \
  --arg url "${URL}" \
  '{gameId: $gameId, version: $version, platform: $platform, url: $url}')

echo -e "Submitting release with payload: ${DATA}"

# Send payload
OUTPUT=$(
  curl -sS \
    -d "${DATA}" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    "${API_URL}/api/webhooks/release"
)

# Parse output
STATUS=$(echo "${OUTPUT}" | jq -r .status)
MESSAGE=$(echo "${OUTPUT}" | jq -r .message)

echo -e "Response: ${MESSAGE}"
echo -e "Status: ${STATUS}"

if [ "${STATUS}" != "201" ]; then
  exit 1
fi

#!/bin/bash

if [ -z "${VERSION}" ]; then
  echo "No version providing, using git tag"
  VERSION=$(git describe --tags --always)
fi

if [ -z "${PLATFORM}" ]; then
  echo "Missing env PLATFORM"
  exit 1
fi

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

BUCKET="www-adsgames-net-data-prod"
API_URL="https://www.adsgames.net"
ZIP_NAME="${PROJECT_ID}-${VERSION}.zip"

# Builds are uploaded to a version-scoped path, so they never change and can be
# cached forever.
CACHE_CONTROL="public, max-age=31536000, immutable"

echo -e "Deploying ${PROJECT_ID} version ${VERSION} for platform ${PLATFORM}"

# Base url
URL="https://storage.googleapis.com/${BUCKET}/games/${PROJECT_ID}"

# Deploy to GCS (bucket is public via uniform bucket-level access)
if [ "${PLATFORM}" = "WEB" ]
then
  echo -e "Deploying web build"
  DEST="gs://${BUCKET}/games/${PROJECT_ID}/${VERSION}/"

  # Content types are auto-detected per file extension; cache-control is applied
  # to every object.
  gcloud storage rsync --recursive \
    --cache-control="${CACHE_CONTROL}" \
    "${BUILD_DIR}" "${DEST}"

  # WebAssembly must be served as application/wasm for streaming compilation;
  # gcloud's extension detection does not guarantee this.
  gcloud storage objects update --content-type="application/wasm" \
    "${DEST}**.wasm" 2>/dev/null || true

  URL="${URL}/${VERSION}/${ENTRY}"
else
  echo -e "Deploying downloadable build"
  cd ${BUILD_DIR}
  zip -r ../${ZIP_NAME} .
  cd ../
  gcloud storage cp \
    --cache-control="${CACHE_CONTROL}" \
    --content-type="application/zip" \
    "${ZIP_NAME}" "gs://${BUCKET}/games/${PROJECT_ID}/"
  URL="${URL}/${ZIP_NAME}"
fi

# Build payload
DATA="{ \
  \"gameId\":\"${PROJECT_ID}\", \
  \"version\":\"${VERSION}\", \
  \"platform\":\"${PLATFORM}\", \
  \"url\":\"${URL}\" \
}"

echo -e "Submitting release with payload: ${DATA}"

# Send payload
OUTPUT=$(
  curl \
    -d "${DATA}" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    "${API_URL}/api/webhooks/release"
)

# Parse output
STATUS=$(echo $OUTPUT | jq -r .status)
MESSAGE=$(echo $OUTPUT | jq -r .message)

echo -e "Response: ${MESSAGE}"
echo -e "Status: ${STATUS}"

if [ "$STATUS" != "201" ]; then
  exit 1
fi

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

BUCKET="ads-games"
API_URL="https://api.adsgames.net"
REGION="us-east-1"
ZIP_NAME="${PROJECT_ID}-${VERSION}.zip"

# Base url
URL="https://${BUCKET}.${REGION}.linodeobjects.com/games/${PROJECT_ID}"

# Lookup game id
OUTPUT=$(curl "${API_URL}/games?slug=${PROJECT_ID}")

# Parse output
GAME_ID=$(echo $OUTPUT | jq -r .[0].id)

# Ensure exists
if [ -z "${GAME_ID}" ]; then
  echo "Game not found"
  exit 1
fi

# Deploy to s3
if [ "${PLATFORM}" = "WEB" ]
then
  echo -e "Deploying web build"
  s3cmd put --guess-mime-type --recursive --acl-public ${BUILD_DIR}/* s3://${BUCKET}/games/${PROJECT_ID}/${VERSION}/
  URL="${URL}/${VERSION}/${ENTRY}"
else
  echo -e "Deploying downloadable build"
  cd ${BUILD_DIR}
  zip -r ../${ZIP_NAME} .
  cd ../
  s3cmd put --guess-mime-type --acl-public ${ZIP_NAME} s3://${BUCKET}/games/${PROJECT_ID}/
  URL="${URL}/${ZIP_NAME}"
fi

# Build payload
DATA="{ \
  \"version\":\"${VERSION}\", \
  \"platform\":\"${PLATFORM}\", \
  \"url\":\"${URL}\" \
}"

# Send payload
OUTPUT=$(
  curl \
    -d "${DATA}" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    "${API_URL}/games/${GAME_ID}/hooks/release"
)

# Parse output
SUCCESS=$(echo $OUTPUT | jq -r .success)
MESSAGE=$(echo $OUTPUT | jq -r .message)

echo $MESSAGE

if [ "$SUCCESS" != "true" ]; then
  exit 1
fi
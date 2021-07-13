#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOCALPATH="${SHARED_DIR}/manifest_external.yaml"
echo "${SHA256_HASH} -" > /tmp/sum.txt
curl -fLs "${URL}" | tee "${LOCALPATH}" | sha256sum -c /tmp/sum.txt
echo "Downloaded ${URL}, sha256 checksum matches ${SHA256_HASH}"

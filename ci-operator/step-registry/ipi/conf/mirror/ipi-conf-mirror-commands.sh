#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
mkdir -p ${HOME}/.docker
cp ${CLUSTER_PROFILE_DIR}/pull-secret ${HOME}/.docker/config.json
oc registry login
# Repository to be mirrored
MIRROR_REPO=$( oc get is release -o 'jsonpath={.status.publicDockerImageRepository}' )
# server + name
MIRROR_BASE=$(dirname ${REPO_NAME})
# Tag of the mirrored release
MIRROR_TAG="mirorred"
# Imagestream created by ci-operator which holds the mirrored images
MIRROR_IMAGESTREAM="stable-${MIRROR_TAG}"

echo "MIRROR_REPO: ${MIRROR_REPO}"
echo "MIRROR_BASE: ${MIRROR_BASE}"
echo "MIRROR_TAG: ${MIRROR_TAG}"
echo "MIRROR_IMAGESTREAM: ${MIRROR_IMAGESTREAM}"

# Cleanup mirrored imagestream
oc get is ${MIRROR_IMAGESTREAM} -o 'jsonpath={.spec.tags[*].name}' | xargs -n1 -I {} oc delete istag "${MIRROR_IMAGESTREAM}:{}"

oc adm release new \
  --from-release ${RELEASE_IMAGE_LATEST} \
  --to-image ${MIRROR_BASE}/${MIRROR_IMAGESTREAM}:release \
  --mirror ${MIRROR_BASE}/${MIRROR_IMAGESTREAM} \
  || echo 'ignore: the release could not be reproduced from its inputs'
oc adm release mirror \
  --from ${MIRROR_BASE}/${MIRROR_IMAGESTREAM}:release \
  --to ${MIRROR_REPO} \
  --to-release-image ${MIRROR_BASE}:${MIRROR_TAG}
oc delete imagestream "$(basename "${MIRROR_BASE}/${MIRROR_IMAGESTREAM}")"

cat >> ${SHARED_DIR}/install-config.yaml << EOF
imageContentSources:
- source: "${MIRROR_BASE}/${MIRROR_IMAGESTREAM}"
  mirrors:
  - "${MIRROR_REPO}"
EOF

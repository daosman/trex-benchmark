#!/bin/bash

VERSION="${1:-3.02}"

REGISTRY='quay.io/dosman'
PULL_SECRET="${HOME}/.docker/config.json"
IMAGE='trex'

TAG=${VERSION}
podman build -f Dockerfile --no-cache . \
  --build-arg TREX_VERSION=${VERSION} \
  --authfile=${PULL_SECRET} \
  -t ${REGISTRY}/${IMAGE}:${TAG}

podman push --authfile=${PULL_SECRET} ${REGISTRY}/${IMAGE}:${TAG}

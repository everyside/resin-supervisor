#!/bin/bash
set -e

# Jenkins build steps
VERSION=$(git describe --always --abbrev=6)
ESCAPED_BRANCH_NAME=$(echo $sourceBranch | sed 's/[^a-z0-9A-Z_.-]/-/g')

# Try pulling the old build first for caching purposes.
docker pull resin/${ARCH}-supervisor:${ESCAPED_BRANCH_NAME} || docker pull resin/${ARCH}-supervisor:master || true

# Test the gosuper
make SUPERVISOR_VERSION=${VERSION} JOB_NAME=${JOB_NAME} test-gosuper

# Build the images
make SUPERVISOR_VERSION=${ESCAPED_BRANCH_NAME} \
	ARCH=${ARCH} \
	JOB_NAME=${JOB_NAME} \
	DEPLOY_REGISTRY= \
	PUBNUB_SUBSCRIBE_KEY=${PUBNUB_SUBSCRIBE_KEY} \
	PUBNUB_PUBLISH_KEY=${PUBNUB_PUBLISH_KEY} \
	MIXPANEL_TOKEN=${MIXPANEL_TOKEN} \
	deploy
make SUPERVISOR_VERSION=${VERSION} \
	ARCH=${ARCH} \
	JOB_NAME=${JOB_NAME} \
	DEPLOY_REGISTRY= \
	PUBNUB_SUBSCRIBE_KEY=${PUBNUB_SUBSCRIBE_KEY} \
	PUBNUB_PUBLISH_KEY=${PUBNUB_PUBLISH_KEY} \
	MIXPANEL_TOKEN=${MIXPANEL_TOKEN} \
	deploy

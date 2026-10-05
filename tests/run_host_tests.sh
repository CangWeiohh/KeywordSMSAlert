#!/bin/sh
#
# Compiles the platform independent KeywordSMSAlert logic for macOS and runs the
# unit tests. Use this before shipping: it validates configuration parsing, keyword
# matching (including Chinese text) and the de-duplication window without a device.
#
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(dirname "$HERE")"

cd "$PROJECT"
mkdir -p .theos/host-tests

clang -fobjc-arc -fblocks -g -O1 \
    -DTHEOS_PACKAGE_SCHEME_ROOTHIDE=1 \
    -I"$HERE/shim" -I"$PROJECT/Sources" \
    -framework Foundation \
    "$HERE/host_tests.m" \
    Sources/KSAConfig.m Sources/KSACommon.m Sources/KSADedupCache.m Sources/KSALog.m \
    -o .theos/host-tests/host_tests

exec .theos/host-tests/host_tests

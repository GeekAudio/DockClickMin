#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/dockclickmin-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc WindowPolicy.swift tests/main.swift -o "$TEST_DIR/window-policy-tests"
"$TEST_DIR/window-policy-tests"

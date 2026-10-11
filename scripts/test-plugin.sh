#!/usr/bin/env bash
# Tests the plugin's logic that doesn't need PackagePlugin (the vercel.json edits and .swift-version
# of `swift package vercel init`, and the toolchain check): compiles those files of
# Plugins/VercelPlugin with the tests in scripts/plugin-tests and runs them.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
# Every plugin source that doesn't import PackagePlugin.
SOURCES=()
for file in Plugins/VercelPlugin/*.swift; do
  grep -q '^import PackagePlugin' "$file" || SOURCES+=("$file")
done
swiftc "${SOURCES[@]}" scripts/plugin-tests/*.swift -o "$BUILD/plugin-tests"
"$BUILD/plugin-tests"

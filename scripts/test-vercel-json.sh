#!/usr/bin/env bash
# Tests the vercel.json edits of `swift package vercel init`: compiles
# Plugins/VercelPlugin/VercelJSON.swift with scripts/vercel-json-tests.swift and runs them.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
# Top-level code must be in a file named main.swift.
cp scripts/vercel-json-tests.swift "$BUILD/main.swift"
swiftc Plugins/VercelPlugin/VercelJSON.swift "$BUILD/main.swift" -o "$BUILD/vercel-json-tests"
"$BUILD/vercel-json-tests"

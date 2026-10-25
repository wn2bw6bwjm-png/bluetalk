#!/usr/bin/env bash
# Runs analyzers and tests for the pure-Dart packages (no Flutter needed).
set -euo pipefail
cd "$(dirname "$0")/.."
for p in mesh_core mesh_engine; do
  echo "=== $p"
  (cd packages/$p && dart pub get >/dev/null && dart analyze && dart test)
done

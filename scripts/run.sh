#!/usr/bin/env bash
# Builds a debug app bundle and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x Commonplace 2>/dev/null || true
scripts/build-app.sh debug
open build/Commonplace.app

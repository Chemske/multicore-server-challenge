#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
args=()
if [ -n "${PGROOT:-}" ]; then args+=("-Dpg-root=$PGROOT"); fi
zig build -Doptimize=ReleaseSafe "${args[@]}"

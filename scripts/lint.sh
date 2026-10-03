#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in ruff swiftlint; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing %s. Install the linters with: brew install ruff swiftlint\n' "$tool" >&2
        exit 1
    fi
done
ruff check .
ruff format --check .
swiftlint lint --strict

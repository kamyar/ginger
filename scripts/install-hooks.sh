#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v ozm >/dev/null 2>&1; then
    git_directory="$(ozm git --agent-name "install-hooks" --agent-description "Find the repository hook directory" rev-parse --absolute-git-dir)"
else
    git_directory="$(git rev-parse --absolute-git-dir)"
fi
source_hook="$PWD/.githooks/pre-commit"
target_hook="$git_directory/hooks/pre-commit"
mkdir -p "$git_directory/hooks"
if [[ -e "$target_hook" || -L "$target_hook" ]]; then
    if [[ ! -L "$target_hook" ]] && cmp -s "$source_hook" "$target_hook"; then
        chmod +x "$target_hook"
        printf 'The pre-commit hook is already installed.\n'
        exit 0
    fi
    printf 'An existing pre-commit hook was not replaced: %s\n' "$target_hook" >&2
    printf 'Add ./scripts/lint.sh to that hook, or merge the hooks manually.\n' >&2
    exit 1
fi
cp "$source_hook" "$target_hook"
chmod +x "$target_hook"
printf 'Installed the repository pre-commit hook. Global Git hook settings were not changed.\n'

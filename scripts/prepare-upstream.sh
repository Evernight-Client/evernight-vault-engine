#!/usr/bin/env bash
# Fetches the pinned upstream cubiomes checkout and applies our loot patches.
#
#   bash scripts/prepare-upstream.sh [--force]
#
# Result: build/cubiomes (pristine upstream at upstream.conf's commit + patches applied).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/upstream.conf"

WORK="$ROOT/build/cubiomes"
FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

if [ "$FORCE" -eq 1 ]; then
    rm -rf "$WORK"
fi

if [ ! -d "$WORK/.git" ]; then
    echo "fetching cubiomes $UPSTREAM_COMMIT"
    rm -rf "$WORK"
    mkdir -p "$(dirname "$WORK")"
    git init -q "$WORK"
    git -C "$WORK" remote add origin "$UPSTREAM_REPO"
    git -C "$WORK" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
    git -C "$WORK" checkout -q FETCH_HEAD
else
    if [ "$(git -C "$WORK" rev-parse HEAD)" != "$UPSTREAM_COMMIT" ]; then
        echo "build/cubiomes is on the wrong commit, re-fetching"
        rm -rf "$WORK"
        exec "$0" --force
    fi
fi

for patch in "$ROOT"/patches/*.patch "$ROOT"/patches/*.diff; do
    [ -e "$patch" ] || continue
    if git -C "$WORK" apply --check -p"$PATCH_STRIP" --reverse "$patch" >/dev/null 2>&1; then
        echo "already applied: $(basename "$patch")"
        continue
    fi
    echo "applying: $(basename "$patch")"
    git -C "$WORK" apply -p"$PATCH_STRIP" "$patch"
done

echo "upstream ready: $WORK"

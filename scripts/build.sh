#!/usr/bin/env bash
# Builds the vault loot engine for one target platform.
#
#   bash scripts/build.sh [target] [outdir]
#
# target: auto (default) | linux-x86_64 | linux-aarch64 | windows-x86_64 |
#         macos-universal
# Output: <outdir>/vaulttool-<target>[.exe]
#
# The loot core is a pristine checkout of upstream cubiomes at the pinned commit with
# patches/ applied (see upstream.conf and scripts/prepare-upstream.sh).
#
# Android is intentionally not a target: newer Android versions refuse to execute binaries
# extracted into app-writable storage, so Evernight hides the prediction module there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-auto}"
OUTDIR="${2:-$ROOT/dist}"
CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2}"
EXTRA=()
EXT=""

host_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) uname -m ;;
    esac
}

if [ "$TARGET" = "auto" ]; then
    case "$(uname -s)" in
        Linux) TARGET="linux-$(host_arch)" ;;
        Darwin) TARGET="macos-universal" ;;
        MINGW* | MSYS* | CYGWIN*) TARGET="windows-x86_64" ;;
        *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
    esac
fi

case "$TARGET" in
    linux-x86_64)
        ;;
    linux-aarch64)
        CC="${CC:-aarch64-linux-gnu-gcc}"
        ;;
    windows-x86_64)
        CC="${CC:-x86_64-w64-mingw32-gcc}"
        EXT=".exe"
        EXTRA+=(-static -static-libgcc)
        ;;
    macos-universal)
        EXTRA+=(-arch arm64 -arch x86_64)
        ;;
    *)
        echo "unknown target: $TARGET" >&2
        exit 1
        ;;
esac

if [ "${VAULT_UPSTREAM_READY:-0}" != "1" ]; then
    bash "$ROOT/scripts/prepare-upstream.sh"
fi

CUBIOMES="$ROOT/build/cubiomes"
if [ ! -d "$CUBIOMES/loot" ]; then
    echo "upstream checkout missing at $CUBIOMES (run scripts/prepare-upstream.sh)" >&2
    exit 1
fi

TRIAL="$CUBIOMES/loot/loot_tables/chests/trial_chambers"
SOURCES=(
    "$ROOT/src/vaulttool.c"
    "$CUBIOMES/loot/loot_table_context.c"
    "$CUBIOMES/loot/loot_functions.c"
    "$CUBIOMES/loot/loot_table_parser.c"
    "$CUBIOMES/loot/items.c"
    "$CUBIOMES/loot/cjson/cJSON.c"
    "$TRIAL/reward_1_21_1.c"
    "$TRIAL/reward_common_1_21_1.c"
    "$TRIAL/reward_rare_1_21_1.c"
    "$TRIAL/reward_unique_1_21_1.c"
    "$TRIAL/reward_ominous_1_21_1.c"
    "$TRIAL/reward_ominous_common_1_21_1.c"
    "$TRIAL/reward_ominous_rare_1_21_1.c"
    "$TRIAL/reward_ominous_unique_1_21_1.c"
)

mkdir -p "$OUTDIR"
OUTPUT="$OUTDIR/vaulttool-$TARGET$EXT"
echo "building $TARGET with $CC"
"$CC" $CFLAGS "${EXTRA[@]}" -std=c11 -fwrapv \
    -I "$CUBIOMES" \
    -I "$CUBIOMES/loot" \
    -I "$CUBIOMES/loot/cjson" \
    "${SOURCES[@]}" \
    -o "$OUTPUT" -lm
echo "built: $OUTPUT"

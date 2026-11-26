#!/usr/bin/env bash
# Builds the vault loot engine for one target platform.
#
#   bash scripts/build.sh [target] [outdir]
#
# target: auto (default) | linux-x86_64 | linux-aarch64 | android-aarch64 |
#         windows-x86_64 | windows-aarch64 | macos-universal
# Output: <outdir>/vaulttool-<target>[.exe]
#
# The loot core is a pristine checkout of upstream cubiomes at the pinned commit with
# patches/ applied (see upstream.conf and scripts/prepare-upstream.sh).
#
# android-aarch64 is linked statically against the Android NDK and windows-aarch64 is a PE
# ARM64 build (llvm-mingw); both need their toolchain available, see the README. Statically
# linked means the binary depends on neither bionic's dynamic loader nor a device libc, but
# Android still only permits exec() from app storage for launchers that target API <= 28 —
# Evernight probes that at runtime and hides the module when execution is refused.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-auto}"
OUTDIR="${2:-$ROOT/dist}"
# VAULT_CC is the explicit compiler override. Ambient CC is deliberately ignored: CI images
# export CC=cc, which would silently build a host ELF for a cross target.
CC="${VAULT_CC:-cc}"
CFLAGS="${CFLAGS:--O2}"
EXTRA=()
EXT=""
EXPECT_MAGIC="elf"
# Machine check: catches a toolchain that builds the host or the wrong architecture, which the
# magic check alone cannot see (a host x86_64 ELF named *-aarch64 has the right magic).
EXPECT_MACHINE=""

host_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x86_64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) uname -m ;;
    esac
}

# NDK host directory for this build host, falling back to whatever prebuilt/ ships.
ndk_prebuilt() {
    local want=""
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) want=windows-x86_64 ;;
        Darwin) want=darwin-x86_64 ;;
        *) want=linux-x86_64 ;;
    esac
    if [ -d "$1/toolchains/llvm/prebuilt/$want" ]; then
        echo "$1/toolchains/llvm/prebuilt/$want"
        return 0
    fi
    ls -d "$1"/toolchains/llvm/prebuilt/* 2>/dev/null | head -n 1
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
        EXPECT_MACHINE="3e"
        ;;
    linux-aarch64)
        CC="${VAULT_CC:-aarch64-linux-gnu-gcc}"
        EXPECT_MACHINE="b7"
        ;;
    android-aarch64)
        NDK="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
        if [ -z "$NDK" ] || [ ! -d "$NDK/toolchains/llvm" ]; then
            echo "android-aarch64 needs the Android NDK; set ANDROID_NDK_ROOT to the NDK root" >&2
            exit 1
        fi
        PREBUILT="$(ndk_prebuilt "$NDK")"
        if [ -z "$PREBUILT" ] || [ ! -d "$PREBUILT/bin" ]; then
            echo "no NDK prebuilt toolchain under $NDK/toolchains/llvm/prebuilt" >&2
            exit 1
        fi
        API_CC="aarch64-linux-android${ANDROID_API:-21}-clang"
        # Windows hosts ship the wrappers as .cmd; MSYS and Git Bash need the extension to run one.
        if [ ! -x "$PREBUILT/bin/$API_CC" ] && [ -x "$PREBUILT/bin/$API_CC.cmd" ]; then
            API_CC="$API_CC.cmd"
        fi
        CC="${VAULT_CC:-$PREBUILT/bin/$API_CC}"
        EXPECT_MACHINE="b7"
        # Static, so nothing on the device has to provide a libc or a dynamic loader; the page size
        # override keeps the segments loadable on 16 KiB page kernels (Android 15+).
        EXTRA+=(-static -Wl,-z,max-page-size=16384)
        ;;
    windows-x86_64)
        CC="${VAULT_CC:-x86_64-w64-mingw32-gcc}"
        EXT=".exe"
        EXPECT_MAGIC="pe"
        EXPECT_MACHINE="8664"
        EXTRA+=(-static -static-libgcc)
        ;;
    windows-aarch64)
        # llvm-mingw cross-builds the PE ARM64 from an x86_64 host; MSVC and the MinGW gcc
        # packages only target x86_64.
        CC="${VAULT_CC:-aarch64-w64-mingw32-clang}"
        EXT=".exe"
        EXPECT_MAGIC="pe"
        EXPECT_MACHINE="aa64"
        EXTRA+=(-static)
        ;;
    macos-universal)
        EXPECT_MAGIC="macho"
        EXTRA+=(-arch arm64 -arch x86_64)
        ;;
    *)
        echo "unknown target: $TARGET" >&2
        exit 1
        ;;
esac

# Refuse to publish a binary that does not match the target format (a wrong CC would
# otherwise produce a host ELF named *.exe, which Windows rejects).
verify_magic() {
    local file="$1"
    local magic
    magic="$(od -An -tx1 -N4 "$file" | tr -d ' \n')"
    case "$EXPECT_MAGIC" in
        elf) case "$magic" in 7f454c46*) return 0 ;; esac ;;
        pe) case "$magic" in 4d5a*) return 0 ;; esac ;;
        macho) case "$magic" in cffaedfe | feedfacf | cafebabe | bebafeca) return 0 ;; esac ;;
    esac
    echo "built binary has the wrong format for $TARGET (magic $magic)" >&2
    exit 1
}

# e_machine (ELF) or the COFF machine (PE), so a cross build that silently produced the host
# architecture is rejected instead of shipped.
verify_machine() {
    local file="$1"
    local machine=""
    case "$EXPECT_MAGIC" in
        elf) machine="$(od -An -tx2 -j18 -N2 "$file" | tr -d ' \n')" ;;
        pe)
            local lfanew
            lfanew="$(od -An -tu4 -j60 -N4 "$file" | tr -d ' ')"
            machine="$(od -An -tx2 -j$((lfanew + 4)) -N2 "$file" | tr -d ' \n')"
            ;;
        *) return 0 ;;
    esac
    # od pads the word to four digits ("00b7"); compare without leading zeros.
    if [ -n "$machine" ]; then
        machine="$(printf '%x' "$((16#$machine))")"
    fi
    if [ "$machine" != "$EXPECT_MACHINE" ]; then
        echo "built binary has machine ${machine:-unknown}, expected $EXPECT_MACHINE for $TARGET" >&2
        exit 1
    fi
}

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
verify_magic "$OUTPUT"
if [ -n "$EXPECT_MACHINE" ]; then
    verify_machine "$OUTPUT"
fi
echo "built: $OUTPUT"

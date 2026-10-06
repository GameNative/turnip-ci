#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MESA_REPO="${MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_REF="${MESA_REF:-main}"
PATCHES="${PATCHES:-}"
VARIANT_NAME="${VARIANT_NAME:-turnip-ci}"
NDK_VERSION="${NDK_VERSION:-r28c}"
PACKAGE_VERSION="${PACKAGE_VERSION:-1}"
SDK_VERSION="${SDK_VERSION:-36}"
WORKDIR="${WORKDIR:-$REPO_ROOT/work}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"

log() { printf '\033[0;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) NDK_OS=linux; NDK_HOST_TAG=linux-x86_64; BUILD_SYSTEM=linux ;;
    Darwin) NDK_OS=darwin; NDK_HOST_TAG=darwin-x86_64; BUILD_SYSTEM=darwin ;;
    *) die "Unsupported host: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) BUILD_CPU=x86_64 ;;
    arm64|aarch64) BUILD_CPU=aarch64 ;;
    *) die "Unsupported host CPU: $(uname -m)" ;;
esac

check_deps() {
    local dep
    for dep in git curl unzip zip meson ninja python3 flex bison glslangValidator pkg-config; do
        command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep"
    done
    python3 -c 'import mako, yaml, packaging' 2>/dev/null || die "Missing Python modules: pip install mako pyyaml packaging"
}

prepare_ndk() {
    NDK_DIR="$WORKDIR/android-ndk-$NDK_VERSION"
    if [ ! -d "$NDK_DIR" ]; then
        local zip="$WORKDIR/android-ndk-$NDK_VERSION-$NDK_OS.zip"
        log "Downloading NDK $NDK_VERSION"
        curl -fL --retry 3 -o "$zip" "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-$NDK_OS.zip"
        unzip -q "$zip" -d "$WORKDIR"
        rm -f "$zip"
        if [ "$NDK_OS" = darwin ] && [ ! -d "$NDK_DIR" ]; then
            local app
            app="$(find "$WORKDIR" -maxdepth 1 -name 'AndroidNDK*.app' | head -n1)"
            [ -n "$app" ] && mv "$app/Contents/NDK" "$NDK_DIR" && rm -rf "$app"
        fi
    fi
    [ -d "$NDK_DIR" ] || die "NDK not found at $NDK_DIR"
    NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/$NDK_HOST_TAG/bin"
    NDK_MAJOR="$(sed -n 's/^Pkg.Revision *= *\([0-9]*\).*/\1/p' "$NDK_DIR/source.properties")"
    log "NDK $NDK_VERSION (major $NDK_MAJOR)"
}

fetch_mesa() {
    MESA_DIR="$WORKDIR/mesa"
    rm -rf "$MESA_DIR"
    git init -q "$MESA_DIR"
    git -C "$MESA_DIR" remote add origin "$MESA_REPO"
    log "Fetching $MESA_REPO @ $MESA_REF"
    git -C "$MESA_DIR" fetch -q --depth=1 origin "$MESA_REF"
    git -C "$MESA_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
    MESA_COMMIT="$(git -C "$MESA_DIR" rev-parse --short=10 HEAD)"
    MESA_VERSION="$(tr -d '[:space:]' < "$MESA_DIR/VERSION")"
    log "Mesa $MESA_VERSION ($MESA_COMMIT)"
}

apply_patches() {
    local dir="$WORKDIR/patches"
    rm -rf "$dir"
    mkdir -p "$dir"
    local n=0 line file
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        n=$((n + 1))
        file="$dir/$(printf '%03d' "$n").patch"
        case "$line" in
            http://*|https://*)
                curl -fsSL --retry 3 -o "$file" "$line" || die "Failed to download patch: $line"
                ;;
            *)
                local src="$REPO_ROOT/$line"
                [ -f "$src" ] || src="$REPO_ROOT/patches/$line"
                [ -f "$src" ] || die "Patch not found: $line"
                case "$(cd "$(dirname "$src")" && pwd)/" in
                    "$REPO_ROOT/patches/"*) ;;
                    *) die "Local patches must live under patches/: $line" ;;
                esac
                cp "$src" "$file"
                ;;
        esac
        log "Applying patch $n: $line"
        if ! git -C "$MESA_DIR" apply --check --verbose "$file"; then
            die "Patch does not apply: $line"
        fi
        git -C "$MESA_DIR" apply "$file"
    done <<< "$PATCHES"
    PATCH_COUNT=$n
}

apply_ndk_fixes() {
    [ "${NDK_MAJOR:-0}" -ge 29 ] || return 0
    log "Applying NDK r29+ buffer_handle_t fixes"
    cd "$MESA_DIR"
    perl -pi -e 's/typedef const native_handle_t\* buffer_handle_t;/typedef void* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h
    perl -pi -e 's/, hnd->handle/, (void *)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c
    perl -pi -e 's/([a-z_]+)->handle->/((const native_handle_t *)$1->handle)->/g' src/vulkan/runtime/vk_android.c
    perl -ni -e 'print unless /-Werror=gnu-empty-initializer/' meson.build
    cd - >/dev/null
}

write_cross_files() {
    local api
    for api in "$SDK_VERSION" 36 35 34; do
        [ -x "$NDK_BIN/aarch64-linux-android${api}-clang" ] && break
    done
    [ -x "$NDK_BIN/aarch64-linux-android${api}-clang" ] || die "No aarch64-linux-android{34..36}-clang in $NDK_BIN"
    log "Using aarch64-linux-android${api}-clang"

    cat > "$WORKDIR/android-aarch64.txt" <<CROSS
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['$NDK_BIN/aarch64-linux-android${api}-clang']
cpp = ['$NDK_BIN/aarch64-linux-android${api}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$NDK_BIN/ld.lld'
cpp_ld = '$NDK_BIN/ld.lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$NDK_BIN/pkg-config', '$(command -v pkg-config)']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
CROSS

    cat > "$WORKDIR/native.txt" <<NATIVE
[binaries]
c = ['cc']
cpp = ['c++']

[build_machine]
system = '$BUILD_SYSTEM'
cpu_family = '$BUILD_CPU'
cpu = '$BUILD_CPU'
endian = 'little'
NATIVE
}

build_mesa() {
    INSTALL_DIR="$WORKDIR/install"
    rm -rf "$MESA_DIR/build" "$INSTALL_DIR"
    cd "$MESA_DIR"
    meson setup build \
        --cross-file "$WORKDIR/android-aarch64.txt" \
        --native-file "$WORKDIR/native.txt" \
        --prefix "$INSTALL_DIR" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=android \
        -Dplatform-sdk-version="$SDK_VERSION" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvideo-codecs= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled
    ninja -C build
    ninja -C build install
    cd - >/dev/null
    LIB="$INSTALL_DIR/lib/libvulkan_freedreno.so"
    [ -f "$LIB" ] || die "libvulkan_freedreno.so was not produced"
}

package_zip() {
    local stage="$WORKDIR/package"
    rm -rf "$stage"
    mkdir -p "$stage" "$OUT_DIR"
    cp "$LIB" "$stage/"
    META_NAME="$VARIANT_NAME" \
    META_DESC="Turnip from $MESA_REPO @ $MESA_REF ($MESA_COMMIT), $PATCH_COUNT patch(es), NDK $NDK_VERSION" \
    META_PKG="$PACKAGE_VERSION" \
    META_DRV="Mesa $MESA_VERSION-$MESA_COMMIT" \
    python3 - "$stage/meta.json" <<'PY'
import json, os, sys
meta = {
    "schemaVersion": 1,
    "name": os.environ["META_NAME"],
    "description": os.environ["META_DESC"],
    "author": "GameNative turnip-ci",
    "packageVersion": os.environ["META_PKG"],
    "vendor": "Mesa",
    "driverVersion": os.environ["META_DRV"],
    "minApi": 27,
    "libraryName": "libvulkan_freedreno.so",
}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY
    ZIP_NAME="${VARIANT_NAME}-${MESA_VERSION}-${MESA_COMMIT}.zip"
    rm -f "$OUT_DIR/$ZIP_NAME"
    (cd "$stage" && zip -9 -q "$OUT_DIR/$ZIP_NAME" libvulkan_freedreno.so meta.json)
    log "Built $OUT_DIR/$ZIP_NAME"
    cat "$stage/meta.json"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            echo "zip_path=$OUT_DIR/$ZIP_NAME"
            echo "zip_name=$ZIP_NAME"
            echo "mesa_version=$MESA_VERSION"
            echo "mesa_commit=$MESA_COMMIT"
        } >> "$GITHUB_OUTPUT"
    fi
}

main() {
    mkdir -p "$WORKDIR"
    WORKDIR="$(cd "$WORKDIR" && pwd)"
    mkdir -p "$OUT_DIR"
    OUT_DIR="$(cd "$OUT_DIR" && pwd)"
    check_deps
    prepare_ndk
    fetch_mesa
    apply_patches
    apply_ndk_fixes
    write_cross_files
    build_mesa
    package_zip
}

main "$@"

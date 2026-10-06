# turnip-ci

CI builds of Turnip (Mesa's freedreno Vulkan driver) for Android. Each build makes an AdrenoTools zip that GameNative can import.

The workflow `.github/workflows/build.yml` is a thin wrapper around `build.sh`. The steps are:

1. Download the Android NDK (default `r28c`).
2. Shallow-clone Mesa at the ref you give.
3. Apply your patches in order with `git apply`. The build stops if a patch does not apply.
4. Cross-compile with `aarch64-linux-android36-clang` (35 or 34 if 36 is not in the NDK), `ld.lld` and a static libstdc++.
5. Run `meson setup` with the community Turnip options (`-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dplatforms=android -Dandroid-stub=true -Dplatform-sdk-version=36 ...`), then `ninja`.
6. Zip `libvulkan_freedreno.so` with a `meta.json`. The `driverVersion` field is `Mesa <VERSION>-<short commit>`.

The zip is uploaded as a workflow artifact. When you push a `v*` tag, the zip is also attached to a GitHub release.

## Starting a build

You can use the Actions tab ("Build Turnip" > "Run workflow") or the `gh` CLI.

Upstream Mesa `main`, with no patches:

```sh
gh workflow run build.yml -R GameNative/turnip-ci
```

whitebelyash's A8xx branch (`turnip/gen8` in `mesa-unified`):

```sh
gh workflow run build.yml -R GameNative/turnip-ci \
  -f mesa_repo=https://github.com/whitebelyash/mesa-unified.git \
  -f mesa_ref=turnip/gen8 \
  -f variant_name=turnip-gen8
```

Upstream `main` with patches. List one patch per line. Each line is a URL or a file under `patches/`:

```sh
gh workflow run build.yml -R GameNative/turnip-ci \
  -f variant_name=turnip-patched \
  -f patches="$(printf '%s\n' \
    https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/12345.patch \
    patches/my-fix.patch)"
```

Other inputs: `mesa_ref` takes a branch, a tag or a full commit SHA. `ndk` takes an NDK release name, for example `r28c` or `r29`. With NDK r29 or later, `build.sh` also applies the `buffer_handle_t` header fixes that the community scripts use.

To follow a run and get the zip:

```sh
gh run watch -R GameNative/turnip-ci
gh run download -R GameNative/turnip-ci <run-id>
```

A build from Mesa `main` takes approximately 15 to 25 minutes.

### Releases

When you push a `v*` tag, the workflow builds with the default inputs and attaches the zip to a release with the same name:

```sh
git tag v2026.10.06 && git push origin v2026.10.06
```

## Adding a patch

Refer to [patches/README.md](patches/README.md). In summary, put `foo.patch` (made against the Mesa root) in `patches/`, commit it, and give `patches/foo.patch` in the `patches` input. You can also give the URL of a raw patch and not commit it.

## Building locally

`build.sh` runs on Linux (x86_64) and macOS. It uses the same environment variables as the workflow inputs:

```sh
MESA_REF=main PATCHES="" VARIANT_NAME=turnip-local NDK_VERSION=r28c ./build.sh
```

You must have `git curl unzip zip meson ninja python3 flex bison glslangValidator pkg-config` and the Python modules `mako pyyaml packaging`. On Ubuntu:

```sh
sudo apt-get install ninja-build flex bison glslang-tools pkg-config zip unzip
pip install --user meson mako pyyaml packaging
```

The script keeps the NDK and the Mesa checkout in `work/` and writes the zip to `out/`. You can change these with `WORKDIR` and `OUT_DIR`.

## Importing into GameNative

1. Copy the zip to the device. Do not extract it. GameNative reads `meta.json` and `libvulkan_freedreno.so` from the zip.
2. In GameNative, go to **Settings > Emulation > Driver Manager** and tap **Import ZIP from device**. Then select the zip.
3. The driver shows with the `variant_name` you gave in the build. Select it in the game's or container's graphics driver settings.

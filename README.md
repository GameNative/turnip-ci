# turnip-ci

CI builds of Turnip (Mesa's freedreno Vulkan driver) for Android. Each build makes an AdrenoTools zip that GameNative can import.

The workflow `.github/workflows/build.yml` is a thin wrapper around `build.sh`. The steps are:

1. Download the Android NDK (default `r28c`).
2. Shallow-clone Mesa at the ref you give.
3. Apply your patches in order with `git apply`. The build stops if a patch does not apply.
4. Cross-compile with `aarch64-linux-android36-clang` (35 or 34 if 36 is not in the NDK), `ld.lld` and a static libstdc++.
5. Run `meson setup` with the community Turnip options (`-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dplatforms=android -Dandroid-stub=true -Dplatform-sdk-version=36 ...`), then `ninja`.
6. Zip `libvulkan_freedreno.so` with a `meta.json`. The `driverVersion` field is `Mesa <VERSION>-<short commit>`.

The zip is uploaded as a workflow artifact. When you push a `v*` tag, `.github/workflows/release.yml` runs the same build and attaches the zip to a GitHub release.

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

When you push a `v*` tag, `release.yml` builds upstream `main` with the default inputs and attaches the zip to a release with the same name:

```sh
git tag v2026.10.06 && git push origin v2026.10.06
```

## Calling from another repository

`build.yml` is also a reusable workflow (`workflow_call`). It takes the same inputs and these extra inputs:

- `use_checkout` (boolean): build the caller's commit (the same checkout that `actions/checkout` gives) and do not clone `mesa_repo`/`mesa_ref`. The patches in `patches` are applied on top of that tree.
- `artifact_name`: the name of the uploaded artifact. The default is the zip file name.
- `turnip_ci_ref`: the turnip-ci ref whose `build.sh` is used. The default is `main`.

It also takes an optional secret, `turnip_ci_token`. The outputs are `zip_name`, `artifact_name`, `mesa_version` and `mesa_commit`.

```yaml
jobs:
  turnip:
    uses: GameNative/turnip-ci/.github/workflows/build.yml@main
    with:
      use_checkout: true
      variant_name: turnip-pr-${{ github.event.pull_request.number }}
      artifact_name: turnip-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}
```

turnip-ci is private. Before other repositories can call it, you must do the two steps that follow:

1. Set **Settings > Actions > General > Access** in turnip-ci to "Accessible from repositories in the GameNative organization". The calling repository must be private or internal, because GitHub does not let public repositories call workflows in a private repository.
2. If the caller's `GITHUB_TOKEN` cannot read turnip-ci, give a token that can read it as `secrets.turnip_ci_token`.

## Adding a patch

Refer to [patches/README.md](patches/README.md). In summary, put `foo.patch` (made against the Mesa root) in `patches/`, commit it, and give `patches/foo.patch` in the `patches` input. You can also give the URL of a raw patch and not commit it.

## Building locally

`build.sh` runs on Linux (x86_64). It is also written for macOS, but it has not been tested there. It uses the same environment variables as the workflow inputs:

```sh
MESA_REF=main PATCHES="" VARIANT_NAME=turnip-local NDK_VERSION=r28c ./build.sh
```

You must have `git curl unzip zip meson ninja python3 flex bison glslangValidator pkg-config` and the Python modules `mako pyyaml packaging`. On Ubuntu:

```sh
sudo apt-get install ninja-build flex bison glslang-tools pkg-config zip unzip
pip install --user meson mako pyyaml packaging
```

The script keeps the NDK and the Mesa checkout in `work/` and writes the zip to `out/`. You can change these with `WORKDIR` and `OUT_DIR`. To build a Mesa tree that you already have, set `MESA_SRC=/path/to/mesa`. The script then does not clone, and it applies `PATCHES` directly to that tree.

## Importing into GameNative

1. Copy the zip to the device. Do not extract it. GameNative reads `meta.json` and `libvulkan_freedreno.so` from the zip.
2. In GameNative, go to **Settings > Emulation > Driver Manager** and tap **Import ZIP from device**. Then select the zip.
3. The driver shows with the `variant_name` you gave in the build. Select it in the game's or container's graphics driver settings.

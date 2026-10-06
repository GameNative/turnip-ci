# Patches

Patches are applied to the Mesa checkout in the order you list them, with `git apply`. If a patch does not apply cleanly, the build stops with an error. Partial applies and `.rej` files are not allowed.

## Listing patches

The `patches` workflow input (or the `PATCHES` environment variable for `build.sh`) takes one entry per line:

- An `http://` or `https://` URL to a raw patch. Examples are a GitLab merge request (`https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/12345.patch`) or a GitHub commit (`https://github.com/<owner>/<repo>/commit/<sha>.patch`).
- A file in this directory. You can write it as `patches/foo.patch` or `foo.patch`. Paths outside `patches/` are refused.

Blank lines and lines that start with `#` are ignored.

## Adding a patch to the repo

1. Make the patch against the Mesa ref you build, for example with `git format-patch -1 <sha>` or `git diff > foo.patch`. Paths must be relative to the Mesa root.
2. Put it in this directory and commit it.
3. Add `patches/foo.patch` to the `patches` input when you start the workflow.

Patches you keep here must still match the Mesa ref you build. Pin `mesa_ref` to a commit if a patch must keep applying.

# Building the klee Ubuntu Touch images on GitHub Actions

This directory contains a GitHub Actions workflow that builds the three images
the klee installer needs **without a Linux machine**:

| Artifact | Image | Purpose |
| --- | --- | --- |
| `klee-boot-images` | `ut_boot.img` | Ubuntu Touch kernel (GKI android15-6.6-halium) |
| `klee-boot-images` | `ut_init_boot.img` | Halium initramfs + klee ramdisk overlay |
| `klee-boot-images` | `ut_boot_fastboot-boot.img` | One-off `fastboot boot` test image |
| `klee-rootfs` | `ubuntu.img` | UT 24.04-1.x rootfs (EROFS) + klee overlay + modules |
| `klee-modules` | modules tree | only needed if you rebuild the rootfs separately |

## How to run it

1. Push this workflow to your fork (branch `main`).
2. On GitHub: **Actions** → **Build klee Ubuntu Touch images** → **Run workflow**.
   - `build_rootfs`: leave `true` for a complete build. Set `false` if you only
     want the kernel + boot images (much faster).
   - `kernel_jobs`: parallelism for `make`. `4` is right for GitHub's standard
     runners; do not raise it, the runner has only ~16 GB RAM.
3. When the run finishes, download the artifacts from the run's summary page.
4. Put them in `release/images/` of the repo (or wherever your installer expects them):

```
release/images/ut_boot.img
release/images/ut_init_boot.img
release/images/ubuntu.img
release/images/ut_boot_fastboot-boot.img   (optional, for fastboot boot)
```

## Why the workflow looks the way it does

These are the non-obvious constraints, each one learned the hard way:

- **`container: ubuntu:22.04`** – the port's scripts call `python2`
  (`make-bootimage.sh` → `mkdtboimg.py`), and Ubuntu 22.04 is the last release
  that ships `python2` and `libtinfo5`. GitHub's `ubuntu-22.04` *runner image*
  itself no longer has them, so everything runs in a container. This is exactly
  what the upstream GitLab CI (`port/build/gsi-port-ci.yml`) does.

- **AOSP clang r510928** – `deviceinfo` sets Halium 16, so
  `setup_repositories.sh` would clone branch `main-kernel-build-2024`, whose
  clang is `r510928` (the same compiler as the stock kernel). The workflow
  clones that branch itself and keeps only `clang-r510928/bin`, which is what
  `build-klee.sh` expects at `~/klee-ut/toolchain/clang-r510928/bin`.

- **`build-klee.sh` paths** – it hardcodes `$HOME/klee-ut/...` for the kernel
  tree, the output tree and the work dir, and `$HOME/poco x8 pro ub touch` for
  the final images. The workflow respects that instead of patching the script,
  except for the `-j` value, which is pinned via `sed` so a 4 vCPU runner does
  not run out of memory.

- **Rootfs is built by a separate job** – `build-klee.sh`'s rootfs step wants a
  pre-made `downloads/out/ubuntu.img` (the author produced his with
  `prepare-fake-ota.sh` + Jumpdrive). That file is not published, so the rootfs
  job rebuilds the same result from the UBports CI base rootfs instead:
  unpack the `system/` tree, lay it onto ext4 (with `^metadata_csum,^orphan_file`
  because the initrd's `e2fsck` is 1.43), drop in the klee overlay, apply
  `port/rootfs-patches/*.sh`, then compress to EROFS.

- **EROFS, not ext4, is shipped** – the dual boot install has to fit the rootfs
  plus user data into the free space of `super`. The port ships a compressed
  EROFS image (`mkfs.erofs -zlz4hc,12 -E ztailpacking -C 65536`), which turns
  the ~3.5 GiB ext4 image into ~1.2 GiB. Ubuntu 22.04's `erofs-utils` is 1.4,
  far too old for those flags, so the job builds `erofs-utils` 1.7.1 from source.

- **Python 2 only for the boot images** – the rootfs job does not need
  `python2`, so it does not install it.

## Known limitations of this workflow

- **Disk space.** The kernel job builds inside a container on the runner's root
  filesystem (~14 GB free). A full GKI build wants ~25–30 GB. The job removes
  `apt` lists and uses a shallow clone to buy room, but if it fails with
  `No space left on device`, the fix is to build the kernel locally in WSL2 or
  to split the kernel build across more jobs. Watch the `df -h` output in the
  log to see how close you are.

- **Time.** A GKI kernel on 4 vCPU takes roughly 2–4 hours; the whole two-job
  run can approach the 6-hour per-job limit, which is why the jobs are split.
  Each job is capped at 350 minutes.

- **Not tested end-to-end.** The workflow was assembled from the repository's
  own scripts, `deviceinfo`, `gsi-port-ci.yml` and the upstream build tools. The
  commands mirror what those do, but no run has confirmed them on a runner yet.
  The first run is expected to need small fixes.

## Recovering the phone (you already have the stock ROM)

`C:\Users\Kaze\Documents\Poco_X8_Pro_Things\klee_id_global_images_OS3.0.304.0.WPJIDXM_16.0\images`
contains the stock fastboot ROM (Android 16). If Ubuntu Touch will not boot:

```
fastboot flash boot       boot.img
fastboot flash init_boot  init_boot.img
fastboot flash vendor_boot vendor_boot.img
```

The bootloader (LK) is never touched by the port, so **Volume Down + Power**
always reaches fastboot. Keep the IMEI/NVRAM backup from `install.sh` copied
somewhere off the computer before you start.

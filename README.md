# Pi-hole on ARMv5 (Pogoplug, SheevaPlug, GoFlex, other Kirkwood boards)

Pi-hole stopped shipping ARMv5 builds of `pihole-FTL`, and its installer refuses
ARMv5 CPUs. Even with a hand-built binary, `pihole -up` / `pihole -r` replaces it
with an official one that cannot run. This repo fixes both:

* **`build-armv5.sh`** cross-compiles a fully static `pihole-FTL` for ARMv5TE
  (soft-float EABI, musl). No dependencies on the device, so it runs the same
  on Alpine, Debian armel, or anything else.
* **A GitHub Actions workflow** watches `pi-hole/FTL`. When there's a new
  release it builds it, tests it on an emulated ARM926 CPU (a real ARMv5 core),
  and publishes it **here** under the same tag name (`v6.9`, ...).
* **A small patch to the core scripts**, applied to your fork of
  `pi-hole/pi-hole`, makes the installer detect ARMv5 and download FTL from
  this repo's releases. Updates also come from your fork, and every other
  architecture works as before. The same workflow merges each new upstream
  core release into your fork, so `pihole -up` keeps working normally.

v6 only has one binary: `pihole-FTL` includes dnsmasq, SQLite (`pihole-FTL sqlite3`),
Lua, and the web server/API. Nothing else is architecture-specific. The web
interface (`pi-hole/web`) and core scripts are plain files, and the web
interface still comes straight from upstream.

## Layout

```
build-armv5.sh                      cross-build: musl + gmp, nettle, libidn2,
                                    libunistring, ncurses(tinfo), readline,
                                    mbedTLS, then FTL
patches/                            FTL source patches applied at build time
core-patch/0001-armv5-support.patch the core-script patch (owner = __FORK_OWNER__)
scripts/sync-core-fork.sh           init/sync your pi-hole fork
test/functional-test.sh             DNS/blocking/API/TLS test under qemu-arm
.github/workflows/release.yml       the automation
```

## One-time setup

1. **Fork `pi-hole/pi-hole`** on GitHub. Keep the name `pi-hole`. In the fork, go to
   *Settings → Actions → General* and select **Disable actions**, so upstream's CI
   workflows don't run there.
2. **Create a repo named `FTL-armv5`** under the same account, and push the
   contents of this folder to it. Actions stay enabled here. This repo doesn't
   have to be a fork of `pi-hole/FTL`, because the workflow builds upstream's
   tagged source directly.
3. **Create a fine-grained personal access token.** Give it access to
   *only* `saladsforme00-hub/pi-hole`, with the permissions **Contents: Read and write** and
   **Workflows: Read and write**. Workflows permission is needed because upstream
   merges can touch `.github/workflows`. In `FTL-armv5`, add it as the repository
   secret **`CORE_FORK_TOKEN`** (*Settings → Secrets and variables → Actions*).
4. **Run the workflow once by hand.** Go to *Actions → "ARMv5 FTL build + core fork sync" →
   Run workflow* and tick **init_core**. The first FTL build takes about 15–25 minutes.
   After that, the cached sysroot brings it down to a few minutes. When it's done:
   * `FTL-armv5` has a release, for example `v6.9`, with `pihole-FTL-armv5` and
     `pihole-FTL-armv5.sha1`.
   * Your fork's `master` is the latest core release plus one ARMv5 commit, and
     it's tagged with the upstream version, for example `v6.6`.

From then on, the workflow runs every 6 hours by itself.

## Installing on the Pogoplug (Alpine)

```sh
apk add bash curl
curl -sSL "https://raw.githubusercontent.com/saladsforme00-hub/pi-hole/master/automated%20install/basic-install.sh" | bash
```

The installer should print `Detected ARMv5 architecture (v5TE), using saladsforme00-hub/FTL-armv5 builds`.

**Already ran the official installer?** Point the existing checkout at your fork
and repair:

```sh
cd /etc/.pihole
git remote set-url origin https://github.com/saladsforme00-hub/pi-hole.git
git fetch --force --tags origin
git reset --hard "$(git describe --abbrev=0 --tags origin/master)"
pihole -r        # choose "Repair"
```

## Updating

Use `pihole -up` as usual. It checks your fork for core updates, `pi-hole/web` for
the web interface, and `saladsforme00-hub/FTL-armv5` for FTL. The installer verifies the binary's
SHA1 before installing it, like upstream.

## Safety rails

* **Upstream changes that collide with the patch never reach your device.** If a
  core release conflicts with the patch, the sync job fails without pushing, and
  GitHub emails you. Your Pi-hole stays on the previous version. To fix it, refresh
  `core-patch/0001-armv5-support.patch` against the new release, then rerun with
  **init_core**. A re-init is recorded as a merge, so devices still fast-forward.
* **Core updates wait for FTL.** The core sync runs only after the FTL job
  succeeds, so your fork never offers a core release before the matching FTL
  binary has been published.
* **Releases are published as drafts first.** The binary and checksum are
  uploaded before the release goes public, so the installer never sees a release
  that has no binary.
* **Every build is tested before it's published.** The tests run under
  `qemu-arm -cpu arm926`: hosts record, exact and regex blocking, the stats API,
  and HTTP and HTTPS. The build also fails if the binary contains any ARMv6+ or
  VFP instructions, or isn't tagged `v5TE`.
* **You can pin your own binary.** `touch /etc/pihole/ftl-pinned` stops the installer and
  `pihole -up` from ever replacing `/usr/bin/pihole-FTL`.
* `pihole checkout ftl <branch>` doesn't apply to ARMv5, because only releases are
  built. If you select a branch, the installer prints a notice and stays on the
  latest release.

## Building by hand

On Ubuntu 24.04 (x86_64 or arm64):

```sh
sudo apt-get install -y build-essential gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
     cmake m4 xxd file curl git qemu-user dnsutils
git clone --depth 1 --branch v6.9 https://github.com/pi-hole/FTL.git ftl-src
./build-armv5.sh ftl-src out          # -> out/pihole-FTL-armv5 (+ .sha1)
sudo test/functional-test.sh out/pihole-FTL-armv5   # optional, uses /etc/pihole!
```

## How the build works

* **Toolchain:** Ubuntu's `arm-linux-gnueabi-gcc`, which targets ARMv5T by default,
  together with musl built from source and musl's GCC specs file. The flags are
  `-march=armv5te -mfloat-abi=soft -marm`. libgcc provides the ARMv5 atomic
  helpers (`__sync_*`, which use the kernel's lock-free `__kuser_cmpxchg`) and
  the unwinder that FTL uses for crash backtraces.
* **Dependencies:** the versions match upstream's `ftl-build` image (Alpine 3.23,
  ftl-build v2.19). Two dependencies differ:
  * readline uses ncurses' `libtinfo` instead of GNU termcap.
  * nettle is built with `--disable-fat`, so it contains no ARMv6/NEON code paths.
* **`patches/0001-events-accept-armv5-kernel-helper-atomics.patch`:** FTL asserts
  `ATOMIC_BOOL_LOCK_FREE == 2`. On ARMv5, GCC can only promise `1`, because the
  atomics are library calls. Those calls are lock-free and async-signal-safe,
  since the kernel restarts an interrupted cmpxchg, so the patch accepts them
  on ARMv5 only.
* **Version metadata** (`pihole-FTL version`/`tag`/`--hash`) is taken from the
  unpatched upstream tag. This matches the official build, so the updater and
  the web UI's version checks behave normally.
* Optional dnsmasq features that upstream's static builds also lack (DBus,
  conntrack, nftset) are off.

## Limits

* Your kernel needs the ARM kuser helpers. ARMv5 kernels always have them.
* FTL is heavy for 128 MB devices. Keep blocklists moderate and put
  `/etc/pihole` on decent storage, not a slow USB stick.

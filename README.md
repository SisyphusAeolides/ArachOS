# ArachOS

![ArachOS](docs/ArachOS.png)

ArachOS is assembled with [archiso](https://wiki.archlinux.org/title/Archiso), but its boot and service contract is its own: RustD is PID 1, Arach-Kernel is the only kernel, and the measured Arach payloads are loaded directly by the boot contract. The release path never falls back to a generic Linux kernel. ArchISO supplies the image assembly primitives; it does not define the installed runtime package interface.

The release pipeline is Arch-native: pacman packages are built in Podman and
assembled by the ArchISO profile.

## Core components

| Package | Replaces | Description |
|---|---|---|
| `rustd` | `systemd` | Rust PID 1 and service manager |
| `rustd-resolved` | `systemd-resolved` | Rust DNS resolver |
| `libinput-rs` | `libinput` | 100% Rust libinput 1.31.3 ABI drop-in |
| `tuned-rs` | `tuned` / `power-profiles-daemon` | Rust power management |
| `blerust` | `blesh` | Rust line editor |
| `ccze-rs` | `ccze` | Rust log colorizer |
| `iwchaos` | — | Kept outside the release image until an Arach-Kernel-native Wi-Fi driver is qualified |
| `hermes-gpu-stack` | NVIDIA/AMD drivers | Hardware-qualified multi-vendor GPU stack |
| `arach-hwd` | — | Signed Arach-Kernel hardware and firmware planner |
| `corinth` | Arch package transaction path | Signed native package resolver with atomic generations and rollback |
| `arach-kernel` | `linux` | Measured Arach Kernel Multiboot2 image + RustD payloads |
| `arachos-release` | `archlinux-release` | ArachOS identity, branding, and OS metadata |

## Installer

ArachOS ships a fully branded Calamares “Everything” installer built from the
pinned upstream Calamares source. KDE Plasma is the default desktop, and the
profile exposes the filesystem, bootloader, and desktop choices whose tools
are present in the image. The stock Calamares package job is not in the
sequence: `arachos-packages` receives the selections from `netinstall` and
executes signed Corinth transactions inside the mounted target root. No
foreign package-manager backend is available to the installer, and the live
profile does not install a distribution package-manager client. The standalone
measured-kernel qualification image uses Limine's Multiboot2 loader; the live
installer profile currently uses GRUB's Multiboot2 path. The installer remains
qualification-only until Arach Kernel provides the persistent live root and
the complete Calamares handoff has passed its installed-disk tests.

The release image is gated on the complete live-media and installed-system
campaign. It will not be published while the Arach Kernel, RustD, RustD-
resolved, Hermes, Calamares installation, first boot, networking,
Corinth/Arach-HWD package transactions, reboot, and shutdown manifests are
pending or incomplete.

## Repository layout

```text
archiso/                        archiso build profile
  airootfs/                     Files placed onto the live/installer root
    etc/                        OS identity, pacman config, Calamares settings
      calamares/                ArachOS branding and netinstall configuration
  packages.x86_64               Package list for the live medium (Plasma, Calamares, etc.)
  pacman.conf                   pacman config used during the ISO build
  profiledef.sh                 archiso profile metadata
packaging/
  branding/                     ArachOS branding assets and OS metadata
  pkgbuild/                     ArachOS PKGBUILD files
  rustd/                        RustD-native companion service units
scripts/
  build-packages.sh             Build all pacman packages from pinned sources
  build-iso.sh                  Build the archiso live/install ISO
  test-calamares-corinth.py     Test Calamares package routing without a target root
  clean-temp.sh                 Remove disposable ArachOS test and image work
  build-arach-kernel-pkg.sh     Build the pacman arach-kernel package
  build-arach-kernel-bundle.sh  Arach Kernel / RustD qualification build
  validate-packages.sh          Validate the built pacman repository
  sign-pkg-repo.sh              Sign packages and the repository database
  stage-corinth-deployment.sh   Stage an explicit signed service deployment
  validate-corinth-deployment.sh Check the deployment boundary
  verify-sources.sh             Validate pinned source checkouts
  check-chaos.sh                Chaos-math, Fortran, and wireless gates
sources.lock                    Exact source revisions for all components
Makefile                        Reproducible entry points
```

## Prerequisites

The supported build path uses Podman so package and ISO tooling stays inside a
reproducible Arch Linux container. The host needs Podman, QEMU, and OVMF:

```sh
sudo pacman -S podman qemu-full edk2-ovmf
```

Formal checks use Idris 2 built directly from the pinned upstream source tree.
Install the Chez Scheme runtime and the other build tools with the Arch package
manager, then build the pinned revision:

```sh
sudo pacman -S --needed chez-scheme agda git base-devel
git clone --filter=blob:none https://github.com/idris-lang/Idris2.git "$HOME/src/Idris2"
git -C "$HOME/src/Idris2" checkout --detach 5aaefadb587224eb44d3be0fbb7e2835b48bd7a6
make -C "$HOME/src/Idris2" bootstrap SCHEME=chez PREFIX="$HOME/.local"
make -C "$HOME/src/Idris2" install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

The formal verification scripts accept `IDRIS2=/path/to/idris2` when the
compiler is installed outside `PATH`.

## Building packages

All ArachOS packages are built from the exact commits recorded in
`sources.lock`. Check out the required source trees alongside this repository,
then run the container build:

```sh
scripts/run-podman-build.sh
```

To sign the package repository, provide your GPG credentials:

```sh
make build-packages \
  ARACHOS_GPG_HOME=/path/to/gpg-home \
  ARACHOS_GPG_KEY_ID=<KEY-ID>
```

The packages are written to `build/packages/` with a signed `arachos.db.tar.gz` pacman repository database.

When a complete adjacent checkout is available, the builder uses it as the
offline Git source. Shallow or partial checkouts are never mirrored as if they
were complete; the builder falls back to the same pinned HTTPS commit so a
missing promisor object cannot turn into a misleading package result.

## Native package-management path

`arach-hwd` and `corinth` are built into the image from the exact revisions in
`sources.lock`. Arach-HWD supplies signed hardware evidence and plans;
Corinth supplies dependency resolution, native artifact verification, atomic
generation publication, and rollback. KDE Plasma remains the default desktop;
Cosmic is not selected by the ArachOS profile.

The Arch package tools are still used by ArchISO while this path is qualified;
they are build-time tooling, not the installed package-management interface.
That keeps image assembly reproducible without claiming an installed-root
transaction that has not run. The Arch-tool hand-off is allowed only after native
install, update, remove, rollback, first-boot, and Calamares tests pass in
disposable QEMU runs. Until then, Corinth is available for qualification and
the release gate reports the remaining work instead of silently falling back.

Once a release is provisioned with its signed Corinth service deployment, the
same four commands search and manage packages from the admitted Arch, AUR,
Fedora, Debian, Alpine, Gentoo, CRUX, and Nix catalogs:

```text
corinth search example
corinth install example
corinth update example
corinth remove example
```

Provider discovery and recipe ingestion run in the repository worker. The
installed client consumes only the signed, digest-pinned catalogs and cached
artifacts named by `/etc/corinth/service.toml`; it never executes a mutable
foreign package script or silently invokes pacman, dnf, apt, apk, emerge,
pkgsrc, or nix as a fallback. A release image without that signed deployment
must remain a qualification image because those commands cannot be trusted to
modify the installed root yet. The service file can bootstrap a signed
provider-registry manifest; Corinth refreshes that manifest on each ordinary
command, enforces its monotonic generation, and keeps a verified private cache
for offline operation. The registry is the only automatic bridge from the
eight foreign ecosystems into the signed native catalogs.

The image builder accepts that deployment only as an explicit release input;
it never creates keys or embeds a mutable provider URL by default. Supply the
three public, signed files together when composing a release image:

```sh
make build-iso \
  ARACHOS_CORINTH_SERVICE_CONFIG=/secure/release/service.toml \
  ARACHOS_CORINTH_SERVICE_SIGNATURE=/secure/release/service.toml.sig \
  ARACHOS_CORINTH_KEYRING=/secure/release/keys.toml \
  ARACHOS_CORINTH_DEPLOYMENT_REQUIRED=1
```

The builder copies them only into its disposable ArchISO profile and checks
that the service names a signed provider registry. Corinth performs the full
signature, digest, generation, expiry, and provider validation at boot. If
the files are omitted, validation explicitly reports a qualification image;
the four commands are not presented as a usable installed transaction path.

The hardware planner uses a separate signed Arach-HWD catalog. Supply its
complete catalog directory with the same build when the release has been
qualified for the target hardware:

```sh
make build-iso \
  ARACHOS_CORINTH_SERVICE_CONFIG=/secure/release/service.toml \
  ARACHOS_CORINTH_SERVICE_SIGNATURE=/secure/release/service.toml.sig \
  ARACHOS_CORINTH_KEYRING=/secure/release/keys.toml \
  ARACHOS_HWD_CATALOG_ROOT=/secure/release/arach-hwd-catalog \
  ARACHOS_CORINTH_DEPLOYMENT_REQUIRED=1
```

The directory must contain `catalog.lock`, `keys.toml`, and a complete
`profiles/` tree with no symlinks. Calamares verifies that catalog through
`arach-hwd plan --require-target-profiles`, writes the resulting plan under
`/run/arach-installer`, and hands that plan to Corinth. A missing catalog keeps
the image in qualification status; the installer never guesses a driver.

The component checks can be run directly from their pinned worktrees:

```sh
RUSTUP_TOOLCHAIN=nightly-x86_64-unknown-linux-gnu \
  cargo test --manifest-path ../Arach-HWD/Cargo.toml --locked --all-targets --features fortran-ranking
RUSTUP_TOOLCHAIN=nightly-x86_64-unknown-linux-gnu \
  cargo test --manifest-path ../Corinth/Cargo.toml --locked --all-targets \
    --features fortran-policy,host-store
```

## Building the ISO

The ISO build requires the Arach Kernel qualification bundle and Hermes qualification to have passed first:

```sh
make build-arach-kernel-bundle
make qualify-hermes
```

Once every required qualification manifest reports `status=pass`, the Podman
build composes the ISO automatically. To rerun only ISO composition inside an
existing builder container:

```sh
podman unshare podman run --rm --privileged --user root \
  --security-opt label=disable \
  -v "$HOME/Projects:/home/builder/workspace:z" \
  arachos-builder bash -lc 'cd ArachOS && make build-iso'
```

For a release candidate, provide the hosted ArachOS repository URL so the installed system has an enabled ArachOS source after reboot:

```sh
ARACHOS_REPOSITORY_URL=https://mirror.example/arachos/1.0/x86_64/ \
  scripts/run-podman-build.sh
```

If that variable is omitted, the installer writes a disabled repository entry and prints a warning. The result is:

```text
build/iso/ArachOS-1.0-<YYYYMM>-x86_64.iso
```

## Installing ArachOS

For a qualified release, boot the ISO to the KDE Plasma live desktop and click
the **Install ArachOS** shortcut to launch Calamares. The installer then guides
you through partitioning, users, and the desktop choices included by the
profile. The final installation step writes the Arach Kernel payload and
validates the Multiboot2 boot contract on the target disk.

The current checkout is still a qualification build, not a release image.
Use the disposable QEMU installation campaign described below until every
manifest reports `status=pass`.

Before release, `make test-kernel-qemu` must pass both BIOS and UEFI boots and
report the runtime-ready marker. Installer tests use disposable QEMU disks and
must cover installation, first boot from the installed disk, networking,
resolver operation, package transactions, reboot, and shutdown. Test firmware
state, disks, serial logs, and failed build work are temporary and are removed
after each run.

If an interrupted run leaves a disposable test directory behind, use
`make clean-temp`. It only removes the ArachOS-owned `arachos-grub.*`,
`arachos-limine.*`, and `arachos-qemu.*` directories below `${TMPDIR:-/tmp}`.
It does not touch unrelated temporary files.

## Arach Kernel qualification bundle

Arach Kernel is the only kernel in the ArachOS boot contract. Build the
qualification bundle:

```sh
make build-arach-kernel-bundle
```

The standalone bundle is built with Limine and records
`status=qualification-only` until the persistent root, BIOS/UEFI installed-boot
gates, and all runtime paths pass. The build stops instead of composing an ISO
when qualification is incomplete.

The pinned kernel now includes the checked sector-I/O and GPT partition
boundary used by the upcoming disk driver. It is deliberately not treated as
storage support yet: a hardware block driver, filesystem implementation, and
boot-time root handoff still have to pass their QEMU and installed-disk tests.

## Hermes release qualification

Hermes is an evidence-driven GPU stack. Run its qualification harness from the pinned Hermes checkout:

```sh
make qualify-hermes
```

A missing firmware path, simulation-only result, incomplete DRM/CUDA/NVML/Mesa/MPS/UVM path, or missing fault-recovery/soak result leaves the manifest `status=blocked`. `build-iso` refuses every Hermes manifest other than `status=pass`.

## Source verification

All source checkouts are pinned in `sources.lock`. To verify that every checkout matches its recorded commit exactly:

```sh
make verify-sources
```

## License

MIT

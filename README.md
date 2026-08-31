<p align="center">
  <img src="docs/ArachOS.png" alt="ArachOS operating system logo" width="320">
</p>

# ArachOS

ArachOS is an independent x86-64 Linux distribution with its own release
identity, RPM repository metadata, DNF configuration, graphical Anaconda
installer, RustD service manager, RustD-resolved resolver, and Arach Kernel
qualification path. The distribution is no longer a remaster or derivative
installer build: the installer boot image is composed from repository metadata
by Lorax, and the final ISO is assembled by ArachOS tooling.

ArachOS uses the generic EL10 RPM ABI as a bootstrap ecosystem so existing RPM
and DNF software remains useful. That is a package-compatibility boundary, not
the product identity. The installed release reports `ID=arachos`, owns the
release and logo capabilities needed by Anaconda, and does not install another
distribution's release or logo package. Upstream licenses and required
compatibility paths remain intact where software expects them.

The design priorities are bounded chaos-math control, predictable performance,
fail-closed validation at security and ABI boundaries, and explicit C shims
where a Linux or vendor ABI requires one. RustD owns the installed service
graph and PID 1; RustD-resolved owns DNS, NSS, Varlink, and resolver
compatibility; Hermes supplies the GPU/GSP compatibility surfaces; the other
Rust components provide tuning, input, line editing, log analysis, and Wi-Fi
validation.

## Component graph

| Component | Checkout | ArachOS role |
| --- | --- | --- |
| RustD | `../rustd` | PID 1, service manager, udev, journal, D-Bus and RPM compatibility shims |
| RustD-resolved | `../rustd-resolved` | Native DNS, NSS, Varlink, DNSSEC, and resolver service |
| Arach Kernel | `../Arach-Kernel` | Rust-first kernel and measured Linux ABI qualification image |
| tuned-rs | `../tuned-rs` | Tuning and power-profile services |
| libinput-rs | `../libinput-rs` | libinput ABI, tools, udev helpers, and input quirks |
| blerust | `../blerust` | Rust line editor |
| ccze-rs | `../ccze-rs` | Streaming log colorizer and bounded analytics |
| iwchaos | `../iwchaos` | Chaos-math validation and wireless integration inputs |
| Hermes | `../Hermes` | Multi-vendor GPU/GSP, CUDA/NVML/Mesa surfaces and kernel-module shims |

Every component revision is recorded in [`sources.lock`](sources.lock), and
the build refuses a checkout whose commit differs from that lock file.

## Build prerequisites

The normal build host needs an EL10-compatible RPM toolchain, Lorax/Anaconda,
QEMU, and the native build dependencies used by the component repositories.
Rustup nightly is supported; the reproducible RustD path defaults to the
system-wide `nightly-2026-07-20` toolchain.

```sh
sudo dnf install \
  anaconda anaconda-gui anaconda-tui lorax lorax-templates-generic \
  mkksiso xorriso createrepo_c rpm-build rpmdevtools \
  cargo rust rustfmt clippy gcc gcc-c++ gcc-gfortran make meson ninja-build \
  patch openssl-devel liburing-devel libevdev-devel mtdev-devel json-c-devel \
  dbus-devel pam-devel polkit-devel selinux-policy-devel python3 clang kmod
```

All checkouts belong under `~/Projects`:

```sh
cd ~/Projects/ArachOS
export RUSTUP_TOOLCHAIN=nightly-2026-07-20
make verify-sources
make check-chaos
```

## RPM and DNF repository

The build uses public EL10-compatible repositories only as bootstrap inputs.
Override them with ArachOS mirrors when they are available:

```sh
export ARACHOS_BASEOS_URL=https://mirror.example/arachos/1.0/core/x86_64/
export ARACHOS_APPSTREAM_URL=https://mirror.example/arachos/1.0/apps/x86_64/
export ARACHOS_CRB_URL=https://mirror.example/arachos/1.0/build/x86_64/
export ARACHOS_RPM_DIST=.arachos

make build-rpms
make validate-rpms
```

`build-rpms` creates a repository containing the RustD stack, ArachOS release
identity, Hermes, and all pinned companion packages. It also writes a manifest
with source revisions, the exact bootstrap systemd capability used for RPM
dependency compatibility, and SHA-256 digests. Sign the repository and enable
GPG verification before publishing a production mirror; local preflight builds
keep verification disabled because no project signing key is committed.

## Graphical Anaconda installer

The installer is a standalone Anaconda boot ISO. It is composed directly from
the configured repositories; no pre-existing distribution ISO is read,
modified, or required. The kickstart supplies repository sources and the
RustD post-install transition but intentionally leaves disk selection and
optional desktop selection to the graphical Anaconda UI.

```sh
sudo make build-installer
```

For a release candidate, provide the hosted ArachOS repository URL so the
installed system has an enabled ArachOS source after reboot:

```sh
sudo ARACHOS_REPOSITORY_URL=https://mirror.example/arachos/1.0/x86_64/ \
  make build-installer
```

If that variable is omitted, the installer writes a disabled media-repository
entry and prints a warning. The result is:

```text
build/iso/ArachOS-1.0-1-installer-x86_64.iso
```

The ISO contains the graphical Anaconda runtime, BIOS and UEFI boot entries,
the ArachOS kickstart, and the ArachOS RPM repository. `build-live` and
`build-live-existing` remain compatibility make targets for the installer
builder; neither target consumes an external ISO or creates a desktop live
session.

## Arach Kernel qualification bundle

Arach Kernel is developed and measured independently from the generic Linux
kernel used to bootstrap Anaconda. The bundle builder builds RustD as a
loader-free static PIE from the pinned RustD checkout, builds the measured C0
Linux-ABI probe and Arach Kernel, and packages them into a GRUB Multiboot2
qualification image:

```sh
make build-arach-kernel-bundle
```

The bundle is a qualification artifact, not a claim that every Linux driver,
filesystem, graphical stack, or installed-system path already runs on Arach
Kernel. Its manifest records every measured artifact and source revision.
Persistent storage, the complete Linux ABI, external-module lifecycle,
RustD/RustD-resolved service startup, and graphical desktop paths remain
separate runtime gates until their BIOS and UEFI tests pass.

## Installed-system transition

The target transaction installs the ArachOS release package, RustD, the
RustD-resolved service and NSS module, RustD-owned compatibility libraries and
commands, SELinux policy, tuned-rs, libinput-rs, blerust, ccze-rs, and Hermes.
It then rebuilds the target initramfs and checks that:

- `/etc/os-release` reports `ID=arachos`;
- `/usr/sbin/init` and `/proc/1/exe` resolve to RustD;
- resolver state is under `/run/rustd/resolve` and the NSS module is active;
- native unit definitions live under `/usr/lib/rustd/system`;
- RPM/DNF dependency capabilities remain available through RustD shims; and
- no outgoing service-manager implementation package remains in the target.

These checks are necessary but not sufficient for a production release. Run
the full disposable-VM boot, networking, storage, graphical, suspend/resume,
shutdown, fault-recovery, and long-running soak campaign before installing on
hardware without a recovery path.

## Containerized media build

For a rootful builder image containing the same Lorax and Anaconda packages:

```sh
ARACHOS_BUILDER_IMAGE=localhost/arachos-build:el10 \
  make build-live-container
```

The container builder mounts only the ArachOS checkout and a dedicated output
directory. It runs the same repository-native installer composition and emits
the same ISO contract as the host build.

## Repository layout

```text
docs/ArachOS.png                    Project artwork
kickstart/ArachOS.ks                Interactive Anaconda configuration
packaging/branding/                 ArachOS release and logo package
packaging/fedora/                   RPM ABI compatibility package specs
packaging/koji/                     Optional ArachOS Koji build-farm setup
packaging/rustd/                    RustD-native companion service units
scripts/build-rpms.sh               Pinned source and RPM assembly
scripts/build-live.sh               Standalone Lorax and Anaconda ISO build
scripts/build-arach-kernel-bundle.sh Arach Kernel/RustD qualification build
scripts/build-koji.sh               Ordered optional Koji RPM pipeline
scripts/validate-rpms.sh            RPM ownership and capability validation
scripts/verify-sources.sh            Source pin and tree validation
scripts/check-chaos.sh               Chaos-math, Fortran, and wireless gates
sources.lock                         Exact source revisions
Makefile                             Reproducible entry points
```

## License

MIT

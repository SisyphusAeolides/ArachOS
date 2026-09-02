<p align="center">
  <img src="docs/ArachOS.png" alt="ArachOS operating system logo" width="320">
</p>

# ArachOS

ArachOS is an independent x86-64 Linux distribution with its own release
identity, RPM repository metadata, DNF configuration, graphical Anaconda
installer, RustD service manager, RustD-resolved resolver, and Arach Kernel
qualification path. The distribution is not presented as a Fedora spin: the
final media owns its volume metadata, boot menus, Anaconda product image,
release files, artwork, and installed-system identity. The bootstrap netinst
image is an implementation input only.

ArachOS uses the Fedora 45 package pool represented by the supplied dated
netinst image as a bootstrap ecosystem. That is build input, not the product
identity. ArachOS owns its release package, repository metadata, installer
profile, and artwork; the installed release reports `ID=arachos` and does not
install another distribution's release or logo package. Upstream licenses and
required compatibility paths remain intact where software expects them.

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
| iwchaos | `../iwchaos` | Chaos-math validation and target-kernel Intel Wi-Fi DKMS modules |
| Hermes | `../Hermes` | Multi-vendor GPU/GSP, CUDA/NVML/Mesa surfaces and kernel-module shims |

Every component revision is recorded in [`sources.lock`](sources.lock), and
the build refuses a checkout whose commit differs from that lock file.

## Build prerequisites

The normal build host needs an RPM toolchain, `mkksiso`, QEMU, and the native
build dependencies used by the component repositories. Rustup nightly is
supported; the reproducible RustD path defaults to the system-wide
`nightly-2026-07-20` toolchain.

```sh
sudo dnf install \
  mkksiso xorriso createrepo_c rpm-build rpmdevtools \
  squashfs-tools \
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

The build uses the Fedora 45 Everything core and updates repositories as
bootstrap inputs. Override them with ArachOS mirrors when they are available:

```sh
export ARACHOS_BOOTSTRAP_RELEASE=45
export ARACHOS_CORE_URL=https://mirror.example/arachos/bootstrap/45/core/x86_64/
export ARACHOS_UPDATES_URL=https://mirror.example/arachos/bootstrap/45/updates/x86_64/
export ARACHOS_RPM_DIST=.arachos

make build-rpms
make validate-rpms
```

`build-rpms` creates a repository containing the RustD stack, ArachOS release
identity, Hermes, the iwchaos target-kernel DKMS source package, and all pinned
companion packages. It also writes a manifest
with source revisions, the exact bootstrap systemd capability used for RPM
dependency compatibility, and SHA-256 digests. The installer builder requires
every ArachOS RPM to be signed by an operator-controlled key. Set
`ARACHOS_GPG_HOME` and `ARACHOS_GPG_KEY_ID` when running `make build-rpms`; the
public key is embedded in the ISO repository and the kickstart verifies it
during installation. An unsigned repository is rejected.

## Graphical Anaconda installer

The installer uses the supplied Everything netinst image only as an initial
Anaconda source. The release build unpacks and rebuilds its Anaconda squashfs
stage2 with the ArachOS release payload, replaces the stage2 `os-release` and
profile set, and injects an ArachOS `product.img` (buildstamp, profile,
stylesheet, splash, header, task-bar icon, and logo artwork). The stage2 patch
also makes the Anaconda window title, icon, release metadata, and fallback
logo assets ArachOS-owned, and removes bootstrap repository, Flatpak, SWID, and
report-workflow identity files that could leak the source distribution. It
requires a separately qualified
Arach-Kernel Linux boot image and a RustD-owned initramfs; a stock Fedora
kernel or systemd initramfs is rejected before `mkksiso` runs. Every BIOS/UEFI
boot label passes `inst.profile=arachos` to Anaconda. The result is ArachOS
installer media, not a bootstrap-branded boot or desktop session. The
installer boots from the configured core/update repositories; it is not a
desktop live session. The kickstart supplies repository sources and the RustD
post-install transition but intentionally leaves disk selection and optional
desktop selection to the graphical Anaconda UI.

Anaconda's `org.fedoraproject.Anaconda.*` D-Bus names are retained as the
upstream module ABI; they are not the displayed distribution identity and are
not replaced, because changing them would disconnect Anaconda's own modules.

The current bootstrap input is:

```text
/home/Sisyphus/Downloads/Fedora-Everything-netinst-x86_64-45-20260831.n.0.iso
sha256=523f17169f6012c8a9f04b1b1ceb330428a8fb1cf72e076de71dd396ffd9c40d
```

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
the ArachOS kickstart, and the ArachOS RPM repository. The upstream installer
license notice remains as a legal attribution for the bootstrap input; it is
not an operating-system identity. The installed target is checked for ArachOS
identity and absence of the bootstrap release package. `build-live` and
`build-live-existing` are retained as compatible make targets for the same
Anaconda composition path, and both reject the generic `kernel*` package family
and any unqualified live kernel/initramfs. Set these release inputs only after
the live-runtime campaign has passed:

```sh
export ARACHOS_INSTALLER_KERNEL=/path/to/arach-kernel-linux-bzimage
export ARACHOS_INSTALLER_INITRD=/path/to/rustd-live-initramfs.img
export ARACHOS_LIVE_RUNTIME_MANIFEST=/path/to/live-manifest.txt
```

The manifest must report `status=pass`, `kernel=arach-kernel`, and
`pid1=rustd`; it must also bind the exact revisions in `sources.lock`. A
pending or missing manifest intentionally produces no ISO.
`build-installer` also builds the pinned Arach-Kernel qualification bundle and
requires its install-qualification manifest before composing media. The current
bundle records `status=qualification-only`, because the persistent root,
Anaconda-target, and BIOS/UEFI installed-boot gates are not complete; the build
therefore stops instead of installing a generic Fedora kernel.

## Arach Kernel qualification bundle

Arach Kernel is developed and measured independently from the generic Linux
kernel used only to bootstrap Anaconda. The bundle builder builds RustD as a
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
separate runtime gates until their BIOS and UEFI tests pass. A target is not
release-ready until an `arach-kernel` package provides `/boot/arach`, the RustD
and RustD-resolved boot payloads, and `/usr/sbin/arach-kernel-install`; that
helper must verify the Multiboot2 image and install both BIOS and UEFI entries
for the persistent ArachOS root. The kickstart rejects residual Fedora
`kernel*` RPMs and refuses a conventional Linux BLS/dracut path.

## Installed-system transition

The target transaction installs the ArachOS release package, RustD, the
RustD-resolved service and NSS module, RustD-owned compatibility libraries and
commands, SELinux policy, tuned-rs, libinput-rs, blerust, ccze-rs, iwchaos, and
Hermes. The iwchaos package registers its target-kernel DKMS source and builds
the four Intel Wi-Fi modules for the bootstrap kernel from a source tree pinned
in `sources.lock`; DKMS then rebuilds the same modules for later installed
kernels. This keeps the first installed system independent of network access
to a source host. A later kernel with a different upstream API must provide a
matching source tree or an explicit `IWCHAOS_LINUX_REF` before it is activated.
The Arach-Kernel package, not RustD or the Fedora bootstrap payload, owns the
installed boot image and bootloader entries through
`/usr/sbin/arach-kernel-install`. The post-install audit invokes that helper
and refuses to continue unless it verifies the Multiboot2 kernel, measured
RustD/RustD-resolved payloads, persistent root, and both BIOS and UEFI entries.
It then checks that:

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

## Hermes release qualification

Hermes is an evidence-driven GPU stack, not a release switch that can be
declared complete by compiling its Rust crates or loading a kernel module. Run
the qualification harness from the pinned Hermes checkout:

```sh
make qualify-hermes
```

It records `build/hermes-qualification/release-manifest.txt` and its scoped
logs. The harness requires strict Rust/formal checks, a clean GCC kmod build,
the advertised drop-in tests, a clean source revision, the Hermes
open-source-boundary audit, shared-chaos coverage, an audit with no placeholder
runtime surfaces, and a physical NVIDIA/AMD/Intel hardware report. Missing
firmware, a
simulation-only result, an incomplete DRM/CUDA/NVML/Mesa/MPS/UVM path, or a
missing fault-recovery/soak result leaves the manifest `status=blocked`.
`build-live`, `build-live-existing`, and `build-live-container` refuse every
Hermes manifest other than `status=pass`; no ISO can therefore ship a
compatibility shell as if it were a complete GPU implementation.

## Containerized media build

For a rootful builder image containing `mkksiso` and the ISO tools:

```sh
ARACHOS_BUILDER_IMAGE=localhost/arachos-build:fedora45 \
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
packaging/rpm/                      ArachOS RPM package specs
packaging/koji/                     Optional ArachOS Koji build-farm setup
packaging/rustd/                    RustD-native companion service units
scripts/build-rpms.sh               Pinned source and RPM assembly
scripts/build-live.sh               Netinst and Anaconda ISO composition
scripts/rebuild-anaconda-stage2.sh Rebuild the branded Anaconda squashfs
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

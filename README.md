<p align="center">
  <img src="docs/ArachOS.png" alt="ArachOS operating system logo" width="320">
</p>

# ArachOS

ArachOS is a CIQ RLC 10.2 live image with Anaconda installer support, built
around RustD as PID 1 and RustD-Resolved as the native resolver. The image is
intended to be installed on a disposable test machine or a snapshot-backed
virtual machine until the installed-system certification gates are green.

The image replaces the RLC service-manager and resolver packages with the
ArachOS RPM set. RLC compatibility entry points remain available for
package scripts, but the running manager, initramfs manager, udev path, resolver
daemon, NSS module, and service units are RustD-owned.

The CIQ RLC release package remains installed for platform, repository, and
support metadata. The separate arachos-release package supplies the ArachOS
identity layer, console branding, Anaconda profile, and image assets.

The build consumes sibling checkouts in `/home/Sisyphus/Projects` by default:

| Component | Checkout | Package role |
| --- | --- | --- |
| RustD | `../rustd` | PID 1, service manager, udev, journal, compatibility libraries |
| RustD-Resolved | `../rustd-resolved` | Native DNS, NSS, Varlink, and resolver service |
| tuned-rs | `../tuned-rs` | Native tuning and power-profile services |
| libinput-rs | `../libinput-rs` | Native libinput ABI and tools |
| blerust | `../blerust` | Rust line editor |
| ccze-rs | `../ccze-rs` | Streaming log colorizer |

All inputs are pinned in [`sources.lock`](sources.lock). The build refuses a
checkout whose commit does not match that file.

## Build prerequisites

Run the build on a CIQ RLC 10.2-compatible build host with the RLC build tools,
a Rust toolchain meeting each source tree's minimum version, and
the tools below:

```sh
sudo dnf install \
  anaconda lorax livemedia-creator createrepo_c rpm-build rpmdevtools \
  cargo rust rustfmt clippy gcc gcc-c++ gcc-gfortran make meson ninja-build patch \
  openssl-devel liburing-devel libevdev-devel mtdev-devel json-c-devel \
  dbus-devel pam-devel polkit-devel selinux-policy-devel python3
```

Build the RPM set first:

```sh
make verify-sources
make build-rpms
make validate-rpms
```

For local preflight testing, use the supplied RLC DVD as a read-only install
tree. The original ISO is never modified:

```sh
sudo RLC_SOURCE_ISO=/home/Sisyphus/Downloads/rlc-plus-10.2-dvd-iso-x86_64-20260808-24929df0-att1.x86_64.iso \
  make build-live-existing
```

The result is written to `build/iso/ArachOS-RLC-10.2-live-x86_64.iso`. The build
also emits a checksum and a package/source manifest beside the ISO.

For the release build, submit the custom source RPMs and the LiveMedia task to
the private RLC Koji deployment:

```sh
make build-rpms
CHAOS_KERNEL_SRPM=/path/to/kernel-clk6.12.src.rpm \
KOJI_CONFIG=/path/to/koji.conf \
RLC_INSTALL_TREE_URL=https://rlc.example.invalid/10.2/x86_64/ \
KOJI_PROFILE=rlc10.2 KOJI_TARGET=rlc-10.2-build \
  make koji-build
```

The Koji pipeline and target requirements are documented in
[`packaging/koji/README.md`](packaging/koji/README.md). A local ISO path is
intentionally rejected by the remote Koji path because the Koji builder must
be able to fetch the install tree itself.

## Image contract

The kickstart installs the RustD boot graph, RustD-Resolved, SELinux policy,
the RustD compatibility packages, and the requested Rust utilities. The
post-install validation requires:

- `/proc/1/exe` to resolve to `/usr/lib/rustd/rustd`;
- `/usr/sbin/init` to resolve to RustD;
- `rustd-resolved.service` to be managed by `rustctl`;
- `/run/rustd/resolve` to own resolver runtime state;
- `libnss_rustd_dns.so.2` to be present and selected in the hosts NSS path;
- no installed RPM whose name is `systemd` or begins with `systemd-`;
- tuned-rs 0.3.0 and the libinput resume unit to be installed under
  `/usr/lib/rustd/system`, never under the outgoing manager's unit root;
- SELinux to remain enforcing with the ArachOS SELinux policy loaded.

The image build does not claim that a successful ISO assembly is equivalent to
the RustD installed-system release certificate. Run the exact RustD and
RustD-Resolved source gates and the full-VM certification campaign before
making the image a machine's only boot path.

## Repository layout

```text
docs/ArachOS.png                Project branding
kickstart/ArachOS.ks              Anaconda live/install kickstart
packaging/fedora/*.spec         Companion RLC-compatible RPM specs
packaging/branding/*.spec       ArachOS identity and installer branding
packaging/koji/                 Koji profile and LiveMedia instructions
packaging/rustd/*.service       RustD-native companion service units
scripts/build-rpms.sh           Pinned source and RPM assembly
scripts/build-live.sh           Local RLC ISO and Anaconda media assembly
scripts/build-koji.sh           Ordered RLC Koji RPM and LiveMedia pipeline
scripts/validate-rpms.sh        RPM ownership and path validation
scripts/verify-sources.sh       Source pin and tree validation
sources.lock                    Exact source revisions
Makefile                        Reproducible entry points
```

## Safety

Keep a known-good recovery path. RustD is a PID 1 replacement and ArachOS
performs a deliberately exclusive package cutover. Test in a VM or on a
machine with recoverable snapshots, and retain the RLC rescue media.

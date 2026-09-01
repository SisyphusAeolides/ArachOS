# ArachOS Koji package build

Koji is an optional build-farm backend for ArachOS. It builds source RPMs in a
private ArachOS profile, tags the resulting builds, waits for repository
metadata, and can export a validated RPM repository for the standalone
ArachOS netinst installer. It does not build or remaster another distribution's
release.

## Required setup

Copy [`koji.conf.example`](koji.conf.example) to a private configuration and
fill in the HTTPS hub, authentication, and ArachOS package targets. The target
must provide the Fedora 45-era RPM build dependencies plus the Rust, C,
Fortran, SELinux, graphics, and kernel toolchains used by the pinned source
trees.

The profile and target defaults are `arachos` and `arachos-1.0-build`. Change
them only when the Koji deployment uses different names.

## Build and export

Build the local source RPM set first, then submit the ordered package set:

```sh
make build-rpms

ARACH_KERNEL_SRPM=/path/to/arach-kernel.src.rpm \
KOJI_CONFIG=/path/to/koji.conf \
KOJI_EXPORT_REPO=$PWD/build/koji-repo \
KOJI_TOPURL=https://koji.example/kojipkgs \
KOJI_PROFILE=arachos KOJI_TARGET=arachos-1.0-build \
  make koji-build
```

`KOJI_BUILD_RPMS=0` skips submission and validates that the target already has
the required latest builds. When `KOJI_EXPORT_REPO` is set, the script
downloads the tagged binary RPMs, regenerates repository metadata, and leaves
the result ready for `make build-installer`:

```sh
RPM_REPO=$PWD/build/koji-repo \
  make build-live-existing
```

The default Arach Kernel source tree is qualified as a GRUB Multiboot2 image.
An SRPM is required only when the package farm is also building a separately
installable kernel package; large source archives remain external build inputs
and are never committed to this repository.

## Scope

Koji produces packages and repository metadata. The graphical installer is
composed by [`scripts/build-live.sh`](../../scripts/build-live.sh), which uses
the pinned Fedora 45 netinst image with the configured bootstrap repositories
and exported ArachOS RPM repository. A successful Koji task is not a runtime
certificate: boot, resolver, storage, graphics, service lifecycle, and fault
recovery still require the ArachOS disposable-VM campaign.

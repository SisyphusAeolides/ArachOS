# Koji package build

ArachOS packages are built and tagged in a private CIQ RLC 10.2 Koji
deployment. The public Fedora Koji service is never a valid target for this
project.

## Required Koji setup

Create a Koji profile using koji.conf.example, then configure a target such
as `rlc-10.2-build` whose build tag contains the CIQ RLC 10.2 repositories
and all build dependencies required by the RustD, RustD-Resolved, tuned-rs,
companion-package, and CLK 6.18 Chaos Kernel SRPMs.

The RLC DVD is not passed to a standard Koji live-media task. Koji's
`spin-livemedia`, `spin-livecd`, and `spin-appliance` tasks synthesize a
different live-root boot model, which is not the RLC Anaconda installer.
Instead, `scripts/build-koji.sh` builds and validates the tagged RPM
repository. `scripts/build-live.sh` then remasters the supplied RLC DVD with
`mkksiso`, preserving its direct graphical Anaconda path and Software
Selection screen.

## Build

Build the source RPM set first, then submit the packages as one ordered
pipeline:

    make build-rpms
    CHAOS_KERNEL_SRPM=/path/to/kernel-clk6.18.src.rpm \
    KOJI_CONFIG=/path/to/koji.conf \
    KOJI_EXPORT_REPO=$PWD/build/koji-repo \
    KOJI_TOPURL=https://koji.example.invalid/kojipkgs \
    KOJI_PROFILE=rlc10.2 KOJI_TARGET=rlc-10.2-build \
    make koji-build

The pipeline builds the CIQ CLK 6.18 Chaos Kernel first, then RustD,
RustD-Resolved, the ArachOS branding layer, and the companion Rust packages.
It waits for the target repository and verifies every package required by the
installed-target transaction in the target's build tag. It does not submit a
live-media task. When `KOJI_EXPORT_REPO` is set, it downloads the validated
binary RPMs from Koji into a local repository for the RLC DVD remaster.

Set `CHAOS_KERNEL_SRPM` to the self-contained `kernel-clk6.18` source RPM from
the Chaos Kernel build. The SRPM is intentionally supplied as a build input
rather than committed to Git because it contains the large CIQ kernel source
archive. The Koji target must provide the RLC 10.2 kernel build dependencies.

If the custom packages are already built and tagged in the target, use
`KOJI_BUILD_RPMS=0`; the script checks that every package named by the
installed-target transaction has a latest build before it returns.

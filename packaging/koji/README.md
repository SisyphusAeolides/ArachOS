# Koji image build

ArachOS is built as a CIQ RLC 10.2 LiveMedia image. The base RLC install tree
and the custom RPMs must be visible to the same private Koji deployment; the
public Fedora Koji service is never a valid target for this project.

## Required Koji setup

Create a Koji profile using koji.conf.example, then configure a target such
as rlc-10.2-build whose build tag contains the CIQ RLC 10.2 repositories,
the matching EL10 LiveMedia repository providing `dracut-live`, and whose
image builder has the livemedia channel and the LiveMedia build group.
The custom package builds must be tagged into that target before the LiveMedia
task starts.

The local DVD ISO cannot be passed directly to a remote Koji builder. Publish
its extracted install tree at an HTTPS URL, or configure the target's install
tree/repository service to expose it. The local ISO remains supported by
make build-live-existing for preflight testing.

## Build

Build the source RPM set first, then submit the packages and image as one
ordered pipeline:

    make build-rpms
    CHAOS_KERNEL_SRPM=/path/to/kernel-clk6.12.src.rpm \
    KOJI_CONFIG=/path/to/koji.conf \
    RLC_INSTALL_TREE_URL=https://rlc.example.invalid/10.2/x86_64/ \
    KOJI_PROFILE=rlc10.2 KOJI_TARGET=rlc-10.2-build \
    make koji-build

The pipeline builds the CIQ CLK 6.12 Chaos Kernel first, then RustD,
RustD-Resolved, the ArachOS branding layer, and the companion Rust packages.
It waits for the target repository,
renders the kickstart with the HTTPS RLC tree, and submits spin-livemedia with
the versioned Lorax templates from this checkout.

Set `CHAOS_KERNEL_SRPM` to the self-contained `kernel-clk6.12` source RPM from
the Chaos Kernel build. The SRPM is intentionally supplied as a build input
rather than committed to Git because it contains the large CIQ kernel source
archive. The Koji target must provide the RLC 10.2 kernel build dependencies.

If the custom packages are already built and tagged in the target, use
KOJI_BUILD_RPMS=0; the script checks that every package named by the kickstart
has a latest target build before submitting the image.

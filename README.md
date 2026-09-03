# ArachOS

![ArachOS](docs/ArachOS.png)

ArachOS is a custom Arch Linux-based operating system built with [archiso](https://wiki.archlinux.org/title/Archiso). It replaces the standard Linux init, input, power management, GPU, and wireless stacks with Rust implementations, and boots an independent measured kernel (Arach Kernel) instead of the generic Linux kernel.

## Core components

| Package | Replaces | Description |
|---|---|---|
| `rustd` | `systemd` | Rust PID 1 and service manager |
| `rustd-resolved` | `systemd-resolved` | Rust DNS resolver |
| `libinput-rs` | `libinput` | 100% Rust libinput 1.31.3 ABI drop-in |
| `tuned-rs` | `tuned` / `power-profiles-daemon` | Rust power management |
| `blerust` | `blesh` | Rust line editor |
| `ccze-rs` | `ccze` | Rust log colorizer |
| `iwchaos` | `iwlwifi` / `iwlmvm` | Intel Wi-Fi DKMS modules with bounded rate policy |
| `hermes-gpu-stack` | NVIDIA/AMD drivers | Hardware-qualified multi-vendor GPU stack |
| `arach-kernel` | `linux` | Measured Arach Kernel Multiboot2 image + RustD payloads |
| `arachos-release` | `archlinux-release` | ArachOS identity, branding, and OS metadata |

## Installer

ArachOS features a **Calamares "Everything" GUI Installer**. It is fully branded, defaults to the KDE Plasma desktop, and provides options for all filesystems, bootloaders, and alternative Desktop Environments during installation. The installer securely transitions the system to the measured Arach Kernel boot contract at the very end of the installation.

## Repository layout

```text
archiso/                        archiso build profile
  airootfs/                     Files placed onto the live/installer root
    etc/                        OS identity, pacman config, Calamares settings
      calamares/                Complete Calamares branding and netinstall configuration
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
  build-arach-kernel-pkg.sh     Build the pacman arach-kernel package
  build-arach-kernel-bundle.sh  Arach Kernel / RustD qualification build
  validate-packages.sh          Validate the built pacman repository
  sign-pkg-repo.sh              Sign packages and the repository database
  verify-sources.sh             Validate pinned source checkouts
  check-chaos.sh                Chaos-math, Fortran, and wireless gates
sources.lock                    Exact source revisions for all components
Makefile                        Reproducible entry points
```

## Prerequisites

Build host must be Arch Linux (or a compatible derivative such as CachyOS) with the following packages installed:

```sh
sudo pacman -S archiso base-devel git cargo rust
```

## Building packages

All ArachOS packages are built from the exact commits recorded in `sources.lock`. Check out the required source trees alongside this repository, then run:

```sh
make build-packages
```

To sign the package repository, provide your GPG credentials:

```sh
make build-packages \
  ARACHOS_GPG_HOME=/path/to/gpg-home \
  ARACHOS_GPG_KEY_ID=<KEY-ID>
```

The packages are written to `build/packages/` with a signed `arachos.db.tar.gz` pacman repository database.

## Building the ISO

The ISO build requires the Arach Kernel qualification bundle and Hermes qualification to have passed first:

```sh
make build-arach-kernel-bundle
make qualify-hermes
```

Once both qualification manifests report `status=pass`, build the ISO:

```sh
sudo make build-iso
```

For a release candidate, provide the hosted ArachOS repository URL so the installed system has an enabled ArachOS source after reboot:

```sh
sudo make build-iso ARACHOS_REPOSITORY_URL=https://mirror.example/arachos/1.0/x86_64/
```

If that variable is omitted, the installer writes a disabled repository entry and prints a warning. The result is:

```text
build/iso/ArachOS-1.0-<YYYYMM>-x86_64.iso
```

## Installing ArachOS

Boot the ISO and you will be greeted by the KDE Plasma desktop. Click the **Install ArachOS** shortcut on the desktop to launch the Calamares installer.

The installer will guide you through partitioning, user creation, and Desktop Environment selection, before validating the strict Multiboot2 boot contract on the target disk.

## Arach Kernel qualification bundle

Arach Kernel is developed and measured independently from the generic Linux kernel. Build the qualification bundle:

```sh
make build-arach-kernel-bundle
```

The bundle records `status=qualification-only` until the persistent root, BIOS/UEFI installed-boot gates, and all runtime paths pass. The build stops instead of composing an ISO when qualification is incomplete.

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

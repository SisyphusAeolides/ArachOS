Name:           arach-kernel
Version:        %{?arachos_version}%{!?arachos_version:1.0}
Release:        %{?arachos_release}%{!?arachos_release:1}%{?dist}
Summary:        Arach Kernel and measured RustD boot payloads
License:        GPL-2.0-only
URL:            https://github.com/SisyphusAeolides/Arach-Kernel
BuildArch:      x86_64

# These files are produced by ArachOS's pinned Arach-Kernel bundle builder.
# The package never compiles or substitutes a generic Linux kernel.
Source0:        arach
Source1:        rustd
Source2:        rustd-resolved
Source3:        arach-kernel-install
Source4:        arach-kernel-bundle-manifest.txt
Source5:        arach-kernel-install-manifest.txt

Requires:       binutils
Requires:       coreutils
Requires:       grub2-tools
Requires(post):  bash

%description
The ArachOS kernel package containing the measured Arach Kernel Multiboot2
image, the RustD PID 1 and RustD-resolved boot payloads, and the strict boot
installation helper.  A Fedora or other generic Linux kernel is never included
or accepted.  The helper refuses installation when the persistent root and
both BIOS and UEFI boot contracts cannot be verified.

%prep

%build

%install
install -Dpm0644 %{SOURCE0} %{buildroot}/boot/arach
install -Dpm0644 %{SOURCE1} %{buildroot}/boot/rustd
install -Dpm0644 %{SOURCE2} %{buildroot}/boot/rustd-resolved
install -Dpm0755 %{SOURCE3} %{buildroot}%{_sbindir}/arach-kernel-install
install -Dpm0644 %{SOURCE4} \
    %{buildroot}%{_datadir}/arachos/arach-kernel/bundle-manifest.txt
install -Dpm0644 %{SOURCE5} \
    %{buildroot}%{_datadir}/arachos/arach-kernel/install-manifest.txt

%check
test -s %{buildroot}/boot/arach
test -s %{buildroot}/boot/rustd
test -s %{buildroot}/boot/rustd-resolved
test -x %{buildroot}%{_sbindir}/arach-kernel-install
grep -Fxq 'schema=arachos-kernel-bundle-v1' \
    %{buildroot}%{_datadir}/arachos/arach-kernel/bundle-manifest.txt
grep -Fxq 'schema=arachos-kernel-install-v1' \
    %{buildroot}%{_datadir}/arachos/arach-kernel/install-manifest.txt

%post
# Package installation is deliberately side-effect free.  Anaconda invokes
# the helper only after the target filesystem and boot mounts are complete;
# running it here would make an RPM transaction appear successful on a
# partially mounted install root.
:

%files
/boot/arach
/boot/rustd
/boot/rustd-resolved
%{_sbindir}/arach-kernel-install
%{_datadir}/arachos/arach-kernel/

%changelog
* Wed Sep 02 2026 Sisyphus Aeolides <SisyphusAeolides@pm.me> - 1.0-1
- Package only the measured Arach Kernel, RustD, and RustD-resolved boot path
- Add strict persistent-root and BIOS/UEFI verification helper

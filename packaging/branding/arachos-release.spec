Name:           arachos-release
Version:        10.2
Release:        1%{?dist}
Summary:        ArachOS identity and installer branding for CIQ RLC 10.2
License:        LicenseRef-ArachOS
URL:            https://github.com/SisyphusAeolides/ArachOS
Source0:        ArachOS.png
BuildArch:      noarch

# Keep the CIQ RLC release package as the platform identity and add ArachOS
# branding as a layer. Replacing rlc-release would discard its repository,
# support, and compatibility metadata.
Requires:       rlc-release >= 10.2

%description
Branding and Anaconda profile integration for ArachOS built on CIQ RLC 10.2.
The package deliberately preserves the RLC release identity and adds an
ArachOS layer for the live media, installer, console, and desktop assets.

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/pixmaps/arachos.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/backgrounds/arachos/ArachOS.png

install -d -m0755 %{buildroot}%{_sysconfdir}/anaconda/profile.d
cat > %{buildroot}%{_sysconfdir}/anaconda/profile.d/z-arachos.conf <<'EOF'
# Anaconda profile for ArachOS on CIQ RLC.
# RLC keeps ID=rocky for platform compatibility, so this profile is loaded
# after the stock Rocky profile and uses it as its base.

[Profile]
profile_id = arachos
base_profile = rocky

[Profile Detection]
os_id = rocky

[Bootloader]
efi_dir = arachos
menu_auto_hide = True

[Payload]
default_source = CLOSEST_MIRROR
EOF

install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/arachos-release <<'EOF'
ArachOS 10.2
Platform: CIQ RLC 10.2
Architecture: %{_target_cpu}
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/issue.d/20-arachos.issue <<'EOF'
ArachOS 10.2 (CIQ RLC 10.2)\n
Kernel \r on \m\n
EOF

%files
%config(noreplace) %{_sysconfdir}/arachos-release
%config(noreplace) %{_sysconfdir}/anaconda/profile.d/z-arachos.conf
%config(noreplace) %{_sysconfdir}/issue.d/20-arachos.issue
%{_datadir}/backgrounds/arachos/ArachOS.png
%{_datadir}/pixmaps/arachos.png

%changelog
* Sun Aug 30 2026 Sisyphus Aeolides <SisyphusAeolides@pm.me> - 10.2-1
- Add the ArachOS identity layer and CIQ RLC Anaconda profile.

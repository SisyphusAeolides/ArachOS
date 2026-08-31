Name:           arachos-release
Version:        %{?arachos_version}%{!?arachos_version:1.0}
Release:        %{?arachos_release}%{!?arachos_release:1}%{?dist}
Summary:        ArachOS release identity and Anaconda branding
License:        LicenseRef-ArachOS
URL:            https://github.com/SisyphusAeolides/ArachOS
Source0:        ArachOS.png
BuildArch:      noarch

Provides:       system-release = %{version}-%{release}
Provides:       system-release(releasever) = 10
Provides:       system-logos = %{version}-%{release}

%description
ArachOS release metadata, graphical installer profile, and product artwork.
The package owns the operating-system identity and provides the generic RPM
capabilities required by Anaconda without importing another distribution's
release package or repository configuration.

%install
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/pixmaps/arachos.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/backgrounds/arachos/ArachOS.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/pixmaps/system-logo-white.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/pixmaps/bootloader/bootlogo_128.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/pixmaps/bootloader/bootlogo_256.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/boot/syslinux-splash.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/sidebar-logo.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/sidebar-bg.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/topbar-bg.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/icons/hicolor/48x48/apps/system-logo-icon.png

install -d -m0755 %{buildroot}%{_sysconfdir}/anaconda/profile.d
cat > %{buildroot}%{_sysconfdir}/anaconda/profile.d/z-arachos.conf <<'EOF'
# Anaconda configuration for ArachOS.

[Profile]
profile_id = arachos
base_profile = rhel

[Profile Detection]
os_id = arachos

[Anaconda]
forbidden_modules =
    org.fedoraproject.Anaconda.Modules.Subscription

[Network]
default_on_boot = DEFAULT_ROUTE_DEVICE

[Bootloader]
efi_dir = arachos
menu_auto_hide = True

[Storage]
file_system_type = xfs
default_partitioning =
    /     (min 1 GiB, max 70 GiB)
    /home (min 500 MiB, free 50 GiB)
    swap

[User Interface]
custom_stylesheet = /usr/share/anaconda/pixmaps/arachos.css
show_kernel_options = True

[Payload]
enable_closest_mirror = False
default_source = CLOSEST_MIRROR

[License]
eula = /usr/share/licenses/arachos-release/LICENSE
EOF

install -Dpm0644 /dev/stdin %{buildroot}%{_usr}/share/anaconda/pixmaps/arachos.css <<'EOF'
/* ArachOS installer palette. */
window, dialog {
    background-color: #10131f;
    color: #e9ecff;
}

headerbar {
    background-color: #171d36;
    color: #ffffff;
}

button.suggested-action {
    background-color: #7148ff;
    color: #ffffff;
}
EOF

install -Dpm0644 /dev/stdin %{buildroot}%{_usr}/lib/os-release <<'EOF'
NAME="ArachOS"
ID=arachos
VERSION="%{version}"
VERSION_ID="%{version}"
PLATFORM_ID="platform:el10"
PRETTY_NAME="ArachOS %{version}"
ANSI_COLOR="0;35"
LOGO=arachos
HOME_URL="https://github.com/SisyphusAeolides/ArachOS"
DOCUMENTATION_URL="https://github.com/SisyphusAeolides/ArachOS"
SUPPORT_URL="https://github.com/SisyphusAeolides/ArachOS/issues"
BUG_REPORT_URL="https://github.com/SisyphusAeolides/ArachOS/issues"
EOF
ln -s ../usr/lib/os-release %{buildroot}%{_sysconfdir}/os-release

install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/system-release <<'EOF'
ArachOS %{version}
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/redhat-release <<'EOF'
ArachOS %{version}
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/system-release-cpe <<'EOF'
cpe:/o:arachos:arachos:%{version}
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/arachos-release <<'EOF'
ArachOS %{version}
Architecture: %{_target_cpu}
Package ecosystem: RPM and DNF
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_sysconfdir}/issue.d/20-arachos.issue <<'EOF'
ArachOS %{version}\n
Kernel \r on \m\n
EOF
install -Dpm0644 /dev/stdin %{buildroot}%{_licensedir}/%{name}/LICENSE <<'EOF'
ArachOS release metadata and artwork are distributed under the terms stated
by the project and the licenses shipped with each upstream component.
EOF

%files
%license %{_licensedir}/%{name}/LICENSE
%config(noreplace) %{_sysconfdir}/arachos-release
%config(noreplace) %{_sysconfdir}/anaconda/profile.d/z-arachos.conf
%config(noreplace) %{_sysconfdir}/issue.d/20-arachos.issue
%config(noreplace) %{_sysconfdir}/os-release
%{_sysconfdir}/redhat-release
%{_sysconfdir}/system-release
%{_sysconfdir}/system-release-cpe
%{_usr}/lib/os-release
%{_usr}/share/anaconda/pixmaps/arachos.css
%{_usr}/share/anaconda/boot/syslinux-splash.png
%{_usr}/share/anaconda/pixmaps/sidebar-bg.png
%{_usr}/share/anaconda/pixmaps/sidebar-logo.png
%{_usr}/share/anaconda/pixmaps/topbar-bg.png
%{_usr}/share/backgrounds/arachos/ArachOS.png
%{_usr}/share/icons/hicolor/48x48/apps/system-logo-icon.png
%{_usr}/share/pixmaps/arachos.png
%{_usr}/share/pixmaps/bootloader/bootlogo_128.png
%{_usr}/share/pixmaps/bootloader/bootlogo_256.png
%{_usr}/share/pixmaps/system-logo-white.png

%changelog
* Mon Aug 31 2026 Sisyphus Aeolides <SisyphusAeolides@pm.me> - 1.0-1
- Establish the independent ArachOS release identity and Anaconda profile.

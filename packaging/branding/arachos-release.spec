Name:           arachos-release
Version:        %{?arachos_version}%{!?arachos_version:1.0}
Release:        %{?arachos_release}%{!?arachos_release:1}%{?dist}
Summary:        ArachOS release identity and Anaconda branding
License:        LicenseRef-ArachOS
URL:            https://github.com/SisyphusAeolides/ArachOS
Source0:        ArachOS.png
BuildArch:      noarch

# Fedora packages use this capability as a minimum package-ecosystem ABI
# guard.  Keep the public ArachOS version independent from the selected
# bootstrap repository while advertising the compatible Fedora package level.
Provides:       system-release = %{?arachos_bootstrap_release}%{!?arachos_bootstrap_release:45}-%{release}
Provides:       system-release(releasever) = %{?arachos_releasever}%{!?arachos_releasever:1}
Provides:       system-logos = %{version}-%{release}

# Replace the bootstrap release packages as one transaction.  Keeping these
# packages installed would leave the target with conflicting identity files
# and Fedora release metadata after the ArachOS package is installed.
Obsoletes:      fedora-release
Obsoletes:      fedora-release-common
Obsoletes:      fedora-logos
Obsoletes:      fedora-release-identity-basic
Obsoletes:      fedora-release-identity-cloud
Obsoletes:      fedora-release-identity-container
Obsoletes:      fedora-release-identity-coreos
Obsoletes:      fedora-release-identity-iot
Obsoletes:      fedora-release-identity-kde
Obsoletes:      fedora-release-identity-server
Obsoletes:      fedora-release-identity-silverblue
Obsoletes:      fedora-release-identity-workstation

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
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/boot/splash.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/sidebar-logo.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/anaconda_header.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/sidebar-bg.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/anaconda/pixmaps/topbar-bg.png
install -Dpm0644 %{SOURCE0} %{buildroot}%{_datadir}/icons/hicolor/48x48/apps/system-logo-icon.png

install -d -m0755 %{buildroot}%{_sysconfdir}/anaconda/profile.d
cat > %{buildroot}%{_sysconfdir}/anaconda/profile.d/z-arachos.conf <<'EOF'
# Anaconda configuration for ArachOS.

[Profile]
profile_id = arachos

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
webui_web_engine = firefox

[Payload]
enable_closest_mirror = False
default_source = CLOSEST_MIRROR
default_environment = custom-environment
updates_repositories =
default_rpm_gpg_keys =

[License]
eula = /usr/share/licenses/arachos-release/LICENSE
EOF

install -Dpm0644 /dev/stdin %{buildroot}%{_usr}/share/anaconda/pixmaps/arachos.css <<'EOF'
/* ArachOS installer palette and product artwork. */
@define-color arachos #10131f;
@define-color arachos-accent #7148ff;

/* Keep the complete Anaconda sidebar contract in the product image. The
 * bootstrap stylesheet is deliberately not inherited: these selectors own
 * the visible installer chrome and all point at ArachOS artwork. */
.logo-sidebar {
    background-image: url('/usr/share/anaconda/pixmaps/sidebar-bg.png');
    background-color: @arachos;
    background-repeat: no-repeat;
    background-size: 100% 100%;
}

.logo {
    background-image: url('/usr/share/anaconda/pixmaps/sidebar-logo.png');
    background-position: 50% 20px;
    background-repeat: no-repeat;
    background-color: transparent;
    background-size: 96px 96px;
}

.product-logo {
    background-image: url('/usr/share/pixmaps/system-logo-white.png');
    background-position: 50% 50%;
    background-repeat: no-repeat;
    background-color: transparent;
    background-size: 96px 96px;
}

AnacondaSpokeWindow #nav-box {
    background-color: @arachos;
    background-image: url('/usr/share/anaconda/pixmaps/topbar-bg.png');
    background-repeat: no-repeat;
    background-size: 132px 132px;
    color: #ffffff;
}

window, dialog {
    background-color: @arachos;
    color: #e9ecff;
}

headerbar {
    background-color: #171d36;
    color: #ffffff;
}

button.suggested-action {
    background-color: @arachos-accent;
    color: #ffffff;
}
EOF

install -Dpm0644 /dev/stdin %{buildroot}%{_usr}/lib/os-release <<'EOF'
NAME="ArachOS"
ID=arachos
VERSION="%{version}"
VERSION_ID="%{version}"
PLATFORM_ID="platform:arachos"
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
%{_usr}/share/anaconda/boot/splash.png
%{_usr}/share/anaconda/boot/syslinux-splash.png
%{_usr}/share/anaconda/pixmaps/anaconda_header.png
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

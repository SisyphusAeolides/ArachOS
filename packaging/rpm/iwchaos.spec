Name:           iwchaos
Version:        %{?iwchaos_version}%{!?iwchaos_version:0.2.4}
Release:        1%{?dist}
Summary:        Target-kernel Intel Wi-Fi modules with a bounded rate policy

License:        GPL-2.0-only
URL:            https://github.com/SisyphusAeolides/iwchaos
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# The package is a DKMS source bundle.  These dependencies are the toolchain
# used by the DKMS build for the selected installed kernel and by iwchaos's
# target-kernel source selector.
Requires:       binutils
Requires:       cargo
Requires:       curl
Requires:       dkms
Requires:       gcc
Requires:       git
Requires:       kernel-devel
Requires:       make
Requires:       python3
Requires:       rust

%description
Target-kernel-compatible Intel iwlwifi, iwlmvm, and iwldvm DKMS modules with a
small bounded fixed-point rate-policy advisory.  The upstream transport and
firmware interface remain authoritative; the distribution firmware package is
used unchanged.

%prep
%autosetup -n %{name}-%{version}

%build

%install
install -d %{buildroot}/usr/src/%{name}-%{version}
cp -a . %{buildroot}/usr/src/%{name}-%{version}/
install -Dm0644 LICENSE %{buildroot}/usr/share/licenses/%{name}/LICENSE
rm -rf %{buildroot}/usr/src/%{name}-%{version}/.git
rm -rf %{buildroot}/usr/src/%{name}-%{version}/vendor
rm -rf %{buildroot}/usr/src/%{name}-%{version}/rust/target
rm -rf %{buildroot}/usr/src/%{name}-%{version}/rust/.ar-extract
find %{buildroot}/usr/src/%{name}-%{version} -type f \
  \( -name '*.o' -o -name '*.ko' -o -name '*.cmd' -o -name '*.d' \) -delete

%post
if command -v dkms >/dev/null 2>&1; then
  if [ ! -f "/var/lib/dkms/%{name}/%{version}/source/dkms.conf" ]; then
    dkms add -m %{name} -v %{version} --rpm_safe_upgrade || :
  fi
  dkms autoinstall -m %{name} -v %{version} --force --rpm_safe_upgrade || :
fi

%preun
if [ "$1" -eq 0 ] && command -v dkms >/dev/null 2>&1; then
  dkms remove -m %{name} -v %{version} --all --rpm_safe_upgrade || :
fi

%files
/usr/src/%{name}-%{version}/
/usr/share/licenses/%{name}/LICENSE

%changelog
* Tue Sep 01 2026 Sisyphus Aeolides <SisyphusAeolides@pm.me> - 0.2.4-1
- Package the target-kernel DKMS source for ArachOS installation

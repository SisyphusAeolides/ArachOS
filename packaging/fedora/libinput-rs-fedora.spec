Name:           libinput-rs
Version:        0.3.15
Release:        1%{?dist}
Summary:        Rust libinput implementation for ArachOS
License:        MIT AND Unicode-3.0
URL:            https://github.com/SisyphusAeolides/libinput-rs
Source0:        libinput-rs-%{version}.tar.gz
Source1:        libinput-rs-elan-resume.service

Provides:       libinput = 1.31.3
Provides:       libinput%{?_isa} = 1.31.3
Provides:       libinput-devel = 1.31.3
Provides:       libinput-devel%{?_isa} = 1.31.3
Obsoletes:      libinput < 1.32.0

BuildRequires:  cargo >= 1.75
BuildRequires:  rust >= 1.75
BuildRequires:  gcc
BuildRequires:  gcc-gfortran
BuildRequires:  make
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  patch
BuildRequires:  pkgconfig(libevdev)
BuildRequires:  pkgconfig(mtdev)
BuildRequires:  liburing-devel
BuildRequires:  python3
Requires:       python3-libevdev
Requires:       python3-pyudev
Requires:       python3-pyyaml
Requires:       rustd-compat-libs

%description
Rust libinput ABI, tools, udev helpers, and quirks installed for ArachOS.
The resume service is placed in RustD's native unit root.

%prep
%autosetup -n libinput-rs-%{version}
test -f Cargo.lock

%build
make build shared

%install
make install DESTDIR=%{buildroot} PREFIX=%{_prefix} LIBDIR=%{_libdir} \
  RPM_TOPDIR=%{_topdir}
rm -rf %{buildroot}%{_prefix}/lib/systemd
install -Dm0644 %{SOURCE1} %{buildroot}%{_prefix}/lib/rustd/system/libinput-rs-elan-resume.service

%check
cargo test --frozen --locked --workspace
test -e %{buildroot}%{_libdir}/libinput.so.10
test ! -e %{buildroot}%{_prefix}/lib/systemd

%files
%license LICENSE
%doc README.md
%{_bindir}/libinput
%{_bindir}/libinput-rs
%{_bindir}/libinput-rs-chwd
%{_libexecdir}/libinput/
%{_prefix}/lib/udev/libinput-device-group
%{_prefix}/lib/udev/libinput-fuzz-extract
%{_prefix}/lib/udev/libinput-fuzz-to-zero
%{_udevrulesdir}/80-libinput-device-groups.rules
%{_udevrulesdir}/90-libinput-fuzz-override.rules
%{_udevrulesdir}/90-libinput-rs-elantech-crc.rules
%{_prefix}/lib/rustd/system/libinput-rs-elan-resume.service
%{_datadir}/libinput/*.quirks
%{_libdir}/libinput.so.10.13.0
%{_libdir}/libinput.so.10
%{_libdir}/libinput.so
%{_includedir}/libinput.h
%{_libdir}/pkgconfig/libinput.pc
%{_mandir}/man1/*.1.*
%{_mandir}/man8/*.8.*
%{_datadir}/zsh/site-functions/_libinput

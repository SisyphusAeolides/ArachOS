Name:           tuned-rs
Version:        0.3.0
Release:        1%{?dist}
Summary:        Rust TuneD implementation for ArachOS
License:        GPL-2.0-or-later AND MIT AND Apache-2.0
URL:            https://github.com/SisyphusAeolides/tuned-rs
Source0:        tuned-rs-%{version}.tar.gz
Source1:        tuned-rs.service
Source2:        tuned-rs-ppd.service

Provides:       tuned = %{version}-%{release}
Provides:       tuned%{?_isa} = %{version}-%{release}
Provides:       tuned-ppd = %{version}-%{release}
Provides:       tuned-ppd%{?_isa} = %{version}-%{release}
Obsoletes:      tuned < %{version}-%{release}
Obsoletes:      power-profiles-daemon < %{version}-%{release}

BuildRequires:  cargo >= 1.75
BuildRequires:  rust >= 1.75
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  dbus-devel
Requires:       dbus
Requires:       polkit
Requires:       rustd >= 0.1.2

%description
Rust TuneD and power-profile services installed in the RustD unit namespace.
The package keeps the standard D-Bus interfaces while RustD owns service startup,
restart, and lifecycle management.

%prep
%autosetup -n tuned-rs-%{version}
test -f Cargo.lock

%build
CARGO_NET_OFFLINE=true CARGO_PROFILE_RELEASE_DEBUG=2 cargo build --frozen --release --locked

%install
make install-bin DESTDIR=%{buildroot} BINDIR=%{_bindir} SBINDIR=%{_sbindir}
make install-config DESTDIR=%{buildroot} ETCTUNEDDIR=%{_sysconfdir}/tuned
make install-profiles DESTDIR=%{buildroot} PROFILEDIR=%{_prefix}/lib/tuned
install -Dm0644 %{SOURCE1} %{buildroot}%{_prefix}/lib/rustd/system/tuned-rs.service
install -Dm0644 %{SOURCE2} %{buildroot}%{_prefix}/lib/rustd/system/tuned-rs-ppd.service
install -Dm0644 README.md %{buildroot}%{_docdir}/%{name}/README.md
install -Dm0644 packaging/com.redhat.tuned.conf %{buildroot}%{_datadir}/dbus-1/system.d/com.redhat.tuned.conf
install -Dm0644 packaging/com.redhat.tuned.service %{buildroot}%{_datadir}/dbus-1/system-services/com.redhat.tuned.service
install -Dm0644 packaging/com.redhat.tuned.policy %{buildroot}%{_datadir}/polkit-1/actions/com.redhat.tuned.policy
install -Dm0644 packaging/org.freedesktop.UPower.PowerProfiles.conf %{buildroot}%{_datadir}/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf
install -Dm0644 packaging/org.freedesktop.UPower.PowerProfiles.service %{buildroot}%{_datadir}/dbus-1/system-services/org.freedesktop.UPower.PowerProfiles.service
install -Dm0644 packaging/net.hadess.PowerProfiles.service %{buildroot}%{_datadir}/dbus-1/system-services/net.hadess.PowerProfiles.service
install -Dm0644 packaging/org.freedesktop.UPower.PowerProfiles.policy %{buildroot}%{_datadir}/polkit-1/actions/org.freedesktop.UPower.PowerProfiles.policy
install -Dm0644 packaging/net.hadess.PowerProfiles.policy %{buildroot}%{_datadir}/polkit-1/actions/net.hadess.PowerProfiles.policy

%check
CARGO_NET_OFFLINE=true cargo test --frozen --locked --all-targets

%post
if [ -x %{_bindir}/rustctl ]; then
    %{_bindir}/rustctl enable tuned-rs.service tuned-rs-ppd.service >/dev/null 2>&1 || :
fi

%files
%license LICENSE
%doc %{_docdir}/%{name}/README.md
%{_bindir}/tuned-rs
%{_bindir}/tuned-rs-ppd
%{_bindir}/tuned-rs-gui
%{_sbindir}/tuned
%{_sbindir}/tuned-adm
%{_sbindir}/tuned-ppd
%{_prefix}/lib/rustd/system/tuned-rs.service
%{_prefix}/lib/rustd/system/tuned-rs-ppd.service
%{_sysconfdir}/tuned/
%{_prefix}/lib/tuned/
%{_datadir}/dbus-1/system.d/com.redhat.tuned.conf
%{_datadir}/dbus-1/system-services/com.redhat.tuned.service
%{_datadir}/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf
%{_datadir}/dbus-1/system-services/org.freedesktop.UPower.PowerProfiles.service
%{_datadir}/dbus-1/system-services/net.hadess.PowerProfiles.service
%{_datadir}/polkit-1/actions/com.redhat.tuned.policy
%{_datadir}/polkit-1/actions/org.freedesktop.UPower.PowerProfiles.policy
%{_datadir}/polkit-1/actions/net.hadess.PowerProfiles.policy

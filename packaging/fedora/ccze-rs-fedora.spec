Name:           ccze-rs
Version:        0.5.4
Release:        1%{?dist}
Summary:        Rust streaming log colorizer
License:        MIT
URL:            https://github.com/SisyphusAeolides/ccze-rs
Source0:        ccze-rs-%{version}.tar.gz
BuildRequires:  cargo >= 1.75
BuildRequires:  rust >= 1.75
BuildRequires:  gcc
BuildRequires:  gcc-gfortran
Provides:       ccze = %{version}-%{release}
Obsoletes:      ccze < %{version}-%{release}
# The tiny Rust executable has no source files discoverable by
# find-debuginfo on EL9/EL10; suppress an otherwise empty debugsource
# subpackage rather than making the binary build fail.
%global debug_package %{nil}

%description
Streaming log colorizer with native analytics and bounded parsing.

%prep
%autosetup -n ccze-rs-%{version}

%build
CCZE_FORCE_FORTRAN=1 CARGO_NET_OFFLINE=true CARGO_PROFILE_RELEASE_DEBUG=2 cargo build --frozen --release --locked

%install
install -Dm0755 target/release/ccze %{buildroot}%{_bindir}/ccze
install -Dm0644 packaging/ccze.1 %{buildroot}%{_mandir}/man1/ccze.1

%check
CCZE_FORCE_FORTRAN=1 cargo test --frozen --locked --all-targets

%files
%license LICENSE
%doc README.md ARCHITECTURE.md
%{_bindir}/ccze
%{_mandir}/man1/ccze.1*

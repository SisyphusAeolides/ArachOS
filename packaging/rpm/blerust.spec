Name:           blerust
Version:        0.1.16
Release:        1%{?dist}
Summary:        Rust line editor
License:        MIT
URL:            https://github.com/SisyphusAeolides/blerust
Source0:        blerust-%{version}.tar.gz
Provides:       blesh = %{version}-%{release}
Obsoletes:      blesh < %{version}-%{release}
BuildRequires:  cargo
BuildRequires:  rust

%description
Blazing fast and robust line editor installed without shell-profile mutation.

%prep
%autosetup -n blerust-%{version}

%build
CARGO_PROFILE_RELEASE_DEBUG=2 cargo build --frozen --release --locked

%install
install -Dm0755 target/release/blerust %{buildroot}%{_bindir}/blerust

%check
cargo test --frozen --locked --all-targets

%files
%doc README.md
%{_bindir}/blerust

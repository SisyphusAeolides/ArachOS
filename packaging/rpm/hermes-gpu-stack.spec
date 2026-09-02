Name:           hermes-gpu-stack
Version:        0.1.0
Release:        1%{?dist}
Summary:        Hardware-qualified multi-vendor GPU and GSP compatibility stack
License:        MIT
URL:            https://github.com/SisyphusAeolides/Hermes
Source0:        hermes-%{version}.tar.gz
Source1:        hermes-gpu.service

BuildRequires:  cargo >= 1.85
BuildRequires:  rust >= 1.85
BuildRequires:  gcc
BuildRequires:  gawk
BuildRequires:  make
Requires:       rustd >= 0.1.2
Requires:       kmod

Provides:       libcuda.so.1()(64bit)
Provides:       libcudart.so.12()(64bit)
Provides:       libnvidia-ml.so.1()(64bit)
Provides:       libnvidia-cfg.so.1()(64bit)
Provides:       libGLX_nvidia.so.0()(64bit)
Provides:       libEGL_nvidia.so.0()(64bit)

# The release artifacts are stripped Rust binaries and shared objects.  Some
# RPM build environments otherwise create an empty debug-source subpackage and reject
# the otherwise complete package.
%global debug_package %{nil}

%description
Hermes is the ArachOS GPU/GSP compatibility layer. It packages the Rust
control and management tools, NVIDIA-compatible CUDA/NVML/Mesa library
surfaces, and the source for its Linux kernel modules. Firmware remains an
operator-staged input and is never shipped in this RPM. The Hermes service is
installed in RustD's native unit namespace. This package is release-qualified
only when the physical-GPU and runtime-surface qualification manifest passes;
unit tests and simulation do not certify a production GPU stack.

%prep
%autosetup -n hermes-%{version}
test -f Cargo.lock

%build
export CARGO_NET_OFFLINE=true
cargo build --frozen --release --locked \
    -p hermes-ctl \
    -p hermes-settings \
    -p hermes-nvml \
    -p hermes-cuda \
    -p hermes-mesa

%install
install -Dm0755 target/release/hermes-ctl \
    %{buildroot}%{_bindir}/hermes-ctl
install -Dm0755 target/release/nvidia-smi \
    %{buildroot}%{_bindir}/nvidia-smi
install -Dm0755 target/release/nvidia-modprobe \
    %{buildroot}%{_bindir}/nvidia-modprobe
install -Dm0755 target/release/nvidia-persistenced \
    %{buildroot}%{_bindir}/nvidia-persistenced
install -Dm0755 target/release/nvidia-cuda-mps-control \
    %{buildroot}%{_bindir}/nvidia-cuda-mps-control
install -Dm0755 target/release/nvidia-debugdump \
    %{buildroot}%{_bindir}/nvidia-debugdump
install -Dm0755 target/release/nvidia-settings \
    %{buildroot}%{_bindir}/nvidia-settings
install -Dm0755 target/release/libnvidia_ml.so \
    %{buildroot}%{_libdir}/libnvidia_ml.so
install -Dm0755 target/release/libhermes_cuda.so \
    %{buildroot}%{_libdir}/libhermes_cuda.so
install -Dm0755 target/release/libhermes_mesa.so \
    %{buildroot}%{_libdir}/libhermes_mesa.so

ln -s libnvidia_ml.so %{buildroot}%{_libdir}/libnvidia-ml.so.1
ln -s libnvidia_ml.so %{buildroot}%{_libdir}/libnvidia-ml.so
ln -s libnvidia_ml.so %{buildroot}%{_libdir}/libnvidia-cfg.so.1
ln -s libnvidia_ml.so %{buildroot}%{_libdir}/libnvidia-cfg.so
ln -s libhermes_cuda.so %{buildroot}%{_libdir}/libcuda.so.1
ln -s libhermes_cuda.so %{buildroot}%{_libdir}/libcuda.so
ln -s libhermes_cuda.so %{buildroot}%{_libdir}/libcudart.so.12
ln -s libhermes_cuda.so %{buildroot}%{_libdir}/libcudart.so
ln -s libhermes_mesa.so %{buildroot}%{_libdir}/libGLX_nvidia.so.0
ln -s libhermes_mesa.so %{buildroot}%{_libdir}/libEGL_nvidia.so.0

install -d %{buildroot}%{_datadir}/vulkan/icd.d
install -d %{buildroot}%{_sysconfdir}/vulkan/icd.d
cat > %{buildroot}%{_datadir}/vulkan/icd.d/hermes_icd.json <<EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "%{_libdir}/libhermes_mesa.so",
        "api_version": "1.3.0"
    }
}
EOF
cp %{buildroot}%{_datadir}/vulkan/icd.d/hermes_icd.json \
    %{buildroot}%{_sysconfdir}/vulkan/icd.d/hermes_icd.json
cp %{buildroot}%{_datadir}/vulkan/icd.d/hermes_icd.json \
    %{buildroot}%{_datadir}/vulkan/icd.d/nvidia_icd.json

install -d %{buildroot}%{_datadir}/glvnd/egl_vendor.d
cat > %{buildroot}%{_datadir}/glvnd/egl_vendor.d/10_nvidia.json <<EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "%{_libdir}/libEGL_nvidia.so.0"
    }
}
EOF

install -d %{buildroot}%{_datadir}/hermes
target/release/hermes-ctl dropin-catalog \
    > %{buildroot}%{_datadir}/hermes/DROPIN_CATALOG.txt
cat > %{buildroot}%{_datadir}/hermes/DROPIN_MANIFEST.txt <<EOF
Hermes GPU compatibility stack
named_surfaces=30
gsp_online=hardware-and-firmware-qualified
firmware=operator-staged; not included in this RPM
kmod_source=%{_prefix}/src/hermes-gpu-kmod-%{version}
service=%{_prefix}/lib/rustd/system/hermes-gpu.service
EOF

install -Dm0644 %{SOURCE1} \
    %{buildroot}%{_prefix}/lib/rustd/system/hermes-gpu.service

kmod_root=%{buildroot}%{_prefix}/src/hermes-gpu-kmod-%{version}
install -d "$kmod_root/include" "$kmod_root/tests"
install -Dm0644 linux/kmod/Makefile "$kmod_root/Makefile"
install -Dm0644 linux/kmod/README.md "$kmod_root/README.md"
for source in linux/kmod/*.c; do
    install -Dm0644 "$source" "$kmod_root/$(basename "$source")"
done
for header in linux/kmod/include/*.h; do
    install -Dm0644 "$header" "$kmod_root/include/$(basename "$header")"
done
for test_source in linux/kmod/tests/*.c; do
    install -Dm0644 "$test_source" "$kmod_root/tests/$(basename "$test_source")"
done

%check
export CARGO_NET_OFFLINE=true
cargo test --frozen --locked --workspace
make -C linux/kmod CC=gcc all
make -C linux/kmod host-test
make -C formal/fortran check

%post
if [ -x %{_bindir}/rustctl ]; then
    %{_bindir}/rustctl enable hermes-gpu.service >/dev/null 2>&1 || :
fi

%files
%license LICENSE
%doc README.md docs/DROP_IN.md docs/DRM_MESA.md docs/CCCL_CUDA.md
%{_bindir}/hermes-ctl
%{_bindir}/nvidia-smi
%{_bindir}/nvidia-modprobe
%{_bindir}/nvidia-persistenced
%{_bindir}/nvidia-cuda-mps-control
%{_bindir}/nvidia-debugdump
%{_bindir}/nvidia-settings
%{_libdir}/libnvidia_ml.so
%{_libdir}/libnvidia-ml.so
%{_libdir}/libnvidia-ml.so.1
%{_libdir}/libnvidia-cfg.so
%{_libdir}/libnvidia-cfg.so.1
%{_libdir}/libhermes_cuda.so
%{_libdir}/libcuda.so
%{_libdir}/libcuda.so.1
%{_libdir}/libcudart.so
%{_libdir}/libcudart.so.12
%{_libdir}/libhermes_mesa.so
%{_libdir}/libGLX_nvidia.so.0
%{_libdir}/libEGL_nvidia.so.0
%{_sysconfdir}/vulkan/icd.d/hermes_icd.json
%{_datadir}/vulkan/icd.d/hermes_icd.json
%{_datadir}/vulkan/icd.d/nvidia_icd.json
%{_datadir}/glvnd/egl_vendor.d/10_nvidia.json
%{_datadir}/hermes/
%{_prefix}/lib/rustd/system/hermes-gpu.service
%{_prefix}/src/hermes-gpu-kmod-%{version}/

#!/usr/bin/env bash
set -Eeuo pipefail

RPM_REPO=${1:?usage: sign-rpm-repo.sh RPM_REPO}
GPG_HOME=${ARACHOS_GPG_HOME:-}
GPG_KEY_ID=${ARACHOS_GPG_KEY_ID:-}

fail() { printf 'ArachOS RPM signing: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

need rpmsign
need rpm
need gpg
[[ -d $RPM_REPO ]] || fail "RPM repository is missing: $RPM_REPO"
[[ -n $GPG_HOME ]] || fail 'ARACHOS_GPG_HOME is required for a signed repository'
[[ -d $GPG_HOME ]] || fail "GPG home is missing: $GPG_HOME"
[[ -n $GPG_KEY_ID ]] || fail 'ARACHOS_GPG_KEY_ID is required for a signed repository'

mapfile -d '' rpm_files < <(
    find "$RPM_REPO" -maxdepth 1 -type f -name '*.rpm' -print0 | sort -z
)
(( ${#rpm_files[@]} > 0 )) || fail 'repository contains no RPM packages'

for rpm_path in "${rpm_files[@]}"; do
    GNUPGHOME="$GPG_HOME" rpmsign --resign --key-id "$GPG_KEY_ID" "$rpm_path"
    signature_bytes=$(rpm -qp --qf '%{RSAHEADER}' "$rpm_path")
    [[ -n $signature_bytes && $signature_bytes != '(none)' ]] || fail \
        "RPM remains unsigned: $(basename "$rpm_path")"
done

GNUPGHOME="$GPG_HOME" gpg --batch --yes --armor --export "$GPG_KEY_ID" \
    > "$RPM_REPO/RPM-GPG-KEY-ARACHOS"
[[ -s $RPM_REPO/RPM-GPG-KEY-ARACHOS ]] || fail 'public signing key was not exported'

fingerprint=$(GNUPGHOME="$GPG_HOME" gpg --batch --with-colons --fingerprint "$GPG_KEY_ID" \
    | awk -F: '$1 == "fpr" {print $10; exit}')
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || fail 'could not determine signing-key fingerprint'
printf 'signed %d RPMs with ArachOS key %s\n' "${#rpm_files[@]}" "$fingerprint"

#!/usr/bin/env bash
# Sign all packages in the ArachOS pacman repository.
set -Eeuo pipefail

PKG_REPO="${1:?usage: sign-pkg-repo.sh PKG_REPO}"
GPG_HOME="${ARACHOS_GPG_HOME:-}"
GPG_KEY_ID="${ARACHOS_GPG_KEY_ID:-}"

fail() { printf 'ArachOS pkg signing: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

need gpg
need repo-add

[[ -d "$PKG_REPO" ]] || fail "package repository is missing: $PKG_REPO"
[[ -n "$GPG_HOME" ]]   || fail 'ARACHOS_GPG_HOME is required'
[[ -d "$GPG_HOME" ]]   || fail "GPG home is missing: $GPG_HOME"
[[ -n "$GPG_KEY_ID" ]] || fail 'ARACHOS_GPG_KEY_ID is required'

mapfile -d '' pkg_files < <(
  find "$PKG_REPO" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0 | sort -z
)
(( ${#pkg_files[@]} > 0 )) || fail 'repository contains no packages'

for pkg_path in "${pkg_files[@]}"; do
  GNUPGHOME="$GPG_HOME" gpg --batch --yes --armor --detach-sign \
    --default-key "$GPG_KEY_ID" \
    --output "${pkg_path}.sig" "$pkg_path"
  [[ -s "${pkg_path}.sig" ]] || fail "package signature missing: $(basename "$pkg_path")"
done

GNUPGHOME="$GPG_HOME" gpg --batch --yes --armor --export "$GPG_KEY_ID" \
  > "$PKG_REPO/ArachOS-GPG-KEY"
[[ -s "$PKG_REPO/ArachOS-GPG-KEY" ]] || fail 'public signing key was not exported'

fingerprint=$(GNUPGHOME="$GPG_HOME" gpg --batch --with-colons \
  --fingerprint "$GPG_KEY_ID" | awk -F: '$1 == "fpr" {print $10; exit}')
[[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || fail 'could not determine signing-key fingerprint'
printf 'signed %d packages with ArachOS key %s\n' "${#pkg_files[@]}" "$fingerprint"

# Re-add all signed packages to the repo database with signing
pushd "$PKG_REPO" >/dev/null
GNUPGHOME="$GPG_HOME" repo-add -s -n arachos.db.tar.gz *.pkg.tar.zst
popd >/dev/null

#!/usr/bin/env bash
# Generate release-manifest.json and SHA256SUMS from the final, immutable artifacts in a directory.
# Filenames encode the compatibility dimensions; anything unrecognised is an error.
#
#   make-release-manifest.sh DIST_DIR EXTENSION_VERSION [REPO]
set -Eeuo pipefail

dist=${1:?dist dir}; version=${2:?extension version}; repo=${3:-secp256k1-sha256/adaptive_autovacuum}
tag="v$version"
base="https://github.com/$repo/releases/download/$tag"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

artifacts='[]'
for f in "$dist"/*.deb "$dist"/*.rpm "$dist"/*.zip; do
    [[ -f $f ]] || continue
    name=$(basename "$f"); sha=$(sha256sum "$f" | cut -d' ' -f1); size=$(stat -c %s "$f")
    case "$name" in
        *-debuginfo-*|*-debugsource-*|*-dbgsym_*) echo "skipping debug package $name" >&2; continue ;;
        # adaptive_autovacuum-1.2.0.zip : PGXN source distribution, not an installer artifact (listed in SHA256SUMS only)
        adaptive_autovacuum-[0-9]*.zip)
            [[ $name == *-pg*-windows-* ]] || { echo "source distribution $name: checksummed, not in the manifest" >&2; continue; } ;;&
        # adaptive-autovacuum-setup-1.2.0-1.el9.noarch.rpm : helper shared by every major (postgres_major 0 = any)
        adaptive-autovacuum-setup-*.noarch.rpm)
            [[ $name =~ ^adaptive-autovacuum-setup-[^-]+-[0-9]+\.(el[0-9]+)\.noarch\.rpm$ ]] || { echo "unrecognised helper rpm name: $name" >&2; exit 1; }
            rec=$(jq -n --arg n "$name" --arg u "$base/$name" --arg s "$sha" --argjson z "$size" --arg d "${BASH_REMATCH[1]}" \
                  '{artifact_filename:$n, artifact_url:$u, sha256:$s, size_bytes:$z, postgres_major:0, operating_system:"linux", distribution:$d, architecture:"noarch", package_type:"rpm", component:"setup-helper"}') ;;
        # adaptive-autovacuum-setup_1.2.0-1_all.deb : helper shared by every major and Ubuntu release
        adaptive-autovacuum-setup_*_all.deb)
            [[ $name =~ ^adaptive-autovacuum-setup_[^_]+_all\.deb$ ]] || { echo "unrecognised helper deb name: $name" >&2; exit 1; }
            rec=$(jq -n --arg n "$name" --arg u "$base/$name" --arg s "$sha" --argjson z "$size" \
                  '{artifact_filename:$n, artifact_url:$u, sha256:$s, size_bytes:$z, postgres_major:0, operating_system:"linux", architecture:"all", package_type:"deb", component:"setup-helper"}') ;;
        # postgresql-18-adaptive-autovacuum_1.2.0-1_ubuntu24.04_amd64.deb
        postgresql-*-adaptive-autovacuum_*_*_*.deb)
            [[ $name =~ ^postgresql-([0-9]+)-adaptive-autovacuum_([^_]+)_([a-z]+[0-9.]+)_([a-z0-9]+)\.deb$ ]] || { echo "unrecognised deb name: $name" >&2; exit 1; }
            rec=$(jq -n --arg n "$name" --arg u "$base/$name" --arg s "$sha" --argjson z "$size" --argjson m "${BASH_REMATCH[1]}" --arg d "${BASH_REMATCH[3]}" --arg a "${BASH_REMATCH[4]}" \
                  '{artifact_filename:$n, artifact_url:$u, sha256:$s, size_bytes:$z, postgres_major:$m, operating_system:"linux", distribution:$d, architecture:$a, package_type:"deb"}') ;;
        # postgresql18-adaptive-autovacuum-1.2.0-1.el9.x86_64.rpm
        postgresql*-adaptive-autovacuum-*.rpm)
            [[ $name =~ ^postgresql([0-9]+)-adaptive-autovacuum-[^-]+-[0-9]+\.(el[0-9]+)\.([a-z0-9_]+)\.rpm$ ]] || { echo "unrecognised rpm name: $name" >&2; exit 1; }
            rec=$(jq -n --arg n "$name" --arg u "$base/$name" --arg s "$sha" --argjson z "$size" --argjson m "${BASH_REMATCH[1]}" --arg d "${BASH_REMATCH[2]}" --arg a "${BASH_REMATCH[3]}" \
                  '{artifact_filename:$n, artifact_url:$u, sha256:$s, size_bytes:$z, postgres_major:$m, operating_system:"linux", distribution:$d, architecture:$a, package_type:"rpm"}') ;;
        # adaptive_autovacuum-1.2.0-pg18-windows-x64.zip
        adaptive_autovacuum-*-pg*-windows-*.zip)
            [[ $name =~ ^adaptive_autovacuum-[^-]+-pg([0-9]+)-windows-([a-z0-9]+)\.zip$ ]] || { echo "unrecognised zip name: $name" >&2; exit 1; }
            rec=$(jq -n --arg n "$name" --arg u "$base/$name" --arg s "$sha" --argjson z "$size" --argjson m "${BASH_REMATCH[1]}" --arg a "${BASH_REMATCH[2]}" \
                  '{artifact_filename:$n, artifact_url:$u, sha256:$s, size_bytes:$z, postgres_major:$m, operating_system:"windows", architecture:$a, package_type:"zip"}') ;;
        *) echo "unrecognised artifact name: $name" >&2; exit 1 ;;
    esac
    artifacts=$(jq --argjson r "$rec" '. + [$r]' <<<"$artifacts")
done
[[ $(jq length <<<"$artifacts") -gt 0 ]] || { echo "no artifacts found in $dist" >&2; exit 1; }

jq -n --arg v "$version" --arg t "$tag" --argjson a "$artifacts" \
   '{schema_version:1, extension_version:$v, package_revision:1, minimum_installer_version:"1.2.0", published_at:(now|todate), release_tag:$t, artifacts:$a}' \
   >"$dist/release-manifest.json"
(cd "$dist" && sha256sum -- *.deb *.rpm *.zip release-manifest.json install.sh install.ps1 2>/dev/null | grep -v '^[0-9a-f]* *$' >SHA256SUMS || true)
echo "wrote $dist/release-manifest.json ($(jq '.artifacts|length' "$dist/release-manifest.json") artifacts) and $dist/SHA256SUMS"

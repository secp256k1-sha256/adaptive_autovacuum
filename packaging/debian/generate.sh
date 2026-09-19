#!/usr/bin/env bash
# Materialise debian/ for one PostgreSQL major from the templates in packaging/debian.
#   packaging/debian/generate.sh 18 [OUTDIR]    -> OUTDIR/debian (default ./debian)
# Produces two binary packages: postgresql-<major>-adaptive-autovacuum (arch any) and
# adaptive-autovacuum-setup (arch all, identical for every major).
set -Eeuo pipefail
major=${1:?PostgreSQL major}
out=${2:-.}/debian
here=$(cd "$(dirname "$0")" && pwd)
[[ $major =~ ^[0-9]+$ ]] || { echo "major must be a number" >&2; exit 2; }
rm -rf "$out"; mkdir -p "$out/source"
for f in control changelog; do sed "s/@PGMAJOR@/$major/g" "$here/$f.in" >"$out/$f"; done
# Maintainer scripts belong to the extension package (multi-binary source: <pkg>.postinst).
sed "s/@PGMAJOR@/$major/g" "$here/postinst" >"$out/postgresql-$major-adaptive-autovacuum.postinst"
cp "$here/prerm" "$out/postgresql-$major-adaptive-autovacuum.prerm"
chmod 755 "$out"/*.postinst "$out"/*.prerm
cp "$here/copyright" "$out/copyright"
cp "$here/source/format" "$out/source/format"
# The shebang must stay on line 1; pin PG_MAJOR right after it.
{ head -n 1 "$here/rules"; echo "PG_MAJOR := $major"; tail -n +2 "$here/rules"; } >"$out/rules"; chmod 755 "$out/rules"
echo "generated $out for PostgreSQL $major"

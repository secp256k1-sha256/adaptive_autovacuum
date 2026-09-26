#!/usr/bin/env bash
# adaptive_autovacuum bootstrap installer for Linux.
# Downloads the release manifest, selects and verifies one prebuilt package for this
# host plus the shared adaptive-autovacuum-setup package, installs both with the OS package manager, then hands over to
# adaptive-autovacuum-setup (shipped inside the package) for configuration.
#
#   curl -fsSLO https://github.com/secp256k1-sha256/adaptive_autovacuum/releases/latest/download/install.sh
#   less install.sh
#   sudo bash install.sh
set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.3.0"
readonly REPO="${AAV_REPO:-secp256k1-sha256/adaptive_autovacuum}"
readonly RELEASE_BASE="https://github.com/$REPO/releases"
# Hosts a GitHub release download may legitimately redirect to.
readonly ALLOWED_HOSTS="github.com objects.githubusercontent.com release-assets.githubusercontent.com githubusercontent.com"
readonly SUPPORTED_MAJORS="${AAV_SUPPORTED_MAJORS:-17 18}"
# shellcheck disable=SC2034  # EX_OK documents the shared contract
readonly EX_OK=0 EX_ARGS=2 EX_NO_PG=3 EX_AMBIGUOUS=4 EX_UNSUPPORTED=5 EX_DOWNLOAD=6 EX_PRIVILEGE=7 EX_CONFIG_FAILED=8

OPT_VERSION="latest" OPT_MANIFEST="" OPT_ARTIFACT_DIR="" OPT_PG_MAJOR="" OPT_CHECK=0 OPT_DRY_RUN=0 OPT_VERBOSE=0 OPT_YES=0
SETUP_ARGS=()

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options] [-- setup options]

  --version VERSION       extension release to install (default: latest)
  --pg-major N            choose the PostgreSQL major when several supported majors are installed
  --manifest FILE|URL     use this release manifest instead of the GitHub release asset
  --artifact-dir DIR      take packages from DIR instead of downloading (offline install)
  --check                 discovery and compatibility only; installs nothing
  --dry-run               print every planned change; installs nothing
  --yes                   accept prompts (package installation and the PostgreSQL restart)
  --verbose               diagnostic output
  --help

All other options (--control-database NAME, --skip-create-extension, --no-restart, --service NAME,
--data-dir PATH, --port PORT, --db-user NAME, --pgpassfile PATH, --no-enable ...) are passed to
adaptive-autovacuum-setup install. Run "adaptive-autovacuum-setup --help" for the full list.

Exit codes: 0 ok, 2 arguments, 3 no supported PostgreSQL, 4 ambiguous, 5 unsupported platform,
            6 download/integrity failure, 7 privileges, 8 installation failure
EOF
}

say() { printf '%s\n' "$*"; }
# The packaged helper first; a stale copy earlier in PATH (e.g. /usr/local/bin) must not win.
setup_bin() { if [[ -x /usr/bin/adaptive-autovacuum-setup ]]; then echo /usr/bin/adaptive-autovacuum-setup; else command -v adaptive-autovacuum-setup; fi; }
verbose() { [[ $OPT_VERBOSE -eq 1 ]] && say "[..]   $*" || true; }
die() { local c=$1; shift; printf 'ERROR: %s\n' "$*" >&2; exit "$c"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die $EX_ARGS "required command not found: $1. Install it: $2"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) OPT_VERSION=${2:?}; shift 2 ;;
            --pg-major) OPT_PG_MAJOR=${2:?}; SETUP_ARGS+=(--pg-major "$2"); shift 2 ;;
            --manifest) OPT_MANIFEST=${2:?}; shift 2 ;;
            --artifact-dir) OPT_ARTIFACT_DIR=${2:?}; shift 2 ;;
            --check) OPT_CHECK=1; shift ;;
            --dry-run) OPT_DRY_RUN=1; SETUP_ARGS+=(--dry-run); shift ;;
            --yes|-y) OPT_YES=1; SETUP_ARGS+=(--yes); shift ;;
            --verbose|-v) OPT_VERBOSE=1; SETUP_ARGS+=(--verbose); shift ;;
            --help|-h) usage; exit 0 ;;
            --) shift; SETUP_ARGS+=("$@"); break ;;
            --control-database|--database|--service|--data-dir|--cluster|--port|--host|--db-user|--pgpassfile|--pg-config|--startup-wait|--restart-timeout)
                SETUP_ARGS+=("$1" "${2:?}"); shift 2 ;;
            --skip-create-extension|--all-databases|--no-restart|--no-enable) SETUP_ARGS+=("$1"); shift ;;
            *) die $EX_ARGS "unknown option: $1 (see --help)" ;;
        esac
    done
    [[ $OPT_VERSION == latest || $OPT_VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die $EX_ARGS "--version must look like 1.3.0"
    OPT_VERSION=${OPT_VERSION#v}
    [[ -z $OPT_PG_MAJOR || $OPT_PG_MAJOR =~ ^[0-9]+$ ]] || die $EX_ARGS "--pg-major must be a number"
    [[ -z $OPT_ARTIFACT_DIR || -d $OPT_ARTIFACT_DIR ]] || die $EX_ARGS "--artifact-dir is not a directory"
}

TMPDIR_AAV=""
cleanup() { [[ -n $TMPDIR_AAV && -d $TMPDIR_AAV ]] && rm -rf -- "$TMPDIR_AAV" || true; }
trap cleanup EXIT

# ------------------------------------------------------------- host facts
OS_ID="" OS_VERSION="" PKG_TYPE="" ARCH_DEB="" ARCH_RPM="" DISTRO_TAG=""
detect_host() {
    [[ -r /etc/os-release ]] || die $EX_UNSUPPORTED "cannot read /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-unknown}; OS_VERSION=${VERSION_ID:-}
    case "$(uname -m)" in
        x86_64|amd64) ARCH_DEB=amd64; ARCH_RPM=x86_64 ;;
        aarch64|arm64) ARCH_DEB=arm64; ARCH_RPM=aarch64 ;;
        *) die $EX_UNSUPPORTED "unsupported CPU architecture: $(uname -m)" ;;
    esac
    case "$OS_ID" in
        ubuntu) PKG_TYPE=deb; DISTRO_TAG="ubuntu${OS_VERSION}" ;;
        debian) PKG_TYPE=deb; DISTRO_TAG="debian${OS_VERSION}" ;;
        rhel|rocky|almalinux|centos|ol) PKG_TYPE=rpm; DISTRO_TAG="el${OS_VERSION%%.*}" ;;
        *) die $EX_UNSUPPORTED "unsupported distribution: $OS_ID $OS_VERSION (supported: Ubuntu 24.04/26.04, Debian 12/13, RHEL/Rocky/Alma 9/10)" ;;
    esac
    if [[ $PKG_TYPE == deb ]]; then need_cmd apt-get "apt"; need_cmd dpkg "dpkg"; else need_cmd dnf "dnf"; need_cmd rpm "rpm"; fi
}

# Minimal major discovery: which supported PostgreSQL majors are present on this host.
detect_pg_majors() {  # -> space separated majors
    local -A seen=() ; local p v m
    if command -v pg_lsclusters >/dev/null 2>&1; then
        while read -r v _; do [[ $v =~ ^[0-9]+$ ]] && seen[$v]=1; done < <(pg_lsclusters --no-header 2>/dev/null || true)
    fi
    for p in /usr/lib/postgresql/*/bin/pg_config /usr/pgsql-*/bin/pg_config; do
        [[ -x $p ]] || continue
        v=$("$p" --version 2>/dev/null | sed -n 's/^PostgreSQL \([0-9]*\).*/\1/p'); [[ -n $v ]] && seen[$v]=1
    done
    while read -r _ _ args; do
        [[ $args =~ (^|/)(postgres|postmaster)([[:space:]]|$) ]] || continue
        for p in $args; do [[ $p =~ ^/.*/(pgsql-|postgresql/)([0-9]+)/bin/ ]] && seen[${BASH_REMATCH[2]}]=1; done
    done < <(ps -eo pid=,user=,args= 2>/dev/null)
    printf '%s\n' "${!seen[@]}" | sort -n | tr '\n' ' '
}

# Majors with a running postmaster (binary path carries the major on PGDG layouts).
detect_running_majors() {
    local -A seen=(); local p args
    while read -r _ _ args; do
        [[ $args =~ (^|/)(postgres|postmaster)([[:space:]]|$) ]] || continue
        for p in $args; do [[ $p =~ ^/.*/(pgsql-|postgresql/)([0-9]+)/bin/ ]] && seen[${BASH_REMATCH[2]}]=1; done
    done < <(ps -eo pid=,user=,args= 2>/dev/null)
    printf '%s\n' "${!seen[@]}" | sort -n | tr '\n' ' '
}

choose_major() {
    local present running supported=() running_supported=() m s
    present=$(detect_pg_majors); running=$(detect_running_majors)
    verbose "PostgreSQL majors present: ${present:-none}; running: ${running:-none}"
    for m in $present; do for s in $SUPPORTED_MAJORS; do [[ $m == "$s" ]] && supported+=("$m"); done; done
    for m in $running; do for s in $SUPPORTED_MAJORS; do [[ $m == "$s" ]] && running_supported+=("$m"); done; done
    if [[ -n $OPT_PG_MAJOR ]]; then
        for s in $SUPPORTED_MAJORS; do [[ $OPT_PG_MAJOR == "$s" ]] && { PG_MAJOR=$OPT_PG_MAJOR; return; }; done
        die $EX_UNSUPPORTED "PostgreSQL $OPT_PG_MAJOR is not supported by this release (supported: $SUPPORTED_MAJORS)"
    fi
    if [[ ${#supported[@]} -eq 0 ]]; then
        die $EX_NO_PG "no supported PostgreSQL installation found (present: ${present:-none}; supported majors: $SUPPORTED_MAJORS)."
    elif [[ ${#supported[@]} -eq 1 ]]; then PG_MAJOR=${supported[0]}
    elif [[ ${#running_supported[@]} -eq 1 ]]; then PG_MAJOR=${running_supported[0]}; say "Several supported majors installed (${supported[*]}); using the running one: $PG_MAJOR"
    else die $EX_AMBIGUOUS "several supported PostgreSQL majors are installed (${supported[*]}) and ${#running_supported[@]} of them run; pass --pg-major N"
    fi
    # The helper must not pick a different cluster than the package we install.
    SETUP_ARGS+=(--pg-major "$PG_MAJOR")
}

# ------------------------------------------------------------- manifest
MANIFEST_JSON=""
fetch() {  # url dest
    local url=$1 dest=$2 effective host
    verbose "download $url"
    effective=$(curl --proto '=https' --tlsv1.2 -fsSL --max-redirs 5 -o "$dest" -w '%{url_effective}' "$url") || die $EX_DOWNLOAD "download failed: $url"
    host=$(sed -E 's#^https://([^/]+)/.*#\1#' <<<"$effective")
    local ok=0 h
    for h in $ALLOWED_HOSTS; do [[ $host == "$h" || $host == *".$h" ]] && ok=1; done
    [[ $ok -eq 1 ]] || die $EX_DOWNLOAD "download was redirected to an unexpected host: $host"
}

load_manifest() {
    local src="$OPT_MANIFEST" path="$TMPDIR_AAV/release-manifest.json"
    if [[ -z $src ]]; then
        if [[ $OPT_VERSION == latest ]]; then src="$RELEASE_BASE/latest/download/release-manifest.json"; else src="$RELEASE_BASE/download/v$OPT_VERSION/release-manifest.json"; fi
    fi
    if [[ $src == https://* ]]; then need_cmd curl "curl"; fetch "$src" "$path"; else [[ -r $src ]] || die $EX_ARGS "manifest not readable: $src"; cp -- "$src" "$path"; fi
    MANIFEST_JSON=$(jq -c . "$path" 2>/dev/null) || die $EX_DOWNLOAD "release manifest is not valid JSON"
    # Schema and allowlists: every value used in a path or command is validated here.
    jq -e '
        (.schema_version | type == "number") and
        (.extension_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.-]+)?$")) and
        (.minimum_installer_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.artifacts | type == "array" and length > 0) and
        all(.artifacts[];
            (.artifact_filename | test("^[A-Za-z0-9._+-]+$")) and
            (.artifact_url | test("^https://[A-Za-z0-9._-]+/[A-Za-z0-9._/+%-]+$")) and
            (.sha256 | test("^[0-9a-f]{64}$")) and
            (.postgres_major | type == "number") and
            (.operating_system | test("^[a-z]+$")) and
            (.architecture | test("^[a-z0-9_]+$")) and
            (.package_type | test("^(deb|rpm|zip)$")) and
            ((.distribution // "x") | test("^[A-Za-z0-9._-]+$")))' <<<"$MANIFEST_JSON" >/dev/null \
        || die $EX_DOWNLOAD "release manifest failed validation (unexpected fields or values)"
    local minver; minver=$(jq -r .minimum_installer_version <<<"$MANIFEST_JSON")
    if [[ $(printf '%s\n%s\n' "$minver" "$INSTALLER_VERSION" | sort -V | head -1) != "$minver" ]]; then
        die $EX_UNSUPPORTED "this install.sh ($INSTALLER_VERSION) is older than the release requires ($minver); download the install.sh published with the release"
    fi
    EXT_VERSION=$(jq -r .extension_version <<<"$MANIFEST_JSON")
    if [[ $OPT_VERSION != latest && $OPT_VERSION != "$EXT_VERSION" ]]; then die $EX_DOWNLOAD "manifest is for $EXT_VERSION, not the requested $OPT_VERSION"; fi
}

# Two artifacts per host: the extension package for this major and the shared setup-helper package.
select_artifact() {
    local arch; [[ $PKG_TYPE == deb ]] && arch=$ARCH_DEB || arch=$ARCH_RPM
    ARTIFACT=$(jq -c --arg t "$PKG_TYPE" --arg d "$DISTRO_TAG" --arg a "$arch" --argjson m "$PG_MAJOR" '
        [.artifacts[] | select((.component // "extension") == "extension" and .package_type == $t and .architecture == $a
                               and .postgres_major == $m and .operating_system == "linux" and ((.distribution // "") == $d))]' <<<"$MANIFEST_JSON")
    case $(jq length <<<"$ARTIFACT") in
        1) ARTIFACT=$(jq -c '.[0]' <<<"$ARTIFACT") ;;
        0) die $EX_UNSUPPORTED "release $EXT_VERSION has no package for $DISTRO_TAG/$arch/PostgreSQL $PG_MAJOR. Available: $(jq -r '[.artifacts[] | select((.component // "extension") == "extension") | "\(.distribution // .operating_system)/\(.architecture)/pg\(.postgres_major)"] | join(", ")' <<<"$MANIFEST_JSON")" ;;
        *) die $EX_DOWNLOAD "release manifest lists several packages for this host; refusing to guess" ;;
    esac
    # Helper: rpm is per distribution tag, deb is one arch-all package for every release.
    HELPER_ARTIFACT=$(jq -c --arg t "$PKG_TYPE" --arg d "$DISTRO_TAG" '
        [.artifacts[] | select(.component == "setup-helper" and .package_type == $t and .operating_system == "linux"
                               and ($t == "deb" or (.distribution // "") == $d))]' <<<"$MANIFEST_JSON")
    case $(jq length <<<"$HELPER_ARTIFACT") in
        1) HELPER_ARTIFACT=$(jq -c '.[0]' <<<"$HELPER_ARTIFACT") ;;
        0) die $EX_UNSUPPORTED "release $EXT_VERSION has no adaptive-autovacuum-setup package for $PKG_TYPE/$DISTRO_TAG" ;;
        *) die $EX_DOWNLOAD "release manifest lists several helper packages for this host; refusing to guess" ;;
    esac
}

obtain_one() {  # artifact-json -> path on stdout, verified
    local art=$1 name url sha path
    name=$(jq -r .artifact_filename <<<"$art"); url=$(jq -r .artifact_url <<<"$art"); sha=$(jq -r .sha256 <<<"$art")
    path="$TMPDIR_AAV/$name"
    if [[ -n $OPT_ARTIFACT_DIR ]]; then
        [[ -f $OPT_ARTIFACT_DIR/$name ]] || die $EX_DOWNLOAD "package not found in --artifact-dir: $OPT_ARTIFACT_DIR/$name"
        cp -- "$OPT_ARTIFACT_DIR/$name" "$path"
    else
        need_cmd curl "curl"; fetch "$url" "$path"
    fi
    local actual; actual=$(sha256sum "$path" | cut -d' ' -f1)
    [[ $actual == "$sha" ]] || die $EX_DOWNLOAD "checksum mismatch for $name: expected $sha, got $actual. The download is corrupt or tampered with; nothing was installed."
    say "[OK]   artifact checksum verified ($name)" >&2   # stdout carries only the path
    printf '%s' "$path"
}

obtain_artifact() {  # -> PKG_PATH and HELPER_PATH verified (both before anything is installed)
    PKG_PATH=$(obtain_one "$ARTIFACT")
    HELPER_PATH=$(obtain_one "$HELPER_ARTIFACT")
}

package_installed_version() {  # empty when not installed
    local v
    if [[ $PKG_TYPE == deb ]]; then v=$(dpkg-query -W -f '${Version}' "postgresql-$PG_MAJOR-adaptive-autovacuum" 2>/dev/null) || v=""
    else v=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "postgresql$PG_MAJOR-adaptive-autovacuum" 2>/dev/null) || v=""; fi
    printf '%s' "$v"
}

install_package() {
    local before; before=$(package_installed_version)
    if [[ -n $before ]]; then say "Package already installed: $before"; fi
    if [[ $PKG_TYPE == deb ]]; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then die $EX_CONFIG_FAILED "another apt/dpkg process holds the lock; retry later"; fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$HELPER_PATH" "$PKG_PATH" || die $EX_CONFIG_FAILED "apt-get install failed"
    else
        dnf install -y "$HELPER_PATH" "$PKG_PATH" || die $EX_CONFIG_FAILED "dnf install failed"
    fi
    say "[OK]   extension files installed ($(package_installed_version))"
}

main() {
    parse_args "$@"
    say "adaptive_autovacuum installer $INSTALLER_VERSION"
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die $EX_PRIVILEGE "run as root: sudo bash install.sh ..."
    need_cmd jq "apt-get install jq  |  dnf install jq"; need_cmd sha256sum "coreutils"
    detect_host
    choose_major
    say "Host: $OS_ID $OS_VERSION ($DISTRO_TAG, $(uname -m), $PKG_TYPE packages); PostgreSQL major: $PG_MAJOR"
    TMPDIR_AAV=$(mktemp -d)
    load_manifest
    select_artifact
    say "Release: $EXT_VERSION; packages: $(jq -r .artifact_filename <<<"$ARTIFACT") + $(jq -r .artifact_filename <<<"$HELPER_ARTIFACT")"
    local installed; installed=$(package_installed_version)
    if [[ $OPT_CHECK -eq 1 ]]; then
        say "Installed package: ${installed:-none}"
        if setup_bin >/dev/null; then "$(setup_bin)" check "${SETUP_ARGS[@]}"; fi
        exit 0
    fi
    if [[ $OPT_DRY_RUN -eq 1 ]]; then
        say "Dry run: would download and verify the package, install it with $( [[ $PKG_TYPE == deb ]] && echo apt-get || echo dnf ), then run:"
        say "  adaptive-autovacuum-setup install ${SETUP_ARGS[*]}"
        if setup_bin >/dev/null; then "$(setup_bin)" install "${SETUP_ARGS[@]}" || true; fi
        exit 0
    fi
    if [[ $OPT_YES -eq 0 ]]; then
        if [[ -t 0 && -t 1 ]]; then
            local a; read -r -p "Install the package and configure PostgreSQL $PG_MAJOR? [Y/n] " a
            [[ -z $a || $a =~ ^[Yy] ]] || die $EX_ARGS "cancelled"
        else
            die $EX_ARGS "non-interactive session: pass --yes to install"
        fi
    fi
    obtain_artifact
    install_package
    setup_bin >/dev/null || die $EX_CONFIG_FAILED "the package did not provide adaptive-autovacuum-setup"
    say ""
    exec "$(setup_bin)" install "${SETUP_ARGS[@]}"
}

main "$@"

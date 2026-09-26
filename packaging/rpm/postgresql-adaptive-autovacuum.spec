%{!?pgmajor: %global pgmajor 18}
%global pgroot /usr/pgsql-%{pgmajor}
%global pgbindir %{pgroot}/bin
%global extname adaptive_autovacuum
# Extension packages ship no separate debuginfo/debugsource RPMs.
%global debug_package %{nil}
# PGXS links the module with an rpath to %{pgroot}/lib, as PGDG's own packages do; EL10's check-rpaths rejects it.
%global __brp_check_rpaths %{nil}

Name:           postgresql%{pgmajor}-adaptive-autovacuum
Version:        1.3.0
Release:        1%{?dist}
Summary:        Adaptive autovacuum controller extension for PostgreSQL %{pgmajor}
License:        PostgreSQL
URL:            https://github.com/secp256k1-sha256/adaptive_autovacuum
Source0:        %{extname}-%{version}.tar.gz

BuildRequires:  gcc make
BuildRequires:  postgresql%{pgmajor}-devel
Requires:       postgresql%{pgmajor}-server
Requires:       adaptive-autovacuum-setup = %{version}-%{release}

%description
adaptive_autovacuum watches dead-tuple and freeze debt, worker saturation and
host capacity, and adjusts PostgreSQL autovacuum settings within guardrails.
This package installs the shared library and the extension control and SQL
scripts for PostgreSQL %{pgmajor}. It does not restart PostgreSQL, change its
configuration or create the extension: run "adaptive-autovacuum-setup install"
(package adaptive-autovacuum-setup, installed as a dependency) for that.

# One helper serves every PostgreSQL major on the host, so it is its own noarch package.
%package -n adaptive-autovacuum-setup
Summary:        Setup, health-check and rollback helper for the adaptive_autovacuum extension
BuildArch:      noarch
Requires:       jq
Requires:       bash >= 4.2
Requires:       util-linux

%description -n adaptive-autovacuum-setup
adaptive-autovacuum-setup discovers PostgreSQL clusters, appends
adaptive_autovacuum to shared_preload_libraries while preserving other
entries, restarts the selected service with consent and rollback, creates or
updates the extension per database and runs SELECT * FROM
adaptive_autovacuum.doctor(). Shared by the postgresql<major>-adaptive-autovacuum
packages.

%prep
%autosetup -n %{extname}-%{version}

%build
make %{?_smp_mflags} PG_CONFIG=%{pgbindir}/pg_config with_llvm=no

%install
make install DESTDIR=%{buildroot} PG_CONFIG=%{pgbindir}/pg_config with_llvm=no
install -D -m 755 packaging/linux/adaptive-autovacuum-setup %{buildroot}%{_bindir}/adaptive-autovacuum-setup
install -D -m 644 packaging/common/health-check.sql %{buildroot}%{_datadir}/adaptive-autovacuum/health-check.sql
install -D -m 644 packaging/common/enable-preload.sql %{buildroot}%{_datadir}/adaptive-autovacuum/enable-preload.sql
install -D -m 644 packaging/common/disable-preload.sql %{buildroot}%{_datadir}/adaptive-autovacuum/disable-preload.sql
install -d -m 700 %{buildroot}%{_sharedstatedir}/adaptive-autovacuum

%files
%license LICENSE
%doc README.md docs/INSTALL-LINUX.md docs/TROUBLESHOOTING.md docs/INSTALLER-SECURITY.md
%{pgroot}/lib/%{extname}.so
%{pgroot}/share/extension/%{extname}.control
%{pgroot}/share/extension/%{extname}--*.sql

%files -n adaptive-autovacuum-setup
%license LICENSE
%{_bindir}/adaptive-autovacuum-setup
%dir %{_datadir}/adaptive-autovacuum
%{_datadir}/adaptive-autovacuum/*.sql
%dir %attr(0700, root, root) %{_sharedstatedir}/adaptive-autovacuum

%post
if [ "$1" -eq 1 ]; then
    echo "adaptive_autovacuum files installed for PostgreSQL %{pgmajor}."
    echo "Configure and activate with: sudo adaptive-autovacuum-setup install   (extension created once, in the control database postgres)"
fi

%preun
if [ "$1" -eq 0 ]; then
    # Files only: never DROP EXTENSION or edit a live cluster from a package script.
    echo "Removing adaptive_autovacuum files for PostgreSQL %{pgmajor}. If the library is still in shared_preload_libraries, run"
    echo "  adaptive-autovacuum-setup remove-preload   before the next PostgreSQL restart."
fi

%changelog
* Sat Sep 26 2026 adaptive_autovacuum maintainers - 1.3.0-1
- Table settings recommended, never written; autovacuum = off repaired before the sweep; autovacuum_naptime managed;
  worker raises easier; packages for Debian 12/13 and EL10; upgrade script 1.2.0 -> 1.3.0
* Thu Sep 24 2026 adaptive_autovacuum maintainers - 1.2.0-1
- One control plane per cluster: install once in the control database (postgres); every database is discovered and managed, no CREATE EXTENSION elsewhere
- Cost-weighted vacuum_activity_rate replaces the MB/s signal; XID velocity without allocating XIDs; cluster-first status(), database_status, table_status, actions
- Installer: --control-database (default postgres); no upgrade script from 1.1.0, the helper re-creates the extension
* Sat Sep 19 2026 adaptive_autovacuum maintainers - 1.1.0-1
- Operator API: doctor(), status(), enable_default_policy(); upgrade script 1.0.0 -> 1.1.0
- adaptive-autovacuum-setup helper (own noarch package) and Tier 1 installer; PostgreSQL 17 and 18

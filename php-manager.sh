#!/usr/bin/env bash
#
# php-manager — cross-platform PHP version manager (no sudo)
# Version: 3.1.0
# Platforms: Windows (Git Bash), Linux (x86_64/aarch64), macOS (Intel/Apple Silicon)
#
# Sources:
#   Windows      -> official php.net builds (TS/NTS, SHA256 verified)
#                   + Xdebug (xdebug.org, SHA256 verified, TS/NTS auto-matched)
#                   + PECL DLLs (redis, igbinary) matching branch/TS/compiler
#   Linux/macOS  -> static-php.dev "bulk" builds (static binary: intl, pdo_mysql,
#                   pgsql, sqlite3, redis, swoole, opcache, imagick, ...
#                   NOTE: bulk has no pdo_pgsql/pdo_sqlite/xdebug — Windows builds do)
#
# Commands:
#   ./php-manager.sh install            # setup PATH + wrappers (no downloads)
#   ./php-manager.sh list               # installed vs latest, all branches
#   ./php-manager.sh available          # downloadable on this platform
#   ./php-manager.sh install 8.4        # install one branch (full: PHP + DLLs + ini)
#   ./php-manager.sh update             # update installed branches (PHP + DLLs)
#   ./php-manager.sh update 8.4         # update one branch (PHP + DLLs + ini)
#   ./php-manager.sh update-all         # install missing + update all
#   ./php-manager.sh reinstall 8.4      # force reinstall one branch
#   ./php-manager.sh reinstall-all      # force reinstall everything
#   ./php-manager.sh repair 8.4         # re-fetch missing DLLs + rebuild php.ini (no PHP download)
#   ./php-manager.sh use 8.5            # make `php` / `composer` point to this branch
#   ./php-manager.sh fix-ini <path>     # disable dead/broken extension lines in ANY php.ini (e.g. WAMP)
#   ./php-manager.sh remove 8.2         # uninstall a branch
#   ./php-manager.sh composer           # install/update Composer (SHA384 verified)
#   ./php-manager.sh doctor             # diagnostics (PATH conflicts, Xdebug, ...)
#   ./php-manager.sh refresh            # force-refresh release caches
#   ./php-manager.sh self-update        # global `php-manager` command
#
# After install:  php84 -v | php85 artisan migrate | cmp84 install | php artisan serve
#
# Env options:
#   PHP_THREAD_SAFETY=ts|nts               (Windows only; default nts; existing installs keep their mode)
#   PHP_MANAGER_BRANCHES="8.2 8.3 8.4 8.5" (override branch set)
#   PHP_MANAGER_EXTS="xdebug igbinary redis" (Windows extra DLLs; set "" to disable)
#   PHP_MANAGER_TZ="Asia/Karachi"          (date.timezone)
#   PHP_MANAGER_MEMORY_LIMIT="512M"
#   PHP_MANAGER_XDEBUG_MODE="debug,develop"

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.1.0"
readonly MANAGER_DIR="${HOME}/.php-version-manager"
readonly PHP_DIR="${MANAGER_DIR}/versions"
readonly BIN_DIR="${MANAGER_DIR}/bin"
readonly TOOLS_DIR="${MANAGER_DIR}/tools"
readonly CACHE_DIR="${MANAGER_DIR}/cache"
readonly DEFAULT_FILE="${MANAGER_DIR}/default"
readonly CACERT_FILE="${MANAGER_DIR}/cacert.pem"

readonly DEFAULT_BRANCHES="8.1 8.2 8.3 8.4 8.5 8.6"
readonly MANIFEST_TTL=5          # minutes
readonly LISTING_TTL=60          # minutes (xdebug / pecl indexes)
readonly CACERT_TTL=10080        # minutes (7 days)

readonly WIN_MANIFEST_URL="https://www.php.net/~windows/releases/releases.json"
readonly WIN_DOWNLOAD_URL="https://www.php.net/~windows/releases"
readonly STATIC_BASE_URL="https://dl.static-php.dev/static-php-cli/bulk"
readonly PECL_BASE_URL="https://windows.php.net/downloads/pecl/releases"
readonly XDEBUG_DOWNLOAD_URL="https://xdebug.org/download"
readonly XDEBUG_FILES_URL="https://xdebug.org/files"
readonly CACERT_URL="https://curl.se/ca/cacert.pem"
readonly COMPOSER_INSTALLER_URL="https://getcomposer.org/installer"
readonly COMPOSER_SIGNATURE_URL="https://composer.github.io/installer.sig"

readonly TZ_SETTING="${PHP_MANAGER_TZ:-Asia/Karachi}"
readonly MEMORY_LIMIT="${PHP_MANAGER_MEMORY_LIMIT:-512M}"
readonly XDEBUG_MODE="${PHP_MANAGER_XDEBUG_MODE:-debug,develop}"
readonly WIN_CORE_EXTS="bcmath curl exif fileinfo gd gettext intl mbstring mysqli openssl pdo_mysql pdo_pgsql pdo_sqlite pgsql soap sockets sodium sqlite3 zip gmp"

# ---------- logging ----------
log()     { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warning() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error()   { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()     { error "$*"; exit 1; }
trap 'error "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ---------- platform ----------
detect_platform() {
    local kernel arch
    kernel="$(uname -s)"; arch="$(uname -m)"
    case "$kernel" in
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        Linux*)               PLATFORM="linux" ;;
        Darwin*)              PLATFORM="macos" ;;
        *) die "Unsupported platform: $kernel" ;;
    esac
    case "$arch" in
        x86_64|amd64)  ARCH="x86_64" ;;
        arm64|aarch64) ARCH="aarch64" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
    if [[ "$PLATFORM" == "windows" ]]; then
        PHP_BIN_NAME="php.exe"
        [[ "$ARCH" == "x86_64" ]] || die "Windows builds are x64 only."
        PS_BIN="$(command -v powershell.exe 2>/dev/null || command -v pwsh.exe 2>/dev/null || command -v pwsh 2>/dev/null || true)"
        [[ -n "$PS_BIN" ]] || die "powershell.exe/pwsh not found (required to parse the php.net JSON manifest)."
    else
        PHP_BIN_NAME="php"
        PS_BIN=""
    fi
}

win_path()   { cygpath -w "$1"; }
mixed_path() { cygpath -m "$1"; }
path_for_ini() { if [[ "$PLATFORM" == "windows" ]]; then mixed_path "$1"; else printf '%s' "$1"; fi; }

branch_ok() { [[ "$1" =~ ^8\.[0-9]+$ ]]; }
managed_branches() { echo "${PHP_MANAGER_BRANCHES:-$DEFAULT_BRANCHES}"; }
compiler_for_branch() { case "$1" in 8.0|8.1|8.2|8.3) echo "vs16" ;; *) echo "vs17" ;; esac; }

# portable version sort (no GNU sort -V dependency; handles 8.4.9 < 8.4.27 and 8.5.12 < 8.5.12-1)
version_sort() { awk -F'[.-]' '{printf "%08d%08d%08d%08d %s\n", $1, $2, $3, $4, $0}' | sort | cut -d' ' -f2-; }
reverse_lines() { awk '{a[NR]=$0} END {for (i=NR; i>0; i--) print a[i]}'; }
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | version_sort | tail -1)" == "$1" ]]; }

installed_branches() {
    local d
    for d in "$PHP_DIR"/*; do
        [[ -d "$d" && -x "$d/$PHP_BIN_NAME" ]] || continue
        basename "$d"
    done | version_sort
}

php_exe() { echo "${PHP_DIR}/${1}/${PHP_BIN_NAME}"; }
php_ini() { echo "${PHP_DIR}/${1}/php.ini"; }
meta_file() { echo "${PHP_DIR}/${1}/.php-manager-release"; }

installed_version() {
    local exe; exe="$(php_exe "$1")"
    [[ -x "$exe" ]] || return 1
    MSYS_NO_PATHCONV=1 "$exe" -n -r 'echo PHP_VERSION;' 2>/dev/null || return 1
}

php_zts() {
    local exe; exe="$(php_exe "$1")"
    MSYS_NO_PATHCONV=1 "$exe" -n -r 'echo PHP_ZTS ? "ts" : "nts";' 2>/dev/null || echo "nts"
}

# ---------- download / checksum ----------
fetch() { curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1"; }

fetch_cached() { # url file ttl_minutes — keeps stale copy on network failure
    local url="$1" file="$2" ttl="$3" tmp
    if [[ -s "$file" ]] && [[ -z "$(find "$file" -mmin +"$ttl" 2>/dev/null || true)" ]]; then
        return 0
    fi
    tmp="${file}.tmp.$$"
    if fetch "$url" "$tmp"; then
        mv -f "$tmp" "$file"
        return 0
    fi
    rm -f "$tmp"
    if [[ -s "$file" ]]; then
        warning "Refresh failed (${url}) — using cached copy."
        return 0
    fi
    return 1
}

ensure_cacert() {
    fetch_cached "$CACERT_URL" "$CACERT_FILE" "$CACERT_TTL" \
        || warning "Could not fetch CA bundle — HTTPS (Composer/guzzle) may fail until it is available."
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else die "sha256sum/shasum not found"; fi
}

sha384_of() {
    if command -v sha384sum >/dev/null 2>&1; then sha384sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 384 "$1" | awk '{print $1}'
    else die "sha384sum/shasum not found"; fi
}

extract_archive() {
    case "$1" in
        *.zip)    unzip -q -o "$1" -d "$2" ;;
        *.tar.gz) tar -xzf "$1" -C "$2" ;;
        *) die "Unknown archive type: $1" ;;
    esac
}

# ---------- release discovery ----------
manifest_file() { echo "${CACHE_DIR}/manifest-${PLATFORM}.json"; }

refresh_manifest() {
    log "Fetching release manifest (${PLATFORM})..."
    local f tmp; f="$(manifest_file)"; tmp="${f}.tmp.$$"
    if [[ "$PLATFORM" == "windows" ]]; then
        fetch "$WIN_MANIFEST_URL" "$tmp" || { rm -f "$tmp"; return 1; }
    else
        fetch "${STATIC_BASE_URL}/?format=json" "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$f"
}

ensure_manifest() { # [force]
    local f; f="$(manifest_file)"
    if [[ "${1:-}" == "force" ]] || [[ ! -s "$f" ]] || [[ -n "$(find "$f" -mmin +"$MANIFEST_TTL" 2>/dev/null || true)" ]]; then
        if ! refresh_manifest; then
            [[ -s "$f" ]] && warning "Manifest refresh failed — using cached copy." || die "Cannot fetch release manifest."
        fi
    fi
}

soft_refresh_manifest() { ensure_manifest force; }

static_asset_name() { echo "cli-${PLATFORM}-${ARCH}"; }

# Windows: parse releases.json properly with PowerShell
# (structure: branch -> version, "<ts>-<compiler>-x64" -> zip{path,sha256})
win_json_query() { # branch [build_key] -> prints version [path sha256]
    local branch="$1" key="${2:-}" ps1
    ps1="${CACHE_DIR}/manifest-query.ps1"
    if [[ ! -s "$ps1" ]]; then
        cat > "$ps1" <<'PS1'
param([string]$File, [string]$Branch, [string]$Key)
$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw -LiteralPath $File | ConvertFrom-Json
$p = $j.PSObject.Properties[$Branch]
if ($null -eq $p) { exit 1 }
$b = $p.Value
if ([string]::IsNullOrEmpty($Key)) { Write-Output $b.version; exit 0 }
$k = $b.PSObject.Properties[$Key]
if ($null -eq $k) { exit 2 }
Write-Output $b.version
Write-Output $k.Value.zip.path
Write-Output $k.Value.zip.sha256
exit 0
PS1
    fi
    MSYS_NO_PATHCONV=1 "$PS_BIN" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$(win_path "$ps1")" "$(win_path "$(manifest_file)")" "$branch" "$key"
}

latest_version() { # full release string (Windows may carry a rebuild suffix, e.g. 8.5.12-1)
    local branch="$1"
    ensure_manifest
    if [[ "$PLATFORM" == "windows" ]]; then
        win_json_query "$branch" 2>/dev/null | head -1 || true
    else
        local esc="${branch//./\\.}"
        grep -oE "php-${esc}\.[0-9]+-$(static_asset_name)\.tar\.gz" "$(manifest_file)" 2>/dev/null \
            | sed -E "s/^php-([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/" | version_sort | tail -1 || true
    fi
}

base_version() { echo "${1%-*}"; } # 8.5.12-1 -> 8.5.12 (PHP_VERSION never contains the rebuild suffix)

win_release_info() { # branch ts -> sets REL_VERSION REL_FILE REL_HASH
    local branch="$1" ts="$2" compiler build_key out
    compiler="$(compiler_for_branch "$branch")"
    build_key="${ts}-${compiler}-x64"
    out="$(win_json_query "$branch" "$build_key" 2>/dev/null)" \
        || die "Build ${build_key} unavailable for PHP ${branch} in php.net manifest."
    REL_VERSION="$(sed -n 1p <<< "$out")"
    REL_FILE="$(sed -n 2p <<< "$out")"
    REL_HASH="$(sed -n 3p <<< "$out")"
    [[ -n "$REL_VERSION" && -n "$REL_FILE" && -n "$REL_HASH" ]] || die "Incomplete manifest data for PHP ${branch} (${build_key})."
}

branch_is_current() { # branch latest installed meta
    local latest="$2" installed="$3" meta="$4" latest_base
    [[ -n "$latest" && -n "$installed" ]] || return 1
    latest_base="$(base_version "$latest")"
    [[ "$installed" == "$latest_base" ]] || return 1
    if [[ "$meta" == "$latest" ]]; then return 0; fi
    if [[ -z "$meta" && "$latest" == "$latest_base" ]]; then return 0; fi
    return 1
}

# ---------- php.ini (idempotent managed block) ----------
INI_MARKER_BEGIN="; >>> php-manager >>>"
INI_MARKER_END="; <<< php-manager <<<"

write_ini_block() {
    local ini="$1" branch="$2" dir="${PHP_DIR}/${branch}" tmp ext f xd
    tmp="$(mktemp)"
    if [[ -f "$ini" ]]; then
        sed "/^${INI_MARKER_BEGIN}\$/,/^${INI_MARKER_END}\$/d" "$ini" > "$tmp"
    fi
    {
        printf '%s\n' "$INI_MARKER_BEGIN"
        printf '; Managed by php-manager %s — edits inside this block are overwritten.\n' "$SCRIPT_VERSION"
        printf 'date.timezone = %s\n' "$TZ_SETTING"
        printf 'memory_limit = %s\n' "$MEMORY_LIMIT"
        printf 'upload_max_filesize = 100M\npost_max_size = 100M\n'
        printf 'max_execution_time = 300\nmax_input_time = 300\nmax_input_vars = 5000\n'
        printf 'realpath_cache_size = 4096k\nrealpath_cache_ttl = 600\n'
        if [[ -s "$CACERT_FILE" ]]; then
            printf 'curl.cainfo = "%s"\n' "$(path_for_ini "$CACERT_FILE")"
            printf 'openssl.cafile = "%s"\n' "$(path_for_ini "$CACERT_FILE")"
        fi
        if [[ "$PLATFORM" == "windows" ]]; then
            printf 'extension_dir = "%s"\n' "$(path_for_ini "${dir}/ext")"
            if [[ -f "${dir}/ext/php_opcache.dll" ]]; then
                printf 'zend_extension=opcache\n'   # must load BEFORE xdebug
            fi
        fi
        printf 'opcache.enable = 1\nopcache.enable_cli = 1\n'
        printf 'opcache.memory_consumption = 128\nopcache.interned_strings_buffer = 16\n'
        printf 'opcache.max_accelerated_files = 20000\nopcache.revalidate_freq = 0\n'
        if [[ "$PLATFORM" == "windows" ]]; then
            for ext in $WIN_CORE_EXTS; do
                [[ -f "${dir}/ext/php_${ext}.dll" ]] && printf 'extension=%s\n' "$ext"
            done
            for ext in igbinary redis; do
                [[ -f "${dir}/ext/php_${ext}.dll" ]] && printf 'extension=%s\n' "$ext"
            done
            xd=""
            for f in "${dir}/ext"/php_xdebug-*.dll; do
                if [[ -f "$f" ]]; then xd="$f"; break; fi
            done
            if [[ -n "$xd" ]]; then
                printf 'zend_extension="%s"\n' "$(path_for_ini "$xd")"
                printf 'xdebug.mode = %s\n' "$XDEBUG_MODE"
                printf 'xdebug.start_with_request = trigger\n'
                printf 'xdebug.max_nesting_level = 512\n'
            fi
        fi
        printf '%s\n' "$INI_MARKER_END"
    } >> "$tmp"
    mv "$tmp" "$ini"
}

configure_php() {
    local branch="$1" dir="${PHP_DIR}/${branch}" ini="${PHP_DIR}/${branch}/php.ini" tmp
    if [[ "$PLATFORM" == "windows" ]]; then
        if [[ ! -f "$ini" ]]; then
            if [[ -f "${dir}/php.ini-development" ]]; then cp "${dir}/php.ini-development" "$ini"
            else : > "$ini"; fi
        fi
        # Neutralize ANY foreign active extension lines (e.g. a copied WAMP ini pointing at
        # c:/wamp64/.../zend_ext/php_xdebug-...-nts-....dll). The managed block below
        # re-enables everything that actually exists and matches this build.
        tmp="$(mktemp)"
        sed -e "/^${INI_MARKER_BEGIN}\$/,/^${INI_MARKER_END}\$/d" \
            -e 's/^[[:space:]]*\(\(zend_\)\{0,1\}extension[[:space:]]*=.*\)$/; [php-manager disabled] \1/I' \
            "$ini" > "$tmp"
        mv "$tmp" "$ini"
    fi
    write_ini_block "$ini" "$branch"
}

smoke_test() { # branch — surface any "Failed loading" noise immediately
    local branch="$1" exe ini out
    exe="$(php_exe "$branch")"; ini="$(php_ini "$branch")"
    out="$(MSYS_NO_PATHCONV=1 "$exe" -c "$(path_for_ini "$ini")" -v 2>&1 || true)"
    if grep -qi "failed loading" <<< "$out"; then
        warning "PHP $branch still reports load failures:"
        grep -i "failed loading" <<< "$out" | sort -u >&2
        return 1
    fi
    return 0
}

# ---------- extra DLLs (Windows): Xdebug + PECL ----------
probe_extension() { # exe dll kind(zend|ext) module_name
    local exe="$1" dll="$2" kind="$3" name="$4" out flag
    flag="extension"; [[ "$kind" == "zend" ]] && flag="zend_extension"
    out="$(MSYS_NO_PATHCONV=1 "$exe" -n -d "${flag}=$(path_for_ini "$dll")" -m 2>&1 || true)"
    grep -qi "failed loading" <<< "$out" && return 1
    grep -qix "$name" <<< "$out" && return 0
    return 1
}

# prints "version|sha256|filename" of the newest stable Xdebug for branch/ts/compiler
xdebug_best() { # branch ts compiler page
    local branch="$1" ts="$2" compiler="$3" page="$4"
    local line file ver hash best_ver="" best_hash="" best_file=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        file="$(sed -E "s#.*href=['\"]/files/(php_xdebug-[^'\"]+\.dll)['\"].*#\1#" <<< "$line")"
        ver="$(sed -E "s/^php_xdebug-([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/" <<< "$file")"
        hash="$(sed -E 's/.*SHA256:(&nbsp;|[[:space:]]*)([0-9a-fA-F]{64}).*/\2/' <<< "$line")"
        [[ "$hash" == "$line" ]] && hash=""
        if [[ -z "$best_ver" ]] || ver_gt "$ver" "$best_ver"; then
            best_ver="$ver"; best_hash="$hash"; best_file="$file"
        fi
    done < <(tr '<' '\n' < "$page" \
        | grep -E "href=['\"]/files/php_xdebug-[0-9]+\.[0-9]+\.[0-9]+-${branch//./\\.}-${ts}-${compiler}-x86_64\.dll['\"]" || true)
    [[ -n "$best_file" ]] && printf '%s|%s|%s' "$best_ver" "$best_hash" "$best_file"
    return 0
}

ensure_xdebug() { # branch ts compiler
    local branch="$1" ts="$2" compiler="$3"
    local dir="${PHP_DIR}/${branch}" exe page best best_ver="" best_hash="" best_file="" f cur
    exe="$(php_exe "$branch")"
    page="${CACHE_DIR}/xdebug-download.html"
    fetch_cached "$XDEBUG_DOWNLOAD_URL" "$page" "$LISTING_TTL" || { warning "Xdebug: cannot reach xdebug.org — skipped."; return 0; }

    best="$(xdebug_best "$branch" "$ts" "$compiler" "$page")"
    if [[ -n "$best" ]]; then
        best_ver="${best%%|*}"; best="${best#*|}"
        best_hash="${best%%|*}"; best_file="${best#*|}"
    fi
    if [[ -z "$best_file" ]]; then
        warning "Xdebug: no stable build for PHP ${branch} (${ts}/${compiler}) — skipped."
        return 0
    fi

    cur=""
    for f in "${dir}/ext"/php_xdebug-*.dll; do
        [[ -f "$f" ]] || continue
        cur="$(sed -E "s/^php_xdebug-([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/" <<< "$(basename "$f")")"
        break
    done
    if [[ "$cur" == "$best_ver" && -f "${dir}/ext/${best_file}" ]]; then
        success "PHP $branch: Xdebug $cur up to date (${ts}/${compiler})"
        return 0
    fi

    log "PHP $branch: Xdebug ${cur:-none} -> ${best_ver} (${ts}/${compiler})"
    local part="${CACHE_DIR}/${best_file}.part" actual
    if ! fetch "${XDEBUG_FILES_URL}/${best_file}" "$part"; then
        warning "Xdebug: download failed — skipped."; rm -f "$part"; return 0
    fi
    if [[ -n "$best_hash" ]]; then
        actual="$(sha256_of "$part")"
        if [[ "${actual,,}" != "${best_hash,,}" ]]; then
            warning "Xdebug: SHA256 mismatch — skipped."; rm -f "$part"; return 0
        fi
    fi
    if ! probe_extension "$exe" "$part" zend "Xdebug"; then
        warning "Xdebug ${best_ver} refused to load into PHP ${branch} (${ts}/${compiler}) — skipped (TS/NTS or VC runtime mismatch?)."
        rm -f "$part"; return 0
    fi
    mkdir -p "${dir}/ext"
    rm -f "${dir}/ext"/php_xdebug-*.dll
    mv -f "$part" "${dir}/ext/${best_file}"
    success "PHP $branch: Xdebug ${best_ver} installed ($(basename "$best_file"))"
}

ensure_pecl_ext() { # branch ts compiler ext
    local branch="$1" ts="$2" compiler="$3" ext="$4"
    local dir="${PHP_DIR}/${branch}" exe index versions v zip dirindex archive tmp_dir dll meta
    exe="$(php_exe "$branch")"
    index="${CACHE_DIR}/pecl-${ext}.html"
    fetch_cached "${PECL_BASE_URL}/${ext}/" "$index" "$LISTING_TTL" || { warning "PECL ${ext}: index unreachable — skipped."; return 0; }
    versions="$(grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' "$index" | sed 's/href="//; s|/"||' | version_sort | reverse_lines || true)"
    [[ -n "$versions" ]] || { warning "PECL ${ext}: no stable releases found — skipped."; return 0; }
    meta="${dir}/.php-manager-ext-${ext}"

    local tried=0
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        tried=$((tried + 1)); [[ $tried -le 4 ]] || break
        zip="php_${ext}-${v}-${branch}-${ts}-${compiler}-x64.zip"
        dirindex="${CACHE_DIR}/pecl-${ext}-${v}.html"
        fetch_cached "${PECL_BASE_URL}/${ext}/${v}/" "$dirindex" 1440 || continue
        grep -Fq "$zip" "$dirindex" || continue

        if [[ -f "$meta" && "$(cat "$meta")" == "$v" && -f "${dir}/ext/php_${ext}.dll" ]]; then
            success "PHP $branch: ${ext} $v up to date (${ts}/${compiler})"
            return 0
        fi
        log "PHP $branch: ${ext} -> ${v} (${ts}/${compiler})"
        archive="${CACHE_DIR}/${zip}"
        if ! fetch "${PECL_BASE_URL}/${ext}/${v}/${zip}" "$archive"; then
            warning "PECL ${ext}: download failed — skipped."; rm -f "$archive"; return 0
        fi
        tmp_dir="$(mktemp -d "${CACHE_DIR}/pecl-${ext}-XXXXXX")"
        extract_archive "$archive" "$tmp_dir"
        dll="${tmp_dir}/php_${ext}.dll"
        if [[ ! -f "$dll" ]]; then
            warning "PECL ${ext}: archive missing php_${ext}.dll — skipped."
            rm -rf "$tmp_dir" "$archive"; return 0
        fi
        if ! probe_extension "$exe" "$dll" ext "$ext"; then
            warning "PECL ${ext} ${v} refused to load into PHP ${branch} (${ts}/${compiler}) — skipped."
            rm -rf "$tmp_dir" "$archive"; return 0
        fi
        mkdir -p "${dir}/ext"
        mv -f "$dll" "${dir}/ext/php_${ext}.dll"
        echo "$v" > "$meta"
        rm -rf "$tmp_dir" "$archive"
        success "PHP $branch: ${ext} ${v} installed"
        return 0
    done <<< "$versions"
    warning "PECL ${ext}: no build for PHP ${branch} (${ts}/${compiler}) — skipped."
    return 0
}

ensure_extensions() {
    local branch="$1" e ts compiler
    if [[ "$PLATFORM" != "windows" ]]; then
        log "PHP $branch: static build — extensions are compiled in (no DLL management needed)."
        return 0
    fi
    ts="$(php_zts "$branch")"
    compiler="$(compiler_for_branch "$branch")"
    for e in ${PHP_MANAGER_EXTS-xdebug igbinary redis}; do
        case "$e" in
            xdebug) ensure_xdebug "$branch" "$ts" "$compiler" ;;
            "") ;;
            *) ensure_pecl_ext "$branch" "$ts" "$compiler" "$e" ;;
        esac
    done
}

# ---------- install core ----------
resolve_thread_safety() { # env override > keep existing install's mode > default nts
    local branch="$1"
    if [[ -n "${PHP_THREAD_SAFETY:-}" ]]; then
        case "${PHP_THREAD_SAFETY,,}" in ts|nts) echo "${PHP_THREAD_SAFETY,,}" ;; *) die "PHP_THREAD_SAFETY must be ts or nts" ;; esac
        return 0
    fi
    if [[ -x "$(php_exe "$branch")" ]]; then php_zts "$branch"; else echo "nts"; fi
}

finalize_branch() { # DLLs + ini + wrappers + smoke test (shared by install/update/repair)
    local branch="$1"
    ensure_cacert
    ensure_extensions "$branch"
    configure_php "$branch"
    smoke_test "$branch" || warning "PHP $branch: fix the load failures above (php-manager repair $branch)."
    create_wrappers "$branch"
    if ! default_branch >/dev/null 2>&1; then set_default "$branch"; fi
}

install_branch() { # branch [force]
    local branch="$1" force="${2:-no}"
    branch_ok "$branch" || die "Invalid branch: $branch (expected e.g. 8.4)"
    ensure_manifest

    local latest installed meta ts
    latest="$(latest_version "$branch")"
    [[ -n "$latest" ]] || { warning "PHP $branch has no build for ${PLATFORM}/${ARCH} — skipping."; return 0; }
    installed="$(installed_version "$branch" || true)"
    meta="$(cat "$(meta_file "$branch")" 2>/dev/null || true)"

    if [[ "$force" != "force" ]] && branch_is_current "$branch" "$latest" "$installed" "$meta"; then
        success "PHP $branch already up to date ($installed) — checking extensions/ini..."
        finalize_branch "$branch"
        return 0
    fi

    if [[ -n "$installed" ]]; then log "PHP $branch: $installed -> $latest (full update)"
    else log "PHP $branch: installing $latest"; fi

    local tmp_dir new_dir dst backup archive url
    tmp_dir="$(mktemp -d "${CACHE_DIR}/php-${branch}-XXXXXX")"
    new_dir="${PHP_DIR}/${branch}-new"
    dst="${PHP_DIR}/${branch}"
    backup="${PHP_DIR}/${branch}-backup"
    rm -rf "$new_dir" "$backup"
    mkdir -p "$new_dir"

    if [[ "$PLATFORM" == "windows" ]]; then
        ts="$(resolve_thread_safety "$branch")"
        win_release_info "$branch" "$ts"
        url="${WIN_DOWNLOAD_URL}/${REL_FILE}"
        archive="${CACHE_DIR}/${REL_FILE}"
        fetch "$url" "$archive" || { rm -rf "$tmp_dir" "$new_dir"; die "Download failed: $url"; }
        local actual; actual="$(sha256_of "$archive")"
        [[ "${actual,,}" == "${REL_HASH,,}" ]] || { rm -rf "$tmp_dir" "$new_dir"; die "SHA256 mismatch for ${REL_FILE}"; }
        extract_archive "$archive" "$tmp_dir"
        [[ -f "${tmp_dir}/php.exe" ]] || die "Invalid PHP archive (php.exe missing)"
        cp -R "${tmp_dir}/." "$new_dir/"
        rm -f "$archive"
    else
        archive="${tmp_dir}/php.tar.gz"
        fetch "${STATIC_BASE_URL}/php-${latest}-$(static_asset_name).tar.gz" "$archive" \
            || { rm -rf "$tmp_dir" "$new_dir"; die "Download failed for PHP ${latest}"; }
        extract_archive "$archive" "$tmp_dir"
        [[ -f "${tmp_dir}/php" ]] || die "Invalid PHP archive (php binary missing)"
        cp "${tmp_dir}/php" "${new_dir}/php"
        chmod +x "${new_dir}/php"
    fi

    local new_exe="${new_dir}/${PHP_BIN_NAME}" ver
    ver="$(MSYS_NO_PATHCONV=1 "$new_exe" -n -r 'echo PHP_VERSION;' 2>/dev/null)" \
        || { rm -rf "$tmp_dir" "$new_dir"; die "New PHP $branch binary failed verification."; }
    log "Verified PHP $ver"

    [[ ! -d "$dst" ]] || mv "$dst" "$backup"
    if mv "$new_dir" "$dst"; then
        rm -rf "$backup"
    else
        [[ ! -d "$backup" ]] || mv "$backup" "$dst"
        rm -rf "$tmp_dir" "$new_dir"
        die "Failed to activate PHP $branch (rolled back)."
    fi
    rm -rf "$tmp_dir"

    echo "$latest" > "$(meta_file "$branch")"
    finalize_branch "$branch"   # AFTER activation, so absolute ini paths are correct
    success "PHP $branch ready ($ver)"
}

repair_branch() {
    local branch="$1"
    branch_ok "$branch" || die "Invalid branch: $branch"
    [[ -x "$(php_exe "$branch")" ]] || die "PHP $branch is not installed."
    log "Repairing PHP $branch (DLLs + php.ini)..."
    finalize_branch "$branch"
    success "PHP $branch repaired."
}

remove_branch() {
    local branch="$1" compact b
    branch_ok "$branch" || die "Invalid branch: $branch"
    [[ -d "${PHP_DIR}/${branch}" ]] || die "PHP $branch is not installed."
    rm -rf "${PHP_DIR:?}/${branch}" "${PHP_DIR:?}/${branch}-backup" "${PHP_DIR:?}/${branch}-new"
    compact="${branch//./}"
    rm -f "${BIN_DIR}/php${compact}" "${BIN_DIR}/php${compact}.cmd" \
          "${BIN_DIR}/cmp${compact}" "${BIN_DIR}/cmp${compact}.cmd"
    if [[ -f "$DEFAULT_FILE" && "$(cat "$DEFAULT_FILE")" == "$branch" ]]; then
        rm -f "$DEFAULT_FILE"
        b="$(installed_branches | tail -1)"
        if [[ -n "$b" ]]; then set_default "$b"
        else rm -f "${BIN_DIR}/php" "${BIN_DIR}/php.cmd" "${BIN_DIR}/composer" "${BIN_DIR}/composer.cmd"; fi
    fi
    success "PHP $branch removed."
}

update_installed() {
    local any=no b
    for b in $(installed_branches); do any=yes; install_branch "$b"; done
    [[ "$any" == yes ]] || warning "Nothing installed yet — run: $0 update-all"
}

install_or_update_all() {
    local force="${1:-no}" b
    for b in $(managed_branches); do install_branch "$b" "$force"; done
}

# ---------- composer ----------
highest_php() {
    local b
    b="$(installed_branches | tail -1)"
    [[ -n "$b" ]] || return 1
    php_exe "$b"
}

install_composer() {
    local php b ini installer sig phar tmp_phar expected actual
    b="$(installed_branches | tail -1)"
    [[ -n "$b" ]] || die "Install a PHP version first."
    php="$(php_exe "$b")"; ini="$(php_ini "$b")"
    ensure_cacert
    installer="${CACHE_DIR}/composer-setup.php"
    sig="${CACHE_DIR}/composer-installer.sig"
    phar="${TOOLS_DIR}/composer.phar"
    tmp_phar="${CACHE_DIR}/composer-new.phar"

    log "Installing/updating Composer..."
    fetch "$COMPOSER_INSTALLER_URL" "$installer"
    fetch "$COMPOSER_SIGNATURE_URL" "$sig"
    expected="$(tr -d '[:space:]' < "$sig")"
    actual="$(sha384_of "$installer")"
    [[ "${expected,,}" == "${actual,,}" ]] || die "Composer installer SHA384 mismatch."

    rm -f "$tmp_phar"
    MSYS_NO_PATHCONV=1 "$php" -c "$(path_for_ini "$ini")" -d xdebug.mode=off "$installer" \
        --install-dir="$CACHE_DIR" --filename=composer-new.phar --quiet \
        || die "Composer installer failed."
    [[ -f "$tmp_phar" ]] || die "Composer phar was not produced."
    mv -f "$tmp_phar" "$phar"
    rm -f "$installer" "$sig"

    MSYS_NO_PATHCONV=1 "$php" -c "$(path_for_ini "$ini")" -d xdebug.mode=off "$phar" --version
    for b in $(installed_branches); do create_composer_wrapper "$b"; done
    create_default_shims
    success "Composer installed."
}

# ---------- wrappers ----------
create_wrappers() {
    local branch="$1" compact exe ini
    compact="${branch//./}"
    exe="$(php_exe "$branch")"; ini="$(php_ini "$branch")"
    if [[ "$PLATFORM" == "windows" ]]; then
        local mexe mini wexe wini
        mexe="$(mixed_path "$exe")"; mini="$(mixed_path "$ini")"
        wexe="$(win_path "$exe")";   wini="$(win_path "$ini")"
        cat > "${BIN_DIR}/php${compact}" <<EOF
#!/usr/bin/env bash
export PHPRC="${mini%/*}"
exec "${mexe}" -c "${mini}" "\$@"
EOF
        printf '@echo off\r\nset "PHPRC=%s"\r\n"%s" -c "%s" %%*\r\n' "${wini%\\*}" "$wexe" "$wini" > "${BIN_DIR}/php${compact}.cmd"
    else
        cat > "${BIN_DIR}/php${compact}" <<EOF
#!/usr/bin/env bash
export PHPRC="${ini%/*}"
exec "${exe}" -c "${ini}" "\$@"
EOF
    fi
    chmod +x "${BIN_DIR}/php${compact}"
    create_composer_wrapper "$branch"
}

create_composer_wrapper() {
    local branch="$1" compact exe ini phar
    compact="${branch//./}"
    exe="$(php_exe "$branch")"; ini="$(php_ini "$branch")"; phar="${TOOLS_DIR}/composer.phar"
    if [[ "$PLATFORM" == "windows" ]]; then
        local mexe mini mphar wexe wini wphar
        mexe="$(mixed_path "$exe")"; mini="$(mixed_path "$ini")"; mphar="$(mixed_path "$phar")"
        wexe="$(win_path "$exe")";   wini="$(win_path "$ini")";   wphar="$(win_path "$phar")"
        cat > "${BIN_DIR}/cmp${compact}" <<EOF
#!/usr/bin/env bash
export PHPRC="${mini%/*}"
exec "${mexe}" -c "${mini}" -d xdebug.mode=off "${mphar}" "\$@"
EOF
        printf '@echo off\r\nset "PHPRC=%s"\r\n"%s" -c "%s" -d xdebug.mode=off "%s" %%*\r\n' "${wini%\\*}" "$wexe" "$wini" "$wphar" > "${BIN_DIR}/cmp${compact}.cmd"
    else
        cat > "${BIN_DIR}/cmp${compact}" <<EOF
#!/usr/bin/env bash
export PHPRC="${ini%/*}"
exec "${exe}" -c "${ini}" -d xdebug.mode=off "${phar}" "\$@"
EOF
    fi
    chmod +x "${BIN_DIR}/cmp${compact}"
}

# ---------- default php / composer shims ----------
default_branch() {
    local b
    [[ -s "$DEFAULT_FILE" ]] || return 1
    b="$(cat "$DEFAULT_FILE")"
    [[ -x "$(php_exe "$b")" ]] || return 1
    echo "$b"
}

set_default() { echo "$1" > "$DEFAULT_FILE"; create_default_shims; }

create_default_shims() {
    local b exe ini phar
    if ! b="$(default_branch)"; then
        rm -f "${BIN_DIR}/php" "${BIN_DIR}/php.cmd" "${BIN_DIR}/composer" "${BIN_DIR}/composer.cmd"
        return 0
    fi
    exe="$(php_exe "$b")"; ini="$(php_ini "$b")"; phar="${TOOLS_DIR}/composer.phar"
    if [[ "$PLATFORM" == "windows" ]]; then
        local mexe mini mphar wexe wini wphar
        mexe="$(mixed_path "$exe")"; mini="$(mixed_path "$ini")"; mphar="$(mixed_path "$phar")"
        wexe="$(win_path "$exe")";   wini="$(win_path "$ini")";   wphar="$(win_path "$phar")"
        cat > "${BIN_DIR}/php" <<EOF
#!/usr/bin/env bash
export PHPRC="${mini%/*}"
exec "${mexe}" -c "${mini}" "\$@"
EOF
        printf '@echo off\r\nset "PHPRC=%s"\r\n"%s" -c "%s" %%*\r\n' "${wini%\\*}" "$wexe" "$wini" > "${BIN_DIR}/php.cmd"
        cat > "${BIN_DIR}/composer" <<EOF
#!/usr/bin/env bash
export PHPRC="${mini%/*}"
exec "${mexe}" -c "${mini}" -d xdebug.mode=off "${mphar}" "\$@"
EOF
        printf '@echo off\r\nset "PHPRC=%s"\r\n"%s" -c "%s" -d xdebug.mode=off "%s" %%*\r\n' "${wini%\\*}" "$wexe" "$wini" "$wphar" > "${BIN_DIR}/composer.cmd"
    else
        cat > "${BIN_DIR}/php" <<EOF
#!/usr/bin/env bash
export PHPRC="${ini%/*}"
exec "${exe}" -c "${ini}" "\$@"
EOF
        cat > "${BIN_DIR}/composer" <<EOF
#!/usr/bin/env bash
export PHPRC="${ini%/*}"
exec "${exe}" -c "${ini}" -d xdebug.mode=off "${phar}" "\$@"
EOF
    fi
    chmod +x "${BIN_DIR}/php" "${BIN_DIR}/composer"
}

register_wrappers() {
    local b
    for b in $(installed_branches); do create_wrappers "$b"; done
    if ! default_branch >/dev/null 2>&1; then
        b="$(installed_branches | tail -1)"
        [[ -z "$b" ]] || set_default "$b"
    fi
    create_default_shims
}

# ---------- PATH ----------
configure_path() {
    local marker="# php-version-manager"
    local line="export PATH=\"${BIN_DIR}:\$PATH\""
    local rc
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        [[ -f "$rc" || "$rc" == "${HOME}/.bashrc" ]] || continue
        touch "$rc"
        grep -Fq "$marker" "$rc" || printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
    done
    export PATH="${BIN_DIR}:${PATH}"

    if [[ "$PLATFORM" == "windows" ]]; then
        PHP_MANAGER_BIN_WIN="$(win_path "$BIN_DIR")"
        export PHP_MANAGER_BIN_WIN
        MSYS_NO_PATHCONV=1 "$PS_BIN" -NoLogo -NoProfile -NonInteractive -Command '
            $Bin = $env:PHP_MANAGER_BIN_WIN
            $Current = [Environment]::GetEnvironmentVariable("Path", "User")
            $Parts = @($Current -split ";" | Where-Object { $_ -and $_.Trim() -and ($_ -ne $Bin) })
            [Environment]::SetEnvironmentVariable("Path", ((@($Bin) + $Parts) -join ";"), "User")
            Write-Host "PHP Manager prepended to Windows user PATH."'
        unset PHP_MANAGER_BIN_WIN
        warning "If WAMP/XAMPP is in the SYSTEM PATH it still wins in cmd/PowerShell — use Git Bash, or remove WAMP from the system PATH."
    fi
}

self_update() {
    local src dst bash_win
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    dst="${BIN_DIR}/php-manager"
    if [[ "$src" != "$dst" ]]; then
        cp "$src" "$dst"; chmod +x "$dst"
        if [[ "$PLATFORM" == "windows" ]]; then
            bash_win="$(win_path "$(command -v bash)")"
            printf '@echo off\r\n"%s" "%s" %%*\r\n' "$bash_win" "$(win_path "$dst")" > "${dst}.cmd"
        fi
        success "Global command installed: php-manager <command>"
    fi
}

# ---------- fix any php.ini (e.g. WAMP) ----------
fix_ini() {
    local ini="$1"
    [[ -f "$ini" ]] || die "INI not found: $ini"
    local dir backup exe failed_list tmp disabled=0
    dir="$(cd "$(dirname "$ini")" && pwd)"
    backup="${ini}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$ini" "$backup"

    exe=""
    if [[ -x "${dir}/${PHP_BIN_NAME}" ]]; then exe="${dir}/${PHP_BIN_NAME}"
    elif command -v php >/dev/null 2>&1; then exe="$(command -v php)"; fi

    failed_list=""
    if [[ -n "$exe" ]]; then
        failed_list="$(MSYS_NO_PATHCONV=1 "$exe" -c "$(path_for_ini "$ini")" -m 2>&1 >/dev/null \
            | grep -i "failed loading" \
            | sed -E "s/.*[Ff]ailed loading[[:space:]]+'?([^']*)'?[[:space:]]*$/\1/" \
            | sed -E 's#.*[\\/]##' | sort -u || true)"
    fi

    local extdir line value target base cand resolved
    extdir="$(sed -nE 's/^[[:space:]]*extension_dir[[:space:]]*=[[:space:]]*"?([^";]+)"?.*/\1/p' "$ini" | tail -1 | sed 's/[[:space:]]*$//' || true)"
    [[ -n "$extdir" ]] || extdir="${dir}/ext"
    if [[ "$PLATFORM" == "windows" && "$extdir" =~ ^[A-Za-z]: ]]; then
        extdir="$(cygpath -u "$extdir" 2>/dev/null || echo "$extdir")"
    fi

    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(zend_)?extension[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            value="${BASH_REMATCH[2]}"
            value="${value%%;*}"; value="${value%\"}"; value="${value#\"}"
            value="$(sed 's/[[:space:]]*$//' <<< "$value")"
            target="$value"
            if [[ "$target" != /* && ! "$target" =~ ^[A-Za-z]:[\\/] ]]; then
                target="${extdir%/}/${target}"
            fi
            if [[ "$PLATFORM" == "windows" && "$target" =~ ^[A-Za-z]: ]]; then
                target="$(cygpath -u "$target" 2>/dev/null || echo "$target")"
            fi
            resolved=""
            for cand in "$target" "${target}.dll" "${target}.so" "${extdir%/}/php_${value}.dll"; do
                if [[ -f "$cand" ]]; then resolved="$cand"; break; fi
            done
            base="${resolved:-$target}"; base="${base##*/}"
            if [[ -z "$resolved" ]] || grep -Fxq "$base" <<< "$failed_list" \
               || grep -Fxq "php_${value}.dll" <<< "$failed_list"; then
                printf '; [php-manager disabled] %s\n' "$line" >> "$tmp"
                warning "disabled: ${line}  (missing or refuses to load)"
                disabled=$((disabled + 1))
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$ini"
    mv "$tmp" "$ini"
    if [[ $disabled -gt 0 ]]; then
        success "fix-ini: disabled ${disabled} broken extension line(s). Backup: ${backup}"
        log "For a working Xdebug use the managed PHP instead: php-manager use <branch>  (DLLs auto-matched TS/NTS)."
    else
        rm -f "$backup"
        success "fix-ini: no broken extension lines found in ${ini}"
    fi
}

# ---------- views ----------
show_list() {
    soft_refresh_manifest
    printf '\n%-8s %-16s %-16s %s\n' "BRANCH" "INSTALLED" "LATEST" "STATUS"
    printf '%s\n' "--------------------------------------------------------------"
    local b latest installed meta status def
    def="$(default_branch 2>/dev/null || true)"
    for b in $(managed_branches); do
        latest="$(latest_version "$b")"
        installed="$(installed_version "$b" || true)"
        meta="$(cat "$(meta_file "$b")" 2>/dev/null || true)"
        if   [[ -z "$latest" ]];    then status="N/A for ${PLATFORM}/${ARCH}"
        elif [[ -z "$installed" ]]; then status="not installed"
        elif branch_is_current "$b" "$latest" "$installed" "$meta"; then status="up to date"
        else status="UPDATE AVAILABLE"; fi
        [[ "$b" == "$def" ]] && b="${b}*"
        printf '%-8s %-16s %-16s %s\n' "$b" "${installed:--}" "${latest:--}" "$status"
    done
    printf '%s\n' "--------------------------------------------------------------"
    [[ -n "$def" ]] && printf '* = default (php / composer)\n'
    return 0
}

show_available() {
    soft_refresh_manifest
    log "Available on ${PLATFORM}/${ARCH}:"
    local b v
    for b in $(managed_branches); do
        v="$(latest_version "$b")"
        [[ -n "$v" ]] && printf '  php %s -> %s\n' "$b" "$v"
    done
    return 0
}

show_doctor() {
    printf 'php-manager %s\n' "$SCRIPT_VERSION"
    printf 'platform : %s/%s\n' "$PLATFORM" "$ARCH"
    printf 'root     : %s\n' "$MANAGER_DIR"
    printf 'source   : %s\n' "$([[ "$PLATFORM" == windows ]] && echo "$WIN_MANIFEST_URL" || echo "$STATIC_BASE_URL")"
    printf 'default  : %s\n' "$(default_branch 2>/dev/null || echo '(none — run: php-manager use <branch>)')"
    local c tools="curl tar sha256sum shasum"
    [[ "$PLATFORM" == "windows" ]] && tools="curl tar unzip cygpath ${PS_BIN##*/}"
    for c in $tools; do
        command -v "$c" >/dev/null 2>&1 && printf '  %-14s ok\n' "$c" || printf '  %-14s missing\n' "$c"
    done
    local p
    p="$(command -v php 2>/dev/null || true)"
    if [[ -n "$p" ]]; then
        printf 'php in PATH : %s\n' "$p"
        case "$p" in
            "$BIN_DIR"/*) ;;
            *) warning "A foreign PHP (WAMP/XAMPP?) runs first in PATH. Fix: php-manager use <branch>, restart shell."
               MSYS_NO_PATHCONV=1 php --ini 2>/dev/null | grep -i "loaded configuration" || true ;;
        esac
    else
        warning "php not found in PATH — run: php-manager install"
    fi
    local b v ts mods xd rd
    for b in $(installed_branches); do
        v="$(installed_version "$b" || echo broken)"
        ts="$(php_zts "$b")"
        mods="$(MSYS_NO_PATHCONV=1 "$(php_exe "$b")" -c "$(path_for_ini "$(php_ini "$b")")" -m 2>/dev/null || true)"
        xd="no"; grep -qix "Xdebug" <<< "$mods" && xd="yes"
        rd="no"; grep -qix "redis" <<< "$mods" && rd="yes"
        printf 'php %s : %s (%s) xdebug=%s redis=%s\n' "$b" "$v" "$ts" "$xd" "$rd"
        if [[ "$PLATFORM" != "windows" ]] && ! grep -qix "pdo_pgsql" <<< "$mods"; then
            warning "php $b: static bulk build has no pdo_pgsql/pdo_sqlite (pgsql/sqlite3 ext are present). Use Windows builds or a distro PHP if you need PDO PgSQL."
        fi
    done
}

show_help() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# ---------- main ----------
initialize() {
    detect_platform
    require_command curl
    require_command tar
    if [[ "$PLATFORM" == "windows" ]]; then
        require_command unzip
        require_command cygpath
    fi
    mkdir -p "$PHP_DIR" "$BIN_DIR" "$TOOLS_DIR" "$CACHE_DIR"
}

main() {
    initialize
    local action="${1:-help}"; shift || true

    case "$action" in
        install)
            if [[ $# -gt 0 ]]; then
                soft_refresh_manifest
                install_branch "$1"
            else
                log "Setting up php-manager (PATH + wrappers)..."
                configure_path
                register_wrappers
                self_update
                success "Setup done. Next: php-manager update-all"
                warning "Restart your shell to load PATH."
            fi
            ;;
        update)
            soft_refresh_manifest
            if [[ $# -gt 0 ]]; then install_branch "$1"; else update_installed; fi
            if highest_php >/dev/null; then install_composer; fi
            ;;
        update-all|upgrade-all)
            soft_refresh_manifest
            install_or_update_all
            if highest_php >/dev/null; then install_composer; fi
            ;;
        reinstall)
            [[ $# -gt 0 ]] || die "Usage: $0 reinstall <branch>"
            soft_refresh_manifest
            install_branch "$1" force
            ;;
        reinstall-all)
            soft_refresh_manifest
            install_or_update_all force
            if highest_php >/dev/null; then install_composer; fi
            ;;
        repair)
            if [[ $# -gt 0 ]]; then
                repair_branch "$1"
            else
                local b
                for b in $(installed_branches); do repair_branch "$b"; done
            fi
            ;;
        use)
            [[ $# -gt 0 ]] || die "Usage: $0 use <branch>"
            branch_ok "$1" || die "Invalid branch: $1"
            [[ -x "$(php_exe "$1")" ]] || die "PHP $1 is not installed."
            set_default "$1"
            success "php / composer now point to PHP $1. Restart your shell if PATH is not loaded yet."
            ;;
        fix-ini)
            [[ $# -gt 0 ]] || die "Usage: $0 fix-ini /path/to/php.ini"
            fix_ini "$1"
            ;;
        remove|uninstall)
            [[ $# -gt 0 ]] || die "Usage: $0 remove <branch>"
            remove_branch "$1"
            ;;
        list|ls)        show_list ;;
        available)      show_available ;;
        composer)       install_composer ;;
        doctor)         show_doctor ;;
        refresh)        soft_refresh_manifest; rm -f "${CACHE_DIR}/xdebug-download.html" "${CACHE_DIR}"/pecl-*.html; success "Caches refreshed." ;;
        self-update)    configure_path; self_update ;;
        --version|-V)   echo "php-manager ${SCRIPT_VERSION}" ;;
        help|--help|-h) show_help ;;
        *)
            if branch_ok "$action"; then soft_refresh_manifest; install_branch "$action"
            else die "Unknown command: $action (see: $0 help)"; fi
            ;;
    esac
}

main "$@"

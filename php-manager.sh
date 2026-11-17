#!/usr/bin/env bash
#
# php-manager — cross-platform PHP version manager (no sudo)
# Version: 3.0.0
# Platforms: Windows (Git Bash), Linux (x86_64/aarch64), macOS (Intel/Apple Silicon)
#
# Sources:
#   Windows      -> official php.net builds (TS/NTS, full extensions, SHA256 verified)
#   Linux/macOS  -> static-php.dev "bulk" builds (static binary: intl, pdo_mysql,
#                  pdo_pgsql, pdo_sqlite, redis, swoole, opcache, imagick, ...)
#
# Commands:
#   ./php-manager.sh install            # setup PATH + wrappers (no downloads)
#   ./php-manager.sh list               # installed vs latest, all branches
#   ./php-manager.sh available          # downloadable on this platform
#   ./php-manager.sh install 8.4        # install one branch
#   ./php-manager.sh update             # update installed branches only
#   ./php-manager.sh update 8.4         # update one branch
#   ./php-manager.sh update-all         # install missing + update all
#   ./php-manager.sh reinstall 8.4      # force reinstall one branch
#   ./php-manager.sh reinstall-all      # force reinstall everything
#   ./php-manager.sh remove 8.2         # uninstall a branch
#   ./php-manager.sh composer           # install/update Composer (SHA384 verified)
#   ./php-manager.sh doctor             # diagnostics
#   ./php-manager.sh self-update        # global `php-manager` command
#
# After install:  php84 -v | php85 artisan migrate | cmp84 install
#
# Env options:
#   PHP_THREAD_SAFETY=ts|nts               (Windows only, default ts)
#   PHP_MANAGER_BRANCHES="8.2 8.3 8.4 8.5" (override branch set)

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.0.0"
readonly MANAGER_DIR="${HOME}/.php-version-manager"
readonly PHP_DIR="${MANAGER_DIR}/versions"
readonly BIN_DIR="${MANAGER_DIR}/bin"
readonly TOOLS_DIR="${MANAGER_DIR}/tools"
readonly CACHE_DIR="${MANAGER_DIR}/cache"

readonly THREAD_SAFETY="${PHP_THREAD_SAFETY:-ts}"
readonly DEFAULT_BRANCHES="8.1 8.2 8.3 8.4 8.5"

readonly WIN_MANIFEST_URL="https://www.php.net/~windows/releases/releases.json"
readonly WIN_DOWNLOAD_URL="https://www.php.net/~windows/releases"
readonly STATIC_BASE_URL="https://dl.static-php.dev/static-php-cli/bulk"
readonly COMPOSER_INSTALLER_URL="https://getcomposer.org/installer"
readonly COMPOSER_SIGNATURE_URL="https://composer.github.io/installer.sig"

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
    else
        PHP_BIN_NAME="php"
    fi
}

win_path() { cygpath -w "$1"; }
branch_ok() { [[ "$1" =~ ^8\.[0-9]+$ ]]; }
managed_branches() { echo "${PHP_MANAGER_BRANCHES:-$DEFAULT_BRANCHES}"; }

installed_branches() {
    local d
    for d in "$PHP_DIR"/*; do
        [[ -d "$d" && -x "$d/$PHP_BIN_NAME" ]] || continue
        basename "$d"
    done | sort -V
}

php_exe() { echo "${PHP_DIR}/${1}/${PHP_BIN_NAME}"; }

installed_version() {
    local exe; exe="$(php_exe "$1")"
    [[ -x "$exe" ]] || return 1
    MSYS_NO_PATHCONV=1 "$exe" -n -r 'echo PHP_VERSION;' 2>/dev/null || return 1
}

# ---------- download / checksum ----------
fetch() { curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"; }

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
    if [[ "$PLATFORM" == "windows" ]]; then
        fetch "$WIN_MANIFEST_URL" "$(manifest_file)"
    else
        fetch "${STATIC_BASE_URL}/?format=json" "$(manifest_file)"
    fi
}

ensure_manifest() { # 5 min TTL — one fetch per run, not per branch
    local f; f="$(manifest_file)"
    if [[ ! -s "$f" ]] || [[ -n "$(find "$f" -mmin +5 2>/dev/null)" ]]; then
        refresh_manifest
    fi
}

static_asset_name() { echo "cli-${PLATFORM}-${ARCH}"; }

latest_version() {
    local branch="$1" f; f="$(manifest_file)"
    ensure_manifest
    if [[ "$PLATFORM" == "windows" ]]; then
        grep -A2 "\"${branch}\":" "$f" | grep -o '"version"[^,]*' | head -1 \
            | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    else
        grep -o "php-${branch}\.[0-9]*-$(static_asset_name)\.tar\.gz" "$f" \
            | sed "s/php-${branch}\.\([0-9]*\)-.*/\1/" | sort -n | tail -1 \
            | sed "s/^/${branch}./"
    fi
}

win_release_info() { # sets REL_FILE REL_HASH REL_VERSION
    local branch="$1" compiler build_key f; f="$(manifest_file)"
    case "$branch" in
        8.1|8.2|8.3) compiler="vs16" ;;
        8.4|8.5)     compiler="vs17" ;;
        *) die "Unsupported Windows branch: $branch" ;;
    esac
    build_key="${THREAD_SAFETY}-${compiler}-x64"
    REL_VERSION="$(latest_version "$branch")"
    [[ -n "$REL_VERSION" ]] || die "PHP $branch not found in php.net manifest."
    local block
    block="$(tr -d '\n' < "$f" \
        | sed "s/\"${branch}\":/\n&/g" | grep "^\"${branch}\":" \
        | grep -o "\"${build_key}\".\{0,600\}" | head -1)"
    REL_FILE="$(echo "$block" | grep -o '"path"[^,]*' | head -1 | sed 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    REL_HASH="$(echo "$block" | grep -o '"sha256"[^,}]*' | head -1 | sed 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    [[ -n "$REL_FILE" && -n "$REL_HASH" ]] || die "Build ${build_key} unavailable for PHP ${branch}."
}

# ---------- php.ini (idempotent managed block) ----------
INI_MARKER_BEGIN="; >>> php-manager >>>"
INI_MARKER_END="; <<< php-manager <<<"

write_ini_block() {
    local ini="$1" tmp
    tmp="$(mktemp)"
    if [[ -f "$ini" ]]; then
        sed "/^${INI_MARKER_BEGIN}\$/,/^${INI_MARKER_END}\$/d" "$ini" > "$tmp"
    fi
    cat >> "$tmp" <<EOF
${INI_MARKER_BEGIN}
date.timezone = Asia/Karachi
memory_limit = 512M
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 300
max_input_time = 300
max_input_vars = 5000
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
${INI_MARKER_END}
EOF
    mv "$tmp" "$ini"
}

configure_php() {
    local dir="$1"
    local ini="${dir}/php.ini"
    if [[ "$PLATFORM" == "windows" ]]; then
        [[ -f "$ini" || ! -f "${dir}/php.ini-development" ]] || cp "${dir}/php.ini-development" "$ini"
        local ext
        sed -i.bak 's|^;*\s*extension_dir\s*=.*|extension_dir = "ext"|' "$ini" 2>/dev/null || true
        rm -f "${ini}.bak"
        for ext in bcmath curl exif fileinfo gd gettext intl mbstring mysqli openssl \
                   pdo_mysql pdo_pgsql pdo_sqlite pgsql soap sockets sodium sqlite3 zip; do
            if [[ -f "${dir}/ext/php_${ext}.dll" ]] && ! grep -Eq "^\s*extension\s*=\s*${ext}\s*$" "$ini"; then
                printf 'extension=%s\n' "$ext" >> "$ini"
            fi
        done
    fi
    write_ini_block "$ini"
}

# ---------- install core ----------
install_branch() { # branch [force]
    local branch="$1" force="${2:-no}"
    branch_ok "$branch" || die "Invalid branch: $branch (expected e.g. 8.4)"
    ensure_manifest

    local latest installed url archive tmp_dir new_dir dst backup
    latest="$(latest_version "$branch")"
    [[ -n "$latest" ]] || { warning "PHP $branch has no build for ${PLATFORM}/${ARCH} — skipping."; return 0; }

    installed="$(installed_version "$branch" || true)"
    if [[ "$force" != "force" && -n "$installed" && "$installed" == "$latest" ]]; then
        success "PHP $branch already up to date ($installed)"
        return 0
    fi

    if [[ -n "$installed" ]]; then log "PHP $branch: $installed -> $latest"
    else log "PHP $branch: installing $latest"; fi

    tmp_dir="$(mktemp -d "${CACHE_DIR}/php-${branch}-XXXXXX")"
    new_dir="${PHP_DIR}/${branch}-new"
    dst="${PHP_DIR}/${branch}"
    backup="${PHP_DIR}/${branch}-backup"
    rm -rf "$new_dir" "$backup"
    mkdir -p "$new_dir"

    if [[ "$PLATFORM" == "windows" ]]; then
        win_release_info "$branch"
        url="${WIN_DOWNLOAD_URL}/${REL_FILE}"
        archive="${CACHE_DIR}/${REL_FILE}"
        fetch "$url" "$archive"
        local actual; actual="$(sha256_of "$archive")"
        [[ "${actual,,}" == "${REL_HASH,,}" ]] || die "SHA256 mismatch for ${REL_FILE}"
        extract_archive "$archive" "$tmp_dir"
        [[ -f "${tmp_dir}/php.exe" ]] || die "Invalid PHP archive (php.exe missing)"
        cp -R "${tmp_dir}/." "$new_dir/"
        rm -f "$archive"
    else
        archive="${tmp_dir}/php.tar.gz"
        fetch "${STATIC_BASE_URL}/php-${latest}-$(static_asset_name).tar.gz" "$archive"
        extract_archive "$archive" "$tmp_dir"
        [[ -f "${tmp_dir}/php" ]] || die "Invalid PHP archive (php binary missing)"
        cp "${tmp_dir}/php" "${new_dir}/php"
        chmod +x "${new_dir}/php"
    fi

    configure_php "$new_dir"

    local new_exe="${new_dir}/${PHP_BIN_NAME}" ver
    ver="$(MSYS_NO_PATHCONV=1 "$new_exe" -r 'echo PHP_VERSION;' 2>/dev/null)" \
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

    create_wrappers "$branch"
    success "PHP $branch ready ($ver)"
}

remove_branch() {
    local branch="$1"
    branch_ok "$branch" || die "Invalid branch: $branch"
    [[ -d "${PHP_DIR}/${branch}" ]] || die "PHP $branch is not installed."
    rm -rf "${PHP_DIR:?}/${branch}"
    local compact="${branch//./}"
    rm -f "${BIN_DIR}/php${compact}" "${BIN_DIR}/php${compact}.cmd" \
          "${BIN_DIR}/cmp${compact}" "${BIN_DIR}/cmp${compact}.cmd"
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
    for b in $(installed_branches | sort -Vr); do php_exe "$b"; return 0; done
    return 1
}

install_composer() {
    local php; php="$(highest_php)" || die "Install a PHP version first."
    local installer="${CACHE_DIR}/composer-setup.php"
    local sig="${CACHE_DIR}/composer-installer.sig"
    local phar="${TOOLS_DIR}/composer.phar"
    local tmp_phar="${CACHE_DIR}/composer-new.phar"

    log "Installing/updating Composer..."
    fetch "$COMPOSER_INSTALLER_URL" "$installer"
    fetch "$COMPOSER_SIGNATURE_URL" "$sig"
    local expected actual
    expected="$(tr -d '[:space:]' < "$sig")"
    actual="$(sha384_of "$installer")"
    [[ "${expected,,}" == "${actual,,}" ]] || die "Composer installer SHA384 mismatch."

    rm -f "$tmp_phar"
    MSYS_NO_PATHCONV=1 "$php" "$installer" --install-dir="$CACHE_DIR" --filename=composer-new.phar --quiet \
        || die "Composer installer failed."
    [[ -f "$tmp_phar" ]] || die "Composer phar was not produced."
    mv -f "$tmp_phar" "$phar"
    rm -f "$installer" "$sig"

    MSYS_NO_PATHCONV=1 "$php" "$phar" --version
    local b
    for b in $(installed_branches); do create_composer_wrapper "$b"; done
    success "Composer installed."
}

# ---------- wrappers ----------
create_wrappers() {
    local branch="$1"
    local compact="${branch//./}"
    local exe="${PHP_DIR}/${branch}/${PHP_BIN_NAME}"

    if [[ "$PLATFORM" == "windows" ]]; then
        local win_exe; win_exe="$(win_path "$exe")"
        cat > "${BIN_DIR}/php${compact}" <<EOF
#!/usr/bin/env bash
exec "${exe}" "\$@"
EOF
        cat > "${BIN_DIR}/php${compact}.cmd" <<EOF
@echo off
"${win_exe}" %*
EOF
    else
        cat > "${BIN_DIR}/php${compact}" <<EOF
#!/usr/bin/env bash
exec "${exe}" -c "${PHP_DIR}/${branch}/php.ini" "\$@"
EOF
    fi
    chmod +x "${BIN_DIR}/php${compact}"
    create_composer_wrapper "$branch"
}

create_composer_wrapper() {
    local branch="$1"
    local compact="${branch//./}"
    local exe="${PHP_DIR}/${branch}/${PHP_BIN_NAME}"
    local phar="${TOOLS_DIR}/composer.phar"

    if [[ "$PLATFORM" == "windows" ]]; then
        local win_exe win_phar
        win_exe="$(win_path "$exe")"; win_phar="$(win_path "$phar")"
        cat > "${BIN_DIR}/cmp${compact}" <<EOF
#!/usr/bin/env bash
exec "${exe}" "${phar}" "\$@"
EOF
        cat > "${BIN_DIR}/cmp${compact}.cmd" <<EOF
@echo off
"${win_exe}" "${win_phar}" %*
EOF
    else
        cat > "${BIN_DIR}/cmp${compact}" <<EOF
#!/usr/bin/env bash
exec "${exe}" -c "${PHP_DIR}/${branch}/php.ini" "${phar}" "\$@"
EOF
    fi
    chmod +x "${BIN_DIR}/cmp${compact}"
}

register_wrappers() {
    local b
    for b in $(installed_branches); do create_wrappers "$b"; done
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
        powershell.exe -NoLogo -NoProfile -NonInteractive -Command '
            $Bin = $env:PHP_MANAGER_BIN_WIN
            $Current = [Environment]::GetEnvironmentVariable("Path", "User")
            $Parts = @($Current -split ";" | Where-Object { $_ -and $_.Trim() })
            if ($Parts -notcontains $Bin) {
                [Environment]::SetEnvironmentVariable("Path", (($Parts + $Bin) -join ";"), "User")
                Write-Host "Added PHP Manager to Windows user PATH."
            } else {
                Write-Host "PHP Manager already in Windows user PATH."
            }'
        unset PHP_MANAGER_BIN_WIN
    fi
}

self_update() {
    local src; src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local dst="${BIN_DIR}/php-manager"
    if [[ "$src" != "$dst" ]]; then
        cp "$src" "$dst"; chmod +x "$dst"
        if [[ "$PLATFORM" == "windows" ]]; then
            printf '@echo off\r\n"C:\\Program Files\\Git\\bin\\bash.exe" "%s" %%*\r\n' "$(win_path "$dst")" > "${dst}.cmd"
        fi
        success "Global command installed: php-manager <command>"
    fi
}

# ---------- views ----------
show_list() {
    ensure_manifest
    printf '\n%-8s %-16s %-16s %s\n' "BRANCH" "INSTALLED" "LATEST" "STATUS"
    printf '%s\n' "--------------------------------------------------------------"
    local b latest installed status
    for b in $(managed_branches); do
        latest="$(latest_version "$b")"
        installed="$(installed_version "$b" || true)"
        if   [[ -z "$latest" ]];    then status="N/A for ${PLATFORM}/${ARCH}"
        elif [[ -z "$installed" ]]; then status="not installed"
        elif [[ "$installed" == "$latest" ]]; then status="up to date"
        else status="UPDATE AVAILABLE"; fi
        printf '%-8s %-16s %-16s %s\n' "$b" "${installed:--}" "${latest:--}" "$status"
    done
    printf '%s\n' "--------------------------------------------------------------"
}

show_available() {
    ensure_manifest
    log "Available on ${PLATFORM}/${ARCH}:"
    local b v
    for b in $(managed_branches); do
        v="$(latest_version "$b")"
        [[ -n "$v" ]] && printf '  php %s -> %s\n' "$b" "$v"
    done
}

show_doctor() {
    printf 'php-manager %s\n' "$SCRIPT_VERSION"
    printf 'platform : %s/%s\n' "$PLATFORM" "$ARCH"
    printf 'root     : %s\n' "$MANAGER_DIR"
    printf 'source   : %s\n' "$([[ "$PLATFORM" == windows ]] && echo "$WIN_MANIFEST_URL" || echo "$STATIC_BASE_URL")"
    local c
    for c in curl tar unzip sha256sum shasum powershell.exe; do
        command -v "$c" >/dev/null 2>&1 && printf '  %-14s ok\n' "$c" || printf '  %-14s missing\n' "$c"
    done
    local b
    for b in $(installed_branches); do
        printf 'php %s : %s\n' "$b" "$(installed_version "$b" || echo broken)"
    done
}

show_help() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
            if [[ $# -gt 0 ]]; then install_branch "$1"; else update_installed; fi
            if highest_php >/dev/null; then install_composer; fi
            ;;
        update-all|upgrade-all)
            install_or_update_all
            if highest_php >/dev/null; then install_composer; fi
            ;;
        reinstall)
            [[ $# -gt 0 ]] || die "Usage: $0 reinstall <branch>"
            install_branch "$1" force
            ;;
        reinstall-all)
            install_or_update_all force
            if highest_php >/dev/null; then install_composer; fi
            ;;
        remove|uninstall)
            [[ $# -gt 0 ]] || die "Usage: $0 remove <branch>"
            remove_branch "$1"
            ;;
        list|ls)        show_list ;;
        available)      show_available ;;
        composer)       install_composer ;;
        doctor)         show_doctor ;;
        self-update)    configure_path; self_update ;;
        help|--help|-h) show_help ;;
        *)
            if branch_ok "$action"; then install_branch "$action"
            else die "Unknown command: $action (see: $0 help)"; fi
            ;;
    esac
}

main "$@"

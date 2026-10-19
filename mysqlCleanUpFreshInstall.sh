#!/usr/bin/env bash
###############################################################################
#  mysql_manager.sh — Interactive MySQL Installer & Manager  (v4 — multi-OS)
#  Supports: Amazon Linux 2 / RHEL / CentOS 7-9  AND  Ubuntu / Debian
#  Usage  : sudo bash mysql_manager.sh
#  Log    : /var/log/mysql_manager_<timestamp>.log
###############################################################################

set -euo pipefail

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/mysql_manager_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "# Log started: $(date '+%Y-%m-%d %H:%M:%S')"

# ─── Secure temp dir for MySQL option files ──────────────────────────────────
SECURE_TMP=$(mktemp -d /tmp/mysql_mgr.XXXXXX)
chmod 700 "$SECURE_TMP"

# ─── Colors & Output ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
err()     { echo -e "${RED}[ERROR]${NC}   $*"; }
header()  {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}\n"
}
line()    { echo -e "${CYAN}───────────────────────────────────────────────────${NC}"; }

# ─── Cleanup trap (secure temp dir + error message) ──────────────────────────
_on_exit() {
    local rc=$?
    rm -rf "$SECURE_TMP" 2>/dev/null || true
    if (( rc != 0 )); then
        echo ""
        err "Script stopped unexpectedly (exit code ${rc})."
        err "If execution had not started, no changes were made."
        info "Full log: ${LOG_FILE}"
    fi
}
trap _on_exit EXIT

# ─── Root check ───────────────────────────────────────────────────────────────
if (( EUID != 0 )); then
    err "Run with sudo:  sudo bash $0"
    exit 1
fi

###############################################################################
#  OS DETECTION — sets globals used everywhere below
###############################################################################
OS_FAMILY=""       # "rhel" or "debian"
OS_NAME=""         # human-readable e.g. "Amazon Linux 2", "Ubuntu 22.04"
EL_VER=""          # RHEL major version (7, 8, 9) for repo URL selection
SVC_NAME=""        # systemd service: "mysqld" (RHEL) or "mysql" (Debian)
MY_CNF=""          # primary config file path
SOCK_DEFAULT=""    # default socket path
ERROR_LOG=""       # where mysqld writes the temp root password
PURGE_ERRORS=0     # tracks failures during purge

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        local id_lower="${ID,,}"
        case "$id_lower" in
            amzn|rhel|centos|ol|rocky|alma|fedora)
                OS_FAMILY="rhel"
                OS_NAME="${NAME} ${VERSION_ID:-}"
                ;;
            ubuntu|debian|linuxmint|pop)
                OS_FAMILY="debian"
                OS_NAME="${NAME} ${VERSION_ID:-}"
                ;;
            *)
                # Try to guess from the ID_LIKE field
                local idlike="${ID_LIKE,,}"
                if [[ "$idlike" == *"rhel"* || "$idlike" == *"centos"* || "$idlike" == *"fedora"* ]]; then
                    OS_FAMILY="rhel"
                    OS_NAME="${NAME} ${VERSION_ID:-}"
                elif [[ "$idlike" == *"debian"* || "$idlike" == *"ubuntu"* ]]; then
                    OS_FAMILY="debian"
                    OS_NAME="${NAME} ${VERSION_ID:-}"
                fi
                ;;
        esac
    fi

    # Fallback: check for package managers
    if [[ -z "$OS_FAMILY" ]]; then
        if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            OS_FAMILY="rhel"
            OS_NAME="Unknown RHEL-based"
        elif command -v apt-get &>/dev/null; then
            OS_FAMILY="debian"
            OS_NAME="Unknown Debian-based"
        fi
    fi

    if [[ -z "$OS_FAMILY" ]]; then
        err "Unsupported operating system."
        err "This script supports RHEL/CentOS/Amazon Linux (yum) and Ubuntu/Debian (apt-get)."
        exit 1
    fi

    # Set OS-specific defaults
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        SVC_NAME="mysqld"
        MY_CNF="/etc/my.cnf"
        SOCK_DEFAULT="/var/lib/mysql/mysql.sock"
        ERROR_LOG="/var/log/mysqld.log"
        # Detect EL major version for repo URL selection
        if [[ -f /etc/os-release ]]; then
            # shellcheck disable=SC1091
            source /etc/os-release
            local ver_id="${VERSION_ID:-}"
            local id_val="${ID:-}"
            EL_VER="${ver_id%%.*}"
            # Amazon Linux 2 (VERSION_ID=2) uses EL7-compatible repos
            # Amazon Linux 2023 (VERSION_ID=2023) uses EL9-compatible repos
            if [[ "${id_val,,}" == "amzn" ]]; then
                case "$EL_VER" in
                    2)    EL_VER="7" ;;
                    2023) EL_VER="9" ;;
                esac
            fi
        fi
        if [[ -z "$EL_VER" && -f /etc/redhat-release ]]; then
            EL_VER=$(grep -oP '(?<=release )\d+' /etc/redhat-release 2>/dev/null || true)
        fi
        [[ -z "$EL_VER" ]] && EL_VER="7"
    else
        SVC_NAME="mysql"
        MY_CNF="/etc/mysql/my.cnf"
        SOCK_DEFAULT="/var/run/mysqld/mysqld.sock"
        ERROR_LOG="/var/log/mysql/error.log"
    fi

    ok "Detected OS: ${OS_NAME} (${OS_FAMILY})"
}

###############################################################################
#  HELPER FUNCTIONS
###############################################################################

# ── Prompt: yes / no ─────────────────────────────────────────────────────────
ask_yn() {
    local ans
    while true; do
        read -rp "$(echo -e "${YELLOW}$1 [y/n]: ${NC}")" ans
        case "${ans,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Please enter y or n." ;;
        esac
    done
}

# ── Prompt: non-empty text ───────────────────────────────────────────────────
ask_text() {
    local val
    while true; do
        echo -ne "${CYAN}$1: ${NC}" >&2
        read -r val
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        if [[ -n "$val" ]]; then
            printf '%s\n' "$val"
            return 0
        fi
        warn "Input cannot be empty." >&2
    done
}

# ── Prompt: hidden password with policy check ────────────────────────────────
#    MySQL 8.0+ validate_password requires: ≥8 chars, 1 upper, 1 lower,
#    1 digit, 1 special.  We enforce this so ALTER USER won't reject it.
ask_pass() {
    local label="$1"
    local p1 p2
    while true; do
        # Prompts and warnings go to stderr so they're visible on screen.
        # Only the final password goes to stdout (captured by the caller).
        echo -ne "${CYAN}${label}: ${NC}" >&2
        read -sr p1
        echo >&2
        if [[ -z "$p1" ]]; then
            warn "Password cannot be empty." >&2; continue
        fi
        if (( ${#p1} < 8 )); then
            warn "Minimum 8 characters." >&2; continue
        fi
        if [[ ! "$p1" =~ [A-Z] ]]; then
            warn "Need at least one UPPERCASE letter." >&2; continue
        fi
        if [[ ! "$p1" =~ [a-z] ]]; then
            warn "Need at least one lowercase letter." >&2; continue
        fi
        if [[ ! "$p1" =~ [0-9] ]]; then
            warn "Need at least one digit." >&2; continue
        fi
        if [[ ! "$p1" =~ [^a-zA-Z0-9] ]]; then
            warn "Need at least one special character (!@#\$%^&* etc)." >&2; continue
        fi
        echo -ne "${CYAN}Confirm password: ${NC}" >&2
        read -sr p2
        echo >&2
        if [[ "$p1" != "$p2" ]]; then
            warn "Passwords do not match." >&2; continue
        fi
        printf '%s\n' "$p1"
        return 0
    done
}

# ── Validate version string (X.Y.Z) ─────────────────────────────────────────
validate_version() {
    local ver="$1"
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

# ── Validate SQL identifier (username / db name / hostname) ──────────────────
#    Allows letters, digits, underscore, hyphen, dot (for hostnames/IPs),
#    and % (for wildcard host).  Max 64 chars (MySQL limit).
validate_identifier() {
    local val="$1" label="$2"
    if [[ -z "$val" ]]; then
        err "${label} cannot be empty."
        return 1
    fi
    if (( ${#val} > 64 )); then
        err "${label} must be 64 characters or fewer (got ${#val})."
        return 1
    fi
    if [[ ! "$val" =~ ^[a-zA-Z0-9_.%@:-]+$ ]]; then
        err "${label} '${val}' contains invalid characters."
        err "Allowed: letters, digits, underscore, hyphen, dot, percent."
        return 1
    fi
    return 0
}

# ── Escape single quotes for SQL strings ─────────────────────────────────────
sql_escape() {
    local s="$1"
    s="${s//\\/\\\\}"       # \ → \\
    s="${s//\'/\\\'}"       # ' → \'
    printf '%s\n' "$s"
}

# ── Run any mysql-family command with password hidden from process list ───────
#    Uses --defaults-extra-file with a temp file, so password never
#    appears in `ps aux`.  Used by run_sql() and run_mysqldump().
_run_mysql_cmd() {
    local cmd="$1" pw="$2"; shift 2
    local optfile="${SECURE_TMP}/my_opts.cnf"
    cat > "$optfile" <<EOF
[client]
user=root
password=${pw}
EOF
    chmod 600 "$optfile"
    "$cmd" --defaults-extra-file="$optfile" "$@"
    local rc=$?
    rm -f "$optfile"
    return $rc
}
run_sql()       { local pw="$1"; shift; _run_mysql_cmd mysql     "$pw" "$@"; }
run_mysqldump() { local pw="$1"; shift; _run_mysql_cmd mysqldump "$pw" "$@"; }

# Run SQL with password-bearing statements piped via stdin (not visible in ps)
run_sql_stdin() {
    local pw="$1" sql="$2"; shift 2
    local optfile="${SECURE_TMP}/my_opts.cnf"
    cat > "$optfile" <<EOF
[client]
user=root
password=${pw}
EOF
    chmod 600 "$optfile"
    printf '%s\n' "$sql" | mysql --defaults-extra-file="$optfile" "$@"
    local rc=$?
    rm -f "$optfile"
    return $rc
}

# ── Network connectivity check ───────────────────────────────────────────────
check_network() {
    info "Checking internet connectivity..."
    local ok_net=0
    for host in dev.mysql.com repo.mysql.com 8.8.8.8; do
        if ping -c1 -W3 "$host" &>/dev/null; then
            ok_net=1; break
        fi
    done
    if (( ! ok_net )); then
        # ping might be blocked; try a TCP check
        if timeout 5 bash -c 'echo >/dev/tcp/dev.mysql.com/443' 2>/dev/null; then
            ok_net=1
        fi
    fi
    if (( ! ok_net )); then
        err "Cannot reach dev.mysql.com — no internet access."
        err "Make sure this instance has a route to the internet"
        err "(NAT gateway, IGW, or direct public IP)."
        return 1
    fi
    ok "Internet connectivity confirmed."
    return 0
}

# ── Find the primary MySQL config file on this system ─────────────────────────
find_my_cnf() {
    # Returns the first existing config path
    for f in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    echo "$MY_CNF"  # fallback to OS default
    return 0
}

###############################################################################
#  PACKAGE MANAGER HELPERS (abstract yum vs apt-get)
###############################################################################

# Query installed packages for a pattern, return matching lines
pkg_query() {
    local pattern="$1"
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -qa 2>/dev/null | grep -iE "$pattern" || true
    else
        dpkg -l 2>/dev/null | grep -iE "$pattern" | awk '{print $2 "-" $3}' || true
    fi
}

# List files belonging to a package
pkg_files() {
    local pkg="$1"
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -ql "$pkg" 2>/dev/null || true
    else
        # dpkg needs just the package name (strip version)
        local pname
        pname=$(echo "$pkg" | sed 's/-[0-9].*//')
        dpkg -L "$pname" 2>/dev/null || true
    fi
}

###############################################################################
#  DEEP MYSQL DETECTION
#  Searches: PATH → package database → common paths → filesystem scan →
#            running processes → systemd units
###############################################################################
detect_installed() {
    INST_VER=""
    INST_TYPE=""            # "mysql" or "mariadb"
    INST_PATH=""            # path to the mysql binary found

    local bin_ver="" found_bin=""

    # ── 1. Check PATH ────────────────────────────────────────────────────
    if command -v mysql &>/dev/null; then
        found_bin=$(command -v mysql)
    fi

    # ── 2. Check package database (RPM or dpkg) ─────────────────────────
    if [[ -z "$found_bin" ]]; then
        local pkg
        pkg=$(pkg_query '^mysql-community-server|^mysql-server|^mariadb-server' | head -1)
        if [[ -n "$pkg" ]]; then
            found_bin=$(pkg_files "$pkg" | grep -E '/bin/mysql$' | head -1 || true)
        fi
    fi

    # ── 3. Check common non-standard paths ───────────────────────────────
    if [[ -z "$found_bin" ]]; then
        local try_paths=(
            /usr/local/mysql/bin/mysql
            /usr/local/bin/mysql
            /opt/mysql/bin/mysql
            /opt/mysql/server/bin/mysql
            /usr/mysql/bin/mysql
        )
        for p in "${try_paths[@]}"; do
            if [[ -x "$p" ]]; then
                found_bin="$p"
                break
            fi
        done
    fi

    # ── 4. Scan filesystem (limited depth, skip network mounts, timeout) ─
    if [[ -z "$found_bin" ]]; then
        info "Scanning filesystem for mysql binary (this may take a moment)..."
        found_bin=$(timeout 30 find / -maxdepth 5 -name "mysql" -type f -executable \
                    -xdev \
                    ! -path '/proc/*' ! -path '/sys/*' ! -path '/dev/*' \
                    ! -path '/snap/*' ! -path '/run/*' \
                    2>/dev/null | head -1 || true)
    fi

    # ── 5. Check running processes ───────────────────────────────────────
    if [[ -z "$found_bin" ]]; then
        local running
        running=$(pgrep -a mysqld 2>/dev/null | head -1 || true)
        if [[ -n "$running" ]]; then
            local proc_bin
            proc_bin=$(echo "$running" | awk '{print $2}')
            if [[ -x "$proc_bin" ]]; then
                local bin_dir
                bin_dir=$(dirname "$proc_bin")
                if [[ -x "${bin_dir}/mysql" ]]; then
                    found_bin="${bin_dir}/mysql"
                fi
            fi
            if [[ -z "$found_bin" ]]; then
                warn "mysqld process running ($(echo "$running" | awk '{print $2}'))"
                warn "but mysql client binary not found alongside it."
            fi
        fi
    fi

    # ── 6. Check systemd units ───────────────────────────────────────────
    local svc_found=""
    if systemctl list-unit-files 2>/dev/null | grep -qiE 'mysqld|mariadb|mysql\.service'; then
        svc_found="yes"
        if [[ -z "$found_bin" ]]; then
            local exec_path
            for svc in mysqld mariadb mysql; do
                exec_path=$(systemctl show -p ExecStart "$svc" 2>/dev/null \
                            | grep -oP 'path=\K[^ ;]+' || true)
                if [[ -n "$exec_path" && -x "$exec_path" ]]; then
                    local d; d=$(dirname "$exec_path")
                    [[ -x "${d}/mysql" ]] && found_bin="${d}/mysql"
                    break
                fi
            done
        fi
    fi

    # ── Extract version from whatever we found ───────────────────────────
    if [[ -n "$found_bin" ]]; then
        INST_PATH="$found_bin"
        bin_ver=$("$found_bin" --version 2>/dev/null || true)
        if [[ -n "$bin_ver" ]]; then
            if echo "$bin_ver" | grep -qi mariadb; then
                INST_TYPE="mariadb"
            else
                INST_TYPE="mysql"
            fi
            INST_VER=$(echo "$bin_ver" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
        fi
    fi

    # ── Fall back to package version string if binary didn't give one ────
    if [[ -z "$INST_VER" ]]; then
        local pkg
        pkg=$(pkg_query '^mysql-community-server|^mysql-server|^mariadb-server' | head -1)
        if [[ -n "$pkg" ]]; then
            echo "$pkg" | grep -qi mariadb && INST_TYPE="mariadb" || INST_TYPE="mysql"
            INST_VER=$(echo "$pkg" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
        fi
    fi

    # ── Report findings ──────────────────────────────────────────────────
    if [[ -n "$INST_VER" ]]; then
        echo ""
        line
        echo -e "${BOLD}  MySQL / MariaDB Installation Detected${NC}"
        line
        echo -e "  ${BOLD}Type        :${NC}  ${INST_TYPE}"
        echo -e "  ${BOLD}Version     :${NC}  ${GREEN}${INST_VER}${NC}"
        [[ -n "$INST_PATH" ]] && \
        echo -e "  ${BOLD}Client bin  :${NC}  ${INST_PATH}"

        # Find and show the server binary (mysqld)
        local srv_bin=""
        if [[ -n "$INST_PATH" ]]; then
            local bdir; bdir=$(dirname "$INST_PATH")
            [[ -x "${bdir}/mysqld" ]] && srv_bin="${bdir}/mysqld"
            [[ -z "$srv_bin" && -x "${bdir}/../libexec/mysqld" ]] && \
                srv_bin=$(readlink -f "${bdir}/../libexec/mysqld" 2>/dev/null || true)
            [[ -z "$srv_bin" && -x "${bdir}/../sbin/mysqld" ]] && \
                srv_bin=$(readlink -f "${bdir}/../sbin/mysqld" 2>/dev/null || true)
        fi
        [[ -z "$srv_bin" ]] && srv_bin=$(command -v mysqld 2>/dev/null || true)
        [[ -z "$srv_bin" ]] && srv_bin=$(pgrep -a mysqld 2>/dev/null | head -1 | awk '{print $2}' || true)
        [[ -n "$srv_bin" && -x "$srv_bin" ]] && \
        echo -e "  ${BOLD}Server bin  :${NC}  ${srv_bin}"

        # Install method
        local inst_pkg
        inst_pkg=$(pkg_query '^mysql-community|^mysql-server|^mariadb-server' | head -1)
        if [[ -n "$inst_pkg" ]]; then
            if [[ "$OS_FAMILY" == "rhel" ]]; then
                echo -e "  ${BOLD}Installed by:${NC}  RPM  (${inst_pkg})"
            else
                echo -e "  ${BOLD}Installed by:${NC}  DEB  (${inst_pkg})"
            fi
        elif [[ -n "$INST_PATH" && "$INST_PATH" != *"/usr/bin/"* ]]; then
            echo -e "  ${BOLD}Installed by:${NC}  ${YELLOW}Non-standard / manual (binary at ${INST_PATH})${NC}"
        fi

        # Data directory
        local datadir="" cnf_file
        cnf_file=$(find_my_cnf)
        datadir=$(grep -E '^\s*datadir\s*=' "$cnf_file" 2>/dev/null \
                  | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
        # Also check mysqld.cnf on Debian
        if [[ -z "$datadir" && -f /etc/mysql/mysql.conf.d/mysqld.cnf ]]; then
            datadir=$(grep -E '^\s*datadir\s*=' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null \
                      | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
        fi
        [[ -z "$datadir" ]] && datadir="/var/lib/mysql"
        if [[ -d "$datadir" ]]; then
            local data_sz
            data_sz=$(du -sh "$datadir" 2>/dev/null | awk '{print $1}' || echo "?")
            echo -e "  ${BOLD}Data dir    :${NC}  ${datadir}  (${data_sz})"
        fi

        # Config file
        for cf in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
            if [[ -f "$cf" ]]; then
                echo -e "  ${BOLD}Config file :${NC}  ${cf}"
                break
            fi
        done

        # Service status, PID, port, socket, uptime
        local svc_name_detected=""
        for s in mysqld mysql mariadb; do
            if systemctl is-enabled "$s" &>/dev/null; then
                svc_name_detected="$s"; break
            fi
        done
        if [[ -n "$svc_name_detected" ]]; then
            local svc_state
            svc_state=$(systemctl is-active "$svc_name_detected" 2>/dev/null || echo "unknown")
            if [[ "$svc_state" == "active" ]]; then
                echo -e "  ${BOLD}Service     :${NC}  ${svc_name_detected}.service  ${GREEN}[RUNNING]${NC}"

                # PID
                local mpid
                mpid=$(systemctl show -p MainPID "$svc_name_detected" 2>/dev/null \
                       | cut -d= -f2 || true)
                [[ -n "$mpid" && "$mpid" != "0" ]] && \
                echo -e "  ${BOLD}PID         :${NC}  ${mpid}"

                # Port
                local port
                port=$(ss -tlnp 2>/dev/null | grep -i mysql | grep -oP ':\K[0-9]+' | head -1 || true)
                if [[ -z "$port" ]]; then
                    port=$(grep -E '^\s*port\s*=' "$cnf_file" 2>/dev/null \
                           | head -1 | grep -oP '[0-9]+' || true)
                fi
                [[ -n "$port" ]] && \
                echo -e "  ${BOLD}Port        :${NC}  ${port}"

                # Socket
                local sock
                sock=$(grep -E '^\s*socket\s*=' "$cnf_file" 2>/dev/null \
                       | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
                [[ -z "$sock" && -S /var/lib/mysql/mysql.sock ]] && sock="/var/lib/mysql/mysql.sock"
                [[ -z "$sock" && -S /var/run/mysqld/mysqld.sock ]] && sock="/var/run/mysqld/mysqld.sock"
                [[ -z "$sock" && -S /tmp/mysql.sock ]] && sock="/tmp/mysql.sock"
                [[ -n "$sock" ]] && \
                echo -e "  ${BOLD}Socket      :${NC}  ${sock}"

                # Uptime
                local uptime_str
                uptime_str=$(systemctl show -p ActiveEnterTimestamp "$svc_name_detected" 2>/dev/null \
                             | cut -d= -f2 || true)
                [[ -n "$uptime_str" ]] && \
                echo -e "  ${BOLD}Running since:${NC} ${uptime_str}"
            else
                echo -e "  ${BOLD}Service     :${NC}  ${svc_name_detected}.service  ${RED}[${svc_state^^}]${NC}"
            fi
        elif [[ -n "$svc_found" ]]; then
            echo -e "  ${BOLD}Service     :${NC}  systemd unit exists but ${YELLOW}not enabled${NC}"
        else
            echo -e "  ${BOLD}Service     :${NC}  ${YELLOW}no systemd unit found${NC}"
        fi
        line
        echo ""

    elif [[ -n "$svc_found" ]]; then
        warn "Systemd unit for mysql/mariadb exists but version unreadable."
        warn "Will clean this up during purge."
        INST_VER="unknown"
        INST_TYPE="mysql"
    else
        echo ""
        line
        echo -e "  ${BOLD}No MySQL / MariaDB installation found anywhere on this system.${NC}"
        line
        echo ""
    fi
}

###############################################################################
#  VERSION COMPARE   0=equal  1=A>B  2=A<B
###############################################################################
ver_cmp() {
    [[ "$1" == "$2" ]] && return 0
    local IFS=.
    local i a=($1) b=($2)
    for (( i=0; i<${#a[@]} || i<${#b[@]}; i++ )); do
        (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 1
        (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 2
    done
    return 0
}

###############################################################################
#  BACKUP EXISTING DATA
###############################################################################
offer_backup() {
    local pw="$1"
    echo ""
    warn "All databases in the MySQL datadir will be PERMANENTLY DELETED."
    warn "Backup is MANDATORY before purge. Skipping requires explicit opt-out."
    echo ""

    local backup_dir="/root/mysql_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    info "Dumping all databases..."
    local dump_file="${backup_dir}/all_databases.sql"
    if run_mysqldump "$pw" --all-databases --routines --triggers --events \
         > "$dump_file" 2>/dev/null; then
        local sz
        sz=$(stat -c%s "$dump_file" 2>/dev/null || stat -f%z "$dump_file" 2>/dev/null || echo "0")
        if (( sz < 1024 )); then
            err "Backup file is suspiciously small (${sz} bytes)."
            err "Dump may be empty or incomplete — do NOT trust it."
            if ! ask_yn "Continue WITHOUT a verified backup? DATA WILL BE LOST"; then
                warn "Aborted."; exit 0
            fi
        else
            local human_sz
            human_sz=$(du -sh "$dump_file" | awk '{print $1}')
            ok "Backup saved to ${dump_file} (${human_sz})"
            info "Verify this backup is restorable before relying on it."
        fi
    else
        err "mysqldump failed — password may be wrong or MySQL not running."
        rm -f "$dump_file"
        if ! ask_yn "Continue WITHOUT any backup? ALL DATA WILL BE PERMANENTLY LOST"; then
            warn "Aborted."; exit 0
        fi
    fi

    # Back up config files
    local cnf_file
    cnf_file=$(find_my_cnf)
    if [[ -f "$cnf_file" ]]; then
        local cfg_bak="${backup_dir}/my.cnf.bak"
        cp "$cnf_file" "$cfg_bak" 2>/dev/null || true
        info "Config backed up to ${cfg_bak}"
    fi
    # Back up additional configs
    for extra_cnf in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/my.cnf.d/*.cnf; do
        if [[ -f "$extra_cnf" ]]; then
            local base
            base=$(basename "$extra_cnf")
            cp "$extra_cnf" "${backup_dir}/${base}.bak" 2>/dev/null || true
        fi
    done
    info "All config files backed up to ${backup_dir}/"
}

###############################################################################
#  PURGE EVERYTHING MYSQL / MARIADB
###############################################################################
purge_all() {
    PURGE_ERRORS=0

    # Discover actual datadir BEFORE removing packages (Debian --purge deletes configs)
    local actual_datadir="/var/lib/mysql"
    local cnf_file
    cnf_file=$(find_my_cnf)
    local cfg_datadir=""
    cfg_datadir=$(grep -E '^\s*datadir\s*=' "$cnf_file" 2>/dev/null \
                  | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
    if [[ -z "$cfg_datadir" && -f /etc/mysql/mysql.conf.d/mysqld.cnf ]]; then
        cfg_datadir=$(grep -E '^\s*datadir\s*=' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null \
                      | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
    fi
    # Also try querying running server directly
    if [[ -z "$cfg_datadir" ]]; then
        for svc in mysqld mysql mariadb; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                cfg_datadir=$(mysql -BNe "SELECT @@datadir;" 2>/dev/null || true)
                cfg_datadir="${cfg_datadir%/}"
                break
            fi
        done
    fi
    [[ -n "$cfg_datadir" ]] && actual_datadir="$cfg_datadir"
    info "Discovered datadir: ${actual_datadir}"

    info "Stopping services..."
    for svc in mysqld mariadb mysql; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            if ! systemctl stop "$svc" 2>/dev/null; then
                err "Failed to stop ${svc}.service"
                PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
            fi
        fi
        systemctl disable "$svc" 2>/dev/null || true
    done

    # Verify no mysqld process remains
    if pgrep -x mysqld &>/dev/null; then
        warn "mysqld still running after service stop. Waiting 5s..."
        sleep 5
        if pgrep -x mysqld &>/dev/null; then
            err "mysqld process still alive. Cannot safely continue purge."
            err "Kill it manually (kill \$(pgrep mysqld)) or investigate why it won't stop."
            PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
            return 1
        fi
    fi

    # Build explicit package list instead of wildcards
    info "Building package inventory..."
    local pkgs_to_remove=()

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        local rhel_patterns=(
            mysql-community-server mysql-community-client
            mysql-community-common mysql-community-libs
            mysql-community-libs-compat mysql-community-devel
            mysql-community-embedded mysql-community-test
            mysql-community-release
            mysql-server mysql-client mysql-common mysql-libs
            mariadb-server mariadb-client mariadb-common mariadb-libs
            mariadb mariadb-devel
        )
        for pkg in "${rhel_patterns[@]}"; do
            if rpm -q "$pkg" &>/dev/null; then
                pkgs_to_remove+=("$pkg")
            fi
        done
    else
        export DEBIAN_FRONTEND=noninteractive
        local deb_patterns=(
            mysql-community-server mysql-community-client
            mysql-community-common mysql-common
            mysql-client mysql-server
            mysql-client-core-5.7 mysql-server-core-5.7
            mysql-client-5.7 mysql-server-5.7
            mysql-client-core-8.0 mysql-server-core-8.0
            mysql-client-8.0 mysql-server-8.0
            mysql-client-core-8.4 mysql-server-core-8.4
            mysql-client-8.4 mysql-server-8.4
            mariadb-server mariadb-client mariadb-common
            mysql-apt-config
        )
        for pkg in "${deb_patterns[@]}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                pkgs_to_remove+=("$pkg")
            fi
        done
    fi

    if (( ${#pkgs_to_remove[@]} > 0 )); then
        info "Removing packages: ${pkgs_to_remove[*]}"
        if [[ "$OS_FAMILY" == "rhel" ]]; then
            if ! yum remove -y "${pkgs_to_remove[@]}" 2>&1; then
                err "Package removal had errors."
                PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
            fi
        else
            if ! apt-get remove -y --purge "${pkgs_to_remove[@]}" 2>&1; then
                err "Package removal had errors."
                PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
            fi
            apt-get autoremove -y 2>/dev/null || true
        fi
    else
        info "No known MySQL/MariaDB packages found to remove."
    fi

    info "Cleaning data, logs, configs..."
    local dirs_to_remove=(
        "$actual_datadir"
        /var/log/mysqld.log /var/log/mysql
        /var/log/mariadb /var/run/mysqld
        /etc/my.cnf /etc/my.cnf.rpmsave /etc/my.cnf.d
        /etc/mysql
    )
    # Add default datadir if different from configured one
    if [[ "$actual_datadir" != "/var/lib/mysql" && -d /var/lib/mysql ]]; then
        dirs_to_remove+=(/var/lib/mysql)
    fi

    for target in "${dirs_to_remove[@]}"; do
        if [[ -e "$target" ]]; then
            if ! rm -rf "$target" 2>/dev/null; then
                err "Failed to remove: ${target}"
                PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
            fi
        fi
    done

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rm -f /etc/yum.repos.d/mysql-community*.repo 2>/dev/null || true
    else
        rm -f /etc/apt/sources.list.d/mysql*.list 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/mysql*.sources 2>/dev/null || true
    fi

    # Clean up non-standard installs if detected earlier
    if [[ -n "${INST_PATH:-}" && "$INST_PATH" != "/usr/bin/mysql" ]]; then
        local inst_dir
        inst_dir=$(dirname "$(dirname "$INST_PATH")")
        if [[ "$inst_dir" != "/" && "$inst_dir" != "/usr" && "$inst_dir" != "/usr/local" ]]; then
            warn "Non-standard install detected at ${inst_dir}"
            if ask_yn "Remove ${inst_dir}?"; then
                if ! rm -rf "$inst_dir" 2>/dev/null; then
                    err "Failed to remove ${inst_dir}"
                    PURGE_ERRORS=$(( PURGE_ERRORS + 1 ))
                fi
            fi
        fi
    fi

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        yum clean all --setopt='*.skip_if_unavailable=1' &>/dev/null || true
    else
        apt-get clean &>/dev/null || true
    fi

    if (( PURGE_ERRORS > 0 )); then
        warn "Purge completed with ${PURGE_ERRORS} error(s). Review log for details."
    else
        ok "All MySQL / MariaDB components removed."
    fi
}

###############################################################################
#  INSTALL MYSQL — RHEL / Amazon Linux / CentOS
###############################################################################
install_mysql_rhel() {
    local ver="$1"
    local mm
    mm=$(echo "$ver" | grep -oP '^\d+\.\d+')

    local el="${EL_VER:-7}"

    # Validate EL version is supported by Oracle repos
    case "$el" in
        7|8|9) ;;
        *)
            err "EL${el} not supported by Oracle MySQL repos. Supported: EL7, EL8, EL9."
            return 1
            ;;
    esac

    # ── Repo URL mapping (EL-version-specific) ───────────────────────────
    local repo_url=""
    case "$mm" in
        5.7)
            if (( el > 7 )); then
                err "MySQL 5.7 repos only available for EL7. Detected EL${el}."
                return 1
            fi
            repo_url="https://dev.mysql.com/get/mysql57-community-release-el${el}-11.noarch.rpm"
            ;;
        8.0) repo_url="https://dev.mysql.com/get/mysql80-community-release-el${el}-11.noarch.rpm" ;;
        8.4) repo_url="https://dev.mysql.com/get/mysql84-community-release-el${el}-1.noarch.rpm"  ;;
        *)
            err "No Oracle MySQL repo for version ${mm}. Supported: 5.7, 8.0, 8.4."
            err "Refusing to silently fall back to a different version."
            return 1
            ;;
    esac

    info "Adding MySQL Community repo for EL${el}..."
    yum remove -y --setopt='*.skip_if_unavailable=1' 'mysql*-community-release' 2>/dev/null || true
    if ! rpm -Uvh "$repo_url" 2>&1; then
        err "Could not add MySQL repo."
        err "Check internet connectivity or the repo URL: ${repo_url}"
        return 1
    fi

    info "Importing GPG keys..."
    local gpg_ok=true
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 2>/dev/null || gpg_ok=false
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 2>/dev/null || true
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql      2>/dev/null || true
    if [[ "$gpg_ok" == false ]]; then
        warn "Primary GPG key import failed — install may fail signature checks."
    fi

    info "Installing mysql-community-server (this may take a minute)..."
    if ! yum install -y --setopt='*.skip_if_unavailable=1' \
            mysql-community-server mysql-community-client 2>&1; then
        err "MySQL installation failed. Check GPG key and repository configuration."
        err "Do NOT bypass with --nogpgcheck — diagnose the key/repo error instead."
        return 1
    fi

    info "Starting ${SVC_NAME}..."
    systemctl start "$SVC_NAME" || { err "${SVC_NAME} would not start."; return 1; }
    systemctl enable "$SVC_NAME" 2>/dev/null || true
    ok "MySQL server installed and running."
}

###############################################################################
#  INSTALL MYSQL — Ubuntu / Debian
###############################################################################
install_mysql_debian() {
    local ver="$1"
    local mm
    mm=$(echo "$ver" | grep -oP '^\d+\.\d+')

    export DEBIAN_FRONTEND=noninteractive

    # ── Download and install MySQL APT config package ────────────────────
    info "Adding MySQL APT repository..."

    local apt_config_url="https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb"
    local apt_deb="${SECURE_TMP}/mysql-apt-config.deb"

    if ! wget -q -O "$apt_deb" "$apt_config_url" 2>&1; then
        # Try curl as fallback
        if ! curl -fsSL -o "$apt_deb" "$apt_config_url" 2>&1; then
            err "Could not download MySQL APT config."
            err "Check internet connectivity."
            return 1
        fi
    fi

    # Pre-seed debconf to select the right MySQL version without prompts
    local mysql_select="mysql-${mm}"
    case "$mm" in
        5.7) mysql_select="mysql-5.7" ;;
        8.0) mysql_select="mysql-8.0" ;;
        8.4) mysql_select="mysql-8.4-lts" ;;
        *)
            err "No Oracle MySQL APT repo for version ${mm}. Supported: 5.7, 8.0, 8.4."
            err "Refusing to silently fall back to a different version."
            return 1
            ;;
    esac

    # Pre-configure mysql-apt-config to avoid interactive prompts
    echo "mysql-apt-config mysql-apt-config/select-server select ${mysql_select}" \
        | debconf-set-selections 2>/dev/null || true
    echo "mysql-apt-config mysql-apt-config/select-tools select Enabled" \
        | debconf-set-selections 2>/dev/null || true

    if ! dpkg -i "$apt_deb" 2>&1; then
        err "Could not install MySQL APT config package."
        return 1
    fi
    rm -f "$apt_deb"

    # Import GPG key (modern signed-by method for Ubuntu 22.04+, legacy fallback)
    info "Importing GPG keys..."
    local gpg_imported=false
    if command -v gpg &>/dev/null; then
        if wget -qO- https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 \
            | gpg --dearmor -o /usr/share/keyrings/mysql-archive-keyring.gpg 2>/dev/null; then
            gpg_imported=true
        fi
    fi
    if [[ "$gpg_imported" == false ]]; then
        apt-key adv --keyserver keyserver.ubuntu.com --recv-keys B7B3B788A8D3785C 2>/dev/null || true
    fi

    info "Updating package index..."
    apt-get update 2>&1 || warn "Some repositories may have failed to update."

    # Pre-seed root password to avoid interactive prompt during install
    # MySQL 8.0+ uses auth_socket by default, temp password comes from error log
    echo "mysql-community-server mysql-community-server/root-pass password " \
        | debconf-set-selections 2>/dev/null || true
    echo "mysql-community-server mysql-community-server/re-root-pass password " \
        | debconf-set-selections 2>/dev/null || true
    echo "mysql-community-server mysql-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" \
        | debconf-set-selections 2>/dev/null || true

    info "Installing mysql-community-server (this may take a minute)..."
    if ! apt-get install -y mysql-community-server mysql-community-client 2>&1; then
        warn "mysql-community-* failed. Trying mysql-server..."
        if ! apt-get install -y mysql-server mysql-client 2>&1; then
            err "MySQL installation failed."
            return 1
        fi
    fi

    # Ensure the run directory exists
    mkdir -p /var/run/mysqld 2>/dev/null || true
    chown mysql:mysql /var/run/mysqld 2>/dev/null || true

    info "Starting ${SVC_NAME}..."
    systemctl start "$SVC_NAME" || { err "${SVC_NAME} would not start."; return 1; }
    systemctl enable "$SVC_NAME" 2>/dev/null || true
    ok "MySQL server installed and running."
}

###############################################################################
#  INSTALL MYSQL — unified entry point + post-install (root password, harden)
###############################################################################
install_mysql() {
    local ver="$1"

    # ── Call OS-specific installer ───────────────────────────────────────
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        install_mysql_rhel "$ver" || return 1
    else
        install_mysql_debian "$ver" || return 1
    fi

    # ── Wait for temporary password to appear in log ─────────────────────
    #    mysqld writes the temp password AFTER the process forks, so
    #    systemctl may return before it exists.  Retry up to 15 seconds.
    info "Waiting for mysqld to initialize..."
    local temp_pw="" attempt

    # Check both possible log locations
    for attempt in $(seq 1 15); do
        # RHEL: /var/log/mysqld.log   Debian: /var/log/mysql/error.log
        for log_path in "$ERROR_LOG" /var/log/mysqld.log /var/log/mysql/error.log; do
            if [[ -f "$log_path" ]]; then
                temp_pw=$(grep 'temporary password' "$log_path" 2>/dev/null \
                          | tail -1 | awk '{print $NF}' || true)
                [[ -n "$temp_pw" ]] && break 2
            fi
        done
        sleep 1
    done

    echo ""
    if [[ -n "$temp_pw" ]]; then
        info "Temporary root password detected."
        local new_pw
        new_pw=$(ask_pass "Enter NEW MySQL root password")

        local esc_pw
        esc_pw=$(sql_escape "$new_pw")

        # Use the temp password via option file to avoid ps leak
        local optfile="${SECURE_TMP}/tmp_opts.cnf"
        cat > "$optfile" <<EOF
[client]
user=root
password=${temp_pw}
EOF
        chmod 600 "$optfile"

        if printf '%s\n' "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_pw}';" \
             | mysql --defaults-extra-file="$optfile" --connect-expired-password 2>/dev/null; then
            ok "Root password set."
            ROOT_PW="$new_pw"
        else
            err "Automatic password change failed."
            warn "You may need to run: mysql_secure_installation"
            ROOT_PW=""
        fi
        rm -f "$optfile"
    else
        # On Debian with auth_socket, root can login without a password via sudo
        # Try connecting with empty password first
        if run_sql "" -e "SELECT 1" &>/dev/null; then
            info "Root access available (auth_socket or empty password)."
            local new_pw
            new_pw=$(ask_pass "Enter NEW MySQL root password")
            local esc_npw
            esc_npw=$(sql_escape "$new_pw")
            if run_sql_stdin "" "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${esc_npw}';" 2>/dev/null; then
                ok "Root password set."
                ROOT_PW="$new_pw"
            elif run_sql_stdin "" "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_npw}';" 2>/dev/null; then
                ok "Root password set."
                ROOT_PW="$new_pw"
            elif run_sql_stdin "" "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${esc_npw}');" 2>/dev/null; then
                ok "Root password set (legacy method)."
                ROOT_PW="$new_pw"
            else
                warn "Could not set root password (may already be configured)."
                ROOT_PW=""
            fi
        else
            info "No temporary password found. Trying empty password..."
            local new_pw
            new_pw=$(ask_pass "Enter NEW MySQL root password")
            local esc_npw
            esc_npw=$(sql_escape "$new_pw")
            if run_sql_stdin "" "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_npw}';" 2>/dev/null; then
                ok "Root password set."
                ROOT_PW="$new_pw"
            elif run_sql_stdin "" "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${esc_npw}');" 2>/dev/null; then
                ok "Root password set (legacy method)."
                ROOT_PW="$new_pw"
            else
                warn "Could not set root password (may already be configured)."
                ROOT_PW=""
            fi
        fi
    fi

    # ── Verify installed version matches requested ─────────────────────
    if [[ -n "${ROOT_PW}" ]]; then
        local installed_ver
        installed_ver=$(run_sql "$ROOT_PW" -BNe "SELECT VERSION();" 2>/dev/null || true)
        if [[ -n "$installed_ver" ]]; then
            local installed_mm
            installed_mm=$(echo "$installed_ver" | grep -oP '^\d+\.\d+')
            local requested_mm
            requested_mm=$(echo "$ver" | grep -oP '^\d+\.\d+')
            if [[ "$installed_mm" != "$requested_mm" ]]; then
                err "Version mismatch: requested ${ver} but installed ${installed_ver}."
                err "Repository may not have the requested version."
                warn "Investigate before creating databases or users."
            else
                ok "Installed version ${installed_ver} matches requested ${requested_mm}.x"
            fi
        fi
    fi

    # ── Basic hardening ──────────────────────────────────────────────────
    if [[ -n "${ROOT_PW}" ]]; then
        info "Applying basic hardening..."
        if run_sql "$ROOT_PW" -e "
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
" 2>/dev/null; then
            ok "Hardening applied."
        else
            warn "Some hardening steps skipped."
        fi
    fi
    return 0
}

###############################################################################
#  VERIFY ROOT LOGIN
###############################################################################
verify_root_login() {
    if [[ -z "${ROOT_PW:-}" ]]; then
        err "No root password available — cannot create users / databases."
        return 1
    fi
    if ! run_sql "$ROOT_PW" -e "SELECT 1" &>/dev/null; then
        err "Root login failed. Check the password."
        return 1
    fi
    ok "Root login verified."
}

###############################################################################
#  COLLECT ONE USER INTERACTIVELY  (with input validation)
###############################################################################
collect_user() {
    line
    echo -e "${BOLD}New MySQL User${NC}"

    local uname uhost upass upriv uscope ugrant=""

    # ── Username ─────────────────────────────────────────────────────────
    while true; do
        uname=$(ask_text "Username")
        if validate_identifier "$uname" "Username"; then
            if (( ${#uname} > 32 )); then
                err "MySQL username max 32 characters."; continue
            fi
            break
        fi
    done

    # ── Host ─────────────────────────────────────────────────────────────
    echo -e "  1) localhost   2) Any host (%)   3) Specific host/IP"
    local hc
    read -rp "$(echo -e "${YELLOW}Choose [1/2/3]: ${NC}")" hc
    case "$hc" in
        2)
            uhost="%"
            warn "'%' allows connections from ANY host. Use only if explicitly required."
            warn "Prefer a specific IP/subnet for production databases."
            ;;
        3)
            while true; do
                uhost=$(ask_text "Host / IP")
                validate_identifier "$uhost" "Host" && break
            done
            ;;
        *) uhost="localhost" ;;
    esac

    # ── Password ─────────────────────────────────────────────────────────
    upass=$(ask_pass "Password for '${uname}'@'${uhost}'")

    # ── Role / Privileges ────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Choose a privilege role:${NC}"
    echo "  1) ALL PRIVILEGES       — Full admin access"
    echo "  2) READ ONLY            — SELECT"
    echo "  3) READ / WRITE         — SELECT, INSERT, UPDATE, DELETE"
    echo "  4) DBA                  — ALL PRIVILEGES + GRANT OPTION"
    echo "  5) DEVELOPER            — SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER"
    echo "  6) BACKUP               — SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER"
    echo "  7) CUSTOM               — type your own list"

    local rc
    read -rp "$(echo -e "${YELLOW}Role [1-7]: ${NC}")" rc
    case "$rc" in
        1) upriv="ALL PRIVILEGES" ;;
        2) upriv="SELECT" ;;
        3) upriv="SELECT, INSERT, UPDATE, DELETE" ;;
        4) upriv="ALL PRIVILEGES"; ugrant="WITH GRANT OPTION" ;;
        5) upriv="SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER" ;;
        6) upriv="SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER" ;;
        7)
            while true; do
                upriv=$(ask_text "Privileges (comma-separated, e.g. SELECT, INSERT)")
                local bad_chars='[;`"'"'"'\\]'
                if [[ "$upriv" =~ $bad_chars ]]; then
                    err "Privilege string must not contain ; ' \" \` or \\"
                    continue
                fi
                break
            done
            ;;
        *) upriv="SELECT"; warn "Defaulted to SELECT." ;;
    esac

    # ── Scope (show queued databases as numbered list) ─────────────────
    echo ""
    if (( ${#DBS[@]} > 0 )); then
        echo -e "${BOLD}Grant access to which database(s)?${NC}"
        echo "  0) All databases (*.*)"
        local idx=1
        for _db in "${DBS[@]}"; do
            echo "  ${idx}) ${_db}"
            (( idx++ ))
        done
        echo ""
        echo -e "  ${CYAN}Pick one or more (comma-separated, e.g. 1,2):${NC}"

        while true; do
            local sc
            read -rp "$(echo -e "${YELLOW}Selection [0 for all]: ${NC}")" sc

            if [[ "$sc" == "0" || -z "$sc" ]]; then
                uscope="*.*"
                break
            fi

            # Parse comma-separated IDs and build scope entries
            local scope_list=()
            IFS=',' read -ra picks <<< "$sc"
            local valid_pick=true
            for p in "${picks[@]}"; do
                p="${p## }"; p="${p%% }"   # trim spaces
                if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > ${#DBS[@]} )); then
                    err "Invalid selection '${p}'. Choose 1-${#DBS[@]} or 0 for all."
                    valid_pick=false; break
                fi
                local pick_db="${DBS[$((p-1))]}"
                # Skip duplicates
                local already=false
                for existing in "${scope_list[@]+"${scope_list[@]}"}"; do
                    [[ "$existing" == "$pick_db" ]] && { already=true; break; }
                done
                [[ "$already" == false ]] && scope_list+=("$pick_db")
            done

            if [[ "$valid_pick" == false ]]; then
                continue   # retry instead of silently defaulting
            elif (( ${#scope_list[@]} == 1 )); then
                uscope="${scope_list[0]}.*"
                break
            else
                # Multiple databases → store semicolon-separated, execute as multiple GRANTs
                uscope=$(printf '%s;' "${scope_list[@]}")
                uscope="${uscope%;}"   # remove trailing semicolon
                break
            fi
        done
    else
        echo "  1) All databases (*.*)   2) Specific database (type name)"
        local sc
        read -rp "$(echo -e "${YELLOW}Scope [1/2]: ${NC}")" sc
        case "$sc" in
            2)
                local dbn
                while true; do
                    dbn=$(ask_text "Database name")
                    validate_identifier "$dbn" "Database name" && break
                done
                uscope="${dbn}.*"
                ;;
            *) uscope="*.*" ;;
        esac
    fi

    # ── Store (unit-separator delimited — safe even if password has |) ──
    local US=$'\x1F'
    USERS+=("${uname}${US}${uhost}${US}${upass}${US}${upriv}${US}${uscope}${US}${ugrant}")
    ok "Queued  '${uname}'@'${uhost}'  ->  [${upriv}] on ${uscope} ${ugrant}"
}

###############################################################################
#  MAIN
###############################################################################
main() {
    # ── Detect OS first ──────────────────────────────────────────────────
    detect_os

    header "MySQL Manager  —  ${OS_NAME}  (v4)"

    # ── Global state ─────────────────────────────────────────────────────
    ACTION=""
    TARGET_VER=""
    ROOT_PW=""
    INST_VER=""
    INST_TYPE=""
    INST_PATH=""
    declare -a USERS=()
    declare -a DBS=()

    ###################################################################
    #  PHASE 1 — COLLECT ALL DECISIONS  (nothing touches the system)
    ###################################################################

    # ── 1A  Target version ───────────────────────────────────────────────
    header "Step 1 -> Target Version"
    echo -e "  Popular choices: ${BOLD}5.7.44${NC}  ${BOLD}8.0.40${NC}  ${BOLD}8.4.3${NC}"
    while true; do
        TARGET_VER=$(ask_text "MySQL version to install (e.g. 8.0.40)")
        if validate_version "$TARGET_VER"; then
            break
        fi
        err "Invalid format. Use X.Y.Z  (e.g. 8.0.40, 5.7.44, 8.4.3)"
    done

    # ── 1B  Detect existing install (deep scan) ──────────────────────────
    header "Step 2 -> Existing Installation Check"
    detect_installed

    if [[ -n "$INST_VER" && "$INST_VER" != "unknown" ]]; then
        local cmp=0
        ver_cmp "$INST_VER" "$TARGET_VER" && cmp=$? || cmp=$?

        case $cmp in
            0)
                warn "Same version (${INST_VER}) already installed."
                if ask_yn "Delete everything and REINSTALL MySQL ${TARGET_VER}?"; then
                    ACTION="reinstall"
                    info "Current root password needed for pre-purge backup."
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                else
                    info "Keeping existing installation."
                    ACTION="skip"
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                fi
                ;;
            1)
                warn "Installed (${INST_VER}) is NEWER than requested (${TARGET_VER})."
                if ask_yn "DOWNGRADE? All data will be lost"; then
                    ACTION="reinstall"
                    info "Current root password needed for pre-purge backup."
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                else
                    ACTION="skip"
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                fi
                ;;
            2)
                warn "Installed (${INST_VER}) is OLDER than requested (${TARGET_VER})."
                if ask_yn "Remove old version and install ${TARGET_VER}? ALL DATA WILL BE LOST"; then
                    ACTION="upgrade"
                    info "Current root password needed for pre-purge backup."
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                else
                    ACTION="skip"
                    ROOT_PW=$(ask_pass "Current MySQL root password")
                fi
                ;;
        esac
    elif [[ "$INST_VER" == "unknown" ]]; then
        warn "MySQL/MariaDB detected but version unknown."
        if ask_yn "Remove it and install MySQL ${TARGET_VER}?"; then
            ACTION="reinstall"
            info "Current root password needed for pre-purge backup."
            ROOT_PW=$(ask_pass "Current MySQL root password")
        else
            ACTION="skip"
            ROOT_PW=$(ask_pass "Current MySQL root password")
        fi
    else
        info "No MySQL / MariaDB detected."
        ACTION="fresh_install"
    fi

    # ── 1C  Databases (collected BEFORE users so we can offer them) ─────
    header "Step 3 -> Database Creation"
    if ask_yn "Create databases?"; then
        while true; do
            local db
            while true; do
                db=$(ask_text "Database name")
                validate_identifier "$db" "Database name" && break
            done
            DBS+=("$db")
            ok "Queued database '${db}'."
            echo ""
            ask_yn "Create another database?" || break
        done
    else
        info "Skipping database creation."
    fi

    # ── 1D  Users (after databases, so scope can reference them) ─────────
    header "Step 4 -> User Creation"
    if ask_yn "Create MySQL users?"; then
        while true; do
            collect_user
            echo ""
            ask_yn "Create another user?" || break
        done
    else
        info "Skipping user creation."
    fi

    ###################################################################
    #  PHASE 2 — SHOW PLAN & CONFIRM
    ###################################################################
    header "Execution Plan — Please Review"
    line

    echo -e "${BOLD}OS:${NC}  ${OS_NAME} (${OS_FAMILY})"
    echo ""
    echo -e "${BOLD}Installation:${NC}"
    case "$ACTION" in
        fresh_install) echo -e "  -> Fresh install MySQL ${GREEN}${TARGET_VER}${NC}" ;;
        reinstall)     echo -e "  -> ${RED}REMOVE${NC} ${INST_TYPE} ${INST_VER}  ->  install MySQL ${GREEN}${TARGET_VER}${NC}" ;;
        upgrade)       echo -e "  -> ${RED}REMOVE${NC} ${INST_TYPE} ${INST_VER}  ->  install MySQL ${GREEN}${TARGET_VER}${NC}" ;;
        skip)          echo -e "  -> Keep existing ${INST_TYPE} ${INST_VER} (no install changes)" ;;
    esac

    echo ""
    echo -e "${BOLD}Databases to create: ${#DBS[@]}${NC}"
    if (( ${#DBS[@]} > 0 )); then
        for d in "${DBS[@]}"; do
            echo -e "  -> ${d}"
        done
    fi

    echo ""
    echo -e "${BOLD}Users to create: ${#USERS[@]}${NC}"
    if (( ${#USERS[@]} > 0 )); then
        for u in "${USERS[@]}"; do
            local _n _h _p _pr _sc _g
            IFS=$'\x1F' read -r _n _h _p _pr _sc _g <<< "$u"
            # Display multi-db scope nicely (semicolons → comma list)
            local display_sc="$_sc"
            if [[ "$_sc" == *";"* ]]; then
                display_sc=$(echo "$_sc" | sed 's/;/.*, /g')
                display_sc="${display_sc}.*"
            fi
            echo -e "  -> '${_n}'@'${_h}'  [${_pr}] on ${display_sc}  ${_g}"
        done
    fi

    line
    echo ""
    if [[ "$ACTION" == "reinstall" || "$ACTION" == "upgrade" ]]; then
        echo -e "  ${RED}${BOLD}!! WARNING: ALL EXISTING MYSQL DATA WILL BE PERMANENTLY DELETED${NC}"
        echo ""
        local confirm_host
        confirm_host=$(hostname)
        echo -e "  ${RED}Type '${confirm_host}' to confirm destructive operation:${NC}"
        local typed_confirm
        read -rp "  > " typed_confirm
        if [[ "$typed_confirm" != "$confirm_host" ]]; then
            err "Confirmation mismatch. Expected '${confirm_host}', got '${typed_confirm}'."
            warn "Aborted. No changes were made."
            exit 0
        fi
        ok "Destructive operation confirmed."
        echo ""
    fi

    if ! ask_yn "Proceed with this plan?"; then
        warn "Aborted. No changes were made."
        exit 0
    fi

    ###################################################################
    #  PHASE 3 — EXECUTE
    ###################################################################
    header "Executing..."

    # ── 3A  Pre-flight checks (network + disk space) ──────────────────
    if [[ "$ACTION" != "skip" ]]; then
        check_network || exit 1

        local avail_mb
        avail_mb=$(df -m /var/lib 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
        if (( avail_mb < 500 )); then
            err "Insufficient disk space on /var/lib: ${avail_mb}MB available, need >= 500MB."
            err "MySQL install + datadir initialization requires significant disk space."
            if ! ask_yn "Continue anyway? Install may fail mid-way"; then
                exit 1
            fi
        elif (( avail_mb < 1000 )); then
            warn "Low disk space on /var/lib: ${avail_mb}MB. Recommend >= 1GB free."
        fi
    fi

    # ── 3B  Backup (mandatory when purging an existing install) ─────────
    if [[ "$ACTION" == "reinstall" || "$ACTION" == "upgrade" ]]; then
        local running_svc=""
        for s in mysqld mysql mariadb; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                running_svc="$s"; break
            fi
        done
        if [[ -n "$running_svc" ]]; then
            if [[ -n "${ROOT_PW:-}" ]]; then
                offer_backup "$ROOT_PW"
            else
                err "MySQL is running but no root password available."
                err "Cannot create backup without authentication."
                if ! ask_yn "Continue WITHOUT any backup? ALL DATA WILL BE PERMANENTLY LOST"; then
                    warn "Aborted. Provide root password or back up manually."
                    exit 0
                fi
            fi
        else
            warn "MySQL service not running — cannot create SQL dump."
            # Check all possible data directories for existing data
            local check_datadir="/var/lib/mysql"
            local cnf_chk
            cnf_chk=$(find_my_cnf)
            local cnf_datadir=""
            cnf_datadir=$(grep -E '^\s*datadir\s*=' "$cnf_chk" 2>/dev/null \
                          | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
            [[ -n "$cnf_datadir" ]] && check_datadir="$cnf_datadir"

            if [[ -d "$check_datadir" ]] && (( $(du -sm "$check_datadir" 2>/dev/null | awk '{print $1}' || echo 0) > 10 )); then
                warn "Data directory ${check_datadir} contains data."
                if ! ask_yn "Continue without backup? Data directory will be deleted"; then
                    warn "Aborted. Start MySQL and provide root password to back up."
                    exit 0
                fi
            fi
        fi
    fi

    # ── 3C  Purge ────────────────────────────────────────────────────────
    if [[ "$ACTION" == "reinstall" || "$ACTION" == "upgrade" || "$ACTION" == "fresh_install" ]]; then
        info "[1/4] Cleaning previous MySQL / MariaDB remnants..."
        purge_all || { err "Purge failed critically. Cannot continue."; exit 1; }
        if (( PURGE_ERRORS > 0 )); then
            warn "Purge had ${PURGE_ERRORS} non-fatal error(s)."
            if ! ask_yn "Continue with installation despite purge errors?"; then
                warn "Aborted. Review log: ${LOG_FILE}"
                exit 0
            fi
        fi
    fi

    # ── 3D  Install ──────────────────────────────────────────────────────
    if [[ "$ACTION" != "skip" ]]; then
        info "[2/4] Installing MySQL ${TARGET_VER}..."
        install_mysql "$TARGET_VER" || { err "Install failed. See log: ${LOG_FILE}"; exit 1; }
    else
        info "[2/4] Skipped (keeping existing install)."
    fi

    # ── Verify ───────────────────────────────────────────────────────────
    # Try all possible service names
    local svc_running=false
    for s in "$SVC_NAME" mysqld mysql mariadb; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            svc_running=true; break
        fi
    done
    if [[ "$svc_running" == false ]]; then
        for s in "$SVC_NAME" mysqld mysql; do
            if systemctl start "$s" 2>/dev/null; then
                svc_running=true; break
            fi
        done
        if [[ "$svc_running" == false ]]; then
            err "MySQL service will not start."
            exit 1
        fi
    fi
    verify_root_login || exit 1

    # ── 3E  Databases ────────────────────────────────────────────────────
    if (( ${#DBS[@]} > 0 )); then
        info "[3/4] Creating databases..."

        # Pick the right collation for the installed version (query once)
        local collation="utf8mb4_unicode_ci"
        local running_ver
        running_ver=$(run_sql "$ROOT_PW" -BNe "SELECT VERSION();" 2>/dev/null || true)
        if [[ -n "$running_ver" ]]; then
            local major minor patch
            IFS='.' read -r major minor patch <<< "$(echo "$running_ver" | grep -oP '^\d+\.\d+\.\d+')"
            # MySQL 8.0.17+ supports utf8mb4_0900_ai_ci (faster, Unicode 9.0)
            if (( 10#${major:-0} > 8 )) || \
               (( 10#${major:-0} == 8 && 10#${minor:-0} > 0 )) || \
               (( 10#${major:-0} == 8 && 10#${minor:-0} == 0 && 10#${patch:-0} >= 17 )); then
                collation="utf8mb4_0900_ai_ci"
            fi
        fi
        info "Using collation: ${collation}"

        for d in "${DBS[@]}"; do
            if run_sql "$ROOT_PW" -e \
                "CREATE DATABASE IF NOT EXISTS \`${d}\` CHARACTER SET utf8mb4 COLLATE ${collation};" 2>/dev/null; then
                ok "Database '${d}' created."
            else
                err "Failed to create '${d}'."
            fi
        done
    else
        info "[3/4] No databases to create."
    fi

    # ── 3F  Users ────────────────────────────────────────────────────────
    if (( ${#USERS[@]} > 0 )); then
        info "[4/4] Creating users..."
        for u in "${USERS[@]}"; do
            local _n _h _p _pr _sc _g
            IFS=$'\x1F' read -r _n _h _p _pr _sc _g <<< "$u"

            # Escape password for SQL
            local esc_p
            esc_p=$(sql_escape "$_p")

            # Create user (password piped via stdin, not visible in ps)
            if run_sql_stdin "$ROOT_PW" \
                "CREATE USER IF NOT EXISTS '${_n}'@'${_h}' IDENTIFIED BY '${esc_p}';" 2>/dev/null; then
                ok "User '${_n}'@'${_h}' created."
            else
                if run_sql_stdin "$ROOT_PW" \
                    "ALTER USER '${_n}'@'${_h}' IDENTIFIED BY '${esc_p}';" 2>/dev/null; then
                    ok "User '${_n}'@'${_h}' existed -> password updated."
                else
                    err "Could not create user '${_n}'@'${_h}'."
                fi
            fi

            # Grant privileges (handles multiple databases separated by ;)
            if [[ "$_sc" == *";"* ]]; then
                # Multiple databases selected — issue a GRANT for each
                IFS=';' read -ra _db_list <<< "$_sc"
                for _one_db in "${_db_list[@]}"; do
                    if run_sql "$ROOT_PW" -e \
                        "GRANT ${_pr} ON \`${_one_db}\`.* TO '${_n}'@'${_h}' ${_g};" 2>/dev/null; then
                        ok "Granted [${_pr}] on ${_one_db}.*"
                    else
                        err "Grant failed for '${_n}'@'${_h}' on ${_one_db}.*"
                    fi
                done
            else
                if run_sql "$ROOT_PW" -e \
                    "GRANT ${_pr} ON ${_sc} TO '${_n}'@'${_h}' ${_g};" 2>/dev/null; then
                    ok "Granted [${_pr}] on ${_sc}."
                else
                    err "Grant failed for '${_n}'@'${_h}'."
                fi
            fi
        done
        run_sql "$ROOT_PW" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    else
        info "[4/4] No users to create."
    fi

    ###################################################################
    #  PHASE 4 — FINAL STATUS
    ###################################################################
    header "All Done"

    echo -e "${BOLD}MySQL Version:${NC}"
    run_sql "$ROOT_PW" -e "SELECT VERSION() AS version;" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}Databases:${NC}"
    run_sql "$ROOT_PW" -e "SHOW DATABASES;" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}Users:${NC}"
    run_sql "$ROOT_PW" -e "
SELECT User, Host FROM mysql.user
WHERE User NOT IN ('mysql.sys','mysql.session','mysql.infoschema','root','rdsadmin')
ORDER BY User;" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}Service:${NC}"
    # Try the OS-appropriate service name first
    systemctl status "$SVC_NAME" --no-pager 2>/dev/null | head -5 \
        || systemctl status mysqld --no-pager 2>/dev/null | head -5 \
        || systemctl status mysql --no-pager 2>/dev/null | head -5 \
        || true

    line
    ok "MySQL ${TARGET_VER} is ready to use."
    info "Full session log: ${LOG_FILE}"
    echo ""
}

main "$@"
#!/usr/bin/env bash
###############################################################################
#  mysql_manager.sh — Interactive MySQL Installer & Manager  (v4 — full suite)
#  Supports: Amazon Linux 2 / RHEL / CentOS 7  AND  Ubuntu / Debian
#  Usage  : sudo bash mysql_manager.sh
#  Log    : /var/log/mysql_manager_<timestamp>.log
#
#  Menu Options:
#    1) Fresh Install       — clean install on bare system
#    2) Reinstall           — backup → purge → install
#    3) Backup Databases    — dump databases to SQL files
#    4) Restore Databases   — restore from SQL dump files
#    5) Create DBs & Users  — add to running MySQL
#    6) Uninstall MySQL     — purge everything
#    7) Show Status         — detect & display info
#    0) Exit
###############################################################################

set -euo pipefail

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/mysql_manager_$(date +%Y%m%d_%H%M%S).log"
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

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
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
#  GLOBAL STATE
###############################################################################
OS_FAMILY=""       # "rhel" or "debian"
OS_NAME=""         # human-readable e.g. "Amazon Linux 2", "Ubuntu 22.04"
SVC_NAME=""        # systemd service: "mysqld" (RHEL) or "mysql" (Debian)
MY_CNF=""          # primary config file path
SOCK_DEFAULT=""    # default socket path
ERROR_LOG=""       # where mysqld writes the temp root password

ROOT_PW=""         # MySQL root password (set during install or credential prompt)
INST_VER=""        # detected installed version
INST_TYPE=""       # "mysql" or "mariadb"
INST_PATH=""       # path to the mysql binary found
LAST_DUMP_DIR=""   # path to most recent dump (for restore-after-reinstall offer)

###############################################################################
#  OS DETECTION
###############################################################################
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
    else
        SVC_NAME="mysql"
        MY_CNF="/etc/mysql/my.cnf"
        SOCK_DEFAULT="/var/run/mysqld/mysqld.sock"
        ERROR_LOG="/var/log/mysql/error.log"
    fi

    ok "Detected OS: ${OS_NAME} (${OS_FAMILY})"
}

###############################################################################
#  PROMPT HELPERS
###############################################################################

# ── yes / no ──────────────────────────────────────────────────────────────────
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

# ── Non-empty text ────────────────────────────────────────────────────────────
ask_text() {
    local val
    while true; do
        echo -ne "${CYAN}$1: ${NC}" >&2
        read -r val
        val="${val## }"; val="${val%% }"
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
        warn "Input cannot be empty." >&2
    done
}

# ── Password with MySQL 8.0+ validate_password policy check ─────────────────
#    For NEW passwords only.  Prompts/warnings go to stderr.
ask_pass() {
    local label="$1"
    local p1 p2
    while true; do
        echo -ne "${CYAN}${label}: ${NC}" >&2
        read -sr p1; echo >&2
        if [[ -z "$p1" ]]; then warn "Password cannot be empty." >&2; continue; fi
        if (( ${#p1} < 8 )); then warn "Minimum 8 characters." >&2; continue; fi
        if [[ ! "$p1" =~ [A-Z] ]]; then warn "Need at least one UPPERCASE letter." >&2; continue; fi
        if [[ ! "$p1" =~ [a-z] ]]; then warn "Need at least one lowercase letter." >&2; continue; fi
        if [[ ! "$p1" =~ [0-9] ]]; then warn "Need at least one digit." >&2; continue; fi
        if [[ ! "$p1" =~ [^a-zA-Z0-9] ]]; then warn "Need at least one special character (!@#\$%^&* etc)." >&2; continue; fi
        echo -ne "${CYAN}Confirm password: ${NC}" >&2
        read -sr p2; echo >&2
        if [[ "$p1" != "$p2" ]]; then warn "Passwords do not match." >&2; continue; fi
        echo "$p1"
        return 0
    done
}

# ── Password prompt for EXISTING passwords (no policy check) ─────────────────
ask_existing_pass() {
    local label="$1"
    local p1
    echo -ne "${CYAN}${label}: ${NC}" >&2
    read -sr p1; echo >&2
    echo "$p1"
    return 0
}

# ── Pick a directory path (with default, creates if missing) ─────────────────
ask_path() {
    local label="$1" default="$2"
    local val
    echo -ne "${CYAN}${label} [${default}]: ${NC}" >&2
    read -r val
    val="${val## }"; val="${val%% }"
    [[ -z "$val" ]] && val="$default"

    # Expand ~ to $HOME
    val="${val/#\~/$HOME}"

    # Create the directory if it doesn't exist
    if [[ ! -d "$val" ]]; then
        if mkdir -p "$val" 2>/dev/null; then
            ok "Created directory: ${val}" >&2
        else
            err "Cannot create directory: ${val}" >&2
            return 1
        fi
    fi

    # Check writability
    if [[ ! -w "$val" ]]; then
        err "Directory not writable: ${val}" >&2
        return 1
    fi

    echo "$val"
    return 0
}

###############################################################################
#  VALIDATION & SQL HELPERS
###############################################################################

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_identifier() {
    local val="$1" label="$2"
    if [[ -z "$val" ]]; then err "${label} cannot be empty."; return 1; fi
    if (( ${#val} > 64 )); then err "${label} must be 64 characters or fewer."; return 1; fi
    if [[ ! "$val" =~ ^[a-zA-Z0-9_.%@:-]+$ ]]; then
        err "${label} '${val}' contains invalid characters."
        err "Allowed: letters, digits, underscore, hyphen, dot, percent."
        return 1
    fi
    return 0
}

sql_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\\\'}"
    echo "$s"
}

# ── Run mysql/mysqldump with password hidden from ps via --defaults-extra-file
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

# ── Network check ─────────────────────────────────────────────────────────────
check_network() {
    info "Checking internet connectivity..."
    local ok_net=0
    for host in dev.mysql.com repo.mysql.com 8.8.8.8; do
        if ping -c1 -W3 "$host" &>/dev/null; then ok_net=1; break; fi
    done
    if (( ! ok_net )); then
        timeout 5 bash -c 'echo >/dev/tcp/dev.mysql.com/443' 2>/dev/null && ok_net=1
    fi
    if (( ! ok_net )); then
        err "Cannot reach dev.mysql.com — check internet / NAT gateway."
        return 1
    fi
    ok "Internet connectivity confirmed."
}

# ── Find the primary config file ──────────────────────────────────────────────
find_my_cnf() {
    for f in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    echo "$MY_CNF"
}

# ── Version compare: 0=equal  1=A>B  2=A<B ───────────────────────────────────
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
#  PACKAGE MANAGER HELPERS
###############################################################################
pkg_query() {
    local pattern="$1"
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -qa 2>/dev/null | grep -iE "$pattern" || true
    else
        dpkg -l 2>/dev/null | grep -iE "$pattern" | awk '{print $2 "-" $3}' || true
    fi
}

pkg_files() {
    local pkg="$1"
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rpm -ql "$pkg" 2>/dev/null || true
    else
        local pname; pname=$(echo "$pkg" | sed 's/-[0-9].*//')
        dpkg -L "$pname" 2>/dev/null || true
    fi
}

###############################################################################
#  MYSQL SERVICE HELPERS
###############################################################################

# Find which mysql service is currently active
get_running_service() {
    for s in "$SVC_NAME" mysqld mysql mariadb; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            echo "$s"; return 0
        fi
    done
    return 1
}

# Ensure MySQL is running; try to start it if not
ensure_mysql_running() {
    if get_running_service &>/dev/null; then
        return 0
    fi
    warn "MySQL is not running."
    if ask_yn "Try to start it?"; then
        for s in "$SVC_NAME" mysqld mysql mariadb; do
            if systemctl start "$s" 2>/dev/null; then
                ok "Started ${s}."
                return 0
            fi
        done
        err "Could not start MySQL service."
        return 1
    fi
    return 1
}

###############################################################################
#  MYSQL CREDENTIAL MANAGEMENT
###############################################################################
ensure_mysql_credentials() {
    local max_attempts=3
    local attempt=0

    # If we already have working credentials, verify them
    if [[ -n "${ROOT_PW:-}" ]]; then
        if run_sql "$ROOT_PW" -e "SELECT 1" &>/dev/null; then
            ok "MySQL credentials verified."
            return 0
        else
            warn "Stored credentials no longer work."
            ROOT_PW=""
        fi
    fi

    # Try empty password first (auth_socket on Debian, or fresh installs)
    if run_sql "" -e "SELECT 1" &>/dev/null; then
        info "MySQL root accessible without password (auth_socket or empty)."
        ROOT_PW=""
        return 0
    fi

    # Prompt for credentials with retry
    while (( attempt < max_attempts )); do
        (( attempt++ ))
        echo ""
        info "MySQL root password required (attempt ${attempt}/${max_attempts})"
        ROOT_PW=$(ask_existing_pass "MySQL root password")

        if run_sql "$ROOT_PW" -e "SELECT 1" &>/dev/null; then
            ok "Connected to MySQL successfully."
            return 0
        else
            err "Connection failed. Wrong password or MySQL not accessible."
        fi
    done

    err "Could not connect after ${max_attempts} attempts."
    ROOT_PW=""
    return 1
}

###############################################################################
#  LIST NON-DEFAULT DATABASES
###############################################################################
# Populates global USER_DBS=() array with non-system database names
list_user_databases() {
    USER_DBS=()

    local db_list
    db_list=$(run_sql "$ROOT_PW" -BNe "
        SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
        WHERE SCHEMA_NAME NOT IN
            ('mysql','information_schema','performance_schema','sys','test')
        ORDER BY SCHEMA_NAME;" 2>/dev/null || true)

    if [[ -z "$db_list" ]]; then
        return 1
    fi

    while IFS= read -r db; do
        [[ -n "$db" ]] && USER_DBS+=("$db")
    done <<< "$db_list"

    return 0
}

###############################################################################
#  DEEP MYSQL DETECTION
###############################################################################
detect_installed() {
    INST_VER=""
    INST_TYPE=""
    INST_PATH=""

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

    # ── 3. Common non-standard paths ────────────────────────────────────
    if [[ -z "$found_bin" ]]; then
        for p in /usr/local/mysql/bin/mysql /usr/local/bin/mysql \
                 /opt/mysql/bin/mysql /opt/mysql/server/bin/mysql \
                 /usr/mysql/bin/mysql; do
            [[ -x "$p" ]] && { found_bin="$p"; break; }
        done
    fi

    # ── 4. Filesystem scan (limited depth) ──────────────────────────────
    if [[ -z "$found_bin" ]]; then
        info "Scanning filesystem for mysql binary..."
        found_bin=$(find / -maxdepth 6 -name "mysql" -type f -executable \
                    ! -path '/proc/*' ! -path '/sys/*' ! -path '/dev/*' \
                    2>/dev/null | head -1 || true)
    fi

    # ── 5. Running processes ────────────────────────────────────────────
    if [[ -z "$found_bin" ]]; then
        local running
        running=$(pgrep -a mysqld 2>/dev/null | head -1 || true)
        if [[ -n "$running" ]]; then
            local proc_bin; proc_bin=$(echo "$running" | awk '{print $2}')
            if [[ -x "$proc_bin" ]]; then
                local bin_dir; bin_dir=$(dirname "$proc_bin")
                [[ -x "${bin_dir}/mysql" ]] && found_bin="${bin_dir}/mysql"
            fi
            [[ -z "$found_bin" ]] && warn "mysqld running but client binary not found alongside it."
        fi
    fi

    # ── 6. Systemd units ────────────────────────────────────────────────
    local svc_found=""
    if systemctl list-unit-files 2>/dev/null | grep -qiE 'mysqld|mariadb|mysql\.service'; then
        svc_found="yes"
        if [[ -z "$found_bin" ]]; then
            for svc in mysqld mariadb mysql; do
                local exec_path
                exec_path=$(systemctl show -p ExecStart "$svc" 2>/dev/null \
                            | grep -oP 'path=\K[^ ;]+' || true)
                if [[ -n "$exec_path" && -x "$exec_path" ]]; then
                    local d; d=$(dirname "$exec_path")
                    [[ -x "${d}/mysql" ]] && { found_bin="${d}/mysql"; break; }
                fi
            done
        fi
    fi

    # ── Extract version ─────────────────────────────────────────────────
    if [[ -n "$found_bin" ]]; then
        INST_PATH="$found_bin"
        bin_ver=$("$found_bin" --version 2>/dev/null || true)
        if [[ -n "$bin_ver" ]]; then
            echo "$bin_ver" | grep -qi mariadb && INST_TYPE="mariadb" || INST_TYPE="mysql"
            INST_VER=$(echo "$bin_ver" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
        fi
    fi

    # Package fallback
    if [[ -z "$INST_VER" ]]; then
        local pkg
        pkg=$(pkg_query '^mysql-community-server|^mysql-server|^mariadb-server' | head -1)
        if [[ -n "$pkg" ]]; then
            echo "$pkg" | grep -qi mariadb && INST_TYPE="mariadb" || INST_TYPE="mysql"
            INST_VER=$(echo "$pkg" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
        fi
    fi

    # ── Report ───────────────────────────────────────────────────────────
    if [[ -n "$INST_VER" ]]; then
        echo ""
        line
        echo -e "${BOLD}  MySQL / MariaDB Installation Detected${NC}"
        line
        echo -e "  ${BOLD}Type        :${NC}  ${INST_TYPE}"
        echo -e "  ${BOLD}Version     :${NC}  ${GREEN}${INST_VER}${NC}"
        [[ -n "$INST_PATH" ]] && \
        echo -e "  ${BOLD}Client bin  :${NC}  ${INST_PATH}"

        # Server binary
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
        [[ -n "$srv_bin" && -x "$srv_bin" ]] && \
        echo -e "  ${BOLD}Server bin  :${NC}  ${srv_bin}"

        # Install method
        local inst_pkg
        inst_pkg=$(pkg_query '^mysql-community|^mysql-server|^mariadb-server' | head -1)
        if [[ -n "$inst_pkg" ]]; then
            local method="RPM"; [[ "$OS_FAMILY" == "debian" ]] && method="DEB"
            echo -e "  ${BOLD}Installed by:${NC}  ${method}  (${inst_pkg})"
        elif [[ -n "$INST_PATH" && "$INST_PATH" != *"/usr/bin/"* ]]; then
            echo -e "  ${BOLD}Installed by:${NC}  ${YELLOW}Non-standard / manual (${INST_PATH})${NC}"
        fi

        # Data directory
        local datadir="" cnf_file
        cnf_file=$(find_my_cnf)
        datadir=$(grep -E '^\s*datadir\s*=' "$cnf_file" 2>/dev/null \
                  | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
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
            [[ -f "$cf" ]] && { echo -e "  ${BOLD}Config file :${NC}  ${cf}"; break; }
        done

        # Service status, PID, port, socket, uptime
        local svc_name_detected=""
        for s in mysqld mysql mariadb; do
            systemctl is-enabled "$s" &>/dev/null && { svc_name_detected="$s"; break; }
        done
        if [[ -n "$svc_name_detected" ]]; then
            local svc_state
            svc_state=$(systemctl is-active "$svc_name_detected" 2>/dev/null || echo "unknown")
            if [[ "$svc_state" == "active" ]]; then
                echo -e "  ${BOLD}Service     :${NC}  ${svc_name_detected}.service  ${GREEN}[RUNNING]${NC}"
                local mpid
                mpid=$(systemctl show -p MainPID "$svc_name_detected" 2>/dev/null | cut -d= -f2 || true)
                [[ -n "$mpid" && "$mpid" != "0" ]] && echo -e "  ${BOLD}PID         :${NC}  ${mpid}"

                local port
                port=$(ss -tlnp 2>/dev/null | grep -i mysql | grep -oP ':\K[0-9]+' | head -1 || true)
                [[ -z "$port" ]] && port=$(grep -E '^\s*port\s*=' "$cnf_file" 2>/dev/null | head -1 | grep -oP '[0-9]+' || true)
                [[ -n "$port" ]] && echo -e "  ${BOLD}Port        :${NC}  ${port}"

                local sock
                sock=$(grep -E '^\s*socket\s*=' "$cnf_file" 2>/dev/null | head -1 | sed 's/.*=\s*//' | xargs 2>/dev/null || true)
                [[ -z "$sock" && -S /var/lib/mysql/mysql.sock ]] && sock="/var/lib/mysql/mysql.sock"
                [[ -z "$sock" && -S /var/run/mysqld/mysqld.sock ]] && sock="/var/run/mysqld/mysqld.sock"
                [[ -z "$sock" && -S /tmp/mysql.sock ]] && sock="/tmp/mysql.sock"
                [[ -n "$sock" ]] && echo -e "  ${BOLD}Socket      :${NC}  ${sock}"

                local uptime_str
                uptime_str=$(systemctl show -p ActiveEnterTimestamp "$svc_name_detected" 2>/dev/null | cut -d= -f2 || true)
                [[ -n "$uptime_str" ]] && echo -e "  ${BOLD}Running since:${NC} ${uptime_str}"
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
        INST_VER="unknown"; INST_TYPE="mysql"
    else
        echo ""; line
        echo -e "  ${BOLD}No MySQL / MariaDB installation found on this system.${NC}"
        line; echo ""
    fi
}

###############################################################################
#  BACKUP / DUMP DATABASES
###############################################################################
dump_databases() {
    local caller="${1:-interactive}"   # "interactive" or "pre-reinstall"

    header "Database Backup"

    # ── Ensure MySQL is running & we have credentials ────────────────────
    if ! ensure_mysql_running; then
        err "Cannot backup: MySQL is not running."
        return 1
    fi
    if ! ensure_mysql_credentials; then
        err "Cannot backup: authentication failed."
        return 1
    fi

    # ── List non-default databases ───────────────────────────────────────
    if ! list_user_databases; then
        warn "No non-default databases found. Nothing to backup."
        return 0
    fi

    if (( ${#USER_DBS[@]} == 0 )); then
        warn "No non-default databases found. Nothing to backup."
        return 0
    fi

    echo -e "${BOLD}Non-default databases found:${NC}"
    echo ""
    echo "  0) ALL databases (${#USER_DBS[@]} total)"
    local idx=1
    for _db in "${USER_DBS[@]}"; do
        # Show size of each database
        local db_sz
        db_sz=$(run_sql "$ROOT_PW" -BNe "
            SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)
            FROM information_schema.TABLES
            WHERE table_schema = '${_db}';" 2>/dev/null || echo "?")
        [[ "$db_sz" == "NULL" || -z "$db_sz" ]] && db_sz="0.00"
        echo -e "  ${idx}) ${_db}  ${CYAN}(${db_sz} MB)${NC}"
        (( idx++ ))
    done
    echo ""

    # ── Let user pick databases ──────────────────────────────────────────
    local selected_dbs=()
    while true; do
        echo -e "  ${CYAN}Pick databases to backup (comma-separated, e.g. 1,3):${NC}"
        local sc
        read -rp "$(echo -e "${YELLOW}Selection [0 for all]: ${NC}")" sc

        if [[ "$sc" == "0" || -z "$sc" ]]; then
            selected_dbs=("${USER_DBS[@]}")
            break
        fi

        local valid=true
        IFS=',' read -ra picks <<< "$sc"
        for p in "${picks[@]}"; do
            p="${p## }"; p="${p%% }"
            if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > ${#USER_DBS[@]} )); then
                err "Invalid selection '${p}'. Choose 1-${#USER_DBS[@]} or 0 for all."
                valid=false; break
            fi
            local pick_db="${USER_DBS[$((p-1))]}"
            # Deduplicate
            local already=false
            for existing in "${selected_dbs[@]+"${selected_dbs[@]}"}"; do
                [[ "$existing" == "$pick_db" ]] && { already=true; break; }
            done
            [[ "$already" == false ]] && selected_dbs+=("$pick_db")
        done
        [[ "$valid" == true && ${#selected_dbs[@]} -gt 0 ]] && break
    done

    ok "Selected ${#selected_dbs[@]} database(s) for backup."

    # ── Ask for dump destination ─────────────────────────────────────────
    local default_path="/root/mysql_backups_$(date +%Y%m%d_%H%M%S)"
    local dump_dir
    dump_dir=$(ask_path "Backup destination directory" "$default_path") || {
        err "Invalid backup path."
        return 1
    }

    # ── Check available disk space ───────────────────────────────────────
    local avail_mb
    avail_mb=$(df -m "$(dirname "$dump_dir")" 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    local total_db_mb
    total_db_mb=$(run_sql "$ROOT_PW" -BNe "
        SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1024 / 1024, 0), 0)
        FROM information_schema.TABLES
        WHERE table_schema IN ($(printf "'%s'," "${selected_dbs[@]}" | sed 's/,$//' ));" 2>/dev/null || echo "0")
    [[ "$total_db_mb" == "NULL" || -z "$total_db_mb" ]] && total_db_mb=0

    info "Estimated data size: ~${total_db_mb} MB  |  Available disk: ~${avail_mb} MB"
    if (( total_db_mb > 0 && avail_mb > 0 && total_db_mb * 2 > avail_mb )); then
        warn "Disk space may be tight (dump files can be up to 2x data size)."
        if ! ask_yn "Continue anyway?"; then
            warn "Backup cancelled."
            return 1
        fi
    fi

    # ── Confirm ──────────────────────────────────────────────────────────
    echo ""
    line
    echo -e "${BOLD}  Backup Plan${NC}"
    line
    for d in "${selected_dbs[@]}"; do
        echo -e "  -> ${d}  →  ${dump_dir}/${d}.sql"
    done
    echo -e "  ${BOLD}Destination:${NC} ${dump_dir}"
    line
    echo ""

    if ! ask_yn "Start backup?"; then
        warn "Backup cancelled."
        return 1
    fi

    # ── Dump each database ───────────────────────────────────────────────
    local success=0 fail=0
    for d in "${selected_dbs[@]}"; do
        local outfile="${dump_dir}/${d}.sql"
        info "Dumping '${d}'..."

        if run_mysqldump "$ROOT_PW" \
             --single-transaction --routines --triggers --events \
             --databases "$d" > "$outfile" 2>/dev/null; then

            # Verify the dump file
            if [[ -s "$outfile" ]]; then
                local fsize
                fsize=$(du -sh "$outfile" | awk '{print $1}')
                # Basic sanity: file should start with a MySQL comment or SET
                if head -5 "$outfile" | grep -qiE '^--|^/\*|^SET'; then
                    ok "  ${d} → ${outfile}  (${fsize})"
                    # Generate checksum
                    md5sum "$outfile" > "${outfile}.md5" 2>/dev/null || true
                    (( success++ ))
                else
                    err "  ${d} → dump file looks corrupt (no SQL header)."
                    (( fail++ ))
                fi
            else
                err "  ${d} → dump file is empty."
                rm -f "$outfile"
                (( fail++ ))
            fi
        else
            err "  ${d} → mysqldump failed."
            [[ -f "$outfile" ]] && rm -f "$outfile"
            (( fail++ ))
        fi
    done

    # ── Summary ──────────────────────────────────────────────────────────
    echo ""
    line
    echo -e "${BOLD}  Backup Summary${NC}"
    line
    echo -e "  ${GREEN}Succeeded: ${success}${NC}  |  ${RED}Failed: ${fail}${NC}"
    echo -e "  ${BOLD}Location: ${dump_dir}${NC}"
    if (( success > 0 )); then
        echo ""
        echo -e "  ${BOLD}Files:${NC}"
        ls -lh "${dump_dir}"/*.sql 2>/dev/null | awk '{print "    " $NF "  (" $5 ")"}'
    fi
    line

    LAST_DUMP_DIR="$dump_dir"

    if (( fail > 0 && caller == "pre-reinstall" )); then
        echo ""
        warn "Some backups failed."
        if ! ask_yn "Continue with reinstall despite backup failures?"; then
            err "Reinstall cancelled. Fix the backup issues and try again."
            return 1
        fi
    fi

    return 0
}

###############################################################################
#  RESTORE DATABASES
###############################################################################
restore_databases() {
    local source_dir="${1:-}"   # optional: pre-set directory path

    header "Database Restore"

    # ── Ensure MySQL is running & we have credentials ────────────────────
    if ! ensure_mysql_running; then
        err "Cannot restore: MySQL is not running."
        return 1
    fi
    if ! ensure_mysql_credentials; then
        err "Cannot restore: authentication failed."
        return 1
    fi

    # ── Ask for dump source (file or directory) ──────────────────────────
    if [[ -z "$source_dir" ]]; then
        echo -e "Enter the path to a ${BOLD}.sql file${NC} or a ${BOLD}directory${NC} containing .sql files."
        local src
        src=$(ask_text "Dump file or directory path")
        src="${src/#\~/$HOME}"
    else
        local src="$source_dir"
    fi

    # ── Determine what we're working with ────────────────────────────────
    local dump_files=()

    if [[ -f "$src" ]]; then
        # Single file
        if [[ "$src" == *.sql || "$src" == *.sql.gz ]]; then
            dump_files+=("$src")
        else
            err "File must be .sql or .sql.gz: ${src}"
            return 1
        fi
    elif [[ -d "$src" ]]; then
        # Directory: scan for .sql and .sql.gz files
        while IFS= read -r -d '' f; do
            dump_files+=("$f")
        done < <(find "$src" -maxdepth 1 \( -name '*.sql' -o -name '*.sql.gz' \) -type f -print0 2>/dev/null | sort -z)

        if (( ${#dump_files[@]} == 0 )); then
            err "No .sql or .sql.gz files found in: ${src}"
            return 1
        fi
    else
        err "Path not found: ${src}"
        return 1
    fi

    # ── Show available dump files ────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Available dump files:${NC}"
    echo ""
    echo "  0) ALL files (${#dump_files[@]} total)"
    local idx=1
    for f in "${dump_files[@]}"; do
        local fname; fname=$(basename "$f")
        local fsize; fsize=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        echo -e "  ${idx}) ${fname}  ${CYAN}(${fsize})${NC}"
        (( idx++ ))
    done
    echo ""

    # ── Let user pick files ──────────────────────────────────────────────
    local selected_files=()
    while true; do
        echo -e "  ${CYAN}Pick files to restore (comma-separated, e.g. 1,2):${NC}"
        local sc
        read -rp "$(echo -e "${YELLOW}Selection [0 for all]: ${NC}")" sc

        if [[ "$sc" == "0" || -z "$sc" ]]; then
            selected_files=("${dump_files[@]}")
            break
        fi

        local valid=true
        selected_files=()
        IFS=',' read -ra picks <<< "$sc"
        for p in "${picks[@]}"; do
            p="${p## }"; p="${p%% }"
            if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > ${#dump_files[@]} )); then
                err "Invalid selection '${p}'. Choose 1-${#dump_files[@]} or 0 for all."
                valid=false; break
            fi
            local pick="${dump_files[$((p-1))]}"
            local already=false
            for existing in "${selected_files[@]+"${selected_files[@]}"}"; do
                [[ "$existing" == "$pick" ]] && { already=true; break; }
            done
            [[ "$already" == false ]] && selected_files+=("$pick")
        done
        [[ "$valid" == true && ${#selected_files[@]} -gt 0 ]] && break
    done

    # ── For each file, determine target DB and action ────────────────────
    echo ""
    echo -e "${BOLD}Restore plan:${NC}"
    line

    local restore_plan=()   # "file|target_db|action" entries

    for f in "${selected_files[@]}"; do
        local fname; fname=$(basename "$f")
        local target_db=""

        # Try to infer DB name from filename (dbname.sql or dbname.sql.gz)
        target_db=$(echo "$fname" | sed -E 's/\.(sql|sql\.gz)$//')

        # Check if file uses CREATE DATABASE inside (--databases flag)
        local has_create_db=false
        if [[ "$f" == *.sql.gz ]]; then
            zcat "$f" 2>/dev/null | head -50 | grep -qi "CREATE DATABASE" && has_create_db=true
        else
            head -50 "$f" 2>/dev/null | grep -qi "CREATE DATABASE" && has_create_db=true
        fi

        local action=""
        if [[ "$has_create_db" == true ]]; then
            # Dump was made with --databases; it will create/use the DB itself
            action="auto (dump contains CREATE DATABASE)"
            echo -e "  ${fname}  →  ${GREEN}${action}${NC}"
        else
            # Need to specify target database
            echo -e "  ${fname}  →  target database: ${BOLD}${target_db}${NC}"
            echo -ne "    ${CYAN}Change target DB name? (Enter to keep '${target_db}', or type new name): ${NC}"
            local new_name
            read -r new_name
            new_name="${new_name## }"; new_name="${new_name%% }"
            [[ -n "$new_name" ]] && target_db="$new_name"

            # Check if target DB already exists
            local db_exists
            db_exists=$(run_sql "$ROOT_PW" -BNe \
                "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${target_db}';" \
                2>/dev/null || echo "0")
            if [[ "$db_exists" == "1" ]]; then
                warn "  Database '${target_db}' already exists."
                echo "    1) Drop and recreate (clean restore)"
                echo "    2) Import into existing DB (merge/overwrite tables)"
                echo "    3) Skip this file"
                local choice
                read -rp "$(echo -e "    ${YELLOW}Choice [1/2/3]: ${NC}")" choice
                case "$choice" in
                    1) action="drop_recreate" ;;
                    2) action="merge" ;;
                    3) continue ;;
                    *) action="merge"; warn "    Defaulting to merge." ;;
                esac
            else
                action="create_new"
            fi
        fi

        restore_plan+=("${f}|${target_db}|${action}")
    done

    if (( ${#restore_plan[@]} == 0 )); then
        warn "No files selected for restore."
        return 0
    fi

    line
    echo ""
    if ! ask_yn "Proceed with restore?"; then
        warn "Restore cancelled."
        return 0
    fi

    # ── Execute restore ──────────────────────────────────────────────────
    local success=0 fail=0

    for entry in "${restore_plan[@]}"; do
        IFS='|' read -r f target_db action <<< "$entry"
        local fname; fname=$(basename "$f")

        info "Restoring ${fname}..."

        # Prepare the database
        case "$action" in
            drop_recreate)
                info "  Dropping '${target_db}'..."
                run_sql "$ROOT_PW" -e "DROP DATABASE IF EXISTS \`${target_db}\`;" 2>/dev/null || true
                info "  Creating '${target_db}'..."
                run_sql "$ROOT_PW" -e "CREATE DATABASE \`${target_db}\` CHARACTER SET utf8mb4;" 2>/dev/null || {
                    err "  Could not create database '${target_db}'. Skipping."
                    (( fail++ )); continue
                }
                ;;
            create_new)
                info "  Creating '${target_db}'..."
                run_sql "$ROOT_PW" -e "CREATE DATABASE IF NOT EXISTS \`${target_db}\` CHARACTER SET utf8mb4;" 2>/dev/null || {
                    err "  Could not create database '${target_db}'. Skipping."
                    (( fail++ )); continue
                }
                ;;
            merge)
                info "  Importing into existing '${target_db}'..."
                ;;
            # "auto" dumps with CREATE DATABASE — no prep needed
        esac

        # Import the dump
        local import_rc=0
        if [[ "$f" == *.sql.gz ]]; then
            if [[ "$action" == "auto"* ]]; then
                zcat "$f" 2>/dev/null | run_sql "$ROOT_PW" 2>/dev/null || import_rc=$?
            else
                zcat "$f" 2>/dev/null | run_sql "$ROOT_PW" "$target_db" 2>/dev/null || import_rc=$?
            fi
        else
            if [[ "$action" == "auto"* ]]; then
                run_sql "$ROOT_PW" < "$f" 2>/dev/null || import_rc=$?
            else
                run_sql "$ROOT_PW" "$target_db" < "$f" 2>/dev/null || import_rc=$?
            fi
        fi

        if (( import_rc == 0 )); then
            # Verify: count tables
            local tbl_count="?"
            if [[ -n "$target_db" && "$action" != "auto"* ]]; then
                tbl_count=$(run_sql "$ROOT_PW" -BNe \
                    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${target_db}';" \
                    2>/dev/null || echo "?")
            fi
            ok "  ${fname} → restored successfully (${tbl_count} tables)."
            (( success++ ))
        else
            err "  ${fname} → import failed (exit code ${import_rc})."
            (( fail++ ))
        fi
    done

    # ── Summary ──────────────────────────────────────────────────────────
    echo ""
    line
    echo -e "${BOLD}  Restore Summary${NC}"
    line
    echo -e "  ${GREEN}Succeeded: ${success}${NC}  |  ${RED}Failed: ${fail}${NC}"
    line

    if (( success > 0 )); then
        echo ""
        echo -e "${BOLD}Current databases:${NC}"
        run_sql "$ROOT_PW" -e "SHOW DATABASES;" 2>/dev/null || true
    fi

    return 0
}

###############################################################################
#  PURGE EVERYTHING
###############################################################################
purge_all() {
    info "Stopping services..."
    systemctl stop mysqld  2>/dev/null || true
    systemctl stop mariadb 2>/dev/null || true
    systemctl stop mysql   2>/dev/null || true
    systemctl disable mysqld  2>/dev/null || true
    systemctl disable mariadb 2>/dev/null || true

    info "Removing packages..."
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        yum remove -y --setopt='*.skip_if_unavailable=1' \
            'mysql*' 'MySQL*' 'mariadb*' 'MariaDB*' 2>/dev/null || true
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y --purge 'mysql*' 'mariadb*' 'libmysql*' 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    info "Cleaning data, logs, configs..."
    rm -rf /var/lib/mysql /var/log/mysqld.log /var/log/mysql \
           /var/log/mariadb /var/run/mysqld \
           /etc/my.cnf /etc/my.cnf.rpmsave /etc/my.cnf.d \
           /etc/mysql 2>/dev/null || true

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        rm -f /etc/yum.repos.d/mysql-community*.repo 2>/dev/null || true
    else
        rm -f /etc/apt/sources.list.d/mysql*.list /etc/apt/sources.list.d/mysql*.sources 2>/dev/null || true
    fi

    # Clean non-standard installs
    if [[ -n "${INST_PATH:-}" && "$INST_PATH" != "/usr/bin/mysql" ]]; then
        local inst_dir
        inst_dir=$(dirname "$(dirname "$INST_PATH")")
        if [[ "$inst_dir" != "/" && "$inst_dir" != "/usr" ]]; then
            info "Removing non-standard install at ${inst_dir}..."
            rm -rf "$inst_dir" 2>/dev/null || true
        fi
    fi

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        yum clean all --setopt='*.skip_if_unavailable=1' &>/dev/null || true
    else
        apt-get clean &>/dev/null || true
    fi
    ok "All MySQL / MariaDB components removed."
}

###############################################################################
#  INSTALL — RHEL
###############################################################################
install_mysql_rhel() {
    local ver="$1"
    local mm; mm=$(echo "$ver" | grep -oP '^\d+\.\d+')

    local repo_url=""
    case "$mm" in
        5.7) repo_url="https://dev.mysql.com/get/mysql57-community-release-el7-11.noarch.rpm" ;;
        8.0) repo_url="https://dev.mysql.com/get/mysql80-community-release-el7-11.noarch.rpm" ;;
        8.4) repo_url="https://dev.mysql.com/get/mysql84-community-release-el7-1.noarch.rpm"  ;;
        *)   warn "No pre-built Oracle repo for ${mm}. Falling back to 8.0 repo."
             repo_url="https://dev.mysql.com/get/mysql80-community-release-el7-11.noarch.rpm" ;;
    esac

    info "Adding MySQL Community repo..."
    yum remove -y --setopt='*.skip_if_unavailable=1' 'mysql*-community-release' 2>/dev/null || true
    if ! rpm -Uvh "$repo_url" 2>&1; then
        err "Could not add MySQL repo."; return 1
    fi

    info "Importing GPG keys..."
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 2>/dev/null || true
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 2>/dev/null || true
    rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql      2>/dev/null || true

    info "Installing mysql-community-server (this may take a minute)..."
    if ! yum install -y --setopt='*.skip_if_unavailable=1' \
            mysql-community-server mysql-community-client 2>&1; then
        warn "GPG check may have failed. Retrying with --nogpgcheck..."
        if ! yum install -y --nogpgcheck --setopt='*.skip_if_unavailable=1' \
                mysql-community-server mysql-community-client 2>&1; then
            err "MySQL installation failed."; return 1
        fi
    fi

    systemctl start "$SVC_NAME" || { err "${SVC_NAME} would not start."; return 1; }
    systemctl enable "$SVC_NAME" 2>/dev/null || true
    ok "MySQL server installed and running."
}

###############################################################################
#  INSTALL — Debian / Ubuntu
###############################################################################
install_mysql_debian() {
    local ver="$1"
    local mm; mm=$(echo "$ver" | grep -oP '^\d+\.\d+')
    export DEBIAN_FRONTEND=noninteractive

    info "Adding MySQL APT repository..."
    local apt_config_url="https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb"
    local apt_deb="${SECURE_TMP}/mysql-apt-config.deb"

    if ! wget -q -O "$apt_deb" "$apt_config_url" 2>&1; then
        if ! curl -fsSL -o "$apt_deb" "$apt_config_url" 2>&1; then
            err "Could not download MySQL APT config."; return 1
        fi
    fi

    local mysql_select="mysql-8.0"
    case "$mm" in
        5.7) mysql_select="mysql-5.7" ;;
        8.0) mysql_select="mysql-8.0" ;;
        8.4) mysql_select="mysql-8.4-lts" ;;
        *)   warn "No pre-built APT repo for ${mm}. Defaulting to 8.0." ;;
    esac

    echo "mysql-apt-config mysql-apt-config/select-server select ${mysql_select}" | debconf-set-selections 2>/dev/null || true
    echo "mysql-apt-config mysql-apt-config/select-tools select Enabled" | debconf-set-selections 2>/dev/null || true

    dpkg -i "$apt_deb" 2>&1 || { err "Could not install MySQL APT config."; return 1; }
    rm -f "$apt_deb"

    info "Importing GPG keys..."
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys B7B3B788A8D3785C 2>/dev/null || true
    command -v gpg &>/dev/null && \
        wget -qO- https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 \
        | gpg --dearmor -o /usr/share/keyrings/mysql-archive-keyring.gpg 2>/dev/null || true

    info "Updating package index..."
    apt-get update 2>&1 || warn "Some repositories may have failed."

    echo "mysql-community-server mysql-community-server/root-pass password " | debconf-set-selections 2>/dev/null || true
    echo "mysql-community-server mysql-community-server/re-root-pass password " | debconf-set-selections 2>/dev/null || true
    echo "mysql-community-server mysql-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)" | debconf-set-selections 2>/dev/null || true

    info "Installing mysql-community-server..."
    if ! apt-get install -y mysql-community-server mysql-community-client 2>&1; then
        warn "mysql-community-* failed. Trying mysql-server..."
        if ! apt-get install -y mysql-server mysql-client 2>&1; then
            err "MySQL installation failed."; return 1
        fi
    fi

    mkdir -p /var/run/mysqld 2>/dev/null || true
    chown mysql:mysql /var/run/mysqld 2>/dev/null || true

    systemctl start "$SVC_NAME" || { err "${SVC_NAME} would not start."; return 1; }
    systemctl enable "$SVC_NAME" 2>/dev/null || true
    ok "MySQL server installed and running."
}

###############################################################################
#  INSTALL — unified entry point + post-install root password + hardening
###############################################################################
install_mysql() {
    local ver="$1"

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        install_mysql_rhel "$ver" || return 1
    else
        install_mysql_debian "$ver" || return 1
    fi

    # ── Wait for temp password ───────────────────────────────────────────
    info "Waiting for mysqld to initialize..."
    local temp_pw="" attempt
    for attempt in $(seq 1 15); do
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
        local new_pw; new_pw=$(ask_pass "Enter NEW MySQL root password")
        local esc_pw; esc_pw=$(sql_escape "$new_pw")

        local optfile="${SECURE_TMP}/tmp_opts.cnf"
        cat > "$optfile" <<EOF
[client]
user=root
password=${temp_pw}
EOF
        chmod 600 "$optfile"
        if mysql --defaults-extra-file="$optfile" --connect-expired-password \
             -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_pw}';" 2>/dev/null; then
            ok "Root password set."
            ROOT_PW="$new_pw"
        else
            err "Automatic password change failed."
            warn "You may need to run: mysql_secure_installation"
            ROOT_PW=""
        fi
        rm -f "$optfile"
    else
        # Debian auth_socket or empty password
        if run_sql "" -e "SELECT 1" &>/dev/null; then
            info "Root access available (auth_socket or empty password)."
            local new_pw; new_pw=$(ask_pass "Enter NEW MySQL root password")
            local esc_npw; esc_npw=$(sql_escape "$new_pw")
            if run_sql "" -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${esc_npw}';" 2>/dev/null \
               || run_sql "" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_npw}';" 2>/dev/null \
               || run_sql "" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${esc_npw}');" 2>/dev/null; then
                ok "Root password set."
                ROOT_PW="$new_pw"
            else
                warn "Could not set root password."
                ROOT_PW=""
            fi
        else
            local new_pw; new_pw=$(ask_pass "Enter NEW MySQL root password")
            local esc_npw; esc_npw=$(sql_escape "$new_pw")
            if run_sql "" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_npw}';" 2>/dev/null \
               || run_sql "" -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${esc_npw}');" 2>/dev/null; then
                ok "Root password set."
                ROOT_PW="$new_pw"
            else
                warn "Could not set root password."
                ROOT_PW=""
            fi
        fi
    fi

    # ── Basic hardening ──────────────────────────────────────────────────
    if [[ -n "${ROOT_PW}" ]]; then
        info "Applying basic hardening..."
        run_sql "$ROOT_PW" -e "
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;" 2>/dev/null && ok "Hardening applied." || warn "Some hardening steps skipped."
    fi
    return 0
}

###############################################################################
#  COLLECT ONE USER INTERACTIVELY
###############################################################################
collect_user() {
    # Uses global DBS=() and USERS=() arrays (Bash 4.2 compat — no namerefs)

    line
    echo -e "${BOLD}New MySQL User${NC}"

    local uname uhost upass upriv uscope ugrant=""

    # ── Username ─────────────────────────────────────────────────────────
    while true; do
        uname=$(ask_text "Username")
        if validate_identifier "$uname" "Username"; then
            (( ${#uname} > 32 )) && { err "MySQL username max 32 characters."; continue; }
            break
        fi
    done

    # ── Host ─────────────────────────────────────────────────────────────
    echo -e "  1) localhost   2) Any host (%)   3) Specific host/IP"
    local hc; read -rp "$(echo -e "${YELLOW}Choose [1/2/3]: ${NC}")" hc
    case "$hc" in
        2) uhost="%" ;;
        3) while true; do uhost=$(ask_text "Host / IP"); validate_identifier "$uhost" "Host" && break; done ;;
        *) uhost="localhost" ;;
    esac

    # ── Password ─────────────────────────────────────────────────────────
    upass=$(ask_pass "Password for '${uname}'@'${uhost}'")

    # ── Privileges ───────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Choose a privilege role:${NC}"
    echo "  1) ALL PRIVILEGES       — Full admin access"
    echo "  2) READ ONLY            — SELECT"
    echo "  3) READ / WRITE         — SELECT, INSERT, UPDATE, DELETE"
    echo "  4) DBA                  — ALL PRIVILEGES + GRANT OPTION"
    echo "  5) DEVELOPER            — SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER"
    echo "  6) BACKUP               — SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER"
    echo "  7) CUSTOM               — type your own list"
    local rc; read -rp "$(echo -e "${YELLOW}Role [1-7]: ${NC}")" rc
    case "$rc" in
        1) upriv="ALL PRIVILEGES" ;;
        2) upriv="SELECT" ;;
        3) upriv="SELECT, INSERT, UPDATE, DELETE" ;;
        4) upriv="ALL PRIVILEGES"; ugrant="WITH GRANT OPTION" ;;
        5) upriv="SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER" ;;
        6) upriv="SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER" ;;
        7) upriv=$(ask_text "Privileges (comma-separated)") ;;
        *) upriv="SELECT"; warn "Defaulted to SELECT." ;;
    esac

    # ── Scope ────────────────────────────────────────────────────────────
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
            local sc; read -rp "$(echo -e "${YELLOW}Selection [0 for all]: ${NC}")" sc
            if [[ "$sc" == "0" || -z "$sc" ]]; then uscope="*.*"; break; fi

            local scope_list=() valid_pick=true
            IFS=',' read -ra picks <<< "$sc"
            for p in "${picks[@]}"; do
                p="${p## }"; p="${p%% }"
                if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > ${#DBS[@]} )); then
                    err "Invalid '${p}'. Choose 1-${#DBS[@]} or 0."
                    valid_pick=false; break
                fi
                local pick_db="${DBS[$((p-1))]}"
                local already=false
                for existing in "${scope_list[@]+"${scope_list[@]}"}"; do
                    [[ "$existing" == "$pick_db" ]] && { already=true; break; }
                done
                [[ "$already" == false ]] && scope_list+=("$pick_db")
            done
            [[ "$valid_pick" == false ]] && continue
            if (( ${#scope_list[@]} == 1 )); then
                uscope="${scope_list[0]}.*"; break
            else
                uscope=$(printf '%s;' "${scope_list[@]}"); uscope="${uscope%;}"
                break
            fi
        done
    else
        echo "  1) All databases (*.*)   2) Specific database"
        local sc; read -rp "$(echo -e "${YELLOW}Scope [1/2]: ${NC}")" sc
        case "$sc" in
            2) local dbn; while true; do dbn=$(ask_text "Database name"); validate_identifier "$dbn" "Database name" && break; done
               uscope="${dbn}.*" ;;
            *) uscope="*.*" ;;
        esac
    fi

    local US=$'\x1F'
    USERS+=("${uname}${US}${uhost}${US}${upass}${US}${upriv}${US}${uscope}${US}${ugrant}")
    ok "Queued  '${uname}'@'${uhost}'  ->  [${upriv}] on ${uscope} ${ugrant}"
}

###############################################################################
#  CREATE DATABASES & USERS  (the execution engine)
###############################################################################
execute_db_and_users() {
    # Uses global DBS=() and USERS=() arrays (Bash 4.2 compat — no namerefs)

    # ── Databases ────────────────────────────────────────────────────────
    if (( ${#DBS[@]} > 0 )); then
        info "Creating databases..."

        # Pick collation
        local collation="utf8mb4_unicode_ci"
        local running_ver
        running_ver=$(run_sql "$ROOT_PW" -BNe "SELECT VERSION();" 2>/dev/null || true)
        if [[ -n "$running_ver" ]]; then
            local major minor patch
            IFS='.' read -r major minor patch <<< "$(echo "$running_ver" | grep -oP '^\d+\.\d+\.\d+')"
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
    fi

    # ── Users ────────────────────────────────────────────────────────────
    if (( ${#USERS[@]} > 0 )); then
        info "Creating users..."
        for u in "${USERS[@]}"; do
            local _n _h _p _pr _sc _g
            IFS=$'\x1F' read -r _n _h _p _pr _sc _g <<< "$u"
            local esc_p; esc_p=$(sql_escape "$_p")

            if run_sql "$ROOT_PW" -e \
                "CREATE USER IF NOT EXISTS '${_n}'@'${_h}' IDENTIFIED BY '${esc_p}';" 2>/dev/null; then
                ok "User '${_n}'@'${_h}' created."
            else
                if run_sql "$ROOT_PW" -e \
                    "ALTER USER '${_n}'@'${_h}' IDENTIFIED BY '${esc_p}';" 2>/dev/null; then
                    ok "User '${_n}'@'${_h}' existed -> password updated."
                else
                    err "Could not create user '${_n}'@'${_h}'."
                fi
            fi

            # Grants
            if [[ "$_sc" == *";"* ]]; then
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
    fi
}

###############################################################################
#  SHOW EXECUTION PLAN (shared by install/reinstall/manage workflows)
###############################################################################
show_plan() {
    local action="$1" target_ver="$2"
    # Uses global DBS=() and USERS=() arrays (Bash 4.2 compat — no namerefs)

    header "Execution Plan — Please Review"
    line

    echo -e "${BOLD}OS:${NC}  ${OS_NAME} (${OS_FAMILY})"
    echo ""
    echo -e "${BOLD}Installation:${NC}"
    case "$action" in
        fresh_install) echo -e "  -> Fresh install MySQL ${GREEN}${target_ver}${NC}" ;;
        reinstall)     echo -e "  -> ${RED}REMOVE${NC} ${INST_TYPE} ${INST_VER}  ->  install MySQL ${GREEN}${target_ver}${NC}" ;;
        skip)          echo -e "  -> Keep existing ${INST_TYPE} ${INST_VER} (no install changes)" ;;
        manage_only)   echo -e "  -> No install changes (managing existing MySQL)" ;;
    esac

    echo ""
    echo -e "${BOLD}Databases to create: ${#DBS[@]}${NC}"
    for d in "${DBS[@]+"${DBS[@]}"}"; do echo -e "  -> ${d}"; done

    echo ""
    echo -e "${BOLD}Users to create: ${#USERS[@]}${NC}"
    for u in "${USERS[@]+"${USERS[@]}"}"; do
        local _n _h _p _pr _sc _g
        IFS=$'\x1F' read -r _n _h _p _pr _sc _g <<< "$u"
        local display_sc="$_sc"
        if [[ "$_sc" == *";"* ]]; then
            display_sc=$(echo "$_sc" | sed 's/;/.*, /g'); display_sc="${display_sc}.*"
        fi
        echo -e "  -> '${_n}'@'${_h}'  [${_pr}] on ${display_sc}  ${_g}"
    done

    line
    echo ""
    if [[ "$action" == "reinstall" ]]; then
        echo -e "  ${RED}${BOLD}!! WARNING: ALL EXISTING MYSQL DATA WILL BE PERMANENTLY DELETED${NC}"
        echo ""
    fi
}

###############################################################################
#  SHOW FINAL STATUS
###############################################################################
show_final_status() {
    header "Final Status"

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
    systemctl status "$SVC_NAME" --no-pager 2>/dev/null | head -5 \
        || systemctl status mysqld --no-pager 2>/dev/null | head -5 \
        || systemctl status mysql --no-pager 2>/dev/null | head -5 \
        || true

    line
    info "Full session log: ${LOG_FILE}"
    echo ""
}

###############################################################################
#  COLLECT DATABASES & USERS (interactive — shared by workflows)
###############################################################################
collect_dbs_and_users() {
    # Uses global DBS=() and USERS=() arrays (Bash 4.2 compat — no namerefs)

    # ── Databases ────────────────────────────────────────────────────────
    header "Database Creation"
    if ask_yn "Create new databases?"; then
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

    # ── Users ────────────────────────────────────────────────────────────
    header "User Creation"
    if ask_yn "Create MySQL users?"; then
        while true; do
            collect_user
            echo ""
            ask_yn "Create another user?" || break
        done
    else
        info "Skipping user creation."
    fi
}

###############################################################################
#  WORKFLOW: Fresh Install
###############################################################################
workflow_fresh_install() {
    header "Fresh Install"

    detect_installed

    if [[ -n "$INST_VER" && "$INST_VER" != "unknown" ]]; then
        warn "MySQL ${INST_VER} is already installed."
        warn "Use option 2 (Reinstall) to replace it, or option 6 (Uninstall) to remove it."
        return
    fi

    # ── Target version ───────────────────────────────────────────────────
    echo -e "  Popular choices: ${BOLD}5.7.44${NC}  ${BOLD}8.0.40${NC}  ${BOLD}8.4.3${NC}"
    local target_ver
    while true; do
        target_ver=$(ask_text "MySQL version to install (e.g. 8.0.40)")
        validate_version "$target_ver" && break
        err "Invalid format. Use X.Y.Z"
    done

    # ── Collect databases & users ────────────────────────────────────────
    DBS=() USERS=()
    collect_dbs_and_users

    # ── Show plan ────────────────────────────────────────────────────────
    show_plan "fresh_install" "$target_ver"
    if ! ask_yn "Proceed?"; then
        warn "Aborted. No changes made."; return
    fi

    # ── Execute ──────────────────────────────────────────────────────────
    check_network || return
    info "Cleaning any remnants..."
    purge_all
    info "Installing MySQL ${target_ver}..."
    install_mysql "$target_ver" || { err "Install failed. See log: ${LOG_FILE}"; return; }

    # Ensure running
    ensure_mysql_running || return
    if [[ -z "$ROOT_PW" ]]; then
        ensure_mysql_credentials || return
    fi

    execute_db_and_users
    show_final_status
    ok "Fresh install complete!"
}

###############################################################################
#  WORKFLOW: Reinstall  (backup → purge → install)
###############################################################################
workflow_reinstall() {
    header "Reinstall MySQL"

    detect_installed

    if [[ -z "$INST_VER" ]]; then
        warn "No MySQL installation detected."
        warn "Use option 1 (Fresh Install) instead."
        return
    fi

    echo -e "  Current: ${BOLD}${INST_TYPE} ${INST_VER}${NC}"
    echo ""

    # ── Target version ───────────────────────────────────────────────────
    echo -e "  Popular choices: ${BOLD}5.7.44${NC}  ${BOLD}8.0.40${NC}  ${BOLD}8.4.3${NC}"
    local target_ver
    while true; do
        target_ver=$(ask_text "MySQL version to install (e.g. 8.0.40)")
        validate_version "$target_ver" && break
        err "Invalid format. Use X.Y.Z"
    done

    # ── BACKUP OFFER — the key improvement ───────────────────────────────
    echo ""
    line
    echo -e "  ${BOLD}${RED}!! REINSTALL WILL DELETE ALL EXISTING DATA !!${NC}"
    line
    echo ""

    local did_backup=false
    if ask_yn "Do you want to backup existing databases first?"; then
        # Need MySQL running for backup
        if ! ensure_mysql_running; then
            err "MySQL is not running — cannot backup."
            if ! ask_yn "Continue WITHOUT backup? ALL DATA WILL BE LOST"; then
                warn "Aborted."; return
            fi
        else
            if dump_databases "pre-reinstall"; then
                did_backup=true
                ok "Backup completed successfully."
            else
                if ! ask_yn "Backup had issues. Continue with reinstall anyway?"; then
                    warn "Aborted."; return
                fi
            fi
        fi
    else
        warn "No backup will be taken. All data will be lost."
        if ! ask_yn "Are you sure you want to continue WITHOUT backup?"; then
            warn "Aborted."; return
        fi
    fi

    # ── Config backup (always) ───────────────────────────────────────────
    local cnf_file; cnf_file=$(find_my_cnf)
    if [[ -f "$cnf_file" ]]; then
        local cfg_bak="/root/my.cnf.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$cnf_file" "$cfg_bak" 2>/dev/null || true
        info "Config backed up to ${cfg_bak}"
    fi

    # ── Collect new databases & users ────────────────────────────────────
    DBS=() USERS=()
    collect_dbs_and_users

    # ── Show plan ────────────────────────────────────────────────────────
    show_plan "reinstall" "$target_ver"
    if [[ "$did_backup" == true ]]; then
        echo -e "  ${GREEN}Backup saved to: ${LAST_DUMP_DIR}${NC}"
        echo ""
    fi
    if ! ask_yn "FINAL CONFIRMATION — Proceed with reinstall?"; then
        warn "Aborted. No changes made."; return
    fi

    # ── Execute ──────────────────────────────────────────────────────────
    check_network || return
    info "Purging existing installation..."
    purge_all
    info "Installing MySQL ${target_ver}..."
    install_mysql "$target_ver" || { err "Install failed."; return; }

    ensure_mysql_running || return
    if [[ -z "$ROOT_PW" ]]; then
        ensure_mysql_credentials || return
    fi

    execute_db_and_users

    # ── Offer restore from earlier backup ────────────────────────────────
    if [[ "$did_backup" == true && -n "$LAST_DUMP_DIR" ]]; then
        echo ""
        if ask_yn "Restore the databases you backed up earlier?"; then
            restore_databases "$LAST_DUMP_DIR"
        fi
    fi

    show_final_status
    ok "Reinstall complete!"
}

###############################################################################
#  WORKFLOW: Backup Only
###############################################################################
workflow_backup() {
    detect_installed
    if [[ -z "$INST_VER" ]]; then
        err "No MySQL installation found. Nothing to backup."
        return
    fi
    dump_databases "interactive"
}

###############################################################################
#  WORKFLOW: Restore Only
###############################################################################
workflow_restore() {
    detect_installed
    if [[ -z "$INST_VER" ]]; then
        err "No MySQL installation found. Install MySQL first."
        return
    fi
    restore_databases ""
}

###############################################################################
#  WORKFLOW: Create DBs & Users on Running MySQL
###############################################################################
workflow_manage() {
    header "Create Databases & Users"

    detect_installed
    if [[ -z "$INST_VER" ]]; then
        err "No MySQL installation found. Install MySQL first."; return
    fi

    if ! ensure_mysql_running; then
        err "MySQL is not running."; return
    fi
    if ! ensure_mysql_credentials; then
        err "Authentication failed."; return
    fi

    DBS=() USERS=()
    collect_dbs_and_users

    show_plan "manage_only" ""
    if ! ask_yn "Proceed?"; then
        warn "Aborted."; return
    fi

    execute_db_and_users
    show_final_status
    ok "Done!"
}

###############################################################################
#  WORKFLOW: Uninstall
###############################################################################
workflow_uninstall() {
    header "Uninstall MySQL"

    detect_installed
    if [[ -z "$INST_VER" ]]; then
        warn "No MySQL installation found. Nothing to uninstall."
        return
    fi

    echo -e "  ${RED}${BOLD}This will PERMANENTLY REMOVE MySQL and ALL DATA.${NC}"
    echo ""

    # ── Offer backup first ───────────────────────────────────────────────
    if ask_yn "Backup databases before uninstalling?"; then
        if ensure_mysql_running; then
            dump_databases "pre-reinstall" || true
        else
            warn "MySQL not running — cannot backup."
        fi
    fi

    echo ""
    if ! ask_yn "FINAL CONFIRMATION — Delete MySQL and ALL data?"; then
        warn "Aborted."; return
    fi

    # Config backup
    local cnf_file; cnf_file=$(find_my_cnf)
    if [[ -f "$cnf_file" ]]; then
        local cfg_bak="/root/my.cnf.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$cnf_file" "$cfg_bak" 2>/dev/null || true
        info "Config backed up to ${cfg_bak}"
    fi

    purge_all

    # Verify
    if command -v mysql &>/dev/null; then
        warn "mysql binary still found at $(command -v mysql)."
        warn "You may need to remove it manually."
    else
        ok "MySQL completely removed."
    fi

    [[ -n "$LAST_DUMP_DIR" ]] && info "Your backup is at: ${LAST_DUMP_DIR}"
}

###############################################################################
#  WORKFLOW: Show Status
###############################################################################
workflow_status() {
    header "Current MySQL Status"
    detect_installed

    if [[ -n "$INST_VER" ]] && ensure_mysql_running 2>/dev/null; then
        if ensure_mysql_credentials 2>/dev/null; then
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
            echo -e "${BOLD}Database Sizes:${NC}"
            run_sql "$ROOT_PW" -e "
SELECT table_schema AS 'Database',
       ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.TABLES
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
GROUP BY table_schema
ORDER BY SUM(data_length + index_length) DESC;" 2>/dev/null || true
        fi
    fi
}

###############################################################################
#  MAIN MENU
###############################################################################
show_menu() {
    echo ""
    line
    echo -e "${BOLD}  What would you like to do?${NC}"
    line
    echo ""
    echo -e "  ${BOLD}1)${NC}  Install MySQL           ${CYAN}(fresh install on bare system)${NC}"
    echo -e "  ${BOLD}2)${NC}  Reinstall MySQL         ${CYAN}(backup → purge → install)${NC}"
    echo -e "  ${BOLD}3)${NC}  Backup Databases        ${CYAN}(dump to SQL files)${NC}"
    echo -e "  ${BOLD}4)${NC}  Restore Databases       ${CYAN}(from SQL dump files)${NC}"
    echo -e "  ${BOLD}5)${NC}  Create DBs & Users      ${CYAN}(on running MySQL)${NC}"
    echo -e "  ${BOLD}6)${NC}  Uninstall MySQL         ${CYAN}(purge everything)${NC}"
    echo -e "  ${BOLD}7)${NC}  Show Status             ${CYAN}(detect & display info)${NC}"
    echo -e "  ${BOLD}0)${NC}  Exit"
    echo ""
}

main() {
    detect_os
    header "MySQL Manager  —  ${OS_NAME}  (v4)"

    while true; do
        show_menu
        local choice
        read -rp "$(echo -e "${YELLOW}Choose [0-7]: ${NC}")" choice

        case "$choice" in
            1) workflow_fresh_install  ;;
            2) workflow_reinstall      ;;
            3) workflow_backup         ;;
            4) workflow_restore        ;;
            5) workflow_manage         ;;
            6) workflow_uninstall      ;;
            7) workflow_status         ;;
            0)
                echo ""
                ok "Goodbye!"
                info "Full session log: ${LOG_FILE}"
                exit 0
                ;;
            *)
                warn "Invalid choice. Enter 0-7."
                ;;
        esac

        echo ""
        if ! ask_yn "Return to main menu?"; then
            ok "Goodbye!"
            info "Full session log: ${LOG_FILE}"
            exit 0
        fi
    done
}

main "$@"
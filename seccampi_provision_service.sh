#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi seccam - Service Provisioning Script
################################################################################
# Writes config.json, prepares the SFTP upload key, pins the Windows
# workstation's SSH host key, and installs the systemd user units:
#
#   seccam_server.service    Always-on HTTP (8081) + WebSocket (8080) server
#   seccam_capture.service   PIR + camera capture, via seccam_capture_wrapper.sh
#                            (always-on or sunrise-to-sunset, per config.json)
#   seccam_capture.timer     Restarts capture at 03:00 daily (daylight mode)
#   seccam_upload.service    Always-on SFTP uploader to the Windows workstation
#   seccam_cleanup.service   Retention + free-space cleanup (oneshot)
#   seccam_cleanup.timer     Runs cleanup hourly (on the hour)
#   seccam_health.service    Health checks + email alerts (oneshot)
#   seccam_health.timer      Runs health checks hourly (at :30)
#
# Units whose scripts are not in the repo yet are written but not started,
# so this script can be run early and simply re-run after pulling new code.
#
# Prerequisites:
#   - seccampi_provision.sh and seccampi_provision_python.sh already run
#   - Repo cloned to ~/seccam/
#
# Usage:
#   sudo ./seccampi_provision_service.sh              First run / re-run (safe)
#   sudo ./seccampi_provision_service.sh --pin-host   Only (re)pin the workstation host key
#   sudo ./seccampi_provision_service.sh --set-smtp-password
#                                                     Only (re)enter the SMTP password
#   sudo ./seccampi_provision_service.sh --reset      Back up and remove config.json and
#                                                     unit files, then re-provision
################################################################################

### Constants
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/seccam"
readonly LOG_FILE="${LOG_DIR}/seccampi_provision_service.log"
readonly DOC_URL="https://github.com/sqlpadawan/seccampi"
readonly ALL_UNITS=(seccam_server.service seccam_capture.service seccam_capture.timer
                    seccam_upload.service seccam_cleanup.service seccam_cleanup.timer
                    seccam_health.service seccam_health.timer)

### Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    mkdir -p "$LOG_DIR"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

### Parse arguments
RESET_MODE=false
PIN_ONLY=false
SMTP_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)    RESET_MODE=true; shift ;;
        --pin-host) PIN_ONLY=true;   shift ;;
        --set-smtp-password) SMTP_ONLY=true; shift ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Options:
  --pin-host   Only (re)pin the workstation SSH host key, then exit
  --set-smtp-password
               Only (re)enter the SMTP login for email alerts, then exit
  --reset      Back up and remove config.json and unit files, then re-provision
               (the upload SSH key and SMTP login are kept)
  -h, --help   Show this help message
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

### Determine actual user (not root when using sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    ACTUAL_USER="$SUDO_USER"
else
    ACTUAL_USER="$USER"
fi
if ! id "$ACTUAL_USER" &>/dev/null; then
    log "ERROR" "User '$ACTUAL_USER' does not exist"
    exit 1
fi
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
ACTUAL_UID=$(id -u "$ACTUAL_USER")

### Helper: run systemctl --user as the actual user from a sudo context
run_user_systemctl() {
    sudo -u "$ACTUAL_USER" \
        XDG_RUNTIME_DIR="/run/user/${ACTUAL_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${ACTUAL_UID}/bus" \
        systemctl --user "$@"
}

### Derived paths
REPO_DIR="${ACTUAL_HOME}/seccam"
VENV_PYTHON="${ACTUAL_HOME}/seccam_venv/bin/python3"
CONFIG_JSON="${REPO_DIR}/config.json"
IMAGE_DIR="${ACTUAL_HOME}/seccam_images"
SSH_DIR="${ACTUAL_HOME}/.ssh"
KEY_FILE="${SSH_DIR}/seccam_upload_ed25519"
KNOWN_HOSTS="${SSH_DIR}/seccam_known_hosts"
SYSTEMD_USER_DIR="${ACTUAL_HOME}/.config/systemd/user"

WRAPPER_SCRIPT="${REPO_DIR}/seccam_capture_wrapper.sh"
CAPTURE_SCRIPT="${REPO_DIR}/seccam_capture.py"
SERVER_SCRIPT="${REPO_DIR}/seccam_server.py"
UPLOAD_SCRIPT="${REPO_DIR}/seccam_upload.py"
CLEANUP_SCRIPT="${REPO_DIR}/seccam_cleanup.py"
HEALTH_SCRIPT="${REPO_DIR}/seccam_health.py"
SECRETS_DIR="${ACTUAL_HOME}/.config/seccam"
SMTP_SECRETS="${SECRETS_DIR}/smtp.json"

### Helper: read a value from config.json ("a.b.c" path), empty if missing
cfg_get() {
    python3 - "$CONFIG_JSON" "$1" <<'PYEOF' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(str(d).lower() if isinstance(d, bool) else d)
PYEOF
}

log "INFO" "Starting service provisioning (script v$SCRIPT_VERSION)"
log "INFO" "User: $ACTUAL_USER  |  Repo: $REPO_DIR"

################################################################################
### Host Key Pinning
################################################################################
# Fetches the workstation's ed25519 host key, shows its fingerprint for you to
# compare against the Windows machine, and stores it in a dedicated
# known_hosts file. The uploader uses strict host key checking against this
# file only, so it will refuse to send images to anything else.
pin_host_key() {
    local host port
    host=$(cfg_get upload.host)
    port=$(cfg_get upload.port)

    if [[ -z "$host" ]]; then
        log "WARN" "No upload host in config.json; skipping host key pinning"
        return 0
    fi

    log "INFO" "Fetching SSH host key from ${host}:${port}..."
    local tmp
    tmp=$(mktemp)
    if ! ssh-keyscan -T 5 -p "$port" -t ed25519 "$host" > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log "WARN" "Could not reach an SSH server at ${host}:${port}"
        log "WARN" "This is expected if the Windows side is not set up yet."
        log "WARN" "After running seccam_windows_setup.ps1, pin the key with:"
        log "WARN" "  sudo ./seccampi_provision_service.sh --pin-host"
        return 0
    fi

    echo ""
    echo "Workstation host key fingerprint:"
    ssh-keygen -lf "$tmp"
    echo ""
    echo "Verify this matches the workstation. On Windows (PowerShell), run:"
    echo "  ssh-keygen -lf C:\\ProgramData\\ssh\\ssh_host_ed25519_key.pub"
    echo ""
    read -r -p "Do the fingerprints match? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        rm -f "$tmp"
        log "WARN" "Host key NOT pinned (fingerprint not confirmed). Uploads will be refused until it is."
        return 0
    fi

    install -o "$ACTUAL_USER" -g "$ACTUAL_USER" -m 600 "$tmp" "$KNOWN_HOSTS"
    rm -f "$tmp"
    log "INFO" "Host key pinned in $KNOWN_HOSTS"
}

################################################################################
### SMTP Login
################################################################################
# Stores the SMTP username and password in ~/.config/seccam/smtp.json (mode
# 600, outside the repo), never in config.json. The password is read with
# hidden input and passed to Python on stdin, so it never appears in the
# process list or in the provisioning log.
set_smtp_secret() {
    local default_user smtp_user smtp_pass smtp_pass2
    default_user=$(cfg_get alerts.from_address)

    echo ""
    echo "SMTP login for email alerts."
    echo "For Gmail, use an app password (requires 2-Step Verification), not"
    echo "your normal account password."
    read -r -p "  SMTP username [${default_user}]: " smtp_user
    smtp_user="${smtp_user:-$default_user}"
    while true; do
        read -r -s -p "  SMTP password (hidden): " smtp_pass;  echo ""
        read -r -s -p "  Confirm password (hidden): " smtp_pass2; echo ""
        [[ -n "$smtp_pass" && "$smtp_pass" == "$smtp_pass2" ]] && break
        echo "  ERROR: Passwords were empty or did not match; try again"
    done

    install -d -o "$ACTUAL_USER" -g "$ACTUAL_USER" -m 700 "$SECRETS_DIR"
    local tmp
    tmp=$(mktemp)
    chmod 600 "$tmp"
    printf '%s' "$smtp_pass" | SMTP_USER="$smtp_user" python3 -c '
import json, os, sys
json.dump({"username": os.environ["SMTP_USER"], "password": sys.stdin.read()},
          open(sys.argv[1], "w"), indent=2)
' "$tmp"
    unset smtp_pass smtp_pass2
    install -o "$ACTUAL_USER" -g "$ACTUAL_USER" -m 600 "$tmp" "$SMTP_SECRETS"
    rm -f "$tmp"
    log "INFO" "SMTP login saved to $SMTP_SECRETS (mode 600)"
    if [[ -f "$HEALTH_SCRIPT" ]]; then
        log "INFO" "Send a test email with: ~/seccam_venv/bin/python3 ~/seccam/seccam_health.py --test-alert"
    fi
}

if [[ "$SMTP_ONLY" == true ]]; then
    if [[ "$(cfg_get alerts.enabled)" != "true" ]]; then
        log "ERROR" "Email alerts are not enabled in config.json"
        exit 1
    fi
    set_smtp_secret
    exit 0
fi

if [[ "$PIN_ONLY" == true ]]; then
    if [[ ! -f "$CONFIG_JSON" ]]; then
        log "ERROR" "config.json not found; run this script without --pin-host first"
        exit 1
    fi
    pin_host_key
    exit 0
fi

################################################################################
### Check Existing Provision State
################################################################################
check_existing_provision() {
    log "INFO" "========================================="
    log "INFO" "Checking existing provision state..."
    log "INFO" "========================================="

    if [[ -f "$CONFIG_JSON" ]]; then
        log "INFO" "  [OK]      config.json ($(cfg_get location.place), mode: $(cfg_get schedule.mode), PIR GPIO: $(cfg_get motion.gpio_pin), retention: $(cfg_get storage.retention_days)d)"
    else
        log "INFO" "  [MISSING] config.json: settings will be prompted"
    fi

    [[ -f "$KEY_FILE" ]]    && log "INFO" "  [OK]      Upload SSH key: $KEY_FILE" \
                            || log "INFO" "  [MISSING] Upload SSH key: will be generated"
    [[ -f "$KNOWN_HOSTS" ]] && log "INFO" "  [OK]      Workstation host key pinned" \
                            || log "INFO" "  [MISSING] Workstation host key: will attempt to pin"

    if [[ -f "$CONFIG_JSON" && "$(cfg_get alerts.enabled)" == "true" ]]; then
        [[ -f "$SMTP_SECRETS" ]] && log "INFO" "  [OK]      SMTP login: $SMTP_SECRETS" \
                                 || log "INFO" "  [MISSING] SMTP login: will prompt"
    fi

    for f in "$WRAPPER_SCRIPT" "$CAPTURE_SCRIPT" "$SERVER_SCRIPT" "$UPLOAD_SCRIPT" "$CLEANUP_SCRIPT" "$HEALTH_SCRIPT"; do
        [[ -f "$f" ]] && log "INFO" "  [OK]      $(basename "$f")" \
                      || log "INFO" "  [PENDING] $(basename "$f") not in repo yet: its unit will not be started"
    done

    for u in "${ALL_UNITS[@]}"; do
        [[ -f "${SYSTEMD_USER_DIR}/${u}" ]] && log "INFO" "  [OK]      $u" \
                                            || log "INFO" "  [MISSING] $u: will create"
    done

    log "INFO" "========================================="
}

check_existing_provision

################################################################################
### 1. Validate Prerequisites
################################################################################
log "INFO" "Validating prerequisites..."

if [[ ! -d "$REPO_DIR" ]]; then
    log "ERROR" "Repo directory not found: $REPO_DIR"
    exit 1
fi

if [[ ! -f "$VENV_PYTHON" ]]; then
    log "ERROR" "Python venv not found at $VENV_PYTHON; run seccampi_provision_python.sh first"
    exit 1
fi

for mod in astral pgeocode paramiko; do
    if ! sudo -u "$ACTUAL_USER" "$VENV_PYTHON" -c "import $mod" 2>/dev/null; then
        log "ERROR" "$mod not available in venv; run seccampi_provision_python.sh first"
        exit 1
    fi
done

log "INFO" "Prerequisites validated"

################################################################################
### 2. Handle Reset
################################################################################
if [[ "$RESET_MODE" == true ]]; then
    echo ""
    echo "Reset will:"
    echo "  - stop and disable all seccam units"
    echo "  - back up config.json to config.json.bak.<timestamp>, then remove it"
    echo "  - back up the pinned workstation host key, then remove it"
    echo "  - remove the seccam unit files (they are regenerated below)"
    echo "Images, upload state, the upload SSH key, and the SMTP login are NOT touched."
    read -r -p "Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Reset cancelled by user"
        exit 0
    fi

    for u in "${ALL_UNITS[@]}"; do
        run_user_systemctl stop "$u"    &>/dev/null || true
        run_user_systemctl disable "$u" &>/dev/null || true
    done
    log "INFO" "Stopped and disabled seccam units"

    STAMP=$(date +%Y%m%d_%H%M%S)
    for f in "$CONFIG_JSON" "$KNOWN_HOSTS"; do
        if [[ -f "$f" ]]; then
            cp -p "$f" "${f}.bak.${STAMP}"
            rm -f "$f"
            log "INFO" "Backed up and removed $f (backup: ${f}.bak.${STAMP})"
        fi
    done

    for u in "${ALL_UNITS[@]}"; do
        if [[ -f "${SYSTEMD_USER_DIR}/${u}" ]]; then
            rm -f "${SYSTEMD_USER_DIR}/${u}"
            log "INFO" "Removed unit file $u"
        fi
    done

    log "INFO" "Reset complete; continuing with fresh provisioning..."
fi

################################################################################
### 3. Write config.json
################################################################################
prompt_config() {
    ### Location
    while true; do
        echo ""
        read -r -p "Enter US zip code for sunrise/sunset calculation: " ZIP_CODE
        if ! [[ "$ZIP_CODE" =~ ^[0-9]{5}$ ]]; then
            echo "ERROR: Zip code must be exactly 5 digits"
            continue
        fi

        log "INFO" "Resolving zip code $ZIP_CODE..."
        LOCATION_RESULT=$(sudo -u "$ACTUAL_USER" "$VENV_PYTHON" - "$ZIP_CODE" <<'PYEOF' 2>/dev/null || true
import math, sys, pgeocode
r = pgeocode.Nominatim("us").query_postal_code(sys.argv[1])
if r is None or math.isnan(r["latitude"]):
    sys.exit(1)
print(f"{r['place_name']}\t{r['state_name']}\t{r['latitude']:.6f}\t{r['longitude']:.6f}")
PYEOF
        )

        if [[ -z "$LOCATION_RESULT" ]]; then
            echo "ERROR: Could not resolve zip code $ZIP_CODE; please try again"
            continue
        fi

        IFS=$'\t' read -r PLACE_NAME STATE_NAME LATITUDE LONGITUDE <<< "$LOCATION_RESULT"
        echo ""
        echo "  Location:  ${PLACE_NAME}, ${STATE_NAME}"
        echo "  Latitude:  ${LATITUDE}"
        echo "  Longitude: ${LONGITUDE}"
        read -r -p "Is this correct? (y/n): " confirm
        [[ "$confirm" == "y" || "$confirm" == "yes" ]] && break
    done

    ### Schedule mode
    while true; do
        echo ""
        echo "Capture schedule:"
        echo "  1) always    Capture on motion 24/7"
        echo "  2) daylight  Capture on motion only between sunrise and sunset"
        read -r -p "Choose 1 or 2 [2]: " choice
        case "${choice:-2}" in
            1) SCHEDULE_MODE="always";   break ;;
            2) SCHEDULE_MODE="daylight"; break ;;
            *) echo "ERROR: Enter 1 or 2" ;;
        esac
    done

    ### PIR GPIO pin
    while true; do
        echo ""
        read -r -p "PIR sensor GPIO pin (BCM numbering) [17]: " GPIO_PIN
        GPIO_PIN="${GPIO_PIN:-17}"
        if [[ "$GPIO_PIN" =~ ^[0-9]+$ ]] && (( GPIO_PIN >= 2 && GPIO_PIN <= 27 )); then
            break
        fi
        echo "ERROR: Enter a BCM GPIO number between 2 and 27"
    done

    ### Local image retention
    echo ""
    echo "Local image retention (images are removed from the Pi, not the workstation):"
    while true; do
        read -r -p "  Days of images to keep on the Pi [3]: " RETENTION_DAYS
        RETENTION_DAYS="${RETENTION_DAYS:-3}"
        [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 && RETENTION_DAYS <= 30 )) && break
        echo "  ERROR: Enter a whole number of days between 1 and 30"
    done
    while true; do
        read -r -p "  Minimum free disk space to maintain, in GB [2]: " MIN_FREE_GB
        MIN_FREE_GB="${MIN_FREE_GB:-2}"
        [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] && (( MIN_FREE_GB >= 1 && MIN_FREE_GB <= 8 )) && break
        echo "  ERROR: Enter a whole number of GB between 1 and 8"
    done

    ### Upload target
    echo ""
    read -r -p "Enable SFTP upload to a Windows workstation? (y/n) [y]: " up
    if [[ "${up:-y}" == "y" || "${up:-y}" == "yes" ]]; then
        UPLOAD_ENABLED="true"
        while true; do
            read -r -p "  Workstation hostname or IP: " UPLOAD_HOST
            [[ "$UPLOAD_HOST" =~ ^[A-Za-z0-9.-]+$ ]] && break
            echo "  ERROR: Hostname may contain only letters, numbers, dots, and hyphens"
        done
        while true; do
            read -r -p "  SSH port [22]: " UPLOAD_PORT
            UPLOAD_PORT="${UPLOAD_PORT:-22}"
            [[ "$UPLOAD_PORT" =~ ^[0-9]+$ ]] && (( UPLOAD_PORT >= 1 && UPLOAD_PORT <= 65535 )) && break
            echo "  ERROR: Enter a port between 1 and 65535"
        done
        while true; do
            read -r -p "  Windows account for uploads [seccam]: " UPLOAD_USER
            UPLOAD_USER="${UPLOAD_USER:-seccam}"
            [[ "$UPLOAD_USER" =~ ^[A-Za-z0-9._-]+$ ]] && break
            echo "  ERROR: Invalid account name"
        done
    else
        UPLOAD_ENABLED="false"
        UPLOAD_HOST=""
        UPLOAD_PORT="22"
        UPLOAD_USER="seccam"
    fi

    ### Email alerts
    echo ""
    read -r -p "Enable email alerts (upload backlog, lost footage, capture down)? (y/n) [y]: " al
    if [[ "${al:-y}" == "y" || "${al:-y}" == "yes" ]]; then
        ALERTS_ENABLED="true"
        local email_re='^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]+$'
        while true; do
            read -r -p "  Send alerts TO (comma-separated for several): " ALERT_TO
            ALERT_TO="${ALERT_TO// /}"
            local ok=true addr
            IFS=',' read -r -a _addrs <<< "$ALERT_TO"
            [[ ${#_addrs[@]} -eq 0 ]] && ok=false
            for addr in "${_addrs[@]}"; do
                [[ "$addr" =~ $email_re ]] || ok=false
            done
            [[ "$ok" == true ]] && break
            echo "  ERROR: Enter one or more valid email addresses"
        done
        while true; do
            read -r -p "  Send alerts FROM (the account that sends them): " ALERT_FROM
            [[ "$ALERT_FROM" =~ $email_re ]] && break
            echo "  ERROR: Enter a valid email address"
        done
        while true; do
            read -r -p "  SMTP server [smtp.gmail.com]: " SMTP_HOST
            SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
            [[ "$SMTP_HOST" =~ ^[A-Za-z0-9.-]+$ ]] && break
            echo "  ERROR: Invalid server name"
        done
        while true; do
            read -r -p "  SMTP port (587 = STARTTLS, 465 = SSL) [587]: " SMTP_PORT
            SMTP_PORT="${SMTP_PORT:-587}"
            [[ "$SMTP_PORT" == "587" || "$SMTP_PORT" == "465" ]] && break
            echo "  ERROR: Enter 587 or 465 (unencrypted SMTP is not supported)"
        done
        while true; do
            read -r -p "  Alert when un-uploaded images are older than (hours) [24]: " BACKLOG_HOURS
            BACKLOG_HOURS="${BACKLOG_HOURS:-24}"
            [[ "$BACKLOG_HOURS" =~ ^[0-9]+$ ]] && (( BACKLOG_HOURS >= 1 && BACKLOG_HOURS <= 168 )) && break
            echo "  ERROR: Enter a whole number of hours between 1 and 168"
        done
    else
        ALERTS_ENABLED="false"
        ALERT_TO=""
        ALERT_FROM=""
        SMTP_HOST="smtp.gmail.com"
        SMTP_PORT="587"
        BACKLOG_HOURS="24"
    fi
}

write_config() {
    local tmp
    tmp=$(mktemp)
    ZIP_CODE="$ZIP_CODE" PLACE="${PLACE_NAME}, ${STATE_NAME}" LAT="$LATITUDE" LON="$LONGITUDE" \
    MODE="$SCHEDULE_MODE" GPIO="$GPIO_PIN" IMG="$IMAGE_DIR" \
    RET_DAYS="$RETENTION_DAYS" MIN_FREE="$MIN_FREE_GB" \
    AL_EN="$ALERTS_ENABLED" AL_TO="$ALERT_TO" AL_FROM="$ALERT_FROM" \
    SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" BACKLOG_H="$BACKLOG_HOURS" \
    UP_EN="$UPLOAD_ENABLED" UP_HOST="$UPLOAD_HOST" UP_PORT="$UPLOAD_PORT" UP_USER="$UPLOAD_USER" \
    KEY="$KEY_FILE" KH="$KNOWN_HOSTS" \
    python3 - "$tmp" <<'PYEOF'
import json, os, sys
e = os.environ
cfg = {
    "location": {
        "zip": e["ZIP_CODE"],
        "place": e["PLACE"],
        "latitude": float(e["LAT"]),
        "longitude": float(e["LON"]),
    },
    "schedule": {"mode": e["MODE"]},
    "motion": {"gpio_pin": int(e["GPIO"])},
    "camera": {
        "resolution": [1920, 1080],
        "jpeg_quality": 85,
        "capture_interval_s": 1.0,
        "preview_resolution": [640, 480],
        "preview_fps": 1,
    },
    "storage": {
        "image_dir": e["IMG"],
        "retention_days": int(e["RET_DAYS"]),
        "min_free_gb": int(e["MIN_FREE"]),
    },
    "upload": {
        "enabled": e["UP_EN"] == "true",
        "host": e["UP_HOST"],
        "port": int(e["UP_PORT"]),
        "username": e["UP_USER"],
        "remote_root": "/",
        "key_file": e["KEY"],
        "known_hosts_file": e["KH"],
        "scan_interval_s": 30,
    },
    "alerts": {
        "enabled": e["AL_EN"] == "true",
        "recipients": [a for a in e["AL_TO"].split(",") if a],
        "from_address": e["AL_FROM"],
        "smtp_host": e["SMTP_HOST"],
        "smtp_port": int(e["SMTP_PORT"]),
        "upload_backlog_hours": int(e["BACKLOG_H"]),
        "capture_stale_minutes": 15,
        "reminder_hours": 24,
    },
    "logging": {"max_log_files": 30},
}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
    install -o "$ACTUAL_USER" -g "$ACTUAL_USER" -m 644 "$tmp" "$CONFIG_JSON"
    rm -f "$tmp"
    log "INFO" "config.json written to $CONFIG_JSON"
}

log "INFO" "Configuring settings..."
if [[ -f "$CONFIG_JSON" ]]; then
    log "INFO" "config.json already exists; keeping it (edit it directly, or use --reset to re-prompt)"
else
    prompt_config
    write_config
fi

UPLOAD_ENABLED=$(cfg_get upload.enabled)
ALERTS_ENABLED=$(cfg_get alerts.enabled)

################################################################################
### 4. Upload SSH Key
################################################################################
log "INFO" "Checking upload SSH key..."

if [[ ! -d "$SSH_DIR" ]]; then
    install -d -o "$ACTUAL_USER" -g "$ACTUAL_USER" -m 700 "$SSH_DIR"
    log "INFO" "Created $SSH_DIR"
fi

if [[ -f "$KEY_FILE" ]]; then
    log "INFO" "Upload key already exists: $KEY_FILE"
else
    # No passphrase: the uploader runs unattended. The key's reach is limited on
    # the Windows side (non-admin account, SFTP only, chrooted to one folder).
    sudo -u "$ACTUAL_USER" ssh-keygen -q -t ed25519 -N "" \
        -C "seccam-upload@$(hostname)" -f "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    log "INFO" "Generated upload key: $KEY_FILE"
fi

################################################################################
### 5. Pin Workstation Host Key
################################################################################
if [[ "$UPLOAD_ENABLED" == "true" ]]; then
    if [[ -f "$KNOWN_HOSTS" ]]; then
        log "INFO" "Workstation host key already pinned (use --pin-host to re-pin)"
    else
        pin_host_key
    fi
else
    log "INFO" "Upload disabled in config.json; skipping host key pinning"
fi

################################################################################
### 5b. SMTP Login for Email Alerts
################################################################################
if [[ "$ALERTS_ENABLED" == "true" ]]; then
    if [[ -f "$SMTP_SECRETS" ]]; then
        log "INFO" "SMTP login already stored (use --set-smtp-password to change it)"
    else
        set_smtp_secret
    fi
else
    log "INFO" "Email alerts disabled in config.json; skipping SMTP login"
fi

################################################################################
### 6. Script Permissions and systemd User Directory
################################################################################
[[ -f "$WRAPPER_SCRIPT" ]] && chmod +x "$WRAPPER_SCRIPT" && log "INFO" "Wrapper script is executable"

if [[ ! -d "$SYSTEMD_USER_DIR" ]]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$SYSTEMD_USER_DIR"
    log "INFO" "Created $SYSTEMD_USER_DIR"
fi

################################################################################
### 7. Stop Running Services Before Rewriting Unit Files
################################################################################
for u in seccam_server.service seccam_capture.service seccam_upload.service; do
    if run_user_systemctl is-active "$u" &>/dev/null; then
        run_user_systemctl stop "$u" 2>&1 | tee -a "$LOG_FILE" || true
        log "INFO" "Stopped $u"
    fi
done

################################################################################
### 8. Write Unit Files
################################################################################
write_unit() {
    local name="$1"
    local path="${SYSTEMD_USER_DIR}/${name}"
    cat > "$path"
    chown "${ACTUAL_USER}:${ACTUAL_USER}" "$path"
    chmod 644 "$path"
    log "INFO" "Wrote $name"
}

write_unit seccam_server.service << EOF
[Unit]
Description=seccam HTTP and WebSocket Server
Documentation=${DOC_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_PYTHON} ${SERVER_SCRIPT}
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

# Wants (not Requires) on the server: if the web server crashes, the camera
# must keep recording. imx500 used Requires, which would stop capture too.
write_unit seccam_capture.service << EOF
[Unit]
Description=seccam PIR-Triggered Camera Capture
Documentation=${DOC_URL}
After=network-online.target seccam_server.service
Wants=network-online.target seccam_server.service

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${WRAPPER_SCRIPT}
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

write_unit seccam_capture.timer << EOF
[Unit]
Description=seccam Capture Daily Restart Timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=seccam_capture.service

[Install]
WantedBy=timers.target
EOF

write_unit seccam_upload.service << EOF
[Unit]
Description=seccam SFTP Uploader
Documentation=${DOC_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_PYTHON} ${UPLOAD_SCRIPT}
Restart=always
RestartSec=30s
Nice=10
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

write_unit seccam_cleanup.service << EOF
[Unit]
Description=seccam Image Retention and Free-Space Cleanup
Documentation=${DOC_URL}

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_PYTHON} ${CLEANUP_SCRIPT}
Nice=15
IOSchedulingClass=idle
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1
EOF

write_unit seccam_cleanup.timer << EOF
[Unit]
Description=seccam Cleanup Hourly Timer

[Timer]
OnCalendar=hourly
Persistent=true
Unit=seccam_cleanup.service

[Install]
WantedBy=timers.target
EOF

write_unit seccam_health.service << EOF
[Unit]
Description=seccam Health Checks and Email Alerts
Documentation=${DOC_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_PYTHON} ${HEALTH_SCRIPT}
Nice=10
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1
EOF

# :30 so any footage-loss records written by the :00 cleanup run are
# reported within half an hour.
write_unit seccam_health.timer << EOF
[Unit]
Description=seccam Health Check Hourly Timer

[Timer]
OnCalendar=*-*-* *:30:00
Persistent=true
Unit=seccam_health.service

[Install]
WantedBy=timers.target
EOF

################################################################################
### 9. Enable and Start Units Whose Scripts Exist
################################################################################
log "INFO" "Reloading systemd user daemon..."
run_user_systemctl daemon-reload

enable_start() {
    run_user_systemctl enable "$@" 2>&1 | tee -a "$LOG_FILE"
    run_user_systemctl start  "$@" 2>&1 | tee -a "$LOG_FILE"
    log "INFO" "Enabled and started: $*"
}

skip_unit() {
    run_user_systemctl disable "$1" &>/dev/null || true
    log "INFO" "SKIPPED $1: $2"
}

if [[ -f "$SERVER_SCRIPT" ]]; then
    enable_start seccam_server.service
else
    skip_unit seccam_server.service "seccam_server.py not in repo yet"
fi

if [[ -f "$WRAPPER_SCRIPT" && -f "$CAPTURE_SCRIPT" ]]; then
    enable_start seccam_capture.timer seccam_capture.service
else
    skip_unit seccam_capture.service "capture script or wrapper not in repo yet"
    skip_unit seccam_capture.timer   "capture script or wrapper not in repo yet"
fi

if [[ "$UPLOAD_ENABLED" != "true" ]]; then
    skip_unit seccam_upload.service "upload disabled in config.json"
elif [[ ! -f "$UPLOAD_SCRIPT" ]]; then
    skip_unit seccam_upload.service "seccam_upload.py not in repo yet"
else
    enable_start seccam_upload.service
fi

if [[ -f "$CLEANUP_SCRIPT" ]]; then
    enable_start seccam_cleanup.timer
else
    skip_unit seccam_cleanup.timer "seccam_cleanup.py not in repo yet"
fi

if [[ "$ALERTS_ENABLED" != "true" ]]; then
    skip_unit seccam_health.timer "email alerts disabled in config.json"
elif [[ ! -f "$HEALTH_SCRIPT" ]]; then
    skip_unit seccam_health.timer "seccam_health.py not in repo yet"
else
    enable_start seccam_health.timer
fi

################################################################################
### 10. Add Service Alias to ~/.bashrc
################################################################################
BASHRC="${ACTUAL_HOME}/.bashrc"
ALIAS_LINE="alias seccam='XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user'"

if grep -qF "alias seccam=" "$BASHRC" 2>/dev/null; then
    log "INFO" "seccam alias already present in $BASHRC"
else
    {
        echo ""
        echo "# seccam service alias"
        echo "$ALIAS_LINE"
    } >> "$BASHRC"
    chown "${ACTUAL_USER}:${ACTUAL_USER}" "$BASHRC"
    log "INFO" "Added seccam alias to $BASHRC"
fi

################################################################################
### 11. Verify
################################################################################
sleep 3
log "INFO" "Unit status:"
for u in "${ALL_UNITS[@]}"; do
    state=$(run_user_systemctl is-active "$u" 2>/dev/null || true)
    enabled=$(run_user_systemctl is-enabled "$u" 2>/dev/null || true)
    log "INFO" "  $(printf '%-24s' "$u") active: ${state:-unknown}  enabled: ${enabled:-unknown}"
done

################################################################################
### 12. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "SERVICE PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "Config: $CONFIG_JSON"
log "INFO" "  Location: $(cfg_get location.place)"
log "INFO" "  Schedule: $(cfg_get schedule.mode)"
log "INFO" "  PIR GPIO: $(cfg_get motion.gpio_pin)"
log "INFO" "  Retention: $(cfg_get storage.retention_days) days, keep $(cfg_get storage.min_free_gb) GB free"
log "INFO" "  Upload:   $(cfg_get upload.enabled) -> $(cfg_get upload.username)@$(cfg_get upload.host):$(cfg_get upload.port)"
log "INFO" "  Alerts:   $(cfg_get alerts.enabled) -> $(cfg_get alerts.recipients) via $(cfg_get alerts.smtp_host):$(cfg_get alerts.smtp_port)"
log "INFO" "========================================="
if [[ "$UPLOAD_ENABLED" == "true" ]]; then
    log "INFO" "Upload public key (seccam_windows_setup.ps1 will ask for this):"
    cat "${KEY_FILE}.pub" | tee -a "$LOG_FILE"
    [[ -f "$KNOWN_HOSTS" ]] || log "WARN" "Host key not pinned yet. After Windows setup: sudo ./seccampi_provision_service.sh --pin-host"
    log "INFO" "========================================="
fi
log "INFO" "Service alias added to ~/.bashrc. As your regular user, run: source ~/.bashrc"
log "INFO" "Useful commands:"
log "INFO" "  seccam status seccam_server.service"
log "INFO" "  seccam status seccam_capture.service"
log "INFO" "  seccam list-timers"
log "INFO" "  journalctl --user -u seccam_capture.service -f"
log "INFO" "  tail -f /var/log/seccam/events.jsonl"
log "INFO" "  ~/seccam_venv/bin/python3 ~/seccam/seccam_health.py --dry-run"
log "INFO" "Re-run this script after pulling new code to start any SKIPPED units."
log "INFO" "========================================="

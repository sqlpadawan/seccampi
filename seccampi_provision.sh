#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi seccam (Motion-Activated Security Camera) Provisioning Script
################################################################################
# Provisions a Raspberry Pi Zero 2 W for headless operation as a PIR-triggered
# security camera. Enables camera auto-detection, sets GPU/CMA memory for the
# libcamera stack, grants camera and GPIO access, and prepares the log, image,
# and data directories.
#
# Prerequisites:
# - Raspberry Pi OS Lite 64-bit (Debian Trixie, arm64), same as the imx500
#   project. The 32-bit image should also work but is not the target.
# - Internet connection established
# - User account already created
# - Raspberry Pi camera connected via CSI ribbon cable (Zero-style narrow cable)
# - PIR motion sensor wired to a GPIO pin (pin number is set later in
#   seccampi_provision_service.sh)
#
# Usage:
#   chmod +x seccampi_provision.sh
#   sudo ./seccampi_provision.sh <username>
#
# Arguments:
#   username - The non-root user account for SSH and systemd services
#
# Notes:
#   This script handles base OS provisioning only. Python packages, camera
#   detection, and services are handled by separate scripts. Safe to re-run.
################################################################################

### Constants
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/seccam"
readonly LOG_FILE="${LOG_DIR}/seccampi_provision.log"
readonly MIN_DISK_SPACE_MB=2048
readonly CONFIG_FILE="/boot/firmware/config.txt"

# Ensure log directory exists before the first log() call. Section 6 sets
# final ownership once the target username is validated.
mkdir -p "$LOG_DIR"

### Standardized logging function
log() {
    local level="$1"
    shift
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

### Check available disk space
check_disk_space() {
    log "INFO" "Checking available disk space..."

    local available_mb
    available_mb=$(df -BM / | awk 'NR==2 {print $4}' | sed 's/M//')

    log "INFO" "Available disk space: ${available_mb}MB"

    if [[ $available_mb -lt $MIN_DISK_SPACE_MB ]]; then
        log "ERROR" "Insufficient disk space: ${available_mb}MB available, ${MIN_DISK_SPACE_MB}MB required"
        return 1
    fi

    log "INFO" "Disk space check passed"
}

### Parse and validate arguments
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <username>"
    echo ""
    echo "Arguments:"
    echo "  username - Existing non-root user for SSH and services"
    exit 1
fi

USERNAME="$1"

if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log "ERROR" "Invalid username format: $USERNAME"
    log "ERROR" "Username must start with a lowercase letter or underscore and contain only lowercase letters, numbers, underscores, or hyphens"
    exit 1
fi

if ! id "$USERNAME" &>/dev/null; then
    log "ERROR" "User '$USERNAME' does not exist. Please create the user first."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log "ERROR" "This script must be run as root (use sudo)"
    exit 1
fi

USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)

log "INFO" "Starting provisioning for user '$USERNAME' (script v$SCRIPT_VERSION)"

if ! check_disk_space; then
    exit 1
fi

################################################################################
### 0. Hardware and OS Sanity Checks (informational)
################################################################################
log "INFO" "Checking hardware and OS..."

PI_MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
fi
ARCH=$(uname -m)
DPKG_ARCH=$(dpkg --print-architecture)

log "INFO" "Model: $PI_MODEL"
log "INFO" "Kernel arch: $ARCH  |  Userland arch: $DPKG_ARCH"

if [[ "$PI_MODEL" != *"Zero 2 W"* ]]; then
    log "WARN" "This script is tuned for a Pi Zero 2 W. Detected '$PI_MODEL'. Continuing anyway."
fi

if [[ "$DPKG_ARCH" != "arm64" ]]; then
    log "WARN" "Expected 64-bit arm64 userland (Raspberry Pi OS Lite 64-bit), found '$DPKG_ARCH'"
fi

# Image folders are named by LOCAL time (YYYYMMDD/HH). A Pi left on UTC will
# file images under the wrong hour. Warn only; do not change it automatically.
CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
log "INFO" "Timezone: $CURRENT_TZ"
if [[ "$CURRENT_TZ" == "Etc/UTC" || "$CURRENT_TZ" == "UTC" ]]; then
    log "WARN" "Timezone is UTC. Image folders use local time, so set your timezone, e.g.:"
    log "WARN" "  sudo timedatectl set-timezone America/Detroit"
fi

################################################################################
### 1. Camera and GPIO Access
################################################################################
log "INFO" "Granting camera and GPIO access to '$USERNAME'..."

for grp in video gpio; do
    if ! getent group "$grp" &>/dev/null; then
        log "WARN" "Group '$grp' does not exist on this system; skipping"
        continue
    fi
    if id -nG "$USERNAME" | grep -qw "$grp"; then
        log "INFO" "User '$USERNAME' already in $grp group"
    else
        if usermod -aG "$grp" "$USERNAME"; then
            log "INFO" "Added '$USERNAME' to $grp group"
        else
            log "ERROR" "Failed to add '$USERNAME' to $grp group"
            exit 1
        fi
    fi
done

################################################################################
### 2. Enable User Lingering
################################################################################
log "INFO" "Enabling user lingering for $USERNAME..."
if loginctl enable-linger "$USERNAME"; then
    log "INFO" "Lingering enabled: user systemd instance will run at boot without login"
else
    log "ERROR" "Failed to enable lingering for $USERNAME"
    exit 1
fi

################################################################################
### 3. Optimize /boot/firmware/config.txt
################################################################################
log "INFO" "Updating $CONFIG_FILE..."

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR" "Config file not found: $CONFIG_FILE"
    exit 1
fi

BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
if cp "$CONFIG_FILE" "$BACKUP_FILE"; then
    chmod 644 "$BACKUP_FILE"
    log "INFO" "Created backup at $BACKUP_FILE"
else
    log "ERROR" "Failed to create backup of config file"
    exit 1
fi

# Appended lines land in whatever [section] ends the file. Make sure that is
# [all] so our settings are not accidentally scoped to [cm4], [cm5], etc.
ensure_all_section() {
    local last_section
    last_section=$(grep -E '^\[.*\]' "$CONFIG_FILE" | tail -n 1 || true)
    if [[ -n "$last_section" && "$last_section" != "[all]" ]]; then
        printf '\n[all]\n' >> "$CONFIG_FILE"
        log "INFO" "Appended [all] section header (file previously ended in $last_section)"
    fi
}

# Only safe for keys that should appear exactly once (e.g. gpu_mem).
# Do NOT use for dtoverlay; use add_or_update_dtoverlay() instead.
add_or_update_config() {
    local key="$1"
    local value="$2"
    local entry="${key}=${value}"

    if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log "WARN" "Invalid config key format: $key"
        return 1
    fi

    if grep -qx "$entry" "$CONFIG_FILE" && [[ $(grep -c "^${key}=" "$CONFIG_FILE") -eq 1 ]]; then
        log "INFO" "Already set: $entry"
        return 0
    fi

    local match_count
    match_count=$(grep -c "^${key}=" "$CONFIG_FILE" || true)

    if [[ "$match_count" -gt 0 ]]; then
        sed -i "/^${key}=/d" "$CONFIG_FILE"
        ensure_all_section
        echo "$entry" >> "$CONFIG_FILE"
        log "INFO" "Replaced ${match_count} existing '${key}=' entry(ies) with: $entry"
    else
        ensure_all_section
        echo "$entry" >> "$CONFIG_FILE"
        log "INFO" "Added: $entry"
    fi
}

# Matches by overlay NAME so multiple distinct overlays can coexist.
add_or_update_dtoverlay() {
    local overlay_name="$1"
    local overlay_params="${2:-}"
    local entry

    if ! [[ "$overlay_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "WARN" "Invalid overlay name format: $overlay_name"
        return 1
    fi

    if [[ -n "$overlay_params" ]]; then
        entry="dtoverlay=${overlay_name},${overlay_params}"
    else
        entry="dtoverlay=${overlay_name}"
    fi

    local match_count
    match_count=$(grep -cE "^dtoverlay=${overlay_name}(,.*)?\$" "$CONFIG_FILE" || true)

    if [[ "$match_count" -eq 1 ]] && grep -qx "$entry" "$CONFIG_FILE"; then
        log "INFO" "Already set: $entry"
        return 0
    fi

    if [[ "$match_count" -gt 0 ]]; then
        sed -i -E "/^dtoverlay=${overlay_name}(,.*)?\$/d" "$CONFIG_FILE"
        ensure_all_section
        echo "$entry" >> "$CONFIG_FILE"
        log "INFO" "Replaced ${match_count} existing 'dtoverlay=${overlay_name}...' entry(ies) with: $entry"
    else
        ensure_all_section
        echo "$entry" >> "$CONFIG_FILE"
        log "INFO" "Added: $entry"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Camera auto-detection (required)
#
# Unlike the IMX500, all official Raspberry Pi camera modules (v1, v2,
# Camera Module 3, HQ, Global Shutter) are detected reliably with
# camera_auto_detect=1, so no sensor-specific dtoverlay is needed. This
# also means the camera model can change without re-provisioning.
# ─────────────────────────────────────────────────────────────────
add_or_update_config "camera_auto_detect" "1"

# ─────────────────────────────────────────────────────────────────
# GPU memory and CMA pool
#
# Mirrors the known-good values from the imx500 project (gpu_mem=128,
# vc4-kms-v3d with a 128MiB CMA pool), proven on the same Pi Zero 2 W board. Camera
# buffers come from CMA; 128MiB comfortably covers a 1080p main stream plus
# a 640x480 preview stream. If picamera2 reports "Cannot allocate memory"
# at higher resolutions, raise cma-128 to cma-160 and reboot.
#
# CMA must be sized via the dtoverlay parameter, not cmdline.txt, so the
# heap keeps the "linux,cma" name picamera2 expects (see imx500 notes).
# ─────────────────────────────────────────────────────────────────
add_or_update_config "gpu_mem" "128"
add_or_update_dtoverlay "vc4-kms-v3d" "cma-128"

log "INFO" "Boot configuration updated"

################################################################################
### 4. Disable WiFi Power Management
################################################################################
log "INFO" "Disabling WiFi power management..."

# Power save causes SSH lag and slow uploads on the Zero 2 W's 2.4 GHz radio.
WIFI_PM_DIR="/etc/NetworkManager/conf.d"
WIFI_PM_CONF="${WIFI_PM_DIR}/wifi-power-management.conf"
mkdir -p "$WIFI_PM_DIR"

cat > "$WIFI_PM_CONF" << EOF
[connection]
wifi.powersave = 2
EOF

chmod 644 "$WIFI_PM_CONF"
log "INFO" "WiFi power management disabled: $WIFI_PM_CONF (takes effect after reboot)"

################################################################################
### 5. Configure Persistent Journal Logging
################################################################################
log "INFO" "Configuring persistent systemd journal logging..."

JOURNALD_CONF="/etc/systemd/journald.conf"
JOURNALD_CHANGED=false

if grep -q "^Storage=persistent" "$JOURNALD_CONF"; then
    log "INFO" "Journal persistence already configured"
else
    sed -i 's/^#Storage=.*/Storage=persistent/' "$JOURNALD_CONF"
    if ! grep -q "^Storage=persistent" "$JOURNALD_CONF"; then
        echo "Storage=persistent" >> "$JOURNALD_CONF"
    fi
    JOURNALD_CHANGED=true
    log "INFO" "Journal persistence enabled"
fi

# Cap the journal so it can't compete with images for SD card space.
if grep -q "^SystemMaxUse=50M" "$JOURNALD_CONF"; then
    log "INFO" "Journal size cap already configured"
else
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' "$JOURNALD_CONF"
    if ! grep -q "^SystemMaxUse=50M" "$JOURNALD_CONF"; then
        echo "SystemMaxUse=50M" >> "$JOURNALD_CONF"
    fi
    JOURNALD_CHANGED=true
    log "INFO" "Journal size cap set to 50M"
fi

if [[ "$JOURNALD_CHANGED" == true ]]; then
    systemctl restart systemd-journald
    log "INFO" "systemd-journald restarted"
fi

################################################################################
### 6. Create seccam Directories
################################################################################
log "INFO" "Creating seccam directories..."

IMAGE_DIR="${USER_HOME}/seccam_images"
DATA_DIR="${USER_HOME}/seccam_data"

# /var/log/seccam: provisioning logs, events.jsonl, wrapper/upload/cleanup logs
chown "${USERNAME}:${USERNAME}" "$LOG_DIR"
chmod 755 "$LOG_DIR"
log "INFO" "Log directory ready: $LOG_DIR (owner $USERNAME)"

# Images and upload state are private to the service user.
for dir in "$IMAGE_DIR" "$DATA_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log "INFO" "Created $dir"
    else
        log "INFO" "$dir already exists"
    fi
    chown "${USERNAME}:${USERNAME}" "$dir"
    chmod 750 "$dir"
done

################################################################################
### 7. Configure Log Rotation
################################################################################
log "INFO" "Configuring log rotation..."

# Rotates the *.log files. events.jsonl is rotated by the capture script
# itself (same approach as imx500), so it is intentionally not listed here.
LOGROTATE_CONF="/etc/logrotate.d/seccam"

cat > "$LOGROTATE_CONF" << EOF
/var/log/seccam/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 ${USERNAME} ${USERNAME}
}
EOF

chmod 644 "$LOGROTATE_CONF"
log "INFO" "Log rotation configured: $LOGROTATE_CONF"

################################################################################
### 8. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "Model: $PI_MODEL ($DPKG_ARCH)"
log "INFO" "User: $USERNAME (groups: video, gpio)"
log "INFO" "Boot Config: camera_auto_detect=1, gpu_mem=128, dtoverlay=vc4-kms-v3d,cma-128"
log "INFO" "WiFi Power Mgmt: Disabled"
log "INFO" "Journal: persistent, capped at 50M"
log "INFO" "Directories: $LOG_DIR, $IMAGE_DIR, $DATA_DIR"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "Config backup: $BACKUP_FILE"
log "INFO" "========================================="
log "INFO" "Next steps:"
log "INFO" "  1. Reboot to apply boot config and group changes: sudo reboot"
log "INFO" "  2. Run Python provisioning (also detects the camera): sudo ./seccampi_provision_python.sh"
log "INFO" "  3. Run service provisioning: sudo ./seccampi_provision_service.sh"
log "INFO" "========================================="

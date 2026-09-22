#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi seccam - Python Environment Provisioning Script
################################################################################
# Creates the seccam Python virtual environment and detects the attached
# Raspberry Pi camera module.
#
# Packaging strategy (Pi Zero 2 W, 512MB RAM, 16GB card):
#   Anything with compiled code (picamera2, numpy, pandas, Pillow, paramiko,
#   lgpio, websockets) is installed via apt. picamera2 must come from apt
#   anyway, and apt builds are prebuilt for the Pi, tested together, smaller
#   on disk than pip wheels, and update with the OS. The venv uses
#   --system-site-packages to see them.
#   pip installs only the pure-Python packages (astral, pgeocode) with
#   --only-binary=:all: so pip can never start compiling a dependency from
#   source, which is slow and memory-hungry on a 512MB board.
#
# Prerequisites:
# - seccampi_provision.sh already run, and the Pi rebooted since
# - Root privileges (for apt package installation)
#
# Usage:
#   chmod +x seccampi_provision_python.sh
#   sudo ./seccampi_provision_python.sh
#   sudo ./seccampi_provision_python.sh --venv-dir /custom/path
#   sudo ./seccampi_provision_python.sh --requirement extra-package
#   sudo ./seccampi_provision_python.sh --detect-camera
#   sudo ./seccampi_provision_python.sh --reset
#
# Arguments:
#   --venv-dir <path>      Custom virtual environment directory
#   --requirement <pkg>    Add an additional pure-Python pip package
#   --detect-camera        Only run camera detection, then exit
#   --reset                Remove the virtual environment (asks to confirm)
################################################################################

### Constants
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/seccam"
readonly LOG_FILE="${LOG_DIR}/provision_python_venv.log"
readonly MIN_DISK_SPACE_MB=1024

### Default Configuration
readonly DEFAULT_VENV_DIR_NAME="seccam_venv"

# apt packages: everything with compiled code comes from here (see header).
readonly DEFAULT_APT_PACKAGES=(
    "python3-pip"
    "python3-venv"
    "python3-libcamera"        # libcamera Python bindings
    "python3-picamera2"        # Picamera2 (installed with --no-install-recommends, no GUI deps)
    "rpicam-apps-lite"         # rpicam-hello for camera detection (no preview window deps)
    "python3-pil"              # Pillow: JPEG encoding for saved stills
    "python3-numpy"            # Required by picamera2 and pgeocode
    "python3-pandas"           # Required by pgeocode (avoids a large pip download/build)
    "python3-requests"         # Required by pgeocode (downloads postal data once)
    "python3-gpiozero"         # PIR motion sensor input
    "python3-lgpio"            # gpiozero pin factory backend on Trixie
    "python3-websockets"       # Live view WebSocket server
    "python3-paramiko"         # SFTP uploads to the Windows workstation
    "sqlite3"                  # CLI for inspecting upload_state.db
)

# pip packages: pure Python only.
readonly DEFAULT_REQUIREMENTS=(
    "astral"                   # Sunrise/sunset calculation
    "pgeocode"                 # Zip code to lat/long during service provisioning
)

### Variables
VENV_DIR=""
REQUIREMENTS=("${DEFAULT_REQUIREMENTS[@]}")
APT_PACKAGES=("${DEFAULT_APT_PACKAGES[@]}")
RESET_MODE=false
DETECT_ONLY=false

### Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    mkdir -p "$LOG_DIR"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

### Check available disk space
check_disk_space() {
    local path="$1"
    local required_mb="$2"

    log "INFO" "Checking available disk space for $path..."

    local available_mb
    available_mb=$(df -BM "$(dirname "$path")" | awk 'NR==2 {print $4}' | sed 's/M//')

    log "INFO" "Available disk space: ${available_mb}MB"

    if [[ $available_mb -lt $required_mb ]]; then
        log "ERROR" "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required"
        return 1
    fi

    log "INFO" "Disk space check passed"
}

### Ensure disk-backed swap exists (512MB board OOM guard during apt installs).
### Sized at 512M, not 1G like imx500, to save space on a 16GB card. All
### heavy packages come from apt (no compiling), so 512M is plenty.
ensure_swap() {
    log "INFO" "Checking for disk-backed swap..."

    if swapon --show | grep -q "^/swapfile"; then
        log "INFO" "Disk-backed swap already active at /swapfile"
        return 0
    fi

    if [[ -f /swapfile ]]; then
        log "INFO" "/swapfile exists but is not active; activating..."
        swapon /swapfile
        log "INFO" "Swap activated"
    else
        log "INFO" "Creating 512M swapfile at /swapfile..."
        fallocate -l 512M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        log "INFO" "Swapfile created and activated"
    fi

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "INFO" "Added /swapfile to /etc/fstab for persistence"
    else
        log "INFO" "/swapfile already in /etc/fstab"
    fi
}

################################################################################
### Parse Command Line Arguments
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --venv-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --venv-dir requires a path argument"
                    exit 1
                fi
                if [[ "$2" =~ [^a-zA-Z0-9/_.~-] ]]; then
                    echo "ERROR: Invalid characters in venv path: $2"
                    exit 1
                fi
                VENV_DIR="$2"
                shift 2
                ;;
            --requirement)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --requirement requires a package name"
                    exit 1
                fi
                if [[ "$2" =~ [^a-zA-Z0-9._-] ]]; then
                    echo "ERROR: Invalid characters in package name: $2"
                    exit 1
                fi
                REQUIREMENTS+=("$2")
                shift 2
                ;;
            --detect-camera)
                DETECT_ONLY=true
                shift
                ;;
            --reset)
                RESET_MODE=true
                shift
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
  --venv-dir <path>      Custom virtual environment directory
  --requirement <pkg>    Add an additional pure-Python pip package (repeatable)
  --detect-camera        Only run camera detection, then exit
  --reset                Remove the virtual environment (asks to confirm)
  -h, --help             Show this help message

Default virtual environment: ~/seccam_venv
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
}

################################################################################
### Determine Actual User and Home Directory
################################################################################
determine_user() {
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

    if [[ -z "$VENV_DIR" ]]; then
        VENV_DIR="$ACTUAL_HOME/$DEFAULT_VENV_DIR_NAME"
    fi
    VENV_DIR="${VENV_DIR/#\~/$ACTUAL_HOME}"

    log "INFO" "Target user: $ACTUAL_USER"
    log "INFO" "Home directory: $ACTUAL_HOME"
    log "INFO" "Virtual environment: $VENV_DIR"
}

################################################################################
### Reset Virtual Environment
################################################################################
reset_environment() {
    log "INFO" "========================================="
    log "INFO" "Python Environment Reset"
    log "INFO" "========================================="

    if [[ ! -d "$VENV_DIR" ]]; then
        log "INFO" "No virtual environment found at $VENV_DIR; nothing to do"
        return 0
    fi

    case "$VENV_DIR" in
        /|/home|/home/*/|/opt|/usr|"$ACTUAL_HOME"|"$ACTUAL_HOME/")
            log "ERROR" "Refusing to remove critical directory: $VENV_DIR"
            exit 1
            ;;
    esac

    if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
        log "ERROR" "$VENV_DIR does not look like a Python venv (no bin/activate); refusing to remove it"
        exit 1
    fi

    echo ""
    echo "This will permanently delete: $VENV_DIR"
    echo "Images, config.json, and upload state are NOT affected. Re-running this"
    echo "script without --reset rebuilds the venv."
    read -r -p "Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Reset cancelled by user"
        exit 0
    fi

    rm -rf "$VENV_DIR"
    log "INFO" "Virtual environment removed: $VENV_DIR"
    log "INFO" "Re-run without --reset to rebuild it"
}

################################################################################
### Install System Packages
################################################################################
install_system_packages() {
    log "INFO" "Installing system packages..."
    export DEBIAN_FRONTEND=noninteractive

    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "Package lists updated"
            break
        fi
        retry_count=$((retry_count + 1))
        log "WARN" "apt-get update failed (attempt $retry_count/$max_retries)"
        if [[ $retry_count -lt $max_retries ]]; then
            sleep 5
        else
            log "ERROR" "Failed to update package lists after $max_retries attempts"
            return 1
        fi
    done

    for pkg in "${APT_PACKAGES[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            local version
            version=$(dpkg -s "$pkg" | awk '/^Version:/ {print $2}')
            log "INFO" "$pkg already installed (version: $version)"
        else
            log "INFO" "Installing $pkg..."
            # --no-install-recommends keeps Qt/OpenGL GUI dependencies off a
            # headless Lite image (per the Picamera2 manual).
            if apt-get install -y --no-install-recommends "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                log "INFO" "$pkg installed"
            else
                log "ERROR" "Failed to install $pkg"
                return 1
            fi
        fi
    done

    # libcamera-v4l2 can claim the camera device node at boot and silently
    # block picamera2 (lesson carried over from imx500). Remove if present.
    if dpkg -s libcamera-v4l2 &>/dev/null; then
        log "WARN" "libcamera-v4l2 is installed and can block picamera2 camera access"
        if apt-get remove -y libcamera-v4l2 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "libcamera-v4l2 removed"
        else
            log "ERROR" "Failed to remove libcamera-v4l2; camera may not be detected"
            return 1
        fi
    else
        log "INFO" "libcamera-v4l2 not present (expected)"
    fi

    log "INFO" "All system packages installed"
}

################################################################################
### Detect Camera Module
################################################################################
detect_camera() {
    log "INFO" "Detecting camera..."

    if ! command -v rpicam-hello &>/dev/null; then
        log "WARN" "rpicam-hello not found; cannot detect camera"
        return 0
    fi

    local output
    output=$(sudo -u "$ACTUAL_USER" rpicam-hello --list-cameras 2>&1 || true)
    echo "$output" >> "$LOG_FILE"

    local sensor
    sensor=$(echo "$output" | grep -oE '^[[:space:]]*[0-9]+ : [A-Za-z0-9_]+' | head -n 1 | awk '{print $3}' || true)

    if [[ -z "$sensor" ]]; then
        log "WARN" "No camera detected. Check that:"
        log "WARN" "  - the ribbon cable is fully seated at both ends (contacts face the board on a Zero)"
        log "WARN" "  - you rebooted after seccampi_provision.sh"
        log "WARN" "Re-check any time with: sudo ./seccampi_provision_python.sh --detect-camera"
        return 0
    fi

    local model
    case "$sensor" in
        ov5647)       model="Camera Module v1 (5MP)" ;;
        imx219)       model="Camera Module v2 (8MP)" ;;
        imx708)       model="Camera Module 3 (12MP, autofocus)" ;;
        imx708_wide)  model="Camera Module 3 Wide (12MP, autofocus)" ;;
        imx708_noir)  model="Camera Module 3 NoIR (12MP, autofocus)" ;;
        imx708_wide_noir) model="Camera Module 3 Wide NoIR (12MP, autofocus)" ;;
        imx477)       model="HQ Camera (12MP)" ;;
        imx296)       model="Global Shutter Camera (1.6MP)" ;;
        imx500)       model="IMX500 AI Camera" ;;
        *)            model="Unrecognized sensor (may be third-party)" ;;
    esac

    log "INFO" "Camera detected: sensor '$sensor' = $model"
    log "INFO" "Camera details and supported modes:"
    echo "$output" | sed -n "/: ${sensor}/,\$p" | tee -a "$LOG_FILE" || true
}

################################################################################
### Verify Python Installation
################################################################################
verify_python() {
    log "INFO" "Verifying Python installation..."

    if ! command -v python3 &>/dev/null; then
        log "ERROR" "Python 3 not found"
        return 1
    fi

    local python_version major minor
    python_version=$(python3 --version 2>&1 | awk '{print $2}')
    major=$(echo "$python_version" | cut -d. -f1)
    minor=$(echo "$python_version" | cut -d. -f2)
    log "INFO" "Python $python_version found"

    if [[ $major -lt 3 ]] || [[ $major -eq 3 && $minor -lt 9 ]]; then
        log "ERROR" "Python 3.9 or higher required (found $python_version)"
        return 1
    fi

    if ! python3 -m venv --help &>/dev/null; then
        log "ERROR" "Python venv module not available"
        return 1
    fi
    log "INFO" "Python venv module available"
}

################################################################################
### Create Virtual Environment
################################################################################
create_virtual_environment() {
    if [[ -d "$VENV_DIR" ]]; then
        log "INFO" "Virtual environment already exists at $VENV_DIR (use --reset to recreate)"
        return 0
    fi

    local parent_dir
    parent_dir=$(dirname "$VENV_DIR")
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$parent_dir"
        log "INFO" "Created parent directory: $parent_dir"
    fi

    log "INFO" "Creating virtual environment at $VENV_DIR (with --system-site-packages)..."
    if sudo -u "$ACTUAL_USER" python3 -m venv --system-site-packages "$VENV_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        if [[ -f "$VENV_DIR/bin/activate" ]]; then
            log "INFO" "Virtual environment created"
        else
            log "ERROR" "Virtual environment created but activation script missing"
            return 1
        fi
    else
        log "ERROR" "Failed to create virtual environment"
        return 1
    fi
}

################################################################################
### Install Python Packages
################################################################################
install_python_packages() {
    log "INFO" "Installing pip packages (binary wheels only)..."

    local failed_packages=()

    for pkg in "${REQUIREMENTS[@]}"; do
        log "INFO" "Installing $pkg..."
        # --only-binary=:all: guarantees pip never compiles on the Pi. If a
        # dependency is not already satisfied by apt and has no wheel, this
        # fails immediately with a clear error instead of building for hours.
        if sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/python3" -m pip install \
                --only-binary=:all: "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "$pkg installed"
        else
            log "ERROR" "Failed to install $pkg"
            failed_packages+=("$pkg")
        fi
    done

    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log "ERROR" "Failed to install ${#failed_packages[@]} package(s): ${failed_packages[*]}"
        log "ERROR" "If a dependency tried to build from source, install its python3-* apt package and re-run"
        return 1
    fi

    log "INFO" "All pip packages installed"
}

################################################################################
### Verify Critical Packages
################################################################################
verify_packages() {
    log "INFO" "Verifying imports inside the venv..."

    local modules=(libcamera picamera2 PIL numpy gpiozero lgpio websockets paramiko sqlite3 astral pgeocode)
    local failed=()

    for mod in "${modules[@]}"; do
        if sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/python3" -c "import ${mod}" 2>>"$LOG_FILE"; then
            log "INFO" "  [OK]   $mod"
        else
            log "ERROR" "  [FAIL] $mod"
            failed+=("$mod")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log "ERROR" "Import failures: ${failed[*]}"
        return 1
    fi

    log "INFO" "Installed pip packages:"
    sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/python3" -m pip list 2>&1 | tee -a "$LOG_FILE"
}

################################################################################
### Set Proper Ownership
################################################################################
set_ownership() {
    log "INFO" "Setting ownership of $VENV_DIR..."
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$VENV_DIR"

    local owner
    owner=$(stat -c '%U:%G' "$VENV_DIR")
    if [[ "$owner" == "$ACTUAL_USER:$ACTUAL_USER" ]]; then
        log "INFO" "Ownership verified: $owner"
    else
        log "WARN" "Ownership verification failed: expected $ACTUAL_USER:$ACTUAL_USER, got $owner"
    fi
}

################################################################################
### Main Execution
################################################################################
parse_arguments "$@"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

log "INFO" "Starting Python environment provisioning script v$SCRIPT_VERSION"

determine_user

if [[ "$RESET_MODE" == true ]]; then
    reset_environment
    exit 0
fi

if [[ "$DETECT_ONLY" == true ]]; then
    detect_camera
    exit 0
fi

if ! check_disk_space "$VENV_DIR" "$MIN_DISK_SPACE_MB"; then
    exit 1
fi

log "INFO" "========================================="
log "INFO" "Python Environment Setup Started"
log "INFO" "========================================="
log "INFO" "Apt packages: ${#APT_PACKAGES[@]}  |  Pip packages: ${#REQUIREMENTS[@]}"

if ! ensure_swap; then
    log "WARN" "Could not ensure swap; continuing, but installs may run out of memory"
fi

install_system_packages || { log "ERROR" "System package installation failed"; exit 1; }
verify_python           || { log "ERROR" "Python verification failed"; exit 1; }
create_virtual_environment || { log "ERROR" "Virtual environment creation failed"; exit 1; }
install_python_packages || { log "ERROR" "Python package installation failed"; exit 1; }

if ! verify_packages; then
    log "ERROR" "Package verification failed. Fix the errors above and re-run this script."
    exit 1
fi

set_ownership
detect_camera

log "INFO" "========================================="
log "INFO" "Python Environment Setup Complete"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "Virtual environment: $VENV_DIR (owner $ACTUAL_USER, system site-packages enabled)"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "Next step: sudo ./seccampi_provision_service.sh"
log "INFO" "========================================="

#!/bin/bash
set -euo pipefail

## Usage:
## chmod +x seccampi_provision.sh
## sudo ./seccampi_provision.sh <hostname> <username> <ssh_key_url>

### Parse arguments
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <hostname> <username> <ssh_key_url>"
  exit 1
fi

NEW_HOSTNAME="$1"
USERNAME="$2"
SSH_KEY_URL="$3"

echo "Starting provisioning for $NEW_HOSTNAME with user $USERNAME..."

### 1. System update
echo "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y || echo "apt update failed"
sudo apt-get -y -o Dpkg::Options::="--force-confnew" full-upgrade || {
  echo "Retrying upgrade with --fix-missing..."
  sudo apt-get -y -o Dpkg::Options::="--force-confnew" full-upgrade --fix-missing
}

### 2. Enable I2C
echo "Enabling I2C..."
sudo raspi-config nonint do_i2c 0

### 3. Set hostname if needed
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
  echo "Updating hostname to $NEW_HOSTNAME..."
  echo "$NEW_HOSTNAME" | sudo tee /etc/hostname > /dev/null
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
else
  echo "Hostname already set. Skipping."
fi

### 4. Configure DHCP on wlan0 via NetworkManager
CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":wlan0" | cut -d: -f1)

if [[ -n "$CON_NAME" ]]; then
  echo "Configuring DHCP for NetworkManager connection: $CON_NAME"
  nmcli con mod "$CON_NAME" ipv4.addresses ""
  nmcli con mod "$CON_NAME" ipv4.method auto
  nmcli con mod "$CON_NAME" ipv4.gateway ""
  nmcli con mod "$CON_NAME" ipv4.dns ""
  nmcli con down "$CON_NAME" && nmcli con up "$CON_NAME"
  echo "✅ DHCP configuration applied via NetworkManager"
else
  echo "❌ No active NetworkManager connection found for wlan0"
fi

### 4b. Disable wlan0 power saving
WLAN_CONF="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
DESIRED_CONF="[connection]\nwifi.powersave = 2"

if [[ ! -f "$WLAN_CONF" || "$(<"$WLAN_CONF")" != "$DESIRED_CONF" ]]; then
  echo "✅ Disabling power saving on wlan0..."
  echo -e "$DESIRED_CONF" | sudo tee "$WLAN_CONF" > /dev/null
else
  echo "✅ Power saving already disabled. Skipping."
fi

### 5. Install required packages
echo "Installing required packages..."
REQUIRED_PKGS=(python3-pip i2c-tools rpi-connect-lite)

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" &> /dev/null; then
    echo "✅ Installing $pkg..."
    sudo apt-get install -y "$pkg" || {
      echo "Retrying $pkg install with --fix-missing..."
      sudo apt-get install -y "$pkg" --fix-missing
    }
  else
    echo "✅ $pkg already installed. Skipping."
  fi
done

### 6. Verify pip3
if ! command -v pip3 &> /dev/null; then
  echo "❌ pip3 missing. Bootstrapping manually..."
  curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py
  sudo python3 get-pip.py && rm get-pip.py
else
  echo "✅ pip3 is available."
fi

### 7. Enable user-lingering
if loginctl show-user "$USERNAME" | grep -q '^Linger=yes'; then
  echo "✅ [INFO] Linger already enabled for user '$USERNAME'"
else
  echo "✅ [INFO] Enabling linger for user '$USERNAME'"
  sudo loginctl enable-linger "$USERNAME"
fi

### 8. Install SSH key if provided
if [[ "$SSH_KEY_URL" != "none" ]]; then
  echo "Installing SSH key from $SSH_KEY_URL for user $USERNAME..."
  AUTH_KEYS="/home/$USERNAME/.ssh/authorized_keys"
  sudo mkdir -p "$(dirname "$AUTH_KEYS")"
  sudo curl -fsSL "$SSH_KEY_URL" | sudo tee "$AUTH_KEYS" > /dev/null
  sudo chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
  sudo chmod 600 "$AUTH_KEYS"
  echo "✅ SSH key installed."
else
  echo "No SSH key URL provided. Skipping SSH setup."
fi

### Final step
echo "✅ Provisioning complete for $NEW_HOSTNAME. Rebooting..."
sudo reboot
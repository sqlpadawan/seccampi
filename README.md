# seccam Motion-Activated Security Camera

Headless, motion-activated still camera built on a Raspberry Pi Zero 2 W, a Raspberry Pi
camera module, and a PIR motion sensor. When the PIR detects motion, the camera captures
one still image per second until motion stops. Images are stored locally by date and hour,
copied to a Windows workstation over SFTP, and pruned from the Pi after a configurable
number of days. A live view page is available on the local network, and email alerts
report upload backlogs, lost footage, and capture outages.

**Hardware:** Raspberry Pi Zero 2 W · Raspberry Pi camera module · PIR motion sensor  
**OS:** Raspberry Pi OS Lite 64-bit (Debian Trixie)  
**Stack:** Python · picamera2 · gpiozero · websockets · paramiko (SFTP) · SQLite · systemd

---

## Project Status

This project is under active development. The table below shows which components are
complete.

| Component | File | Status |
|---|---|---|
| Base OS provisioning | `seccampi_provision.sh` | Complete |
| Python environment provisioning | `seccampi_provision_python.sh` | Complete |
| Service provisioning | `seccampi_provision_service.sh` | Complete |
| Health checks and email alerts | `seccam_health.py` | Complete |
| Capture and PIR handling | `seccam_capture.py`, `seccam_capture_wrapper.sh` | In progress |
| Live view server | `seccam_server.py` | Planned |
| Windows workstation setup | `seccam_windows_setup.ps1` | Planned |
| SFTP uploader | `seccam_upload.py` | Planned |
| Retention cleanup | `seccam_cleanup.py` | Planned |

The service provisioning script can be run before every component exists. It writes all
systemd units but only starts those whose scripts are present. Re-run it after pulling
new code to start the rest.

---

## Requirements

### Hardware

- Raspberry Pi Zero 2 W (a Pi 3, 4, or 5 should also work, but is untested)
- Any official Raspberry Pi camera module (v1, v2, Camera Module 3, HQ, or Global Shutter),
  connected with a Pi Zero camera ribbon cable (the narrow 22-pin end fits the Zero)
- PIR motion sensor with a digital output (e.g. HC-SR501)
- MicroSD card, 16GB or larger
- Power supply for the Pi Zero 2 W (5V, 2.5A recommended)
- 2.4 GHz WiFi (the Zero 2 W does not support 5 GHz)
- A Windows 10 or 11 workstation on the same network to receive images

### Software

- Raspberry Pi OS Lite 64-bit (Debian Trixie), the same OS as the imx500 project
- Internet connection during provisioning (for package installation)
- A computer with SSH access to the Pi
- On the workstation: the Windows OpenSSH Server optional feature
- For email alerts: an SMTP account (a dedicated Gmail account with an app password is recommended)

### Disk Space

On a 16GB card, expect roughly 11GB free after the OS, packages, and swapfile. The default
2GB free-space floor leaves about 9GB for images. At 1920x1080, one 2-minute motion event
produces roughly 40 to 60MB, so the default 3-day retention fits comfortably unless the
camera sees very heavy traffic. See [Storage and Retention](#storage-and-retention).

---

## Wiring the PIR Sensor

The HC-SR501 runs on 5V but its output signal is 3.3V, so it connects directly to a GPIO
pin with no level shifting.

| PIR pin | Pi physical pin | Pi function |
|---|---|---|
| VCC | 2 | 5V |
| GND | 6 | Ground |
| OUT | 11 | GPIO 17 (default, configurable) |

HC-SR501 adjustments:

- **Trigger jumper:** set to **H** (repeatable trigger) so the output stays high while
  motion continues, instead of dropping and re-triggering.
- **Time delay potentiometer:** controls how long the output stays high after motion.
  seccam captures for as long as the output is high, so this sets the minimum length of
  each capture burst.
- **Sensitivity potentiometer:** adjusts detection range.
- Allow about 60 seconds after power-up for the sensor to settle. It may trigger
  randomly during that time.

---

## Architecture

The system runs as independent systemd user services:

| Unit | Script | Runs | Responsibility |
|---|---|---|---|
| `seccam_server.service` | `seccam_server.py` | Always | HTTP and WebSocket server for the live view |
| `seccam_capture.service` | `seccam_capture_wrapper.sh` | Always, or sunrise to sunset | PIR monitoring, still capture, event log, heartbeat |
| `seccam_capture.timer` | | 03:00 daily | Restarts capture each morning (daylight mode) |
| `seccam_upload.service` | `seccam_upload.py` | Always | SFTP uploads to the workstation with retry |
| `seccam_cleanup.timer` | `seccam_cleanup.py` | Hourly at :00 | Age-based and free-space cleanup |
| `seccam_health.timer` | `seccam_health.py` | Hourly at :30 | Health checks and email alerts |

Each service is independent by design. If the web server crashes, capture keeps
recording. If the uploader fails, the health check notices and sends an email.

### Capture Flow

1. The camera starts once and stays running, so there is no startup delay when motion
   is detected.
2. When the PIR output goes high, one still image is saved per second until the output
   goes low.
3. Each saved image is also sent to the live view server as the "latest motion image."
4. Event start and end times, with image counts, are logged to `events.jsonl`.

### Image Storage Layout

Images are stored by **local time** in date and hour folders:

```
~/seccam_images/
└── 20260922/
    ├── 14/
    │   ├── 20260922_143015_021.jpg
    │   ├── 20260922_143016_019.jpg
    │   └── ...
    └── 15/
        └── ...
```

Filenames include milliseconds so two captures in the same second never collide. The
workstation receives the same `YYYYMMDD\HH` structure.

### Runtime Files on the Pi

| Path | Purpose |
|---|---|
| `~/seccam/config.json` | Generated configuration (not committed to git) |
| `~/seccam_venv/` | Python virtual environment |
| `~/seccam_images/` | Captured images |
| `~/seccam_data/upload_state.db` | SQLite record of which images have uploaded |
| `~/seccam_data/lost_images.jsonl` | Record of images deleted before upload |
| `~/seccam_data/capture_heartbeat` | Updated by the capture loop while it runs |
| `~/seccam_data/alert_state.json` | Email alert state (prevents duplicate emails) |
| `~/.ssh/seccam_upload_ed25519` | Upload-only SSH key |
| `~/.ssh/seccam_known_hosts` | Pinned workstation host key |
| `~/.config/seccam/smtp.json` | SMTP login for alerts (mode 600) |
| `/var/log/seccam/` | Event log and service logs |

### Web Interfaces

The live view is LAN-only with no login. Do not expose these ports to the internet.

| URL | Content |
|---|---|
| `http://<pi-ip>:8081/` | Live view page with status strip |
| `http://<pi-ip>:8081/latest.jpg` | Most recent motion image |
| `http://<pi-ip>:8081/status.json` | Mode, camera state, last motion, free disk, upload queue |
| `ws://<pi-ip>:8080/` | WebSocket frame stream |

When nobody has the page open, the server shows the most recent motion image. When a
viewer connects, the capture script sends a low-resolution preview at about one frame per
second, and stops when the last viewer disconnects. This keeps CPU load, heat, and WiFi
traffic down on the Zero 2 W.

---

## Preparing the SD Card

Use Raspberry Pi Imager on your workstation:

1. **Device:** Raspberry Pi Zero 2 W
2. **Operating system:** Raspberry Pi OS (other) > **Raspberry Pi OS Lite (64-bit)**
3. **Storage:** the microSD card
4. In the OS customisation settings:
   - Set the hostname (e.g. `seccampi01`)
   - Create your user account
   - Configure your 2.4 GHz WiFi network and country
   - Set the locale and **timezone** (image folders use local time)
   - On the Services tab, enable SSH (public key authentication recommended)

After the first boot, confirm the OS and architecture:

```bash
cat /etc/os-release | grep PRETTY_NAME
dpkg --print-architecture
```

The first should mention Debian 13 (trixie), and the second should print `arm64`.
`seccampi_provision.sh` also checks both and warns if they differ.

---

## Git Setup on Raspberry Pi OS (Headless)

### Update, Install Git, and Reboot

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install -y git && sudo reboot
```

### Clone the Repository

The GitHub repository is named `seccampi`, but it is cloned into a folder named `seccam`.
The scripts and systemd units expect the code at `~/seccam`, so include the folder name
at the end of the clone command:

```bash
cd ~
git clone https://github.com/sqlpadawan/seccampi.git seccam
```

The repository is public, so no GitHub login is needed. If git asks for a username,
check the URL for typos.

### Prevent Permission Change Conflicts

Making the scripts executable with `chmod +x` changes file modes, which git tracks as a
change and which blocks future pulls. Disable mode tracking in this clone:

```bash
cd ~/seccam
git config core.fileMode false
```

This only affects the clone on the Pi and does not change anything in GitHub.

### Line Endings

The repo's `.gitattributes` forces LF line endings on `.sh` and `.py` files. If you edit
scripts on Windows without it, bash fails with `/bin/bash^M: bad interpreter`.

---

## Provisioning

Run the three provisioning scripts in order. Reboot after the first one.

```bash
cd ~/seccam
chmod +x *.sh
sudo ./seccampi_provision.sh <username>
sudo reboot
```

After the reboot:

```bash
cd ~/seccam
sudo ./seccampi_provision_python.sh
sudo ./seccampi_provision_service.sh
```

### What Each Script Does

| Script | Purpose |
|---|---|
| `seccampi_provision.sh` | Camera auto-detect, GPU and CMA memory, video and gpio groups, user lingering, persistent journal (50MB cap), WiFi power management off, log rotation, and the log, image, and data directories |
| `seccampi_provision_python.sh` | apt packages, 512MB swapfile, Python venv, pip packages, import verification, and camera detection |
| `seccampi_provision_service.sh` | Prompts for settings and writes `config.json`, creates the upload SSH key, pins the workstation host key, stores the SMTP login, writes and starts the systemd units, and adds the `seccam` alias |

### Why Most Packages Come From apt

Everything with compiled code (picamera2, numpy, pandas, Pillow, paramiko, lgpio,
websockets) is installed through apt, and the venv uses `--system-site-packages` to see
them. picamera2 has to come from apt anyway, and the apt builds are prebuilt for the Pi,
tested together, smaller on disk than pip wheels, and update with the OS, which matters on
a 16GB card. pip only installs the pure-Python packages `astral` and `pgeocode`, with
`--only-binary=:all:` so it can never start compiling a dependency from source on a
512MB board.

### Service Provisioning Prompts

`seccampi_provision_service.sh` asks for the following on first run:

| Prompt | Default |
|---|---|
| US zip code (for sunrise and sunset) | none |
| Capture schedule: `always` or `daylight` | `daylight` |
| PIR GPIO pin (BCM numbering) | 17 |
| Days of images to keep on the Pi | 3 |
| Minimum free disk space in GB | 2 |
| Enable SFTP upload, then workstation host, port, and account | yes, 22, `seccam` |
| Enable email alerts, then recipients, sender, SMTP server, port, and backlog threshold | yes, `smtp.gmail.com`, 587, 24 hours |
| SMTP username and password (hidden input) | sender address |

### Re-Provisioning

All provisioning scripts are safe to re-run and show a state check before making changes.

| Script | Re-run behavior |
|---|---|
| `seccampi_provision.sh` | Skips settings already applied, re-applies missing ones, backs up `config.txt` each run |
| `seccampi_provision_python.sh` | Skips installed packages and an existing venv. `--detect-camera` re-runs only camera detection |
| `seccampi_provision_service.sh` | Keeps the existing `config.json`, rewrites unit files, and starts any units whose scripts are now present. `--pin-host` re-pins the workstation host key. `--set-smtp-password` changes the SMTP login |

> ⚠️ **WARNING: `--reset` is destructive.**
> `seccampi_provision_python.sh --reset` deletes the virtual environment.
> `seccampi_provision_service.sh --reset` stops and disables all seccam units and removes
> `config.json`, the pinned host key, and the unit files, then re-prompts for all settings.
> Both require typing `yes` to continue. The service reset saves `config.json` and the
> known hosts file as `*.bak.<timestamp>` first. Neither touches images, upload state, the
> upload SSH key, or the SMTP login. For an extra safety copy before resetting:
>
> ```bash
> cp -p ~/seccam/config.json ~/seccam_config_backup.json
> ```

---

## Configuration

Settings live in `~/seccam/config.json`, generated during service provisioning. Edit the
file directly to change settings, then restart the affected service. Cleanup and health
checks read the file fresh on every run, so their settings need no restart.

```json
{
  "location": {
    "zip": "48888",
    "place": "Stanton, Michigan",
    "latitude": 43.2923,
    "longitude": -85.0814
  },
  "schedule": { "mode": "daylight" },
  "motion": { "gpio_pin": 17 },
  "camera": {
    "resolution": [1920, 1080],
    "jpeg_quality": 85,
    "capture_interval_s": 1.0,
    "preview_resolution": [640, 480],
    "preview_fps": 1
  },
  "storage": {
    "image_dir": "/home/<user>/seccam_images",
    "retention_days": 3,
    "min_free_gb": 2
  },
  "upload": {
    "enabled": true,
    "host": "workstation-name-or-ip",
    "port": 22,
    "username": "seccam",
    "remote_root": "/",
    "key_file": "/home/<user>/.ssh/seccam_upload_ed25519",
    "known_hosts_file": "/home/<user>/.ssh/seccam_known_hosts",
    "scan_interval_s": 30
  },
  "alerts": {
    "enabled": true,
    "recipients": ["you@example.com"],
    "from_address": "camera-alerts@gmail.com",
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 587,
    "upload_backlog_hours": 24,
    "capture_stale_minutes": 15,
    "reminder_hours": 24
  },
  "logging": { "max_log_files": 30 }
}
```

### Settings Reference

| Key | Description |
|---|---|
| `schedule.mode` | `always` captures on motion 24/7. `daylight` captures only between sunrise and sunset |
| `motion.gpio_pin` | BCM GPIO number the PIR output is wired to |
| `camera.resolution` | Still image size. Lowering it is the easiest way to save space |
| `camera.jpeg_quality` | JPEG quality, 1 to 100 |
| `camera.capture_interval_s` | Seconds between stills while motion is active |
| `camera.preview_resolution`, `preview_fps` | Live view preview size and rate (only while someone is viewing) |
| `storage.retention_days` | Days of images kept on the Pi |
| `storage.min_free_gb` | Free space the cleanup job maintains by deleting the oldest hours first |
| `upload.*` | SFTP target. `remote_root` is `/` because the Windows account is restricted to one folder |
| `upload.scan_interval_s` | How often the uploader looks for new images |
| `alerts.recipients` | One or more addresses that receive alerts |
| `alerts.from_address`, `smtp_host`, `smtp_port` | Sending account and server. Port 587 uses STARTTLS, 465 uses SSL |
| `alerts.upload_backlog_hours` | Alert when an un-uploaded image is older than this |
| `alerts.capture_stale_minutes` | Alert when the capture heartbeat is older than this while capture should be running |
| `alerts.reminder_hours` | How often to repeat an alert while the problem continues |
| `logging.max_log_files` | Daily event log files to keep |

---

## Schedule Modes

### Always

The capture wrapper runs continuously and records motion at any hour. The 03:00 timer is
harmless in this mode.

### Daylight

Same approach as the imx500 project. A systemd timer starts the capture service at 03:00.
The wrapper script then:

1. Reads the latitude and longitude from `config.json`
2. Calculates today's sunrise and sunset with the `astral` library
3. Sleeps until sunrise
4. Runs the capture script until sunset, restarting it if it crashes
5. Exits cleanly at sunset, so systemd does not restart it until the next 03:00 timer

The live view server keeps running overnight and shows the last motion image.

### Changing the Mode or Location

Edit `schedule.mode` or the `location` values in `config.json` and restart capture:

```bash
seccam restart seccam_capture.service
```

---

## Storage and Retention

`seccam_cleanup.py` runs hourly and applies two rules:

1. **Age:** delete hour folders older than `storage.retention_days`.
2. **Free space:** if free space is still below `storage.min_free_gb`, delete the oldest
   hour folders until it is back above the threshold.

The current hour is never deleted. Cleanup does not wait for images to upload. If it
deletes images that were never uploaded, it records them and the health check sends a
"footage lost" email.

Preview what cleanup would delete without deleting anything:

```bash
~/seccam_venv/bin/python3 ~/seccam/seccam_cleanup.py --dry-run
```

If space runs short, lower `camera.resolution` (e.g. to `[1280, 720]`) or
`camera.jpeg_quality`, which can roughly halve image size.

---

## Workstation Upload (SFTP)

Images are uploaded to the Windows workstation over SFTP using the built-in Windows
OpenSSH Server.

### Security Design

- The Pi uses a dedicated ed25519 key that exists only for uploads.
- On Windows, the `seccam` account is a standard (non-admin) local user, limited to SFTP
  only, and confined to a single folder with `ChrootDirectory`.
- The workstation's SSH host key is pinned during provisioning after you confirm its
  fingerprint. The uploader uses strict host key checking and refuses to connect to
  anything else.
- No Windows password is stored on the Pi.

### Upload Behavior

- Each image uploads to a temporary name, its size is verified, then it is renamed into
  place, so the workstation never sees a partial file.
- If the workstation is off or asleep, images queue on the Pi and upload when it returns.
- The workstation keeps everything. There is no automatic cleanup on the Windows side.

### Windows Setup

`seccam_windows_setup.ps1` (in progress) will install OpenSSH Server, create the `seccam`
account, configure the chrooted SFTP folder, and install the Pi's public key. Service
provisioning prints the public key at the end of its run.

### Pinning the Host Key

If the workstation was not reachable during service provisioning, pin its host key after
the Windows setup is done:

```bash
sudo ./seccampi_provision_service.sh --pin-host
```

Compare the fingerprint it shows with the one on the workstation (PowerShell):

```powershell
ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub
```

---

## Email Alerts

`seccam_health.py` runs hourly at :30 and emails the configured recipients:

| Alert | Trigger | Emails |
|---|---|---|
| Upload backlog | The oldest un-uploaded image is older than `upload_backlog_hours` | ALERT, REMINDER every `reminder_hours`, RESOLVED |
| Footage lost | Cleanup deleted images that were never uploaded | One email per batch |
| Capture down | No capture heartbeat for `capture_stale_minutes` while capture should be running | ALERT, REMINDER, RESOLVED |

The backlog email includes when the oldest waiting images will be deleted from the Pi. With
3-day retention and a 24-hour threshold, that gives about two days to fix the problem.
Capture-down checks respect the schedule mode and skip the first few minutes after a
reboot. If an email fails to send, the alert is retried on the next run.

### Setting Up a Gmail Sending Account

A dedicated Gmail account for the camera is recommended, so the stored password cannot
reach your main mailbox.

1. Create a Gmail account for the camera.
2. Turn on 2-Step Verification for that account.
3. Create an app password in the account's security settings.
4. During service provisioning, enter the Gmail address as the sender and SMTP username,
   and the app password as the SMTP password.

The SMTP login is stored in `~/.config/seccam/smtp.json` (mode 600), never in
`config.json`. To change it:

```bash
sudo ./seccampi_provision_service.sh --set-smtp-password
```

### Testing Alerts

```bash
# Send a test email
~/seccam_venv/bin/python3 ~/seccam/seccam_health.py --test-alert

# Show current status and what would be emailed, without sending or saving anything
~/seccam_venv/bin/python3 ~/seccam/seccam_health.py --dry-run
```

---

## Service Aliases

`systemctl --user` needs `XDG_RUNTIME_DIR` set when run from some shell contexts. Service
provisioning adds this alias to `~/.bashrc`:

```bash
alias seccam='XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user'
```

Open a new shell or run `source ~/.bashrc` to activate it.

### Useful Commands

| Action | Command |
|---|---|
| Server status | `seccam status seccam_server.service` |
| Restart server | `seccam restart seccam_server.service` |
| Capture status | `seccam status seccam_capture.service` |
| Restart capture | `seccam restart seccam_capture.service` |
| Uploader status | `seccam status seccam_upload.service` |
| All timers | `seccam list-timers` |
| Run cleanup now | `seccam start seccam_cleanup.service` |
| Run health check now | `seccam start seccam_health.service` |
| Capture journal | `journalctl --user -u seccam_capture.service -f` |
| Upload journal | `journalctl --user -u seccam_upload.service -f` |
| Event log | `tail -f /var/log/seccam/events.jsonl` |
| Wrapper log | `tail -f /var/log/seccam/wrapper.log` |
| Health log | `tail -f /var/log/seccam/health.log` |
| Upload count | `sqlite3 ~/seccam_data/upload_state.db "SELECT COUNT(*) FROM uploaded;"` |

---

## Verify the Installation

Check that the camera is detected:

```bash
rpicam-hello --list-cameras
```

Check services and timers:

```bash
seccam status seccam_server.service
seccam status seccam_capture.service
seccam status seccam_upload.service
seccam list-timers
```

Walk in front of the PIR sensor, then confirm images and events:

```bash
ls ~/seccam_images/$(date +%Y%m%d)/$(date +%H)/
tail -n 5 /var/log/seccam/events.jsonl
```

Open `http://<pi-ip>:8081/` in a browser, and send a test alert:

```bash
~/seccam_venv/bin/python3 ~/seccam/seccam_health.py --test-alert
```

---

## Troubleshooting

### Camera Not Detected

`rpicam-hello --list-cameras` reports "No cameras available":

- Check that the ribbon cable is fully seated at both ends. On the Pi Zero, the contacts
  face the board.
- Confirm you rebooted after `seccampi_provision.sh`.
- Re-run detection: `sudo ./seccampi_provision_python.sh --detect-camera`

Sensor names map to camera modules as follows: `ov5647` (v1), `imx219` (v2), `imx708`
(Camera Module 3, with `_wide` and `_noir` variants), `imx477` (HQ), `imx296` (Global
Shutter).

### "Cannot allocate memory" From picamera2

The CMA memory pool is too small for the configured resolution. Either lower
`camera.resolution`, or raise the pool in `/boot/firmware/config.txt` from
`dtoverlay=vc4-kms-v3d,cma-128` to `cma-160` and reboot.

### Images Filed Under the Wrong Hour

Folders use local time. If the Pi is set to UTC, set your timezone:

```bash
sudo timedatectl set-timezone America/Detroit
```

### PIR Triggers Constantly or Never

- Allow 60 seconds after power-up for the sensor to settle.
- Check the trigger jumper (H recommended) and the sensitivity potentiometer.
- Keep the sensor away from heat sources, vents, and direct sunlight.
- Confirm the pin in `config.json` matches the wiring (BCM numbering, not physical pin).

### Uploads Not Arriving

- Confirm the workstation is on and the OpenSSH Server service is running.
- Check the uploader journal: `journalctl --user -u seccam_upload.service -n 50`
- If the workstation's host key changed (e.g. after reinstalling OpenSSH), re-pin it with
  `sudo ./seccampi_provision_service.sh --pin-host`.

---

## License

See [LICENSE](LICENSE).

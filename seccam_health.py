#!/usr/bin/env python3
"""
seccam_health.py - Health checks and email alerts for seccam.

Run hourly by seccam_health.timer (at :30). Checks three conditions and emails
the configured recipients:

  1. Upload backlog   The oldest image not yet uploaded is older than
                      alerts.upload_backlog_hours. Sends ALERT, a REMINDER every
                      alerts.reminder_hours while it continues, and RESOLVED
                      when the backlog clears.
  2. Footage lost     seccam_cleanup.py deleted images that were never uploaded
                      (by age or to free disk space). Sent once per batch.
  3. Capture down     The capture loop has not written its heartbeat within
                      alerts.capture_stale_minutes while it should be running
                      (always mode, or daylight mode between sunrise and
                      sunset). ALERT / REMINDER / RESOLVED like the backlog.

Contracts with the other seccam scripts (the files this script reads):

  ~/seccam_data/upload_state.db     Written by seccam_upload.py.
                                    Table: uploaded(rel_path TEXT PRIMARY KEY,
                                    size INTEGER, uploaded_at TEXT ISO-8601)
                                    rel_path is "YYYYMMDD/HH/<file>.jpg".
  ~/seccam_data/lost_images.jsonl   Appended by seccam_cleanup.py, one line per
                                    hour folder deleted with un-uploaded images:
                                    {"ts": ISO-8601, "hour": "YYYYMMDD/HH",
                                     "files": int, "reason": "age"|"free_space"}
  ~/seccam_data/capture_heartbeat   Touched by seccam_capture.py every ~30s
                                    while the camera loop is running.

Files this script owns:
  ~/seccam_data/alert_state.json    Active alerts, last send times, and the
                                    read offset into lost_images.jsonl.
  /var/log/seccam/health.log

SMTP login is read from ~/.config/seccam/smtp.json (mode 600), written by
seccampi_provision_service.sh. It is never stored in config.json.

Usage:
    ~/seccam_venv/bin/python3 seccam_health.py              Normal hourly run
    ~/seccam_venv/bin/python3 seccam_health.py --dry-run    Show status and what
                                                            would be emailed; sends
                                                            nothing, saves nothing
    ~/seccam_venv/bin/python3 seccam_health.py --test-alert Send a test email
"""

import argparse
import json
import logging
import smtplib
import socket
import sqlite3
import ssl
import sys
import time
from datetime import datetime, timedelta
from email.message import EmailMessage
from pathlib import Path
from zoneinfo import ZoneInfo

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_DIR     = Path(__file__).resolve().parent
CONFIG_PATH  = REPO_DIR / "config.json"
DATA_DIR     = Path.home() / "seccam_data"
UPLOAD_DB    = DATA_DIR / "upload_state.db"
LOST_LOG     = DATA_DIR / "lost_images.jsonl"
HEARTBEAT    = DATA_DIR / "capture_heartbeat"
STATE_PATH   = DATA_DIR / "alert_state.json"
SECRETS_PATH = Path.home() / ".config" / "seccam" / "smtp.json"
LOG_FILE     = Path("/var/log/seccam/health.log")

LOCAL_TZ = ZoneInfo("localtime")
HOSTNAME = socket.gethostname()

# Defaults used if a key is missing from config.json
ALERT_DEFAULTS = {
    "enabled": False,
    "recipients": [],
    "from_address": "",
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 587,
    "upload_backlog_hours": 24,
    "capture_stale_minutes": 15,
    "reminder_hours": 24,
}

log = logging.getLogger("seccam_health")


# ── Setup ─────────────────────────────────────────────────────────────────────
def setup_logging() -> None:
    if log.handlers:           # already configured
        return
    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    log.setLevel(logging.INFO)
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(fmt)
    log.addHandler(stream)
    try:
        fh = logging.FileHandler(LOG_FILE)
        fh.setFormatter(fmt)
        log.addHandler(fh)
    except OSError as e:
        log.warning(f"Cannot write {LOG_FILE}: {e} (logging to journal only)")


def load_config() -> dict:
    cfg = json.loads(CONFIG_PATH.read_text())
    alerts = {**ALERT_DEFAULTS, **cfg.get("alerts", {})}
    cfg["alerts"] = alerts
    return cfg


def load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"alerts": {}, "lost_offset": 0}


def save_state(state: dict) -> None:
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_PATH)


def now_local() -> datetime:
    return datetime.now(LOCAL_TZ)


def fmt_dt(dt: datetime | None) -> str:
    return dt.strftime("%Y-%m-%d %I:%M %p") if dt else "never"


def fmt_age(td: timedelta) -> str:
    hours = td.total_seconds() / 3600
    return f"{hours / 24:.1f} days" if hours >= 48 else f"{hours:.1f} hours"


# ── Email ─────────────────────────────────────────────────────────────────────
def send_email(alerts_cfg: dict, subject: str, body: str) -> bool:
    """Send one email. Returns True on success. Never raises."""
    try:
        secrets = json.loads(SECRETS_PATH.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log.error(f"Cannot read SMTP login from {SECRETS_PATH}: {e}")
        log.error("Set it with: sudo ./seccampi_provision_service.sh --set-smtp-password")
        return False

    recipients = alerts_cfg["recipients"]
    if not recipients or not alerts_cfg["from_address"]:
        log.error("alerts.recipients and alerts.from_address must be set in config.json")
        return False

    msg = EmailMessage()
    msg["Subject"] = f"[seccam {HOSTNAME}] {subject}"
    msg["From"] = alerts_cfg["from_address"]
    msg["To"] = ", ".join(recipients)
    msg.set_content(body + f"\n\n-- \nSent by seccam_health.py on {HOSTNAME} at {fmt_dt(now_local())}\n")

    host, port = alerts_cfg["smtp_host"], int(alerts_cfg["smtp_port"])
    context = ssl.create_default_context()
    try:
        if port == 465:
            server = smtplib.SMTP_SSL(host, port, context=context, timeout=30)
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            server.starttls(context=context)
        with server:
            server.login(secrets["username"], secrets["password"])
            server.send_message(msg)
        log.info(f"Email sent: {subject}")
        return True
    except (smtplib.SMTPException, OSError, KeyError) as e:
        log.error(f"Email send failed ({host}:{port}): {e}")
        return False


# ── Check 1: upload backlog ───────────────────────────────────────────────────
def load_uploaded() -> tuple[set[str], datetime | None]:
    """Return (set of uploaded rel_paths, time of most recent upload)."""
    if not UPLOAD_DB.exists():
        return set(), None
    try:
        con = sqlite3.connect(UPLOAD_DB, timeout=10)
        try:
            paths = {r[0] for r in con.execute("SELECT rel_path FROM uploaded")}
            last = con.execute("SELECT MAX(uploaded_at) FROM uploaded").fetchone()[0]
        finally:
            con.close()
    except sqlite3.Error as e:
        log.warning(f"Could not read {UPLOAD_DB}: {e} (treating all images as pending)")
        return set(), None
    last_dt = None
    if last:
        try:
            last_dt = datetime.fromisoformat(last)
            if last_dt.tzinfo is None:
                last_dt = last_dt.replace(tzinfo=LOCAL_TZ)
        except ValueError:
            pass
    return paths, last_dt


def image_time(path: Path) -> datetime:
    """Capture time from YYYYMMDD_HHMMSS_mmm.jpg, falling back to file mtime."""
    try:
        return datetime.strptime(path.stem[:15], "%Y%m%d_%H%M%S").replace(tzinfo=LOCAL_TZ)
    except ValueError:
        return datetime.fromtimestamp(path.stat().st_mtime, LOCAL_TZ)


def scan_pending(image_dir: Path, uploaded: set[str]) -> tuple[int, datetime | None]:
    """Return (pending image count, capture time of the oldest pending image)."""
    count, oldest = 0, None
    if not image_dir.is_dir():
        return 0, None
    for day in sorted(p for p in image_dir.iterdir() if p.is_dir()):
        for hour in sorted(p for p in day.iterdir() if p.is_dir()):
            for img in sorted(hour.glob("*.jpg")):
                rel = f"{day.name}/{hour.name}/{img.name}"
                if rel in uploaded:
                    continue
                count += 1
                if oldest is None:
                    oldest = image_time(img)
    return count, oldest


def check_backlog(cfg: dict) -> dict:
    if not cfg.get("upload", {}).get("enabled", False):
        return {"active": False, "summary": "upload disabled; not checked", "detail": ""}

    uploaded, last_upload = load_uploaded()
    image_dir = Path(cfg["storage"]["image_dir"])
    pending, oldest = scan_pending(image_dir, uploaded)
    threshold = timedelta(hours=cfg["alerts"]["upload_backlog_hours"])

    if not pending:
        return {"active": False, "summary": "no images waiting to upload", "detail": ""}

    age = now_local() - oldest
    active = age >= threshold
    up = cfg["upload"]
    retention = cfg["storage"]["retention_days"]
    delete_at = oldest + timedelta(days=retention)
    detail = (
        f"{pending} image(s) are waiting to upload to {up['username']}@{up['host']}:{up['port']}.\n"
        f"Oldest waiting image: {fmt_dt(oldest)} ({fmt_age(age)} old)\n"
        f"Last successful upload: {fmt_dt(last_upload)}\n\n"
        f"With {retention}-day retention, the oldest waiting images will be deleted from the\n"
        f"Pi around {fmt_dt(delete_at)} (sooner if free space runs low).\n\n"
        f"Things to check:\n"
        f"  - Is the workstation on and awake?\n"
        f"  - Is the OpenSSH Server service running on it?\n"
        f"  - On the Pi: journalctl --user -u seccam_upload.service -n 50\n"
    )
    return {"active": active, "summary": f"{pending} pending, oldest {fmt_age(age)}", "detail": detail}


# ── Check 2: footage lost ─────────────────────────────────────────────────────
def check_lost(state: dict) -> tuple[list[dict], int]:
    """Return (new lost-image records, new file offset)."""
    if not LOST_LOG.exists():
        return [], 0
    size = LOST_LOG.stat().st_size
    offset = state.get("lost_offset", 0)
    if offset > size:          # file was truncated or replaced; start over
        offset = 0
    records = []
    with LOST_LOG.open("r") as f:
        f.seek(offset)
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                log.warning(f"Skipping malformed line in {LOST_LOG}: {line[:80]}")
        new_offset = f.tell()
    return records, new_offset


def lost_email(records: list[dict]) -> tuple[str, str]:
    total = sum(int(r.get("files", 0)) for r in records)
    reasons = {"age": "retention limit reached", "free_space": "low free disk space"}
    lines = [
        f"  {r.get('hour', '?')}: {r.get('files', '?')} image(s), "
        f"{reasons.get(r.get('reason'), r.get('reason', 'unknown reason'))}"
        for r in records
    ]
    body = (
        f"{total} image(s) were deleted from the Pi before they were uploaded.\n"
        f"These images are gone and do not exist on the workstation.\n\n"
        + "\n".join(lines)
        + "\n\nThis usually follows an upload backlog alert. If deletions were for low\n"
        "free space, consider lowering camera.resolution or storage.retention_days.\n"
    )
    return f"FOOTAGE LOST: {total} image(s) deleted before upload", body


# ── Check 3: capture down ─────────────────────────────────────────────────────
def capture_expected(cfg: dict, grace: timedelta) -> tuple[bool, str]:
    """Whether the capture loop should be running right now (with start-up grace)."""
    try:
        uptime = float(Path("/proc/uptime").read_text().split()[0])
        if uptime < grace.total_seconds():
            return False, "system booted recently; within start-up grace period"
    except (OSError, ValueError):
        pass

    mode = cfg.get("schedule", {}).get("mode", "daylight")
    if mode == "always":
        return True, "always mode"

    from astral import LocationInfo
    from astral.sun import sun

    loc = cfg["location"]
    now = now_local()
    s = sun(LocationInfo(latitude=loc["latitude"], longitude=loc["longitude"]).observer,
            date=now.date(), tzinfo=LOCAL_TZ)
    start, end = s["sunrise"] + grace, s["sunset"]
    if start <= now < end:
        return True, f"daylight mode (sunrise {s['sunrise']:%I:%M %p}, sunset {end:%I:%M %p})"
    return False, f"daylight mode, outside {start:%I:%M %p} to {end:%I:%M %p}"


def check_capture(cfg: dict) -> dict:
    stale = timedelta(minutes=cfg["alerts"]["capture_stale_minutes"])
    expected, why = capture_expected(cfg, stale)
    if not expected:
        return {"active": False, "summary": f"not expected to run ({why})", "detail": ""}

    if HEARTBEAT.exists():
        last = datetime.fromtimestamp(HEARTBEAT.stat().st_mtime, LOCAL_TZ)
        age = now_local() - last
    else:
        last, age = None, None

    if age is not None and age < stale:
        return {"active": False, "summary": f"running (heartbeat {int(age.total_seconds())}s ago)", "detail": ""}

    detail = (
        f"The capture loop should be running ({why}) but its last heartbeat was\n"
        f"{fmt_dt(last)}" + (f" ({fmt_age(age)} ago)" if age else "") + ".\n"
        f"Motion will NOT be recorded until this is fixed.\n\n"
        f"Things to check on the Pi:\n"
        f"  seccam status seccam_capture.service\n"
        f"  journalctl --user -u seccam_capture.service -n 50\n"
        f"  tail -n 50 /var/log/seccam/wrapper.log\n"
    )
    return {"active": True, "summary": f"heartbeat stale ({fmt_dt(last)})", "detail": detail}


# ── Alert state machine ───────────────────────────────────────────────────────
def process_stateful(name: str, title: str, result: dict, state: dict,
                     alerts_cfg: dict, dry_run: bool) -> None:
    """ALERT on start, REMINDER every reminder_hours, RESOLVED on clear.
    State only advances when the email actually sends, so failures retry next run."""
    s = state["alerts"].get(name, {})
    now = time.time()
    remind = alerts_cfg["reminder_hours"] * 3600

    if result["active"] and not s.get("active"):
        subject, body, new = f"ALERT: {title}", result["detail"], {"active": True, "since": now, "last_sent": now}
    elif result["active"] and now - s.get("last_sent", 0) >= remind:
        since = datetime.fromtimestamp(s.get("since", now), LOCAL_TZ)
        subject = f"REMINDER: {title} (since {fmt_dt(since)})"
        body, new = result["detail"], {**s, "last_sent": now}
    elif not result["active"] and s.get("active"):
        since = datetime.fromtimestamp(s.get("since", now), LOCAL_TZ)
        subject = f"RESOLVED: {title}"
        body = f"This condition has cleared.\nIt started {fmt_dt(since)}.\nCurrent status: {result['summary']}\n"
        new = {"active": False}
    else:
        return

    if dry_run:
        log.info(f"[dry-run] Would send: {subject}")
        print("-" * 60 + f"\n{body}" + "-" * 60)
        return
    if send_email(alerts_cfg, subject, body):
        state["alerts"][name] = new


# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="seccam health checks and email alerts")
    parser.add_argument("--dry-run", action="store_true", help="show status and pending emails; send and save nothing")
    parser.add_argument("--test-alert", action="store_true", help="send a test email and exit")
    args = parser.parse_args()

    setup_logging()

    try:
        cfg = load_config()
    except (OSError, json.JSONDecodeError) as e:
        log.error(f"Cannot read {CONFIG_PATH}: {e}")
        return 1
    alerts_cfg = cfg["alerts"]

    if args.test_alert:
        ok = send_email(alerts_cfg, "Test alert",
                        "This is a test email from seccam. If you received it, email alerts are working.\n")
        return 0 if ok else 1

    if not alerts_cfg["enabled"] and not args.dry_run:
        log.info("Email alerts disabled in config.json; nothing to do")
        return 0

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    state = load_state()
    state.setdefault("alerts", {})

    backlog = check_backlog(cfg)
    capture = check_capture(cfg)
    lost_records, lost_offset = check_lost(state)

    log.info(f"Upload backlog: {'ALERT' if backlog['active'] else 'ok'}  ({backlog['summary']})")
    log.info(f"Capture:        {'ALERT' if capture['active'] else 'ok'}  ({capture['summary']})")
    log.info(f"Footage lost:   {len(lost_records)} new record(s)")

    process_stateful("upload_backlog", "images not uploading", backlog, state, alerts_cfg, args.dry_run)
    process_stateful("capture_down", "camera capture is not running", capture, state, alerts_cfg, args.dry_run)

    if lost_records:
        subject, body = lost_email(lost_records)
        if args.dry_run:
            log.info(f"[dry-run] Would send: {subject}")
            print("-" * 60 + f"\n{body}" + "-" * 60)
        elif send_email(alerts_cfg, subject, body):
            state["lost_offset"] = lost_offset
    else:
        state["lost_offset"] = lost_offset

    if not args.dry_run:
        save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())

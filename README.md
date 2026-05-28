# Security-Automation
#security automation log monitor

import re
import time
import subprocess
import smtplib
from email.mime.text import MIMEText

LOG_FILE = "/var/log/syslog"
KEYWORDS = {
    r"failed password": "Possible brute-force attempt",
    r"unauthorized access": "Unauthorized access attempt",
    r"error": "System or service error"
}

# -----------------------------
# Send Email Alert
# -----------------------------
def send_email_alert(subject, message):
    sender = "alert@example.com"
    recipient = "admin@example.com"

    msg = MIMEText(message)
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = recipient

    try:
        with smtplib.SMTP("localhost") as server:
            server.sendmail(sender, [recipient], msg.as_string())
        print("[+] Email alert sent")
    except Exception as e:
        print(f"[!] Failed to send email: {e}")

# -----------------------------
# Automated Response (Optional)
# -----------------------------
def block_ip(ip):
    try:
        subprocess.run(["sudo", "iptables", "-A", "INPUT", "-s", ip, "-j", "DROP"])
        print(f"[+] Blocked IP: {ip}")
    except Exception as e:
        print(f"[!] Failed to block IP: {e}")

# -----------------------------
# Real-Time Log Monitoring
# -----------------------------
def monitor_logs():
    print("[+] Starting real-time security log monitor...")
    with open(LOG_FILE, "r") as file:
        file.seek(0, 2)  # Move to end of file (tail -f behavior)

        while True:
            line = file.readline()
            if not line:
                time.sleep(0.5)
                continue

            for pattern, description in KEYWORDS.items():
                if re.search(pattern, line, re.IGNORECASE):
                    alert_msg = f"{description}: {line.strip()}"
                    print(f"[ALERT] {alert_msg}")

                    # Send alert
                    send_email_alert("Security Alert Detected", alert_msg)

                    # Optional automated response
                    ip_match = re.search(r"(\d+\.\d+\.\d+\.\d+)", line)
                    if ip_match:
                        block_ip(ip_match.group(1))

if __name__ == "__main__":
    monitor_logs()

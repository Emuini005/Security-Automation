# 🛡️ Security Automation: Backup & Recovery System

## 📘 Overview
This repository contains my **Security Automation class project**, demonstrating a secure, reliable, and fully automated **backup and recovery system** 

The goal of this project is to show how automation improves:

- Data protection  
- System resilience  
- Integrity verification  
- Operational efficiency  
- Security‑driven workflows  

This project includes two core components:

- **Automated Backup Script**  
- **Automated Recovery Script**

Both scripts use **pure Python configuration** (no JSON files) and are intentionally simplified for clarity, academic evaluation, and demonstration of security automation concepts.

---

# 📦 Components

## 1️⃣ Automated Backup Script (`backup.py`)

The backup script creates timestamped, versioned backups of a project directory while enforcing security and operational best practices.

### 🔐 Features
- Creates compressed `.tar.gz` backup archives  
- Excludes unnecessary files (e.g., `.git`, `__pycache__`, virtualenvs)  
- Generates **SHA256 checksums** for integrity verification  
- Applies a **retention policy** (keeps last N backups)  
- Logs all actions to both console and file  
- Uses **internal Python dictionaries** for configuration  

### ▶️ Run the backup
```bash
python3 backup.py
```

### 📁 Backup output structure
```
.backups/
    backup_YYYYMMDD_HHMMSS.tar.gz
    backup_YYYYMMDD_HHMMSS.tar.gz.sha256
    backup.log
```

### 🧠 Security Concepts Demonstrated
- **Integrity verification** using SHA256  
- **Automated lifecycle management** via retention  
- **Audit logging** for traceability  
- **Configuration management** using Python dictionaries  

---

## 2️⃣ Automated Recovery Script (`recovery.py`)

The recovery script safely restores a selected backup, verifies integrity, and protects the system from failed restores using rollback snapshots.

### 🔐 Features
- Lists available backups  
- Restores from `.tar.gz` backup archives  
- Verifies integrity using `.sha256` checksum files  
- Creates a **rollback snapshot** before restoring  
- Automatically rolls back if restoration fails  
- Logs all actions for auditing  
- Uses **internal Python configuration** (no JSON files)  

### ▶️ List backups
```bash
python3 recovery.py --list
```

### ▶️ Restore the latest backup
```bash
python3 recovery.py --restore latest
```

### ▶️ Restore a specific backup
```bash
python3 recovery.py --restore backup_20260615_120000.tar.gz
```

### 🧠 Security Concepts Demonstrated
- **Safe recovery with rollback**  
- **Integrity validation before restore**  
- **Audit logging**  
- **Controlled restoration workflow**  

---

# 📂 Recommended Repository Structure
```
/Security-Automation
│
├── backup.py
├── recovery.py
│
├── .backups/
│   ├── backup_*.tar.gz
│   ├── backup_*.tar.gz.sha256
│   └── backup.log
│
└── README.md
```

---

# 🧩 System Diagrams
Diagrams for this project are included separately:

- **Backup Process Flow Diagram**  
- **Recovery Process Flow Diagram**  
- **System Architecture Diagram**  

These diagrams illustrate the end‑to‑end automation workflow and match the simplified Python scripts.

---

# 🚀 Future Enhancements
- Add email or Slack notifications  
- Add encryption for backup archives  
- Add scheduled backups via cron  
- Add cloud upload (AWS S3, Azure Blob, etc.)  
- Add anomaly detection for backup integrity trends  

---

# 🎓 Summary
This project demonstrates a complete, security‑focused automation workflow:

- Automated backups  
- Automated recovery  
- Integrity checks  
- Rollback protection  
- Logging and auditability  
- Pure Python configuration (no external files)  

It fulfills the requirements for the **CYB333 Security Automation** project by showcasing practical, real‑world automation techniques used in modern security operations.

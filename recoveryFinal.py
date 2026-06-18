#!/usr/bin/env python3
"""
Security-Automation Recovery Script (Simplified Version)
=======================================================

Course: Security Automation
Project Goal:
    Demonstrate automated recovery of a project repository from backups
    with integrity verification, rollback safety, and audit logging.

What this script does:
    - Lists available backups
    - Restores a selected backup archive
    - Verifies backup integrity using SHA256 checksum files
    - Creates a rollback snapshot before restoring
    - Automatically rolls back if restoration fails
    - Logs all actions for audit and troubleshooting

This version uses **pure Python configuration only**.
No JSON files are created or loaded.
"""

import os
import sys
import tarfile
import shutil
import hashlib
import argparse
import logging
from datetime import datetime
from pathlib import Path


# -----------------------------
# Configuration (pure Python)
# -----------------------------

DEFAULT_CONFIG = {
    "enable_integrity_check": True,
    "enable_rollback": True,
    "backup_dir": ".backups",
}


# -----------------------------
# Logging
# -----------------------------

def setup_logger(log_path: Path) -> logging.Logger:
    logger = logging.getLogger("recovery")
    logger.setLevel(logging.DEBUG)

    fh = logging.FileHandler(log_path)
    fh.setLevel(logging.DEBUG)

    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)

    formatter = logging.Formatter("[%(asctime)s] %(levelname)s: %(message)s")
    fh.setFormatter(formatter)
    ch.setFormatter(formatter)

    logger.addHandler(fh)
    logger.addHandler(ch)

    return logger


# -----------------------------
# Utility Functions
# -----------------------------

def compute_sha256(file_path: Path) -> str:
    """Compute SHA256 hash of a file."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_checksum(archive_path: Path, logger: logging.Logger) -> bool:
    """
    Verify the archive's SHA256 checksum using the .sha256 file
    created by the backup script.
    """
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")

    if not checksum_path.exists():
        logger.warning("Checksum file not found; skipping integrity check")
        return True

    content = checksum_path.read_text().strip()
    expected = content.split("  ")[0]
    actual = compute_sha256(archive_path)

    if actual == expected:
        logger.info("Checksum verification succeeded")
        return True
    else:
        logger.error("Checksum verification FAILED")
        return False


def list_backups(backup_root: Path, logger: logging.Logger):
    """
    List available backup archives.
    """
    backups = sorted(
        backup_root.glob("backup_*.tar.gz"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if not backups:
        logger.error("No backups found")
        return []

    print("\nAvailable Backups:\n")
    for i, b in enumerate(backups, 1):
        timestamp = datetime.fromtimestamp(b.stat().st_mtime)
        size_kb = b.stat().st_size / 1024
        print(f"[{i}] {b.name}")
        print(f"    Size: {size_kb:.1f} KB")
        print(f"    Date: {timestamp}")
        print("")

    return backups


def create_rollback_snapshot(target_dir: Path, rollback_dir: Path, logger: logging.Logger):
    """Create a rollback snapshot of the current project directory."""
    logger.info("Creating rollback snapshot...")
    rollback_dir.mkdir(parents=True, exist_ok=True)

    for item in target_dir.iterdir():
        dest = rollback_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest, dirs_exist_ok=True)
        else:
            shutil.copy2(item, dest)

    logger.info("Rollback snapshot created")


def rollback(target_dir: Path, rollback_dir: Path, logger: logging.Logger):
    """Restore the rollback snapshot."""
    logger.warning("Rolling back to previous state...")

    for item in target_dir.iterdir():
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()

    for item in rollback_dir.iterdir():
        dest = target_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest, dirs_exist_ok=True)
        else:
            shutil.copy2(item, dest)

    logger.info("Rollback completed")


def restore_backup(archive_path: Path, target_dir: Path, config: dict, logger: logging.Logger):
    """
    Restore from a backup archive.

    Steps:
        1. Verify integrity (optional)
        2. Create rollback snapshot
        3. Extract archive
        4. Roll back if extraction fails
    """
    logger.info(f"Restoring from archive: {archive_path.name}")

    # Step 1: Integrity check
    if config["enable_integrity_check"]:
        if not verify_checksum(archive_path, logger):
            logger.error("Backup integrity failed; aborting restore")
            return False

    # Step 2: Rollback snapshot
    rollback_dir = target_dir / f".rollback_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if config["enable_rollback"]:
        create_rollback_snapshot(target_dir, rollback_dir, logger)

    # Step 3: Extract archive
    try:
        logger.info("Extracting backup archive...")
        with tarfile.open(archive_path, "r:gz") as tar:
            tar.extractall(target_dir)
        logger.info("Restore completed successfully")
        return True

    except Exception as e:
        logger.error(f"Restore failed: {e}")

        if config["enable_rollback"]:
            rollback(target_dir, rollback_dir, logger)

        return False


# -----------------------------
# CLI
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Security-Automation Recovery Script")
    parser.add_argument("--list", action="store_true", help="List available backups")
    parser.add_argument("--restore", type=str, help="Backup name or 'latest'")
    parser.add_argument("--target", type=str, default=".", help="Directory to restore into")
    return parser.parse_args()


def main():
    script_dir = Path(__file__).parent.resolve()
    backup_root = script_dir / DEFAULT_CONFIG["backup_dir"]
    target_dir = Path.cwd()

    backup_root.mkdir(exist_ok=True)

    log_path = backup_root / f"recovery_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    logger = setup_logger(log_path)

    args = parse_args()

    if args.list:
        list_backups(backup_root, logger)
        return

    if args.restore:
        backups = list_backups(backup_root, logger)
        if not backups:
            return

        if args.restore == "latest":
            archive_path = backups[0]
        else:
            archive_path = backup_root / args.restore

        if not archive_path.exists():
            logger.error("Backup not found")
            return

        restore_backup(archive_path, target_dir, DEFAULT_CONFIG, logger)
        return

    print("Use --list or --restore <backup_file>")


if __name__ == "__main__":
    main()


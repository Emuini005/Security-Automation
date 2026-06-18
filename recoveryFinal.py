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
    - Restores a selected backup (repository files only)
    - Verifies backup integrity using SHA256 checksums
    - Creates a rollback snapshot before restoring
    - Automatically rolls back if restoration fails
    - Logs all actions for audit and troubleshooting

This version is intentionally simplified to:
    - Match the simplified backup script
    - Make the logic easy to follow for academic evaluation
    - Highlight core security automation concepts
"""

import os
import sys
import json
import tarfile
import shutil
import hashlib
import argparse
import logging
from datetime import datetime
from pathlib import Path


# -----------------------------
# Configuration
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
    """
    Configure a logger that writes to both console and file.

    Security relevance:
        - Provides an audit trail of recovery actions.
        - Helps diagnose failures and supports incident response.
    """
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

def load_config(config_path: Path) -> dict:
    """
    Load recovery configuration from JSON file.
    If missing, create it with defaults.

    This mirrors the backup script's config handling.
    """
    if config_path.exists():
        data = json.loads(config_path.read_text())
        cfg = DEFAULT_CONFIG.copy()
        cfg.update(data)
        return cfg
    else:
        config_path.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        return DEFAULT_CONFIG.copy()


def compute_sha256(file_path: Path) -> str:
    """Compute SHA256 hash of a file."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_checksum(backup_dir: Path, logger: logging.Logger) -> bool:
    """
    Verify all files listed in checksums.json.

    Security relevance:
        - Ensures backup has not been corrupted or tampered with.
    """
    checksum_file = backup_dir / "checksums.json"
    if not checksum_file.exists():
        logger.warning("No checksum file found; skipping integrity check")
        return True

    checksums = json.loads(checksum_file.read_text())
    logger.info("Verifying backup integrity...")

    all_valid = True
    for rel_path, expected_hash in checksums.items():
        full_path = backup_dir / rel_path
        if not full_path.exists():
            logger.error(f"Missing file: {rel_path}")
            all_valid = False
            continue

        actual_hash = compute_sha256(full_path)
        if actual_hash != expected_hash:
            logger.error(f"Hash mismatch: {rel_path}")
            all_valid = False

    if all_valid:
        logger.info("Integrity check passed")
    else:
        logger.error("Integrity check FAILED")

    return all_valid


# -----------------------------
# Recovery Operations
# -----------------------------

def list_backups(backup_root: Path, logger: logging.Logger):
    """
    List available backups with size and timestamp.

    This helps the user choose which backup to restore.
    """
    backups = sorted(
        backup_root.glob("backup_*"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if not backups:
        logger.error("No backups found")
        return

    print("\nAvailable Backups:\n")
    for i, b in enumerate(backups, 1):
        size = sum(f.stat().st_size for f in b.rglob("*") if f.is_file())
        timestamp = datetime.fromtimestamp(b.stat().st_mtime)
        print(f"[{i}] {b.name}")
        print(f"    Size: {size/1024:.1f} KB")
        print(f"    Date: {timestamp}")
        print("")

    return backups


def create_rollback_snapshot(target_dir: Path, rollback_dir: Path, logger: logging.Logger):
    """
    Create a rollback snapshot of the current project directory.

    Security relevance:
        - Allows safe rollback if recovery fails.
    """
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
    """
    Restore the rollback snapshot.

    This prevents partial or corrupted restores from leaving the system
    in an inconsistent state.
    """
    logger.warning("Rolling back to previous state...")

    # Clear target directory
    for item in target_dir.iterdir():
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()

    # Restore snapshot
    for item in rollback_dir.iterdir():
        dest = target_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest, dirs_exist_ok=True)
        else:
            shutil.copy2(item, dest)

    logger.info("Rollback completed")


def restore_backup(backup_dir: Path, target_dir: Path, config: dict, logger: logging.Logger):
    """
    Restore repository files from a backup archive.

    Steps:
        1. Verify integrity (optional)
        2. Create rollback snapshot
        3. Extract backup archive
        4. Roll back if extraction fails
    """
    logger.info(f"Restoring from backup: {backup_dir.name}")

    # Step 1: Integrity check
    if config["enable_integrity_check"]:
        if not verify_checksum(backup_dir, logger):
            logger.error("Backup integrity failed; aborting restore")
            return False

    # Step 2: Create rollback snapshot
    rollback_dir = backup_dir / f"rollback_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if config["enable_rollback"]:
        create_rollback_snapshot(target_dir, rollback_dir, logger)

    # Step 3: Extract archive
    archive = next(backup_dir.glob("repository/repo_files_*.tar.gz"), None)
    if not archive:
        logger.error("Backup archive not found")
        return False

    try:
        logger.info("Extracting backup archive...")
        with tarfile.open(archive, "r:gz") as tar:
            tar.extractall(target_dir)
        logger.info("Restore completed successfully")
        return True

    except Exception as e:
        logger.error(f"Restore failed: {e}")

        # Step 4: Roll back
        if config["enable_rollback"]:
            rollback(target_dir, rollback_dir, logger)

        return False


# -----------------------------
# CLI
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Security-Automation Recovery Script")
    parser.add_argument("--list", action="store_true", help="List available backups")
    parser.add_argument("--restore", type=str, help="Backup ID to restore (or 'latest')")
    parser.add_argument("--target", type=str, default=".", help="Directory to restore into")
    return parser.parse_args()


def main():
    script_dir = Path(__file__).parent.resolve()
    config_path = script_dir / "recovery-config.json"
    backup_root = script_dir / DEFAULT_CONFIG["backup_dir"]
    target_dir = Path.cwd()

    # Ensure backup directory exists
    backup_root.mkdir(exist_ok=True)

    # Setup logging
    log_path = backup_root / f"recovery_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    logger = setup_logger(log_path)

    # Load config
    config = load_config(config_path)

    args = parse_args()

    if args.list:
        list_backups(backup_root, logger)
        return

    if args.restore:
        backups = list_backups(backup_root, logger)
        if not backups:
            return

        if args.restore == "latest":
            backup_dir = backups[0]
        else:
            backup_dir = backup_root / args.restore

        if not backup_dir.exists():
            logger.error("Backup not found")
            return

        restore_backup(backup_dir, target_dir, config, logger)
        return

    print("Use --list or --restore <backup_id>")


if __name__ == "__main__":
    main()

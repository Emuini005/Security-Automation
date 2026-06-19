#!/usr/bin/env python3
"""
Security-Automation Backup Script (Simplified Version)
=====================================================

Course: Security Automation
Project Goal:
    Demonstrate automation of a security-relevant task (repository backup)
    with logging, integrity verification, immutability, and basic retention.

What this script does:
    - Creates timestamped backups of a project directory
    - Excludes unnecessary files (caches, virtualenvs, etc.)
    - Compresses the backup into a .tar.gz archive
    - Generates SHA256 checksums for integrity verification
    - Applies Linux immutability flags to protect backups
    - Applies a simple retention policy (keep last N backups)
    - Logs all actions to a log file and to the console

This version uses pure Python configuration only.
"""

import os
import sys
import tarfile
import hashlib
import shutil
import logging
import subprocess
from datetime import datetime
from pathlib import Path
import argparse

# -----------------------------
# Configuration (pure Python)
# -----------------------------

DEFAULT_CONFIG = {
    "backup_dir": ".backups",
    "max_backups": 5,
    "exclude_patterns": [
        ".git",
        ".venv",
        "venv",
        "__pycache__",
        ".pytest_cache",
        "*.pyc",
        ".DS_Store",
    ],
    "enable_checksums": True,
    "enable_immutability": True,
}

# -----------------------------
# Logging setup
# -----------------------------

def setup_logger(log_path: Path) -> logging.Logger:
    logger = logging.getLogger("backup")
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
# Utility functions
# -----------------------------

def should_exclude(path: Path, patterns) -> bool:
    name = path.name
    for pattern in patterns:
        if pattern.startswith("*.") and name.endswith(pattern[1:]):
            return True
        if pattern in name:
            return True
    return False


def create_backup_archive(source_dir: Path, backup_root: Path, exclude_patterns, logger):
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    archive_name = f"backup_{timestamp}.tar.gz"
    archive_path = backup_root / archive_name

    logger.info(f"Creating backup archive: {archive_path}")
    backup_root.mkdir(parents=True, exist_ok=True)

    with tarfile.open(archive_path, "w:gz") as tar:
        for root, dirs, files in os.walk(source_dir):
            root_path = Path(root)

            dirs[:] = [
                d for d in dirs
                if not should_exclude(root_path / d, exclude_patterns)
            ]

            for file in files:
                file_path = root_path / file
                if should_exclude(file_path, exclude_patterns):
                    continue

                arcname = file_path.relative_to(source_dir)
                tar.add(file_path, arcname=arcname)

    logger.info("Backup archive created successfully")
    return archive_path


def compute_sha256(file_path: Path) -> str:
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def write_checksum_file(archive_path: Path, logger):
    checksum = compute_sha256(archive_path)
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    checksum_path.write_text(f"{checksum}  {archive_path.name}\n")
    logger.info(f"Checksum written to {checksum_path}")
    return checksum_path


def verify_checksum(archive_path: Path, checksum_path: Path, logger) -> bool:
    if not checksum_path.exists():
        logger.warning("Checksum file not found; skipping verification")
        return False

    content = checksum_path.read_text().strip()
    expected = content.split("  ")[0]
    actual = compute_sha256(archive_path)

    if actual == expected:
        logger.info("Checksum verification succeeded")
        return True
    else:
        logger.error("Checksum verification FAILED")
        return False


# -----------------------------
# Immutability Support
# -----------------------------

def make_immutable(path: Path, logger):
    """
    Applies Linux immutable flag (+i) to a file.
    Prevents modification, deletion, or renaming.
    """
    try:
        subprocess.run(["chattr", "+i", str(path)], check=True)
        logger.info(f"Immutable flag applied: {path}")
    except Exception as e:
        logger.error(f"Failed to apply immutable flag to {path}: {e}")


def remove_immutable(path: Path, logger):
    """
    Removes immutable flag (-i) so retention can delete old backups.
    """
    try:
        subprocess.run(["chattr", "-i", str(path)], check=False)
        logger.debug(f"Immutable flag removed: {path}")
    except Exception as e:
        logger.error(f"Failed to remove immutable flag: {e}")


# -----------------------------
# Retention Policy
# -----------------------------

def apply_retention_policy(backup_root: Path, max_backups: int, logger):
    archives = sorted(
        backup_root.glob("backup_*.tar.gz"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if len(archives) <= max_backups:
        logger.info("Retention policy: nothing to delete")
        return

    for old in archives[max_backups:]:
        logger.info(f"Deleting old backup: {old.name}")

        # Remove immutability before deletion
        remove_immutable(old, logger)
        checksum = old.with_suffix(old.suffix + ".sha256")
        remove_immutable(checksum, logger)

        if checksum.exists():
            checksum.unlink()
        old.unlink()

# -----------------------------
# Main backup flow
# -----------------------------

def run_backup(project_root: Path, config: dict, logger):
    backup_root = project_root / config["backup_dir"]

    archive_path = create_backup_archive(
        source_dir=project_root,
        backup_root=backup_root,
        exclude_patterns=config["exclude_patterns"],
        logger=logger,
    )

    if config["enable_checksums"]:
        checksum_path = write_checksum_file(archive_path, logger)
        verify_checksum(archive_path, checksum_path, logger)

        if config["enable_immutability"]:
            make_immutable(archive_path, logger)
            make_immutable(checksum_path, logger)

    apply_retention_policy(
        backup_root=backup_root,
        max_backups=config["max_backups"],
        logger=logger,
    )

    logger.info("Backup process completed.")

# -----------------------------
# CLI entry point
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Security-Automation Backup Script (Simplified)"
    )
    parser.add_argument(
        "--project-root",
        type=str,
        default=".",
        help="Path to the project directory to back up",
    )
    return parser.parse_args()


def main():
    script_dir = Path(__file__).parent.resolve()
    args = parse_args()

    project_root = (script_dir / args.project_root).resolve()
    backup_root = project_root / DEFAULT_CONFIG["backup_dir"]
    log_path = backup_root / "backup.log"

    backup_root.mkdir(parents=True, exist_ok=True)
    logger = setup_logger(log_path)

    logger.info(f"Starting backup for project: {project_root}")
    run_backup(project_root, DEFAULT_CONFIG, logger)


if __name__ == "__main__":
    main()

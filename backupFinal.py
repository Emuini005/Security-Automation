#!/usr/bin/env python3
"""
Security-Automation Backup Script (Simplified Version)
=====================================================

Course: Security Automation
Project Goal:
    Demonstrate automation of a security-relevant task (repository backup)
    with logging, integrity verification, and basic retention.

What this script does:
    - Creates timestamped backups of a project directory
    - Excludes unnecessary files (caches, virtualenvs, etc.)
    - Compresses the backup into a .tar.gz archive
    - Generates SHA256 checksums for integrity verification
    - Applies a simple retention policy (keep last N backups)
    - Logs all actions to a log file and to the console

This version is intentionally simpler than a production system so that:
    - The control flow is easy to follow
    - Each security-related concept (logging, integrity, retention)
      is visible and explainable in an assignment.
"""

import os
import sys
import tarfile
import hashlib
import shutil
import logging
from datetime import datetime
from pathlib import Path
import argparse
import json

# -----------------------------
# Configuration (simple, explicit)
# -----------------------------

# Default configuration values.
# In a real deployment, these could be loaded from a JSON/YAML file.
DEFAULT_CONFIG = {
    # Where backups will be stored (relative to script directory)
    "backup_dir": ".backups",

    # How many backup archives to keep (retention policy)
    "max_backups": 5,

    # File and directory name patterns to skip during backup
    "exclude_patterns": [
        ".git",
        ".venv",
        "venv",
        "__pycache__",
        ".pytest_cache",
        "*.pyc",
        ".DS_Store",
    ],

    # Whether to generate and verify checksums
    "enable_checksums": True,
}


# -----------------------------
# Logging setup
# -----------------------------

def setup_logger(log_path: Path) -> logging.Logger:
    """
    Configure a logger that writes to both a file and the console.

    Security relevance:
        - Logging provides an audit trail of backup activity.
        - Useful for incident response and troubleshooting.
    """
    logger = logging.getLogger("backup")
    logger.setLevel(logging.DEBUG)

    # File handler (detailed logs)
    fh = logging.FileHandler(log_path)
    fh.setLevel(logging.DEBUG)

    # Console handler (high-level info)
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

def load_config(config_path: Path) -> dict:
    """
    Load configuration from JSON file if it exists, otherwise
    create it with DEFAULT_CONFIG.

    This shows basic configuration management, which is common
    in security automation tooling.
    """
    if config_path.exists():
        with open(config_path, "r") as f:
            data = json.load(f)
        # Merge with defaults so new keys don't break older configs
        cfg = DEFAULT_CONFIG.copy()
        cfg.update(data)
        return cfg
    else:
        config_path.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        return DEFAULT_CONFIG.copy()


def should_exclude(path: Path, patterns) -> bool:
    """
    Decide whether a file or directory should be excluded based on
    simple substring or suffix matching.

    This keeps backups smaller and avoids noisy or sensitive paths
    (like virtualenvs or caches).
    """
    name = path.name
    for pattern in patterns:
        # Very simple matching: suffix (e.g., *.pyc) or substring
        if pattern.startswith("*.") and name.endswith(pattern[1:]):
            return True
        if pattern in name:
            return True
    return False


def create_backup_archive(
    source_dir: Path,
    backup_root: Path,
    exclude_patterns,
    logger: logging.Logger,
) -> Path:
    """
    Create a compressed tar.gz archive of the source directory.

    Steps:
        1. Create a timestamped filename.
        2. Walk the source directory.
        3. Add files to the archive unless excluded.

    Returns:
        Path to the created archive.
    """
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    archive_name = f"backup_{timestamp}.tar.gz"
    archive_path = backup_root / archive_name

    logger.info(f"Creating backup archive: {archive_path}")

    # Ensure backup directory exists
    backup_root.mkdir(parents=True, exist_ok=True)

    # Open tarfile for writing with gzip compression
    with tarfile.open(archive_path, "w:gz") as tar:
        for root, dirs, files in os.walk(source_dir):
            root_path = Path(root)

            # Skip excluded directories
            dirs[:] = [
                d for d in dirs
                if not should_exclude(root_path / d, exclude_patterns)
            ]

            for file in files:
                file_path = root_path / file
                if should_exclude(file_path, exclude_patterns):
                    continue

                # Store relative path inside archive
                arcname = file_path.relative_to(source_dir)
                tar.add(file_path, arcname=arcname)

    logger.info("Backup archive created successfully")
    return archive_path


def compute_sha256(file_path: Path) -> str:
    """
    Compute SHA256 hash of a file.

    Security relevance:
        - Hashes allow us to verify that a backup has not been
          corrupted or tampered with.
    """
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def write_checksum_file(archive_path: Path, logger: logging.Logger) -> Path:
    """
    Generate a .sha256 file next to the archive containing the
    SHA256 checksum.

    Example:
        backup_20260101_010101.tar.gz
        backup_20260101_010101.tar.gz.sha256
    """
    checksum = compute_sha256(archive_path)
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    checksum_path.write_text(f"{checksum}  {archive_path.name}\n")
    logger.info(f"Checksum written to {checksum_path}")
    return checksum_path


def verify_checksum(archive_path: Path, checksum_path: Path, logger: logging.Logger) -> bool:
    """
    Verify that the archive's current SHA256 matches the stored checksum.

    This demonstrates integrity verification, which is a core
    security concept.
    """
    if not checksum_path.exists():
        logger.warning("Checksum file not found; skipping verification")
        return False

    # Read expected checksum from file
    content = checksum_path.read_text().strip()
    if "  " in content:
        expected, _ = content.split("  ", 1)
    else:
        expected = content

    actual = compute_sha256(archive_path)

    if actual == expected:
        logger.info("Checksum verification succeeded")
        return True
    else:
        logger.error("Checksum verification FAILED")
        return False


def apply_retention_policy(backup_root: Path, max_backups: int, logger: logging.Logger):
    """
    Keep only the newest `max_backups` archives and delete older ones.

    This prevents unbounded growth of backup storage and demonstrates
    automated lifecycle management.
    """
    archives = sorted(
        backup_root.glob("backup_*.tar.gz"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if len(archives) <= max_backups:
        logger.info("Retention policy: nothing to delete")
        return

    to_delete = archives[max_backups:]
    for old in to_delete:
        logger.info(f"Retention policy: deleting old backup {old.name}")
        # Also delete checksum file if present
        checksum = old.with_suffix(old.suffix + ".sha256")
        if checksum.exists():
            checksum.unlink()
        old.unlink()


# -----------------------------
# Main backup flow
# -----------------------------

def run_backup(project_root: Path, config: dict, logger: logging.Logger):
    """
    Orchestrate the full backup process:

        1. Create archive
        2. Generate checksum (optional)
        3. Verify checksum (optional)
        4. Apply retention policy

    This function is the "automation glue" that ties together
    all the smaller building blocks.
    """
    backup_root = project_root / config["backup_dir"]

    # 1. Create archive
    archive_path = create_backup_archive(
        source_dir=project_root,
        backup_root=backup_root,
        exclude_patterns=config["exclude_patterns"],
        logger=logger,
    )

    # 2. Generate checksum
    if config.get("enable_checksums", True):
        checksum_path = write_checksum_file(archive_path, logger)

        # 3. Verify checksum immediately (optional but nice for demo)
        verify_checksum(archive_path, checksum_path, logger)

    # 4. Apply retention policy
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
    """
    Define command-line interface.

    For the class project, we keep it simple:
        - No subcommands
        - Just a 'backup now' action and a 'show config' option
    """
    parser = argparse.ArgumentParser(
        description="Security-Automation Backup Script (Simplified)"
    )
    parser.add_argument(
        "--project-root",
        type=str,
        default=".",
        help="Path to the project directory to back up (default: current directory)",
    )
    parser.add_argument(
        "--show-config",
        action="store_true",
        help="Print the effective configuration and exit",
    )
    return parser.parse_args()


def main():
    # Resolve paths relative to this script
    script_dir = Path(__file__).parent.resolve()
    args = parse_args()

    project_root = (script_dir / args.project_root).resolve()
    config_path = script_dir / "backup-config.json"
    backup_root = project_root / DEFAULT_CONFIG["backup_dir"]
    log_path = backup_root / "backup.log"

    # Ensure backup directory exists before logging
    backup_root.mkdir(parents=True, exist_ok=True)

    logger = setup_logger(log_path)
    config = load_config(config_path)

    if args.show_config:
        logger.info("Effective configuration:")
        logger.info(json.dumps(config, indent=2))
        sys.exit(0)

    logger.info(f"Starting backup for project: {project_root}")
    run_backup(project_root, config, logger)


if __name__ == "__main__":
    main()

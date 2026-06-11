#!/usr/bin/env python3
"""
Security-Automation Repository Automated Backup Script
Purpose: Create complete backups with scheduling, notification, and automation
Features: Cron scheduling, email alerts, cloud sync, retention policies
"""

import os
import sys
import json
import shutil
import tarfile
import hashlib
import subprocess
import threading
import argparse
import smtplib
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import requests


class BackupConfig:
    """Configuration management for backup operations"""
    
    DEFAULT_CONFIG = {
        'backup_enabled': True,
        'backup_compression': True,
        'backup_verify': True,
        'max_backup_retention': 10,
        'max_backup_age_days': 30,
        'enable_email_notifications': False,
        'smtp_server': 'localhost',
        'smtp_port': 25,
        'email_from': 'backup@localhost',
        'email_to': 'admin@example.com',
        'notify_on_success': True,
        'notify_on_failure': True,
        'enable_cloud_sync': False,
        'cloud_provider': 'aws',
        'aws_s3_bucket': '',
        'aws_region': 'us-east-1',
        'schedule_enabled': True,
        'cron_schedule': '0 2 * * *',
        'enable_slack': False,
        'slack_webhook_url': '',
        'slack_channel': '#backups',
        'backup_git_bundle': True,
        'backup_git_log': True,
        'backup_remote_tracking': True,
        'exclude_patterns': [
            '.git', '.backups', '.pytest_cache', '__pycache__',
            '*.pyc', '.venv', 'venv', '.env', 'node_modules', '.DS_Store'
        ],
        'enable_audit_log': True,
    }
    
    def __init__(self, config_file: Path):
        self.config_file = config_file
        self.config = self.DEFAULT_CONFIG.copy()
        self.load()
    
    def load(self):
        """Load configuration from file"""
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    loaded = json.load(f)
                    self.config.update(loaded)
                    logger.info(f"Configuration loaded from {self.config_file}")
            except Exception as e:
                logger.warning(f"Failed to load config: {e}. Using defaults.")
        else:
            self.save()
            logger.warning(f"Default configuration created: {self.config_file}")
    
    def save(self):
        """Save configuration to file"""
        self.config_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.config_file, 'w') as f:
            json.dump(self.config, f, indent=2)
    
    def get(self, key: str, default=None):
        """Get config value"""
        return self.config.get(key, default)
    
    def __getitem__(self, key):
        return self.config[key]


class BackupLogger:
    """Logging management"""
    
    def __init__(self, log_file: Path):
        self.log_file = log_file
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Configure logging
        self.logger = logging.getLogger('backup')
        self.logger.setLevel(logging.DEBUG)
        
        # File handler
        fh = logging.FileHandler(log_file)
        fh.setLevel(logging.DEBUG)
        
        # Console handler
        ch = logging.StreamHandler()
        ch.setLevel(logging.INFO)
        
        # Formatter
        formatter = logging.Formatter('[%(asctime)s] %(levelname)s: %(message)s')
        fh.setFormatter(formatter)
        ch.setFormatter(formatter)
        
        self.logger.addHandler(fh)
        self.logger.addHandler(ch)
    
    def info(self, msg):
        self.logger.info(f"\033[34m[INFO]\033[0m {msg}")
    
    def success(self, msg):
        self.logger.info(f"\033[32m[SUCCESS]\033[0m {msg}")
    
    def warning(self, msg):
        self.logger.warning(f"\033[33m[WARNING]\033[0m {msg}")
    
    def error(self, msg):
        self.logger.error(f"\033[31m[ERROR]\033[0m {msg}")


class BackupManager:
    """Main backup operations manager"""
    
    def __init__(self, repo_root: Path, backup_base_dir: Path, config: BackupConfig):
        self.repo_root = repo_root
        self.backup_base_dir = backup_base_dir
        self.state_dir = backup_base_dir / '.state'
        self.lock_file = self.state_dir / 'backup.lock'
        self.config = config
        self.timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        self.backup_dir = backup_base_dir / f'backup_{self.timestamp}'
        self.log_file = self.backup_dir / 'backup.log'
    
    def acquire_lock(self) -> bool:
        """Acquire process lock"""
        self.state_dir.mkdir(parents=True, exist_ok=True)
        
        if self.lock_file.exists():
            try:
                with open(self.lock_file, 'r') as f:
                    pid = int(f.read().strip())
                    if os.path.exists(f'/proc/{pid}'):
                        logger.error(f"Backup already running (PID: {pid})")
                        return False
            except (ValueError, IOError):
                pass
        
        with open(self.lock_file, 'w') as f:
            f.write(str(os.getpid()))
        
        logger.info(f"Lock acquired (PID: {os.getpid()})")
        return True
    
    def release_lock(self):
        """Release process lock"""
        if self.lock_file.exists():
            self.lock_file.unlink()
        logger.info("Lock released")
    
    def initialize(self):
        """Initialize backup environment"""
        logger.info("Initializing backup process...")
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        (self.backup_dir / 'repository').mkdir(exist_ok=True)
        (self.backup_dir / 'metadata').mkdir(exist_ok=True)
        (self.backup_dir / 'configs').mkdir(exist_ok=True)
        logger.success(f"Backup directory created: {self.backup_dir}")
    
    def backup_repository(self) -> bool:
        """Backup repository files"""
        logger.info("Backing up repository files...")
        
        try:
            archive_path = self.backup_dir / 'repository' / f'repo_files_{self.timestamp}.tar.gz'
            
            with tarfile.open(archive_path, 'w:gz') as tar:
                for item in self.repo_root.iterdir():
                    # Skip excluded patterns
                    if any(pattern in str(item) for pattern in self.config['exclude_patterns']):
                        continue
                    tar.add(item, arcname=item.name)
            
            size = self._format_size(archive_path.stat().st_size)
            logger.success(f"Repository files backed up: {size}")
            return True
        
        except Exception as e:
            logger.error(f"Failed to backup repository: {e}")
            return False
    
    def backup_git_metadata(self) -> bool:
        """Backup git metadata"""
        logger.info("Backing up git metadata...")
        
        if not (self.repo_root / '.git').exists():
            logger.warning("Git repository not found")
            return True
        
        try:
            metadata_dir = self.backup_dir / 'metadata'
            os.chdir(self.repo_root)
            
            if self.config['backup_git_bundle']:
                subprocess.run(
                    ['git', 'bundle', 'create', str(metadata_dir / 'repo.bundle'), '--all'],
                    capture_output=True, check=False
                )
            
            if self.config['backup_git_log']:
                result = subprocess.run(
                    ['git', 'log', '--oneline'],
                    capture_output=True, text=True, check=False
                )
                (metadata_dir / 'git_log.txt').write_text(result.stdout)
                
                result = subprocess.run(
                    ['git', 'log', '--graph', '--oneline', '--all'],
                    capture_output=True, text=True, check=False
                )
                (metadata_dir / 'git_log_graph.txt').write_text(result.stdout)
            
            subprocess.run(
                ['git', 'branch', '-a'],
                capture_output=True, stdout=open(metadata_dir / 'branches.txt', 'w'), check=False
            )
            
            subprocess.run(
                ['git', 'tag', '-l'],
                capture_output=True, stdout=open(metadata_dir / 'tags.txt', 'w'), check=False
            )
            
            subprocess.run(
                ['git', 'remote', '-v'],
                capture_output=True, stdout=open(metadata_dir / 'remotes.txt', 'w'), check=False
            )
            
            subprocess.run(
                ['git', 'status'],
                capture_output=True, stdout=open(metadata_dir / 'git_status.txt', 'w'), check=False
            )
            
            logger.success("Git metadata backed up")
            return True
        
        except Exception as e:
            logger.error(f"Failed to backup git metadata: {e}")
            return False
    
    def backup_configurations(self) -> bool:
        """Backup configuration files"""
        logger.info("Backing up configuration files...")
        
        config_files = [
            '.gitignore', '.github', '.gitattributes', 'setup.py', 'setup.cfg',
            'pyproject.toml', 'requirements.txt', 'requirements-dev.txt', '.backup-config'
        ]
        
        try:
            configs_dir = self.backup_dir / 'configs'
            
            for config_file in config_files:
                src = self.repo_root / config_file
                if src.exists():
                    if src.is_dir():
                        shutil.copytree(src, configs_dir / config_file, dirs_exist_ok=True)
                    else:
                        shutil.copy2(src, configs_dir / config_file)
            
            logger.success("Configuration files backed up")
            return True
        
        except Exception as e:
            logger.error(f"Failed to backup configurations: {e}")
            return False
    
    def create_manifest(self) -> bool:
        """Create backup manifest"""
        logger.info("Creating backup manifest...")
        
        try:
            manifest = self.backup_dir / 'MANIFEST.md'
            
            content = f"""# Security-Automation Backup Manifest

## Backup Information
- **Created**: {datetime.now()}
- **Repository**: https://github.com/Emuini005/Security-Automation
- **Backup Version**: 2.0 (Automated - Python)
- **Backup ID**: {self.timestamp}

## Directory Structure

### /repository
- `repo_files_*.tar.gz` - Complete repository files

### /metadata
- `repo.bundle` - Git bundle with complete history
- `git_log.txt` - Git commit log
- `git_log_graph.txt` - Git tree visualization
- `branches.txt` - All branches
- `tags.txt` - All tags
- `remotes.txt` - Remote repositories
- `git_status.txt` - Status at backup time

### /configs
- Configuration files and package manifests

## Backup Statistics
- **Total Size**: {self._format_size(self._get_dir_size(self.backup_dir))}
- **Files Count**: {sum(1 for _ in self.backup_dir.rglob('*') if _.is_file())}
- **Compressed**: Yes
"""
            manifest.write_text(content)
            logger.success("Backup manifest created")
            return True
        
        except Exception as e:
            logger.error(f"Failed to create manifest: {e}")
            return False
    
    def create_checksums(self) -> bool:
        """Create SHA256 checksums"""
        logger.info("Creating backup checksums...")
        
        try:
            checksums = {}
            
            for file in self.backup_dir.rglob('*'):
                if file.is_file() and not file.name == 'checksums.json':
                    try:
                        with open(file, 'rb') as f:
                            file_hash = hashlib.sha256(f.read()).hexdigest()
                            checksums[str(file.relative_to(self.backup_dir))] = file_hash
                    except Exception as e:
                        logger.warning(f"Could not hash {file}: {e}")
            
            checksum_file = self.backup_dir / 'checksums.json'
            with open(checksum_file, 'w') as f:
                json.dump(checksums, f, indent=2)
            
            logger.success("Checksums created")
            return True
        
        except Exception as e:
            logger.error(f"Failed to create checksums: {e}")
            return False
    
    def verify_backup(self) -> bool:
        """Verify backup integrity"""
        logger.info("Verifying backup integrity...")
        
        try:
            checksum_file = self.backup_dir / 'checksums.json'
            
            if not checksum_file.exists():
                logger.warning("Checksum file not found")
                return True
            
            with open(checksum_file, 'r') as f:
                checksums = json.load(f)
            
            all_valid = True
            for file_path, expected_hash in checksums.items():
                full_path = self.backup_dir / file_path
                
                if not full_path.exists():
                    logger.error(f"File missing: {file_path}")
                    all_valid = False
                    continue
                
                with open(full_path, 'rb') as f:
                    actual_hash = hashlib.sha256(f.read()).hexdigest()
                    
                    if actual_hash != expected_hash:
                        logger.error(f"Hash mismatch: {file_path}")
                        all_valid = False
            
            if all_valid:
                logger.success("Backup integrity verified successfully")
            else:
                logger.error("Backup integrity verification failed")
            
            return all_valid
        
        except Exception as e:
            logger.error(f"Verification error: {e}")
            return False
    
    def compress_backup(self) -> bool:
        """Compress backup directory"""
        if not self.config['backup_compression']:
            return True
        
        logger.info("Compressing backup...")
        
        try:
            archive_path = self.backup_base_dir / f'Security-Automation_backup_{self.timestamp}.tar.gz'
            
            with tarfile.open(archive_path, 'w:gz') as tar:
                tar.add(self.backup_dir, arcname=self.backup_dir.name)
            
            size = self._format_size(archive_path.stat().st_size)
            logger.success(f"Backup compressed: {archive_path.name} ({size})")
            return True
        
        except Exception as e:
            logger.error(f"Failed to compress backup: {e}")
            return False
    
    def cleanup_old_backups(self):
        """Clean up old backups based on retention policy"""
        logger.info("Managing backup retention...")
        
        # Remove backups older than max age
        max_age_days = self.config['max_backup_age_days']
        if max_age_days > 0:
            cutoff = datetime.now() - timedelta(days=max_age_days)
            
            for backup_dir in self.backup_base_dir.glob('backup_*'):
                if backup_dir.is_dir():
                    mtime = datetime.fromtimestamp(backup_dir.stat().st_mtime)
                    if mtime < cutoff:
                        logger.warning(f"Removing expired backup: {backup_dir.name}")
                        shutil.rmtree(backup_dir, ignore_errors=True)
        
        # Keep only max retention backups
        max_retention = self.config['max_backup_retention']
        backups = sorted(
            self.backup_base_dir.glob('backup_*'),
            key=lambda x: x.stat().st_mtime,
            reverse=True
        )
        
        if len(backups) > max_retention:
            for backup_dir in backups[max_retention:]:
                logger.warning(f"Removing old backup (retention): {backup_dir.name}")
                shutil.rmtree(backup_dir, ignore_errors=True)
        
        logger.success("Backup retention policy applied")
    
    def send_email_notification(self, subject: str, message: str, status: str):
        """Send email notification"""
        if not self.config['enable_email_notifications']:
            return
        
        try:
            logger.info("Sending email notification...")
            
            msg = MIMEMultipart()
            msg['Subject'] = subject
            msg['From'] = self.config['email_from']
            msg['To'] = self.config['email_to']
            
            body = f"""{message}

Backup Directory: {self.backup_dir}
Timestamp: {datetime.now()}
Status: {status}"""
            
            msg.attach(MIMEText(body, 'plain'))
            
            with smtplib.SMTP(self.config['smtp_server'], self.config['smtp_port']) as server:
                server.sendmail(
                    self.config['email_from'],
                    [self.config['email_to']],
                    msg.as_string()
                )
        
        except Exception as e:
            logger.warning(f"Failed to send email: {e}")
    
    def send_slack_notification(self, message: str, status: str):
        """Send Slack notification"""
        if not self.config['enable_slack'] or not self.config['slack_webhook_url']:
            return
        
        try:
            logger.info("Sending Slack notification...")
            
            color = "good" if status == "SUCCESS" else "danger"
            
            payload = {
                "channel": self.config['slack_channel'],
                "username": "Backup Bot",
                "attachments": [{
                    "color": color,
                    "title": f"Security-Automation Backup {status}",
                    "text": message,
                    "fields": [
                        {
                            "title": "Backup ID",
                            "value": self.timestamp,
                            "short": True
                        },
                        {
                            "title": "Size",
                            "value": self._format_size(self._get_dir_size(self.backup_dir)),
                            "short": True
                        }
                    ],
                    "ts": int(datetime.now().timestamp())
                }]
            }
            
            requests.post(
                self.config['slack_webhook_url'],
                json=payload,
                timeout=10
            )
        
        except Exception as e:
            logger.warning(f"Failed to send Slack notification: {e}")
    
    def run_backup(self) -> bool:
        """Execute full backup process"""
        logger.info("="*42)
        logger.info("Security-Automation Backup Process Started")
        logger.info("="*42)
        
        success = True
        
        try:
            self.initialize()
            success &= self.backup_repository()
            success &= self.backup_git_metadata()
            success &= self.backup_configurations()
            success &= self.create_manifest()
            success &= self.create_checksums()
            
            if self.config['backup_verify']:
                success &= self.verify_backup()
            
            self.compress_backup()
            self.cleanup_old_backups()
            
            status = "SUCCESS" if success else "FAILURE"
            message = f"Backup completed {'successfully' if success else 'with errors'}. Backup ID: {self.timestamp}"
            
            if self.config['notify_on_success'] and status == "SUCCESS":
                self.send_email_notification("Backup Success", message, status)
                self.send_slack_notification(message, status)
            
            if self.config['notify_on_failure'] and status == "FAILURE":
                self.send_email_notification("Backup Failed", message, status)
                self.send_slack_notification(message, status)
            
            logger.info("="*42)
            logger.success(f"Backup process completed: {status}")
            logger.info("="*42)
            logger.info(f"Backup location: {self.backup_dir}")
            
            return success
        
        except Exception as e:
            logger.error(f"Backup process error: {e}")
            return False
    
    @staticmethod
    def _format_size(size_bytes: int) -> str:
        """Format bytes to human readable size"""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size_bytes < 1024:
                return f"{size_bytes:.1f}{unit}"
            size_bytes /= 1024
        return f"{size_bytes:.1f}TB"
    
    @staticmethod
    def _get_dir_size(path: Path) -> int:
        """Get directory size in bytes"""
        total = 0
        for file in path.rglob('*'):
            if file.is_file():
                total += file.stat().st_size
        return total


def setup_cron_schedule(config: BackupConfig, script_path: Path):
    """Setup cron scheduling"""
    if not config['schedule_enabled']:
        logger.info("Cron scheduling disabled")
        return
    
    logger.info("Setting up cron schedule...")
    
    cron_cmd = f"{script_path} --run-backup"
    cron_entry = f"{config['cron_schedule']} cd {script_path.parent} && {sys.executable} {script_path} --run-backup >> {script_path.parent / '.backups' / '.state' / 'cron.log'} 2>&1"
    
    try:
        result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
        current_crontab = result.stdout
        
        if cron_cmd in current_crontab:
            logger.warning("Cron job already exists")
            return
        
        new_crontab = current_crontab + f"\n{cron_entry}\n"
        
        process = subprocess.Popen(['crontab', '-'], stdin=subprocess.PIPE, text=True)
        process.communicate(input=new_crontab)
        
        logger.success(f"Cron schedule configured: {config['cron_schedule']}")
    
    except Exception as e:
        logger.warning(f"Could not add cron job: {e}")


def remove_cron_schedule(script_path: Path):
    """Remove cron scheduling"""
    logger.info("Removing cron schedule...")
    
    try:
        result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
        current_crontab = result.stdout
        
        new_crontab = '\n'.join(
            line for line in current_crontab.split('\n')
            if str(script_path) not in line
        )
        
        process = subprocess.Popen(['crontab', '-'], stdin=subprocess.PIPE, text=True)
        process.communicate(input=new_crontab)
        
        logger.success("Cron schedule removed")
    
    except Exception as e:
        logger.warning(f"Could not remove cron job: {e}")


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='Security-Automation Automated Backup Script'
    )
    parser.add_argument('--run-backup', action='store_true', help='Run backup immediately')
    parser.add_argument('--setup-schedule', action='store_true', help='Setup cron scheduling')
    parser.add_argument('--remove-schedule', action='store_true', help='Remove cron scheduling')
    parser.add_argument('--status', action='store_true', help='Show backup status')
    parser.add_argument('--list', action='store_true', help='List all backups')
    parser.add_argument('--clean', action='store_true', help='Clean old backups')
    parser.add_argument('--configure', action='store_true', help='Edit configuration')
    
    args = parser.parse_args()
    
    # Setup paths
    script_dir = Path(__file__).parent.absolute()
    backup_base_dir = script_dir / '.backups'
    config_file = script_dir / '.backup-config'
    
    # Setup global logger
    global logger
    logger = BackupLogger(script_dir / 'backup_temp.log')
    
    # Load configuration
    config = BackupConfig(config_file)
    
    if args.run_backup:
        manager = BackupManager(script_dir, backup_base_dir, config)
        try:
            if not manager.acquire_lock():
                sys.exit(1)
            manager.run_backup()
        finally:
            manager.release_lock()
    
    elif args.setup_schedule:
        setup_cron_schedule(config, Path(__file__).absolute())
    
    elif args.remove_schedule:
        remove_cron_schedule(Path(__file__).absolute())
    
    elif args.status:
        logger.info("Backup Status:")
        backup_dirs = sorted(backup_base_dir.glob('backup_*'), key=lambda x: x.stat().st_mtime, reverse=True)
        if backup_dirs:
            latest = backup_dirs[0]
            logger.info(f"Last backup: {latest.name}")
        logger.info(f"Total backups: {len(backup_dirs)}")
    
    elif args.list:
        backup_dirs = sorted(backup_base_dir.glob('backup_*'), key=lambda x: x.stat().st_mtime, reverse=True)
        for backup_dir in backup_dirs:
            size = BackupManager._format_size(BackupManager._get_dir_size(backup_dir))
            logger.info(f"{backup_dir.name} - {size}")
    
    elif args.clean:
        manager = BackupManager(script_dir, backup_base_dir, config)
        manager.cleanup_old_backups()
    
    elif args.configure:
        logger.info(f"Edit configuration: {config_file}")
        subprocess.run([os.environ.get('EDITOR', 'nano'), str(config_file)])
    
    else:
        parser.print_help()


if __name__ == '__main__':
    main()

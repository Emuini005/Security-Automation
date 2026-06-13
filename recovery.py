#!/usr/bin/env python3
"""
Security-Automation Repository Automated Recovery Script
Version: 2.0
Purpose: Restore repository from backups with safety checks and automation
Features: Selective restore, rollback, versioning, scheduling
"""

import os
import sys
import json
import shutil
import tarfile
import hashlib
import subprocess
import argparse
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional, List
import requests

__version__ = "2.0.0"
__author__ = "Security-Automation Team"
__license__ = "MIT"


class RecoveryConfig:
    """Configuration management for recovery operations"""
    
    DEFAULT_CONFIG = {
        'auto_restore_enabled': False,
        'restore_verify_before': True,
        'restore_backup_current': True,
        'enable_rollback': True,
        'rollback_on_failure': True,
        'rollback_backup_dir': '',
        'enable_email_notifications': False,
        'email_from': 'recovery@localhost',
        'email_to': 'admin@example.com',
        'enable_slack': False,
        'slack_webhook_url': '',
        'slack_channel': '#recovery',
        'schedule_enabled': False,
        'cron_schedule': '0 3 * * 0',
        'enable_audit': True,
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
        return self.config.get(key, default)
    
    def __getitem__(self, key):
        return self.config[key]


class BackupVersionInfo:
    """Read version information from backup"""
    
    @staticmethod
    def get_version_info(backup_dir: Path) -> Optional[dict]:
        """Extract version information from backup manifest"""
        manifest = backup_dir / 'MANIFEST.md'
        if not manifest.exists():
            return None
        
        try:
            content = manifest.read_text()
            info = {}
            for line in content.split('\n'):
                if '**' in line and ':' in line:
                    parts = line.split(':', 1)
                    if len(parts) == 2:
                        key = parts[0].replace('**', '').replace('-', '').strip().lower()
                        value = parts[1].strip()
                        info[key] = value
            return info if info else None
        except:
            return None


class RecoveryLogger:
    """Logging management"""
    
    def __init__(self, log_file: Path):
        self.log_file = log_file
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        
        self.logger = logging.getLogger('recovery')
        self.logger.setLevel(logging.DEBUG)
        
        # Clear existing handlers
        self.logger.handlers = []
        
        fh = logging.FileHandler(log_file)
        fh.setLevel(logging.DEBUG)
        
        ch = logging.StreamHandler()
        ch.setLevel(logging.INFO)
        
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


class RecoveryManager:
    """Main recovery operations manager"""
    
    def __init__(self, backup_base_dir: Path, config: RecoveryConfig):
        self.backup_base_dir = backup_base_dir
        self.state_dir = backup_base_dir / '.state'
        self.lock_file = self.state_dir / 'recovery.lock'
        self.config = config
        self.timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        self.recovery_log = self.state_dir / f'recovery_{self.timestamp}.log'
        self.rollback_dir = None
    
    def acquire_lock(self) -> bool:
        """Acquire process lock"""
        self.state_dir.mkdir(parents=True, exist_ok=True)
        
        if self.lock_file.exists():
            try:
                with open(self.lock_file, 'r') as f:
                    pid = int(f.read().strip())
                    if os.path.exists(f'/proc/{pid}'):
                        logger.error(f"Recovery already running (PID: {pid})")
                        return False
            except (ValueError, IOError):
                pass
        
        with open(self.lock_file, 'w') as f:
            f.write(str(os.getpid()))
        
        return True
    
    def release_lock(self):
        """Release process lock"""
        if self.lock_file.exists():
            self.lock_file.unlink()
    
    def list_backups(self) -> List[Path]:
        """List available backups with version info"""
        logger.info(f"Available backups (Recovery v{__version__}):")
        
        if not self.backup_base_dir.exists():
            logger.error(f"Backup directory not found: {self.backup_base_dir}")
            return []
        
        backups = sorted(
            self.backup_base_dir.glob('backup_*'),
            key=lambda x: x.stat().st_mtime,
            reverse=True
        )
        
        if not backups:
            logger.error("No backups found")
            return []
        
        print("")
        for i, backup_dir in enumerate(backups, 1):
            size = self._format_size(self._get_dir_size(backup_dir))
            mtime = datetime.fromtimestamp(backup_dir.stat().st_mtime).strftime('%Y-%m-%d %H:%M:%S')
            version_info = BackupVersionInfo.get_version_info(backup_dir)
            
            print(f"\033[34m[{i}]\033[0m {backup_dir.name}")
            print(f"    Size: {size}")
            print(f"    Date: {mtime}")
            
            if version_info:
                print(f"    Script Version: {version_info.get('script version', 'N/A')}")
                print(f"    Git Branch: {version_info.get('git branch', 'N/A')}")
                print(f"    Git Commit: {version_info.get('git commit', 'N/A')[:8]}...")
            
            if (backup_dir / 'MANIFEST.md').exists():
                print(f"    ✓ Manifest")
            if list(backup_dir.glob('repository/repo_files_*.tar.gz')):
                print(f"    ✓ Repository Files")
            if (backup_dir / 'metadata' / 'repo.bundle').exists():
                print(f"    ✓ Git Bundle")
            print("")
        
        return backups
    
    def find_backup(self, backup_id: Optional[str] = None) -> Optional[Path]:
        """Find backup directory"""
        if not backup_id:
            backups = sorted(
                self.backup_base_dir.glob('backup_*'),
                key=lambda x: x.stat().st_mtime,
                reverse=True
            )
            
            if not backups:
                logger.error("No backups found")
                return None
            
            return backups[0]
        
        backup_dir = self.backup_base_dir / backup_id
        if not backup_dir.exists():
            logger.error(f"Backup not found: {backup_dir}")
            return None
        
        return backup_dir
    
    def verify_backup(self, backup_dir: Path) -> bool:
        """Verify backup integrity"""
        logger.info("Verifying backup integrity...")
        
        try:
            checksum_file = backup_dir / 'checksums.json'
            
            if not checksum_file.exists():
                logger.warning("Checksum file not found")
                return True
            
            with open(checksum_file, 'r') as f:
                checksums = json.load(f)
            
            all_valid = True
            for file_path, expected_hash in checksums.items():
                full_path = backup_dir / file_path
                
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
                logger.success("Backup integrity verified")
            else:
                logger.error("Backup integrity check failed")
            
            return all_valid
        
        except Exception as e:
            logger.error(f"Verification error: {e}")
            return False
    
    def backup_current_state(self, restore_dir: Path):
        """Backup current state before restore"""
        if not self.config['restore_backup_current']:
            return
        
        logger.info("Backing up current state before restore...")
        
        if not restore_dir.exists() or not any(restore_dir.iterdir()):
            logger.info("No existing files to backup")
            return
        
        self.rollback_dir = self.backup_base_dir / f'pre_restore_{self.timestamp}'
        self.rollback_dir.mkdir(parents=True, exist_ok=True)
        
        for item in restore_dir.iterdir():
            if item.is_dir():
                shutil.copytree(item, self.rollback_dir / item.name, dirs_exist_ok=True)
            else:
                shutil.copy2(item, self.rollback_dir)
        
        logger.success("Current state backed up")
    
    def rollback_recovery(self, restore_dir: Path):
        """Rollback recovery on failure"""
        if not self.config['rollback_on_failure'] or not self.rollback_dir:
            return
        
        logger.warning("Rolling back recovery...")
        
        if not self.rollback_dir.exists():
            logger.error("Rollback backup not found")
            return
        
        # Clear restore directory
        for item in restore_dir.iterdir():
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
            else:
                item.unlink()
        
        # Restore from rollback
        for item in self.rollback_dir.iterdir():
            if item.is_dir():
                shutil.copytree(item, restore_dir / item.name, dirs_exist_ok=True)
            else:
                shutil.copy2(item, restore_dir)
        
        logger.success("Rollback completed")
    
    def restore_repository(self, backup_dir: Path, restore_dir: Path) -> bool:
        """Restore repository files"""
        logger.info("Restoring repository files...")
        
        try:
            archives = list(backup_dir.glob('repository/repo_files_*.tar.gz'))
            if not archives:
                logger.error("Repository archive not found")
                return False
            
            restore_dir.mkdir(parents=True, exist_ok=True)
            self.backup_current_state(restore_dir)
            
            logger.info("Extracting files...")
            with tarfile.open(archives[0], 'r:gz') as tar:
                tar.extractall(restore_dir)
            
            logger.success("Repository files restored")
            return True
        
        except Exception as e:
            logger.error(f"Failed to restore repository: {e}")
            return False
    
    def restore_git(self, backup_dir: Path, restore_dir: Path) -> bool:
        """Restore git history"""
        logger.info("Restoring git history...")
        
        try:
            git_bundle = backup_dir / 'metadata' / 'repo.bundle'
            
            if not git_bundle.exists():
                logger.error("Git bundle not found")
                return False
            
            restore_dir.mkdir(parents=True, exist_ok=True)
            
            if (restore_dir / '.git').exists():
                logger.info("Git repository exists, fetching from bundle...")
                os.chdir(restore_dir)
                subprocess.run(
                    ['git', 'fetch', str(git_bundle), '*:*'],
                    capture_output=True, check=False
                )
            else:
                logger.info("Creating new git repository from bundle...")
                subprocess.run(
                    ['git', 'clone', str(git_bundle), str(restore_dir)],
                    capture_output=True, check=False
                )
            
            logger.success("Git history restored")
            return True
        
        except Exception as e:
            logger.error(f"Failed to restore git: {e}")
            return False
    
    def restore_configs(self, backup_dir: Path, restore_dir: Path) -> bool:
        """Restore configuration files"""
        logger.info("Restoring configuration files...")
        
        try:
            configs_dir = backup_dir / 'configs'
            
            if not configs_dir.exists():
                logger.warning("Config directory not found in backup")
                return True
            
            restore_dir.mkdir(parents=True, exist_ok=True)
            
            for item in configs_dir.iterdir():
                if item.is_dir():
                    shutil.copytree(item, restore_dir / item.name, dirs_exist_ok=True)
                else:
                    shutil.copy2(item, restore_dir)
            
            logger.success("Configuration files restored")
            return True
        
        except Exception as e:
            logger.error(f"Failed to restore configs: {e}")
            return False
    
    def restore_all(self, backup_dir: Path, restore_dir: Path = None) -> bool:
        """Restore all from backup"""
        if restore_dir is None:
            restore_dir = Path.cwd()
        
        version_info = BackupVersionInfo.get_version_info(backup_dir)
        
        logger.info("="*42)
        logger.info(f"Recovery v{__version__}")
        logger.info("="*42)
        logger.info(f"Backup: {backup_dir.name}")
        if version_info:
            logger.info(f"Backup Script Version: {version_info.get('script version', 'N/A')}")
        logger.info(f"Restore to: {restore_dir}")
        print("")
        
        success = True
        
        if self.config['restore_verify_before']:
            if not self.verify_backup(backup_dir):
                logger.warning("Continuing anyway...")
        
        print("")
        if not self.restore_repository(backup_dir, restore_dir):
            success = False
        
        print("")
        if not self.restore_git(backup_dir, restore_dir):
            success = False
        
        print("")
        if not self.restore_configs(backup_dir, restore_dir):
            success = False
        
        print("")
        
        if not success:
            self.rollback_recovery(restore_dir)
        
        logger.info("="*42)
        logger.success("Restoration completed")
        logger.info("="*42)
        
        return success
    
    def setup_cron_schedule(self, script_path: Path):
        """Setup cron scheduling"""
        if not self.config['schedule_enabled']:
            logger.info("Scheduling disabled")
            return
        
        logger.info("Setting up recovery schedule...")
        
        cron_cmd = f"{script_path} --auto-restore"
        cron_entry = f"{self.config['cron_schedule']} cd {script_path.parent} && {sys.executable} {script_path} --auto-restore >> {self.state_dir / 'cron.log'} 2>&1"
        
        try:
            result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
            current_crontab = result.stdout
            
            if cron_cmd in current_crontab:
                logger.warning("Cron job already exists")
                return
            
            new_crontab = current_crontab + f"\n{cron_entry}\n"
            
            process = subprocess.Popen(['crontab', '-'], stdin=subprocess.PIPE, text=True)
            process.communicate(input=new_crontab)
            
            logger.success("Recovery schedule configured")
        
        except Exception as e:
            logger.warning(f"Could not add cron job: {e}")
    
    def remove_cron_schedule(self, script_path: Path):
        """Remove cron scheduling"""
        logger.info("Removing recovery schedule...")
        
        try:
            result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
            current_crontab = result.stdout
            
            new_crontab = '\n'.join(
                line for line in current_crontab.split('\n')
                if str(script_path) not in line
            )
            
            process = subprocess.Popen(['crontab', '-'], stdin=subprocess.PIPE, text=True)
            process.communicate(input=new_crontab)
            
            logger.success("Schedule removed")
        
        except Exception as e:
            logger.warning(f"Could not remove cron job: {e}")
    
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


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='Security-Automation Automated Recovery Script'
    )
    parser.add_argument('--list', action='store_true', help='List available backups')
    parser.add_argument('--restore-all', nargs='?', const=None, help='Restore all from backup')
    parser.add_argument('--restore-repository', nargs='?', const=None, help='Restore repository files')
    parser.add_argument('--restore-git', nargs='?', const=None, help='Restore git history')
    parser.add_argument('--restore-configs', nargs='?', const=None, help='Restore configurations')
    parser.add_argument('--verify-backup', nargs='?', const=None, help='Verify backup integrity')
    parser.add_argument('--auto-restore', action='store_true', help='Automatic restore')
    parser.add_argument('--setup-schedule', action='store_true', help='Setup cron scheduling')
    parser.add_argument('--remove-schedule', action='store_true', help='Remove cron scheduling')
    parser.add_argument('--configure', action='store_true', help='Edit configuration')
    parser.add_argument('--restore-dir', default='.', help='Directory to restore to')
    parser.add_argument('--version', action='version', version=f'%(prog)s {__version__}')
    
    args = parser.parse_args()
    
    # Setup paths
    script_dir = Path(__file__).parent.absolute()
    backup_base_dir = script_dir / '.backups'
    config_file = script_dir / '.recovery-config'
    
    # Setup global logger
    global logger
    log_dir = backup_base_dir / '.state'
    log_dir.mkdir(parents=True, exist_ok=True)
    logger = RecoveryLogger(log_dir / f'recovery_{datetime.now().strftime("%Y%m%d_%H%M%S")}.log')
    
    # Load configuration
    config = RecoveryConfig(config_file)
    
    # Create manager
    manager = RecoveryManager(backup_base_dir, config)
    
    try:
        if args.list:
            manager.list_backups()
        
        elif args.restore_all is not None:
            if not manager.acquire_lock():
                sys.exit(1)
            backup_dir = manager.find_backup(args.restore_all)
            if backup_dir:
                manager.restore_all(backup_dir, Path(args.restore_dir))
        
        elif args.restore_repository is not None:
            if not manager.acquire_lock():
                sys.exit(1)
            backup_dir = manager.find_backup(args.restore_repository)
            if backup_dir:
                manager.restore_repository(backup_dir, Path(args.restore_dir))
        
        elif args.restore_git is not None:
            if not manager.acquire_lock():
                sys.exit(1)
            backup_dir = manager.find_backup(args.restore_git)
            if backup_dir:
                manager.restore_git(backup_dir, Path(args.restore_dir))
        
        elif args.restore_configs is not None:
            if not manager.acquire_lock():
                sys.exit(1)
            backup_dir = manager.find_backup(args.restore_configs)
            if backup_dir:
                manager.restore_configs(backup_dir, Path(args.restore_dir))
        
        elif args.verify_backup is not None:
            backup_dir = manager.find_backup(args.verify_backup)
            if backup_dir:
                manager.verify_backup(backup_dir)
        
        elif args.auto_restore:
            if not manager.acquire_lock():
                sys.exit(1)
            if config['auto_restore_enabled']:
                backup_dir = manager.find_backup()
                if backup_dir:
                    manager.restore_all(backup_dir)
            else:
                logger.warning("Auto-restore disabled")
        
        elif args.setup_schedule:
            manager.setup_cron_schedule(Path(__file__).absolute())
        
        elif args.remove_schedule:
            manager.remove_cron_schedule(Path(__file__).absolute())
        
        elif args.configure:
            logger.info(f"Edit configuration: {config_file}")
            editor = os.environ.get('EDITOR', 'nano')
            subprocess.run([editor, str(config_file)])
        
        else:
            parser.print_help()
    
    finally:
        manager.release_lock()


if __name__ == '__main__':
    main()

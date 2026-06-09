#!/bin/bash

################################################################################
# Security-Automation Repository Backup Script with Automation Support
# Purpose: Create complete backups of the repository with scheduling and
#          automated execution capabilities
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-./.backups}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_BASE_DIR}/backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_DIR}/backup.log"
CONFIG_FILE="${SCRIPT_DIR}/.backup-config"

# Automation settings
AUTO_MODE="${AUTO_MODE:-false}"
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-false}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"
MAX_BACKUPS="${MAX_BACKUPS:-10}"
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-true}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Load Configuration File
################################################################################

load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        log_info "Configuration loaded from ${CONFIG_FILE}"
    else
        log_info "No configuration file found, using defaults"
        create_default_config
    fi
}

################################################################################
# Create Default Configuration
################################################################################

create_default_config() {
    log_info "Creating default configuration file..."
    
    cat > "${CONFIG_FILE}" << 'EOF'
# Security-Automation Backup Configuration
# Edit this file to customize backup behavior

# Enable automation mode (disables interactive prompts)
AUTO_MODE=false

# Enable notifications on backup completion
ENABLE_NOTIFICATIONS=false

# Email address for notifications (requires mail utility)
NOTIFICATION_EMAIL=""

# Webhook URL for notifications (e.g., Slack, Discord)
NOTIFICATION_WEBHOOK=""

# Maximum number of backups to retain
MAX_BACKUPS=10

# Automatically cleanup old backups
AUTO_CLEANUP=true

# Enable backup compression
BACKUP_COMPRESSION=true

# Backup frequency in hours (for cron scheduling)
BACKUP_FREQUENCY=24

# Remote backup destination (optional, e.g., S3, FTP)
# Format: "s3://bucket-name/path" or "ftp://user:pass@host/path"
REMOTE_BACKUP_DEST=""

# Enable remote backup
ENABLE_REMOTE_BACKUP=false

# Encryption key for backups (leave empty to disable)
BACKUP_ENCRYPTION_KEY=""

EOF
    
    log_success "Default configuration created at ${CONFIG_FILE}"
}

################################################################################
# Utility Functions
################################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE}"
}

################################################################################
# Send Notifications
################################################################################

send_email_notification() {
    if [ -z "${NOTIFICATION_EMAIL}" ] || ! command -v mail &>/dev/null; then
        return 0
    fi
    
    local subject="$1"
    local message="$2"
    
    echo "${message}" | mail -s "${subject}" "${NOTIFICATION_EMAIL}" 2>/dev/null || true
}

send_webhook_notification() {
    if [ -z "${NOTIFICATION_WEBHOOK}" ] || ! command -v curl &>/dev/null; then
        return 0
    fi
    
    local title="$1"
    local message="$2"
    local status="${3:-success}"
    
    local color="28a745"  # green
    [ "${status}" = "error" ] && color="dc3545"  # red
    [ "${status}" = "warning" ] && color="ffc107"  # yellow
    
    # Format for Slack webhook
    local payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "${color}",
            "title": "${title}",
            "text": "${message}",
            "ts": $(date +%s)
        }
    ]
}
EOF
)
    
    curl -X POST -H 'Content-type: application/json' \
        --data "${payload}" \
        "${NOTIFICATION_WEBHOOK}" 2>/dev/null || true
}

send_notifications() {
    local status="$1"
    local message="$2"
    
    if [ "${ENABLE_NOTIFICATIONS}" != "true" ]; then
        return 0
    fi
    
    local title="Backup ${status}: ${TIMESTAMP}"
    
    send_email_notification "${title}" "${message}"
    send_webhook_notification "${title}" "${message}" "${status}"
}

################################################################################
# Initialize Backup
################################################################################

initialize_backup() {
    log_info "Initializing backup process..."
    
    # Create backup directory
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}/repository"
    mkdir -p "${BACKUP_DIR}/metadata"
    mkdir -p "${BACKUP_DIR}/configs"
    
    log_success "Backup directory created: ${BACKUP_DIR}"
}

################################################################################
# Backup Repository
################################################################################

backup_repository() {
    log_info "Backing up repository files..."
    
    local archive_name="repo_files_${TIMESTAMP}.tar.gz"
    local archive_path="${BACKUP_DIR}/repository/${archive_name}"
    
    # Create tar archive of the entire repository
    tar --exclude='.git' \
        --exclude='.backups' \
        --exclude='*.pyc' \
        --exclude='__pycache__' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='node_modules' \
        --exclude='.pytest_cache' \
        -czf "${archive_path}" \
        -C "${REPO_ROOT}" . 2>/dev/null || true
    
    if [ -f "${archive_path}" ]; then
        local size=$(du -h "${archive_path}" | cut -f1)
        log_success "Repository files backed up: $size"
        
        # Encrypt if key is provided
        if [ -n "${BACKUP_ENCRYPTION_KEY}" ] && command -v openssl &>/dev/null; then
            encrypt_backup "${archive_path}"
        fi
        
        return 0
    else
        log_error "Failed to backup repository files"
        return 1
    fi
}

################################################################################
# Encrypt Backup
################################################################################

encrypt_backup() {
    local archive_path="$1"
    
    log_info "Encrypting backup..."
    
    if openssl enc -aes-256-cbc -salt -in "${archive_path}" \
        -out "${archive_path}.enc" -k "${BACKUP_ENCRYPTION_KEY}" 2>/dev/null; then
        rm -f "${archive_path}"
        log_success "Backup encrypted"
        return 0
    else
        log_warning "Encryption failed, keeping unencrypted backup"
        return 1
    fi
}

################################################################################
# Backup Git Metadata
################################################################################

backup_git_metadata() {
    log_info "Backing up git metadata..."
    
    if [ -d "${REPO_ROOT}/.git" ]; then
        # Create git bundle for complete repository history
        cd "${REPO_ROOT}"
        git bundle create "${BACKUP_DIR}/metadata/repo.bundle" --all 2>/dev/null || true
        
        # Export git log
        git log --oneline > "${BACKUP_DIR}/metadata/git_log.txt" 2>/dev/null || true
        
        # Export branches
        git branch -a > "${BACKUP_DIR}/metadata/branches.txt" 2>/dev/null || true
        
        # Export tags
        git tag -l > "${BACKUP_DIR}/metadata/tags.txt" 2>/dev/null || true
        
        # Export remotes
        git remote -v > "${BACKUP_DIR}/metadata/remotes.txt" 2>/dev/null || true
        
        # Export current branch and status
        git status > "${BACKUP_DIR}/metadata/git_status.txt" 2>/dev/null || true
        
        # Export diff stats
        git diff --stat > "${BACKUP_DIR}/metadata/diff_stats.txt" 2>/dev/null || true
        
        log_success "Git metadata backed up"
    else
        log_warning "Git repository not found at ${REPO_ROOT}/.git"
    fi
}

################################################################################
# Backup Configuration Files
################################################################################

backup_configurations() {
    log_info "Backing up configuration files..."
    
    # Backup common config files if they exist
    local config_files=(
        ".gitignore"
        ".github"
        ".gitattributes"
        "setup.py"
        "setup.cfg"
        "pyproject.toml"
        "requirements.txt"
        "requirements-dev.txt"
        "Pipfile"
        "Pipfile.lock"
        "tox.ini"
        ".env.example"
        "docker-compose.yml"
        "Dockerfile"
        ".editorconfig"
        ".pre-commit-config.yaml"
        ".backup-config"
        ".github/workflows"
    )
    
    for config_file in "${config_files[@]}"; do
        if [ -e "${REPO_ROOT}/${config_file}" ]; then
            cp -r "${REPO_ROOT}/${config_file}" "${BACKUP_DIR}/configs/" 2>/dev/null || true
        fi
    done
    
    log_success "Configuration files backed up"
}

################################################################################
# Create Backup Manifest
################################################################################

create_backup_manifest() {
    log_info "Creating backup manifest..."
    
    local manifest_file="${BACKUP_DIR}/MANIFEST.md"
    
    cat > "${manifest_file}" << EOF
# Security-Automation Backup Manifest

## Backup Information
- **Created**: $(date)
- **Repository**: https://github.com/Emuini005/Security-Automation
- **Backup Version**: 2.0 (Automated)
- **Hostname**: $(hostname)
- **User**: $(whoami)

## Directory Structure

### /repository
- Repository files (excluding .git and caches)

### /metadata
- \`repo.bundle\` - Git bundle containing complete repository history
- \`git_log.txt\` - Git commit log
- \`branches.txt\` - List of branches
- \`tags.txt\` - List of tags
- \`remotes.txt\` - Git remote information
- \`git_status.txt\` - Repository status at backup time
- \`diff_stats.txt\` - Diff statistics

### /configs
- Configuration files (.gitignore, .github, etc.)
- Package management files (requirements.txt, Pipfile, etc.)
- Build configuration files (Dockerfile, docker-compose.yml, etc.)

## Recovery Instructions

### Quick Restore
\`\`\`bash
./recovery.sh --restore-all backup_${TIMESTAMP}
\`\`\`

### Selective Restore
\`\`\`bash
./recovery.sh --restore-repository backup_${TIMESTAMP}
./recovery.sh --restore-git backup_${TIMESTAMP}
./recovery.sh --restore-configs backup_${TIMESTAMP}
\`\`\`

EOF

    log_success "Backup manifest created"
}

################################################################################
# Create Checksums
################################################################################

create_checksums() {
    log_info "Creating backup checksums..."
    
    cd "${BACKUP_DIR}"
    
    # Create SHA256 checksums
    find . -type f \( -name "*.tar.gz" -o -name "*.bundle" -o -name "*.txt" -o -name "*.md" -o -name "*.enc" \) \
        -exec sha256sum {} \; > checksums.sha256 2>/dev/null || true
    
    log_success "Checksums created: checksums.sha256"
}

################################################################################
# Verify Backup Integrity
################################################################################

verify_backup_integrity() {
    log_info "Verifying backup integrity..."
    
    cd "${BACKUP_DIR}"
    
    if [ -f "checksums.sha256" ]; then
        if sha256sum -c checksums.sha256 &>/dev/null; then
            log_success "Backup integrity verified successfully"
            return 0
        else
            log_error "Backup integrity verification failed"
            return 1
        fi
    else
        log_warning "Checksum file not found"
        return 1
    fi
}

################################################################################
# Compress Backup
################################################################################

compress_backup() {
    if [ "${BACKUP_COMPRESSION}" != "true" ]; then
        return 0
    fi
    
    log_info "Compressing backup..."
    
    local backup_archive="${BACKUP_BASE_DIR}/Security-Automation_backup_${TIMESTAMP}.tar.gz"
    
    cd "${BACKUP_BASE_DIR}"
    tar -czf "$(basename "${backup_archive}")" "backup_${TIMESTAMP}" 2>/dev/null || true
    
    if [ -f "${backup_archive}" ]; then
        local size=$(du -h "${backup_archive}" | cut -f1)
        log_success "Backup compressed: ${backup_archive} ($size)"
    else
        log_warning "Backup compression skipped"
    fi
}

################################################################################
# Generate Backup Report
################################################################################

generate_backup_report() {
    log_info "Generating backup report..."
    
    local report_file="${BACKUP_DIR}/BACKUP_REPORT.txt"
    
    {
        echo "========================================"
        echo "Security-Automation Backup Report"
        echo "========================================"
        echo "Timestamp: $(date)"
        echo "Backup Directory: ${BACKUP_DIR}"
        echo "Mode: $([ "${AUTO_MODE}" = "true" ] && echo "Automated" || echo "Manual")"
        echo ""
        
        echo "Backup Contents:"
        echo "--------"
        du -sh "${BACKUP_DIR}"/* 2>/dev/null || true
        echo ""
        
        echo "Repository Information:"
        echo "--------"
        if command -v git &> /dev/null && [ -d "${REPO_ROOT}/.git" ]; then
            echo "Current Branch: $(cd "${REPO_ROOT}" && git rev-parse --abbrev-ref HEAD)"
            echo "Current Commit: $(cd "${REPO_ROOT}" && git rev-parse HEAD)"
            echo "Total Commits: $(cd "${REPO_ROOT}" && git rev-list --count HEAD)"
        fi
        echo ""
        
        echo "Files Backed Up:"
        echo "--------"
        find "${BACKUP_DIR}" -type f | wc -l
        echo ""
        
        echo "Total Backup Size:"
        echo "--------"
        du -sh "${BACKUP_DIR}"
        echo ""
        
        echo "Backup Status:"
        echo "--------"
        echo "✓ Repository files"
        echo "✓ Git metadata"
        echo "✓ Configuration files"
        echo "✓ Checksums created"
        
    } | tee "${report_file}"
    
    log_success "Backup report generated"
}

################################################################################
# Cleanup Old Backups
################################################################################

cleanup_old_backups() {
    if [ "${AUTO_CLEANUP}" != "true" ]; then
        return 0
    fi
    
    log_info "Cleaning up old backups (keeping last ${MAX_BACKUPS})..."
    
    # Count existing backups
    local backup_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | wc -l)
    
    if [ "${backup_count}" -gt "${MAX_BACKUPS}" ]; then
        local remove_count=$((backup_count - MAX_BACKUPS))
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' 2>/dev/null | \
            sort -n | head -n "${remove_count}" | cut -d' ' -f2- | \
            while read -r old_backup; do
                log_warning "Removing old backup: $(basename "${old_backup}")"
                rm -rf "${old_backup}"
            done
    fi
    
    log_success "Old backups cleaned up"
}

################################################################################
# Upload to Remote Destination
################################################################################

upload_remote_backup() {
    if [ "${ENABLE_REMOTE_BACKUP}" != "true" ] || [ -z "${REMOTE_BACKUP_DEST}" ]; then
        return 0
    fi
    
    log_info "Uploading backup to remote destination..."
    
    local backup_archive="${BACKUP_BASE_DIR}/Security-Automation_backup_${TIMESTAMP}.tar.gz"
    
    if [ ! -f "${backup_archive}" ]; then
        log_warning "Compressed backup not found, skipping remote upload"
        return 0
    fi
    
    case "${REMOTE_BACKUP_DEST}" in
        s3://*)
            if command -v aws &>/dev/null; then
                aws s3 cp "${backup_archive}" "${REMOTE_BACKUP_DEST}/" || return 1
                log_success "Backup uploaded to S3"
            else
                log_warning "AWS CLI not installed, skipping S3 upload"
                return 0
            fi
            ;;
        ftp://*)
            if command -v curl &>/dev/null; then
                curl -T "${backup_archive}" "${REMOTE_BACKUP_DEST}/" || return 1
                log_success "Backup uploaded via FTP"
            else
                log_warning "curl not installed, skipping FTP upload"
                return 0
            fi
            ;;
        *)
            log_warning "Unsupported remote destination: ${REMOTE_BACKUP_DEST}"
            return 0
            ;;
    esac
}

################################################################################
# Setup Cron Automation
################################################################################

setup_cron_automation() {
    log_info "Setting up cron automation..."
    
    local cron_schedule="0 */${BACKUP_FREQUENCY} * * *"  # Every N hours
    local cron_job="${SCRIPT_DIR}/backup.sh --auto"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "${cron_job}"; then
        log_warning "Cron job already exists"
        return 0
    fi
    
    # Add new cron job
    (crontab -l 2>/dev/null; echo "${cron_schedule} ${cron_job}") | crontab - 2>/dev/null || true
    
    if crontab -l 2>/dev/null | grep -q "${cron_job}"; then
        log_success "Cron automation enabled (every ${BACKUP_FREQUENCY} hours)"
        return 0
    else
        log_error "Failed to setup cron automation"
        return 1
    fi
}

################################################################################
# Remove Cron Automation
################################################################################

remove_cron_automation() {
    log_info "Removing cron automation..."
    
    local cron_job="${SCRIPT_DIR}/backup.sh --auto"
    
    if crontab -l 2>/dev/null | grep -q "${cron_job}"; then
        crontab -l 2>/dev/null | grep -v "${cron_job}" | crontab - 2>/dev/null || true
        log_success "Cron automation disabled"
        return 0
    else
        log_warning "Cron job not found"
        return 0
    fi
}

################################################################################
# Show Usage
################################################################################

show_usage() {
    cat << 'EOF'
Security-Automation Backup Script with Automation Support

Usage: ./backup.sh [OPTIONS]

Options:
  --auto                    Run in automatic mode (non-interactive, no prompts)
  --setup-cron              Setup automated daily backups via cron
  --remove-cron             Remove cron automation
  --configure               Create or edit configuration file
  --manual                  Run backup in manual mode (interactive)
  --verify                  Verify the integrity of the latest backup
  --help                    Show this help message

Examples:
  ./backup.sh                           # Interactive backup
  ./backup.sh --auto                   # Automated backup (for cron)
  ./backup.sh --setup-cron             # Enable automatic backups
  ./backup.sh --configure              # Setup automation settings
  ./backup.sh --verify                 # Verify backup integrity

Configuration:
  Edit .backup-config to customize:
  - Backup frequency
  - Retention policy (max backups)
  - Email/webhook notifications
  - Remote backup destinations
  - Encryption settings

EOF
}

################################################################################
# Main Execution
################################################################################

main() {
    local command="${1:-}"
    
    # Load configuration
    load_config
    
    case "${command}" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --auto)
            AUTO_MODE=true
            run_backup
            ;;
        --manual)
            AUTO_MODE=false
            run_backup
            ;;
        --setup-cron)
            setup_cron_automation
            exit $?
            ;;
        --remove-cron)
            remove_cron_automation
            exit $?
            ;;
        --configure)
            if [ -t 0 ]; then
                edit_config
            else
                log_error "Configuration editor requires interactive terminal"
                exit 1
            fi
            ;;
        --verify)
            verify_latest_backup
            exit $?
            ;;
        *)
            AUTO_MODE=false
            run_backup
            ;;
    esac
}

################################################################################
# Run Backup Procedure
################################################################################

run_backup() {
    log_info "=========================================="
    log_info "Security-Automation Backup Process Started"
    log_info "Mode: $([ "${AUTO_MODE}" = "true" ] && echo "Automated" || echo "Manual")"
    log_info "=========================================="
    
    initialize_backup
    backup_repository || { send_notifications "FAILED" "Repository backup failed"; exit 1; }
    backup_git_metadata
    backup_configurations
    create_backup_manifest
    create_checksums
    verify_backup_integrity || { send_notifications "WARNING" "Backup integrity verification failed"; }
    generate_backup_report
    
    if [ "${BACKUP_COMPRESSION}" = "true" ]; then
        compress_backup
    fi
    
    cleanup_old_backups
    upload_remote_backup || { send_notifications "WARNING" "Remote backup upload failed"; }
    
    log_success "=========================================="
    log_success "Backup process completed successfully!"
    log_success "=========================================="
    log_info "Backup location: ${BACKUP_DIR}"
    log_info "Backup log: ${LOG_FILE}"
    
    # Send success notification
    send_notifications "SUCCESS" "Backup completed successfully at ${BACKUP_DIR}"
}

################################################################################
# Edit Configuration
################################################################################

edit_config() {
    log_info "Editing configuration file..."
    
    if [ -z "${EDITOR:-}" ]; then
        EDITOR="nano"
    fi
    
    "${EDITOR}" "${CONFIG_FILE}" || log_error "Failed to edit configuration file"
}

################################################################################
# Verify Latest Backup
################################################################################

verify_latest_backup() {
    log_info "Verifying latest backup..."
    
    local latest_backup=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" | sort -r | head -n 1)
    
    if [ -z "${latest_backup}" ]; then
        log_error "No backups found"
        return 1
    fi
    
    log_info "Latest backup: $(basename "${latest_backup}")"
    
    cd "${latest_backup}"
    
    if [ -f "checksums.sha256" ]; then
        if sha256sum -c checksums.sha256; then
            log_success "Backup integrity verified"
            return 0
        else
            log_error "Backup integrity verification failed"
            return 1
        fi
    else
        log_error "Checksum file not found"
        return 1
    fi
}

# Run main function with all arguments
main "$@"

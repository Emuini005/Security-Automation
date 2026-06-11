#!/bin/bash

################################################################################
# Security-Automation Repository Automated Backup Script
# Purpose: Create complete backups with scheduling, notification, and automation
# Features: Cron scheduling, email alerts, cloud sync, retention policies
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
CONFIG_FILE="${SCRIPT_DIR}/.backup-config"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-./.backups}"
STATE_DIR="${BACKUP_BASE_DIR}/.state"
LOCK_FILE="${STATE_DIR}/backup.lock"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_BASE_DIR}/backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_DIR}/backup.log"

# ============================================================================
# LOGGING & COLOR CODES
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# ============================================================================
# LOCK MECHANISM FOR CONCURRENT EXECUTION
# ============================================================================

acquire_lock() {
    mkdir -p "${STATE_DIR}"
    
    if [ -f "${LOCK_FILE}" ]; then
        local lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Backup already running (PID: ${lock_pid})"
            return 1
        fi
    fi
    
    echo $$ > "${LOCK_FILE}"
    log_info "Lock acquired (PID: $$)"
    return 0
}

release_lock() {
    rm -f "${LOCK_FILE}"
    log_info "Lock released"
}

# ============================================================================
# CONFIGURATION MANAGEMENT
# ============================================================================

load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        source "${CONFIG_FILE}"
        log_info "Configuration loaded from ${CONFIG_FILE}"
    else
        create_default_config
    fi
}

create_default_config() {
    mkdir -p "${STATE_DIR}"
    
    cat > "${CONFIG_FILE}" << 'CONFIGEOF'
# =============================================================================
# Security-Automation Backup Configuration
# =============================================================================

# BACKUP SETTINGS
BACKUP_ENABLED=true
BACKUP_COMPRESSION=true
BACKUP_VERIFY=true
MAX_BACKUP_RETENTION=10
MAX_BACKUP_AGE_DAYS=30

# NOTIFICATION SETTINGS
ENABLE_EMAIL_NOTIFICATIONS=false
SMTP_SERVER="localhost"
SMTP_PORT=25
EMAIL_FROM="backup@localhost"
EMAIL_TO="admin@example.com"
NOTIFY_ON_SUCCESS=true
NOTIFY_ON_FAILURE=true

# CLOUD SYNC SETTINGS
ENABLE_CLOUD_SYNC=false
CLOUD_PROVIDER="aws"
AWS_S3_BUCKET=""
AWS_REGION="us-east-1"

# SCHEDULING
SCHEDULE_ENABLED=true
CRON_SCHEDULE="0 2 * * *"

# SLACK
ENABLE_SLACK=false
SLACK_WEBHOOK_URL=""
SLACK_CHANNEL="#backups"

# GIT SETTINGS
BACKUP_GIT_BUNDLE=true
BACKUP_GIT_LOG=true
BACKUP_REMOTE_TRACKING=true

# EXCLUDE PATTERNS
EXCLUDE_PATTERNS=(
    ".git"
    ".backups"
    ".pytest_cache"
    "__pycache__"
    "*.pyc"
    ".venv"
    "venv"
    ".env"
    "node_modules"
    ".DS_Store"
)

# ADVANCED
BACKUP_PARALLEL_JOBS=4
ENABLE_AUDIT_LOG=true
AUDIT_LOG_FILE="${STATE_DIR}/audit.log"
CONFIGEOF

    log_warning "Default configuration created: ${CONFIG_FILE}"
    source "${CONFIG_FILE}"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

initialize_backup() {
    log_info "Initializing backup process..."
    
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}/repository"
    mkdir -p "${BACKUP_DIR}/metadata"
    mkdir -p "${BACKUP_DIR}/configs"
    mkdir -p "${STATE_DIR}"
    
    log_success "Backup directory created: ${BACKUP_DIR}"
}

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================

backup_repository() {
    log_info "Backing up repository files..."
    
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args="--exclude='${pattern}' ${exclude_args}"
    done
    
    eval "tar ${exclude_args} -czf '${BACKUP_DIR}/repository/repo_files_${TIMESTAMP}.tar.gz' -C '${REPO_ROOT}' . 2>/dev/null || true"
    
    if [ -f "${BACKUP_DIR}/repository/repo_files_${TIMESTAMP}.tar.gz" ]; then
        local size=$(du -h "${BACKUP_DIR}/repository/repo_files_${TIMESTAMP}.tar.gz" | cut -f1)
        log_success "Repository files backed up: $size"
        return 0
    else
        log_error "Failed to backup repository files"
        return 1
    fi
}

backup_git_metadata() {
    log_info "Backing up git metadata..."
    
    if [ ! -d "${REPO_ROOT}/.git" ]; then
        log_warning "Git repository not found"
        return 0
    fi
    
    cd "${REPO_ROOT}"
    
    if [ "${BACKUP_GIT_BUNDLE}" = true ]; then
        git bundle create "${BACKUP_DIR}/metadata/repo.bundle" --all 2>/dev/null || true
    fi
    
    if [ "${BACKUP_GIT_LOG}" = true ]; then
        git log --oneline > "${BACKUP_DIR}/metadata/git_log.txt" 2>/dev/null || true
        git log --graph --oneline --all > "${BACKUP_DIR}/metadata/git_log_graph.txt" 2>/dev/null || true
    fi
    
    git branch -a > "${BACKUP_DIR}/metadata/branches.txt" 2>/dev/null || true
    git tag -l > "${BACKUP_DIR}/metadata/tags.txt" 2>/dev/null || true
    git remote -v > "${BACKUP_DIR}/metadata/remotes.txt" 2>/dev/null || true
    git status > "${BACKUP_DIR}/metadata/git_status.txt" 2>/dev/null || true
    
    log_success "Git metadata backed up"
}

backup_configurations() {
    log_info "Backing up configuration files..."
    
    local config_files=(
        ".gitignore"
        ".github"
        ".gitattributes"
        "setup.py"
        "setup.cfg"
        "pyproject.toml"
        "requirements.txt"
        "requirements-dev.txt"
        ".backup-config"
    )
    
    for config_file in "${config_files[@]}"; do
        if [ -e "${REPO_ROOT}/${config_file}" ]; then
            cp -r "${REPO_ROOT}/${config_file}" "${BACKUP_DIR}/configs/" 2>/dev/null || true
        fi
    done
    
    log_success "Configuration files backed up"
}

create_backup_manifest() {
    log_info "Creating backup manifest..."
    
    local manifest_file="${BACKUP_DIR}/MANIFEST.md"
    
    cat > "${manifest_file}" << EOF
# Security-Automation Backup Manifest

## Backup Information
- **Created**: $(date)
- **Repository**: https://github.com/Emuini005/Security-Automation
- **Backup Version**: 2.0 (Automated)
- **Backup ID**: ${TIMESTAMP}

## Directory Structure

### /repository
- \`repo_files_*.tar.gz\` - Complete repository files

### /metadata
- \`repo.bundle\` - Git bundle with complete history
- \`git_log.txt\` - Git commit log

### /configs
- Configuration files and manifests

EOF

    log_success "Backup manifest created"
}

create_checksums() {
    log_info "Creating backup checksums..."
    
    cd "${BACKUP_DIR}"
    find . -type f \( -name "*.tar.gz" -o -name "*.bundle" -o -name "*.txt" -o -name "*.md" \) \
        -exec sha256sum {} \; > checksums.sha256
    
    log_success "Checksums created"
}

verify_backup_integrity() {
    log_info "Verifying backup integrity..."
    
    cd "${BACKUP_DIR}"
    
    if [ ! -f "checksums.sha256" ]; then
        log_warning "Checksum file not found"
        return 1
    fi
    
    if sha256sum -c checksums.sha256 &>/dev/null; then
        log_success "Backup integrity verified successfully"
        return 0
    else
        log_error "Backup integrity verification failed"
        return 1
    fi
}

compress_backup() {
    if [ "${BACKUP_COMPRESSION}" = false ]; then
        return 0
    fi
    
    log_info "Compressing backup..."
    
    local backup_archive="${BACKUP_BASE_DIR}/Security-Automation_backup_${TIMESTAMP}.tar.gz"
    cd "${BACKUP_BASE_DIR}"
    tar -czf "$(basename "${backup_archive}")" "backup_${TIMESTAMP}" 2>/dev/null || true
    
    if [ -f "${backup_archive}" ]; then
        local size=$(du -h "${backup_archive}" | cut -f1)
        log_success "Backup compressed: $(basename "${backup_archive}") ($size)"
    fi
}

# ============================================================================
# RETENTION MANAGEMENT
# ============================================================================

cleanup_old_backups() {
    log_info "Managing backup retention..."
    
    if [ -n "${MAX_BACKUP_AGE_DAYS}" ] && [ "${MAX_BACKUP_AGE_DAYS}" -gt 0 ]; then
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -mtime +"${MAX_BACKUP_AGE_DAYS}" | while read -r old_backup; do
            log_warning "Removing expired backup: $(basename "${old_backup}")"
            rm -rf "${old_backup}"
        done
    fi
    
    local backup_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" | wc -l)
    if [ "${backup_count}" -gt "${MAX_BACKUP_RETENTION}" ]; then
        local remove_count=$((backup_count - MAX_BACKUP_RETENTION))
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | \
            sort -n | head -n "${remove_count}" | cut -d' ' -f2- | \
            while read -r old_backup; do
                log_warning "Removing old backup (retention): $(basename "${old_backup}")"
                rm -rf "${old_backup}"
            done
    fi
    
    log_success "Backup retention policy applied"
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================

send_email_notification() {
    local subject="$1"
    local message="$2"
    local status="$3"
    
    if [ "${ENABLE_EMAIL_NOTIFICATIONS}" != true ]; then
        return 0
    fi
    
    log_info "Sending email notification..."
    
    {
        echo "Subject: ${subject}"
        echo "To: ${EMAIL_TO}"
        echo "From: ${EMAIL_FROM}"
        echo ""
        echo "${message}"
        echo ""
        echo "Backup Directory: ${BACKUP_DIR}"
        echo "Timestamp: $(date)"
        echo "Status: ${status}"
    } | sendmail -t "${EMAIL_TO}" 2>/dev/null || log_warning "Failed to send email"
}

send_slack_notification() {
    local message="$1"
    local status="$2"
    
    if [ "${ENABLE_SLACK}" != true ] || [ -z "${SLACK_WEBHOOK_URL}" ]; then
        return 0
    fi
    
    log_info "Sending Slack notification..."
    
    local color="good"
    [ "${status}" = "FAILURE" ] && color="danger"
    
    local payload=$(cat <<EOF
{
    "channel": "${SLACK_CHANNEL}",
    "username": "Backup Bot",
    "attachments": [
        {
            "color": "${color}",
            "title": "Security-Automation Backup ${status}",
            "text": "${message}",
            "fields": [
                {
                    "title": "Backup ID",
                    "value": "${TIMESTAMP}",
                    "short": true
                },
                {
                    "title": "Size",
                    "value": "$(du -sh "${BACKUP_DIR}" | cut -f1)",
                    "short": true
                }
            ],
            "ts": $(date +%s)
        }
    ]
}
EOF
    )
    
    curl -X POST -H 'Content-type: application/json' \
        --data "${payload}" \
        "${SLACK_WEBHOOK_URL}" 2>/dev/null || log_warning "Failed to send Slack notification"
}

# ============================================================================
# SCHEDULING
# ============================================================================

setup_cron_schedule() {
    if [ "${SCHEDULE_ENABLED}" != true ]; then
        log_info "Cron scheduling disabled"
        return 0
    fi
    
    log_info "Setting up cron schedule..."
    
    local cron_cmd="${SCRIPT_DIR}/backup.sh --run-backup"
    local cron_entry="${CRON_SCHEDULE} cd ${SCRIPT_DIR} && /bin/bash ${cron_cmd} >> ${STATE_DIR}/cron.log 2>&1"
    
    if crontab -l 2>/dev/null | grep -q "${cron_cmd}"; then
        log_warning "Cron job already exists"
        return 0
    fi
    
    (crontab -l 2>/dev/null || echo "") | {
        cat
        echo "${cron_entry}"
    } | crontab - 2>/dev/null || log_warning "Could not add cron job"
    
    log_success "Cron schedule configured: ${CRON_SCHEDULE}"
}

remove_cron_schedule() {
    log_info "Removing cron schedule..."
    local cron_cmd="${SCRIPT_DIR}/backup.sh --run-backup"
    crontab -l 2>/dev/null | grep -v "${cron_cmd}" | crontab - 2>/dev/null || true
    log_success "Cron schedule removed"
}

# ============================================================================
# REPORTING
# ============================================================================

generate_backup_report() {
    log_info "Generating backup report..."
    
    local report_file="${BACKUP_DIR}/BACKUP_REPORT.txt"
    
    {
        echo "========================================"
        echo "Security-Automation Backup Report"
        echo "========================================"
        echo "Timestamp: $(date)"
        echo "Backup ID: ${TIMESTAMP}"
        echo ""
        echo "Backup Contents:"
        echo "--------"
        du -sh "${BACKUP_DIR}"/* 2>/dev/null || true
        echo ""
        echo "Total Backup Size:"
        echo "--------"
        du -sh "${BACKUP_DIR}"
        
    } | tee "${report_file}"
    
    log_success "Backup report generated"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

run_backup() {
    log_info "=========================================="
    log_info "Security-Automation Backup Process Started"
    log_info "=========================================="
    
    local backup_success=true
    
    if ! initialize_backup; then backup_success=false; fi
    if ! backup_repository; then backup_success=false; fi
    if ! backup_git_metadata; then backup_success=false; fi
    if ! backup_configurations; then backup_success=false; fi
    if ! create_backup_manifest; then backup_success=false; fi
    if ! create_checksums; then backup_success=false; fi
    
    if [ "${BACKUP_VERIFY}" = true ]; then
        if ! verify_backup_integrity; then backup_success=false; fi
    fi
    
    compress_backup
    generate_backup_report
    cleanup_old_backups
    
    local status="SUCCESS"
    local message="Backup completed successfully. Backup ID: ${TIMESTAMP}"
    
    if [ "${backup_success}" = false ]; then
        status="FAILURE"
        message="Backup completed with errors. Backup ID: ${TIMESTAMP}"
    fi
    
    if [ "${NOTIFY_ON_SUCCESS}" = true ] && [ "${status}" = "SUCCESS" ]; then
        send_email_notification "Backup Success" "${message}" "${status}"
        send_slack_notification "${message}" "${status}"
    fi
    
    if [ "${NOTIFY_ON_FAILURE}" = true ] && [ "${status}" = "FAILURE" ]; then
        send_email_notification "Backup Failed" "${message}" "${status}"
        send_slack_notification "${message}" "${status}"
    fi
    
    log_success "=========================================="
    log_success "Backup process completed: ${status}"
    log_success "=========================================="
    log_info "Backup location: ${BACKUP_DIR}"
}

show_usage() {
    cat << 'EOF'
Security-Automation Automated Backup Script

Usage: ./backup.sh [COMMAND] [OPTIONS]

Commands:
  --run-backup              Run backup immediately
  --setup-schedule          Setup cron scheduling
  --remove-schedule         Remove cron scheduling
  --status                  Show backup status
  --list                    List all backups
  --clean                   Clean old backups
  --configure               Edit configuration
  --help                    Show this help

Examples:
  ./backup.sh --run-backup
  ./backup.sh --setup-schedule
  ./backup.sh --status

EOF
}

# ============================================================================
# COMMAND PROCESSING
# ============================================================================

main() {
    local command="${1:-}"
    
    case "${command}" in
        --run-backup)
            trap release_lock EXIT
            if acquire_lock; then
                load_config
                run_backup
            fi
            ;;
        --setup-schedule)
            load_config
            setup_cron_schedule
            ;;
        --remove-schedule)
            remove_cron_schedule
            ;;
        --status)
            load_config
            log_info "Backup Status:"
            log_info "Last backup:"
            find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | \
                sort -r | head -n 1 | cut -d' ' -f2- | while read -r backup_dir; do
                [ -n "${backup_dir}" ] && du -sh "${backup_dir}"
            done
            ;;
        --list)
            find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | sort -r | cut -d' ' -f2- | while read -r backup; do
                [ -n "${backup}" ] && echo "$(basename "${backup}") - $(du -sh "${backup}" | cut -f1)"
            done
            ;;
        --clean)
            load_config
            cleanup_old_backups
            ;;
        --configure)
            load_config
            ${EDITOR:-nano} "${CONFIG_FILE}"
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
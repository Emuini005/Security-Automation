#!/bin/bash

################################################################################
# Security-Automation Repository Automated Recovery Script
# Purpose: Restore repository from backups with safety checks and automation
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-./.backups}"
STATE_DIR="${BACKUP_BASE_DIR}/.state"
LOCK_FILE="${STATE_DIR}/recovery.lock"
CONFIG_FILE="${SCRIPT_DIR}/.recovery-config"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RECOVERY_LOG="${STATE_DIR}/recovery_${TIMESTAMP}.log"

# ============================================================================
# LOGGING & COLOR CODES
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${RECOVERY_LOG}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${RECOVERY_LOG}" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${RECOVERY_LOG}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${RECOVERY_LOG}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${RECOVERY_LOG}"
}

# ============================================================================
# LOCK MECHANISM
# ============================================================================

acquire_lock() {
    mkdir -p "${STATE_DIR}"
    
    if [ -f "${LOCK_FILE}" ]; then
        local lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Recovery already running (PID: ${lock_pid})"
            return 1
        fi
    fi
    
    echo $$ > "${LOCK_FILE}"
    return 0
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# ============================================================================
# CONFIGURATION MANAGEMENT
# ============================================================================

load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        source "${CONFIG_FILE}"
        log_info "Configuration loaded"
    else
        create_default_config
    fi
}

create_default_config() {
    mkdir -p "${STATE_DIR}"
    
    cat > "${CONFIG_FILE}" << 'CONFIGEOF'
# Recovery Configuration

AUTO_RESTORE_ENABLED=false
RESTORE_VERIFY_BEFORE=true
RESTORE_BACKUP_CURRENT=true
ENABLE_ROLLBACK=true
ROLLBACK_ON_FAILURE=true
ROLLBACK_BACKUP_DIR=""

ENABLE_EMAIL_NOTIFICATIONS=false
EMAIL_FROM="recovery@localhost"
EMAIL_TO="admin@example.com"

ENABLE_SLACK=false
SLACK_WEBHOOK_URL=""
SLACK_CHANNEL="#recovery"

SCHEDULE_ENABLED=false
CRON_SCHEDULE="0 3 * * 0"

ENABLE_AUDIT=true
AUDIT_LOG_FILE="${STATE_DIR}/recovery_audit.log"
CONFIGEOF

    log_warning "Default configuration created: ${CONFIG_FILE}"
    source "${CONFIG_FILE}"
}

# ============================================================================
# INITIALIZATION
# ============================================================================

initialize_recovery() {
    mkdir -p "${STATE_DIR}"
    log_info "Recovery initialized"
}

# ============================================================================
# BACKUP OPERATIONS
# ============================================================================

list_backups() {
    log_info "Available backups:"
    echo ""
    
    if [ ! -d "${BACKUP_BASE_DIR}" ] || [ -z "$(ls -A "${BACKUP_BASE_DIR}" 2>/dev/null)" ]; then
        log_error "No backups found"
        return 1
    fi
    
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | sort -r | while read -r timestamp backup_dir; do
        local backup_name=$(basename "${backup_dir}")
        local backup_size=$(du -sh "${backup_dir}" 2>/dev/null | cut -f1)
        
        echo -e "${BLUE}${backup_name}${NC}"
        echo "    Size: $backup_size"
        [ -f "${backup_dir}/MANIFEST.md" ] && echo "    ✓ Manifest"
        [ -f "${backup_dir}/repository/repo_files_"*.tar.gz ] && echo "    ✓ Repository Files"
        echo ""
    done
}

find_backup_dir() {
    local backup_identifier="${1:-}"
    
    if [ -z "${backup_identifier}" ]; then
        local latest_backup=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" -printf '%T@ %p\n' | sort -r | head -n 1 | cut -d' ' -f2-)
        
        if [ -z "${latest_backup}" ]; then
            log_error "No backups found"
            return 1
        fi
        
        echo "${latest_backup}"
    else
        local backup_dir="${BACKUP_BASE_DIR}/${backup_identifier}"
        
        if [ ! -d "${backup_dir}" ]; then
            log_error "Backup not found: ${backup_dir}"
            return 1
        fi
        
        echo "${backup_dir}"
    fi
}

# ============================================================================
# RESTORE FUNCTIONS
# ============================================================================

verify_backup_integrity() {
    local backup_dir="$1"
    
    log_info "Verifying backup integrity..."
    
    if [ ! -f "${backup_dir}/checksums.sha256" ]; then
        log_warning "Checksum file not found"
        return 0
    fi
    
    cd "${backup_dir}"
    
    if sha256sum -c checksums.sha256 &>/dev/null; then
        log_success "Backup integrity verified"
        return 0
    else
        log_error "Backup integrity check failed"
        return 1
    fi
}

restore_repository() {
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring repository files..."
    
    local repo_archive=$(find "${backup_dir}/repository" -name "repo_files_*.tar.gz" 2>/dev/null | head -n 1)
    
    if [ -z "${repo_archive}" ]; then
        log_error "Repository archive not found"
        return 1
    fi
    
    mkdir -p "${restore_dir}"
    
    log_info "Extracting files..."
    if tar -xzf "${repo_archive}" -C "${restore_dir}"; then
        log_success "Repository files restored"
        return 0
    else
        log_error "Failed to extract repository"
        return 1
    fi
}

restore_git() {
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring git history..."
    
    local git_bundle="${backup_dir}/metadata/repo.bundle"
    
    if [ ! -f "${git_bundle}" ]; then
        log_error "Git bundle not found"
        return 1
    fi
    
    mkdir -p "${restore_dir}"
    
    if [ -d "${restore_dir}/.git" ]; then
        log_info "Git repository exists, fetching from bundle..."
        cd "${restore_dir}"
        git fetch "${git_bundle}" '*:*' 2>/dev/null || log_warning "Fetch completed"
    else
        log_info "Creating new git repository from bundle..."
        git clone "${git_bundle}" "${restore_dir}" 2>/dev/null || true
    fi
    
    log_success "Git history restored"
}

restore_configs() {
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring configuration files..."
    
    if [ ! -d "${backup_dir}/configs" ]; then
        log_warning "Config directory not found"
        return 0
    fi
    
    mkdir -p "${restore_dir}"
    cp -r "${backup_dir}/configs"/* "${restore_dir}/" 2>/dev/null || true
    
    log_success "Configuration files restored"
}

# ============================================================================
# RESTORE ALL
# ============================================================================

restore_all() {
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "=========================================="
    log_info "Starting Full Restoration"
    log_info "=========================================="
    
    if [ "${RESTORE_VERIFY_BEFORE}" = true ]; then
        if ! verify_backup_integrity "${backup_dir}"; then
            log_warning "Continuing anyway..."
        fi
    fi
    
    echo ""
    restore_repository "${backup_dir}" "${restore_dir}" || true
    echo ""
    restore_git "${backup_dir}" "${restore_dir}" || true
    echo ""
    restore_configs "${backup_dir}" "${restore_dir}" || true
    echo ""
    
    log_success "=========================================="
    log_success "Restoration completed"
    log_success "=========================================="
}

# ============================================================================
# SCHEDULING
# ============================================================================

setup_cron_schedule() {
    if [ "${SCHEDULE_ENABLED}" != true ]; then
        log_info "Scheduling disabled"
        return 0
    fi
    
    log_info "Setting up recovery schedule..."
    
    local cron_cmd="${SCRIPT_DIR}/recovery.sh --auto-restore"
    local cron_entry="${CRON_SCHEDULE} cd ${SCRIPT_DIR} && /bin/bash ${cron_cmd} >> ${STATE_DIR}/cron.log 2>&1"
    
    if crontab -l 2>/dev/null | grep -q "${cron_cmd}"; then
        log_warning "Cron job already exists"
        return 0
    fi
    
    (crontab -l 2>/dev/null || echo "") | {
        cat
        echo "${cron_entry}"
    } | crontab - 2>/dev/null || log_warning "Could not add cron job"
    
    log_success "Recovery schedule configured"
}

remove_cron_schedule() {
    log_info "Removing recovery schedule..."
    local cron_cmd="${SCRIPT_DIR}/recovery.sh --auto-restore"
    crontab -l 2>/dev/null | grep -v "${cron_cmd}" | crontab - 2>/dev/null || true
    log_success "Schedule removed"
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================

send_email_notification() {
    local subject="$1"
    local message="$2"
    
    if [ "${ENABLE_EMAIL_NOTIFICATIONS}" != true ]; then
        return 0
    fi
    
    {
        echo "Subject: ${subject}"
        echo "To: ${EMAIL_TO}"
        echo "From: ${EMAIL_FROM}"
        echo ""
        echo "${message}"
    } | sendmail -t "${EMAIL_TO}" 2>/dev/null || log_warning "Email failed"
}

send_slack_notification() {
    local message="$1"
    
    if [ "${ENABLE_SLACK}" != true ] || [ -z "${SLACK_WEBHOOK_URL}" ]; then
        return 0
    fi
    
    local payload=$(cat <<EOF
{
    "channel": "${SLACK_CHANNEL}",
    "text": "${message}",
    "ts": $(date +%s)
}
EOF
    )
    
    curl -X POST -H 'Content-type: application/json' \
        --data "${payload}" \
        "${SLACK_WEBHOOK_URL}" 2>/dev/null || log_warning "Slack failed"
}

# ============================================================================
# HELP & USAGE
# ============================================================================

show_usage() {
    cat << 'EOF'
Security-Automation Automated Recovery Script

Usage: ./recovery.sh [COMMAND] [OPTIONS]

Commands:
  --list                      List available backups
  --restore-all [BACKUP]      Restore all from backup
  --restore-repository [BACKUP] Restore files only
  --restore-git [BACKUP]      Restore git history
  --restore-configs [BACKUP]  Restore configurations
  --verify-backup [BACKUP]    Verify backup integrity
  --auto-restore              Automatic restore
  --setup-schedule            Setup cron scheduling
  --remove-schedule           Remove cron scheduling
  --configure                 Edit configuration
  --help                      Show this help

Examples:
  ./recovery.sh --list
  ./recovery.sh --restore-all
  ./recovery.sh --verify-backup backup_20260609_150000

EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    local command="${1:-}"
    
    trap release_lock EXIT
    
    case "${command}" in
        --list)
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            list_backups
            ;;
        --restore-all)
            if ! acquire_lock; then exit 1; fi
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            restore_all "${backup_dir}" "${3:-.}"
            ;;
        --restore-repository)
            if ! acquire_lock; then exit 1; fi
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            restore_repository "${backup_dir}" "${3:-.}"
            ;;
        --restore-git)
            if ! acquire_lock; then exit 1; fi
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            restore_git "${backup_dir}" "${3:-.}"
            ;;
        --restore-configs)
            if ! acquire_lock; then exit 1; fi
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            restore_configs "${backup_dir}" "${3:-.}"
            ;;
        --verify-backup)
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            verify_backup_integrity "${backup_dir}"
            ;;
        --auto-restore)
            if ! acquire_lock; then exit 1; fi
            initialize_recovery
            load_config
            mkdir -p "${STATE_DIR}"
            if [ "${AUTO_RESTORE_ENABLED}" = true ]; then
                local backup_dir
                backup_dir=$(find_backup_dir "") || exit 1
                restore_all "${backup_dir}"
            else
                log_warning "Auto-restore disabled"
            fi
            ;;
        --setup-schedule)
            load_config
            setup_cron_schedule
            ;;
        --remove-schedule)
            remove_cron_schedule
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
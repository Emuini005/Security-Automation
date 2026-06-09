#!/bin/bash

################################################################################
# Security-Automation Repository Recovery Script with Automation Support
# Purpose: Restore repository from backups with automated recovery options
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-./.backups}"
CONFIG_FILE="${SCRIPT_DIR}/.recovery-config"

# Automation settings
AUTO_MODE="${AUTO_MODE:-false}"
ENABLE_NOTIFICATIONS="${ENABLE_NOTIFICATIONS:-false}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
NOTIFICATION_WEBHOOK="${NOTIFICATION_WEBHOOK:-}"
AUTO_CLEANUP_TEMP="${AUTO_CLEANUP_TEMP:-true}"
DECRYPTION_KEY="${DECRYPTION_KEY:-}"

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
    log_info "Creating default recovery configuration file..."
    
    cat > "${CONFIG_FILE}" << 'EOF'
# Security-Automation Recovery Configuration
# Edit this file to customize recovery behavior

# Enable automation mode (disables interactive prompts)
AUTO_MODE=false

# Enable notifications on recovery completion
ENABLE_NOTIFICATIONS=false

# Email address for notifications (requires mail utility)
NOTIFICATION_EMAIL=""

# Webhook URL for notifications (e.g., Slack, Discord)
NOTIFICATION_WEBHOOK=""

# Automatically cleanup temporary files after recovery
AUTO_CLEANUP_TEMP=true

# Decryption key for encrypted backups
DECRYPTION_KEY=""

# Restore destination (leave empty for current directory)
RESTORE_DESTINATION=""

# Selective restore options (true to restore, false to skip)
RESTORE_REPO_FILES=true
RESTORE_GIT_HISTORY=true
RESTORE_CONFIGS=true

EOF
    
    log_info "Default recovery configuration created at ${CONFIG_FILE}"
}

################################################################################
# Utility Functions
################################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
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
    
    local title="Recovery ${status}: $(date +%Y%m%d_%H%M%S)"
    
    send_email_notification "${title}" "${message}"
    send_webhook_notification "${title}" "${message}" "${status}"
}

################################################################################
# List Available Backups
################################################################################

list_backups() {
    log_info "Available backups:"
    echo ""
    
    if [ ! -d "${BACKUP_BASE_DIR}" ] || [ -z "$(ls -A "${BACKUP_BASE_DIR}" 2>/dev/null)" ]; then
        log_error "No backups found in ${BACKUP_BASE_DIR}"
        return 1
    fi
    
    local count=0
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" | sort -r | while read -r backup_dir; do
        count=$((count + 1))
        local backup_name=$(basename "${backup_dir}")
        local backup_size=$(du -sh "${backup_dir}" 2>/dev/null | cut -f1)
        local backup_date=$(stat -f %Sm -t "%Y-%m-%d %H:%M:%S" "${backup_dir}" 2>/dev/null || \
                           stat -c %y "${backup_dir}" 2>/dev/null | cut -d' ' -f1-2 || echo "N/A")
        
        echo "[$count] $backup_name"
        echo "    Size: $backup_size"
        echo "    Date: $backup_date"
        
        # Show contents
        if [ -f "${backup_dir}/MANIFEST.md" ]; then
            echo "    ✓ Contains MANIFEST"
        fi
        if [ -f "${backup_dir}/repository/repo_files_"*.tar.gz ] || \
           [ -f "${backup_dir}/repository/repo_files_"*.tar.gz.enc ]; then
            echo "    ✓ Contains repository files"
        fi
        if [ -f "${backup_dir}/metadata/repo.bundle" ]; then
            echo "    ✓ Contains git bundle"
        fi
        echo ""
    done
}

################################################################################
# Find Backup Directory
################################################################################

find_backup_dir() {
    local backup_identifier="${1:-}"
    
    if [ -z "${backup_identifier}" ]; then
        # Find latest backup
        local latest_backup=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | sort -r | head -n 1)
        
        if [ -z "${latest_backup}" ]; then
            log_error "No backups found in ${BACKUP_BASE_DIR}"
            return 1
        fi
        
        echo "${latest_backup}"
    else
        # Find specified backup
        local backup_dir="${BACKUP_BASE_DIR}/${backup_identifier}"
        
        if [ ! -d "${backup_dir}" ]; then
            log_error "Backup not found: ${backup_dir}"
            return 1
        fi
        
        echo "${backup_dir}"
    fi
}

################################################################################
# Verify Backup Integrity
################################################################################

verify_backup_integrity() {
    local backup_dir="$1"
    
    log_info "Verifying backup integrity: $(basename "${backup_dir}")"
    
    if [ ! -f "${backup_dir}/checksums.sha256" ]; then
        log_warning "Checksum file not found"
        return 1
    fi
    
    cd "${backup_dir}"
    
    if sha256sum -c checksums.sha256 &>/dev/null; then
        log_success "Backup integrity verified"
        return 0
    else
        log_error "Backup integrity verification failed"
        return 1
    fi
}

################################################################################
# Decrypt Archive
################################################################################

decrypt_archive() {
    local archive_path="$1"
    
    if [ ! -f "${archive_path}.enc" ]; then
        return 0  # Not encrypted
    fi
    
    if [ -z "${DECRYPTION_KEY}" ]; then
        log_error "Encrypted backup found but no decryption key provided"
        return 1
    fi
    
    log_info "Decrypting archive..."
    
    if openssl enc -aes-256-cbc -d -in "${archive_path}.enc" \
        -out "${archive_path}" -k "${DECRYPTION_KEY}" 2>/dev/null; then
        log_success "Archive decrypted"
        return 0
    else
        log_error "Failed to decrypt archive"
        return 1
    fi
}

################################################################################
# Restore Repository Files
################################################################################

restore_repository() {
    if [ "${RESTORE_REPO_FILES}" != "true" ]; then
        log_info "Skipping repository files restore"
        return 0
    fi
    
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring repository files to: ${restore_dir}"
    
    local repo_archive=$(find "${backup_dir}/repository" -name "repo_files_*.tar.gz" 2>/dev/null | head -n 1)
    
    if [ -z "${repo_archive}" ]; then
        log_error "Repository archive not found in backup"
        return 1
    fi
    
    # Decrypt if needed
    decrypt_archive "${repo_archive}" || return 1
    
    # Check if restore directory is not empty
    if [ -d "${restore_dir}" ] && [ -n "$(ls -A "${restore_dir}" 2>/dev/null)" ]; then
        log_warning "Restore directory is not empty: ${restore_dir}"
        
        if [ "${AUTO_MODE}" = "true" ]; then
            log_warning "Overwriting directory (AUTO_MODE enabled)"
        else
            read -p "Continue and overwrite? (yes/no) " -n 3 -r
            echo
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log_error "Restore cancelled"
                return 1
            fi
        fi
    fi
    
    # Create restore directory if needed
    mkdir -p "${restore_dir}"
    
    log_info "Extracting repository files..."
    if tar -xzf "${repo_archive}" -C "${restore_dir}"; then
        log_success "Repository files restored"
        return 0
    else
        log_error "Failed to extract repository files"
        return 1
    fi
}

################################################################################
# Restore Git History
################################################################################

restore_git() {
    if [ "${RESTORE_GIT_HISTORY}" != "true" ]; then
        log_info "Skipping git history restore"
        return 0
    fi
    
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring git history to: ${restore_dir}"
    
    local git_bundle="${backup_dir}/metadata/repo.bundle"
    
    if [ ! -f "${git_bundle}" ]; then
        log_error "Git bundle not found in backup"
        return 1
    fi
    
    # Check if git is already initialized
    if [ -d "${restore_dir}/.git" ]; then
        log_info "Git repository already exists, fetching from bundle..."
        cd "${restore_dir}"
        git fetch "${git_bundle}" '*:*' 2>/dev/null || true
    else
        log_info "Creating new git repository from bundle..."
        git clone "${git_bundle}" "${restore_dir}" 2>/dev/null || true
    fi
    
    if [ -d "${restore_dir}/.git" ]; then
        log_success "Git history restored"
        return 0
    else
        log_error "Failed to restore git history"
        return 1
    fi
}

################################################################################
# Restore Configuration Files
################################################################################

restore_configs() {
    if [ "${RESTORE_CONFIGS}" != "true" ]; then
        log_info "Skipping configuration files restore"
        return 0
    fi
    
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "Restoring configuration files to: ${restore_dir}"
    
    if [ ! -d "${backup_dir}/configs" ]; then
        log_warning "Config directory not found in backup"
        return 0
    fi
    
    # Create restore directory if needed
    mkdir -p "${restore_dir}"
    
    # Copy all config files
    cp -r "${backup_dir}/configs"/* "${restore_dir}/" 2>/dev/null || true
    
    log_success "Configuration files restored"
    return 0
}

################################################################################
# Restore All
################################################################################

restore_all() {
    local backup_dir="$1"
    local restore_dir="${2:-.}"
    
    log_info "=========================================="
    log_info "Starting full restoration"
    log_info "Backup: $(basename "${backup_dir}")"
    log_info "Destination: ${restore_dir}"
    log_info "=========================================="
    
    # Verify backup first
    if ! verify_backup_integrity "${backup_dir}"; then
        if [ "${AUTO_MODE}" != "true" ]; then
            log_warning "Backup integrity check failed"
            read -p "Continue anyway? (yes/no) " -n 3 -r
            echo
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log_error "Restore cancelled"
                send_notifications "FAILED" "Restore cancelled due to integrity check failure"
                return 1
            fi
        fi
    fi
    
    echo ""
    
    # Restore in order
    restore_repository "${backup_dir}" "${restore_dir}" || { send_notifications "FAILED" "Repository restoration failed"; return 1; }
    echo ""
    
    restore_git "${backup_dir}" "${restore_dir}" || { send_notifications "FAILED" "Git history restoration failed"; return 1; }
    echo ""
    
    restore_configs "${backup_dir}" "${restore_dir}" || { send_notifications "FAILED" "Configuration restoration failed"; return 1; }
    echo ""
    
    # Cleanup temporary decrypted files
    if [ "${AUTO_CLEANUP_TEMP}" = "true" ]; then
        cleanup_temp_files "${backup_dir}"
    fi
    
    log_success "=========================================="
    log_success "Full restoration completed"
    log_success "=========================================="
    
    # Show backup report if available
    if [ -f "${backup_dir}/BACKUP_REPORT.txt" ]; then
        echo ""
        log_info "Original Backup Report:"
        cat "${backup_dir}/BACKUP_REPORT.txt"
    fi
    
    send_notifications "SUCCESS" "Repository successfully restored to ${restore_dir}"
}

################################################################################
# Cleanup Temporary Files
################################################################################

cleanup_temp_files() {
    local backup_dir="$1"
    
    log_info "Cleaning up temporary files..."
    
    find "${backup_dir}/repository" -name "repo_files_*.tar.gz" -type f ! -name "*.enc" 2>/dev/null | while read -r temp_file; do
        # Only remove if the .enc version exists
        if [ -f "${temp_file}.enc" ]; then
            rm -f "${temp_file}"
        fi
    done
    
    log_success "Temporary files cleaned up"
}

################################################################################
# Show Usage
################################################################################

show_usage() {
    cat << 'EOF'
Security-Automation Recovery Script with Automation Support

Usage: ./recovery.sh [OPTIONS]

Options:
  --list                         List available backups
  --restore-all [BACKUP]         Restore all from backup (uses latest if not specified)
  --restore-repository [BACKUP]  Restore repository files only
  --restore-git [BACKUP]         Restore git history only
  --restore-configs [BACKUP]     Restore configuration files only
  --verify-backup [BACKUP]       Verify backup integrity
  --auto                         Run in automatic mode (non-interactive)
  --configure                    Create or edit recovery configuration file
  --help                         Show this help message

Examples:
  ./recovery.sh --list
  ./recovery.sh --restore-all
  ./recovery.sh --restore-all backup_20260609_150000
  ./recovery.sh --restore-all backup_20260609_150000 /path/to/restore
  ./recovery.sh --auto                              # Automated recovery (for scripting)
  ./recovery.sh --verify-backup backup_20260609_150000

Configuration:
  Edit .recovery-config to customize:
  - Selective restore options
  - Email/webhook notifications
  - Temporary file cleanup
  - Decryption settings
  - Restore destination

EOF
}

################################################################################
# Edit Configuration
################################################################################

edit_config() {
    log_info "Editing recovery configuration file..."
    
    if [ -z "${EDITOR:-}" ]; then
        EDITOR="nano"
    fi
    
    "${EDITOR}" "${CONFIG_FILE}" || log_error "Failed to edit configuration file"
}

################################################################################
# Main Function
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
        --list)
            list_backups
            ;;
        --auto)
            AUTO_MODE=true
            local backup_dir
            backup_dir=$(find_backup_dir) || exit 1
            local restore_dir="${RESTORE_DESTINATION:-.}"
            restore_all "${backup_dir}" "${restore_dir}"
            ;;
        --configure)
            if [ -t 0 ]; then
                edit_config
            else
                log_error "Configuration editor requires interactive terminal"
                exit 1
            fi
            ;;
        --verify-backup)
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            verify_backup_integrity "${backup_dir}"
            exit $?
            ;;
        --restore-all)
            AUTO_MODE=false
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            local restore_dir="${3:-.}"
            restore_all "${backup_dir}" "${restore_dir}"
            ;;
        --restore-repository)
            AUTO_MODE=false
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            local restore_dir="${3:-.}"
            restore_repository "${backup_dir}" "${restore_dir}"
            ;;
        --restore-git)
            AUTO_MODE=false
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            local restore_dir="${3:-.}"
            restore_git "${backup_dir}" "${restore_dir}"
            ;;
        --restore-configs)
            AUTO_MODE=false
            local backup_dir
            backup_dir=$(find_backup_dir "${2:-}") || exit 1
            local restore_dir="${3:-.}"
            restore_configs "${backup_dir}" "${restore_dir}"
            ;;
        *)
            if [ -n "${command}" ]; then
                log_error "Unknown command: ${command}"
                echo ""
            fi
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"

#!/bin/bash
#===============================================================================
#
#          FILE: server-patching.sh
#
#         USAGE: ./server-patching.sh [OPTIONS]
#
#   DESCRIPTION: Automated server patching script for Proxmox VMs
#                - Manages snapshots on Proxmox hosts
#                - Runs custom update commands on each server
#                - Comprehensive logging and error tracking
#
#       OPTIONS: See show_help() function below
#
#  REQUIREMENTS: jq, ssh, bash 4+
#
#        AUTHOR: Generated for Oswald
#       CREATED: $(date +%Y-%m-%d)
#
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/servers.json"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/patching_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/summary_${TIMESTAMP}.txt"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Arrays to track results
declare -a SUCCESSFUL_SERVERS=()
declare -a FAILED_SERVERS=()
declare -a SKIPPED_SERVERS=()

# Global settings (loaded from config)
SSH_TIMEOUT=30
SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SNAPSHOT_NAME="server_patching"
DRY_RUN=false
SKIP_SNAPSHOTS=false
SKIP_UPDATES=false
SINGLE_SERVER=""

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    
    # Write to terminal with colors
    case ${level} in
        "INFO")
            echo -e "${BLUE}[${timestamp}]${NC} ${message}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[${timestamp}]${NC} ✓ ${message}"
            ;;
        "WARNING")
            echo -e "${YELLOW}[${timestamp}]${NC} ⚠ ${message}"
            ;;
        "ERROR")
            echo -e "${RED}[${timestamp}]${NC} ✗ ${message}"
            ;;
        "STEP")
            echo -e "${CYAN}[${timestamp}]${NC} → ${message}"
            ;;
        "HEADER")
            echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${CYAN}  ${message}${NC}"
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
            echo "" >> "${LOG_FILE}"
            echo "=== ${message} ===" >> "${LOG_FILE}"
            echo "" >> "${LOG_FILE}"
            ;;
        *)
            echo -e "[${timestamp}] ${message}"
            ;;
    esac
}

log_command_output() {
    local output="$1"
    local prefix="$2"
    
    if [[ -n "${output}" ]]; then
        while IFS= read -r line; do
            echo "    ${prefix}${line}" >> "${LOG_FILE}"
            echo -e "    ${CYAN}│${NC} ${line}"
        done <<< "${output}"
    fi
}

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automated server patching script for Proxmox VMs.

OPTIONS:
    -c, --config FILE       Use specified config file (default: servers.json)
    -s, --server NAME       Process only specified server
    -d, --dry-run           Show what would be done without executing
    --skip-snapshots        Skip snapshot operations
    --skip-updates          Skip update commands (useful for testing snapshots)
    -h, --help              Show this help message
    -v, --version           Show version information

EXAMPLES:
    $(basename "$0")                          # Run full patching on all servers
    $(basename "$0") -s web-server-01         # Patch only web-server-01
    $(basename "$0") -d                       # Dry run - show what would happen
    $(basename "$0") --skip-snapshots         # Skip snapshots, only run updates

CONFIGURATION:
    Edit servers.json to add/modify servers and Proxmox hosts.
    
    Each server entry supports:
    - Custom update commands (can be any commands you want to run)
    - Enable/disable individual servers
    - Different OS types and configurations

EOF
}

check_dependencies() {
    local deps=("jq" "ssh")
    local missing=()
    local optional_missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &> /dev/null; then
            missing+=("${dep}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing[*]}"
        log "INFO" "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
    
    # Check for sshpass (optional, only needed for password auth)
    if ! command -v "sshpass" &> /dev/null; then
        # Check if any server or proxmox host uses password auth
        local uses_password=$(jq -r '
            (.servers[] | select(.auth_method == "password")) // 
            (.proxmox_hosts[] | select(.auth_method == "password")) // 
            empty
        ' "${CONFIG_FILE}" 2>/dev/null)
        
        if [[ -n "${uses_password}" ]]; then
            log "WARNING" "sshpass not found but password authentication is configured"
            log "INFO" "Install with: sudo apt install sshpass"
            log "INFO" "Password authentication will fail without sshpass"
        fi
    fi
}

check_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log "ERROR" "Configuration file not found: ${CONFIG_FILE}"
        log "INFO" "Create servers.json with your server configuration"
        exit 1
    fi
    
    # Validate JSON
    if ! jq empty "${CONFIG_FILE}" 2>/dev/null; then
        log "ERROR" "Invalid JSON in configuration file: ${CONFIG_FILE}"
        exit 1
    fi
}

setup_logging() {
    mkdir -p "${LOG_DIR}"
    touch "${LOG_FILE}"
    touch "${SUMMARY_FILE}"
    
    log "INFO" "Logging to: ${LOG_FILE}"
}

load_settings() {
    SSH_TIMEOUT=$(jq -r '.settings.ssh_timeout // 30' "${CONFIG_FILE}")
    SSH_OPTIONS=$(jq -r '.settings.ssh_options // "-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"' "${CONFIG_FILE}")
    SNAPSHOT_NAME=$(jq -r '.settings.snapshot_name // "server_patching"' "${CONFIG_FILE}")
    
    local config_log_dir=$(jq -r '.settings.log_dir // "./logs"' "${CONFIG_FILE}")
    if [[ "${config_log_dir}" != "./logs" ]]; then
        LOG_DIR="${config_log_dir}"
    fi
}

#-------------------------------------------------------------------------------
# SSH Functions
#-------------------------------------------------------------------------------
build_ssh_command() {
    local auth_method=$1
    local ssh_key=$2
    local password=$3
    
    local ssh_cmd=""
    
    if [[ "${auth_method}" == "password" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            # In dry-run mode, just return a placeholder command
            ssh_cmd="sshpass -p '***' ssh ${SSH_OPTIONS}"
        elif ! command -v sshpass &> /dev/null; then
            log "ERROR" "sshpass is required for password authentication but not installed"
            return 1
        else
            ssh_cmd="sshpass -p '${password}' ssh ${SSH_OPTIONS}"
        fi
    else
        # Default to key-based auth
        ssh_cmd="ssh ${SSH_OPTIONS} -o BatchMode=yes"
        if [[ -n "${ssh_key}" && "${ssh_key}" != "null" ]]; then
            ssh_cmd="${ssh_cmd} -i ${ssh_key/#\~/$HOME}"
        fi
    fi
    
    echo "${ssh_cmd}"
}

ssh_execute() {
    local host=$1
    local user=$2
    local auth_method=$3
    local ssh_key=$4
    local password=$5
    local command=$6
    local description=$7
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_command "${auth_method}" "${ssh_key}" "${password}")
    
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "STEP" "[DRY RUN] Would execute on ${user}@${host}: ${command}"
        return 0
    fi
    
    log "STEP" "${description}"
    
    local output
    local exit_code
    
    output=$(eval "timeout ${SSH_TIMEOUT} ${ssh_cmd} '${user}@${host}' '${command}'" 2>&1)
    exit_code=$?
    
    if [[ -n "${output}" ]]; then
        log_command_output "${output}" ""
    fi
    
    return ${exit_code}
}

#-------------------------------------------------------------------------------
# Proxmox Functions
#-------------------------------------------------------------------------------
get_proxmox_connection() {
    local pve_name=$1
    
    local host=$(jq -r ".proxmox_hosts.${pve_name}.host" "${CONFIG_FILE}")
    local user=$(jq -r ".proxmox_hosts.${pve_name}.user" "${CONFIG_FILE}")
    local auth_method=$(jq -r ".proxmox_hosts.${pve_name}.auth_method // \"key\"" "${CONFIG_FILE}")
    local ssh_key=$(jq -r ".proxmox_hosts.${pve_name}.ssh_key" "${CONFIG_FILE}")
    local password=$(jq -r ".proxmox_hosts.${pve_name}.password" "${CONFIG_FILE}")
    
    echo "${host}|${user}|${auth_method}|${ssh_key}|${password}"
}

delete_snapshot() {
    local pve_name=$1
    local vmid=$2
    local server_name=$3
    
    local pve_conn=$(get_proxmox_connection "${pve_name}")
    local pve_host=$(echo "${pve_conn}" | cut -d'|' -f1)
    local pve_user=$(echo "${pve_conn}" | cut -d'|' -f2)
    local pve_auth_method=$(echo "${pve_conn}" | cut -d'|' -f3)
    local pve_key=$(echo "${pve_conn}" | cut -d'|' -f4)
    local pve_password=$(echo "${pve_conn}" | cut -d'|' -f5)
    
    log "STEP" "Checking for existing snapshot '${SNAPSHOT_NAME}' on VM ${vmid}"
    
    # Build SSH command based on auth method
    local ssh_cmd
    ssh_cmd=$(build_ssh_command "${pve_auth_method}" "${pve_key}" "${pve_password}")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to build SSH command for ${pve_name}"
        return 1
    fi
    
    # First check if snapshot exists
    local check_cmd="qm listsnapshot ${vmid} 2>/dev/null | grep -q '${SNAPSHOT_NAME}' && echo 'exists' || echo 'not_found'"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "STEP" "[DRY RUN] Would check and delete snapshot '${SNAPSHOT_NAME}' on VM ${vmid}"
        return 0
    fi
    
    local snapshot_status
    snapshot_status=$(eval "timeout ${SSH_TIMEOUT} ${ssh_cmd} '${pve_user}@${pve_host}' \"${check_cmd}\"" 2>&1)
    
    if [[ "${snapshot_status}" == "exists" ]]; then
        log "STEP" "Deleting existing snapshot '${SNAPSHOT_NAME}' on VM ${vmid}"
        
        local delete_cmd="qm delsnapshot ${vmid} ${SNAPSHOT_NAME} 2>&1"
        local output
        output=$(eval "timeout 300 ${ssh_cmd} '${pve_user}@${pve_host}' \"${delete_cmd}\"" 2>&1)
        local exit_code=$?
        
        if [[ -n "${output}" ]]; then
            log_command_output "${output}" ""
        fi
        
        if [[ ${exit_code} -ne 0 ]]; then
            log "ERROR" "Failed to delete snapshot for ${server_name} (VM ${vmid})"
            return 1
        fi
        
        log "SUCCESS" "Deleted old snapshot for ${server_name}"
    else
        log "INFO" "No existing snapshot '${SNAPSHOT_NAME}' found for VM ${vmid}"
    fi
    
    return 0
}

create_snapshot() {
    local pve_name=$1
    local vmid=$2
    local server_name=$3
    
    local pve_conn=$(get_proxmox_connection "${pve_name}")
    local pve_host=$(echo "${pve_conn}" | cut -d'|' -f1)
    local pve_user=$(echo "${pve_conn}" | cut -d'|' -f2)
    local pve_auth_method=$(echo "${pve_conn}" | cut -d'|' -f3)
    local pve_key=$(echo "${pve_conn}" | cut -d'|' -f4)
    local pve_password=$(echo "${pve_conn}" | cut -d'|' -f5)
    
    local description="Pre-patching snapshot - $(date '+%Y-%m-%d %H:%M:%S')"
    local snapshot_cmd="qm snapshot ${vmid} ${SNAPSHOT_NAME} --description '${description}' 2>&1"
    
    # Build SSH command based on auth method
    local ssh_cmd
    ssh_cmd=$(build_ssh_command "${pve_auth_method}" "${pve_key}" "${pve_password}")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to build SSH command for ${pve_name}"
        return 1
    fi
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "STEP" "[DRY RUN] Would create snapshot '${SNAPSHOT_NAME}' on VM ${vmid}"
        return 0
    fi
    
    log "STEP" "Creating snapshot '${SNAPSHOT_NAME}' for VM ${vmid}"
    
    local output
    output=$(eval "timeout 600 ${ssh_cmd} '${pve_user}@${pve_host}' \"${snapshot_cmd}\"" 2>&1)
    local exit_code=$?
    
    if [[ -n "${output}" ]]; then
        log_command_output "${output}" ""
    fi
    
    if [[ ${exit_code} -ne 0 ]]; then
        log "ERROR" "Failed to create snapshot for ${server_name} (VM ${vmid})"
        return 1
    fi
    
    log "SUCCESS" "Created new snapshot for ${server_name}"
    return 0
}

#-------------------------------------------------------------------------------
# Server Update Functions
#-------------------------------------------------------------------------------
run_update_commands() {
    local server_name=$1
    local ip=$2
    local user=$3
    local auth_method=$4
    local ssh_key=$5
    local password=$6
    local commands_json=$7
    
    # Build SSH command based on auth method
    local ssh_cmd
    ssh_cmd=$(build_ssh_command "${auth_method}" "${ssh_key}" "${password}")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to build SSH command for ${server_name}"
        return 1
    fi
    
    # Parse commands from JSON array
    local num_commands=$(echo "${commands_json}" | jq -r 'length')
    
    for ((i=0; i<num_commands; i++)); do
        local cmd=$(echo "${commands_json}" | jq -r ".[${i}]")
        
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "STEP" "[DRY RUN] Would execute: ${cmd}"
            continue
        fi
        
        log "STEP" "Executing: ${cmd}"
        
        local output
        local exit_code
        
        # Special handling for reboot command - don't wait for response
        if [[ "${cmd}" == *"reboot"* ]]; then
            log "INFO" "Initiating reboot (not waiting for completion)..."
            eval "timeout 10 ${ssh_cmd} '${user}@${ip}' '${cmd}'" 2>&1 || true
            log "SUCCESS" "Reboot command sent"
            continue
        fi
        
        output=$(eval "timeout 600 ${ssh_cmd} '${user}@${ip}' '${cmd}'" 2>&1)
        exit_code=$?
        
        if [[ -n "${output}" ]]; then
            # Truncate very long output for display
            local line_count=$(echo "${output}" | wc -l)
            if [[ ${line_count} -gt 50 ]]; then
                log "INFO" "Output truncated (${line_count} lines total, showing first 20 and last 10)"
                echo "${output}" | head -20 | while IFS= read -r line; do
                    echo "    ${CYAN}│${NC} ${line}"
                done
                echo "    ${CYAN}│${NC} ... (${line_count} lines total) ..."
                echo "${output}" | tail -10 | while IFS= read -r line; do
                    echo "    ${CYAN}│${NC} ${line}"
                done
                # Still log full output to file
                echo "${output}" >> "${LOG_FILE}"
            else
                log_command_output "${output}" ""
            fi
        fi
        
        if [[ ${exit_code} -ne 0 ]]; then
            log "ERROR" "Command failed with exit code ${exit_code}: ${cmd}"
            return 1
        fi
        
        log "SUCCESS" "Command completed: ${cmd}"
    done
    
    return 0
}

#-------------------------------------------------------------------------------
# Main Processing Function
#-------------------------------------------------------------------------------
process_server() {
    local server_json=$1
    
    local name=$(echo "${server_json}" | jq -r '.name')
    local vmid=$(echo "${server_json}" | jq -r '.vmid')
    local pve_host=$(echo "${server_json}" | jq -r '.proxmox_host')
    local ip=$(echo "${server_json}" | jq -r '.ip')
    local user=$(echo "${server_json}" | jq -r '.user')
    local auth_method=$(echo "${server_json}" | jq -r '.auth_method // "key"')
    local ssh_key=$(echo "${server_json}" | jq -r '.ssh_key')
    local password=$(echo "${server_json}" | jq -r '.password')
    local enabled=$(echo "${server_json}" | jq -r '.enabled')
    local commands=$(echo "${server_json}" | jq -c '.update_commands')
    
    log "HEADER" "Processing: ${name}"
    
    # Check if server is enabled
    if [[ "${enabled}" != "true" ]]; then
        log "WARNING" "Server ${name} is disabled, skipping"
        SKIPPED_SERVERS+=("${name} (disabled)")
        return 0
    fi
    
    log "INFO" "Server details:"
    log "INFO" "  VM ID: ${vmid}"
    log "INFO" "  Proxmox Host: ${pve_host}"
    log "INFO" "  IP: ${ip}"
    log "INFO" "  User: ${user}"
    log "INFO" "  Auth Method: ${auth_method}"
    
    # Step 1: Delete old snapshot
    if [[ "${SKIP_SNAPSHOTS}" != "true" ]]; then
        if ! delete_snapshot "${pve_host}" "${vmid}" "${name}"; then
            log "ERROR" "Snapshot deletion failed for ${name}, skipping server"
            FAILED_SERVERS+=("${name} (snapshot deletion failed)")
            return 1
        fi
        
        # Step 2: Create new snapshot
        if ! create_snapshot "${pve_host}" "${vmid}" "${name}"; then
            log "ERROR" "Snapshot creation failed for ${name}, skipping server"
            FAILED_SERVERS+=("${name} (snapshot creation failed)")
            return 1
        fi
    else
        log "INFO" "Skipping snapshot operations (--skip-snapshots)"
    fi
    
    # Step 3: Run update commands
    if [[ "${SKIP_UPDATES}" != "true" ]]; then
        if ! run_update_commands "${name}" "${ip}" "${user}" "${auth_method}" "${ssh_key}" "${password}" "${commands}"; then
            log "ERROR" "Update commands failed for ${name}"
            FAILED_SERVERS+=("${name} (update commands failed)")
            return 1
        fi
    else
        log "INFO" "Skipping update commands (--skip-updates)"
    fi
    
    log "SUCCESS" "Completed processing: ${name}"
    SUCCESSFUL_SERVERS+=("${name}")
    
    return 0
}

#-------------------------------------------------------------------------------
# Summary Functions
#-------------------------------------------------------------------------------
print_summary() {
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "HEADER" "PATCHING SUMMARY"
    
    echo "Patching completed at: ${end_time}" | tee -a "${SUMMARY_FILE}"
    echo "" | tee -a "${SUMMARY_FILE}"
    
    # Successful servers
    echo -e "${GREEN}━━━ SUCCESSFUL (${#SUCCESSFUL_SERVERS[@]}) ━━━${NC}" | tee -a "${SUMMARY_FILE}"
    if [[ ${#SUCCESSFUL_SERVERS[@]} -gt 0 ]]; then
        for server in "${SUCCESSFUL_SERVERS[@]}"; do
            echo -e "  ${GREEN}✓${NC} ${server}" | tee -a "${SUMMARY_FILE}"
        done
    else
        echo "  None" | tee -a "${SUMMARY_FILE}"
    fi
    echo "" | tee -a "${SUMMARY_FILE}"
    
    # Skipped servers
    echo -e "${YELLOW}━━━ SKIPPED (${#SKIPPED_SERVERS[@]}) ━━━${NC}" | tee -a "${SUMMARY_FILE}"
    if [[ ${#SKIPPED_SERVERS[@]} -gt 0 ]]; then
        for server in "${SKIPPED_SERVERS[@]}"; do
            echo -e "  ${YELLOW}○${NC} ${server}" | tee -a "${SUMMARY_FILE}"
        done
    else
        echo "  None" | tee -a "${SUMMARY_FILE}"
    fi
    echo "" | tee -a "${SUMMARY_FILE}"
    
    # Failed servers
    echo -e "${RED}━━━ FAILED (${#FAILED_SERVERS[@]}) ━━━${NC}" | tee -a "${SUMMARY_FILE}"
    if [[ ${#FAILED_SERVERS[@]} -gt 0 ]]; then
        for server in "${FAILED_SERVERS[@]}"; do
            echo -e "  ${RED}✗${NC} ${server}" | tee -a "${SUMMARY_FILE}"
        done
        echo "" | tee -a "${SUMMARY_FILE}"
        echo -e "${RED}${BOLD}⚠ ATTENTION: The above servers require manual intervention!${NC}" | tee -a "${SUMMARY_FILE}"
    else
        echo "  None" | tee -a "${SUMMARY_FILE}"
    fi
    
    echo "" | tee -a "${SUMMARY_FILE}"
    echo "Full log: ${LOG_FILE}" | tee -a "${SUMMARY_FILE}"
    echo "Summary: ${SUMMARY_FILE}" | tee -a "${SUMMARY_FILE}"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--server)
                SINGLE_SERVER="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-snapshots)
                SKIP_SNAPSHOTS=true
                shift
                ;;
            --skip-updates)
                SKIP_UPDATES=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "Server Patching Script v1.0.0"
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Initialize
    check_dependencies
    check_config
    setup_logging
    load_settings
    
    log "HEADER" "SERVER PATCHING STARTED"
    log "INFO" "Start time: ${start_time}"
    log "INFO" "Configuration: ${CONFIG_FILE}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "WARNING" "DRY RUN MODE - No changes will be made"
    fi
    
    if [[ "${SKIP_SNAPSHOTS}" == "true" ]]; then
        log "WARNING" "Snapshot operations will be skipped"
    fi
    
    if [[ "${SKIP_UPDATES}" == "true" ]]; then
        log "WARNING" "Update commands will be skipped"
    fi
    
    # Get servers list
    local servers
    if [[ -n "${SINGLE_SERVER}" ]]; then
        servers=$(jq -c ".servers[] | select(.name == \"${SINGLE_SERVER}\")" "${CONFIG_FILE}")
        if [[ -z "${servers}" ]]; then
            log "ERROR" "Server '${SINGLE_SERVER}' not found in configuration"
            exit 1
        fi
        log "INFO" "Processing single server: ${SINGLE_SERVER}"
    else
        servers=$(jq -c '.servers[]' "${CONFIG_FILE}")
    fi
    
    # Count enabled servers
    local total_servers=$(echo "${servers}" | wc -l)
    local enabled_servers=$(echo "${servers}" | jq -r 'select(.enabled == true)' | jq -s 'length')
    
    log "INFO" "Total servers in config: ${total_servers}"
    log "INFO" "Enabled servers: ${enabled_servers}"
    
    # Process each server
    local current=0
    while IFS= read -r server_json; do
        ((current++))
        local server_name=$(echo "${server_json}" | jq -r '.name')
        log "INFO" "Processing server ${current}/${total_servers}: ${server_name}"
        
        process_server "${server_json}"
        
        # Add a small delay between servers
        if [[ "${DRY_RUN}" != "true" ]] && [[ ${current} -lt ${total_servers} ]]; then
            log "INFO" "Waiting 5 seconds before next server..."
            sleep 5
        fi
    done <<< "${servers}"
    
    # Print summary
    print_summary
    
    # Exit with error code if any servers failed
    if [[ ${#FAILED_SERVERS[@]} -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

# Run main function
main "$@"
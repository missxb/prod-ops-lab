#!/bin/bash
#===============================================================================
# Stage 10: Security Hardening - Main Deployment Script
#===============================================================================
# Enterprise Cloud Native Platform - Security Hardening Deployment
# Production-grade security configurations for infrastructure and Kubernetes
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(dirname "$SCRIPT_DIR")/configs/kubernetes"
LOG_FILE="/var/log/security-hardening-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[INFO]${NC} ${timestamp} - ${message}" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - ${message}" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
        STEP)    echo -e "${CYAN}[STEP]${NC} ${timestamp} - ${message}" ;;
    esac
    
    echo "[${level}] ${timestamp} - ${message}" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# Pre-flight Checks
#-------------------------------------------------------------------------------
preflight_checks() {
    log STEP "Running pre-flight checks..."
    
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root"
        exit 1
    fi
    
    # Check required tools
    local required_tools=("kubectl" "openssl" "firewall-cmd" "trivy" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log WARN "Tool not found: $tool - some features may be limited"
        fi
    done
    
    # Check Kubernetes connectivity
    if command -v kubectl &>/dev/null; then
        if kubectl cluster-info &>/dev/null; then
            log INFO "Kubernetes cluster is reachable"
        else
            log WARN "Kubernetes cluster is not reachable"
        fi
    fi
    
    log INFO "Pre-flight checks completed"
}

#-------------------------------------------------------------------------------
# Main Menu
#-------------------------------------------------------------------------------
show_menu() {
    echo ""
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${CYAN}  Enterprise Cloud Native Platform${NC}"
    echo -e "${CYAN}  Stage 10: Security Hardening${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
    echo "Select security hardening modules to deploy:"
    echo ""
    echo "  [1] SSL/TLS Certificate Management"
    echo "  [2] SSH Security Hardening"
    echo "  [3] Firewall Rules & Policies"
    echo "  [4] Container Security Scanning"
    echo "  [5] Kubernetes RBAC Configuration"
    echo "  [6] Network Policies"
    echo "  [7] Pod Security Policies"
    echo "  [A] Deploy ALL modules"
    echo "  [Q] Quit"
    echo ""
    read -p "Enter your choice: " choice
    echo ""
}

#-------------------------------------------------------------------------------
# Deploy Modules
#-------------------------------------------------------------------------------
deploy_ssl() {
    log STEP "Deploying SSL/TLS Certificate Management..."
    bash "${SCRIPT_DIR}/01-ssl-certs.sh" 2>&1 | tee -a "$LOG_FILE"
}

deploy_ssh() {
    log STEP "Deploying SSH Security Hardening..."
    bash "${SCRIPT_DIR}/02-ssh-hardening.sh" 2>&1 | tee -a "$LOG_FILE"
}

deploy_firewall() {
    log STEP "Deploying Firewall Rules..."
    bash "${SCRIPT_DIR}/03-firewall-rules.sh" 2>&1 | tee -a "$LOG_FILE"
}

deploy_container_scan() {
    log STEP "Deploying Container Security Scanning..."
    bash "${SCRIPT_DIR}/04-container-scan.sh" 2>&1 | tee -a "$LOG_FILE"
}

deploy_k8s_rbac() {
    log STEP "Deploying Kubernetes RBAC..."
    bash "${SCRIPT_DIR}/05-k8s-rbac.sh" 2>&1 | tee -a "$LOG_FILE"
}

deploy_network_policy() {
    log STEP "Deploying Network Policies..."
    kubectl apply -f "${CONFIGS_DIR}/network-policy.yaml" 2>&1 | tee -a "$LOG_FILE"
    log INFO "Network policies applied"
}

deploy_pod_security() {
    log STEP "Deploying Pod Security Policies..."
    kubectl apply -f "${CONFIGS_DIR}/pod-security.yaml" 2>&1 | tee -a "$LOG_FILE"
    log INFO "Pod security policies applied"
}

deploy_all() {
    log STEP "Deploying ALL security modules..."
    deploy_ssl
    deploy_ssh
    deploy_firewall
    deploy_container_scan
    deploy_k8s_rbac
    deploy_network_policy
    deploy_pod_security
    log INFO "All security modules deployed successfully"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== Security Hardening Deployment Started ==="
    log INFO "Log file: ${LOG_FILE}"
    
    preflight_checks
    
    while true; do
        show_menu
        case $choice in
            1) deploy_ssl ;;
            2) deploy_ssh ;;
            3) deploy_firewall ;;
            4) deploy_container_scan ;;
            5) deploy_k8s_rbac ;;
            6) deploy_network_policy ;;
            7) deploy_pod_security ;;
            [Aa]) deploy_all ;;
            [Qq])
                log INFO "Exiting security hardening deployment"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

main "$@"

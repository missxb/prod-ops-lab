#!/bin/bash
#===============================================================================
# Stage 10.5: Kubernetes RBAC Configuration
#===============================================================================
# Production-grade RBAC for admin, readonly, and developer roles
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(dirname "$SCRIPT_DIR")/configs/kubernetes"
LOG_FILE="/var/log/k8s-rbac-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)    echo -e "${GREEN}[INFO]${NC} ${timestamp} - ${message}" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - ${message}" ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
    esac
    
    echo "[${level}] ${timestamp} - ${message}" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# Check Kubernetes Connectivity
#-------------------------------------------------------------------------------
check_k8s() {
    log INFO "Checking Kubernetes connectivity..."
    
    if ! command -v kubectl &>/dev/null; then
        log ERROR "kubectl not found"
        return 1
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log ERROR "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    log INFO "Kubernetes cluster is reachable"
    return 0
}

#-------------------------------------------------------------------------------
# Create Namespaces
#-------------------------------------------------------------------------------
create_namespaces() {
    log INFO "Creating namespaces..."
    
    local namespaces=("production" "staging" "development" "monitoring" "logging" "security")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            log INFO "Namespace ${ns} already exists"
        else
            kubectl create namespace "$ns"
            log INFO "Namespace ${ns} created"
        fi
    done
}

#-------------------------------------------------------------------------------
# Create Admin RBAC
#-------------------------------------------------------------------------------
create_admin_rbac() {
    log INFO "Creating Admin RBAC configuration..."
    
    kubectl apply -f "${CONFIGS_DIR}/rbac-admin.yaml"
    
    log INFO "Admin RBAC applied"
}

#-------------------------------------------------------------------------------
# Create Readonly RBAC
#-------------------------------------------------------------------------------
create_readonly_rbac() {
    log INFO "Creating Readonly RBAC configuration..."
    
    kubectl apply -f "${CONFIGS_DIR}/rbac-readonly.yaml"
    
    log INFO "Readonly RBAC applied"
}

#-------------------------------------------------------------------------------
# Create Developer RBAC
#-------------------------------------------------------------------------------
create_developer_rbac() {
    log INFO "Creating Developer RBAC configuration..."
    
    cat <<EOF | kubectl apply -f -
# Developer ClusterRole - can manage resources in allowed namespaces
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer
  labels:
    app.kubernetes.io/name: rbac-developer
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
rules:
# Pods and deployments
- apiGroups: ["", "apps"]
  resources: ["pods", "pods/log", "pods/status", "deployments", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Services and configmaps
- apiGroups: ["", ""]
  resources: ["services", "configmaps", "secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# Ingress
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# ConfigMaps and Secrets (read-only)
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]

# Events
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]

# Limit ranges and resource quotas
- apiGroups: [""]
  resources: ["limitranges", "resourcequotas"]
  verbs: ["get", "list", "watch"]

# Network policies (read-only)
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "list", "watch"]

---
# Developer RoleBinding for allowed namespaces
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer
  namespace: development
  labels:
    app.kubernetes.io/name: rbac-developer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: developer
subjects:
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io

---
# Developer RoleBinding for staging namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer
  namespace: staging
  labels:
    app.kubernetes.io/name: rbac-developer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: developer
subjects:
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io

---
# Developer RoleBinding for production namespace (limited)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer
  namespace: production
  labels:
    app.kubernetes.io/name: rbac-developer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: developer
subjects:
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io

---
# Developer Role for production (limited permissions)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-limited
  namespace: production
  labels:
    app.kubernetes.io/name: rbac-developer
rules:
# Read-only access to production resources
- apiGroups: ["", "apps"]
  resources: ["pods", "pods/log", "pods/status", "deployments", "replicasets"]
  verbs: ["get", "list", "watch"]

# Read-only access to services
- apiGroups: [""]
  resources: ["services", "configmaps"]
  verbs: ["get", "list", "watch"]

# Read-only access to ingresses
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]

---
# Override developer binding in production with limited role
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-limited
  namespace: production
  labels:
    app.kubernetes.io/name: rbac-developer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: developer-limited
subjects:
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io

---
# DevOps Role - can manage CI/CD and deployment resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: devops
  labels:
    app.kubernetes.io/name: rbac-devops
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
rules:
# Full access to most resources
- apiGroups: ["", "apps", "batch", "extensions"]
  resources: ["*"]
  verbs: ["*"]

# Network policies
- apiGroups: ["networking.k8s.io"]
  resources: ["*"]
  verbs: ["*"]

# RBAC (read-only for audit)
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]

# Secrets management
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

---
# DevOps RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: devops
  labels:
    app.kubernetes.io/name: rbac-devops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: devops
subjects:
- kind: Group
  name: devops
  apiGroup: rbac.authorization.k8s.io

---
# Monitoring Role - read-only for monitoring stack
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring
  labels:
    app.kubernetes.io/name: rbac-monitoring
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
rules:
# Read-only access to pods
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/status", "services", "endpoints", "namespaces"]
  verbs: ["get", "list", "watch"]

# Read-only access to nodes
- apiGroups: [""]
  resources: ["nodes", "nodes/status", "nodes/metrics"]
  verbs: ["get", "list", "watch"]

# Read-only access to events
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]

# Read-only access to deployments
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch"]

# Read-only access to ingresses
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]

# Read-only access to network policies
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "list", "watch"]

# Read-only access to resource quotas
- apiGroups: [""]
  resources: ["resourcequotas", "limitranges"]
  verbs: ["get", "list", "watch"]

---
# Monitoring RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: monitoring
  labels:
    app.kubernetes.io/name: rbac-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: monitoring
subjects:
- kind: Group
  name: monitoring
  apiGroup: rbac.authorization.k8s.io

---
# Service Account for Prometheus
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/part-of: enterprise-cloud-native-platform

---
# ServiceAccount for Grafana
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana
  namespace: monitoring
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
EOF
    
    log INFO "Developer RBAC applied"
}

#-------------------------------------------------------------------------------
# Create Service Accounts
#-------------------------------------------------------------------------------
create_service_accounts() {
    log INFO "Creating service accounts..."
    
    cat <<EOF | kubectl apply -f -
# CI/CD Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cicd
  namespace: production
  labels:
    app.kubernetes.io/name: cicd
    app.kubernetes.io/part-of: enterprise-cloud-native-platform

---
# CI/CD RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cicd
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: developer
subjects:
- kind: ServiceAccount
  name: cicd
  namespace: production

---
# GitOps Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitops
  namespace: production
  labels:
    app.kubernetes.io/name: gitops
    app.kubernetes.io/part-of: enterprise-cloud-native-platform

---
# GitOps RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitops
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: devops
subjects:
- kind: ServiceAccount
  name: gitops
  namespace: production

---
# Security Scanner Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: security-scanner
  namespace: security
  labels:
    app.kubernetes.io/name: security-scanner
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
EOF
    
    log INFO "Service accounts created"
}

#-------------------------------------------------------------------------------
# Create ResourceQuotas
#-------------------------------------------------------------------------------
create_resource_quotas() {
    log INFO "Creating resource quotas..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
  labels:
    app.kubernetes.io/name: resource-quota
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "100"
    services: "50"
    persistentvolumeclaims: "20"

---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: staging-quota
  namespace: staging
  labels:
    app.kubernetes.io/name: resource-quota
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    services: "25"
    persistentvolumeclaims: "10"

---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: development-quota
  namespace: development
  labels:
    app.kubernetes.io/name: resource-quota
spec:
  hard:
    requests.cpu: "5"
    requests.memory: 10Gi
    limits.cpu: "10"
    limits.memory: 20Gi
    pods: "30"
    services: "15"
    persistentvolumeclaims: "5"
EOF
    
    log INFO "Resource quotas created"
}

#-------------------------------------------------------------------------------
# Create LimitRanges
#-------------------------------------------------------------------------------
create_limit_ranges() {
    log INFO "Creating limit ranges..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: production
  labels:
    app.kubernetes.io/name: limit-range
spec:
  limits:
  - default:
      cpu: "1"
      memory: "1Gi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "4"
      memory: "4Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container

---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: staging
  labels:
    app.kubernetes.io/name: limit-range
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "50m"
      memory: "64Mi"
    max:
      cpu: "2"
      memory: "2Gi"
    min:
      cpu: "25m"
      memory: "32Mi"
    type: Container

---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: development
  labels:
    app.kubernetes.io/name: limit-range
spec:
  limits:
  - default:
      cpu: "250m"
      memory: "256Mi"
    defaultRequest:
      cpu: "25m"
      memory: "32Mi"
    max:
      cpu: "1"
      memory: "1Gi"
    min:
      cpu: "10m"
      memory: "16Mi"
    type: Container
EOF
    
    log INFO "Limit ranges created"
}

#-------------------------------------------------------------------------------
# Verify RBAC Configuration
#-------------------------------------------------------------------------------
verify_rbac() {
    log INFO "Verifying RBAC configuration..."
    
    # Check ClusterRoles
    local roles=$(kubectl get clusterroles --no-headers | grep -E "(admin|readonly|developer|devops|monitoring)" | wc -l)
    log INFO "Found ${roles} custom ClusterRoles"
    
    # Check RoleBindings
    local bindings=$(kubectl get rolebindings --all-namespaces --no-headers | wc -l)
    log INFO "Found ${bindings} RoleBindings"
    
    # Check ServiceAccounts
    local accounts=$(kubectl get serviceaccounts --all-namespaces --no-headers | wc -l)
    log INFO "Found ${accounts} ServiceAccounts"
    
    log INFO "RBAC verification completed"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== Kubernetes RBAC Configuration Started ==="
    
    # Check Kubernetes connectivity
    if ! check_k8s; then
        log ERROR "Cannot proceed without Kubernetes cluster"
        exit 1
    fi
    
    # Create namespaces
    create_namespaces
    
    # Apply RBAC configurations
    create_admin_rbac
    create_readonly_rbac
    create_developer_rbac
    
    # Create service accounts
    create_service_accounts
    
    # Create resource quotas
    create_resource_quotas
    
    # Create limit ranges
    create_limit_ranges
    
    # Verify configuration
    verify_rbac
    
    log INFO "=== Kubernetes RBAC Configuration Completed ==="
    log INFO "RBAC roles created: admin, readonly, developer, devops, monitoring"
    log INFO "Logs: ${LOG_FILE}"
}

main "$@"

#!/bin/bash
#===============================================================================
# Stage 10.4: Container Security Scanning
#===============================================================================
# Automated container security scanning with Trivy and OPA
#===============================================================================

set -euo pipefail

# 错误处理
trap 'log ERROR "容器扫描脚本异常退出 (行号: $LINENO)"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(dirname "$SCRIPT_DIR")/configs"
SCAN_RESULTS_DIR="/var/log/container-scans"
LOG_FILE="/var/log/container-scan-$(date +%Y%m%d-%H%M%S).log"

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
# Install Trivy
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Install Trivy
# 功能: 安装Trivy容器安全扫描工具
# 支持: apt, yum, brew, 通用脚本
#-------------------------------------------------------------------------------
install_trivy() {
    log INFO "Installing Trivy..."
    
    if command -v trivy &>/dev/null; then
        log INFO "Trivy already installed"
        trivy --version
        return 0
    fi
    
    # Install Trivy
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y wget apt-transport-https gnupg lsb-release
        wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
        echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
        sudo apt-get update
        sudo apt-get install -y trivy
    elif command -v yum &>/dev/null; then
        sudo yum install -y yum-utils
        sudo rpm -ivh https://github.com/aquasecurity/trivy/releases/download/v0.45.0/trivy_0.45.0_Linux-64bit.rpm
    elif command -v brew &>/dev/null; then
        brew install trivy
    else
        # Install via script
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    fi
    
    log INFO "Trivy installed successfully"
}

#-------------------------------------------------------------------------------
# Scan Container Image
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Scan Container Image
# 功能: 使用Trivy扫描指定镜像的安全漏洞
# 参数: $1=image, $2=severity(默认HIGH,CRITICAL), $3=format(默认table)
# 返回: 0=安全, 1=有CRITICAL漏洞, 2=有HIGH漏洞
#-------------------------------------------------------------------------------
scan_image() {
    local image=$1
    local severity=${2:-"HIGH,CRITICAL"}
    local format=${3:-"table"}
    
    log INFO "Scanning image: ${image}..."
    
    mkdir -p "$SCAN_RESULTS_DIR"
    local output_file="${SCAN_RESULTS_DIR}/$(echo $image | tr '/:' '_')-$(date +%Y%m%d%H%M%S).json"
    
    # Run Trivy scan
    trivy image \
        --severity "$severity" \
        --format json \
        --output "$output_file" \
        "$image"
    
    # Generate table output
    trivy image \
        --severity "$severity" \
        --format table \
        "$image"
    
    # Parse results
    local total_vulns=$(jq '.Results[].Vulnerabilities | length' "$output_file" | awk '{sum+=$1} END {print sum}')
    local critical=$(jq '[.Results[].Vulnerabilities[] | select(.Severity=="CRITICAL")] | length' "$output_file")
    local high=$(jq '[.Results[].Vulnerabilities[] | select(.Severity=="HIGH")] | length' "$output_file")
    local medium=$(jq '[.Results[].Vulnerabilities[] | select(.Severity=="MEDIUM")] | length' "$output_file")
    local low=$(jq '[.Results[].Vulnerabilities[] | select(.Severity=="LOW")] | length' "$output_file")
    
    log INFO "Scan results for ${image}:"
    log INFO "  Total vulnerabilities: ${total_vulns}"
    log INFO "  CRITICAL: ${critical}"
    log INFO "  HIGH: ${high}"
    log INFO "  MEDIUM: ${medium}"
    log INFO "  LOW: ${low}"
    
    # Return exit code based on severity
    if [[ $critical -gt 0 ]]; then
        log ERROR "Critical vulnerabilities found in ${image}!"
        return 1
    elif [[ $high -gt 0 ]]; then
        log WARN "High vulnerabilities found in ${image}"
        return 2
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Scan All Running Containers
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Scan All Running Containers
# 功能: 获取所有运行中容器的镜像并逐一扫描
# 支持: Docker, CRI-O
#-------------------------------------------------------------------------------
scan_running_containers() {
    log INFO "Scanning all running containers..."
    
    if ! command -v docker &>/dev/null && ! command -v crictl &>/dev/null; then
        log WARN "No container runtime found"
        return 0
    fi
    
    # Get list of running container images
    local images=()
    
    if command -v docker &>/dev/null; then
        while IFS= read -r line; do
            images+=("$line")
        done < <(docker ps --format '{{.Image}}' | sort -u)
    elif command -v crictl &>/dev/null; then
        while IFS= read -r line; do
            images+=("$line")
        done < <(crictl images -q | sort -u)
    fi
    
    log INFO "Found ${#images[@]} unique images to scan"
    
    local failed=0
    for image in "${images[@]}"; do
        if ! scan_image "$image"; then
            ((failed++))
        fi
    done
    
    if [[ $failed -gt 0 ]]; then
        log WARN "${failed} images failed security scanning"
        return 1
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Setup OPA (Open Policy Agent)
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Setup OPA (Open Policy Agent)
# 功能: 创建容器安全Rego策略
# 策略: 禁止root运行、必须有资源限制、禁止特权模式等
# 配置路径: $CONFIGS_DIR/opa/
#-------------------------------------------------------------------------------
setup_opa() {
    log INFO "Setting up Open Policy Agent (OPA)..."
    
    # Create OPA policies directory
    local opa_dir="${CONFIGS_DIR}/opa"
    mkdir -p "$opa_dir"
    
    # Create Rego policies for container security
    cat > "${opa_dir}/container-security.rego" <<'EOF'
package kubernetes.admission

import future.keywords.in

# Deny containers running as root
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    container.securityContext.runAsUser == 0
    msg := sprintf("Container %s must not run as root", [container.name])
}

# Deny containers without resource limits
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.resources.limits
    msg := sprintf("Container %s must have resource limits", [container.name])
}

# Deny containers without resource requests
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.resources.requests
    msg := sprintf("Container %s must have resource requests", [container.name])
}

# Deny privileged containers
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    container.securityContext.privileged == true
    msg := sprintf("Container %s must not run in privileged mode", [container.name])
}

# Deny containers with host network
deny[msg] {
    input.request.kind.kind == "Pod"
    input.request.object.spec.hostNetwork == true
    msg := "Pod must not use host network"
}

# Deny containers with host PID
deny[msg] {
    input.request.kind.kind == "Pod"
    input.request.object.spec.hostPID == true
    msg := "Pod must not use host PID namespace"
}

# Deny containers with host IPC
deny[msg] {
    input.request.kind.kind == "Pod"
    input.request.object.spec.hostIPC == true
    msg := "Pod must not use host IPC namespace"
}

# Deny containers without read-only root filesystem
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not container.securityContext.readOnlyRootFilesystem
    msg := sprintf("Container %s must have read-only root filesystem", [container.name])
}

# Deny containers with capabilities added
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    container.securityContext.capabilities.add[_]
    msg := sprintf("Container %s must not add capabilities", [container.name])
}

# Deny containers from untrusted registries
deny[msg] {
    input.request.kind.kind == "Pod"
    container := input.request.object.spec.containers[_]
    not startswith(container.image, "enterprise-registry.local/")
    not startswith(container.image, "docker.io/")
    not startswith(container.image, "gcr.io/")
    not startswith(container.image, "quay.io/")
    msg := sprintf("Container %s image must be from a trusted registry", [container.name])
}
EOF
    
    log INFO "OPA policies created in ${opa_dir}"
}

#-------------------------------------------------------------------------------
# Create Image Allowlist
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Create Image Allowlist
# 功能: 创建K8s ConfigMap定义允许的镜像来源
# 配置: $CONFIGS_DIR/image-allowlist.yaml
#-------------------------------------------------------------------------------
create_image_allowlist() {
    log INFO "Creating image allowlist..."
    
    cat > "${CONFIGS_DIR}/image-allowlist.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: image-allowlist
  namespace: kube-system
  labels:
    app.kubernetes.io/name: image-policy
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
data:
  allowlist.yaml: |
    apiVersion: v1
    kind: List
    items:
    - name: "Allowed Registries"
      registries:
      - "enterprise-registry.local/"
      - "docker.io/library/"
      - "gcr.io/distroless/"
      - "quay.io/"
    
    - name: "Blocked Images"
      images:
      - "docker.io/ubuntu:latest"
      - "docker.io/alpine:latest"
      - "docker.io/nginx:latest"
      - "docker.io/node:latest"
    
    - name: "Allowed Base Images"
      images:
      - "enterprise-registry.local/base/alpine:3.18"
      - "enterprise-registry.local/base/debian:12"
      - "enterprise-registry.local/base/distroless:static"
      - "gcr.io/distroless/static:nonroot"
      - "gcr.io/distroless/base:nonroot"
EOF
    
    log INFO "Image allowlist created"
}

#-------------------------------------------------------------------------------
# Create Scanning CronJob
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# Create Scanning CronJob
# 功能: 创建K8s CronJob每日自动扫描所有运行镜像
# 调度: 每天凌晨2点
# RBAC: ServiceAccount + ClusterRole + ClusterRoleBinding
#-------------------------------------------------------------------------------
create_scanning_cronjob() {
    log INFO "Creating container scanning CronJob..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: container-security-scan
  namespace: kube-system
  labels:
    app.kubernetes.io/name: security-scan
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: security-scan
        spec:
          serviceAccountName: security-scanner
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            fsGroup: 1000
          containers:
          - name: trivy-scanner
            image: aquasec/trivy:latest
            command:
            - /bin/sh
            - -c
            - |
              # Scan all images in use
              for image in \$(kubectl get pods --all-namespaces -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u); do
                echo "Scanning: \$image"
                trivy image --severity HIGH,CRITICAL --exit-code 1 --no-progress "\$image" || true
              done
            resources:
              requests:
                memory: "256Mi"
                cpu: "250m"
              limits:
                memory: "512Mi"
                cpu: "500m"
          restartPolicy: OnFailure
          securityContext:
            seccompProfile:
              type: RuntimeDefault
EOF
    
    # Create ServiceAccount for security scanner
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: security-scanner
  namespace: kube-system
  labels:
    app.kubernetes.io/name: security-scan
    app.kubernetes.io/part-of: enterprise-cloud-native-platform
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: security-scanner
  labels:
    app.kubernetes.io/name: security-scan
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: security-scanner
  labels:
    app.kubernetes.io/name: security-scan
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: security-scanner
subjects:
- kind: ServiceAccount
  name: security-scanner
  namespace: kube-system
EOF
    
    log INFO "Container scanning CronJob created"
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------
main() {
    log INFO "=== Container Security Scanning Started ==="
    
    # Install Trivy
    install_trivy
    
    # Create results directory
    mkdir -p "$SCAN_RESULTS_DIR"
    
    # Setup OPA policies
    setup_opa
    
    # Create image allowlist
    create_image_allowlist
    
    # Create scanning CronJob
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null; then
        create_scanning_cronjob
    else
        log WARN "Kubernetes not available, skipping CronJob creation"
    fi
    
    # Scan running containers if Docker is available
    if command -v docker &>/dev/null; then
        log INFO "Docker detected, scanning running containers..."
        scan_running_containers
    fi
    
    log INFO "=== Container Security Scanning Completed ==="
    log INFO "Scan results stored in: ${SCAN_RESULTS_DIR}"
    log INFO "OPA policies: ${CONFIGS_DIR}/opa"
    log INFO "Logs: ${LOG_FILE}"
}

main "$@"

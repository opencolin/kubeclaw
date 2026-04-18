#!/bin/bash
# KubeClaw: Setup Nebius Managed Kubernetes cluster
# Creates VPC, subnet, mk8s cluster, and optional GPU node group

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="kubeclaw-prod"
K8S_VERSION="1.31"
NODE_COUNT=2
CPU_PLATFORM="cpu-e2"
CPU_PRESET="4vcpu-16gb"
ENABLE_GPU=false
GPU_PLATFORM="gpu-h100-sxm"
GPU_PRESET="1gpu-16vcpu-200gb"
GPU_NODE_COUNT=1
CIDR_BLOCK="10.0.0.0/24"
PROJECT_ID=""

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Creates a Nebius VPC, subnet, mk8s cluster, and optional GPU node group.

Options:
  --cluster-name NAME        Cluster name (default: kubeclaw-prod)
  --project-id ID            Nebius project ID (required; or set NEBIUS_PROJECT_ID)
  --k8s-version VER          Kubernetes version (default: 1.31)
  --node-count N             CPU node count (default: 2)
  --cpu-platform PLATFORM    CPU platform (default: cpu-e2)
  --cpu-preset PRESET        CPU preset (default: 4vcpu-16gb)
  --enable-gpu               Also create GPU node group
  --gpu-platform PLATFORM    GPU platform (default: gpu-h100-sxm)
                             Options: gpu-h100-sxm, gpu-h200-sxm, gpu-b200-sxm, gpu-l40s
  --gpu-preset PRESET        GPU preset (default: 1gpu-16vcpu-200gb)
  --gpu-node-count N         GPU node count (default: 1)
  --cidr CIDR                Subnet CIDR (default: 10.0.0.0/24)
  -h, --help                 Show this help

Examples:
  # Basic cluster
  $0 --project-id project-e00abc...

  # With GPU node group
  $0 --project-id project-e00abc... --enable-gpu

  # Custom GPU
  $0 --project-id project-e00abc... --enable-gpu --gpu-platform gpu-h200-sxm
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --k8s-version) K8S_VERSION="$2"; shift 2 ;;
    --node-count) NODE_COUNT="$2"; shift 2 ;;
    --cpu-platform) CPU_PLATFORM="$2"; shift 2 ;;
    --cpu-preset) CPU_PRESET="$2"; shift 2 ;;
    --enable-gpu) ENABLE_GPU=true; shift ;;
    --gpu-platform) GPU_PLATFORM="$2"; shift 2 ;;
    --gpu-preset) GPU_PRESET="$2"; shift 2 ;;
    --gpu-node-count) GPU_NODE_COUNT="$2"; shift 2 ;;
    --cidr) CIDR_BLOCK="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_error "Unknown option: $1" ;;
  esac
done

# Check nebius CLI
if ! command -v nebius &> /dev/null; then
  log_error "nebius CLI not found. Install: curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash"
fi

if ! nebius iam whoami --format json &> /dev/null; then
  log_error "Not authenticated. Run: nebius profile create"
fi

# Resolve project ID
PROJECT_ID="${PROJECT_ID:-$NEBIUS_PROJECT_ID}"
if [ -z "$PROJECT_ID" ]; then
  log_error "Project ID required. Pass --project-id or set NEBIUS_PROJECT_ID."
fi

log_info "Using project: $PROJECT_ID"

# 1. Create VPC network
log_info "Creating VPC network..."
NETWORK_NAME="${CLUSTER_NAME}-network"
NETWORK_OUT=$(nebius vpc network create \
  --name "$NETWORK_NAME" \
  --parent-id "$PROJECT_ID" \
  --format json 2>&1 || echo "")

NETWORK_ID=$(echo "$NETWORK_OUT" | grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

if [ -z "$NETWORK_ID" ]; then
  # Maybe exists — look it up
  log_warn "Network create failed or exists; looking up..."
  NETWORK_ID=$(nebius vpc network get-by-name --name "$NETWORK_NAME" --parent-id "$PROJECT_ID" --format json 2>/dev/null | \
    grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

[ -z "$NETWORK_ID" ] && log_error "Failed to create/find network"
log_info "✓ Network ID: $NETWORK_ID"

# 2. Create subnet
log_info "Creating subnet..."
SUBNET_NAME="${CLUSTER_NAME}-subnet"
SUBNET_OUT=$(nebius vpc subnet create \
  --name "$SUBNET_NAME" \
  --parent-id "$PROJECT_ID" \
  --network-id "$NETWORK_ID" \
  --ipv4-cidr-blocks "[\"$CIDR_BLOCK\"]" \
  --format json 2>&1 || echo "")

SUBNET_ID=$(echo "$SUBNET_OUT" | grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

if [ -z "$SUBNET_ID" ]; then
  log_warn "Subnet create failed or exists; looking up..."
  SUBNET_ID=$(nebius vpc subnet get-by-name --name "$SUBNET_NAME" --parent-id "$PROJECT_ID" --format json 2>/dev/null | \
    grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
fi

[ -z "$SUBNET_ID" ] && log_error "Failed to create/find subnet"
log_info "✓ Subnet ID: $SUBNET_ID"

# 3. Create mk8s cluster
log_info "Creating mk8s cluster: $CLUSTER_NAME (version $K8S_VERSION)..."
CLUSTER_OUT=$(nebius mk8s cluster create \
  --name "$CLUSTER_NAME" \
  --parent-id "$PROJECT_ID" \
  --control-plane-subnet-id "$SUBNET_ID" \
  --control-plane-version "$K8S_VERSION" \
  --control-plane-endpoints-public-endpoint \
  --format json)

CLUSTER_ID=$(echo "$CLUSTER_OUT" | grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
[ -z "$CLUSTER_ID" ] && log_error "Failed to create cluster"
log_info "✓ Cluster ID: $CLUSTER_ID"

log_info "Waiting for cluster to become ready (this may take 5-10 minutes)..."
# Poll status (simplified - production would parse JSON status field)
for i in {1..60}; do
  STATUS=$(nebius mk8s cluster get --id "$CLUSTER_ID" --format json 2>/dev/null | \
    grep -oE '"state":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  [ "$STATUS" = "RUNNING" ] && break
  sleep 10
done

# 4. Create CPU node group
log_info "Creating CPU node group..."
nebius mk8s node-group create \
  --parent-id "$CLUSTER_ID" \
  --name "${CLUSTER_NAME}-cpu" \
  --fixed-node-count "$NODE_COUNT" \
  --template-resources-platform "$CPU_PLATFORM" \
  --template-resources-preset "$CPU_PRESET" \
  --format json > /dev/null

log_info "✓ CPU node group created"

# 5. Create GPU node group (optional)
if [ "$ENABLE_GPU" = true ]; then
  log_info "Creating GPU node group ($GPU_PLATFORM / $GPU_PRESET)..."
  nebius mk8s node-group create \
    --parent-id "$CLUSTER_ID" \
    --name "${CLUSTER_NAME}-gpu" \
    --fixed-node-count "$GPU_NODE_COUNT" \
    --template-resources-platform "$GPU_PLATFORM" \
    --template-resources-preset "$GPU_PRESET" \
    --format json > /dev/null
  log_info "✓ GPU node group created"
fi

# 6. Fetch kubeconfig
log_info "Fetching kubeconfig..."
KUBECONFIG_PATH="$HOME/.kube/${CLUSTER_NAME}.yaml"
mkdir -p "$HOME/.kube"
nebius mk8s cluster get-credentials --id "$CLUSTER_ID" --external > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo
echo "================================================================"
log_info "Nebius mk8s cluster ready!"
echo "================================================================"
echo "  Cluster:      $CLUSTER_NAME"
echo "  Cluster ID:   $CLUSTER_ID"
echo "  Network ID:   $NETWORK_ID"
echo "  Subnet ID:    $SUBNET_ID"
echo "  Kubeconfig:   $KUBECONFIG_PATH"
echo
echo "Next steps:"
echo "  export KUBECONFIG=$KUBECONFIG_PATH"
echo "  kubectl get nodes"
echo "  ./scripts/install-kubeclaw.sh $([ "$ENABLE_GPU" = true ] && echo '--enable-gpu')"
echo

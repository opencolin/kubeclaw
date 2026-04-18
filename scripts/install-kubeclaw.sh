#!/bin/bash
# KubeClaw Installation Script
# One-command deployment of OpenClaw to Nebius Managed Kubernetes

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="kubeclaw-prod"
NAMESPACE="kubeclaw"
ENABLE_GPU=false
ENABLE_MONITORING=true
GPU_PLATFORM="gpu-h100-sxm"
GPU_PRESET="1gpu-16vcpu-200gb"
DRY_RUN=false

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  -c, --cluster-name NAME      Existing mk8s cluster name (default: kubeclaw-prod)
  -n, --namespace NS           Kubernetes namespace (default: kubeclaw)
  -g, --enable-gpu             Enable GPU support in Helm values
  -p, --gpu-platform PLATFORM  GPU platform: gpu-h100-sxm, gpu-h200-sxm, gpu-b200-sxm, gpu-l40s
                               (default: gpu-h100-sxm)
  -r, --gpu-preset PRESET      Resource preset (default: 1gpu-16vcpu-200gb)
  -m, --disable-monitoring     Disable monitoring stack
  --dry-run                    Show what would be done, don't deploy
  -h, --help                   Show this help

This script installs OpenClaw to an EXISTING mk8s cluster.
To create a new cluster first, run: ./scripts/setup-nebius-mk8s.sh

Examples:
  $0                                      # Basic deployment
  $0 --enable-gpu                         # With GPU support
  $0 --enable-gpu --gpu-platform gpu-h200-sxm
  $0 --dry-run                            # Preview only
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -c|--cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -g|--enable-gpu) ENABLE_GPU=true; shift ;;
    -p|--gpu-platform) GPU_PLATFORM="$2"; shift 2 ;;
    -r|--gpu-preset) GPU_PRESET="$2"; shift 2 ;;
    -m|--disable-monitoring) ENABLE_MONITORING=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) log_error "Unknown option: $1" ;;
  esac
done

log_info "Running pre-flight checks..."

for cmd in nebius kubectl helm; do
  if ! command -v $cmd &> /dev/null; then
    log_error "$cmd not found. Install: nebius via https://storage.eu-north1.nebius.cloud/cli/install.sh"
  fi
done

if ! nebius iam whoami --format json &> /dev/null; then
  log_error "Not authenticated with Nebius. Run 'nebius profile create' first."
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
  log_warn "ANTHROPIC_API_KEY not set. You'll be prompted."
fi

log_info "Fetching cluster credentials..."
CLUSTER_ID=$(nebius mk8s cluster get-by-name --name "$CLUSTER_NAME" --format json 2>/dev/null | \
  grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

if [ -z "$CLUSTER_ID" ]; then
  log_error "Cluster '$CLUSTER_NAME' not found. Create it first with ./scripts/setup-nebius-mk8s.sh"
fi

log_info "Cluster ID: $CLUSTER_ID"

KUBECONFIG_PATH="$HOME/.kube/${CLUSTER_NAME}.yaml"
nebius mk8s cluster get-credentials --id "$CLUSTER_ID" --external > "$KUBECONFIG_PATH" 2>&1 || \
  nebius mk8s cluster get-credentials --id "$CLUSTER_ID" --external
export KUBECONFIG="$KUBECONFIG_PATH"

if ! kubectl cluster-info &> /dev/null; then
  log_error "Cannot access cluster. Check kubeconfig at $KUBECONFIG_PATH"
fi

log_info "✓ Connected to cluster: $CLUSTER_NAME"

log_info "Setting up namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" name="$NAMESPACE" --overwrite

if [ -z "$ANTHROPIC_API_KEY" ]; then
  read -sp "Enter Anthropic API key: " ANTHROPIC_API_KEY
  echo
fi

log_info "Creating API key secret..."
kubectl create secret generic openclaw-secrets \
  --from-literal=anthropic-api-key="$ANTHROPIC_API_KEY" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

log_info "Preparing Helm deployment..."
HELM_ARGS="-n $NAMESPACE -f helm/kubeclaw/values.yaml"

if [ "$ENABLE_MONITORING" = true ]; then
  HELM_ARGS="$HELM_ARGS -f helm/kubeclaw/values-monitoring.yaml"
  log_info "✓ Monitoring enabled"
fi

if [ "$ENABLE_GPU" = true ]; then
  HELM_ARGS="$HELM_ARGS -f helm/kubeclaw/values-gpu.yaml"
  HELM_ARGS="$HELM_ARGS --set gpu.platform=$GPU_PLATFORM"
  HELM_ARGS="$HELM_ARGS --set gpu.preset=$GPU_PRESET"
  log_info "✓ GPU enabled: $GPU_PLATFORM ($GPU_PRESET)"
fi

if [ "$DRY_RUN" = true ]; then
  log_warn "DRY RUN MODE"
  helm install kubeclaw ./helm/kubeclaw/ $HELM_ARGS --dry-run --debug > /tmp/kubeclaw-manifest.yaml
  log_info "Manifest saved to /tmp/kubeclaw-manifest.yaml"
  exit 0
fi

log_info "Installing KubeClaw with Helm..."
helm install kubeclaw ./helm/kubeclaw/ $HELM_ARGS --wait --timeout 5m

log_info "Waiting for OpenClaw pod to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=kubeclaw \
  -n "$NAMESPACE" \
  --timeout=300s 2>/dev/null || true

echo
echo "================================================================"
log_info "KubeClaw deployment complete!"
echo "================================================================"
echo
echo "Access OpenClaw:"
echo "  kubectl port-forward -n $NAMESPACE svc/kubeclaw 18793:80"
echo "  Open: http://localhost:18793"

if [ "$ENABLE_MONITORING" = true ]; then
  echo
  echo "Access Grafana:"
  echo "  kubectl port-forward -n $NAMESPACE svc/grafana 3000:80"
  echo "  Login: admin / changeme (CHANGE THIS!)"
fi

echo
echo "Verify: ./scripts/verify-deployment.sh"
echo

# Detailed Deployment Guide

Step-by-step guide for deploying KubeClaw to production on Nebius Managed Kubernetes.

## Pre-Deployment Checklist

- [ ] Completed [Prerequisites](prerequisites.md)
- [ ] Nebius account with billing enabled
- [ ] Anthropic API key obtained
- [ ] `nebius`, `kubectl`, `helm` installed and configured
- [ ] SSH key available (if using CLI)
- [ ] DNS domain (optional, for public access)

## Step 1: Prepare Deployment Environment

### 1.1 Set Environment Variables
```bash
# Nebius project (find with: nebius iam project list --format json)
export NEBIUS_PROJECT_ID="project-e00abc..."

# Deployment settings
export KUBECLAW_CLUSTER_NAME="kubeclaw-prod"
export KUBECLAW_NAMESPACE="kubeclaw"
export KUBECLAW_DOMAIN="openclaw.example.com"

# Anthropic
export ANTHROPIC_API_KEY="sk-..."
```

### 1.2 Create Project Folder
```bash
mkdir -p ~/kubeclaw-deployment
cd ~/kubeclaw-deployment

# Clone or download KubeClaw
git clone https://github.com/opencolin/kubeclaw.git
cd kubeclaw
```

### 1.3 Verify Prerequisites
```bash
# Check tool versions
echo "nebius: $(nebius --version)"
echo "kubectl: $(kubectl version --client --short)"
echo "helm: $(helm version --short)"

# Test Nebius authentication
nebius iam whoami --format json

# Test Anthropic API
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model": "claude-opus-4-1", "max_tokens": 10, "messages": [{"role": "user", "content": "Hi"}]}' | jq '.content[0].text'
```

## Step 2: Create Nebius Kubernetes Cluster

### 2.1 Create VPC Network and Subnet
```bash
# Create VPC network
NETWORK_ID=$(nebius vpc network create \
  --name ${KUBECLAW_CLUSTER_NAME}-network \
  --parent-id $NEBIUS_PROJECT_ID \
  --format json | jq -r .metadata.id)

# Create subnet
SUBNET_ID=$(nebius vpc subnet create \
  --name ${KUBECLAW_CLUSTER_NAME}-subnet \
  --parent-id $NEBIUS_PROJECT_ID \
  --network-id $NETWORK_ID \
  --ipv4-cidr-blocks '["10.0.0.0/24"]' \
  --format json | jq -r .metadata.id)
```

### 2.2 Create mk8s Cluster
```bash
CLUSTER_ID=$(nebius mk8s cluster create \
  --name $KUBECLAW_CLUSTER_NAME \
  --parent-id $NEBIUS_PROJECT_ID \
  --control-plane-subnet-id $SUBNET_ID \
  --control-plane-version "1.31" \
  --control-plane-endpoints-public-endpoint \
  --format json | jq -r .metadata.id)

# Wait for cluster to be RUNNING (5-10 minutes)
nebius mk8s cluster get --id $CLUSTER_ID --format json | jq .status.state
```

### 2.3 Create CPU Node Group
```bash
nebius mk8s node-group create \
  --parent-id $CLUSTER_ID \
  --name ${KUBECLAW_CLUSTER_NAME}-cpu \
  --fixed-node-count 2 \
  --template-resources-platform cpu-e2 \
  --template-resources-preset 4vcpu-16gb \
  --format json
```

### 2.4 Get Kubeconfig
```bash
nebius mk8s cluster get-credentials \
  --id $CLUSTER_ID \
  --external > ~/.kube/$KUBECLAW_CLUSTER_NAME.yaml

export KUBECONFIG=~/.kube/$KUBECLAW_CLUSTER_NAME.yaml

# Verify
kubectl cluster-info
kubectl get nodes
```

### 2.5 (Optional) Add GPU Node Group
```bash
# Platforms: gpu-h100-sxm, gpu-h200-sxm, gpu-b200-sxm, gpu-l40s
# Presets: 1gpu-16vcpu-200gb, 8gpu-128vcpu-1600gb, etc.
nebius mk8s node-group create \
  --parent-id $CLUSTER_ID \
  --name ${KUBECLAW_CLUSTER_NAME}-gpu \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h100-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb \
  --format json

# Verify
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

## Step 3: Prepare Helm Chart

### 3.1 Create Namespace
```bash
kubectl create namespace $KUBECLAW_NAMESPACE
kubectl label namespace $KUBECLAW_NAMESPACE name=$KUBECLAW_NAMESPACE
```

### 3.2 Add Helm Dependencies
```bash
# Update Chart dependencies (Prometheus, Grafana)
helm dependency update ./helm/kubeclaw/

# List dependencies
helm dependency list ./helm/kubeclaw/
```

### 3.3 Create API Key Secret
```bash
# Create secret with Anthropic API key
kubectl create secret generic openclaw-secrets \
  --from-literal=anthropic-api-key=$ANTHROPIC_API_KEY \
  -n $KUBECLAW_NAMESPACE

# Verify secret was created
kubectl get secret -n $KUBECLAW_NAMESPACE openclaw-secrets
```

## Step 4: Customize Deployment Configuration

### 4.1 Create Custom Values File
```bash
# Copy example values
cp examples/values-prod.yaml ./kubeclaw-prod-values.yaml

# Edit for your environment
cat > kubeclaw-prod-values.yaml << 'EOF'
namespace: kubeclaw

image:
  repository: cr.nebius.cloud/opencloudconsole/openclaw
  tag: latest

resources:
  requests:
    memory: "4Gi"
    cpu: "2"
  limits:
    memory: "8Gi"
    cpu: "4"

persistence:
  enabled: true
  storageClass: "nebius-ssd"
  size: 50Gi

ingress:
  enabled: true
  className: "nebius"
  hosts:
    - host: openclaw.example.com
      paths:
        - path: /
          pathType: Prefix

monitoring:
  enabled: true
  prometheus:
    enabled: true
    retention: "15d"
  grafana:
    enabled: true
    adminPassword: "change-me-now"
EOF
```

### 4.2 (Optional) GPU Configuration
```bash
# For GPU deployment, add GPU values overlay
cat > kubeclaw-gpu-values.yaml << 'EOF'
gpu:
  enabled: true
  type: "nvidia.com/gpu"
  count: 1
  nodePool: "gpu-h100"
  resources:
    limits:
      nvidia.com/gpu: 1

resources:
  requests:
    memory: "8Gi"
    cpu: "4"
  limits:
    memory: "16Gi"
    cpu: "8"

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.nebius.cloud/node-pool
              operator: In
              values:
                - "gpu-h100"
            - key: accelerator
              operator: In
              values:
                - "nvidia-h100"
EOF
```

## Step 5: Deploy with Helm

### 5.1 Dry Run (Recommended)
```bash
# Validate deployment before applying
helm install kubeclaw ./helm/kubeclaw/ \
  -n $KUBECLAW_NAMESPACE \
  -f kubeclaw-prod-values.yaml \
  --dry-run \
  --debug > kubeclaw-manifest.yaml

# Review generated manifest
cat kubeclaw-manifest.yaml | head -100
```

### 5.2 Install Helm Release
```bash
# Basic deployment
helm install kubeclaw ./helm/kubeclaw/ \
  -n $KUBECLAW_NAMESPACE \
  -f kubeclaw-prod-values.yaml

# With GPU (if enabled)
# helm install kubeclaw ./helm/kubeclaw/ \
#   -n $KUBECLAW_NAMESPACE \
#   -f kubeclaw-prod-values.yaml \
#   -f kubeclaw-gpu-values.yaml

# Wait for installation to complete
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=kubeclaw \
  -n $KUBECLAW_NAMESPACE \
  --timeout=300s
```

### 5.3 Verify Installation
```bash
# Check all resources
kubectl get all -n $KUBECLAW_NAMESPACE

# Check pod status
kubectl get pods -n $KUBECLAW_NAMESPACE -o wide

# Check pod logs (tail for issues)
kubectl logs -n $KUBECLAW_NAMESPACE -l app=openclaw -f --tail=20
```

## Step 6: Post-Deployment Configuration

### 6.1 Verify Core Functionality
```bash
# Port forward to test
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/kubeclaw 18793:80 &

# Test API
curl -i http://localhost:18793/health
# Output should be 200 OK

# Stop port forward
fg
# Press Ctrl+C
```

### 6.2 Configure TLS (If Ingress Enabled)
```bash
# Install cert-manager (if not present)
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --create-namespace \
  --set installCRDs=true

# Create ClusterIssuer for Let's Encrypt
kubectl apply -f - << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# Update Ingress for TLS
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n $KUBECLAW_NAMESPACE \
  --reuse-values \
  --set ingress.tls[0].secretName=openclaw-tls \
  --set ingress.tls[0].hosts[0]=openclaw.example.com \
  --set ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod
```

### 6.3 Customize Grafana Password
```bash
# Change default admin password
kubectl exec -n $KUBECLAW_NAMESPACE deployment/grafana -it -- \
  grafana-cli admin reset-admin-password your-secure-password

# Or update via Helm
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n $KUBECLAW_NAMESPACE \
  --reuse-values \
  --set grafana.adminPassword=your-secure-password
```

## Step 7: Verification & Testing

### 7.1 Run Verification Script
```bash
# Run built-in verification
./scripts/verify-deployment.sh

# Output should show:
# ✓ Pod is running
# ✓ Health check passed
# ✓ PVC is bound
# ✓ Monitoring stack is healthy
```

### 7.2 Manual Verification
```bash
# Check all resources deployed
kubectl get deployment,svc,pvc,pod -n $KUBECLAW_NAMESPACE

# Verify OpenClaw
kubectl exec -n $KUBECLAW_NAMESPACE deployment/kubeclaw -- \
  curl -s http://localhost:18793/health | jq

# Verify Prometheus metrics
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/prometheus 9090:9090 &
# Open http://localhost:9090/targets
# Verify kubeclaw target is "UP"

# Verify Grafana
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/grafana 3000:80 &
# Open http://localhost:3000
# Login: admin / password
# Check dashboards for data
```

### 7.3 Test API Integration
```bash
# Get service IP/domain
SERVICE_IP=$(kubectl get svc -n $KUBECLAW_NAMESPACE kubeclaw -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Or use port-forward
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/kubeclaw 18793:80 &
SERVICE_URL="http://localhost:18793"

# Test OpenClaw health
curl -i $SERVICE_URL/health

# Test with actual request (example)
# curl -X POST $SERVICE_URL/api/v1/messages \
#   -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
#   -d '{...}'
```

## Step 8: Monitoring & Alerting Setup

### 8.1 Access Monitoring Stack
```bash
# Grafana dashboard
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/grafana 3000:80
# http://localhost:3000 → admin / password

# Prometheus
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/prometheus 9090:9090
# http://localhost:9090

# AlertManager
kubectl port-forward -n $KUBECLAW_NAMESPACE svc/alertmanager 9093:9093
# http://localhost:9093
```

### 8.2 Configure Alert Notifications
```bash
# Edit AlertManager configuration
kubectl edit secret -n $KUBECLAW_NAMESPACE alertmanager-main

# Add Slack webhook (example)
# receivers:
#   - name: 'slack'
#     slack_configs:
#       - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK'
```

## Step 9: Backup & Recovery Setup

### 9.1 Create PVC Snapshot
```bash
# Create snapshot of OpenClaw PVC
kubectl apply -f - << 'EOF'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: openclaw-snapshot-initial
  namespace: kubeclaw
spec:
  volumeSnapshotClassName: nebius-csi-snapshotclass
  source:
    persistentVolumeClaimName: kubeclaw-pvc
EOF

# Verify snapshot
kubectl get volumesnapshot -n $KUBECLAW_NAMESPACE
```

### 9.2 Schedule Regular Backups
```bash
# Create CronJob for daily snapshots
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kubeclaw-snapshot
  namespace: kubeclaw
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: kubeclaw
          containers:
          - name: snapshot
            image: bitnami/kubectl:latest
            command:
            - /bin/sh
            - -c
            - |
              kubectl apply -f - << EOF2
              apiVersion: snapshot.storage.k8s.io/v1
              kind: VolumeSnapshot
              metadata:
                name: openclaw-snapshot-$(date +%Y%m%d-%H%M%S)
                namespace: kubeclaw
              spec:
                volumeSnapshotClassName: nebius-csi-snapshotclass
                source:
                  persistentVolumeClaimName: kubeclaw-pvc
              EOF2
          restartPolicy: OnFailure
EOF
```

## Step 10: Production Hardening

### 10.1 Apply Security Hardening
```bash
# See Security Hardening Guide
# Key items:
# - Change all default passwords
# - Enable network policies
# - Enable RBAC
# - Rotate API keys regularly
# - Enable audit logging
# - Configure TLS for all endpoints

helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n $KUBECLAW_NAMESPACE \
  --reuse-values \
  --set networkPolicy.enabled=true \
  --set rbac.create=true \
  --set podSecurityPolicy.enabled=true
```

### 10.2 Enable Audit Logging
```bash
# Audit logging is managed via the Nebius console for mk8s
# (no direct nebius CLI flag at time of writing). See:
# https://docs.nebius.com/kubernetes/managed/logging
```

### 10.3 Configure RBAC for Access
```bash
# Create read-only role for developers
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kubeclaw-viewer
  namespace: kubeclaw
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
EOF
```

## Troubleshooting

If deployment fails, see [Troubleshooting Guide](troubleshooting.md) for solutions.

## Next Steps

1. **Monitor**: Access Grafana dashboards regularly
2. **Test**: Run OpenClaw with sample requests
3. **Backup**: Verify backup snapshots are created
4. **Document**: Record cluster IP, domains, API keys (securely)
5. **Train**: Familiarize team with deployment
6. **Plan**: Schedule regular maintenance and updates

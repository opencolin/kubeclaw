# Quick Start Guide

Deploy OpenClaw to Nebius Managed Kubernetes in **5 minutes**.

## Prerequisites

- ✓ Nebius account with a project (note the `project-e00...` ID)
- ✓ `nebius` CLI: `curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash`
- ✓ `kubectl` installed
- ✓ `helm` 3.10+ installed
- ✓ Anthropic API key ([get one](https://console.anthropic.com/keys))

## 1. Create Nebius mk8s Cluster (2 min)

The easy path uses the bundled setup script (creates VPC, subnet, cluster, and node groups):

```bash
# Authenticate
nebius profile create
export NEBIUS_PROJECT_ID="project-e00abc..."  # your project ID

# One-command cluster setup
./scripts/setup-nebius-mk8s.sh \
  --project-id "$NEBIUS_PROJECT_ID" \
  --cluster-name kubeclaw-quickstart
```

The script runs the underlying commands:

```bash
# Create VPC network and subnet
nebius vpc network create --name kubeclaw-quickstart-network --parent-id $NEBIUS_PROJECT_ID --format json
nebius vpc subnet create --name kubeclaw-quickstart-subnet --parent-id $NEBIUS_PROJECT_ID \
  --network-id <NET_ID> --ipv4-cidr-blocks '["10.0.0.0/24"]' --format json

# Create mk8s cluster
nebius mk8s cluster create --name kubeclaw-quickstart --parent-id $NEBIUS_PROJECT_ID \
  --control-plane-subnet-id <SUBNET_ID> --control-plane-version "1.31" \
  --control-plane-endpoints-public-endpoint --format json

# Create CPU node group
nebius mk8s node-group create --parent-id <CLUSTER_ID> --name kubeclaw-quickstart-cpu \
  --fixed-node-count 2 --template-resources-platform cpu-e2 \
  --template-resources-preset 4vcpu-16gb --format json

# Fetch kubeconfig
nebius mk8s cluster get-credentials --id <CLUSTER_ID> --external > ~/.kube/kubeclaw-quickstart.yaml
export KUBECONFIG=~/.kube/kubeclaw-quickstart.yaml
kubectl cluster-info
```

## 2. Deploy OpenClaw (2 min)

### Option A: Quick Install (Default)
```bash
cd kubeclaw
helm repo add kubeclaw https://your-registry-here.com  # Replace with actual repo
helm repo update

helm install kubeclaw kubeclaw/kubeclaw \
  --namespace kubeclaw \
  --create-namespace \
  --set openclaw.apiKey.secretValue=<your-api-key>
```

### Option B: Custom Install (with monitoring)
```bash
helm install kubeclaw ./helm/kubeclaw/ \
  --namespace kubeclaw \
  --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-monitoring.yaml \
  --set openclaw.apiKey.secretValue=<your-api-key>
```

## 3. Verify Deployment (1 min)

```bash
# Check pod status
kubectl get pods -n kubeclaw
# Output: kubeclaw-xxx  1/1  Running  0  1m

# Check logs
kubectl logs -n kubeclaw -f deployment/kubeclaw
# Output: [INFO] OpenClaw started on port 18793

# Run verification script
./scripts/verify-deployment.sh
```

## 4. Access OpenClaw (Optional)

### Port Forward (Local Testing)
```bash
kubectl port-forward -n kubeclaw svc/kubeclaw 18793:80
# Open: http://localhost:18793
```

### Public Access (Ingress)
```bash
# Enable ingress in values
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=openclaw.example.com

# Get Ingress IP
kubectl get ingress -n kubeclaw
# Copy INGRESS-CLASS and IP address
```

## 5. Monitor OpenClaw (Optional)

If you installed with `values-monitoring.yaml`:

```bash
# Access Grafana dashboard
kubectl port-forward -n kubeclaw svc/grafana 3000:80
# Open: http://localhost:3000
# Login: admin / changeme (from values-monitoring.yaml)

# Access Prometheus
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Open: http://localhost:9090
# Query: container_memory_usage_bytes{pod=~"kubeclaw.*"}
```

## Common Commands

```bash
# View deployment status
kubectl get deployment -n kubeclaw

# View pod logs
kubectl logs -n kubeclaw -f deployment/kubeclaw

# Execute shell in pod
kubectl exec -n kubeclaw -it deployment/kubeclaw -- /bin/bash

# Check resource usage
kubectl top pod -n kubeclaw

# Add a GPU node group (requires existing cluster ID)
CLUSTER_ID=$(nebius mk8s cluster get-by-name --name kubeclaw-quickstart \
  --format json | jq -r .metadata.id)
nebius mk8s node-group create \
  --parent-id "$CLUSTER_ID" \
  --name kubeclaw-quickstart-gpu \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h100-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb

# Update deployment
helm upgrade kubeclaw ./helm/kubeclaw/ -n kubeclaw

# Cleanup
helm uninstall kubeclaw -n kubeclaw
nebius mk8s cluster delete --id "$CLUSTER_ID"
```

## Troubleshooting

**Pod stuck in Pending:**
```bash
kubectl describe pod -n kubeclaw deployment/kubeclaw
# Check Events section for resource constraints
```

**API key not working:**
```bash
# Verify secret was created
kubectl get secret -n kubeclaw openclaw-secrets -o yaml

# Re-create secret
kubectl delete secret openclaw-secrets -n kubeclaw
kubectl create secret generic openclaw-secrets \
  --from-literal=anthropic-api-key=<your-key> \
  -n kubeclaw
```

**Monitoring not working:**
```bash
# Check Prometheus targets
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Navigate to Status → Targets in the UI
```

## Next Steps

- [Read full deployment guide](deployment-guide.md)
- [Configure GPU support](gpu-configuration.md)
- [Setup monitoring alerts](monitoring-setup.md)
- [Harden security](security-hardening.md)

## Support

For issues, see [Troubleshooting Guide](troubleshooting.md) or [FAQ](faq.md).

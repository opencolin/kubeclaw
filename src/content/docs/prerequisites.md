---
title: "Prerequisites"
description: "Required accounts, tools, and credentials before deploying KubeClaw"
---

Before deploying KubeClaw, ensure you have the required accounts, tools, and credentials.

## Nebius Account Setup

### 1. Create Nebius Account
- Visit [Nebius AI Cloud Console](https://console.nebius.cloud)
- Sign up with email or GitHub account
- Verify email address
- Enable billing (required for cluster provisioning)

### 2. Install nebius CLI
```bash
# Official installer (all platforms)
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash

# Restart shell or source profile
source ~/.bashrc  # or ~/.zshrc
```

### 3. Create Nebius Profile (Authenticate)
```bash
# Interactive profile creation - opens browser for OAuth
nebius profile create

# Verify authentication
nebius iam whoami --format json
```

### 4. Identify Your Project ID
```bash
# List available projects (tenants/projects)
nebius iam project list --format json

# Note your project ID (starts with project-e00...)
export NEBIUS_PROJECT_ID="project-e00abc..."
```

## Anthropic API Key

### 1. Get API Key
- Visit [Anthropic Console](https://console.anthropic.com/keys)
- Click "Create API Key"
- Copy the key (displayed only once)
- Save securely

### 2. Verify API Key
```bash
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: YOUR_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model": "claude-opus-4-1", "max_tokens": 1024, "messages": [{"role": "user", "content": "Say hello!"}]}' 
```

## Required Tools

### macOS / Linux
```bash
# nebius CLI (official installer)
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash

# kubectl (macOS)
brew install kubectl

# kubectl (Linux)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm (all platforms)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Windows (WSL2 recommended)
Run the Linux commands above inside WSL2. The nebius CLI is officially supported on Linux and macOS; Windows users should use WSL2.

## Verify Tool Installation

```bash
# Check versions
nebius --version              # Output: nebius vX.X.X
kubectl version --client      # Output: v1.31.X
helm version                  # Output: v3.X.X

# Verify Nebius authentication
nebius iam whoami --format json
# Output: {"user_account":{...}, "federation_info":{...}}
```

## Configure kubectl

```bash
# Create kubeconfig directory
mkdir -p ~/.kube

# Verify kubeconfig path is set
echo $KUBECONFIG
# If empty, add to ~/.bashrc or ~/.zshrc:
# export KUBECONFIG=~/.kube/config
```

## Nebius CLI Configuration

### Login
```bash
nebius profile create
# Interactive: opens browser for OAuth login
# Creates named profile in ~/.nebius/config.yaml
```

### List Profiles & Switch
```bash
nebius profile list
nebius profile activate <profile-name>
```

### List Projects
```bash
nebius iam project list --format json
# Note project ID (starts with project-e00...)
```

### Create Service Account (For CI/CD)
```bash
nebius iam service-account create \
  --name kubeclaw-deploy \
  --parent-id "$NEBIUS_PROJECT_ID" \
  --format json

# Create access key for the service account
nebius iam access-key create \
  --account-service-account-id <SA_ID> \
  --description "KubeClaw CI/CD" \
  --format json
```

## Network & Firewall

### Required Ports
| Service | Port | Direction | Purpose |
|---------|------|-----------|---------|
| OpenClaw (Canvas) | 18793 | Inbound | Web UI access |
| OpenClaw (Control) | 18789 | Inbound | WebSocket control |
| Prometheus | 9090 | Internal | Metrics scraping |
| Grafana | 3000 | Internal | Dashboards |
| Kubectl | 6443 | Outbound | Cluster API access |
| HTTPS | 443 | Outbound | Anthropic API, model downloads |
| DNS | 53 | Outbound | Service discovery |

### Firewall Rules (If Needed)
```bash
# Example: Open ports on local machine
# macOS
sudo pfctl -ef /etc/pf.conf

# Linux (UFW)
sudo ufw allow 18793/tcp
sudo ufw allow 18789/tcp
```

## Storage Requirements

### Local Machine
- **KubeClaw source**: ~500 MB
- **kubeconfig files**: ~10 KB
- **Helm cache**: ~100 MB

### Nebius Cloud
- **Persistent Volume**: 50 GB default (configurable)
- **Prometheus PVC**: 50 GB (monitoring enabled)
- **Grafana PVC**: 10 GB (monitoring enabled)
- **Total**: ~110 GB recommended

## Memory & CPU (Local Development)

If running locally (Docker Desktop, Rancher, etc.):
- **RAM**: 4 GB minimum, 8 GB recommended
- **CPU**: 2 cores minimum, 4 cores recommended
- **Disk**: 20 GB free space

## Resource Limits (Nebius Cluster)

Default node type: `n4-highmem-4`
- vCPU: 4
- RAM: 16 GB
- Disk: 50 GB

Recommended for production:
- **Minimum**: 2x `n4-highmem-4` nodes
- **Recommended**: 3x `n4-highmem-4` nodes
- **With GPU**: 1x `n4-highmem-4` + 1x `gpu-h100`

## Environment Variables

### Required
```bash
export NEBIUS_OAUTH_TOKEN="your-token"
export NEBIUS_API_KEY="your-api-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
```

### Optional
```bash
export KUBECLAW_NAMESPACE="kubeclaw"
export KUBECLAW_CLUSTER_NAME="kubeclaw-prod"
export KUBECLAW_REGION="us-central1"
export KUBECONFIG=~/.kube/kubeclaw-prod.yaml
```

### Add to Shell Profile
```bash
# macOS/Linux: ~/.bashrc or ~/.zshrc
cat >> ~/.zshrc << 'EOF'
export NEBIUS_OAUTH_TOKEN="your-token"
export NEBIUS_API_KEY="your-api-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
EOF

source ~/.zshrc
```

## Verify Setup

```bash
# 1. Check Nebius access
nebius auth status

# 2. Check Anthropic API
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model": "claude-opus-4-1", "max_tokens": 100, "messages": [{"role": "user", "content": "Hi"}]}' \
  | jq '.content[0].text'

# 3. Check tools
kubectl version --client --short
helm version --short

# 4. Ready to deploy!
echo "✓ Prerequisites complete. Ready to deploy!"
```

## Troubleshooting Setup

**nebius: command not found**
```bash
# Ensure /usr/local/bin is in PATH
echo $PATH | grep /usr/local/bin
# Add to shell profile if missing
```

**kubectl: unable to connect to the server**
```bash
# Verify kubeconfig
kubectl config view
# Ensure KUBECONFIG variable is set correctly
```

**Anthropic API key invalid**
```bash
# Verify key format (sk-...)
echo $ANTHROPIC_API_KEY | head -c 3

# Get new key from console if needed
```

## Next Steps

- [Quick Start Guide](quick-start.md) - Deploy in 5 minutes
- [Full Deployment Guide](deployment-guide.md) - Detailed walkthrough

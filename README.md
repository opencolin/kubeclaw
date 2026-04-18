# KubeClaw: Deploy OpenClaw & NemoClaw on Nebius Managed Kubernetes

KubeClaw is a comprehensive deployment toolkit for running OpenClaw and NemoClaw on Nebius Managed Kubernetes (mk8s). It provides production-ready Helm charts, deployment guides, GPU configuration, monitoring integration, and security hardening patterns.

## Quick Start (5 minutes)

**Prerequisites**: Nebius account + project ID, `nebius` CLI, `kubectl`, `helm` 3.10+

```bash
# 0. Install nebius CLI and authenticate
curl -sSL https://storage.eu-north1.nebius.cloud/cli/install.sh | bash
nebius profile create
export NEBIUS_PROJECT_ID="project-e00abc..."  # from: nebius iam project list

# 1. Create a Nebius mk8s cluster (creates VPC + subnet + cluster + node groups)
./scripts/setup-nebius-mk8s.sh \
  --project-id "$NEBIUS_PROJECT_ID" \
  --enable-gpu --gpu-platform gpu-h100-sxm

# 2. Deploy OpenClaw with monitoring
./scripts/install-kubeclaw.sh --enable-gpu --gpu-platform gpu-h100-sxm

# 3. Verify deployment
./scripts/verify-deployment.sh
```

Access the deployment:
- **OpenClaw UI**: `https://<your-ingress-ip>:18793`
- **Grafana**: `kubectl port-forward -n kubeclaw svc/grafana 3000:80`

## Features

✅ **Production-Ready Helm Chart**
- Security hardened (RBAC, network policies, pod security standards)
- Modular values for GPU, monitoring, and networking configurations
- Optimized for Nebius managed Kubernetes defaults

✅ **GPU Configuration**
- Nebius GPU node pool setup and scheduling
- NVIDIA H100, H200, B200, B300, L40S support
- Resource requests and limits templates

✅ **Monitoring & Observability**
- Prometheus metrics collection
- Pre-built Grafana dashboards (overview, resources, error rates)
- Alert rules for pod failures, resource exhaustion
- Kubernetes metrics and OpenClaw API monitoring

✅ **Security by Default**
- Network policies restricting ingress/egress
- RBAC roles with least privilege
- Secrets management for API keys
- Pod security standards (restricted profile)

✅ **Deployment Scripts**
- One-command Nebius cluster setup
- Automated OpenClaw installation with monitoring
- Health checks and troubleshooting utilities
- Interactive configuration generator

## Project Structure

```
kubeclaw/
├── docs/              # Comprehensive deployment documentation
├── helm/kubeclaw/     # Helm chart (values, templates)
├── monitoring/        # Prometheus, Grafana, alert configurations
├── examples/          # Reference deployment configurations
├── scripts/           # Setup, install, verify, and cleanup scripts
└── tests/             # Deployment validation tests
```

## Documentation

- **[Quick Start](docs/quick-start.md)**: Deploy in 5 minutes
- **[Architecture](docs/architecture.md)**: Design and deployment patterns
- **[Prerequisites](docs/prerequisites.md)**: Account setup and tooling
- **[Deployment Guide](docs/deployment-guide.md)**: Detailed step-by-step instructions
- **[GPU Configuration](docs/gpu-configuration.md)**: GPU node pools and scheduling
- **[Monitoring Setup](docs/monitoring-setup.md)**: Prometheus and Grafana integration
- **[Security Hardening](docs/security-hardening.md)**: Network policies, RBAC, secrets
- **[Troubleshooting](docs/troubleshooting.md)**: Common issues and solutions
- **[FAQ](docs/faq.md)**: Frequently asked questions

## Examples

Ready-to-use configurations:

- **[basic-deployment.yaml](examples/basic-deployment.yaml)**: Minimal OpenClaw setup
- **[gpu-enabled.yaml](examples/gpu-enabled.yaml)**: With GPU node affinity
- **[with-monitoring.yaml](examples/with-monitoring.yaml)**: Full stack with observability
- **[with-ingress.yaml](examples/with-ingress.yaml)**: Public access via Nebius Ingress
- **[values-prod.yaml](examples/values-prod.yaml)**: Production-ready Helm values

## Installation Methods

### Method 1: Automated (Recommended)

```bash
./scripts/install-kubeclaw.sh \
  --cluster-name my-cluster \
  --enable-gpu \
  --gpu-platform gpu-h100-sxm \
  --gpu-preset 1gpu-16vcpu-200gb
```

### Method 2: Manual Helm Installation

```bash
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-gpu.yaml \
  -f helm/kubeclaw/values-monitoring.yaml
```

### Method 3: Custom Values

```bash
./scripts/generate-config.sh  # Interactive configuration
helm install kubeclaw ./helm/kubeclaw/ -f generated-values.yaml
```

## Verification

After deployment, verify everything is working:

```bash
./scripts/verify-deployment.sh
```

This checks:
- ✓ OpenClaw pod status and readiness
- ✓ Persistent volume mounts
- ✓ API endpoint availability
- ✓ GPU availability (if enabled)
- ✓ Prometheus metrics collection
- ✓ Monitoring stack health

## Configuration

### Environment Variables

```bash
# Nebius project (from: nebius iam project list)
export NEBIUS_PROJECT_ID=project-e00abc...

# Deployment settings
export KUBECLAW_NAMESPACE=kubeclaw
export KUBECLAW_CLUSTER_NAME=kubeclaw-prod
```

### Helm Values Overrides

Key configuration options in `values.yaml`:

```yaml
image:
  # Nebius registry is regional: cr.<REGION>.nebius.cloud/<REGISTRY_ID>
  repository: cr.eu-north1.nebius.cloud/<REGISTRY_ID>/openclaw
  tag: latest

resources:
  requests:
    memory: "4Gi"
    cpu: "2"
  limits:
    memory: "8Gi"
    cpu: "4"

gpu:
  enabled: false
  type: "nvidia.com/gpu"
  platform: "gpu-h100-sxm"    # Nebius GPU platform
  preset: "1gpu-16vcpu-200gb" # Nebius resource preset

monitoring:
  enabled: true
  prometheus:
    retention: 15d
  grafana:
    adminPassword: changeme
```

## Cleanup

Remove the deployment:

```bash
./scripts/cleanup.sh --remove-cluster  # Also deletes Nebius mk8s cluster
# or
helm uninstall kubeclaw -n kubeclaw
```

## Monitoring

### Prometheus Metrics

Prometheus is deployed alongside OpenClaw when `values-monitoring.yaml` is used. Access metrics:

```bash
# Port forward to Prometheus
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090

# Query OpenClaw metrics
# - container_memory_usage_bytes
# - container_cpu_usage_seconds_total
# - kubeclaw_api_request_duration_seconds
```

### Grafana Dashboards

Pre-built dashboards included:
- **OpenClaw Overview**: Pod status, resource allocation, uptime
- **Resource Usage**: CPU, memory, GPU utilization
- **Error Rates**: API errors, restart counts, failures

```bash
# Access Grafana
kubectl port-forward -n kubeclaw svc/grafana 3000:80
# Navigate to http://localhost:3000
# Default: admin / changeme (set in values-monitoring.yaml)
```

### Alert Rules

PrometheusRules are configured for:
- Pod CrashLoopBackOff (instant)
- Memory usage > 80% (5min average)
- CPU usage > 90% (5min average)
- API error rate > 1% (5min average)
- GPU memory exhaustion (if enabled)

## Troubleshooting

**Pod stuck in Pending**
```bash
kubectl describe pod -n kubeclaw -l app=openclaw
# Check resource requests vs available nodes
```

**GPU not visible**
```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
# If no GPUs: verify a GPU node group exists on the cluster
# nebius mk8s node-group list --parent-id $CLUSTER_ID --format json
```

**Monitoring not working**
```bash
kubectl logs -n kubeclaw deploy/prometheus
# Verify ServiceMonitor is targeting OpenClaw pod
```

See [Troubleshooting Guide](docs/troubleshooting.md) for detailed solutions.

## Support & Contributing

For issues, questions, or contributions:
- 📖 See [FAQ](docs/faq.md)
- 🐛 Review [Troubleshooting Guide](docs/troubleshooting.md)
- 📝 Check [Architecture Guide](docs/architecture.md)

## License

KubeClaw is open source. OpenClaw and NemoClaw follow their respective license terms.

## References

- [OpenClaw Helm Chart](https://github.com/chrisbattarbee/openclaw-helm)
- [NemoClaw Repository](https://github.com/NVIDIA/NemoClaw)
- [Nebius Managed Kubernetes](https://docs.nebius.cloud/en/docs/managed-kubernetes/)
- [Nebius AI Cloud](https://nebius.cloud)

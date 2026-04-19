---
title: "Architecture"
description: "KubeClaw deployment architecture and design patterns"
---

## Overview

KubeClaw is designed to deploy OpenClaw/NemoClaw on Nebius Managed Kubernetes with production-grade reliability, security, and observability. This guide explains the architecture, design decisions, and deployment patterns.

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│           Nebius Managed Kubernetes (mk8s)                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐      ┌──────────────┐   ┌──────────────┐  │
│  │   General    │      │  GPU Node    │   │  GPU Node    │  │
│  │  Node Pool   │      │  Pool (H100) │   │  Pool (H200) │  │
│  └──────────────┘      └──────────────┘   └──────────────┘  │
│       │                        │                   │          │
│       └────────────────────────┴───────────────────┘          │
│                        │                                      │
│       ┌────────────────▼────────────────┐                    │
│       │   kubeclaw namespace           │                    │
│       ├────────────────────────────────┤                    │
│       │                                │                    │
│       │  ┌──────────────────────────┐  │                    │
│       │  │ OpenClaw Deployment      │  │                    │
│       │  │ (Single replica, Recreate)  │                    │
│       │  │ - Port 18793 (Canvas)    │  │                    │
│       │  │ - Port 18789 (Control)   │  │                    │
│       │  └──────────────────────────┘  │                    │
│       │           │                     │                    │
│       │           ▼                     │                    │
│       │  ┌──────────────────────────┐  │                    │
│       │  │ Persistent Volume (50Gi) │  │                    │
│       │  │ - Workspace data         │  │                    │
│       │  │ - Session state          │  │                    │
│       │  │ - Credentials            │  │                    │
│       │  └──────────────────────────┘  │                    │
│       │                                │                    │
│       ├────────────────────────────────┤                    │
│       │ Monitoring Stack (Optional)    │                    │
│       │ ┌──────────────────────────┐   │                    │
│       │ │ Prometheus               │   │                    │
│       │ │ - Scrapes metrics        │   │                    │
│       │ │ - Retains 15 days        │   │                    │
│       │ │ - Alert evaluation       │   │                    │
│       │ └──────────────────────────┘   │                    │
│       │           │                     │                    │
│       │           ▼                     │                    │
│       │ ┌──────────────────────────┐   │                    │
│       │ │ Grafana                  │   │                    │
│       │ │ - Dashboards             │   │                    │
│       │ │ - Alerts visualization   │   │                    │
│       │ │ - Query builder          │   │                    │
│       │ └──────────────────────────┘   │                    │
│       │           │                     │                    │
│       │           ▼                     │                    │
│       │ ┌──────────────────────────┐   │                    │
│       │ │ AlertManager             │   │                    │
│       │ │ - Alert routing          │   │                    │
│       │ │ - Notification delivery  │   │                    │
│       │ └──────────────────────────┘   │                    │
│       │                                │                    │
│       └────────────────────────────────┘                    │
│                                                               │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │  External Services            │
        ├───────────────────────────────┤
        │ - Anthropic API               │
        │ - Model registries            │
        │ - External webhooks           │
        │ - Nebius APIs                 │
        └───────────────────────────────┘
```

## Design Principles

### 1. Single-Instance Architecture
OpenClaw is designed as a **single-replica deployment** using Kubernetes `Recreate` strategy:
- **Why**: OpenClaw maintains stateful connections and session data
- **Implication**: No horizontal scaling; upgrade/restart causes brief downtime
- **Mitigation**: Use persistent volumes for state preservation

### 2. Persistent State Management
- **Workspace data**: `/home/openclaw/workspace` mounted to PVC
- **Session state**: Persisted to disk for recovery after pod restart
- **Credentials**: Stored in Kubernetes Secrets, injected at runtime
- **Recovery**: Pod restart restores sessions from persistent storage

### 3. Security First
- **Pod security context**: Non-root user (UID 1000), read-only filesystem
- **Network policies**: Restrict ingress to necessary ports, limit egress to HTTPS/DNS
- **RBAC**: Minimal permissions; pod can read Kubernetes resources only
- **Secrets management**: API keys in Kubernetes Secrets, never in ConfigMaps

### 4. Monitoring & Observability
- **Prometheus**: Scrapes metrics from kubelet, Kubernetes API, and OpenClaw endpoints
- **Grafana**: Pre-built dashboards for overview, resources, and errors
- **AlertManager**: Routes alerts for critical issues (crashes, resource exhaustion)
- **External monitoring**: Compatible with eBPF-based tools (e.g., Metoro) for deeper insights

### 5. GPU Support (Optional)
- **Node affinity**: OpenClaw pods schedule on GPU nodes when enabled
- **Resource requests**: Explicitly request GPU slots (e.g., `nvidia.com/gpu: 1`)
- **Nebius GPU types**: H100, H200, B200, B300, L40S
- **Isolation**: GPU memory isolated at pod level via cgroup limits

## Key Components

### OpenClaw Deployment
```yaml
- Image: cr.nebius.cloud/opencloudconsole/openclaw:latest
- Replicas: 1 (fixed; no autoscaling)
- Strategy: Recreate (no rolling updates)
- Resource limits: 4Gi memory, 4 CPU (configurable)
- Ports:
  - 18793: Canvas HTTP server
  - 18789: Control WebSocket server
- Health checks: Liveness & readiness probes
```

### Persistent Volume Claim
```yaml
- Storage class: nebius-ssd (Nebius default)
- Size: 50Gi (default; configurable)
- Access mode: ReadWriteOnce
- Retention: Delete with PVC (no manual cleanup needed)
```

### Service
```yaml
- Type: ClusterIP (or LoadBalancer for external access)
- Ports:
  - 80 → 18793 (Canvas)
  - 18789 → 18789 (Control)
```

### ServiceMonitor (for Prometheus)
```yaml
- Scrapes OpenClaw metrics on /metrics endpoint
- Interval: 30s (configurable)
- Labels: Matched to Prometheus release
- Alerts: PrometheusRules for common failure modes
```

## Deployment Sequence

### 1. Cluster Setup
```bash
# Create VPC network + subnet (required for mk8s)
NETWORK_ID=$(nebius vpc network create --name kubeclaw-prod-network \
  --parent-id $NEBIUS_PROJECT_ID --format json | jq -r .metadata.id)
SUBNET_ID=$(nebius vpc subnet create --name kubeclaw-prod-subnet \
  --parent-id $NEBIUS_PROJECT_ID --network-id $NETWORK_ID \
  --ipv4-cidr-blocks '["10.0.0.0/24"]' --format json | jq -r .metadata.id)

# Create mk8s cluster
CLUSTER_ID=$(nebius mk8s cluster create --name kubeclaw-prod \
  --parent-id $NEBIUS_PROJECT_ID \
  --control-plane-subnet-id $SUBNET_ID \
  --control-plane-version "1.31" \
  --control-plane-endpoints-public-endpoint \
  --format json | jq -r .metadata.id)

# CPU node group
nebius mk8s node-group create --parent-id $CLUSTER_ID \
  --name kubeclaw-prod-cpu --fixed-node-count 3 \
  --template-resources-platform cpu-e2 \
  --template-resources-preset 4vcpu-16gb --format json
```

### 2. GPU Node Group (Optional)
```bash
nebius mk8s node-group create \
  --parent-id $CLUSTER_ID \
  --name kubeclaw-prod-gpu \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h100-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb \
  --format json
```

### 3. Helm Chart Installation
```bash
# Basic installation
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml

# With monitoring
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-monitoring.yaml

# With GPU
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-gpu.yaml
```

### 4. Verification
```bash
kubectl get all -n kubeclaw
kubectl logs -n kubeclaw -f deployment/kubeclaw
```

## Networking

### Ingress/Egress Policies
- **Ingress**: Only allow traffic to port 18793 (Canvas) and 18789 (Control)
- **Egress**:
  - DNS (UDP 53) for service discovery
  - HTTPS (TCP 443) for Anthropic API and model downloads
  - HTTP (TCP 80) for model registry access

### Nebius Ingress Integration
```yaml
ingress:
  className: "nebius"
  hosts:
    - host: openclaw.example.com
      paths:
        - path: /
          pathType: Prefix
```

## Monitoring & Alerting

### Key Metrics
- `container_cpu_usage_seconds_total`: CPU utilization
- `container_memory_usage_bytes`: Memory usage
- `kube_pod_status_phase`: Pod status (Running, Pending, Failed, etc.)
- `kube_pod_container_status_restarts_total`: Pod restart count
- `kubelet_volume_stats_available_bytes`: PVC available space

### Alert Conditions
| Alert | Threshold | Duration | Action |
|-------|-----------|----------|--------|
| CrashLooping | >0.1 restarts/min | 5 min | Page oncall |
| High Memory | >80% limit | 5 min | Scale up or investigate |
| High CPU | >90% limit | 5 min | Investigate workload |
| PVC Full | <10% available | 5 min | Expand PVC or cleanup |
| Pod Not Running | Any non-Running phase | 5 min | Investigate logs |

## Scaling Considerations

### Vertical Scaling
- Increase resource requests/limits in `values.yaml`
- Requires pod restart (brief downtime)
- GPU expansion: Add GPU resources, update node affinity

### Horizontal Scaling
- **Not recommended**: OpenClaw is single-instance by design
- **Workaround**: Run multiple deployments in different namespaces
- **Alternative**: Use external load balancer + session affinity

## High Availability

### Current Design
- Single replica with persistent storage recovery
- Pod restart restores session state within minutes
- Suitable for non-critical deployments

### Enhanced HA (Future)
- Active-passive standby using StatefulSet + leader election
- Shared persistent volume with locking mechanism
- External load balancer for failover routing

## Disaster Recovery

### Backup Strategy
- **PVC snapshots**: Nebius supports PVC snapshots via `VolumeSnapshotClass`
- **Frequency**: Daily snapshots of workspace PVC
- **Retention**: 7-day rolling window
- **Recovery RTO**: <5 minutes; RPO: <24 hours

### Cleanup & Decommissioning
```bash
# Remove deployment
helm uninstall kubeclaw -n kubeclaw

# Remove PVC (data loss!)
kubectl delete pvc -n kubeclaw --all

# Remove cluster
nebius mk8s cluster delete --id $CLUSTER_ID
```

## Cost Optimization

### Resource Sizing
- **Default**: 4Gi memory, 2 CPU (suitable for most workloads)
- **Small**: 2Gi memory, 1 CPU (limited to small models)
- **Large**: 8Gi memory, 4 CPU (for large models + concurrent sessions)

### GPU Cost
- H100: ~$4/hour on Nebius (highest performance)
- H200: ~$3.5/hour (new; better memory)
- L40S: ~$0.5/hour (small models, inference only)

### Storage Cost
- PVC: ~$0.06/GB/month on Nebius
- Snapshots: ~$0.03/GB/month
- Optimize: Use `emptyDir` for temporary data; only persist essential state

## Troubleshooting Architecture Issues

### Pod Stuck in Pending
**Diagnosis**: Check node resources and affinity labels
```bash
kubectl describe pod -n kubeclaw openclaw-xxx
kubectl describe nodes
```
**Solution**: Scale up node pool or adjust resource requests

### Metrics Not Appearing
**Diagnosis**: Verify ServiceMonitor is creating scrape targets
```bash
kubectl port-forward -n kubeclaw svc/prometheus 9090:90
# Check "Targets" tab in Prometheus UI
```
**Solution**: Ensure `monitoring.prometheus.enabled: true` in values

### GPU Not Detected
**Diagnosis**: Check node labels and pod events
```bash
kubectl get nodes -L nvidia.com/gpu
kubectl describe pod -n kubeclaw openclaw-xxx | grep -i gpu
```
**Solution**: Verify node pool has GPU labels; update node affinity

## Related Documentation

- [Quick Start Guide](quick-start.md)
- [Deployment Guide](deployment-guide.md)
- [GPU Configuration](gpu-configuration.md)
- [Monitoring Setup](monitoring-setup.md)
- [Security Hardening](security-hardening.md)
- [Troubleshooting](troubleshooting.md)

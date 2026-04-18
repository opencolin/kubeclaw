# GPU Configuration Guide

Configure OpenClaw to use Nebius GPUs for accelerated inference.

## GPU Platforms on Nebius

Use these platform/preset identifiers with `--template-resources-platform` and `--template-resources-preset`:

| Platform | Preset (example) | Memory per GPU | Best For |
|----------|------------------|----------------|----------|
| `gpu-h100-sxm` | `1gpu-16vcpu-200gb` | 80 GB | Large models, concurrent inference |
| `gpu-h200-sxm` | `1gpu-16vcpu-200gb` | 141 GB | Very large models |
| `gpu-b200-sxm` | `1gpu-16vcpu-200gb` | 192 GB | Extreme scale |
| `gpu-l40s`     | `1gpu-8vcpu-32gb`   | 48 GB  | Small models, batch inference |

Multi-GPU presets (e.g. `8gpu-128vcpu-1600gb`) are available on each SXM platform. See `nebius compute platform list` for the full catalog.

## 1. Create GPU Node Pool

### Option A: Using the setup script

```bash
./scripts/setup-nebius-mk8s.sh \
  --project-id "$NEBIUS_PROJECT_ID" \
  --cluster-name kubeclaw-gpu \
  --enable-gpu \
  --gpu-platform gpu-h100-sxm \
  --gpu-preset 1gpu-16vcpu-200gb
```

### Option B: Using the nebius CLI directly

```bash
# Assumes VPC, subnet, and cluster already exist. Grab the cluster ID:
CLUSTER_ID=$(nebius mk8s cluster get-by-name --name kubeclaw-gpu \
  --format json | jq -r .metadata.id)

# Add a GPU node group
nebius mk8s node-group create \
  --parent-id "$CLUSTER_ID" \
  --name kubeclaw-gpu-h100 \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h100-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb \
  --format json

# Verify GPU availability
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

## 2. Verify GPU Availability

```bash
# Check GPU node labels
kubectl get nodes --show-labels | grep gpu

# Check GPU allocatable resources
kubectl describe node gpu-h100-1 | grep -A5 "Allocated resources"

# Run GPU detection pod
kubectl run gpu-test --image=nvidia/cuda:12.0.0-runtime \
  -it --rm --restart=Never -- nvidia-smi

# Output should show GPU information
```

## 3. Deploy OpenClaw with GPU

### Option A: Using values-gpu.yaml Overlay

```bash
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-gpu.yaml \
  --set openclaw.apiKey.secretValue=<your-key>
```

### Option B: Custom Values

```yaml
# values-custom-gpu.yaml
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
```

```bash
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f values-custom-gpu.yaml
```

## 4. Verify GPU Allocation

```bash
# Check pod is running on GPU node
kubectl get pod -n kubeclaw -o wide
# Output: kubeclaw-xxx  gpu-h100-1

# Verify GPU is visible inside pod
kubectl exec -n kubeclaw deployment/kubeclaw -- nvidia-smi

# Check GPU allocation in Prometheus
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Query: nvidia_smi_memory_used_bytes
```

## GPU Resource Limits

### Memory Limits (Critical)
Set GPU memory limits to prevent OOM kills:

```yaml
env:
  - name: CUDA_VISIBLE_DEVICES
    value: "0"
  - name: GPU_MEMORY_FRACTION
    value: "0.95"  # Use up to 95% of GPU memory
```

### Shared GPU (Advanced)
For multiple pods sharing one GPU (not recommended for inference):

```yaml
resources:
  limits:
    nvidia.com/gpu: "0.5"  # Half GPU access
```

## GPU Monitoring

### Prometheus Metrics
```promql
# GPU Memory Usage
nvidia_smi_memory_used_bytes{pod="kubeclaw-xxx"}

# GPU Utilization
nvidia_smi_gpu_utilization{pod="kubeclaw-xxx"}

# GPU Temperature
nvidia_smi_temperature_gpu{pod="kubeclaw-xxx"}

# GPU Power Usage
nvidia_smi_power_draw_watts{pod="kubeclaw-xxx"}
```

### Grafana Dashboards
Create a GPU monitoring dashboard:

```json
{
  "panels": [
    {
      "title": "GPU Memory Usage",
      "targets": [
        {"expr": "nvidia_smi_memory_used_bytes{pod=~\"kubeclaw.*\"} / 1024 / 1024 / 1024"}
      ]
    },
    {
      "title": "GPU Utilization",
      "targets": [
        {"expr": "nvidia_smi_gpu_utilization{pod=~\"kubeclaw.*\"}"}
      ]
    }
  ]
}
```

## GPU Troubleshooting

### Pod Stuck in Pending

**Symptoms**: Pod creates but never transitions to Running
```bash
kubectl describe pod -n kubeclaw deployment/kubeclaw | grep -A10 Events
```

**Solutions**:
```bash
# 1. Verify GPU nodes exist
kubectl get nodes -L accelerator

# 2. Check node labels match affinity
kubectl describe node gpu-h100-1 | grep Labels

# 3. Fix node affinity in values.yaml
# Ensure nodePool name matches exactly
```

### GPU Not Detected

**Symptoms**: nvidia-smi command not found in pod
```bash
kubectl exec -n kubeclaw deployment/kubeclaw -- nvidia-smi
# Output: command not found
```

**Solutions**:
```bash
# 1. Verify NVIDIA drivers on node
kubectl node-shell gpu-h100-1 -- nvidia-smi

# 2. Check NVIDIA device plugin pods
kubectl get pods -n kube-system | grep nvidia

# 3. Restart device plugin if not running
kubectl delete pod -n kube-system -l app=nvidia-device-plugin
```

### GPU Memory Exhaustion

**Symptoms**: Pod OOM killed despite having GPU memory
```bash
kubectl logs -n kubeclaw deployment/kubeclaw | grep -i oom
```

**Solutions**:
```bash
# 1. Reduce batch size in OpenClaw config
# (See architecture guide for config location)

# 2. Increase GPU node size (H200 vs H100) — node groups are immutable on
#    the platform field, so delete and recreate
nebius mk8s node-group delete --id <NODE_GROUP_ID>
nebius mk8s node-group create \
  --parent-id "$CLUSTER_ID" \
  --name kubeclaw-gpu-h200 \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h200-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb

# 3. Use GPU memory swapping (slower)
env:
  - name: CUDA_LAUNCH_BLOCKING
    value: "1"
```

### GPU Underutilization

**Symptoms**: GPU shows 0-10% utilization
```bash
# Check GPU metrics
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Query: nvidia_smi_gpu_utilization
```

**Solutions**:
```bash
# 1. Increase batch size
# 2. Run multiple concurrent requests
# 3. Enable tensor operations optimization
env:
  - name: CUDA_LAUNCH_BLOCKING
    value: "0"
  - name: TF_FORCE_GPU_ALLOW_GROWTH
    value: "true"  # For TensorFlow
```

## Multi-GPU Setup (Advanced)

For multiple GPUs in one pod:

```yaml
gpu:
  enabled: true
  count: 2  # 2 GPUs
  resources:
    limits:
      nvidia.com/gpu: 2

env:
  - name: CUDA_VISIBLE_DEVICES
    value: "0,1"  # Both GPUs visible
```

## GPU Scheduling Strategies

### Strategy 1: Dedicated Pod (Default)
Single pod uses all GPU capacity.

**Pros**: Simplicity, no scheduling conflicts
**Cons**: Underutilization if pod doesn't need full GPU

```yaml
# values-gpu.yaml (default)
```

### Strategy 2: Shared Pod Pool
Multiple pods share GPUs with resource fractions.

**Pros**: Better utilization
**Cons**: Complexity, potential performance interference

```yaml
resources:
  limits:
    nvidia.com/gpu: "0.5"  # Half GPU per pod
```

### Strategy 3: Time-Shared GPU
Pods take turns using GPU (context switching).

**Pros**: Highest density
**Cons**: Latency, not suitable for real-time inference

## Cost Optimization

### Calculate Total Cost

```bash
# 1. GPU node cost
GPU_COST_PER_HOUR=4.00  # H100
HOURS_PER_MONTH=720
GPU_NODES=1
MONTHLY_GPU_COST=$((GPU_COST_PER_HOUR * HOURS_PER_MONTH * GPU_NODES))

# 2. General node cost
NODE_COST_PER_HOUR=0.80  # n4-highmem-4
GENERAL_NODES=1
MONTHLY_NODE_COST=$((NODE_COST_PER_HOUR * HOURS_PER_MONTH * GENERAL_NODES))

# 3. Storage cost
STORAGE_GB=100
MONTHLY_STORAGE_COST=$((STORAGE_GB * 0.06))

# Total
TOTAL_COST=$(($MONTHLY_GPU_COST + $MONTHLY_NODE_COST + $MONTHLY_STORAGE_COST))
echo "Monthly cost estimate: \$$TOTAL_COST"
```

### Cost Reduction Strategies

1. **Use smaller GPU**: L40S ($0.50/hr) vs H100 ($4/hr)
2. **Implement auto-scaling**: Scale down GPU nodes during off-hours
3. **Spot instances**: Use preemptible Nebius VMs (40% discount)
4. **GPU sharing**: Run multiple workloads if possible
5. **Batch processing**: Group requests to maximize GPU utilization

## Related Documentation

- [Architecture Guide](architecture.md) - GPU architecture and design
- [Monitoring Setup](monitoring-setup.md) - GPU metric monitoring
- [Troubleshooting](troubleshooting.md) - Common GPU issues

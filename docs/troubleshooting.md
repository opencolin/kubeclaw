# Troubleshooting Guide

Solutions for common KubeClaw deployment and operation issues.

## Pod Issues

### Pod Stuck in Pending

**Symptoms**: Pod created but never transitions to Running

```bash
kubectl describe pod -n kubeclaw deployment/kubeclaw | grep -A20 Events
```

**Possible Causes & Solutions**:

1. **Insufficient resources**
   ```bash
   # Check node capacity
   kubectl describe nodes
   # Look for "Allocatable" resources vs "Allocated resources"
   
   # Solution: Scale up cluster or reduce pod requests
   helm upgrade kubeclaw ./helm/kubeclaw/ \
     -n kubeclaw \
     --set resources.requests.memory=2Gi \
     --set resources.requests.cpu=1
   ```

2. **GPU node pool not ready**
   ```bash
   # Check GPU nodes exist
   kubectl get nodes -L accelerator
   
   # Solution: Add a GPU node group to the cluster
   CLUSTER_ID=$(nebius mk8s cluster get-by-name --name kubeclaw-prod \
     --format json | jq -r .metadata.id)
   nebius mk8s node-group create \
     --parent-id "$CLUSTER_ID" \
     --name kubeclaw-prod-gpu \
     --fixed-node-count 1 \
     --template-resources-platform gpu-h100-sxm \
     --template-resources-preset 1gpu-16vcpu-200gb
   ```

3. **Node affinity mismatch**
   ```bash
   # Check node labels
   kubectl get nodes --show-labels | grep gpu
   
   # Update affinity in values.yaml to match actual labels
   ```

4. **PVC not binding**
   ```bash
   # Check PVC status
   kubectl get pvc -n kubeclaw
   
   # Check PVC events
   kubectl describe pvc -n kubeclaw kubeclaw-pvc | grep -A10 Events
   
   # Solution: Verify storage class exists
   kubectl get storageclass
   ```

### Pod CrashLooping

**Symptoms**: Pod restarts repeatedly with exit code > 0

```bash
# Check restart count
kubectl get pods -n kubeclaw
# Output: kubeclaw-xxx  0/1  CrashLoopBackOff  5  2m

# View logs
kubectl logs -n kubeclaw deployment/kubeclaw
kubectl logs -n kubeclaw deployment/kubeclaw --previous  # Previous attempt
```

**Common Causes & Solutions**:

1. **API key invalid**
   ```bash
   # Check secret exists
   kubectl get secret -n kubeclaw openclaw-secrets
   
   # Verify key format
   kubectl get secret -n kubeclaw openclaw-secrets -o jsonpath='{.data.anthropic-api-key}' | base64 -d | head -c 5
   # Should output: sk-...
   
   # Solution: Update secret with correct key
   kubectl delete secret openclaw-secrets -n kubeclaw
   kubectl create secret generic openclaw-secrets \
     --from-literal=anthropic-api-key='sk-...(correct key)' \
     -n kubeclaw
   ```

2. **OutOfMemory**
   ```bash
   # Check memory limit
   kubectl get pod -n kubeclaw deployment/kubeclaw -o yaml | grep -A5 resources
   
   # Check actual memory usage
   kubectl top pod -n kubeclaw
   
   # Solution: Increase memory limit
   helm upgrade kubeclaw ./helm/kubeclaw/ \
     -n kubeclaw \
     --set resources.limits.memory=16Gi
   ```

3. **Disk space exhausted**
   ```bash
   # Check PVC usage
   kubectl get pvc -n kubeclaw
   
   # Expand PVC
   kubectl patch pvc kubeclaw-pvc -n kubeclaw \
     -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
   ```

### Pod in ImagePullBackOff

**Symptoms**: Error pulling container image

```bash
# Check events
kubectl describe pod -n kubeclaw deployment/kubeclaw | grep -i image
```

**Solutions**:

```bash
# 1. Verify image exists in registry
# Registry URL format: cr.<REGION>.nebius.cloud/<REGISTRY_ID>
nebius iam get-access-token | docker login cr.eu-north1.nebius.cloud --username iam --password-stdin
docker pull cr.eu-north1.nebius.cloud/<REGISTRY_ID>/openclaw:latest

# 2. Create image pull secret (if using private registry)
kubectl create secret docker-registry nebius-registry \
  --docker-server=cr.nebius.cloud \
  --docker-username=<username> \
  --docker-password=<token> \
  -n kubeclaw

# 3. Update Helm values
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set imagePullSecrets[0].name=nebius-registry
```

## Network Issues

### Cannot Access OpenClaw UI

**Symptoms**: Ingress or port-forward doesn't work

```bash
# Check service exists
kubectl get svc -n kubeclaw

# Port forward and test
kubectl port-forward -n kubeclaw svc/kubeclaw 18793:80
curl http://localhost:18793  # Should return HTML
```

**Solutions**:

1. **Service not exposed**
   ```bash
   # Verify service type
   kubectl get svc -n kubeclaw kubeclaw -o yaml | grep type
   
   # Change to LoadBalancer
   helm upgrade kubeclaw ./helm/kubeclaw/ \
     -n kubeclaw \
     --set service.type=LoadBalancer
   
   # Get external IP
   kubectl get svc -n kubeclaw kubeclaw
   ```

2. **Ingress misconfigured**
   ```bash
   # Check Ingress
   kubectl get ingress -n kubeclaw
   kubectl describe ingress -n kubeclaw kubeclaw | grep -A10 Rules
   
   # Verify Ingress controller running
   kubectl get pods -n ingress-nginx
   # If empty, install ingress controller
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm install ingress-nginx ingress-nginx/ingress-nginx
   ```

3. **Network policy blocking**
   ```bash
   # Check network policies
   kubectl get networkpolicies -n kubeclaw
   
   # Temporarily disable to test
   kubectl delete networkpolicies -n kubeclaw --all
   # Re-apply if issue resolved
   ```

### DNS Resolution Issues

**Symptoms**: `getaddrinfo: Name or service not known` errors

```bash
# Test DNS from pod
kubectl exec -n kubeclaw deployment/kubeclaw -- nslookup kubernetes.default
kubectl exec -n kubeclaw deployment/kubeclaw -- nslookup api.anthropic.com
```

**Solutions**:

```bash
# 1. Check CoreDNS running
kubectl get pods -n kube-system | grep coredns

# 2. Check DNS ConfigMap
kubectl get cm -n kube-system coredns -o yaml

# 3. Restart CoreDNS if needed
kubectl rollout restart -n kube-system deployment/coredns
```

## Storage Issues

### PVC Won't Bind

**Symptoms**: PVC stuck in Pending

```bash
kubectl describe pvc -n kubeclaw kubeclaw-pvc | grep -A10 Events
```

**Solutions**:

```bash
# 1. Check storage class exists
kubectl get storageclass

# 2. Use correct storage class
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set persistence.storageClass=nebius-ssd

# 3. Create storage class if missing
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nebius-ssd
provisioner: nebius.cloud/block-storage
parameters:
  type: ssd
EOF
```

### PVC Running Out of Space

**Symptoms**: Pod OOM or disk full errors

```bash
# Check usage
kubectl get pvc -n kubeclaw
df -h  # In pod

# List large files
kubectl exec -n kubeclaw deployment/kubeclaw -- du -sh /home/openclaw/*
```

**Solutions**:

```bash
# 1. Expand PVC
kubectl patch pvc kubeclaw-pvc -n kubeclaw \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# 2. Clean up workspace
kubectl exec -n kubeclaw deployment/kubeclaw -- \
  rm -rf /home/openclaw/workspace/*

# 3. Reduce retention in monitoring
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set monitoring.prometheus.retention=7d
```

## Monitoring Issues

### Metrics Not Appearing in Prometheus

**Symptoms**: Grafana dashboards show no data

```bash
# Check Prometheus targets
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Navigate to Status → Targets in UI

# Check ServiceMonitor
kubectl get servicemonitor -n kubeclaw
```

**Solutions**:

```bash
# 1. Enable monitoring in Helm
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  -f helm/kubeclaw/values-monitoring.yaml

# 2. Verify ServiceMonitor selector matches pod labels
kubectl get pods -n kubeclaw -L app,version

# 3. Check metrics endpoint
kubectl exec -n kubeclaw deployment/kubeclaw -- curl http://localhost:18793/metrics
```

### Alerts Not Firing

**Symptoms**: Alert rules configured but no notifications

```bash
# Check PrometheusRule
kubectl get prometheusrules -n kubeclaw
kubectl describe prometheusrules -n kubeclaw kubeclaw

# Check AlertManager
kubectl logs -n kubeclaw deployment/alertmanager
```

**Solutions**:

```bash
# 1. Verify rule expressions
# Test in Prometheus UI manually

# 2. Check AlertManager receiver configuration
kubectl get secret -n kubeclaw alertmanager-main -o yaml

# 3. Test alert manually
# In Prometheus UI: Alerts tab → manually change threshold
```

## GPU Issues

### GPU Not Detected in Pod

**Symptoms**: `nvidia-smi` returns "command not found"

```bash
# Check node has GPU
kubectl get nodes -L nvidia.com/gpu

# Check GPU scheduling
kubectl get pod -n kubeclaw deployment/kubeclaw -o yaml | grep -A5 nvidia
```

**Solutions**:

```bash
# 1. Verify GPU driver on node
kubectl debug node/<node-name> -it --image=ubuntu

# 2. Check NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia
# If missing, install:
helm repo add nvidia https://nvidia.github.io/k8s-device-plugin
helm install nvidia-device-plugin nvidia/nvidia-device-plugin -n kube-system

# 3. Update node affinity
# Ensure values-gpu.yaml node pool name matches actual pool
```

### GPU Memory Exhaustion

**Symptoms**: CUDA out of memory errors

```bash
# Check GPU memory
kubectl exec -n kubeclaw deployment/kubeclaw -- nvidia-smi
```

**Solutions**:

```bash
# 1. Reduce batch size in config
# (See OpenClaw documentation)

# 2. Upgrade to a larger GPU (e.g. H200 has 141 GB vs H100's 80 GB).
#    Node groups are immutable on the platform field — delete and recreate.
nebius mk8s node-group delete --id <NODE_GROUP_ID>
nebius mk8s node-group create \
  --parent-id "$CLUSTER_ID" \
  --name kubeclaw-prod-gpu-h200 \
  --fixed-node-count 1 \
  --template-resources-platform gpu-h200-sxm \
  --template-resources-preset 1gpu-16vcpu-200gb

# 3. Use GPU memory optimization
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  -f values-gpu.yaml \
  --set env[0].name=CUDA_LAUNCH_BLOCKING \
  --set env[0].value=1
```

## Logging & Debugging

### Enable Verbose Logging

```bash
# Set debug mode
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set debug.enabled=true \
  --set debug.verboseLogging=true

# Check logs
kubectl logs -n kubeclaw deployment/kubeclaw --tail=100 -f
```

### Get Cluster Diagnostics

```bash
# Collect comprehensive info
kubectl cluster-info dump --output-directory=./cluster-dump

# Get pod info
kubectl get pods -n kubeclaw -o yaml > pods.yaml
kubectl get svc -n kubeclaw -o yaml > services.yaml
kubectl get events -n kubeclaw --sort-by='.lastTimestamp' > events.log

# Get node info
kubectl get nodes -o yaml > nodes.yaml
kubectl describe nodes > nodes-describe.log
```

## Performance Issues

### High Latency

**Symptoms**: OpenClaw responses are slow

```bash
# Check metrics
# In Grafana: OpenClaw Overview → API latency

# Check resource usage
kubectl top pods -n kubeclaw
kubectl top nodes
```

**Solutions**:

```bash
# 1. Increase resource limits
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set resources.limits.cpu=8 \
  --set resources.limits.memory=16Gi

# 2. Enable GPU for acceleration
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  -f values-gpu.yaml

# 3. Reduce load on cluster
# Scale down other workloads
```

### High Memory Usage

```bash
# Check actual vs requested
kubectl top pod -n kubeclaw
kubectl get pod -n kubeclaw -o yaml | grep -A5 resources

# Identify memory leaks
# Monitor over time in Grafana
```

## Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `ImagePullBackOff` | Image not found | Verify image path in values.yaml |
| `CrashLoopBackOff` | App crashing | Check logs: `kubectl logs` |
| `Pending` | Resource shortage | Increase cluster size |
| `FailedScheduling` | Node affinity/taint | Fix affinity in values |
| `OutOfMemory` | Memory exhausted | Increase memory limit |
| `Disk full` | PVC exhausted | Expand PVC |

## Getting Help

1. **Check logs**:
   ```bash
   kubectl logs -n kubeclaw deployment/kubeclaw
   ```

2. **Check events**:
   ```bash
   kubectl get events -n kubeclaw --sort-by='.lastTimestamp'
   ```

3. **Check status**:
   ```bash
   kubectl describe pod -n kubeclaw deployment/kubeclaw
   ```

4. **Review architecture**:
   - See [Architecture Guide](architecture.md)

5. **Check FAQ**:
   - See [FAQ](faq.md)

## Still Stuck?

If the troubleshooting steps above don't help:

1. Collect diagnostics:
   ```bash
   kubectl cluster-info dump --output-directory=./cluster-dump
   ```

2. Save all configuration:
   ```bash
   helm get values kubeclaw -n kubeclaw > values-deployed.yaml
   ```

3. Search issues on [GitHub](https://github.com/opencolin/kubeclaw/issues)

4. Contact support with collected information

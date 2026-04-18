# Monitoring & Observability Setup

Configure Prometheus, Grafana, and alerting for OpenClaw.

## Overview

The monitoring stack includes:
- **Prometheus**: Metrics collection and storage
- **Grafana**: Dashboards and visualization
- **AlertManager**: Alert routing and notifications

## 1. Enable Monitoring in Helm

### Option A: Quick Enable
```bash
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f helm/kubeclaw/values-monitoring.yaml \
  --set openclaw.apiKey.secretValue=<your-key>
```

### Option B: Custom Configuration
```yaml
# values-monitoring-custom.yaml
monitoring:
  enabled: true
  prometheus:
    enabled: true
    retention: "30d"
    scrapeInterval: "15s"
  grafana:
    enabled: true
    adminPassword: "your-secure-password"
  alertmanager:
    enabled: true
```

```bash
helm install kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw --create-namespace \
  -f helm/kubeclaw/values.yaml \
  -f values-monitoring-custom.yaml
```

## 2. Verify Monitoring Stack

```bash
# Check pod status
kubectl get pods -n kubeclaw | grep -E 'prometheus|grafana|alertmanager'

# Check services
kubectl get svc -n kubeclaw

# Check Prometheus targets
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Open http://localhost:9090/targets
```

## 3. Access Grafana Dashboard

### Local Access
```bash
# Port forward Grafana
kubectl port-forward -n kubeclaw svc/grafana 3000:80

# Open browser: http://localhost:3000
# Login: admin / changeme (change default password!)
```

### Public Access (via Ingress)
```bash
# Enable Ingress for Grafana
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.hosts[0].host=grafana.example.com

# Get Ingress IP
kubectl get ingress -n kubeclaw grafana
```

## 4. Change Grafana Default Password

**IMPORTANT**: Change the default password immediately.

```bash
# Option 1: Via UI
# 1. Login with admin / changeme
# 2. Click profile icon (top right)
# 3. Change password

# Option 2: Via Helm values
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set grafana.adminPassword="your-new-secure-password"

# Option 3: Via kubectl
kubectl exec -n kubeclaw svc/grafana -it -- grafana-cli admin reset-admin-password new-password
```

## 5. Configure Prometheus Scrape Targets

### Automatic ServiceMonitor
Prometheus automatically scrapes OpenClaw metrics via ServiceMonitor:

```yaml
# Configured in values-monitoring.yaml
serviceMonitor:
  enabled: true
  interval: 30s
```

### Manual Configuration (if needed)
```yaml
# Add to values-monitoring.yaml
prometheus:
  scrapeConfigs:
    - job_name: 'kubeclaw'
      static_configs:
        - targets: ['kubeclaw:18793']
      metrics_path: '/metrics'
      scrape_interval: 30s
```

### Verify Scraping
```bash
# Check targets
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Navigate to Status → Targets in Prometheus UI

# Check for errors
kubectl logs -n kubeclaw deployment/prometheus | grep -i error
```

## 6. Pre-built Grafana Dashboards

### Import Dashboards
```bash
# 1. In Grafana UI: Click + → Import
# 2. Select dashboard JSON from monitoring/dashboards/
# 3. Choose Prometheus as data source

# Or use kubectl to create ConfigMap
kubectl create configmap grafana-dashboards \
  --from-file=monitoring/dashboards/ \
  -n kubeclaw
```

### Available Dashboards

#### 1. OpenClaw Overview
Shows pod status, uptime, restart count, resource allocation.

**Key panels**:
- Pod status (Running, Pending, Failed)
- Uptime percentage
- Restart count
- Resource usage (CPU, Memory)

#### 2. Resource Usage
Detailed CPU, memory, and disk metrics.

**Key panels**:
- CPU usage over time
- Memory usage trend
- PVC usage percentage
- Container restart graph

#### 3. Error Rates
API errors, crash loops, and failure tracking.

**Key panels**:
- Error rate (per minute)
- Crash loop restarts
- Failed pod events
- HTTP error codes (5xx)

### Customize Dashboards
```json
{
  "title": "Custom OpenClaw Dashboard",
  "panels": [
    {
      "title": "Pod Status",
      "targets": [
        {"expr": "kube_pod_status_phase{pod=~\"kubeclaw.*\"}"}
      ]
    },
    {
      "title": "Memory Usage (Gi)",
      "targets": [
        {"expr": "container_memory_usage_bytes{pod=~\"kubeclaw.*\"} / 1024 / 1024 / 1024"}
      ]
    }
  ]
}
```

## 7. Configure Alerts

### Default Alert Rules
Alert rules are configured via PrometheusRules in `values-monitoring.yaml`:

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| CrashLooping | >0.1 restarts/min | 5 min | Critical |
| High Memory | >80% of limit | 5 min | Warning |
| High CPU | >90% of limit | 5 min | Warning |
| PVC Full | <10% available | 5 min | Warning |
| Pod Not Running | Not Running phase | 5 min | Critical |
| GPU Memory Exhaustion | >95% used | 5 min | Critical |

### Add Custom Alerts
```yaml
# monitoring/alerts/custom-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: openclaw-custom
  namespace: kubeclaw
spec:
  groups:
    - name: custom.rules
      interval: 30s
      rules:
        - alert: CustomAlert
          expr: 'some_metric > 100'
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Custom alert triggered"
            description: "Value: {{ $value }}"
```

```bash
kubectl apply -f monitoring/alerts/custom-rules.yaml
```

### Test Alerts
```bash
# Trigger memory alert by running memory-intensive operation
kubectl exec -n kubeclaw deployment/kubeclaw -- \
  stress-ng --vm 1 --vm-bytes 7G --timeout 300s

# Check alert in Prometheus
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Navigate to Alerts tab
```

## 8. AlertManager Configuration

### Default Receivers
Configure where alerts are sent (email, Slack, PagerDuty, etc.):

```yaml
# monitoring/alertmanager/config.yaml
global:
  resolve_timeout: 5m

route:
  receiver: 'default'
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h

receivers:
  - name: 'default'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK_URL'
        channel: '#alerts'
        title: 'Alert: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

### Slack Integration
```bash
# 1. Create Slack app: api.slack.com/apps
# 2. Enable Incoming Webhooks
# 3. Copy webhook URL
# 4. Update AlertManager config

kubectl create secret generic alertmanager-webhook \
  --from-literal=webhook-url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  -n kubeclaw
```

### Email Integration
```yaml
receivers:
  - name: 'email'
    email_configs:
      - to: 'oncall@example.com'
        from: 'alerts@example.com'
        smarthost: 'smtp.gmail.com:587'
        auth_username: 'alerts@example.com'
        auth_password: 'password'
```

## 9. Key Metrics to Monitor

### OpenClaw-Specific Metrics
```promql
# API request rate (requests/sec)
rate(http_requests_total{job="kubeclaw"}[5m])

# API error rate
rate(http_requests_total{job="kubeclaw", status=~"5.."}[5m])

# Average request duration (95th percentile)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{job="kubeclaw"}[5m]))

# Active sessions
openclose_active_sessions{job="kubeclaw"}

# Model inference latency
histogram_quantile(0.95, rate(model_inference_duration_seconds_bucket[5m]))
```

### Kubernetes Metrics
```promql
# Pod CPU usage percentage
(rate(container_cpu_usage_seconds_total{pod="kubeclaw-*"}[5m]) / 4) * 100

# Pod memory usage percentage
(container_memory_usage_bytes{pod="kubeclaw-*"} / container_spec_memory_limit_bytes{pod="kubeclaw-*"}) * 100

# Pod restart count
kube_pod_container_status_restarts_total{pod="kubeclaw-*"}

# PVC usage percentage
(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100
```

## 10. Monitoring Best Practices

### Alerting Strategy
✓ **DO**:
- Alert on business metrics (API errors, latency)
- Alert on resource exhaustion (memory, disk)
- Use meaningful alert names and descriptions
- Set appropriate thresholds based on SLO
- Ensure someone is on-call to respond

✗ **DON'T**:
- Alert on every metric change
- Use generic alert messages
- Ignore alert fatigue (too many false positives)
- Set thresholds without understanding baseline

### Data Retention
```yaml
monitoring:
  prometheus:
    retention: "15d"  # Keep 2 weeks of data
    storageSize: "50Gi"  # Adjust based on volume
```

### Query Performance
- Use time ranges wisely (avoid very long queries)
- Use recording rules for complex calculations
- Downsample data after retention period

## 11. Troubleshooting Monitoring

### Prometheus Not Scraping Metrics
```bash
# 1. Check ServiceMonitor
kubectl get servicemonitor -n kubeclaw

# 2. Check pod labels match selector
kubectl get pod -n kubeclaw -L app,version

# 3. Verify metrics endpoint
kubectl port-forward -n kubeclaw svc/kubeclaw 18793:80
curl http://localhost:18793/metrics
```

### Grafana Data Not Appearing
```bash
# 1. Verify Prometheus as data source
# In Grafana: Configuration → Data Sources → Prometheus

# 2. Check query syntax
# Navigate to Explore tab and test query

# 3. Verify metrics are being collected
kubectl port-forward -n kubeclaw svc/prometheus 9090:9090
# Try querying in Prometheus UI
```

### Out of Memory in Prometheus
```bash
# 1. Check Prometheus resources
kubectl logs -n kubeclaw deployment/prometheus

# 2. Increase PVC size
kubectl patch pvc prometheus -n kubeclaw \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# 3. Reduce retention period
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set monitoring.prometheus.retention=7d
```

## Related Documentation

- [Architecture Guide](architecture.md) - Monitoring architecture
- [Troubleshooting](troubleshooting.md) - Common issues
- [Security Hardening](security-hardening.md) - Secure monitoring access

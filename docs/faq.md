# Frequently Asked Questions

## General

**Q: What's the difference between OpenClaw and NemoClaw?**
A: OpenClaw is Anthropic's open-source AI orchestration platform; NemoClaw is NVIDIA's variant with enhanced GPU support. KubeClaw supports both.

**Q: Can I run OpenClaw outside Kubernetes?**
A: Yes, see [OpenClaw repository](https://github.com/anthropics/openClaw) for Docker and bare-metal installation guides.

**Q: Is KubeClaw production-ready?**
A: Yes, with security hardening enabled (see [Security Guide](security-hardening.md)). Monitor the deployment closely for the first week.

## Deployment

**Q: How long does deployment take?**
A: ~10 minutes for basic setup, ~15 minutes with GPU node pool creation.

**Q: Can I deploy without GPU?**
A: Yes, GPU is optional. Deployment works on CPU-only clusters but with slower inference.

**Q: What's the minimum cluster size?**
A: 2 nodes (`n4-highmem-4` type) minimum; 3 nodes recommended for production.

**Q: Can I scale horizontally (multiple replicas)?**
A: No, OpenClaw is designed as single-instance. For high availability, use backup/restore instead.

## Costs

**Q: How much does it cost to run KubeClaw?**
A: Approximately $100-200/month for basic setup (2 nodes). With H100 GPU: ~$3,000/month.

**Q: Can I reduce costs?**
A: Yes:
- Use smaller node types (`n4-standard-2` vs `n4-highmem-4`)
- Disable GPU if not needed
- Use Spot instances (40% cheaper, but preemptible)
- Reduce storage size (default 50GB is generous)

**Q: Am I charged for unused resources?**
A: Yes, stopped clusters still incur storage costs. Delete unused clusters.

## Storage

**Q: How much storage does OpenClaw need?**
A: Default 50GB. Usage depends on:
- Workspace size: ~5-10GB per 100 sessions
- Model cache: ~5-50GB depending on models
- Buffer: Keep 20-30% free

**Q: Can I use cheaper storage (standard vs SSD)?**
A: Yes, but performance degrades. Not recommended for production.

**Q: How do I backup data?**
A: Use Nebius PVC snapshots or manual `kubectl cp`:
```bash
kubectl cp kubeclaw/kubeclaw-pvc:/home/openclaw ./backup -n kubeclaw
```

## Monitoring

**Q: Why aren't metrics appearing in Grafana?**
A: Check:
1. Prometheus is running: `kubectl get pods -n kubeclaw | grep prometheus`
2. OpenClaw metrics endpoint is accessible
3. ServiceMonitor selector matches pod labels

See [Monitoring Troubleshooting](troubleshooting.md#metrics-not-appearing-in-prometheus)

**Q: Can I send alerts to Slack?**
A: Yes, configure AlertManager webhook in [monitoring setup](monitoring-setup.md#slack-integration).

**Q: How long are metrics retained?**
A: Default 15 days. Change with: `--set monitoring.prometheus.retention=30d`

## Security

**Q: Where should I store the API key?**
A: In Kubernetes Secrets, never in ConfigMaps or environment variables. See [Secret Management](security-hardening.md#4-secret-management).

**Q: How often should I rotate API keys?**
A: Every 90 days. See [API Key Rotation](security-hardening.md#rotate-api-keys-regularly).

**Q: Is network traffic encrypted?**
A: Yes, enable TLS in Ingress and use HTTPS to external APIs. See [TLS Configuration](security-hardening.md#6-tlshttps-configuration).

**Q: Can I restrict network access?**
A: Yes, via NetworkPolicies. See [Network Policies](security-hardening.md#2-network-policies).

## GPU

**Q: Which GPU should I use?**
A: 
- H100: Best performance (~$4/hr)
- H200: Great performance, more memory (~$3.5/hr)
- L40S: For small models (~$0.5/hr)

**Q: Can I use multiple GPUs?**
A: Yes, but OpenClaw doesn't natively support multi-GPU inference. See [Multi-GPU Setup](gpu-configuration.md#multi-gpu-setup-advanced).

**Q: How do I verify GPU is working?**
A: Run `kubectl exec ... -- nvidia-smi` and check Prometheus metrics.

## Troubleshooting

**Q: Pod is stuck in Pending.**
A: Check resources: `kubectl describe pod`. See [Troubleshooting Guide](troubleshooting.md#pod-stuck-in-pending).

**Q: Pod keeps restarting.**
A: Check logs: `kubectl logs deployment/kubeclaw`. Usually API key or resource issues.

**Q: Cannot connect to OpenClaw UI.**
A: Port forward and test: `kubectl port-forward svc/kubeclaw 18793:80`. See [Troubleshooting Guide](troubleshooting.md#cannot-access-openclaw-ui).

**Q: High latency or timeouts.**
A: Increase resources or enable GPU. Check metrics in Grafana.

## Updates & Maintenance

**Q: How do I update OpenClaw?**
A: Update the Helm chart:
```bash
helm repo update
helm upgrade kubeclaw kubeclaw/kubeclaw -n kubeclaw
```

**Q: Do updates cause downtime?**
A: Yes, briefly. OpenClaw uses `Recreate` strategy (no rolling updates). Sessions are preserved via persistent storage.

**Q: How do I backup before updating?**
A: Create PVC snapshot:
```bash
# Nebius console or kubectl apply VolumeSnapshot
```

**Q: Can I rollback if update fails?**
A: Yes:
```bash
helm rollback kubeclaw -n kubeclaw
```

## Support

**Q: Who maintains KubeClaw?**
A: The open-source community. See [GitHub repository](https://github.com/opencolin/kubeclaw).

**Q: Where can I report issues?**
A: [GitHub Issues](https://github.com/opencolin/kubeclaw/issues)

**Q: Is there commercial support?**
A: Not official, but community support available on GitHub Discussions.

## Advanced

**Q: Can I customize OpenClaw configuration?**
A: Yes, edit `ConfigMap` or pass environment variables. See [Architecture Guide](architecture.md).

**Q: Can I use a different model?**
A: Yes:
```bash
helm upgrade kubeclaw ./helm/kubeclaw/ -n kubeclaw --set openclaw.model=claude-opus-4-1
```

**Q: How do I integrate with external systems?**
A: OpenClaw supports webhooks and APIs. See OpenClaw documentation.

**Q: Can I run multiple deployments?**
A: Yes, create separate Helm releases or namespaces. Be mindful of cluster capacity.

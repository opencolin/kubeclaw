# Security Hardening Guide

Implement defense-in-depth security for OpenClaw on Nebius Kubernetes.

## Security Architecture

```
┌─────────────────────────────────────┐
│ External Access (Ingress Layer)     │
│ - Network policies (firewall)       │
│ - TLS/HTTPS enforcement             │
│ - Authentication (optional)         │
└──────────┬──────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│ Pod Security                         │
│ - Non-root user                     │
│ - Read-only filesystem              │
│ - No privilege escalation           │
│ - Dropped capabilities              │
└──────────┬──────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│ Secret Management                    │
│ - API keys in Secrets               │
│ - Never in ConfigMaps               │
│ - RBAC access controls              │
│ - External secret providers         │
└──────────┬──────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│ Data Protection                      │
│ - Encryption at rest (optional)     │
│ - PVC snapshots                     │
│ - Backup retention                  │
└─────────────────────────────────────┘
```

## 1. Pod Security Context

### Default Configuration
```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: true
```

### Enforce with Pod Security Policy
```yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: openclaw-restricted
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'MustRunAs'
    seLinuxOptions:
      level: 's0:c123,c456'
  readOnlyRootFilesystem: true
```

```bash
kubectl apply -f security/pod-security-policy.yaml
```

## 2. Network Policies

### Default Deny Incoming
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: kubeclaw
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

### Allow OpenClaw Traffic
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-openclaw
  namespace: kubeclaw
spec:
  podSelector:
    matchLabels:
      app: openclaw
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: kubeclaw
    ports:
    - protocol: TCP
      port: 18793
    - protocol: TCP
      port: 18789
```

### Restrict Egress
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
  namespace: kubeclaw
spec:
  podSelector:
    matchLabels:
      app: openclaw
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
  # Allow HTTPS to external APIs
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443
  # Allow to Kubernetes API
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 6443
```

**Verify**:
```bash
kubectl get networkpolicies -n kubeclaw
kubectl describe networkpolicy allow-openclaw -n kubeclaw
```

## 3. RBAC Configuration

### Service Account
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openclaw
  namespace: kubeclaw
```

### Role (Namespace-scoped)
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openclaw
  namespace: kubeclaw
rules:
# Read pod information
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
# Create/manage jobs if needed
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["create", "get", "list", "watch", "patch"]
```

### RoleBinding
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openclaw
  namespace: kubeclaw
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: openclaw
subjects:
- kind: ServiceAccount
  name: openclaw
  namespace: kubeclaw
```

**Verify least privilege**:
```bash
# Check what permissions are granted
kubectl auth can-i create pods --as=system:serviceaccount:kubeclaw:openclaw
# Output: no
```

## 4. Secret Management

### Store API Key in Secret
```bash
# Create secret with API key
kubectl create secret generic openclaw-secrets \
  --from-literal=anthropic-api-key='sk-...' \
  -n kubeclaw

# Verify (will show encoded value)
kubectl get secret openclaw-secrets -n kubeclaw -o yaml

# Never store in ConfigMap!
# ✗ Bad: kubectl create configmap openclaw-config --from-literal=api-key='sk-...'
```

### Use External Secrets Operator (Recommended for Production)
```bash
# Install external-secrets
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Create SecretStore pointing to Nebius Secret Manager
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: nebius-secrets
  namespace: kubeclaw
spec:
  provider:
    nebius:
      auth:
        workloadIdentity: {}
      apiEndpoint: "api.nebius.cloud:443"
      projectId: "your-project-id"
```

## 5. Encryption

### Enable etcd Encryption (Cluster-level)
```bash
# In Nebius mk8s, this is typically enabled by default
# Verify with:
kubectl get secret -n kubeclaw -o json | jq '.items[0].metadata.managedFields[0].time'
```

### Encrypt Persistent Volumes
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-ssd
provisioner: nebius.cloud/block-storage
parameters:
  type: ssd
  encrypted: "true"
```

### Encrypt Backups
```bash
# PVC Snapshots with encryption
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: openclaw-snapshot
  namespace: kubeclaw
spec:
  volumeSnapshotClassName: nebius-csi-snapshotclass
  source:
    persistentVolumeClaimName: openclaw-pvc
```

## 6. TLS/HTTPS Configuration

### Enable Ingress TLS
```yaml
ingress:
  enabled: true
  tls:
  - secretName: openclaw-tls
    hosts:
    - openclaw.example.com
  hosts:
  - host: openclaw.example.com
    paths:
    - path: /
      pathType: Prefix
```

### Create TLS Certificate
```bash
# Using Let's Encrypt + cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace

# Create ClusterIssuer
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
```

## 7. Audit Logging

### Enable Kubernetes Audit
```bash
# Nebius mk8s streams control-plane audit logs to Nebius Cloud Logging by
# default. Configuration lives in the Nebius Console under the cluster's
# "Logging" tab (no dedicated nebius CLI flag at time of writing).
```

### Monitor Audit Logs
```bash
# Access audit logs from Nebius console
# Or stream to external system (ELK, Datadog, etc.)
```

## 8. Image Security

### Use Private Container Registry
```yaml
imagePullSecrets:
- name: nebius-registry-secret

---
apiVersion: v1
kind: Secret
metadata:
  name: nebius-registry-secret
  namespace: kubeclaw
type: kubernetes.io/dockercfg
data:
  .dockercfg: <base64-encoded-registry-credentials>
```

### Image Scanning
```bash
# Scan OpenClaw image for vulnerabilities
trivy image cr.nebius.cloud/opencloudconsole/openclaw:latest

# In CI/CD, block deployment if vulnerabilities found
```

### Image Signing & Verification
```bash
# Sign images with Cosign
cosign sign cr.nebius.cloud/opencloudconsole/openclaw:latest

# Verify in Kubernetes admission controller
```

## 9. API Key Protection

### Rotate API Keys Regularly
```bash
# Create new secret with rotated key
kubectl create secret generic openclaw-secrets-v2 \
  --from-literal=anthropic-api-key='sk-...(new key)' \
  -n kubeclaw

# Update Helm values to use new secret
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set openclaw.apiKey.secretName=openclaw-secrets-v2

# Delete old secret after rollout
kubectl delete secret openclaw-secrets -n kubeclaw
```

### Never Log API Keys
```yaml
# Ensure logging configuration doesn't expose secrets
env:
  - name: LOG_LEVEL
    value: "info"
  - name: LOG_SENSITIVE_DATA
    value: "false"  # Don't log API keys, tokens, etc.
```

## 10. Security Checklist

### Pre-Deployment
- [ ] API key stored in Secret (not ConfigMap)
- [ ] Non-root pod security context enforced
- [ ] Network policies restrict traffic
- [ ] RBAC roles follow principle of least privilege
- [ ] TLS/HTTPS enabled for all external access
- [ ] Image pulled from trusted registry
- [ ] Pod security policies enforced

### Post-Deployment
- [ ] Audit logs enabled
- [ ] Monitoring and alerting configured
- [ ] Backup/snapshot strategy in place
- [ ] Access logs reviewed regularly
- [ ] Vulnerability scans completed
- [ ] Security updates applied timely

### Ongoing
- [ ] Monthly security review
- [ ] API key rotation (every 90 days)
- [ ] Backup integrity verification
- [ ] Network policy audit
- [ ] RBAC access review

## 11. Incident Response

### Compromised API Key
```bash
# 1. Immediately revoke old key in Anthropic Console
# 2. Create new secret
kubectl create secret generic openclaw-secrets \
  --from-literal=anthropic-api-key='sk-...(new key)' \
  -n kubeclaw --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart pod
kubectl delete pod -n kubeclaw -l app=openclaw

# 4. Review API usage
# Check in Anthropic Console for suspicious activity
```

### Suspected Intrusion
```bash
# 1. Enable verbose logging
helm upgrade kubeclaw ./helm/kubeclaw/ \
  -n kubeclaw \
  --set debug.enabled=true

# 2. Collect pod logs
kubectl logs -n kubeclaw deployment/kubeclaw > incident.log

# 3. Review network policies
kubectl describe networkpolicies -n kubeclaw

# 4. Check access logs
kubectl get events -n kubeclaw --sort-by='.lastTimestamp'
```

## Related Documentation

- [Architecture Guide](architecture.md) - Security architecture
- [Monitoring Setup](monitoring-setup.md) - Security monitoring
- [Troubleshooting](troubleshooting.md) - Security issues

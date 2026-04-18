#!/bin/bash
# KubeClaw Deployment Verification Script

set -e

NAMESPACE="${KUBECLAW_NAMESPACE:-kubeclaw}"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_pass() { echo -e "${GREEN}✓${NC} $1"; }
check_fail() { echo -e "${RED}✗${NC} $1"; }
check_warn() { echo -e "${YELLOW}⚠${NC} $1"; }

echo "KubeClaw Deployment Verification"
echo "=================================="
echo

# 1. Pod Status
echo "1. Pod Status:"
POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=kubeclaw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  check_fail "Pod not found"
else
  STATUS=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}')
  if [ "$STATUS" = "Running" ]; then
    check_pass "Pod is running: $POD"
  else
    check_warn "Pod status: $STATUS"
  fi
fi

# 2. PVC Status
echo
echo "2. Storage:"
PVC=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PVC" ]; then
  check_warn "No PVC found"
else
  PVC_STATUS=$(kubectl get pvc -n "$NAMESPACE" "$PVC" -o jsonpath='{.status.phase}')
  if [ "$PVC_STATUS" = "Bound" ]; then
    check_pass "PVC is bound: $PVC"
  else
    check_fail "PVC status: $PVC_STATUS"
  fi
fi

# 3. Service Status
echo
echo "3. Service:"
SVC=$(kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=kubeclaw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$SVC" ]; then
  check_fail "Service not found"
else
  check_pass "Service is available: $SVC"
  SVC_IP=$(kubectl get svc -n "$NAMESPACE" "$SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "ClusterIP")
  echo "  IP: $SVC_IP"
fi

# 4. Health Check
echo
echo "4. API Health:"
if [ -n "$POD" ]; then
  HEALTH=$(kubectl exec -n "$NAMESPACE" "$POD" -- curl -s http://localhost:18793/health 2>/dev/null || echo "failed")
  if [ "$HEALTH" != "failed" ]; then
    check_pass "Health check passed"
  else
    check_warn "Health check failed or endpoint unreachable"
  fi
fi

# 5. Monitoring Stack
echo
echo "5. Monitoring Stack:"
PROM=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/instance=kubeclaw,app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROM" ]; then
  check_warn "Prometheus not deployed (monitoring may be disabled)"
else
  PROM_STATUS=$(kubectl get pod -n "$NAMESPACE" "$PROM" -o jsonpath='{.status.phase}')
  if [ "$PROM_STATUS" = "Running" ]; then
    check_pass "Prometheus is running"
  else
    check_warn "Prometheus status: $PROM_STATUS"
  fi
fi

GRAFANA=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$GRAFANA" ]; then
  check_warn "Grafana not deployed"
else
  GRAFANA_STATUS=$(kubectl get pod -n "$NAMESPACE" "$GRAFANA" -o jsonpath='{.status.phase}')
  if [ "$GRAFANA_STATUS" = "Running" ]; then
    check_pass "Grafana is running"
  else
    check_warn "Grafana status: $GRAFANA_STATUS"
  fi
fi

# 6. GPU (if enabled)
echo
echo "6. GPU Configuration:"
GPU_ENABLED=$(kubectl get deployment -n "$NAMESPACE" kubeclaw -o yaml | grep -c 'nvidia.com/gpu' || echo "0")
if [ "$GPU_ENABLED" -gt 0 ]; then
  GPU_COUNT=$(kubectl get pod -n "$NAMESPACE" "$POD" -o yaml | grep 'nvidia.com/gpu' | head -1 | grep -oE '[0-9]+$' || echo "?")
  check_pass "GPU is configured: $GPU_COUNT GPU(s)"
else
  check_warn "GPU not configured"
fi

# 7. Network Policies
echo
echo "7. Security:"
NP=$(kubectl get networkpolicies -n "$NAMESPACE" 2>/dev/null | wc -l)
if [ "$NP" -gt 1 ]; then
  check_pass "Network policies are configured"
else
  check_warn "Network policies not configured"
fi

# Summary
echo
echo "=================================="
echo "Verification Complete"
echo
echo "Next steps:"
echo "  - Review pod logs: kubectl logs -n $NAMESPACE -f deployment/kubeclaw"
echo "  - Access OpenClaw: kubectl port-forward -n $NAMESPACE svc/kubeclaw 18793:80"
echo "  - Access Grafana: kubectl port-forward -n $NAMESPACE svc/grafana 3000:80"
echo

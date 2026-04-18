#!/bin/bash
# KubeClaw Cleanup Script

NAMESPACE="${KUBECLAW_NAMESPACE:-kubeclaw}"
CLUSTER_NAME="${KUBECLAW_CLUSTER_NAME:-kubeclaw-prod}"
REMOVE_CLUSTER=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --remove-cluster) REMOVE_CLUSTER=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "KubeClaw Cleanup"
echo "================"
echo
echo "This will remove:"
echo "  - Helm release: kubeclaw"
echo "  - Namespace: $NAMESPACE"
if [ "$REMOVE_CLUSTER" = true ]; then
  echo "  - Nebius mk8s cluster: $CLUSTER_NAME (ALL DATA LOST)"
  echo "  - Associated VPC network and subnet"
fi
echo

read -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Cleanup cancelled."
  exit 0
fi

echo "Removing Helm release..."
helm uninstall kubeclaw -n "$NAMESPACE" --wait || true

echo "Removing namespace..."
kubectl delete namespace "$NAMESPACE" --wait=true || true

if [ "$REMOVE_CLUSTER" = true ]; then
  echo "Looking up cluster ID..."
  CLUSTER_ID=$(nebius mk8s cluster get-by-name --name "$CLUSTER_NAME" --format json 2>/dev/null | \
    grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

  if [ -n "$CLUSTER_ID" ]; then
    echo "Deleting node groups..."
    nebius mk8s node-group list --parent-id "$CLUSTER_ID" --format json 2>/dev/null | \
      grep -oE '"id":\s*"computenodegroup-[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | \
      while read NG_ID; do
        echo "  Deleting node group: $NG_ID"
        nebius mk8s node-group delete --id "$NG_ID" || true
      done

    echo "Deleting cluster: $CLUSTER_ID"
    nebius mk8s cluster delete --id "$CLUSTER_ID"

    echo "Cleaning up VPC resources..."
    SUBNET_ID=$(nebius vpc subnet get-by-name --name "${CLUSTER_NAME}-subnet" --format json 2>/dev/null | \
      grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$SUBNET_ID" ] && nebius vpc subnet delete --id "$SUBNET_ID" || true

    NETWORK_ID=$(nebius vpc network get-by-name --name "${CLUSTER_NAME}-network" --format json 2>/dev/null | \
      grep -oE '"id":\s*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$NETWORK_ID" ] && nebius vpc network delete --id "$NETWORK_ID" || true
  else
    echo "Cluster not found: $CLUSTER_NAME"
  fi
fi

echo "Cleanup complete."

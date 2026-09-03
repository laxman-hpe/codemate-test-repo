#!/usr/bin/env bash

set -euo pipefail

for cmd in kubectl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required tool '$cmd' is not installed or not in PATH."
    exit 1
  fi
done

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <namespace-1> [namespace-2 ... namespace-N]"
  exit 1
fi

# Function to check if a resource is auto-injected by Kubernetes/Istio/Mesh
is_ignored_resource() {
  local kind="$1"
  local name="$2"

  case "$kind" in
    configmaps|configmap|cm)
      case "$name" in
        ezaf-root-ca|istio-ca-root-cert|kube-root-ca.crt)
          return 0
          ;;
      esac
      ;;
    serviceaccounts|serviceaccount|sa)
      case "$name" in
        default)
          return 0
          ;;
      esac
      ;;
  esac

  return 1
}

inspect_stuck_resource() {
  local kind="$1"
  local name="$2"
  local ns="$3"

  echo "  [DIAGNOSIS] Inspecting $kind/$name in namespace '$ns':"

  local json
  if ! json=$(kubectl get "$kind" "$name" -n "$ns" -o json 2>/dev/null); then
    echo "    - Resource vanished or could not be queried."
    return
  fi

  local finalizers
  finalizers=$(echo "$json" | jq -r '.metadata.finalizers // [] | .[]' 2>/dev/null || true)
  if [ -n "$finalizers" ]; then
    echo "    - BLOCKED BY FINALIZERS:"
    while IFS= read -r fin; do
      echo "        * $fin"
    done <<< "$finalizers"
  fi

  local deletion_ts
  deletion_ts=$(echo "$json" | jq -r '.metadata.deletionTimestamp // empty')
  if [ -n "$deletion_ts" ]; then
    echo "    - Status: Deletion in progress (DeletionTimestamp: $deletion_ts)"
  fi
}

clean_namespace() {
  local ns="$1"
  echo "=================================================="
  echo "Processing Namespace: $ns"
  echo "=================================================="

  if ! kubectl get namespace "$ns" &> /dev/null; then
    echo "[-] Namespace '$ns' does not exist. Skipping."
    return
  fi

  # 1. Scale down workloads to stop pods and PVC recreation
  echo "[1/4] Scaling down workloads (StatefulSets, Deployments)..."
  kubectl scale statefulset --all --replicas=0 -n "$ns" --timeout=10s &> /dev/null || true
  kubectl scale deployment --all --replicas=0 -n "$ns" --timeout=10s &> /dev/null || true

  # 2. Delete workload controllers and CRDs first
  echo "[2/4] Deleting workload controllers..."
  kubectl delete statefulsets,deployments,daemonsets,replicasets,jobs,cronjobs --all -n "$ns" --force --grace-period=0 --timeout=10s &> /dev/null || true

  # 3. Discover and delete all remaining resources (skipping ignored system resources)
  echo "[3/4] Deleting remaining API resources and storage..."
  local resource_types
  resource_types=$(kubectl api-resources --verbs=delete --namespaced -o name 2>/dev/null | grep -v 'events' || true)

  for rtype in $resource_types; do
    local items
    items=$(kubectl get "$rtype" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$items" ]; then
      for item in $items; do
        if is_ignored_resource "$rtype" "$item"; then
          continue
        fi
        kubectl delete "$rtype" "$item" -n "$ns" --force --grace-period=0 --timeout=5s &> /dev/null || true
      done
    fi
  done

  # 4. Verify & diagnose remaining items (skipping ignored system resources)
  echo "[4/4] Verifying state..."
  sleep 2

  local remaining_found=0
  for rtype in $resource_types; do
    local remaining_items
    remaining_items=$(kubectl get "$rtype" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$remaining_items" ]; then
      for item in $remaining_items; do
        if is_ignored_resource "$rtype" "$item"; then
          continue
        fi
        remaining_found=1
        echo "[!] STUCK RESOURCE: $rtype/$item"
        inspect_stuck_resource "$rtype" "$item" "$ns"
      done
    fi
  done

  if [ "$remaining_found" -eq 0 ]; then
    echo "[+] Namespace '$ns' successfully cleaned."
  else
    echo "[-] Namespace '$ns' has stuck user resources remaining."
  fi

  echo "[*] Deleting namespace '$ns'..."
  kubectl delete namespace "$ns" --timeout=30s
}

for target_ns in "$@"; do
  clean_namespace "$target_ns"
  echo ""
done

#!/usr/bin/env bash
# Registers a remote cluster in the HUB's Argo CD, so a gitops/services/<app>/app.yaml can
# target it with `destination: { cluster: <name> }`. The declarative equivalent of
# `argocd cluster add`, without needing an argocd CLI login.
#
#   scripts/register-argo-cluster.sh <hub-kube-context> <cluster-kube-context> <name>
#
# On the remote cluster: ServiceAccount kube-system/argocd-manager, bound to cluster-admin
# (what `argocd cluster add` creates too — the ApplicationSet deploys arbitrary charts,
# CRDs and webhooks included), plus a long-lived token Secret for it.
# On the hub: the Argo cluster Secret `cluster-<name>` in openshift-gitops.
#
# The token is a credential to the remote cluster and lives ONLY in those two Secrets —
# never in git. Idempotent; re-running refreshes the hub Secret from the current token.
# Rotate by deleting kube-system/argocd-manager-token on the remote and re-running.
set -euo pipefail

hub_ctx="$1"
cluster_ctx="$2"
name="$3"
argo_ns="${ARGO_NAMESPACE:-openshift-gitops}"

remote() { oc --context "$cluster_ctx" "$@"; }

remote apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

token=""
for _ in $(seq 1 30); do
  token=$(remote get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
  [[ -n "$token" ]] && break
  sleep 2
done
[[ -n "$token" ]] || { echo "register: token controller never populated argocd-manager-token" >&2; exit 1; }

server=$(oc config view --minify --context "$cluster_ctx" -o jsonpath='{.clusters[0].cluster.server}')
# CA bundle that signs the API's EXTERNAL cert (on OpenShift, kube-apiserver-lb-signer is
# in this bundle). Not the kubeconfig's CA: a kubeconfig made with insecure-skip-tls has none.
ca=$(remote get cm kube-apiserver-server-ca -n openshift-kube-apiserver -o jsonpath='{.data.ca-bundle\.crt}')

config=$(jq -n --arg t "$token" --arg ca "$(printf '%s' "$ca" | base64 | tr -d '\n')" \
  '{bearerToken: $t, tlsClientConfig: {insecure: false, caData: $ca}}')

oc --context "$hub_ctx" create secret generic "cluster-${name}" -n "$argo_ns" \
  --from-literal=name="$name" \
  --from-literal=server="$server" \
  --from-literal=config="$config" \
  --dry-run=client -o yaml |
  oc --context "$hub_ctx" label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml |
  oc --context "$hub_ctx" apply -f -

echo "register: $name ($server) registered in $argo_ns"

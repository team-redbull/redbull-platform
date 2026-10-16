#!/usr/bin/env bash
# End-to-end check of Vault + ESO on one cluster. Run it against every cluster after
# onboarding, and after any change to charts/vault or gitops/charts/external-secrets.
#
#   charts/vault/scripts/smoke-test.sh <hub-kube-context> <cluster-kube-context> <cluster-name> [<other-cluster-name>]
#
# <cluster-name> is the cluster's name in Vault (environments/default.yaml vault.clusters);
# for the hub itself pass the hub context twice and `hub`. <other-cluster-name> (default:
# a name that is not this one) is used for the isolation check.
#
# Proves, in order:
#   1. ClusterSecretStore `vault` is Ready (auth mount, role, TLS, network all work)
#   2. reads kv/shared/*                              (every cluster may)
#   3. reads kv/clusters/<cluster-name>/*             (its own subtree)
#   4. builds a value from several fields             (target.template — the Mongo-URL pattern)
#   5. picks up a value changed in Vault              (force-sync annotation)
#   6. is DENIED kv/clusters/<other>/*                (policy isolation — 403, no Secret)
#   7. PushSecret writes a generated password to kv/clusters/<cluster-name>/generated/*
# and cleans up everything it created unless KEEP=1.
#
# Token for writing the test values: VAULT_TOKEN, else the lab-mode root token in
# vault/vault-init on the hub.
set -euo pipefail

hub_ctx="$1"
ctx="$2"
name="$3"
other="${4:-not-${name}}"
ns=eso-smoke
vault_ns=vault
run_id=$(date +%s)

pass=0
fail=0
ok() { echo "  PASS  $*"; pass=$((pass + 1)); }
ko() { echo "  FAIL  $*"; fail=$((fail + 1)); }

token="${VAULT_TOKEN:-$(oc --context "$hub_ctx" get secret vault-init -n "$vault_ns" -o jsonpath='{.data.root-token}' | base64 -d)}"
v() {
  { printf '%s\n' "$token"; } |
    oc --context "$hub_ctx" exec -i -n "$vault_ns" vault-0 -c vault -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"
}
k() { oc --context "$ctx" "$@"; }

# Wait for a Secret key to hold an expected value; prints the last value seen on failure.
wait_value() {
  local secret="$1" key="$2" want="$3" got=""
  for _ in $(seq 1 30); do
    got=$(k get secret "$secret" -n "$ns" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ "$got" == "$want" ]] && return 0
    sleep 3
  done
  echo "    (secret $secret key $key = '$got', wanted '$want')"
  return 1
}

cleanup() {
  [[ "${KEEP:-0}" == "1" ]] && { echo "KEEP=1 — leaving namespace $ns and the kv test paths"; return; }
  k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for p in "shared/eso-smoke-${name}" "clusters/${name}/eso-smoke" "clusters/${name}/generated/eso-smoke"; do
    v kv metadata delete "kv/${p}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

echo "== smoke test: cluster '$name' (context $ctx)"

# --- 1. store ------------------------------------------------------------------------
if [[ "$(k get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; then
  ok "ClusterSecretStore vault is Ready"
else
  ko "ClusterSecretStore vault is not Ready: $(k get clustersecretstore vault -o jsonpath='{.status.conditions[*].message}' 2>&1)"
fi

# --- test data in Vault --------------------------------------------------------------
v kv put "kv/shared/eso-smoke-${name}" value="shared-${run_id}" user=smoke password="pw-${run_id}" >/dev/null
v kv put "kv/clusters/${name}/eso-smoke" value="own-${run_id}" >/dev/null
v kv put "kv/clusters/${other}/eso-smoke" value="forbidden-${run_id}" >/dev/null

k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -n "$ns" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: shared
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault }
  target: { name: shared }
  data:
    - secretKey: value
      remoteRef: { key: shared/eso-smoke-${name}, property: value }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: own
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault }
  target: { name: own }
  data:
    - secretKey: value
      remoteRef: { key: clusters/${name}/eso-smoke, property: value }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: templated
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault }
  target:
    name: templated
    template:
      data:
        url: "mongodb://{{ .user }}:{{ .password }}@db.example.svc:27017/app?authSource=app"
  data:
    - secretKey: user
      remoteRef: { key: shared/eso-smoke-${name}, property: user }
    - secretKey: password
      remoteRef: { key: shared/eso-smoke-${name}, property: password }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: forbidden
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault }
  target: { name: forbidden }
  data:
    - secretKey: value
      remoteRef: { key: clusters/${other}/eso-smoke, property: value }
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: generated
spec:
  length: 24
  digits: 4
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: generated
spec:
  refreshInterval: 1h
  updatePolicy: Replace
  deletionPolicy: Delete
  secretStoreRefs:
    - { kind: ClusterSecretStore, name: vault }
  selector:
    generatorRef:
      apiVersion: generators.external-secrets.io/v1alpha1
      kind: Password
      name: generated
  data:
    - match:
        secretKey: password
        remoteRef: { remoteKey: clusters/${name}/generated/eso-smoke, property: password }
EOF

# --- 2-4. reads ----------------------------------------------------------------------
wait_value shared value "shared-${run_id}" && ok "reads kv/shared/*" || ko "reads kv/shared/*"
wait_value own value "own-${run_id}" && ok "reads kv/clusters/${name}/*" || ko "reads kv/clusters/${name}/*"
wait_value templated url "mongodb://smoke:pw-${run_id}@db.example.svc:27017/app?authSource=app" &&
  ok "target.template composes a URL from fields" || ko "target.template composes a URL from fields"

# --- 5. update -----------------------------------------------------------------------
v kv patch "kv/shared/eso-smoke-${name}" value="shared-${run_id}-v2" >/dev/null
k annotate externalsecret shared -n "$ns" force-sync="$(date +%s)" --overwrite >/dev/null
wait_value shared value "shared-${run_id}-v2" && ok "picks up a changed value (force-sync)" ||
  ko "picks up a changed value (force-sync)"

# --- 6. isolation --------------------------------------------------------------------
denied=""
for _ in $(seq 1 20); do
  denied=$(k get externalsecret forbidden -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
  [[ -n "$denied" ]] && break
  sleep 3
done
# The failure must be Vault's 403 — any sync error (a typo'd store, a network blip) would
# also leave no Secret, and must not count as proof the policy works. ESO keeps the
# provider's message in the controller log; the event carries the generic reason only.
forbidden_403=$(k logs -n external-secrets deploy/external-secrets --since=10m 2>/dev/null |
  grep "eso-smoke" | grep '"forbidden"' | grep -ciE 'permission denied|403' || true)
if k get secret forbidden -n "$ns" >/dev/null 2>&1; then
  ko "isolation: Secret 'forbidden' was created from kv/clusters/${other}/ — policy leak"
elif [[ "$denied" == "SecretSyncedError" && "$forbidden_403" -gt 0 ]]; then
  ok "isolation: kv/clusters/${other}/* is denied by Vault (403)"
else
  ko "isolation: status '$denied', 403 in controller log: ${forbidden_403} — not proven denied by policy"
fi

# --- 7. push -------------------------------------------------------------------------
pushed=""
for _ in $(seq 1 20); do
  pushed=$(v kv get -field=password "kv/clusters/${name}/generated/eso-smoke" 2>/dev/null || true)
  [[ -n "$pushed" ]] && break
  sleep 3
done
if [[ ${#pushed} -eq 24 ]]; then
  ok "PushSecret wrote a generated password to kv/clusters/${name}/generated/"
else
  ko "PushSecret: got '${pushed:0:4}…' (len ${#pushed}): $(k get pushsecret generated -n "$ns" -o jsonpath='{.status.conditions[*].message}' 2>&1)"
fi

# The other cluster's test value is not ours to keep.
v kv metadata delete "kv/clusters/${other}/eso-smoke" >/dev/null 2>&1 || true

echo "== $name: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

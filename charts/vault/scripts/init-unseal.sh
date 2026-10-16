#!/usr/bin/env bash
# Initializes Vault once and unseals every pod. Run as a helmfile postsync hook of the
# `vault` release (see helmfile.yaml.gotmpl), and safe to re-run at any time — after a
# node drain, a pod restart or an upgrade, re-running it is exactly how a sealed pod is
# brought back. Every step checks state first.
#
# Why a hook and not a template: init and unseal are API calls against a running Vault,
# and their output (unseal keys + root token) is the one thing that must never be in git.
#
# Where the init output goes is the one real decision here:
#   init_secret != ""  → LAB MODE. The keys and root token are stored in a Secret in the
#                         vault namespace, so this script can unseal unattended. Anyone who
#                         can read that Secret owns Vault. Fine for a sandbox; for anything
#                         long-lived, copy the keys offline, delete the Secret, and unseal by
#                         hand (or move to auto-unseal) — see gitops/SECRETS.md.
#   init_secret == ""  → the script refuses to init; do it by hand (`vault operator init`,
#                         ideally with -pgp-keys) and unseal with VAULT_UNSEAL_KEYS
#                         (space-separated) in the environment.
set -euo pipefail

ns="$1"
statefulset="$2"
key_shares="$3"
key_threshold="$4"
init_secret="$5"

vault_status() {
  # `vault status` exits 2 when sealed — that is a valid answer here, not a failure.
  oc exec -n "$ns" "$1" -c vault -- vault status -format=json 2>/dev/null || true
}

replicas=$(oc get statefulset "$statefulset" -n "$ns" -o jsonpath='{.spec.replicas}')
pods=()
for ((i = 0; i < replicas; i++)); do pods+=("${statefulset}-${i}"); done
[[ ${#pods[@]} -gt 0 ]] || { echo "vault: statefulset $statefulset has 0 replicas" >&2; exit 1; }

# Pods are NOT Ready until unsealed (readiness probe → 503), which is why this release
# runs with wait: false. Wait for Running instead, so `vault` is exec-able.
for pod in "${pods[@]}"; do
  echo "vault: waiting for $pod to be Running"
  # `oc wait` errors out at once on a pod that does not exist yet, and the StatefulSet
  # creates them one by one (and only after the previous one is Running).
  for _ in $(seq 1 120); do
    oc get pod "$pod" -n "$ns" >/dev/null 2>&1 && break
    sleep 5
  done
  oc wait -n "$ns" "pod/$pod" --for=jsonpath='{.status.phase}'=Running --timeout=600s
done

# Wait until the API answers at all (a fresh pod needs a few seconds to open the listener).
for _ in $(seq 1 60); do
  [[ -n "$(vault_status "${pods[0]}")" ]] && break
  sleep 5
done

initialized=$(vault_status "${pods[0]}" | jq -r '.initialized')
if [[ "$initialized" != "true" ]]; then
  if [[ -z "$init_secret" ]]; then
    echo "vault: NOT initialized and no init Secret configured — initialize by hand:" >&2
    echo "  oc exec -n $ns ${pods[0]} -- vault operator init -key-shares=$key_shares -key-threshold=$key_threshold" >&2
    exit 1
  fi
  if oc get secret "$init_secret" -n "$ns" >/dev/null 2>&1; then
    # A Secret but an uninitialized Vault means the raft data is gone (PVCs deleted) and
    # the stored keys belong to a Vault that no longer exists. Re-initializing would
    # overwrite the only copy of the old keys — make a human decide.
    echo "vault: Secret $init_secret exists but Vault is uninitialized — refusing to overwrite it." >&2
    echo "  If the old data is really gone: oc delete secret $init_secret -n $ns, then re-run." >&2
    exit 1
  fi
  echo "vault: initializing ($key_shares shares, threshold $key_threshold)"
  init_json=$(oc exec -n "$ns" "${pods[0]}" -c vault -- \
    vault operator init -key-shares="$key_shares" -key-threshold="$key_threshold" -format=json)
  # Straight into the Secret; never echoed.
  oc create secret generic "$init_secret" -n "$ns" \
    --from-literal=init.json="$init_json" \
    --from-literal=root-token="$(jq -r '.root_token' <<<"$init_json")"
  oc label secret "$init_secret" -n "$ns" app.kubernetes.io/part-of=vault-bootstrap
  echo "vault: initialized; keys + root token stored in Secret $ns/$init_secret (LAB MODE)"
fi

# Plain space-separated string, not an array: macOS still ships bash 3.2, which has no
# mapfile and treats an empty array as unbound under `set -u`.
keys="${VAULT_UNSEAL_KEYS:-}"
if [[ -z "$keys" && -n "$init_secret" ]] && oc get secret "$init_secret" -n "$ns" >/dev/null 2>&1; then
  keys=$(oc get secret "$init_secret" -n "$ns" -o jsonpath='{.data.init\.json}' \
    | base64 -d | jq -r '.unseal_keys_b64[:'"$key_threshold"'] | join(" ")')
fi

# Unseal in pod order: vault-0 first, so the followers' retry_join has a leader to join.
for pod in "${pods[@]}"; do
  for _ in $(seq 1 60); do
    status=$(vault_status "$pod")
    [[ -n "$status" ]] && break
    sleep 5
  done
  if [[ "$(jq -r '.sealed' <<<"$status")" != "true" ]]; then
    echo "vault: $pod already unsealed"
    continue
  fi
  if [[ $(wc -w <<<"$keys") -lt $key_threshold ]]; then
    echo "vault: $pod is sealed and no unseal keys are available (set VAULT_UNSEAL_KEYS)" >&2
    exit 1
  fi
  echo "vault: unsealing $pod"
  # A follower that has not joined raft yet reports sealed until its retry_join completes;
  # feeding it keys is what lets the join finish. Retry the whole round until it sticks.
  for _ in $(seq 1 30); do
    for key in $keys; do
      oc exec -n "$ns" "$pod" -c vault -- vault operator unseal "$key" >/dev/null 2>&1 || true
    done
    [[ "$(vault_status "$pod" | jq -r '.sealed')" == "false" ]] && break
    sleep 5
  done
  if [[ "$(vault_status "$pod" | jq -r '.sealed')" != "false" ]]; then
    echo "vault: $pod is still sealed after unseal attempts" >&2
    exit 1
  fi
  echo "vault: $pod unsealed"
done

for pod in "${pods[@]}"; do
  oc wait -n "$ns" "pod/$pod" --for=condition=Ready --timeout=300s
done
echo "vault: all ${#pods[@]} pods initialized, unsealed and Ready"

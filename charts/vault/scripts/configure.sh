#!/usr/bin/env bash
# Configures Vault for the External Secrets Operator on every cluster. Run as a helmfile
# postsync hook of the `vault` release, after init-unseal.sh. Idempotent: every write is
# a declarative PUT of the full object, so re-running converges instead of duplicating.
#
# What it sets up (layout and the reasoning are in gitops/SECRETS.md):
#   kv/                            KV v2 — all static secrets
#     shared/<...>                 readable by EVERY cluster
#     clusters/<cluster>/<...>     readable only by <cluster>
#     clusters/<cluster>/generated/<...>  also WRITABLE by <cluster> (ESO PushSecret)
#   auth/k8s-<cluster>/            one Kubernetes auth mount per cluster, role
#                                  `external-secrets` bound to that cluster's vault-auth SA
#   policy cluster-<cluster>       the read/write scope above
#   policy secrets-admin           full kv/ access, for humans (attach to a userpass/OIDC user)
#   audit device stdout            every request logged to the pod log
#
# Token: VAULT_TOKEN from the environment, else the root token in the lab-mode init Secret.
set -euo pipefail

ns="$1"
pod="$2"
init_secret="$3"
clusters_json="$4"
eso_namespace="$5"
eso_service_account="$6"
audience="$7"

token="${VAULT_TOKEN:-}"
if [[ -z "$token" && -n "$init_secret" ]]; then
  token=$(oc get secret "$init_secret" -n "$ns" -o jsonpath='{.data.root-token}' | base64 -d)
fi
[[ -n "$token" ]] || { echo "vault: no VAULT_TOKEN and no init Secret to read one from" >&2; exit 1; }

# v <stdin> <vault args...> — runs the vault CLI inside the pod. The token travels as the
# first line of stdin, never as an argument (arguments show up in `ps` and in audit of the
# exec). Whatever follows the token on stdin reaches vault, for `-` arguments.
v() {
  local input="$1"
  shift
  { printf '%s\n' "$token"; printf '%s' "$input"; } |
    oc exec -i -n "$ns" "$pod" -c vault -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"
}

# --- KV v2 ---------------------------------------------------------------------------
if v '' secrets list -format=json | jq -e 'has("kv/")' >/dev/null; then
  echo "vault: kv/ already enabled"
else
  echo "vault: enabling KV v2 at kv/"
  v '' secrets enable -path=kv -version=2 kv
fi

# --- Audit ---------------------------------------------------------------------------
if v '' audit list -format=json 2>/dev/null | jq -e 'has("stdout/")' >/dev/null 2>&1; then
  echo "vault: stdout audit device already enabled"
else
  echo "vault: enabling stdout audit device"
  v '' audit enable -path=stdout file file_path=stdout
fi

# --- Human access --------------------------------------------------------------------
# The policy is what matters; the userpass mount is just the simplest place to hang it.
# No users are created here — that would put a password in git. See gitops/SECRETS.md.
v 'path "kv/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
path "sys/mounts" {
  capabilities = ["read"]
}
' policy write secrets-admin -
if ! v '' auth list -format=json | jq -e 'has("userpass/")' >/dev/null; then
  echo "vault: enabling userpass auth (no users)"
  v '' auth enable userpass
fi

# --- Per-cluster auth + policy -------------------------------------------------------
existing_auth=$(v '' auth list -format=json)
count=$(jq 'length' <<<"$clusters_json")
for ((i = 0; i < count; i++)); do
  c=$(jq -c ".[$i]" <<<"$clusters_json")
  name=$(jq -r '.name' <<<"$c")
  mount="k8s-${name}"
  echo "vault: --- cluster $name (auth/$mount)"

  v "path \"kv/data/shared/*\" {
  capabilities = [\"read\"]
}
path \"kv/metadata/shared/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"kv/data/clusters/${name}/*\" {
  capabilities = [\"read\"]
}
path \"kv/metadata/clusters/${name}/*\" {
  capabilities = [\"read\", \"list\"]
}
# PushSecret target: ESO writes the value AND the custom_metadata it uses to mark
# ownership, and deletes both when a PushSecret with deletionPolicy: Delete goes away.
path \"kv/data/clusters/${name}/generated/*\" {
  capabilities = [\"create\", \"update\", \"read\", \"delete\"]
}
path \"kv/metadata/clusters/${name}/generated/*\" {
  capabilities = [\"create\", \"update\", \"read\", \"list\", \"delete\"]
}
" policy write "cluster-${name}" -

  if jq -e --arg m "${mount}/" 'has($m)' <<<"$existing_auth" >/dev/null; then
    echo "vault: auth/$mount already enabled"
  else
    v '' auth enable -path="$mount" -description="ESO on cluster ${name}" kubernetes
  fi

  if [[ "$(jq -r '.local // false' <<<"$c")" == "true" ]]; then
    # Vault's own cluster: Vault reviews tokens with its own pod SA (the chart's
    # authDelegator binding), and the in-cluster CA is picked up automatically.
    v '' write "auth/${mount}/config" kubernetes_host="https://kubernetes.default.svc:443"
  else
    # Remote cluster: no reviewer JWT is stored. With disable_local_ca_jwt, Vault reviews
    # each login with the CLIENT's own JWT — so the remote vault-auth SA holds
    # system:auth-delegator (gitops/charts/external-secrets), and no long-lived token for
    # the remote cluster ever sits in Vault. Requires hub → remote API reachability.
    host=$(jq -r '.host' <<<"$c")
    ca=$(jq -r '.caCert // ""' <<<"$c")
    if [[ -n "$ca" ]]; then
      v "$ca" write "auth/${mount}/config" kubernetes_host="$host" kubernetes_ca_cert=- disable_local_ca_jwt=true
    else
      v '' write "auth/${mount}/config" kubernetes_host="$host" disable_local_ca_jwt=true
    fi
  fi

  # audience: ESO requests a token minted for "vault" (ClusterSecretStore
  # serviceAccountRef.audiences), so a token stolen from Vault's logs/traffic is useless
  # against the Kubernetes API and vice versa.
  v '' write "auth/${mount}/role/external-secrets" \
    bound_service_account_names="$eso_service_account" \
    bound_service_account_namespaces="$eso_namespace" \
    audience="$audience" \
    token_policies="cluster-${name}" \
    token_ttl=1h token_max_ttl=4h
done

echo "vault: configured ${count} cluster(s)"

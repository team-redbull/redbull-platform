#!/usr/bin/env bash
# Wires htpasswd users into cluster login and grants cluster-admin. Run as a
# helmfile postsync hook (see helmfile.yaml.gotmpl) rather than as a
# Helm-templated resource: oauth/cluster pre-exists on every OpenShift
# cluster (owned by the cluster-version-operator), so a Helm-owned template
# for it would hit the same "invalid ownership metadata" conflict documented
# in CLAUDE.md for pre-existing Namespaces/Secrets.
#
# If the cluster already has an HTPasswd-type identity provider (the normal
# case — most clusters are bootstrapped with one out of band), the users are
# merged into ITS backing Secret, so the login screen keeps a single
# htpasswd option and any existing users are preserved. Only if no HTPasswd
# provider exists at all does this script create one from scratch.
set -euo pipefail

bootstrap_provider_name="$1"
bootstrap_secret_name="$2"
htpasswd_lines="$3"
shift 3
cluster_admins=("$@")

# First HTPasswd-type provider's backing Secret name, if any already exists.
existing_secret=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}' | awk '{print $1}')

if [[ -n "$existing_secret" ]]; then
  echo "htpasswd-idp: merging users into existing HTPasswd provider's secret '$existing_secret'"
  current=$(oc get secret "$existing_secret" -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d)
  merged="$current"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    user="${line%%:*}"
    if grep -q "^${user}:" <<<"$current"; then
      echo "htpasswd-idp: user '$user' already present in '$existing_secret', skipping"
    else
      echo "htpasswd-idp: adding user '$user' to '$existing_secret'"
      merged="${merged}"$'\n'"${line}"
    fi
  done <<<"$htpasswd_lines"
  encoded=$(printf '%s' "$merged" | base64 | tr -d '\n')
  oc patch secret "$existing_secret" -n openshift-config --type=merge -p "{\"data\":{\"htpasswd\":\"${encoded}\"}}"
else
  echo "htpasswd-idp: no HTPasswd provider found, bootstrapping '$bootstrap_provider_name' / secret '$bootstrap_secret_name'"
  oc create secret generic "$bootstrap_secret_name" -n openshift-config \
    --from-literal=htpasswd="$htpasswd_lines" --dry-run=client -o yaml | oc apply -f -

  provider_json=$(printf '{"name":"%s","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"%s"}}}' \
    "$bootstrap_provider_name" "$bootstrap_secret_name")
  existing_names=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}')
  if [[ -z "$existing_names" ]]; then
    oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":[${provider_json}]}}"
  else
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${provider_json}}]"
  fi
fi

for user in "${cluster_admins[@]}"; do
  echo "htpasswd-idp: granting cluster-admin to '$user'"
  oc adm policy add-cluster-role-to-user cluster-admin "$user"
done

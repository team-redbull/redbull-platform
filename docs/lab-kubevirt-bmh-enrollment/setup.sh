#!/usr/bin/env bash
# Rebuilds the KubeVirt VM -> BareMetalHost -> InfraEnv enrollment lab. See README.md.
#
#   KUBECONFIG=<admin kubeconfig> ./setup.sh render   # write manifests to $STATE_DIR/rendered, change nothing
#   KUBECONFIG=<admin kubeconfig> ./setup.sh apply    # render, then apply in order with a gate after each step
#   KUBECONFIG=<admin kubeconfig> ./setup.sh status   # BMH / VM / Agent at a glance
#
# Safe to rerun. Everything goes through `oc apply` except the VM, the router Pod and the
# BMH, which are created only when missing: re-applying them fights the controllers that
# own their runtime fields (see README, "Gotchas").
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
: "${KUBECONFIG:?set KUBECONFIG to a cluster-admin kubeconfig for the lab cluster}"
export KUBECONFIG

STORAGE_CLASS=${STORAGE_CLASS:-ocs-external-storagecluster-ceph-rbd}
OS_VERSION=${OS_VERSION:-4.20}
REDFISH_IMAGE=${REDFISH_IMAGE:-ghcr.io/team-redbull/kubevirt-redfish}
REDFISH_TAG=${REDFISH_TAG:-sha-33f34dac2ee10041fd2c1383bfebd35256de8afd}

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# wait_for <description> <timeout-seconds> <command...>
# Retries the command every 5s; on timeout prints its last output and exits.
wait_for() {
  local what=$1 timeout=$2 start=$SECONDS out
  shift 2
  until out=$("$@" 2>&1); do
    if (( SECONDS - start >= timeout )); then
      printf 'ERROR: timed out after %ss waiting for: %s\n%s\n' "$timeout" "$what" "$out" >&2
      exit 1
    fi
    sleep 5
  done
  echo "ok: $what"
}

for bin in oc helm python3 openssl ssh-keygen curl git; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH"
done

CLUSTER=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
# Credentials and rendered manifests live here, OUTSIDE the repo (its GitHub copy is public).
STATE_DIR=${STATE_DIR:-$HOME/.kv-lab/$CLUSTER}
OUT=$STATE_DIR/rendered

ensure_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [ ! -s "$STATE_DIR/redfish-password" ]; then
    # Reuse the live password if the lab already exists, so the BMC secret and the
    # redfish config keep matching.
    if oc get secret kv-worker-1-bmc -n lab-hosts >/dev/null 2>&1; then
      oc get secret kv-worker-1-bmc -n lab-hosts -o jsonpath='{.data.password}' | base64 -d > "$STATE_DIR/redfish-password"
    else
      openssl rand -base64 18 | tr -d '/+=' > "$STATE_DIR/redfish-password"
    fi
  fi
  [ -f "$STATE_DIR/ssh_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C kv-lab -f "$STATE_DIR/ssh_ed25519"
  # A curl config, so the password never appears on a command line.
  printf 'user = "admin:%s"\ninsecure\nsilent\nmax-time = 60\n' "$(cat "$STATE_DIR/redfish-password")" > "$STATE_DIR/redfish.curlrc"
  chmod 600 "$STATE_DIR/redfish-password" "$STATE_DIR/ssh_ed25519" "$STATE_DIR/redfish.curlrc"
}

# Everything that differs per cluster is read from the cluster, never hardcoded.
discover() {
  MTU=$(oc get network.config cluster -o jsonpath='{.status.clusterNetworkMTU}')
  DNS_IP=$(oc get svc dns-default -n openshift-dns -o jsonpath='{.spec.clusterIP}')
  # The Route's generated host is <route-name>-<namespace>.<apps domain>.
  REDFISH_HOST=kubevirt-redfish-kubevirt-redfish.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
  # One x86_64 RHCOS live ISO for $OS_VERSION, from the operator's own default list.
  read -r OS_URL OS_RELEASE < <(oc get deploy infrastructure-operator -n multicluster-engine -o json | python3 -I -c '
import json, sys
want = sys.argv[1]
env = {e["name"]: e.get("value", "") for c in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"] for e in c.get("env", [])}
for i in json.loads(env.get("OS_IMAGES") or "[]"):
    if i["cpu_architecture"] == "x86_64" and i["openshift_version"] == want:
        print(i["url"], i["version"])
        break
' "$OS_VERSION") || true
  [ -n "${OS_URL:-}" ] || die "no x86_64 OS image for $OS_VERSION in the infrastructure-operator's OS_IMAGES (set OS_VERSION)"
  oc get storageprofile "$STORAGE_CLASS" -o jsonpath='{.status.claimPropertySets}' \
    | grep -q '"accessModes":\["ReadWriteMany"\],"volumeMode":"Block"' \
    || die "storage class $STORAGE_CLASS does not offer ReadWriteMany Block (set STORAGE_CLASS)"
  printf 'cluster=%s mtu=%s dns=%s redfish=%s os=%s/%s sc=%s\n' \
    "$CLUSTER" "$MTU" "$DNS_IP" "$REDFISH_HOST" "$OS_VERSION" "$OS_RELEASE" "$STORAGE_CLASS"
}

render() {
  ensure_state
  discover
  mkdir -p "$OUT"
  local f pw pub
  pw=$(cat "$STATE_DIR/redfish-password")
  pub=$(cat "$STATE_DIR/ssh_ed25519.pub")
  for f in "$HERE"/manifests/*.yaml; do
    sed -e "s|@@MTU@@|$MTU|g" \
        -e "s|@@DNS_IP@@|$DNS_IP|g" \
        -e "s|@@STORAGE_CLASS@@|$STORAGE_CLASS|g" \
        -e "s|@@REDFISH_IMAGE@@|$REDFISH_IMAGE|g" \
        -e "s|@@REDFISH_TAG@@|$REDFISH_TAG|g" \
        -e "s|@@REDFISH_PASSWORD@@|$pw|g" \
        -e "s|@@REDFISH_HOST@@|$REDFISH_HOST|g" \
        -e "s|@@SSH_PUB@@|$pub|g" \
        -e "s|@@OS_VERSION@@|$OS_VERSION|g" \
        -e "s|@@OS_URL@@|$OS_URL|g" \
        -e "s|@@OS_RELEASE@@|$OS_RELEASE|g" \
        "$f" > "$OUT/$(basename "$f")"
  done
  if grep -l '@@[A-Z_]*@@' "$OUT"/*.yaml; then die "placeholders left unrendered in the files above"; fi

  helm template hosted-cluster-nodes "$REPO/gitops/charts/hosted-cluster-nodes" -n kv-lab \
    -f "$OUT/10-nodes-values.yaml" > "$OUT/10-nodes.yaml"
  helm template kubevirt-redfish "$REPO/gitops/charts/kubevirt-redfish" -n kubevirt-redfish \
    -f "$OUT/20-redfish-values.yaml" > "$OUT/20-redfish.yaml"
  # Split the nodes chart: the cluster-scoped classes are applied, the VM is create-only.
  python3 -I -c '
import sys
docs = [d for d in open(sys.argv[1]).read().split("\n---\n") if "kind:" in d]
def pick(kinds):
    return "\n---\n".join(d for d in docs if any("\nkind: %s\n" % k in "\n" + d + "\n" for k in kinds)) + "\n"
open(sys.argv[2], "w").write(pick(["VirtualMachineClusterInstancetype", "VirtualMachineClusterPreference"]))
open(sys.argv[3], "w").write(pick(["VirtualMachine"]))
' "$OUT/10-nodes.yaml" "$OUT/10-classes.yaml" "$OUT/10-vm.yaml"
  echo "rendered into $OUT"
}

redfish_get() { curl -K "$STATE_DIR/redfish.curlrc" -f "https://$REDFISH_HOST$1" | grep -q '"Id"'; }
asc_healthy() { [ "$(oc get agentserviceconfig agent -o jsonpath='{.status.conditions[?(@.type=="DeploymentsHealthy")].status}')" = True ]; }
converged_off() { oc exec -n multicluster-engine deploy/assisted-service -c assisted-service -- env | grep -qx 'ALLOW_CONVERGED_FLOW=false'; }
infraenv_ready() { [ -n "$(oc get infraenv lab -n lab-hosts -o jsonpath='{.status.isoDownloadURL}')" ]; }

apply() {
  render

  log "1/7 namespaces + vmnet NAD"
  oc apply -f "$OUT/00-base.yaml"

  log "2/7 VM classes + VM (VM only if missing)"
  oc apply -f "$OUT/10-classes.yaml"
  if oc get vm kv-worker-1 -n kv-lab >/dev/null 2>&1; then
    echo "VM kv-worker-1 exists, left alone (its runStrategy and cdrom0 belong to kubevirt-redfish)"
  else
    # No --dry-run=server first: KubeMacPool reserves the MAC on a dry run, and the real
    # create then fails. The retry covers virt-api not having seen the new instancetype yet.
    wait_for "VM kv-worker-1 created" 180 oc create -n kv-lab -f "$OUT/10-vm.yaml"
  fi

  log "3/7 kubevirt-redfish"
  oc apply -n kubevirt-redfish -f "$OUT/20-redfish.yaml"
  oc rollout status deploy/kubevirt-redfish -n kubevirt-redfish --timeout=300s
  # Gate: the system answers over the Route, which is the path Ironic will use.
  wait_for "Redfish serves kv-worker-1 via the Route" 180 redfish_get /redfish/v1/Systems/kv-worker-1

  log "4/7 NAT router (only if missing)"
  oc get pod vmnet-router -n kv-lab >/dev/null 2>&1 || oc create -f "$OUT/30-router.yaml"
  oc wait pod/vmnet-router -n kv-lab --for=condition=Ready --timeout=600s
  oc exec -n kv-lab vmnet-router -- curl -sS -m 15 -o /dev/null -w 'router egress: quay.io -> %{http_code} (401 is good)\n' https://quay.io/v2/

  log "5/7 assisted service + metal3 watchAllNamespaces"
  oc apply -f "$OUT/40-assisted.yaml"
  oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces":true}}'
  wait_for "AgentServiceConfig DeploymentsHealthy" 900 asc_healthy
  wait_for "assisted-service runs with ALLOW_CONVERGED_FLOW=false" 300 converged_off
  oc rollout status deploy/metal3-baremetal-operator -n openshift-machine-api --timeout=300s

  log "6/7 secrets, InfraEnv, NMStateConfig"
  oc create secret generic pull-secret -n lab-hosts --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=<(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d) \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic kv-worker-1-bmc -n lab-hosts \
    --from-literal=username=admin --from-file=password="$STATE_DIR/redfish-password" \
    --dry-run=client -o yaml | oc apply -f -
  oc apply -f "$OUT/50-infraenv.yaml"
  wait_for "InfraEnv lab has its discovery ISO" 300 infraenv_ready

  log "7/7 BareMetalHost (only if missing)"
  if oc get bmh kv-worker-1 -n lab-hosts >/dev/null 2>&1; then
    echo "BMH kv-worker-1 exists, left alone (BMAC owns its spec.image)"
  else
    oc create -f "$OUT/60-bmh.yaml"
  fi

  echo
  echo "Applied. Enrollment takes about 3-5 minutes; follow it with: $0 status"
}

status() {
  oc get bmh -n lab-hosts
  echo
  oc get vm,vmi -n kv-lab
  echo
  oc get agents -n lab-hosts -o custom-columns='AGENT:.metadata.name,HOSTNAME:.spec.hostname,APPROVED:.spec.approved,STATE:.status.debugInfo.state,IP:.status.inventory.interfaces[0].ipV4Addresses[0]'
}

case "${1:-}" in
  render) render ;;
  apply) apply ;;
  status) status ;;
  *) echo "usage: $0 render|apply|status" >&2; exit 2 ;;
esac

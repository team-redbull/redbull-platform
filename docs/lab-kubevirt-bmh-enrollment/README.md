# Lab: KubeVirt VM → BareMetalHost → InfraEnv enrollment on an RHDP cluster

## Purpose

How to rebuild, from nothing, a lab where a KubeVirt VM is enrolled into an assisted-installer
InfraEnv exactly like a physical server would be:

1. a `BareMetalHost` with a Redfish BMC address,
2. an `NMStateConfig` with a static IP,
3. `kubevirt-redfish` playing the BMC,
4. Ironic booting the discovery ISO over virtual media.

Everything here was built and verified on **2026-10-22** on `cluster-k4lgj.dyn.redhatworkshops.io`
(RHDP, OCP 4.19.11, CNV 4.19.37, ACM 2.14 / MCE 2.9, ODF external). The end state:

```
$ ./setup.sh status
NAME          STATE         CONSUMER   ONLINE   ERROR
kv-worker-1   provisioned              true
AGENT                                  HOSTNAME      APPROVED   STATE           IP
3803dbc8-f2c2-5724-8423-ef3b5cba4107   kv-worker-1   true       known-unbound   192.168.100.10/24
```

That host is in the InfraEnv inventory with every validation passing, ready to be bound to a
cluster. **Installing it into a hosted cluster has not been done yet** (see
[Known gap](#known-gap-the-post-install-reboot-on-cnv-419)).

If the lab is pruned, deleted or replaced by a new RHDP cluster, rerun:

```bash
KUBECONFIG=<cluster-admin kubeconfig> docs/lab-kubevirt-bmh-enrollment/setup.sh apply
KUBECONFIG=<cluster-admin kubeconfig> docs/lab-kubevirt-bmh-enrollment/setup.sh status   # repeat until an Agent shows up
```

Enrollment takes about 3-5 minutes after `apply` finishes.

---

## Why it is built this way

None of this is the production design: there the VMs bridge onto a real VLAN with a real
gateway. The lab is shaped by the RHDP infrastructure, and each choice below answers a
measured constraint.

| Constraint (measured on k4lgj) | Consequence |
| --- | --- |
| The cluster's nodes are themselves KubeVirt VMs on a parent cluster (`ocpv02.dfw3.infra.demo.redhat.com`; DMI says `Red Hat / OpenShift Virtualization`). | The "security group" is the parent's port security on the node NICs. Nothing inside the cluster can change it. |
| **The parent drops frames from any MAC/IP it did not assign.** An OVS port with a foreign MAC/IP on `br-ex`: its ARP requests were captured leaving worker-1's `enp2s0` and never arriving at worker-2. The node's real MAC passed both ways. | A VM bridged or `localnet`'ed onto the machine network (10.10.10.0/24) cannot reach anything off its own node. No NNCP bridge, no localnet. |
| The machine network 10.10.10.0/24 has **no gateway** (`10.10.10.1` is ARP-FAILED, no internet through `br-ex`). Internet goes only through each node's per-node NAT'd `enp1s0`. | Even a working bridge would have no egress. The discovery agent pulls its image from `registry.redhat.io` *before* it registers, so no egress means the host never appears. |
| The default pod network **does** egress: OVN-K runs `routingViaHost: true`, so pods leave via the node's routing table. | Egress has to start on the pod network. |
| A primary UDN routes egress via the non-existent `10.10.10.1` (measured on the sibling lab 64spr). | Not a usable alternative. |

So the lab uses the one shape that survives:

- **VM network:** an OVN **layer2 overlay** secondary network (`vmnet`). It is Geneve between
  node IPs, so the parent only ever sees node MACs. It has **no subnets**, so OVN-K checks only
  the MAC and the NMStateConfig's static IPs pass.
- **NAT router Pod:** `192.168.100.1` on `vmnet`, masquerading out of the pod network. It is the
  VMs' gateway; DNS is the cluster's `dns-default` Service, reached through that NAT.
- **Converged flow off.** Behind NAT, Ironic can never call back into IPA. With
  `ALLOW_CONVERGED_FLOW=false`, BMAC just boots the discovery ISO over virtual media, and the
  agent only ever calls out.

### kubevirt-redfish on 4.19

kubevirt-redfish is documented and supported (as Technology Preview) only from OpenShift 4.22.
It is not part of the CNV operator, though: it is a standalone pod that drives VMs through the
KubeVirt API. Both the Red Hat `kubevirt-redfish-rhel9:v4.22` image and the team-redbull fork
passed every call Ironic makes against CNV 4.19:

- list systems,
- power on/off,
- boot override,
- InsertMedia (helper-pod fetch of Ironic's `https://<master-ip>:6183/…iso`),
- EjectMedia.

The lab runs the **fork**, `team-redbull/kubevirt-redfish` main (upstream main plus PRs #29–#33:
client-go rate limits, worker pool, VM/VMI cache, VM write race). Its own CI
(`.github/workflows/scalefix-image.yml`) builds every push to `main` as
`ghcr.io/team-redbull/kubevirt-redfish:sha-<commit>`. `setup.sh` pins
`sha-33f34dac2ee10041fd2c1383bfebd35256de8afd` (main HEAD on 2026-10-22). To move to a newer
commit, set `REDFISH_TAG=sha-<commit>`. To force a fresh build:
`gh workflow run scalefix-image.yml -R team-redbull/kubevirt-redfish`.

---

## Topology

```
                     ┌────────────────────── cluster-k4lgj (MCE hub AND KubeVirt cluster) ───────────────────────┐
                     │                                                                                            │
  ns lab-hosts       │  BareMetalHost kv-worker-1 ──(BMC: Route)──► ns kubevirt-redfish: kubevirt-redfish         │
  (MCE side)         │  NMStateConfig  (static 192.168.100.10)              │  power = VM runStrategy             │
                     │  InfraEnv lab ──► assisted-service / image-service   │  media = cdrom0 PVC (helper pod)    │
                     │         ▲               (ns multicluster-engine)     ▼                                     │
                     │         │ agent registers over HTTPS          ns kv-lab: VM kv-worker-1                    │
                     │         │ (*.apps -> 10.10.10.101)              02:00:00:6b:76:0a / 192.168.100.10         │
                     │         │                                              │ net: vmnet (OVN layer2 overlay)   │
                     │         └──── vmnet-router Pod ◄───────────────────────┘                                   │
                     │               net1 192.168.100.1  ── nft masquerade ──► eth0 (pod network) ──► node ──► internet
                     └────────────────────────────────────────────────────────────────────────────────────────────┘
  Ironic (metal3 Pod, hostNetwork on a master) calls the redfish Route, and serves the ISO on https://<master-ip>:6183.
```

---

## What gets created

| Object | Namespace | File | Re-applied by `setup.sh`? |
| --- | --- | --- | --- |
| Namespaces `kv-lab` (PSA privileged), `kubevirt-redfish`, `lab-hosts` | – | `00-base.yaml` | yes |
| NAD `vmnet` (OVN layer2, no subnets, cluster MTU) | `kv-lab` | `00-base.yaml` | yes |
| `VirtualMachineClusterInstancetype worker-lab` (8 vCPU / 32Gi), `VirtualMachineClusterPreference worker-node` | cluster | rendered from `gitops/charts/hosted-cluster-nodes` + `10-nodes-values.yaml` | yes |
| VM `kv-worker-1` (+ its 120Gi RWX Block root DataVolume) | `kv-lab` | same chart | **create-only** |
| kubevirt-redfish: SA, config Secret, ClusterRole + binding, Service, Deployment, Route | `kubevirt-redfish` | rendered from `gitops/charts/kubevirt-redfish` + `20-redfish-values.yaml` | yes |
| Pod `vmnet-router` | `kv-lab` | `30-router.yaml` | **create-only** |
| ConfigMap `assisted-service-config` + `AgentServiceConfig agent` | `multicluster-engine` / cluster | `40-assisted.yaml` | yes |
| `Provisioning provisioning-configuration` → `watchAllNamespaces: true` | cluster | `oc patch` in `setup.sh` | yes |
| Secrets `pull-secret` (copied from `openshift-config`), `kv-worker-1-bmc` | `lab-hosts` | `setup.sh` | yes |
| `InfraEnv lab`, `NMStateConfig kv-worker-1` | `lab-hosts` | `50-infraenv.yaml` | yes |
| `BareMetalHost kv-worker-1` | `lab-hosts` | `60-bmh.yaml` | **create-only** |

Two of these are **cluster-wide** changes, not lab-local:

- the AgentServiceConfig, which serves every InfraEnv;
- `watchAllNamespaces`, after which the BareMetal operator acts on BMHs in every namespace.

### Files

```
docs/lab-kubevirt-bmh-enrollment/
├── README.md          this file
├── setup.sh           render | apply | status
└── manifests/         templates; @@NAME@@ placeholders are filled by `setup.sh render`
```

**Nothing secret is in the repo** (its GitHub copy is public). `setup.sh` keeps state per
cluster in `~/.kv-lab/<infrastructureName>/`, e.g. `~/.kv-lab/cluster-k4lgj-n8btc/`:

| File | What |
| --- | --- |
| `redfish-password` | BMC password, used by the redfish config and the `kv-worker-1-bmc` Secret. Generated once; reused from the live Secret if the lab already exists. |
| `ssh_ed25519`, `.pub` | Key put in the InfraEnv (`core@` on the discovery ISO). |
| `redfish.curlrc` | curl config with the BMC credentials, so the password never hits a command line. |
| `rendered/` | The exact manifests applied, including the password. Do not copy into the repo. |
| `kubeconfig` | k4lgj only: the `oc login` kubeconfig used on 2026-10-22. Its token expires. |

---

## What `setup.sh apply` does, step by step

Each step ends with a gate; the script stops at the first one that fails. To do a step by
hand, run `setup.sh render` and apply the matching file from the `rendered/` folder in the
state directory.

Values that differ per cluster are **discovered**, never hardcoded:

| Value | Read from |
| --- | --- |
| MTU | `network.config/cluster` `.status.clusterNetworkMTU` |
| DNS IP | `svc/dns-default -n openshift-dns` |
| Redfish Route host | `kubevirt-redfish-kubevirt-redfish.<ingresses.config/cluster .spec.domain>` |
| OS image | the infrastructure-operator's default `OS_IMAGES`, x86_64 entry for `OS_VERSION` |

The script also checks that `STORAGE_CLASS` offers `ReadWriteMany` `Block`.

1. **Namespaces + `vmnet` NAD.**
2. **VM classes + VM.** The chart is rendered with `rebootPolicy: null`, because CNV 4.19 has no
   such field. The VM is created only if missing, and never `--dry-run=server`'d first (see
   Gotchas). Its root disk stays `PendingPopulation` until the first power-on; the storage class
   is WaitForFirstConsumer.
3. **kubevirt-redfish.** Gate: `GET /redfish/v1/Systems/kv-worker-1` through the Route (system
   ids are bare VM names: `systemIdConvention: legacy`, decided 2026-11-05)
   returns the system. This is the path Ironic uses.
4. **NAT router Pod**, created only if missing. Gate: Ready, then `curl https://quay.io/v2/`
   from inside it returns 401 (reachable).
5. **AgentServiceConfig + converged-flow-off ConfigMap, `watchAllNamespaces: true`.** Gates:
   `DeploymentsHealthy=True`, `ALLOW_CONVERGED_FLOW=false` present in the assisted-service
   environment, BareMetal operator rolled out.
6. **Secrets, InfraEnv, NMStateConfig.** Gate: the InfraEnv has an `isoDownloadURL`.
7. **BareMetalHost**, created only if missing.

What happens next, on its own, as observed on 2026-10-22 (about 3 minutes in total):

1. BMH `registering` → `available`.
2. Then `provisioning`: Ironic powers the VM off, InsertMedia, sets a boot override, powers it
   on. The redfish log shows `Inserting virtual media cdrom0 with image
   https://10.10.10.12:6183/redfish/boot-<uuid>.iso` and a `copy-iso-…` helper pod.
3. Then `provisioned`. The VM boots the ISO, and the NMStateConfig gives `enp1s0`
   `192.168.100.10/24`, MTU 1300.
4. The Agent registers, is auto-approved by BMAC, and goes to `known-unbound`.

### Success looks like

- `oc get bmh -n lab-hosts`: `provisioned`, no error.
- `oc get agents -n lab-hosts`: approved, state `known-unbound`, conditions `Connected`,
  `RequirementsMet` and `Validated` True, NTP synced, `vda` eligible as the install disk.

### If the VM boots but no Agent appears

The overlay or the NAT is the suspect.

1. Check the router first: `oc exec -n kv-lab vmnet-router -- nft list ruleset` (the `vmnet`
   table) and `ip -br a` (`net1` = `192.168.100.1/24`).
2. Then the VM: copy `ssh_ed25519` into the router and `ssh core@192.168.100.10` from there.
   Check `ip a`, the default route and `journalctl -u agent`. *This path has not been exercised
   yet.*

---

## Gotchas

- **Never re-apply the VM or the BMH.** kubevirt-redfish owns the VM's `runStrategy`,
  boot order and the `cdrom0` disk/volume: re-applying the chart's VM shuts the node down
  (`Halted`) and strips the CD-ROM mid-boot. BMAC writes the BMH's `spec.image`: re-applying
  `60-bmh.yaml` removes it and BMO deprovisions the host. `setup.sh` creates both only when missing.
- **KubeMacPool reserves a MAC on `--dry-run=server`.** A server dry run of a VM with a fixed
  `macAddress`, followed by the real create, fails with `failed to allocate requested mac
  address`. The KMP log names a VM that does not exist. Do not dry-run the VM; wait, or use
  another MAC (change it in all three files).
- **The instancetype is not instantly visible to virt-api.** A VM created a second after its
  class gets `Failure to find instancetype`. `setup.sh` retries the create.
- **`rebootPolicy` is silently dropped on CNV 4.19.** The fork sets `Terminate` during boot-once,
  and the API server answers `Warning: unknown field "spec.template.spec.domain.rebootPolicy"`.
  See the known gap below.
- **Redfish reports 2 GiB / 1 CPU** for the VM (log: `Memory not found in VM spec … using default`).
  Both images read `domain.cpu/memory` and ignore instancetypes. This is cosmetic, because the
  agent reports its own inventory. It would be a small fix to upstream.
- **The router is a bare Pod.** If it is deleted, evicted, or its node reboots, the VMs lose
  their gateway and DNS. Rerun `setup.sh apply` to recreate it.
- **The router's netns carries OpenShift's `openshift-block-output` nft table**, which rejects
  forwarded traffic to 22623/22624 (MCS). That is irrelevant for a hosted cluster, whose ignition
  is a Route, but it would break a standalone-cluster install through this NAT.
- **The Redfish Route is public** (`*.apps` resolves to a public IP). Anyone with the password
  controls the VM.
- **A one-off client-side timeout** on ForceOff from a laptop (request never reached the
  server; the retry took 1.5s) is the internet path to the public Route, not the controller.
  Ironic calls the Route from inside the cluster.

---

## Known gap: the post-install reboot on CNV 4.19

This was not tried. It is expected, based on the earlier finding written up in the
`hosted-cluster-nodes` chart's `defaults.rebootPolicy` comment (`values.yaml`).

1. After the installer writes the disk, the guest reboots *inside the same VMI*, because
   `rebootPolicy: Terminate` never landed.
2. The `cdrom0` disk is still attached with CD-first boot order, so the node boots the discovery
   ISO again instead of its disk.
3. The fork's boot-once restore triggers on a VMI **UID change**, which a guest reboot does not
   produce.

The plausible workaround to test: once the Agent reaches its reboot stage, force a new VMI with
Redfish ForceOff then On. On CNV ≥ 4.22, drop the `rebootPolicy: null` override instead.

---

## Teardown

Order matters: the BMH must go while kubevirt-redfish still answers, or its deprovisioning
finalizer hangs.

```bash
S=~/.kv-lab/<infrastructureName>/rendered
oc delete bmh kv-worker-1 -n lab-hosts --wait            # powers the VM off and ejects over Redfish
oc delete agents --all -n lab-hosts
oc delete infraenv lab -n lab-hosts; oc delete nmstateconfig kv-worker-1 -n lab-hosts
oc delete vm kv-worker-1 -n kv-lab                       # also deletes its root disk
oc delete pod vmnet-router -n kv-lab
oc delete -n kubevirt-redfish -f $S/20-redfish.yaml      # includes the ClusterRole/Binding
oc delete -f $S/10-classes.yaml
oc delete ns kv-lab kubevirt-redfish lab-hosts
# Cluster-wide, only if nothing else on the cluster uses them:
oc delete agentserviceconfig agent; oc delete cm assisted-service-config -n multicluster-engine
oc patch provisioning provisioning-configuration --type merge -p '{"spec":{"watchAllNamespaces":false}}'
```

---

## On a different RHDP cluster: re-check the network first

The design rests on two measurements. A new lab may come from a different parent environment,
so redo them before trusting the shape above. Both are read-only or cleaned up on exit.

**Is there a gateway on the machine network?** From a worker:

```bash
oc debug node/<worker> -q -- chroot /host bash -c \
  'ip r; ping -c2 -W2 <br-ex gateway>; curl --interface br-ex -m 10 -so /dev/null -w "%{http_code}\n" https://quay.io/v2/'
```

**Does the parent pass a foreign MAC?** Add an OVS internal port inside a netns on worker A.
Put it in a netns, not on the host: an address on the host would steal the node's own routes.
Then ARP a peer, and capture on worker B's NIC at the same time
(`oc debug node/<B> -- tcpdump -nnei enp2s0 arp and host 10.10.10.250`; tcpdump is in the debug
image, not on RHCOS):

```bash
oc debug node/<A> -q -- chroot /host bash -c '
trap "ovs-vsctl --if-exists del-port br-ex t0; ip netns del probe" EXIT
ip netns add probe
ovs-vsctl add-port br-ex t0 -- set interface t0 type=internal
ip link set t0 netns probe
ip netns exec probe ip link set t0 address 02:ab:cd:00:00:01
ip netns exec probe ip link set t0 up
ip netns exec probe ip addr add 10.10.10.250/24 dev t0     # a free IP: check with arping -D first
ip netns exec probe arping -c3 -w4 -I t0 <A own br-ex IP>  # control: must answer
ip netns exec probe arping -c3 -w4 -I t0 <B br-ex IP>      # the test'
```

Use `arping`, not `ping`: OVN-K's `br-ex` flows pull IP traffic from an unknown port into its
conntrack tables, while ARP falls through to `NORMAL`.

- **If B answers, and the network has a gateway:** the parent allows foreign MACs, and the
  simpler production-like shape becomes possible: a localnet NAD on `br-ex` (needs the NMState
  operator for the bridge mapping), with no router.
- **If B stays silent:** keep the overlay + router used here.

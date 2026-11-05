# VM CPU Configuration for Hosted Cluster Compute Nodes

## Purpose

This page describes how CPU (and the memory that comes with it) is configured for the
KubeVirt VMs that serve as compute nodes of hosted clusters, on the KubeVirt hosts
that run them, and in the scheduling rules that place them.

Every setting below was chosen on purpose. Each section explains what the setting
does, why it is needed, and what goes wrong without it, so that future changes are
made deliberately and not reverted by accident.

## The goal

A VM that asks for **x vCPUs gets x real CPU threads of the bare-metal host that runs
it**, for its whole life, with no overcommit:

- The VM's pod has **requests equal to limits**, for **both CPU and memory**
  (Kubernetes QoS class `Guaranteed`).
- No other workload can use the CPUs the VM was given.
- The guest sees a CPU layout that matches what it really got, so its own scheduler
  makes good decisions.
- The same configuration works on **every bare-metal server model**, including ones
  we have not bought yet.

"x CPUs" always means **x hardware threads**, the unit Kubernetes counts in
(`cpu: 1` = one thread). On a host with hyperthreading, 16 vCPUs = 8 physical cores.

## The configuration at a glance

| Where | What | Why, in one line |
| --- | --- | --- |
| KubeVirt hosts: `KubeletConfig` | `cpuManagerPolicy: static` | Lets the kubelet give a pod CPUs of its own |
| | `full-pcpus-only: "true"` | Hands out whole cores, so two VMs never share a core |
| | `topologyManagerPolicy: best-effort` | Keeps a VM on one socket when possible, never refuses it |
| | `systemReserved.cpu: "4"`, `memory: 15000Mi` | CPU and memory left for everything that is not a pinned VM |
| VM (or instancetype) | `dedicatedCpuPlacement: true` | Requests = limits for CPU and memory; vCPUs pinned |
| VM (or preference) | `sockets: 1`, `cores: x/2`, `threads: 2` | Guest sees hyperthread pairs, which is what it has |
| VM sizes | Even numbers only | Whole cores; odd counts are rejected or truncated |
| Each host: label | `redbull.io/threads-per-numa=<n>` | Tells the scheduler how big one socket is |
| VM: node affinity | `preferred`, `Gt <x-1>` | Prefer hosts where one socket can hold the whole VM |
| `HyperConverged` | **Not** used for this | Its ratio setting cannot make limits equal requests |

Current VM sizes: **16 vCPU / 128Gi**, **32 vCPU / 256Gi**, **64 vCPU / 512Gi**.

---

## Background: two things to understand first

### 1. Overcommit: why "8 vCPUs" does not mean 8 CPUs by default

By default KubeVirt **overcommits CPU 10 to 1**. The VM pod requests
`vCPUs ÷ 10` CPUs from the host (the `cpuAllocationRatio`, default `10`).

> **Example.** A VM with `cores: 8` and `guest: 64Gi` produced a virt-launcher pod
> with:
>
> ```
> requests: cpu: 800m, memory: 65860Mi
> ```
>
> The guest sees 8 CPUs, but only **0.8 of a host CPU** is reserved for it. When the
> host is busy, the VM gets about that much. Ten such VMs fit on 8 host CPUs.
>
> The memory is fine: 65536Mi (64Gi) for the guest plus about 324Mi of KubeVirt
> overhead. Memory is not overcommitted by default.

For a hosted-cluster worker this is dangerous: the guest kubelet tells its own
cluster "I have 64 CPUs" while the host guarantees about 6. Everything in this page
exists to close that gap.

To see what a VM really gets, look at the **virt-launcher pod**, not the VM object.
The VM YAML has no `containers` field; KubeVirt creates the pod from it when the VM
starts:

```bash
oc get pod -n <ns> | grep virt-launcher-<vm-name>
oc get pod -n <ns> <pod-name> \
  -o jsonpath='{.spec.containers[?(@.name=="compute")].resources}{"\n"}{.status.qosClass}{"\n"}'
```

The `devices.kubevirt.io/kvm`, `tun` and `vhost-net` entries in that output are
access to `/dev/kvm` and the network devices. Every VM pod has them; they are not
CPU or memory.

### 2. NUMA: why "which CPUs" matters, not just "how many"

A server with two sockets is really two computers joined together. Each socket
(each physical CPU chip) has its own memory attached directly to it:

```
   Socket 0                    Socket 1
 [ 48 cores ]  <-- link -->  [ 48 cores ]
 [ memory A ]                [ memory B ]
```

A core on socket 0 reads memory A fast. It can read memory B too, but only across the
link, which is noticeably slower. A socket together with its own memory is a **NUMA
node**. Our servers have two.

- A VM whose vCPUs are all on **one socket** has its memory mostly local: fast.
- A VM **spread across both sockets** keeps reaching across the link: slower. The
  guest cannot compensate, because it was told it has one socket.

Fitting a VM in one socket is free performance. It is **not** a correctness
requirement: a spread VM still works and still gets every CPU it asked for.

The two server models we have today:

| Server | Threads per core | Cores per socket | Sockets | NUMA nodes | Threads per socket |
| --- | --- | --- | --- | --- | --- |
| Model A | 2 | 48 | 2 | 2 | 96 |
| Model B | 2 | 32 | 2 | 2 | 64 |

More models will be added. Nothing below depends on these two.

---

## Decision 1: dedicated CPUs on the VM, not a cluster-wide ratio

**Setting:** `dedicatedCpuPlacement: true` on the VM (or `dedicatedCPUPlacement: true`
in an instancetype; see the casing note under Decision 5).

**What it does:**

- KubeVirt sets the pod's **requests and limits to the same values**, for CPU *and*
  memory (memory includes KubeVirt's overhead). The pod is `Guaranteed`.
- The kubelet then **pins** each vCPU to its own host thread that nothing else may
  use.
- The overcommit ratio no longer applies to that VM.

> **Verified.** A VM with 1 socket × 2 cores × 2 threads and `guest: 1Gi` produced:
>
> ```
> requests: cpu: 4, memory: 1416Mi
> limits:   cpu: 4, memory: 1416Mi
> qosClass: Guaranteed
> nodeSelector: kubevirt.io/cpumanager=true, ...
> ```
>
> No `resources:` block was written on the VM. KubeVirt filled in both.

**Do not add a `resources:` block to the VM.** KubeVirt computes it, including the
memory overhead. Writing it by hand only creates a second place to get it wrong.

### Alternatives that were rejected

**`HyperConverged` `vmiCPUAllocationRatio: 1`.** This is a real, supported field on
CNV 4.22 (`spec.vmiCPUAllocationRatio` in the `v1` API). It makes an 8-vCPU VM
*request* 8 CPUs, but sets **no limit**. The pod stays `Burstable`, vCPUs are not
pinned, and requests ≠ limits. It does not meet the goal. It is also cluster-wide,
and has no effect on VMs that use dedicated CPUs anyway.

**Explicit `resources.requests` = `resources.limits` on the VM, without pinning.**
This does give `Guaranteed`, and needs no host preparation. Rejected because:

- The vCPUs float across the host's CPUs instead of owning some.
- QEMU's own threads (emulator, I/O) share the same CPU limit as the vCPUs, so the
  guest can be throttled under load even though it is "within its limit".
- It **cannot be combined with an instancetype**. Verified:
  `spec.template.spec.domain.resources.requests.cpu conflicts with selected instance type`.

---

## Decision 2: prepare the hosts with a KubeletConfig, not a PerformanceProfile

Dedicated CPUs only work on hosts whose kubelet runs the CPU Manager in `static`
mode. Until a host has it, pinned VMs **do not schedule there at all**: KubeVirt adds
the node selector `kubevirt.io/cpumanager=true` to their pod, and only labels hosts
where the CPU Manager is static.

There are two OpenShift objects that can configure this.

**A PerformanceProfile** is tied to the hardware. Its `spec.cpu.reserved` and
`spec.cpu.isolated` are explicit lists of CPU numbers. Model A numbers its CPUs
0–191, Model B 0–127, and the hyperthread siblings sit at different numbers on each.
A list that is right for one model is wrong for the other. That means one profile
and one machine config pool **per server model**, and new work for every new model.

**A KubeletConfig** uses only policies and quantities, never CPU lists. **One object
fits every host and every KubeVirt cluster.** That is why we use it.

What we give up: a PerformanceProfile also moves operating-system daemons and
hardware interrupts onto the reserved CPUs. With a KubeletConfig only, those can
still briefly run on a VM's pinned CPUs. That matters for real-time or packet-
processing workloads, not for OpenShift worker nodes.

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: kubevirt-dedicated-cpus
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    cpuManagerPolicy: static
    cpuManagerReconcilePeriod: 5s
    cpuManagerPolicyOptions:
      full-pcpus-only: "true"
    topologyManagerPolicy: best-effort
    systemReserved:
      cpu: "4"
      memory: 15000Mi
```

The pool selector targets the `worker` pool. If a KubeVirt cluster runs VMs on hosts
in another pool (for example a compact cluster, where the hosts are in `master`),
point it there instead.

Each setting, and why:

### `cpuManagerPolicy: static`

The kubelet's default (`none`) lets every container use every CPU. `static` lets a
`Guaranteed` pod with a whole number of CPUs **own** them. Without it,
`dedicatedCpuPlacement` has nothing to pin to.

### `full-pcpus-only: "true"`

Without it, the kubelet may hand out single hyperthreads. Two VMs could then each
get one thread of the **same physical core** and compete for it, while each believes
it owns its CPUs.

With it, the kubelet only hands out **whole cores** (both threads together).

> **Example.** A 16-vCPU VM gets 8 complete physical cores. No other VM can be given
> the other thread of any of those cores.

Side effect: a pod must ask for an **even** number of CPUs, or it is rejected. See
Decision 4.

### `topologyManagerPolicy: best-effort`

This decides how the kubelet places a VM's CPUs **on the node it has already been
scheduled to**:

| Policy | VM fits in one socket | VM does not fit in one socket |
| --- | --- | --- |
| `best-effort` (ours) | Placed on one socket | Spread across both, **and runs** |
| `single-numa-node` | Placed on one socket | **Rejected** (`TopologyAffinityError`) |

Two separate components act one after the other, and it is easy to mix them up:

1. **The scheduler picks the node.** It sees only the node's *total* free CPUs
   ("120 free"). It knows nothing about sockets.
2. **The kubelet on that node picks which CPUs.** That is where the topology policy
   applies. It never sends the VM to another node.

So with `single-numa-node`, the scheduler can send a VM to a node that has enough
CPUs in total but not enough on any one socket, and the kubelet then refuses it.

> **Example.** A host has 10 free threads on each socket, 20 in total. The scheduler
> sees 20 free and sends a 16-vCPU VM there. With `single-numa-node` the kubelet
> rejects it, because no single socket has 16. With `best-effort` it runs, spread.

For our VMs a rejection is worse than a slower VM: the VM is powered on over Redfish
while its BareMetalHost provisions, so a failed launcher pod leaves the host stuck
rather than producing a clear scheduling error.

`best-effort` still puts every VM on one socket whenever it fits. Steering VMs
toward hosts where they *do* fit is the job of the node label in Decision 6.

The only safe way to enforce strict one-socket placement would be the NUMA Resources
Operator, which adds a socket-aware second scheduler (and would have to be mirrored
into the air-gapped environment). Add it only if measurements show the cross-socket
cost matters.

### Why the reservation matters more here than on an ordinary worker

On an ordinary OpenShift worker, `systemReserved` is mostly a **scheduling buffer**.
Pods are `Burstable` and usually use less than they request, and system daemons can
use any CPU that happens to be idle. A small reservation rarely becomes the real
limit.

On a KubeVirt host full of pinned VMs, it is a **hard ceiling**:

- **CPU.** Once VMs own every other CPU, the reserved CPUs are the only ones left for
  everything that is not a VM: kubelet, CRI-O, OVN/OVS, virt-handler, monitoring,
  Multus, the machine-config daemon, and the network and storage interrupts the VMs
  cause.
- **Memory.** VMs are `Guaranteed`, and a Linux guest gradually fills all its RAM
  with page cache. A packed host really does use everything except the reservation.
  If the host OS, kubelet, OVS and the NFS client do not fit in what is left, the
  kubelet starts **evicting VMs**.

What does **not** run there: a pinned VM's own QEMU threads (emulator, disk I/O).
KubeVirt confines the whole `compute` container to the VM's own pinned CPUs, so
those threads compete with the VM's vCPUs, not with the host. See Decision 8.

### `systemReserved.cpu: "4"`

Units: `cpu: "4"` means 4 **threads**, which on a hyperthreaded host is **2 physical
cores**. It is the same value our existing hosted-cluster bare-metal environments use
(`4000m`), so every environment shares one reservation shape.

It **must be even**, because `full-pcpus-only` works in whole cores.

The number has to cover the list above under real network load. Watch the reserved
CPUs on a packed host (`mpstat -P <reserved CPUs>`, or the node's CPU dashboard) and
raise it to `"6"` or `"8"` if they sit near 100%.

OpenShift's `autoSizingReserved` scales the reservation with node size, but produces
a fractional CPU, which does not fit `full-pcpus-only`. A fixed number is the better
fit here.

### `systemReserved.memory: 15000Mi`

About 14.6Gi, the same value our existing hosted-cluster bare-metal environments use.

On a KubeVirt host this value matters more than on an ordinary worker, because of the
memory point above: on a packed host it is genuinely all the host gets. Do not lower
it to save room for VMs.

For scale: as we understand OpenShift's own automatic sizing (`autoSizingReserved`),
it reserves roughly 2% of RAM above 128GB plus a fixed base. That would be about 12Gi
on a 512GB host and about 22Gi on a 1TB host. Check the formula in the OpenShift
documentation before relying on these numbers. On hosts with much more RAM than
512GB, consider raising it.

### `cpuManagerReconcilePeriod: 5s`

How often the kubelet re-checks CPU assignments. `5s` is the value OpenShift's own
documentation uses for the static policy.

---

## Decision 3: the CPU layout the guest sees

**Setting:** `sockets: 1`, `cores: x/2`, `threads: 2`.

The vCPU count is `sockets × cores × threads`. The layout does **not** change how
much host CPU the VM gets; that is Decision 1. It changes what the guest *believes*,
which changes how well the guest schedules its own work.

### Why `threads: 2` instead of `cores: x`

With `full-pcpus-only`, a 16-vCPU VM really owns 8 cores × 2 threads.

- `cores: 16` tells the guest it has 16 independent cores. Its scheduler then puts
  two busy tasks on what it thinks are separate cores, but they are sibling threads
  of one physical core and compete for it.
- `cores: 8, threads: 2` tells the truth. The guest fills whole cores first and
  understands which vCPUs share a core.

> **Example.** For a 16-vCPU VM, `lscpu` inside the guest shows:
>
> ```
> CPU(s):               16
> Socket(s):            1
> Core(s) per socket:   8
> Thread(s) per core:   2
> ```

### Why `sockets: 1`

`best-effort` keeps a VM on one host socket whenever it fits, and Decision 6 steers it
to hosts where it fits. One socket is the truthful layout in that case. Never fake a
two-socket layout with `sockets: 2`: the guest would believe it has two NUMA nodes
that do not correspond to anything real.

### Why this layout works on every server model

The guest layout describes **what the VM gets** (whole hyperthread pairs from one
socket), not the host. That is the same on every model that has 2 threads per core.
The host's socket and core counts never appear in the VM.

The one case where a different layout is needed: a server with hyperthreading
**disabled**. There `threads: 2` would describe something that does not exist. If
such hosts are ever added, give them a node label and steer VMs with a different
layout to them with a `nodeSelector`.

### Why not NUMA passthrough and hugepages

The chart's `worker-64-rt` class sets `numa.guestMappingPassthrough`, which presents
the host's real NUMA layout to the guest and requires 1Gi hugepages pre-allocated on
every host. That only pays off for a VM **larger than one socket**. All current sizes
fit in one socket on every server we have, so it is not used.

---

## Decision 4: VM sizes must be even

Two reasons:

1. `full-pcpus-only` rejects a pod that asks for an odd number of CPUs.
2. With an instancetype and the `spread` preference (Decision 5), an odd size is
   **silently truncated**.

> **Verified.**
>
> | Instancetype `guest` | Guest sees |
> | --- | --- |
> | 8 | 1 socket × 4 cores × 2 threads = 8 |
> | 64 | 1 socket × 32 cores × 2 threads = 64 |
> | **7** | **1 socket × 3 cores × 2 threads = 6** |
>
> A 7-vCPU VM boots with 6 vCPUs and no error anywhere.

All current sizes (16, 32, 64) are even. The template enforces it, so a mistake fails
at render time instead of in the cluster.

---

## Decision 5: how the VM template expresses all this

There are two equivalent ways to write it. The plain VM template is what is deployed
today; the instancetype form is what the `hosted-cluster-nodes` chart in this repo
uses.

### Form A: plain VirtualMachine (current `vm.yaml`)

Only the `cpu:` block changes, plus the even-size guard and the affinity from
Decision 6:

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: redbull.io/threads-per-numa
                    operator: Gt
                    values: ["{{ sub (int .spec.cpu) 1 }}"]
      domain:
        {{- if mod (int .spec.cpu) 2 }}
        {{- fail (printf "%s: cpu must be even (whole cores), got %v" .name .spec.cpu) }}
        {{- end }}
        cpu:
          sockets: 1
          cores: {{ div (int .spec.cpu) 2 }}
          threads: 2
          dedicatedCpuPlacement: true
        memory:
          guest: {{ .spec.memory }}
```

Everything else in the template (disks, network, firmware, labels) is unchanged.

### Form B: VirtualMachineClusterInstancetype + VirtualMachineClusterPreference

KubeVirt's recommended way to size VMs: **sizes** live in instancetypes, **house
style** lives in one preference, and VMs refer to them by name.

**One instancetype per size.** It holds only the count, the memory and the pinning:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineClusterInstancetype
metadata:
  name: worker-16
spec:
  cpu:
    guest: 16
    dedicatedCPUPlacement: true
  memory:
    guest: 128Gi
```

(and the same for `worker-32` with 32 / 256Gi, and `worker-64` with 64 / 512Gi).

Why instancetypes:

- A size is defined **once**, cluster-wide, and every VM of that size is identical.
- A VM cannot accidentally carry its own `cpu:` or `resources:` next to one; KubeVirt
  rejects the conflict.
- Editing an instancetype does **not** resize VMs already using it: each VM keeps a
  copy of the version it was created with. To resize a VM, point it at another
  instancetype.

> **Casing trap.** The instancetype field is `dedicatedCPUPlacement`; the same field
> on a VM is `dedicatedCpuPlacement`. The wrong casing is silently dropped, and the
> VM ends up unpinned.

**One preference for all sizes.** It turns "x vCPUs" into the layout from Decision 3:

```yaml
apiVersion: instancetype.kubevirt.io/v1beta1
kind: VirtualMachineClusterPreference
metadata:
  name: worker-node
spec:
  cpu:
    preferredCPUTopology: spread
    spreadOptions:
      across: CoresThreads
      ratio: 2
```

`spread` across `CoresThreads` with `ratio: 2` means "2 threads per core, as many
cores as needed, one socket". The verified results are the table in Decision 4.

This replaces the chart's current `preferredCPUTopology: cores`, which would present
16 vCPUs as 16 independent cores (the problem described in Decision 3).

The preference's other settings stay as they are: multi-queue disks and NICs, a
dedicated I/O thread for the root disk, and the minimum-size `requirements`.

> **A preference only fills in what the VM leaves unset.** A VM that sets
> `cores: 8` itself keeps `cores: 8`, whatever the preference says. Verified. With
> Form B, the VM must not set any `cpu:` fields; the layout has to come from the
> preference.

The node affinity from Decision 6 is **not** part of an instancetype or preference.
It stays on the VM template in both forms; with Form B, the template reads the vCPU
count from the instancetype it references.

---

## Decision 6: steer VMs to hosts where one socket can hold them

### The problem

The scheduler sees each host's total CPUs, not how many sit on one socket. Without
help, it may place a 64-vCPU VM on a Model B host (64 threads per socket, some of
them taken), where `best-effort` has to spread it across both sockets, even though a
Model A host had room on one socket.

### The node label: `redbull.io/threads-per-numa`

Each host is labelled with **how many threads one of its sockets has**:

| Server | Label |
| --- | --- |
| Model A (2×48×2) | `redbull.io/threads-per-numa=96` |
| Model B (2×32×2) | `redbull.io/threads-per-numa=64` |
| Any future model | Its own number |

The label describes the **host**, not the VM. The number differs per server model;
the VM template does not.

The value is the host's total threads divided by its number of NUMA nodes.

A host **without** the label still receives VMs; it just never counts as a match. A
forgotten label costs performance, never availability.

### The VM rule: "prefer a host where one socket has at least x threads"

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: redbull.io/threads-per-numa
              operator: Gt
              values: ["{{ sub (int .spec.cpu) 1 }}"]
```

**Why `cpu − 1`.** Kubernetes has no "at least" operator, only `Gt` ("greater than").
"At least 64" has to be written as "greater than 63".

| VM size | Rendered rule | Meaning |
| --- | --- | --- |
| 16 | `Gt 15` | Prefer hosts with at least 16 threads per socket |
| 32 | `Gt 31` | At least 32 |
| 64 | `Gt 63` | At least 64 |

> **Example.** Where does a 64-vCPU VM go?
>
> | Host | Label | 64 > 63? | Result |
> | --- | --- | --- | --- |
> | Model A | 96 | Yes | Preferred |
> | Model B | 64 | Yes | Preferred |
> | Future 2×24×2 | 48 | No | Used only if no preferred host has room |

**Why the threshold is the VM's own size, with no margin.** The kubelet should take
the reserved CPUs from one socket (we expect socket 0), leaving the other socket
completely free. "One socket has at least x threads" is then the right test. The rule
is only a preference, so it does not need a safety margin.

**Why on every VM, not only the 64s.** For 16 and 32 the rule changes nothing today,
because every host qualifies. If a host with small sockets is added later, those
sizes are steered away from it too, with no template change.

### Why `preferred` and not `required`

| | `preferred` (ours) | `required` |
| --- | --- | --- |
| A matching host has room | VM goes there | VM goes there |
| Only non-matching hosts have room | VM goes there, spread across sockets, **runs** | VM stays **Pending** until a matching host has room |
| What can go wrong | A VM sometimes runs slower | A VM sometimes waits, and its BareMetalHost is stuck |

Our VMs are powered on over Redfish during host provisioning, so a VM that waits
means a host that is stuck. A slower worker is the better failure.

### What `weight: 100` does

`weight` is required on every `preferred` rule and must be 1–100. It only matters
**relative to other preferred rules on the same VM**: the scheduler adds up the
weights of the rules a host matches. With a single rule, any value gives the same
result.

How strongly node affinity counts against the scheduler's other scoring (free
resources, balanced load) is set by the scheduler's own configuration, not by the
pod. In practice a matching host with room wins.

`100` is used so that if a second preferred rule is ever added (say, a rack at weight
`20`), this one already ranks highest.

### The label never blocks a migration

The rule is "at least", not "equal to", so a **bigger** host always matches. And it
is `preferred`, so even a smaller host is still allowed. The label only ranks hosts;
it never removes one from the list.

---

## Decision 7: CPU model

**Setting:** none on the VM. VMs use the cluster's default CPU model.

KubeVirt adds a node selector for the VM's CPU model (for example
`cpu-model.node.kubevirt.io/Icelake-Server-v2=true`) to every pod, including the
target pod of a live migration. So a VM only runs on hosts whose CPUs support that
model.

- **A named model** (the default) is a common feature set. A VM can live-migrate
  between different server generations, as long as all of them support the model.
- **`host-passthrough`** shows the guest the exact host CPU. It is the fastest, but a
  VM can only safely live-migrate between hosts with the **same** CPU. On a mixed
  fleet, migration can fail or crash the guest.

We keep a named model because the fleet is mixed and we rely on live migration.

**Check before rolling out.** If the cluster's default model is newer than some of
the servers, VMs silently never land on those servers:

```bash
oc get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.spec.defaultCPUModel}'
oc get nodes -L cpu-model.node.kubevirt.io/<that-model>
```

Every KubeVirt host should show `true`. If not, set a model that all servers support.

---

## Decision 8: no emulator-thread isolation

**Setting:** `isolateEmulatorThread` is **off** (the default).

Without it, QEMU's emulator thread and the root disk's I/O thread run **on the VM's
own pinned CPUs**: KubeVirt confines the whole `compute` container to them. They take
time from the vCPUs, not from the host.

When on, it gives those threads a pinned CPU of their own, so they never interrupt a
vCPU. It costs one extra CPU per VM, which makes the request **odd** (x + 1), and
`full-pcpus-only` rejects odd requests. KubeVirt has an option to round it up to an
even number (one extra core per VM), but we believe it is an alpha setting, so it has
not been relied on.

The trade-off: for most worker nodes these threads are light and the default is
fine. On disk- or network-heavy workers they steal noticeable vCPU time, and
isolation is the fix once the even-rounding option can be relied on.

---

## Live migration

KubeVirt supports live-migrating VMs with dedicated CPUs. How it works:

1. A **second virt-launcher pod** is created for the VM, with the same requests,
   limits, node selectors and affinity. The scheduler places it on another host.
2. The target host's kubelet pins x threads to it: whole cores, on one socket if
   possible. They are whatever CPUs are free there, not the same CPU numbers as on
   the source.
3. KubeVirt re-points each vCPU at the target's new CPUs.
4. Memory is copied over the network **while the VM keeps running**. Pages the guest
   changes during the copy are sent again. Then the VM pauses briefly, the last pages
   and CPU state move across, and it resumes on the target.
5. The source pod ends, and its cores are freed.

The guest notices nothing. Its layout stays 1 socket × x/2 cores × 2 threads.

What this configuration changes:

- **A migration needs real free capacity.** Before, an 8-vCPU VM's target pod
  requested 0.8 CPU and fit almost anywhere. Now it needs x free threads (whole cores)
  and the VM's full memory, on a host with the static CPU Manager.
- **During a migration the VM holds double its size**: both pods keep their full
  reservation until it finishes.
- **Draining a host needs room for all of its VMs elsewhere.** Upgrades, KubeletConfig
  changes and maintenance all drain hosts. **Always keep at least one host's worth of
  VMs (the largest host's) free somewhere in the cluster**, or drains hang on VMs
  with nowhere to go.
- **The VM may be laid out differently on the target.** One socket on the source can
  become two sockets on a busier target, or the other way round. It keeps running.
- **Large VMs take longer.** A busy 512Gi worker can change memory faster than it is
  copied, and the migration never finishes. The controls are in the `HyperConverged`
  CR's `liveMigrationConfig` (bandwidth, parallel migrations, post-copy). This comes
  from the VM sizes, not from this configuration.

Already in place and required for migration: the root disk is `ReadWriteMany`, and
the NIC is a bridge on a Multus secondary network (a bridge on the pod network would
block migration).

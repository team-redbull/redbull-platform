# VM CPU and Memory: Fixed Sizes with a Minimal CPU Overcommit

## Purpose

This page describes the CPU and memory configuration of the KubeVirt VMs that serve as
compute nodes of hosted clusters, **as deployed now**: fixed VM sizes, memory fully
reserved, and CPU reserved at 31/32 of the VM's size.

It explains each setting and why it was chosen, so that changes are made deliberately.

[vm-cpu-configuration.md](vm-cpu-configuration.md) describes a different design,
**pinned CPUs**, where requests equal limits for CPU too. That design is **not**
deployed. The two are compared at the end of this page.

## The goal

- **Fixed VM sizes** that hosted-cluster users can rely on: 16, 32 and 64 vCPUs.
- **Memory is never overcommitted.** A VM always has all of its memory.
- **CPU is overcommitted only slightly (about 3%)**, just enough to fit one more VM on
  each bare-metal host than an exact reservation would allow.
- **Under full contention, every VM still gets at least 31/32 of its vCPUs.**

## The configuration at a glance

| Where | Setting | Why, in one line |
| --- | --- | --- |
| VM | `cores: x` | The guest sees x CPUs on one socket |
| VM | `resources.limits.cpu: x` | A VM never uses more than its size |
| VM | `resources.requests.cpu: x × 31/32` | Reserves 97% of the size, so one more VM fits per host |
| VM | `resources.requests.memory` = `limits.memory` = guest memory | Memory is fully reserved and fixed |
| VM | **No** `dedicatedCpuPlacement` | KubeVirt does not allow request ≠ limit with it |
| KubeVirt hosts | `systemReserved: cpu 4000m, memory 15000Mi` | Same as our other bare-metal environments |
| KubeVirt hosts | CPU Manager stays at the default (`none`) | Nothing is pinned, so static mode would add nothing |

| VM size | CPU limit | CPU request | Memory (request = limit) |
| --- | --- | --- | --- |
| Small | 16 | 15.5 (`15500m`) | 128Gi |
| Medium | 32 | 31 (`31000m`) | 256Gi |
| Large | 64 | 62 (`62000m`) | 512Gi |

---

## Background: requests, limits, and what the scheduler counts

Every VM runs inside a **virt-launcher pod**. Its `compute` container holds the VM, and
that container's resources are what Kubernetes uses:

- **Request**: the amount reserved for the VM. The scheduler places a VM only on a host
  with that much unreserved. Under contention, the kernel shares CPU time in proportion
  to requests, so a VM always gets at least its request.
- **Limit**: the most the VM may ever use.

**The request is what decides how many VMs fit on a host.** The limit only lets a VM
use more when the host has spare CPU.

To see what a VM really has, look at its virt-launcher pod, not the VM object:

```bash
oc get pod -n <ns> | grep virt-launcher-<vm-name>
oc get pod -n <ns> <pod-name> \
  -o jsonpath='{.spec.containers[?(@.name=="compute")].resources}{"\n"}{.status.qosClass}{"\n"}'
```

The `devices.kubevirt.io/kvm`, `tun` and `vhost-net` entries in that output are access
to `/dev/kvm` and the network devices. Every VM pod has them; they are not CPU or
memory.

### KubeVirt's default overcommit does not apply

Without an explicit request, KubeVirt requests **vCPUs ÷ 10**: a 64-vCPU VM would reserve
6.4 CPUs. Setting `resources.requests.cpu` on the VM replaces that.

> **Verified.** A 64-vCPU VM with `requests.cpu: 62`, `limits.cpu: 64` produced a pod
> with `cpu: 62` / `64`, not 6.4.

---

## Decision 1: CPU request = 31/32 of the VM size

### Why not request = limit

A bare-metal host with 192 threads and 4 reserved has **188 allocatable**. Part of that
is already requested by non-VM pods (OVN, Multus, virt-handler, monitoring, and each
virt-launcher's small helper containers), typically 1–2 CPUs. That leaves about 186.

With request = limit, a host of large VMs fits **2** (128). The remaining 58 can only
be used by smaller VMs. Requesting 62 instead fits **3** (186).

| Host filled with only | Request = limit | Request = 31/32 |
| --- | --- | --- |
| 64-vCPU VMs | 2 (128 CPUs) | **3** (186 CPUs) |
| 32-vCPU VMs | 5 (160 CPUs) | **6** (186 CPUs) |
| 16-vCPU VMs | 11 (176 CPUs) | **12** (186 CPUs) |

**31/32 is the same ratio for every size.** It is the largest simple ratio that fits
one more VM of every size into 186 CPUs. It is about 3% of overcommit.

### What a VM gets in the worst case

Overcommit only matters when **every** VM on the host is busy at the same time.

> **Example.** A host runs three 64-vCPU VMs: 3 × 64 = 192 vCPUs, on 188 allocatable
> CPUs. If all three run at 100%, the kernel shares CPU time in proportion to requests,
> so each gets **at least 62 CPUs' worth**. The guest sees the difference as about 3%
> **steal time** (`st` in `top`). When any VM is below full load, the others get all
> 64.

### Why the limit is the VM's size

Without a limit, a VM could use idle CPUs beyond its own size. Its vCPU count already
caps how many CPUs it can run on at once. The limit also covers QEMU's own threads, so
a VM cannot exceed its size even counting its overhead.

**Side effect to watch:** QEMU's emulator, disk I/O and network threads count against
the same limit as the vCPUs. A guest running all its vCPUs at 100% while also doing
heavy I/O can be throttled slightly below its size. If that shows up, the
`container_cpu_cfs_throttled_periods_total` metric for the `compute` container is the
signal.

### Requests must be written per VM, so no instancetypes

KubeVirt rejects a VM that sets `resources.requests.cpu` next to an instancetype
("conflicts with selected instance type"). The cluster-wide alternative,
`HyperConverged` `spec.vmiCPUAllocationRatio`, takes a whole number, so it cannot
express 32/31. So these VMs are plain VirtualMachines with the resources in the
template.

---

## Decision 2: memory request = limit = guest memory

**Setting:** `resources.requests.memory` and `resources.limits.memory` both equal to
`memory.guest`.

- **Fully reserved.** The scheduler only places a VM on a host with all of its memory
  free. Memory is never overcommitted.
- **Fixed.** A VM cannot grow past its size plus KubeVirt's overhead.
- **KubeVirt adds its overhead** (QEMU, page tables, virt-launcher) to both the request
  and the limit. Do not add it yourself.

> **Verified.** A VM with `memory.guest: 1Gi` and memory requests = limits = 1Gi
> produced a pod with `1798Mi` / `1798Mi`. Without a memory limit on the VM, the pod
> got a request of `1796Mi` and **no limit**.

**Risk of a memory limit:** if a VM's real overhead ever exceeds KubeVirt's estimate,
the VM is killed for exceeding its limit (`OOMKilled` on the virt-launcher pod). This
is rare. If it happens, the fix is to raise the memory request and limit slightly above
`memory.guest`; KubeVirt adds its overhead on top of whatever is set there.

**Memory decides whether the extra VM fits at all.** The CPU overcommit only adds a VM
if the host also has the RAM for it:

| Host filled with only | Guest memory | + overhead + 15000Mi reserved |
| --- | --- | --- |
| 3 × 64-vCPU / 512Gi | 1536Gi | about 1.55TB |
| 6 × 32-vCPU / 256Gi | 1536Gi | about 1.55TB |
| 12 × 16-vCPU / 128Gi | 1536Gi | about 1.56TB |

On a host with less RAM, memory is the limit and the CPU overcommit gains nothing
there. Check each server model's RAM.

---

## Decision 3: no pinned CPUs

`dedicatedCpuPlacement: true` requires the CPU request to equal the limit.

> **Verified.** KubeVirt rejects the combination:
> `spec.template.spec.domain.resources.requests.cpu or
> spec.template.spec.domain.resources.limits.cpu must be equal when
> DedicatedCPUPlacement is true`.

So with a 31/32 request, the vCPUs are **not pinned**. They run as ordinary threads that
the host kernel places on any CPU outside of what other pinned workloads hold. What
that means:

- **No CPU is owned by one VM.** A VM's vCPUs share host CPUs with other VMs and with
  host processes, within each VM's request and limit.
- **A vCPU can land on either socket.** The host's memory is split between its two
  sockets, and reaching the other socket's memory is slower. The kernel's automatic
  NUMA balancing moves threads and memory toward each other over time, which recovers
  part of that. It is on by default on RHEL-based hosts; check with
  `sysctl kernel.numa_balancing` (`1` = on).
- **Two vCPUs can share one physical core** (its two hyperthreads). That is consistent
  with our sizing unit: x vCPUs means x host threads, not x physical cores.

---

## Decision 4: the CPU layout the guest sees

**Setting:** `cores: x` only. When only `cores` is set, KubeVirt sets `sockets` and
`threads` to 1, so they are not written in the template.

The vCPU count is `sockets × cores × threads`. The layout changes only what the guest
believes, not what it gets.

- **One socket, x cores** is the standard layout for unpinned vCPUs. Without it,
  KubeVirt's default presents each vCPU as its own socket, so a 64-vCPU VM would boot
  with 64 sockets.
- **Not `threads: 2`.** That layout describes vCPUs that sit on real core pairs, which
  is only true with pinning. Here the vCPUs float, so claiming pairs would mislead the
  guest's scheduler.

> **Example.** For a 16-vCPU VM, `lscpu` inside the guest shows:
>
> ```
> CPU(s):               16
> Socket(s):            1
> Core(s) per socket:   16
> Thread(s) per core:   1
> ```

---

## Decision 5: host configuration

The KubeVirt hosts use the same reservation as our other bare-metal environments:

```yaml
kubeletConfig:
  systemReserved:
    cpu: 4000m
    memory: 15000Mi
```

- **`cpu: 4000m`** is 4 threads (2 physical cores), taken out of allocatable for the
  host OS, kubelet, CRI-O and other system processes. 192 − 4 = **188 allocatable**.
- **`memory: 15000Mi`** (about 14.6Gi) is kept for the host. Because VM memory requests
  equal their limits, a full host really does use everything except this. Do not lower
  it to fit more VMs; if the host runs short, the kubelet starts evicting VMs.

**No CPU Manager, Topology Manager or `full-pcpus-only` settings.** Those only affect
pinned CPUs, and nothing here is pinned. If a host already has the KubeletConfig from
[vm-cpu-configuration.md](vm-cpu-configuration.md), it does no harm; these VMs simply
run in its shared CPU pool.

---

## The VM template

```yaml
spec:
  template:
    spec:
      domain:
        cpu:
          cores: {{ .spec.cpu }}
        memory:
          guest: {{ .spec.memory }}
        resources:
          requests:
            cpu: "{{ div (mul (int .spec.cpu) 31000) 32 }}m"
            memory: {{ .spec.memory }}
          limits:
            cpu: "{{ .spec.cpu }}"
            memory: {{ .spec.memory }}
```

The CPU request is computed in thousandths of a CPU (`m`) so it stays exact for every
size:

| `.spec.cpu` | `× 31000 ÷ 32` | Request |
| --- | --- | --- |
| 16 | 15500 | `15500m` = 15.5 |
| 32 | 31000 | `31000m` = 31 |
| 64 | 62000 | `62000m` = 62 |

Everything else in the template (disks, network, firmware, labels) is unchanged.

---

## Live migration

How it works:

1. A **second virt-launcher pod** is created for the VM, with the same requests and
   limits, and the scheduler places it on another host.
2. Memory is copied over the network **while the VM keeps running**. Pages the guest
   changes during the copy are sent again. Then the VM pauses briefly, the last pages
   and CPU state move across, and it resumes on the target.
3. The source pod ends.

What to plan for:

- **The target needs the VM's full request free**: 62 CPUs and 512Gi for a large VM.
- **During a migration the VM is counted twice**, once on each host, until it finishes.
- **Draining a host needs room for all of its VMs elsewhere.** Upgrades and
  maintenance drain hosts. Always keep at least one host's worth of VMs (the largest
  host's) free somewhere in the cluster, or drains hang on VMs with nowhere to go.
- **Large VMs take longer.** A busy 512Gi worker can change memory faster than it is
  copied, and the migration never finishes. The controls are in the `HyperConverged`
  CR's `liveMigrationConfig` (bandwidth, parallel migrations, post-copy).
- **CPU model.** A VM only runs on hosts that support its CPU model, including the
  migration target. Keep the cluster's default model one that every server model
  supports:

  ```bash
  oc get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.spec.defaultCPUModel}'
  oc get nodes -L cpu-model.node.kubevirt.io/<that-model>
  ```

Already in place and required for migration: the root disk is `ReadWriteMany`, and the
NIC is a bridge on a Multus secondary network.

---

## Comparison with the pinned design

| | This page (deployed) | Pinned ([vm-cpu-configuration.md](vm-cpu-configuration.md)) |
| --- | --- | --- |
| VM sizes | Fixed 16 / 32 / 64 | Must be even; 3 per host only with smaller sizes |
| CPU request vs limit | 31/32 | Equal |
| Large VMs per 188-CPU host | 3 | 2 (or 3 at 62 vCPU) |
| Worst-case CPU per VM | 31/32 of its size | All of its size |
| VM owns its CPUs | No | Yes |
| vCPUs kept on one socket | No (kernel balancing only) | Yes, when it fits |
| Instancetypes possible | No | Yes |
| Host preparation | None beyond `systemReserved` | CPU Manager static, `full-pcpus-only`, Topology Manager |
| Guest CPU layout | `cores: x` | `cores: x/2`, `threads: 2` |

The pinned design gives more consistent performance; this one fits more VMs of fixed
sizes. Moving to pinned later means making CPU requests equal limits, which brings back
the packing loss, or changing the VM sizes.

---

## Rollout

1. **Check the CPU model** (see Live migration).
2. **Check each server model's RAM** against the memory table in Decision 2.
3. **Check the non-VM CPU requests on a real host:** `oc describe node <host>` →
   "Allocated resources". The packing table assumes these are 2 CPUs or less.
4. **Switch the VM template.** VMs already running keep their old configuration until
   they are restarted.
5. **Verify on one VM of each size:**
   - The `compute` container shows the CPU request and limit from the table, and
     memory request = limit.
   - In the guest, `lscpu` shows `Socket(s): 1`, `Core(s) per socket: <x>`.

---

## What was verified, and what was not

Verified on a test cluster (CNV 4.22):

- An explicit CPU request replaces KubeVirt's default 10:1 ratio.
- KubeVirt adds memory overhead to both the request and the limit.
- Without a memory limit on the VM, the pod has none.
- `dedicatedCpuPlacement` is rejected when the CPU request differs from the limit.
- An instancetype rejects a VM-level CPU request.

**Not** verified, because the test cluster's hosts are VMs themselves:

- Packing three large VMs on a real 192-thread host (depends on the non-VM requests).
- Worst-case steal time under full contention.
- Throttling from QEMU threads counted against the limit.
- Live migration of these VMs between bare-metal hosts.

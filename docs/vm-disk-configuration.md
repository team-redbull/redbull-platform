# VM Disk Configuration for Hosted Cluster Compute Nodes

## Purpose

This page describes how to define the disks of a KubeVirt VirtualMachine that is
provisioned by the assisted installer and joins a hosted cluster as a compute node.

It covers which disks a VM needs, how each one is configured, and the reasoning
behind those choices, so that the configuration stays consistent across the project
and so that future changes are made deliberately.

## Context

Our compute nodes are KubeVirt VMs that are made to behave like physical servers.
Each VM is paired with a `BareMetalHost`, driven over Redfish by the
`kubevirt-redfish` controller, and installed by the assisted installer. Once the
installation completes, the VM joins a hosted cluster as a compute node and stays in
service for a long time.

That dual life is the key to every decision on this page:

- **During provisioning** the VM must look like a server with a BMC and removable
  boot media.
- **After provisioning** it is a long-lived cluster node whose storage must support
  routine maintenance of the underlying KubeVirt hosts.

## Disk layout at a glance

| Disk | Bus | Purpose | Who defines it | Lifetime |
| --- | --- | --- | --- | --- |
| `rootdisk` | `virtio` | Install target for RHCOS | You, in the VM manifest | Life of the node |
| `cdrom0` | `sata` | Discovery ISO boot media | `kubevirt-redfish`, automatically | Provisioning only |

> **Define only the root disk.** Do not add a CD-ROM device, do not create a
> DataVolume for the discovery ISO, and do not hand-manage boot order.

---

## The root disk

The root disk is the machine's hard drive. The discovery agent inspects it, the
assisted installer validates it, and RHCOS is written to it during installation.
It is the only disk that persists for the life of the node.

### Bus: `virtio`

`virtio` is a paravirtualised interface. The guest talks to the hypervisor through a
shared memory ring with no hardware emulation, which makes it the fastest option and
the lowest in CPU overhead. RHCOS ships with the driver built in.

Other buses exist and are worth knowing:

| Bus | What it is | When to use it |
| --- | --- | --- |
| `virtio` | Paravirtualised block device | **Default for all normal disks** |
| `scsi` | Paravirtualised SCSI (virtio-scsi) | Hotplugged volumes, SCSI reservations |
| `sata` | Emulated AHCI controller | CD-ROMs, or guests without virtio drivers |
| `usb` | Emulated USB | Rarely relevant |

### Size: 120Gi

The assisted installer refuses to install on a host whose disk is below its minimum.
The default requirement for a worker is **100 GB**, and it is evaluated in GB rather
than GiB.

We standardise on **120Gi** because:

- A volume of exactly 100 GB leaves no margin against the validation threshold.
- 120Gi is 128.8 GB, comfortably above the minimum.
- It leaves room for the node's container images and ephemeral storage in service,
  not just for the base OS.

The minimum is configurable in the assisted service deployment, so confirm the
effective value before sizing below 120Gi. If the disk uses `Filesystem` volume mode,
see the table under volume mode below: part of the volume is reserved for overhead,
which makes under-sizing considerably riskier.

### Access mode: `ReadWriteMany`

**Use RWX.** KubeVirt requires every PVC attached to a VM to be shared before it will
live-migrate that VM. Its own check states this plainly:

```
cannot migrate VMI: PVC %v is not shared, live migration requires
that all PVCs must be shared (using ReadWriteMany access mode)
```

Because our VMs become long-lived cluster nodes, live migration is what lets us
perform maintenance on a KubeVirt host without disrupting the hosted cluster running
on top of it. An RWO root disk would permanently forfeit that.

Note the word *every*. A single RWO volume anywhere on the VM blocks migration for
the whole VM, regardless of how the other disks are configured.

### Volume mode: `Block` or `Filesystem`

Both are valid. The right value is the one your storage class actually supports, so
check before choosing rather than copying a default.

```bash
oc get storageprofile <storage-class> -o jsonpath='{.status.claimPropertySets}'
```

**Prefer `Block` where it is offered.** It hands the guest a raw device with no
filesystem layer in between, which performs better and consumes no extra space.

**`Filesystem` is a correct choice, not a fallback.** It is normal on backends where
shared access comes from a shared filesystem rather than a shared block device. If
your storage offers `ReadWriteMany` only in `Filesystem` mode, use `Filesystem` mode.
The access mode requirement is the one that cannot bend.

**If you use `Filesystem`, do not shrink the disk.** In this mode the VM's disk is a
file inside the PVC, and CDI reserves part of the volume for filesystem overhead. The
default reservation is 6%, which changes the arithmetic against the installer's
100 GB minimum:

| Requested | Mode | Usable | Against the 100 GB minimum |
| --- | --- | --- | --- |
| 100Gi | `Filesystem` | ~94Gi = 100.9 GB | passes by under 1 GB |
| 120Gi | `Filesystem` | ~113Gi = 121.1 GB | comfortable |
| 100Gi | `Block` | 100Gi = 107.4 GB | passes |
| 120Gi | `Block` | 120Gi = 128.8 GB | comfortable |

This is the case that makes the 120Gi standard worth keeping. A 100Gi disk in
`Filesystem` mode clears the threshold by less than a gigabyte, so any change to the
overhead setting or the validator config turns a working size into a failing one.

### Be explicit

If `accessModes` and `volumeMode` are omitted, CDI picks the first entry advertised
by the storage class's StorageProfile. That default may not be what you want, and it
can change with the storage class. State both explicitly.

To see what a storage class advertises:

```bash
oc get storageprofile <storage-class> -o jsonpath='{.status.claimPropertySets}'
```

---

## The CD-ROM

The CD-ROM holds the discovery ISO and exists only while the machine is being
provisioned. **It is created and managed entirely by `kubevirt-redfish`.**

When Ironic issues a Redfish `InsertMedia` call, the controller:

1. Adds a SATA CD-ROM device named `cdrom0` to the VM, if one is not already present.
2. Creates a PVC for the ISO and attaches it to that device.
3. Sets the CD-ROM as the primary boot device and demotes the root disk to secondary.

This is why you must not define the CD-ROM yourself, and why you should not set boot
order manually. The controller rewrites boot order as part of the provisioning
handshake, and a hand-authored device only conflicts with what it creates.

### The CD-ROM is always `sata`

A CD-ROM cannot use `virtio`. The virtio block interface has no ATAPI semantics, and
KubeVirt's admission webhook rejects the combination outright:

```
Bus type virtio is invalid for CD-ROM device
```

`sata` is what the controller uses, and it works with any guest without extra drivers.

### The CD-ROM PVC is always `ReadWriteOnce`

The access mode is fixed in the controller and is not exposed through configuration.
This is a deliberate consequence to be aware of rather than a problem to solve: while
the CD-ROM is attached, the VM has an RWO volume and therefore **cannot live-migrate**.

This is temporary and is resolved by ejecting the media once the node is in service.

---

## Why the ISO needs its own device

A reasonable question is why the VM cannot simply import the discovery ISO onto the
root disk and install from there. It cannot, because the discovery ISO is not an
installer image.

The discovery ISO is a **live RHCOS environment**. It contains a kernel, an
initramfs, a root filesystem, the assisted installer agent, and an embedded Ignition
config carrying the InfraEnv's identity: its ID, the service URL, the pull secret and
the SSH key.

When it boots, it runs entirely in RAM and writes nothing to the target disk. It then:

1. Inventories the hardware: CPU, memory, disks and network interfaces.
2. Registers the host with the assisted service, which creates the `Agent` object.
3. Runs validations and connectivity checks.
4. Waits for the host to be approved and assigned to a hosted cluster.
5. **Only then** writes RHCOS to the root disk, applies Ignition and reboots.

The live environment has to stay running while the disk beneath it is overwritten, so
the boot media and the install target must be two separate devices. This mirrors
exactly what a BMC does for a physical server: present an ISO as removable media,
boot it, and let the machine boot its own drive afterwards.

---

## Power state: why `runStrategy: Halted`

`runStrategy` is not a hint about whether the VM should be up. **It is the power
switch, and the BMC owns it.** The Redfish controller implements every power action
by patching that exact field:

```
power on  ->  {"op": "replace", "path": "/spec/runStrategy", "value": "Always"}
power off ->  {"op": "replace", "path": "/spec/runStrategy", "value": "Halted"}
```

So the value in the manifest is the machine's state *before anything touches it*, and
`Halted` is correct for two reasons:

- The `BareMetalHost` field `online: true` is what powers the machine on, and it does
  so only after Ironic has attached the boot media and set the boot override. A VM
  that starts itself boots with no media and no override, and has to be power-cycled
  anyway.
- Declaring `Always` asserts in Git that the machine is permanently on, which directly
  contradicts the BMC being in control of its power.

The field is mandatory. KubeVirt rejects a VirtualMachine without it:

```
The request is invalid: spec.running: RunStrategy must be specified
```

### Consequence for GitOps

Because the field must be present in Git and the BMC changes it at runtime, a GitOps
controller with self-healing enabled will treat every power-on as drift and revert it,
**shutting the node down**. On a compute node that is running hosted cluster
workloads, that is an outage.

Configure the application to ignore that field, so Git supplies the value at creation
and the BMC owns it from then on. For Argo CD:

```yaml
ignoreDifferences:
  - group: kubevirt.io
    kind: VirtualMachine
    jsonPointers:
      - /spec/runStrategy
```

## DataVolume lifecycle: use `dataVolumeTemplates`

There are two ways to attach a DataVolume to a VM, and the VM's `volumes` block looks
identical in both cases. The difference is whether the VM owns the DataVolume.

**Standard: declare the root disk under `spec.dataVolumeTemplates`.**

When the VM creates the DataVolume from a template, Kubernetes establishes a full
ownership chain:

```
VirtualMachine  ->  DataVolume  ->  PersistentVolumeClaim
```

Deleting the VM cascades through both, so a decommissioned node takes its disk with
it and leaves nothing behind.

Why this is the standard:

- **No orphaned volumes.** A standalone DataVolume survives its VM. At fleet scale
  those orphans accumulate into real, unreclaimed capacity.
- **One object per machine.** The manifest fully describes the node, with no separate
  disk object to create first and keep in step by name.
- **No ordering dependency.** A standalone DataVolume must exist and be populated
  before the VM can start, which means sequencing two resources.

**The implication to understand:** with templates, deleting the VM object destroys
the node's operating system disk. That is the correct behaviour when the VM *is* the
server, but it means VM deletion should be treated as decommissioning the machine.

To check which form an existing VM uses:

```bash
oc get vm <vm> -n <ns> -o jsonpath='{.spec.dataVolumeTemplates[*].metadata.name}{"\n"}'
oc get dv <disk> -n <ns> -o jsonpath='{.metadata.ownerReferences}{"\n"}'
```

A DataVolume with no `ownerReferences` is standalone and will outlive its VM.

### A note on `blank` volumes

The root disk uses `source: blank: {}`. CDI still runs a populator to prepare it,
which is visible as a short-lived `prime-` PVC and pod. This is expected and
completes in seconds.

---

## After the node joins the hosted cluster

Once the VM has been installed and has joined its hosted cluster, **the CD-ROM should
be ejected.** Ejecting removes the CD-ROM device, its volume reference and its PVC.

This matters because the CD-ROM PVC is RWO, and as explained above a single RWO
volume prevents the VM from live-migrating. Ejecting it leaves the VM with nothing
but its RWX root disk, which restores live migration for the rest of the node's
service life.

---

## Reference manifest

This configuration is implemented as a Helm chart, which renders one VirtualMachine
per entry in its `nodes` list and applies every default described above. Prefer the
chart over hand-written manifests: it enforces the rules on this page at render time,
failing on duplicate names or MAC addresses, on a missing storage class, and on an
eviction strategy that cannot work with the requested access mode.

The manifest it produces looks like this:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: compute-node-0
  namespace: <vm-namespace>
  labels:
    # Must match the chassis vm_selector in the kubevirt-redfish configuration,
    # or the VM is not visible over Redfish.
    redfish-enabled: "true"
spec:
  # The BareMetalHost powers the VM on through Redfish.
  runStrategy: Halted

  dataVolumeTemplates:
    - metadata:
        name: compute-node-0-root
      spec:
        source:
          blank: {}
        storage:
          storageClassName: <storage-class>
          accessModes:
            - ReadWriteMany      # required for live migration
          volumeMode: Block
          resources:
            requests:
              storage: 120Gi     # keep above the 100 GB validator minimum

  template:
    metadata:
      labels:
        kubevirt.io/vm: compute-node-0
    spec:
      domain:
        cpu:
          sockets: 1
          cores: 8
          threads: 1
        memory:
          guest: 16Gi
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
            # Root disk only. kubevirt-redfish adds the CD-ROM itself
            # and manages boot order during provisioning.
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              bridge: {}
              macAddress: "<must match the BareMetalHost bootMACAddress>"
          rng: {}
      networks:
        - name: default
          multus:
            networkName: <network-attachment-definition>
      volumes:
        - name: rootdisk
          dataVolume:
            name: compute-node-0-root
```

---

## Checklist

When defining a new compute node VM:

- [ ] Root disk only. No CD-ROM device in the manifest.
- [ ] Root disk bus is `virtio`.
- [ ] Root disk is at least 120Gi.
- [ ] `accessModes: [ReadWriteMany]` is set explicitly.
- [ ] `volumeMode` is set explicitly and matches what the storage class supports.
- [ ] If `volumeMode` is `Filesystem`, the disk is not smaller than 120Gi.
- [ ] The disk is declared under `spec.dataVolumeTemplates`.
- [ ] No `bootOrder` is set manually.
- [ ] `runStrategy: Halted`, and the application ignores drift on that field.
- [ ] The VM carries the label matched by the Redfish chassis selector.
- [ ] The interface MAC matches the `BareMetalHost` `bootMACAddress`.
- [ ] After the node joins its hosted cluster, the CD-ROM is ejected.

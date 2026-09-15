# OLM on OpenShift — how it works

Background reading for anyone adding, debugging or removing an operator in this repo.

This file explains the **mechanism**. For the point-of-use rules — how to consume the
`operator-olm` subchart, the checklist for a new operator, the sync-wave table, vendoring —
see [`charts/operator-olm/README.md`](charts/operator-olm/README.md). That README lists what
not to do; this one explains why those things break, so a failure that *isn't* on its list is
still diagnosable.

Everything here describes **OLM v0** (API group `operators.coreos.com`), which is what this
cluster runs and what every chart here targets. See [§12](#12-olm-v1) for what is coming.

**Contents**

1. [The mental model](#1-the-mental-model)
2. [CatalogSource — the store](#2-catalogsource--the-store)
3. [Mirroring: `oc mirror` and IDMS](#3-mirroring-oc-mirror-and-idms)
4. [OperatorGroup — scope](#4-operatorgroup--which-namespaces-the-operator-may-enter)
5. [Subscription — the standing intent](#5-subscription--the-standing-intent)
6. [InstallPlan — the receipt](#6-installplan--the-receipt)
7. [ClusterServiceVersion — the installed operator](#7-clusterserviceversion--the-installed-operator)
8. [Upgrades](#8-upgrades)
9. [Uninstalling](#9-uninstalling)
10. [How this repo's Argo layer uses it](#10-how-this-repos-argo-layer-uses-it)
11. [Debug kit](#11-debug-kit)
12. [OLM v1](#12-olm-v1)
13. [Summary](#13-the-seven-things-to-carry-around)

---

## 1. The mental model

OLM is an app store. Six objects, one sentence each:

| Object | Plain meaning | Scope |
|---|---|---|
| **CatalogSource** | The store itself — a pod serving a searchable index of operators | Namespaced |
| **PackageManifest** | A listing in the store window. Read-only, generated | Namespaced (virtual) |
| **Subscription** | "Install this, and keep it updated" — a standing intent | Namespaced |
| **InstallPlan** | The checkout receipt: exactly what will be created | Namespaced |
| **ClusterServiceVersion (CSV)** | The installed app's manifest — the operator's identity card | Namespaced |
| **OperatorGroup** | Which namespaces the installed app is allowed to act in | Namespaced |

The chain only flows one way:

```
CatalogSource   (a pod serving an index image)
      │  packageserver reads it
      ▼
PackageManifest (read-only projection — what's available)
      │  a human writes:
      ▼
Subscription    ──needs an── OperatorGroup in the same namespace
      │  OLM's resolver picks a bundle and emits:
      ▼
InstallPlan     (list of CSVs + CRDs + RBAC to create)
      │  approved (automatically, or by hand)
      ▼
CSV             (the operator's manifest)
      │  OLM materialises what the CSV declares:
      ▼
CRDs · ServiceAccount · Roles/ClusterRoles · Deployment · webhooks
      │  the operator now watches for:
      ▼
Custom Resources (HyperConverged, NMState, …) ── a chart here writes these
```

Two things worth internalising immediately:

- **Only two of these are ever authored: the OperatorGroup and the Subscription.**
  InstallPlan and CSV are produced by OLM. That is exactly why
  [`charts/operator-olm`](charts/operator-olm/) templates two objects and nothing else, and
  why a consuming chart adds only its config CR on top.
- **The CSV — not the Deployment — is the source of truth for the operator pod.**
  Hand-editing the operator's Deployment is reverted by OLM. To change it, change the CSV's
  inputs (`Subscription.spec.config`, [§5](#specconfig--how-to-tune-the-operator-pod)).

---

## 2. CatalogSource — the store

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: generic-cs
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: <registry>/redbull/index:4.22
```

Applying it makes OLM run **a pod** in that namespace serving a gRPC API over the index
image. `oc get pods -n openshift-marketplace` is where to check whether a catalog is actually
alive, as opposed to merely declared.

This repo runs exactly one, [`charts/generic-cs`](charts/generic-cs/) — the mirrored index for
this OpenShift version, from which every operator resolves. It is its own Argo app because one
catalog serves every operator, so exactly one thing must own it; folding it into an operator's
chart would delete the catalog out from under every other Subscription when that operator was
retired.

### Namespace determines visibility

The single most confusing part:

- A CatalogSource in **`openshift-marketplace`** is OpenShift's *global catalog namespace* —
  visible to Subscriptions in **every** namespace.
- A CatalogSource anywhere else is visible **only** to Subscriptions in that same namespace.

That is why `generic-cs` lives in `openshift-marketplace`, and why
[`services/generic-cs/app.yaml`](services/generic-cs/app.yaml) notes that — unlike every other
service here — its namespace is created by OLM itself and is deliberately absent from
`charts/namespaces/values.yaml`.

### Default catalogs, and turning them off

A connected cluster ships four, managed by the marketplace operator: `redhat-operators`,
`certified-operators`, `community-operators`, `redhat-marketplace`. For an air-gapped cluster
they are disabled wholesale via the singleton `OperatorHub` CR:

```bash
oc patch operatorhub cluster --type=merge \
  -p '{"spec":{"disableAllDefaultSources":true}}'
```

That CR is a cluster-scoped singleton that already exists on the cluster — the same shape as
the `OAuth cluster` object [`charts/htpasswd-idp`](../charts/htpasswd-idp/) handles
imperatively, and for the same reason it belongs to the Helmfile bootstrap layer rather than
Argo.

### Digest vs tag

`generic-cs`'s values prefer a digest, and the reason is concrete: **OLM does not re-pull a
mutable tag** unless the CatalogSource also sets

```yaml
spec:
  updateStrategy:
    registryPoll:
      interval: 30m
```

which that chart deliberately does not template. A re-pushed `:latest` index therefore appears
to do nothing at all.

### Argo blind spot

Argo CD ships **no** health check for CatalogSource, so the `generic-cs` app reports Healthy
the instant the object is applied — even if the registry pod crash-loops. Argo's health
assessment is per-kind and there is simply no assessor registered for this kind. The only
legible signal is the *consuming* Subscription flipping to `CatalogSourcesUnhealthy`.

### PackageManifest — the listing

```bash
oc get packagemanifests -n openshift-marketplace
oc describe packagemanifest kubevirt-hyperconverged -n openshift-marketplace
```

This is **not a stored object**. It is an aggregated API served live by `packageserver`,
which reads the catalog pods. It cannot be created or edited. It is the lookup table for the
strings that must be exactly right:

```bash
oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace \
  -o jsonpath='{.status.catalogSource} {.status.channels[*].name} {.status.channels[?(@.name=="stable")].currentCSV}'
```

→ the catalog it came from, the available channels, and the CSV at the head of `stable`. That
is the command [`charts/openshift-virtualization/values.yaml`](charts/openshift-virtualization/values.yaml)
cites for verifying `subscription.name` and `startingCSV`.

---

## 3. Mirroring: `oc mirror` and IDMS

The air-gapped environment depends entirely on this, and it is two distinct halves:

- **`oc mirror`** solves *"the images aren't in the internal registry."* A bastion-host tool.
  It copies bits.
- **IDMS** solves *"the cluster still asks for them by their original name."* A cluster
  object. It rewrites pull requests.

Do only the first and every pull still goes to `registry.redhat.io` and fails. Do only the
second and the rewrite points at an empty registry. Both are required — and `oc mirror`
*generates* the IDMS.

### `oc mirror` — the copier

An `oc` plugin (`oc-mirror`), downloaded separately from the OpenShift client. It handles:

1. **OpenShift release payloads** — every image in a given OCP version
2. **Operator catalogs** — an index, plus the bundles *and every operand image they reference*
3. **Additional images** — anything else named explicitly

Point 2 is why this is not `skopeo copy` in a loop. Mirroring a catalog means walking the
index, finding every bundle in the requested channels, reading each bundle's CSV for
`relatedImages`, and copying those too. For CNV that is dozens of images (virt-launcher,
virt-handler, CDI, containerdisks…). Miss one and the operator installs cleanly, then a pod
`ImagePullBackOff`s later under load.

#### ImageSetConfiguration

```yaml
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    channels:
      - name: stable-4.22
        minVersion: 4.22.0
        maxVersion: 4.22.3
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
      packages:
        - name: kubevirt-hyperconverged
          channels: [{name: stable}]
        - name: kubernetes-nmstate-operator
          channels: [{name: stable}]
  additionalImages:
    - name: registry.redhat.io/ubi9/ubi:latest
```

**Filtering is the whole game.** An unfiltered `redhat-operator-index` is hundreds of
operators and well over a terabyte. An explicit `packages:` list cuts it to what is actually
run here; `minVersion`/`maxVersion` do the same for the upgrade graph — without them, every
version in the channel's history is mirrored.

This is also where `operator-olm`'s `startingCSV: ""` default earns itself: if the
ImageSetConfiguration pinned exactly one version, the channel head *is* that version and
there is nothing left to pin against.

> `apiVersion` matters. `v2alpha1` is oc-mirror **v2** (the `--v2` flag, the current path);
> `v1alpha2` is the deprecated v1. Behaviour differs meaningfully — v1 *rebuilt* the catalog
> index with rewritten image references, whereas v2 mirrors it as-is and leans entirely on
> IDMS to do the rewriting. Confirm which version is in use before following an older
> procedure.

#### Two workflows

**Mirror-to-mirror** — the bastion reaches both the internet and the internal registry:

```bash
oc mirror --config=imageset-config.yaml \
  --workspace file:///data/workspace \
  docker://myregistry.internal:8443/redbull --v2
```

**Mirror-to-disk → disk-to-mirror** — nothing touches both networks. The true air-gap:

```bash
# connected side
oc mirror --config=imageset-config.yaml file:///data/mirror --v2
#   → carry /data/mirror/ across on physical media

# disconnected side
oc mirror --from file:///data/mirror \
  docker://myregistry.internal:8443/redbull --v2
```

The first run is hours and hundreds of GB. Later runs are **incremental** — oc-mirror keeps
metadata in the workspace and transfers only what changed. **Keep that workspace.** Losing it
turns the next small update back into a full re-download.

#### What it hands back

Alongside the images, the disk-to-mirror run writes a `cluster-resources/` directory:

```
cluster-resources/
├── idms-oc-mirror.yaml                    ← ImageDigestMirrorSet
├── itms-oc-mirror.yaml                    ← ImageTagMirrorSet (if any tag-based images)
└── cs-redhat-operator-index-v4-22.yaml    ← a ready-made CatalogSource
```

These are manifests to apply, not documentation. Two notes on how they meet this repo:

- **The IDMS and the generated CatalogSource belong in different layers.** IDMS is
  cluster-scoped and drives a node rollout → Helmfile bootstrap. A CatalogSource is a plain
  namespaced object, continuously reconciled → Argo, i.e. `charts/generic-cs`.
- **Do not apply the generated CatalogSource verbatim.** Take its `spec.image` (the mirrored
  index pullspec, ideally by digest) into `generic-cs`'s `catalogSource.image` and keep the
  stable `name: generic-cs`. That is precisely the coupling that chart's comments protect:
  the generated file's name carries the catalog version, while every Subscription in the
  cluster references the CatalogSource *by name*.

### IDMS — the rewriter

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: redbull-mirror
spec:
  imageDigestMirrors:
    - source: registry.redhat.io/container-native-virtualization
      mirrors:
        - myregistry.internal:8443/redbull/container-native-virtualization
      mirrorSourcePolicy: NeverContactSource
    - source: registry.redhat.io/rhel9
      mirrors:
        - myregistry.internal:8443/redbull/rhel9
```

Cluster-scoped, `config.openshift.io/v1`. Read it as **a prefix rewrite rule for the container
runtime**: anything whose pullspec starts with `source`, try `mirrors` instead.

#### How it reaches the nodes

```
IDMS object
    │  the Machine Config Operator watches it
    ▼
renders a MachineConfig containing /etc/containers/registries.conf
    │  per MachineConfigPool (master, worker, …)
    ▼
MCO rolls the pool — one node at a time, respecting maxUnavailable:
    (cordon → drain) → write the file → restart CRI-O (and on many
    versions, reboot) → uncordon
    ^ the drain and the reboot are both version-dependent; see below
```

An IDMS edit is **a rolling change across every node in the cluster**, serialised. On a large
cluster that is hours. It is neither instant nor free, which is why it belongs to bootstrap
and not to a continuously-reconciling Argo app.

> Whether it is a full reboot or only a CRI-O reload is **version-dependent** — newer MCO
> versions can apply registries.conf-only changes without rebooting. Do not assume; watch it:
> ```bash
> oc get mcp          # UPDATING=True while it rolls
> oc get nodes -w
> oc get mc | grep registries
> ```
> Either way, treat it as a disruptive rolling operation and schedule it.

#### IDMS vs ITMS

| | Matches | Object |
|---|---|---|
| **IDMS** | pullspecs by **digest** (`…@sha256:abc…`) | `ImageDigestMirrorSet` |
| **ITMS** | pullspecs by **tag** (`…:v4.22.0`) | `ImageTagMirrorSet` |

The split exists because the two carry different safety guarantees. A digest is
content-addressed — the same digest in the mirror is byte-identical to the upstream one, so
rewriting is provably safe. A tag is mutable, so rewriting one means trusting that the
mirror's `:v4.22.0` is what upstream's was. OpenShift makes that weaker promise an explicit
opt-in.

**For OLM this is almost entirely IDMS's job.** Operator bundles reference their operands by
digest in `relatedImages` — mandated for certified operators precisely so that disconnected
mirroring works. Needing an ITMS for an operator usually means a community operator playing
loose with tags.

#### `mirrorSourcePolicy`

```yaml
mirrorSourcePolicy: NeverContactSource   # or AllowContactingSource (default)
```

The default tries each mirror and, if all fail, **falls back to the original source**. On a
genuinely air-gapped cluster that fallback is a slow timeout against an unreachable host, so
a missing image presents as a long hang rather than a clean failure. `NeverContactSource`
fails fast and honestly — which is what makes "did the mirror actually get this image?"
answerable.

#### ICSP — the deprecated ancestor

`ImageContentSourcePolicy` (`operator.openshift.io/v1alpha1`) is the single predecessor that
IDMS and ITMS split out of, deprecated since 4.13. Existing ones still work; do not write new
ones. Migration is mechanical:

```bash
oc adm migrate icsp <file>.yaml --dest-dir ./idms-out
```

Do not run a live ICSP and an IDMS with overlapping rules — the merged registries.conf becomes
genuinely hard to reason about.

#### Verifying it landed

The object being applied proves nothing; the file on the node is the truth:

```bash
oc get idms,itms
oc debug node/<node> -- chroot /host cat /etc/containers/registries.conf
```

Look for a `[[registry]]` block carrying the `prefix`, with a `[[registry.mirror]]` under it.
Absent means the MachineConfigPool has not finished rolling.

### The two things that break this that aren't IDMS

Both present as mirror failures and are not.

**1. The pull secret.** Nodes need credentials for the mirror registry:

```bash
oc extract secret/pull-secret -n openshift-config --to=. --confirm
# add an auth entry for myregistry.internal:8443
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=.dockerconfigjson
```

Editing that secret triggers its own MCO rollout. Symptom when wrong: `401 Unauthorized` on
pull, *after* the IDMS rewrite has clearly worked.

**2. The registry's CA.** A self-signed or internal-CA certificate must be trusted by the
nodes:

```bash
oc create configmap registry-ca -n openshift-config --from-file=myregistry.internal..8443=ca.crt
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-ca"}}}'
```

Note the key format: hostname with `..` standing in for the port colon. Symptom when wrong:
`x509: certificate signed by unknown authority`. The bastion needs the same CA for `oc mirror`
to push at all — that half is hit immediately, which is why the *cluster* half is the one that
surprises people later.

### The whole sequence, in order

| # | Step | Layer |
|---|---|---|
| 1 | Write `ImageSetConfiguration`, run `oc mirror` | Bastion, by hand |
| 2 | Add mirror credentials to the global pull secret | Bootstrap (MCO rollout) |
| 3 | Trust the registry CA via `image.config.openshift.io/cluster` | Bootstrap (MCO rollout) |
| 4 | Apply the generated **IDMS/ITMS** | Bootstrap (**MCO rollout — the slow one**) |
| 5 | `disableAllDefaultSources: true` on `OperatorHub` | Bootstrap |
| 6 | Set `catalogSource.image` in `charts/generic-cs`, push | **Argo** |
| 7 | Subscriptions resolve and install | **Argo**, automatically |

Steps 2–4 are each a rolling node operation. Batch them into one maintenance window rather
than triggering three separate rollouts — a concrete reason they sit together in bootstrap
instead of scattered. Steps 6–7 are the only day-to-day GitOps, and the only fast ones.

---

## 4. OperatorGroup — which namespaces the operator may enter

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
```

An OperatorGroup answers one question: **which namespaces will this operator watch?** OLM
turns the answer into two things: RBAC — Roles and RoleBindings for the operator's
ServiceAccount in each target namespace — and an `olm.targetNamespaces` annotation stamped
onto the operator Deployment's pod template.

Note the second one is an *annotation*, not an env var. Operators scaffolded by operator-sdk
map it into `WATCH_NAMESPACE` themselves, via a downward-API `fieldRef`. So the annotation is
what OLM guarantees, and it is the thing to read when an operator appears to be watching the
wrong scope:

```bash
oc get deploy <operator-deployment> -n <ns> \
  -o jsonpath='{.spec.template.metadata.annotations.olm\.targetNamespaces}'
```

**OLM will not install a CSV into a namespace that has no OperatorGroup.** The Subscription
resolves, the InstallPlan is created, and then the CSV sits at `Failed / NoOperatorGroup`
forever. That is why the OperatorGroup is sync-wave `0` and the Subscription is wave `1` in
`operator-olm` — the ordering is load-bearing, not cosmetic.

### Install modes — the matching rules

Every CSV declares which shapes it supports:

```yaml
installModes:
  - type: OwnNamespace     supported: true
  - type: SingleNamespace  supported: true
  - type: MultiNamespace   supported: false
  - type: AllNamespaces    supported: false
```

And `targetNamespaces` *is* the shape:

| `targetNamespaces` | Mode OLM infers |
|---|---|
| `["openshift-cnv"]` (the OperatorGroup's own namespace) | **OwnNamespace** |
| `["some-other-ns"]` (exactly one, not its own) | **SingleNamespace** |
| `["a", "b"]` | **MultiNamespace** |
| **absent, or `[]`** | **AllNamespaces** |

Ask for a shape the CSV does not support and the CSV goes
`Failed / UnsupportedOperatorGroup`; nothing installs.

**This is the mechanism behind the empty-list trap.** `targetNamespaces: []` is not "unset"
and not "default" — OLM reads an empty or absent list as *all namespaces*, and records that as
`status.namespaces: [""]` (a list containing the empty string, the AllNamespaces sentinel).
The CNV CSV supports only OwnNamespace/SingleNamespace, so an empty list is an immediate
install failure. Hence `charts/openshift-virtualization/values.yaml` states `- openshift-cnv`
explicitly rather than relying on a default.

To see what OLM actually decided:

```bash
oc get og -n openshift-cnv -o jsonpath='{.items[*].status.namespaces}'
# [""]                → AllNamespaces
# ["openshift-cnv"]   → OwnNamespace
```

There is also `spec.selector` (a label selector over namespaces) as an alternative to an
explicit list — dynamic membership, and rarely worth the unpredictability. `operator-olm` does
not template it.

### One per namespace — and why it is unrecoverable

Two OperatorGroups in one namespace is ambiguous by construction: OLM cannot know which scope
to grant. Its response is to fail **every** CSV in that namespace with
`TooManyOperatorGroups` — including operators that were already running happily. Nothing
retries it back to health; a human must delete one, after which each CSV re-reconciles.

That single fact is behind three deliberate pieces of `operator-olm`: the
`operatorGroup.enabled` ownership flag, the hardcoded `openshift-operators` guard (that
namespace already ships the cluster-wide `global-operators` OperatorGroup), and the rule that
two aliased copies sharing a namespace must disable one. See that chart's README for how to
apply them.

Worth running before adding any operator, since this bites in namespaces nobody here created:

```bash
oc get operatorgroups -A
```

### `spec.serviceAccountName` — scoped installs

Not templated by `operator-olm`, but worth knowing it exists. By default OLM installs
operators using its own highly-privileged ServiceAccount. Setting `spec.serviceAccountName` on
the OperatorGroup makes OLM install the operator *as* that SA — if the SA lacks a permission
the CSV requests, the install fails loudly instead of quietly granting near-cluster-admin
rights. The standard hardening move for letting a team install operators into their own
namespace.

---

## 5. Subscription — the standing intent

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  name: kubevirt-hyperconverged     # the PACKAGE name — not free-form
  channel: stable
  source: generic-cs                # CatalogSource name
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
  # startingCSV: kubevirt-hyperconverged.v4.22.0
```

`metadata.name` is cosmetic. **`spec.name` is the package name** from the PackageManifest —
get it wrong and the result is `ResolutionFailed`, not a helpful "no such package". `source`
and `sourceNamespace` are a **by-name** reference to a CatalogSource, and nothing on either
side validates the pair; that is why both `charts/generic-cs` and `operator-olm` carry
matching comments about the coupling.

A Subscription is a **continuous** intent, not a one-shot install — OLM re-resolves it
forever. That is what makes cross-app ordering unnecessary in the Argo layer here: a
Subscription whose catalog has not landed yet sits at `CatalogSourcesUnhealthy` and heals
itself the moment `generic-cs` syncs. A soft dependency, exactly as `CLAUDE.md` requires of
anything in that layer.

### Channels

A channel is a named upgrade track inside the package — `stable`, `stable-4.22`, `fast`,
`candidate`. Subscribing to one means "follow this track's head". Switching channels is a
legitimate upgrade path (`stable-4.21` → `stable-4.22`) and is **not reversible**: OLM does
not support downgrades.

### `startingCSV` pins the first install only

It means "begin at this exact version". After that, with `installPlanApproval: Automatic`, OLM
keeps upgrading within the channel — the pin does **not** hold. Genuinely holding a version
requires `Manual` approval, which stalls under GitOps (below). The default of empty — take the
channel head — is right for a mirror containing exactly one version. A `startingCSV` that is
absent from the catalog yields `ResolutionFailed` forever, with nothing installed.

### `spec.config` — how to tune the operator pod

Not templated by `operator-olm`, and the Subscription field most worth knowing, because it is
the **only** supported way to change the operator's Deployment:

```yaml
spec:
  config:
    env:
      - {name: HTTP_PROXY, value: http://proxy:3128}
    nodeSelector:
      node-role.kubernetes.io/infra: ""
    tolerations: [...]
    resources:
      limits: {memory: 1Gi}
```

OLM merges these into the CSV's Deployment. Editing that Deployment directly is reverted.

### States, and what Argo shows

`status.state`:

| State | Meaning |
|---|---|
| `AtLatestKnown` | Installed, nothing newer in the channel. **The only healthy state.** |
| `UpgradeAvailable` | A newer CSV exists but has not started (typically Manual approval) |
| `UpgradePending` | An InstallPlan is in flight |

`status.conditions` — the ones actually seen in practice:

| Condition | Cause | Where to look |
|---|---|---|
| `CatalogSourcesUnhealthy` | Catalog missing, or its pod not serving | `oc get pods -n openshift-marketplace`; check `source`/`sourceNamespace` spelling |
| `ResolutionFailed` | Package/channel/startingCSV absent from the catalog, or an unsatisfiable dependency | `oc describe sub` — the message names the missing thing |
| `InstallPlanPending` | Waiting for manual approval | The InstallPlan ([§6](#6-installplan--the-receipt)) |
| `InstallPlanFailed` | The InstallPlan tried and failed | `oc describe ip <name>` |
| `InstallPlanMissing` | The referenced InstallPlan was deleted | Delete and recreate the Subscription |
| `BundleUnpackFailed` | The unpack Job could not pull the bundle image | Registry / IDMS ([§3](#3-mirroring-oc-mirror-and-idms)) |

**Argo CD's built-in Subscription health check maps exactly onto this:** Healthy only at
`AtLatestKnown`; Progressing while status is absent or `InstallPlanPending`; Degraded on
`CatalogSourcesUnhealthy` / `ResolutionFailed` / `InstallPlanFailed` / `InstallPlanMissing`.

Two consequences follow, and both are load-bearing here:

- Sync-wave 1 is a **real gate** — Argo will not apply wave 10 until OLM has genuinely
  finished, so a consuming chart's config CR meets a cluster that already has the CRD.
- `installPlanApproval: Manual` **stalls the whole app**: Progressing forever means no later
  wave ever runs, so the config CRs are never applied at all.

---

## 6. InstallPlan — the receipt

The object nobody authors, and the one that makes Manual approval make sense.

```bash
oc get installplans -n openshift-cnv        # `ip` for short
```

When the resolver picks a bundle, it writes an InstallPlan listing **every** object to be
created: the CSV(s), every CRD, every ServiceAccount, every Role/ClusterRole and binding.

```yaml
spec:
  clusterServiceVersionNames: [kubevirt-hyperconverged.v4.22.0]
  approval: Automatic          # or Manual
  approved: true               # ← the switch
status:
  phase: Complete
```

Phases: `Planning → RequiresApproval → Installing → Complete` (or `Failed`).

**Manual approval** means OLM creates the InstallPlan with `approved: false` and stops.
Approval is a patch:

```bash
oc patch installplan <name> -n <ns> --type=merge -p '{"spec":{"approved":true}}'
```

`operator-olm` deliberately ships nothing to do this automatically — a self-approving Job
defeats the entire point of choosing Manual. Under GitOps the workable answer is `Automatic`,
with versions pinned by what the mirrored catalog actually contains.

**Dependency resolution lives here too.** A bundle can declare required APIs; if a package
needs another operator, the resolver puts *both* CSVs into one InstallPlan and installs the
dependency alongside. That is why an InstallPlan sometimes lists operators nobody asked for,
and why `ResolutionFailed` sometimes names a package that is not the one being installed.

It is also why `charts/openshift-virtualization` notes that `kubernetes-nmstate` is **not**
installed by CNV: nmstate is not a declared dependency of the CNV bundle, so no resolver will
ever bring it in. It is a separate package needing a separate Subscription — which is why that
chart's NNCP sits in the last sync wave, so its failure on a cluster without nmstate costs
only the tail of the sync and never the CNV install itself.

---

## 7. ClusterServiceVersion — the installed operator

```bash
oc get csv -n openshift-cnv
```

The CSV is the operator's manifest. It carries:

- **`spec.install`** — the operator's Deployment(s), verbatim. OLM creates and owns them.
- **`spec.customresourcedefinitions.owned`** — the CRDs this operator provides
  (`HyperConverged`, `VirtualMachine`, …). Cluster-scoped, and what a consuming chart's
  wave-10 config CRs depend on.
- **`spec.customresourcedefinitions.required`** — CRDs it needs from elsewhere; drives
  dependency resolution.
- **`spec.permissions` / `clusterPermissions`** — OLM creates the ServiceAccount, Roles and
  ClusterRoles from these. Operator RBAC is never hand-written.
- **`spec.installModes`** — matched against the OperatorGroup ([§4](#4-operatorgroup--which-namespaces-the-operator-may-enter)).
- **`spec.webhookdefinitions`** — validating and mutating webhooks. The source of the real
  race the charts here guard against: a CRD is registered a moment *before* its webhook is
  serving, so a config CR applied in that window is rejected. Hence
  `SkipDryRunOnMissingResource=true` on the wave-10 objects.

### CSV phases

| Phase | Meaning |
|---|---|
| `Pending` | Waiting on something — usually a missing or wrong OperatorGroup, or a required CRD |
| `InstallReady` | Requirements met, about to install |
| `Installing` | Creating the Deployment |
| `Succeeded` | **The operator is running.** The only good steady state |
| `Failed` | See `status.reason` — `NoOperatorGroup`, `TooManyOperatorGroups`, `UnsupportedOperatorGroup`, `InstallComponentFailed` |
| `Replacing` | An upgrade is in progress; this CSV is being superseded |
| `Deleting` | On its way out |

```bash
oc get csv -n openshift-cnv \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason
```

### Copied CSVs — "why does this operator appear everywhere?"

When an OperatorGroup targets namespaces beyond its own, OLM **copies** the CSV into every
target namespace so that users there can see what is available. With AllNamespaces that is
every namespace on the cluster — which is why `oc get csv -A` on a normal OpenShift cluster
returns hundreds of rows.

Copies carry the `olm.copiedFrom` annotation:

```bash
oc get csv -n <some-ns> -o jsonpath='{.items[*].metadata.annotations.olm\.copiedFrom}'
```

Three consequences:

- **Deleting a copy is pointless** — OLM recreates it immediately. Delete the *original*, in
  the operator's own namespace.
- **Copies run nothing.** There is one operator Deployment, in the install namespace. A copy
  is a read-only advertisement.
- Copies can be suppressed cluster-wide via the `OLMConfig` singleton
  (`spec.features.disableCopiedCSVs: true`) when the noise starts hurting etcd or listings.

### `oc get operators` — the cluster-wide aggregate

```bash
oc get operators
```

A cluster-scoped `Operator` object per installed operator, aggregating every resource OLM
associates with it via the label `operators.coreos.com/<package>.<namespace>: ""`. It is the
fastest "what is installed on this cluster, and where" view — and that label is how an
operator's stray resources are found during a cleanup.

---

## 8. Upgrades

With `installPlanApproval: Automatic`, when the catalog's channel head moves:

1. The resolver notices a newer CSV; the Subscription goes `UpgradeAvailable` → `UpgradePending`.
2. A new InstallPlan is created and approved.
3. The new CSV installs. The old one goes `Replacing`, then is garbage-collected.
4. The Subscription returns to `AtLatestKnown`.

Two mechanisms decide what "newer" means:

- **`spec.replaces`** — each CSV names the one it supersedes, forming a linear chain that OLM
  walks one hop at a time. A broken link stalls the upgrade.
- **`olm.skipRange`** — a semver range (`">=4.20.0 <4.22.0"`) letting a CSV jump the chain in
  one step. Standard for large version gaps.

**On an OpenShift upgrade:** mirror a new index, bump `catalogSource.image` in
`charts/generic-cs/values.yaml`, and keep the **name** stable. A rename is a delete-and-recreate,
and every Subscription is unresolvable in between.

**Operands do not upgrade with the operator.** A new CNV operator does not restart running
VMs. Workload updates are the operator's own business, governed by its config CR — for CNV,
the `HyperConverged`'s `workloadUpdateStrategy`.

---

## 9. Uninstalling

**`git rm` does not uninstall an operator.** Deleting the **Subscription** removes only the
standing intent. The CSV, the CRDs, the operator Deployment, the ServiceAccounts and every
operand keep running, now unmanaged. There is no cascade, because the Subscription does not
*own* the CSV — it points at it.

So under Argo, deleting `gitops/services/openshift-virtualization/` deletes the Application,
which prunes the OperatorGroup and Subscription it rendered — and leaves CNV fully installed
and running.

By hand, in this order:

```bash
# 1. stop the standing intent
oc delete subscription kubevirt-hyperconverged -n openshift-cnv

# 2. delete the OPERANDS FIRST, while the operator is still alive to run their finalizers
oc delete hyperconverged kubevirt-hyperconverged -n openshift-cnv

# 3. now the operator itself — this takes down the operator Deployment
oc delete csv -n openshift-cnv \
  -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv

# 4. only then the CRDs, by hand — read the warning below first
oc get crd -o name | grep kubevirt.io
```

> **Deleting a CRD deletes every custom resource of that kind, cluster-wide, instantly and
> irreversibly.** `oc delete crd virtualmachines.kubevirt.io` deletes every VM on the cluster.
> There is no confirmation and no undo. Always `oc get <kind> -A` first.

Step 2 before step 3 is not cosmetic: deleting the CSV first removes the operator that owns
the operands' finalizers, and the operands then hang in `Terminating` forever. The escape is
`oc patch <res> -p '{"metadata":{"finalizers":null}}' --type=merge` — the same finalizer-stuck
shape that `CLAUDE.md` documents for Argo Applications.

---

## 10. How this repo's Argo layer uses it

Mostly a pointer section; the detail is in
[`charts/operator-olm/README.md`](charts/operator-olm/README.md) and in each service's
`app.yaml`.

- **OperatorGroup wave 0 → Subscription wave 1 → config CRs wave 10+.** Wave 0→1 is required
  by OLM (`NoOperatorGroup`). Wave 1→10 works because Argo has a real Subscription health
  check ([§5](#states-and-what-argo-shows)).
- **`SkipDryRunOnMissingResource=true` on wave-10 CRs** covers the residual window where the
  CRD is registered but the webhook is not yet serving. It is not needed on the two objects
  `operator-olm` renders — `operators.coreos.com` CRDs ship with every OpenShift cluster.
- **All ordering here is intra-app.** Dependencies *between* these apps — `generic-cs` before
  an operator, CNV before `kubevirt-redfish` — are soft and recover via `retry`/`selfHeal`, so
  no cross-app sync waves are introduced. See `CLAUDE.md`.
- **Operator-mutated config CRs go perpetually `OutOfSync`.** Operators like HCO default dozens
  of spec fields that were never set in the chart, and `selfHeal: true` then fights the
  operator indefinitely. The fix is `spec.ignoreDifferences`, which lives on the
  **Application** — the `overrides:` block in `gitops/services/<operator>/app.yaml` — because
  it is an Argo-comparison concern, not a chart concern:

  ```yaml
  overrides:
    spec:
      ignoreDifferences:
        - group: hco.kubevirt.io
          kind: HyperConverged
          jsonPointers: ["/spec"]
  ```

  Narrow it to the specific mutated fields once they are known; ignoring all of `/spec` also
  stops selfHeal from correcting real drift.

---

## 11. Debug kit

**One command for the whole picture:**

```bash
oc get og,sub,ip,csv -n <namespace>
```

Read it top-down. The first thing that is wrong is the cause; everything below it is a
symptom.

| Symptom | Look at | Likely cause |
|---|---|---|
| No InstallPlan at all | `oc describe sub` | `ResolutionFailed` (wrong package/channel/startingCSV) or `CatalogSourcesUnhealthy` |
| InstallPlan stuck `RequiresApproval` | `oc get ip -o yaml` | `installPlanApproval: Manual` |
| CSV `Failed / NoOperatorGroup` | `oc get og -n <ns>` | No OperatorGroup in that namespace |
| CSV `Failed / TooManyOperatorGroups` | `oc get og -A` | Two charts own the same namespace |
| CSV `Failed / UnsupportedOperatorGroup` | `oc get csv -o jsonpath='{.spec.installModes}'` | A `targetNamespaces` shape the CSV does not support — often empty, i.e. AllNamespaces |
| CSV `Succeeded`, operator pod not running | `oc describe pod -n <ns>` | Image pull (IDMS/pull secret/CA), or SCC |
| Everything Succeeded, the config CR is ignored | `oc get deploy <op> -n <ns> -o jsonpath='{.spec.template.metadata.annotations.olm\.targetNamespaces}'` | Wrong namespace, or the operator is not watching it — this is what it actually thinks it watches |
| Catalog empty, no packagemanifests | `oc get pods -n openshift-marketplace` | Index pod crash-looping — bad image or unreachable registry |

```bash
# what's available
oc get packagemanifests -n openshift-marketplace | grep -i <name>
oc describe packagemanifest <pkg> -n openshift-marketplace   # channels + currentCSV

# what's installed, cluster-wide
oc get operators
oc get csv -A --field-selector status.phase!=Succeeded       # only the broken ones

# the catalog itself
oc get catalogsource -A
oc get pods -n openshift-marketplace

# scope audit — worth running before adding any operator
oc get operatorgroups -A

# the operator's own logs
oc logs deploy/<operator-deployment> -n <ns>

# OLM's logs, when the objects themselves make no sense
oc logs -n openshift-operator-lifecycle-manager deploy/olm-operator
oc logs -n openshift-operator-lifecycle-manager deploy/catalog-operator
```

The last two are underused. When a Subscription's status is unhelpfully terse, the resolver's
actual reasoning is in `catalog-operator`.

---

## 12. OLM v1

Everything above is **OLM v0** (API group `operators.coreos.com`) — what this cluster runs and
what every chart here targets.

Recent OpenShift also ships **OLM v1** alongside it (API group `olm.operatorframework.io`),
with a much smaller surface:

- **`ClusterCatalog`** replaces CatalogSource — serves catalog content over HTTP, with no
  per-catalog gRPC pod.
- **`ClusterExtension`** replaces Subscription + OperatorGroup + InstallPlan in a single
  object. It takes a ServiceAccount and installs as that identity: no implicit OperatorGroup
  semantics, no install modes, no copied CSVs.

It does not yet cover every operator (single-namespace and webhook-heavy operators were the
last gaps), and v0 continues to work alongside it. Check what this cluster actually has rather
than assuming either way:

```bash
oc api-resources | grep -E 'operators.coreos.com|olm.operatorframework.io'
```

There is no reason to rewrite `operator-olm` for it now. The point of knowing the names is to
recognise what is being looked at when a future operator ships only a v1 bundle.

---

## 13. The seven things to carry around

1. **Only two objects are authored.** OperatorGroup and Subscription. Everything else is
   produced by OLM.
2. **No OperatorGroup, no install** — and **two OperatorGroups breaks every operator in the
   namespace**, not just the new one.
3. **Empty `targetNamespaces` means AllNamespaces**, never "default".
4. **`spec.name` is the package name** from the PackageManifest, not a chosen name.
5. **Catalog references are by name and nothing validates them.** A typo surfaces as
   `CatalogSourcesUnhealthy`, not as an error at apply time.
6. **`Manual` approval stalls GitOps** — Argo sits Progressing and no later sync wave ever
   runs.
7. **Deleting the Subscription uninstalls nothing.** Subscription → operands → CSV → CRDs, in
   that order, and deleting a CRD deletes every CR of that kind cluster-wide.

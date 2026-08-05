# redbull-platform — context for future sessions

CD is **split in two**: a **Helmfile bootstrap layer** (this repo's
`helmfile.yaml.gotmpl` + `charts/`) plus an **Argo CD service layer** (this repo's
`gitops/`). See `README.md` for the release table, usage, and configuration. This
file covers the non-obvious *why* behind the current shape, so it doesn't get
re-litigated or accidentally reverted.

## The CD split: Helmfile bootstrap + Argo CD service layer

**Helmfile** (`helmfile.yaml.gotmpl`) owns only the **bootstrap + order-sensitive**
layer: `namespaces`, `htpasswd-idp` (local-shell postsync hook, see below),
`crossplane` → `provider-http` → `provider-http-config` (the one genuinely hard
CRD-before-CR ordering), plus the still-Helmfile-managed `segments-manager-mongodb`
and `mock-segment-connectivity`, and the not-yet-migrated `bmh-generator-operator`,
`server-scanner-dashboard`, `hosted-cluster-integration`. Argo CD is **already
installed** (OpenShift GitOps, namespace `user1-argocd`) — this platform does not
deploy it.

**Argo CD** owns the stateless service layer via **one generic ApplicationSet**
(`gitops/appset.yaml`) over `gitops/services/<env>/<service>/{app.yaml,values.yaml}`:
`temporal`, `segments-manager`, `workflows`, `segment-lifecycle`. Each service's
chart lives in its **own repo in the `helm-charts` git group** (`helm-charts-<name>`,
chart at repo root) — the sole, hand-edited copy; the code repos no longer carry a
`helm/` chart folder (except `workflows` keeps `helm/mock-segment-connectivity`).

Why keep Helmfile at all instead of going all-Argo: the bootstrap layer is
cluster-scoped, order-sensitive, and its hooks need an admin kubeconfig
(`apply-oauth.sh`, the `kubectl wait` presyncs) — none of which is a
continuously-reconciled concern. Splitting this way means **Argo inherits zero hard
ordering**: every dependency left in the Argo layer is soft (a worker crash-loops
until Temporal is up, then connects) and recovers via `retry`/`selfHeal`. The only
real ordering (Postgres→schema→server) is now *intra-chart* — see next section.

**Do not** move the bootstrap releases into Argo, or add cross-app sync-wave/RollingSync
ordering to the ApplicationSet, without re-deriving the above.

### Deleting a service requires the Application finalizer (silent-orphan trap)

Removing a `gitops/services/<env>/<service>/` folder makes the git generator stop
emitting that service, so the ApplicationSet deletes its Application. But deleting an
Application **without** `resources-finalizer.argocd.argoproj.io` is a **non-cascading**
delete — the Application object disappears and every resource it managed is left
running in the cluster, unowned and invisible to Argo. There is no error; the app
just vanishes and the workloads stay forever.

Argo CD 3.x's ApplicationSet controller adds that finalizer to generated Applications
on its own, which makes it look unnecessary on a current cluster — **older controllers
do not**. Both halves were verified live on the dev cluster (Argo 3.1.16 / GitOps
1.18.6): an appset-generated app (auto-finalized) cascaded cleanly on folder removal,
and a hand-made Application with `finalizers: []` orphaned its ConfigMap/Service/SA
verbatim.

The finalizer is declared here as **defence in depth, not as the diagnosed cause** of
the 2026-07-28 air-gapped incident — see the deadlock below, which is what actually
bit.

So `gitops/appset.yaml` now declares the finalizer **explicitly** in
`template.metadata`. **Do not remove it** because "Argo adds it anyway" — that is only
true on new enough controllers, and the failure mode is silent. Equally, do not set
`spec.syncPolicy.preserveResourcesOnDeletion: true`, which suppresses the same cascade.

### The real trap: deleting a service folder deadlocks its own deletion

**Never delete a `gitops/services/<env>/<service>/` folder in a single commit.** Doing
so hangs the Application in `Unknown`/`Progressing` forever with its finalizer set, and
**nothing is deleted from the cluster** (observed on the air-gapped env, 2026-07-28,
deleting `temporal`).

The cause is this appset's own multi-source design. Every Application renders from two
sources: the chart repo, plus *this* repo as `$values`, with a valueFile at
`$values/gitops/services/<env>/<service>/values.yaml`. So `app.yaml` (what the git
generator watches) and `values.yaml` (what the app renders from) sit in the **same
folder**, and one commit removes both. Then:

1. the generator stops emitting the service → the ApplicationSet deletes the Application;
2. `resources-finalizer.argocd.argoproj.io` blocks removal until the cascade runs;
3. the cascade needs a successful reconcile, which needs a successful **manifest render**;
4. rendering now fails — `values file $values/… does not exist` — so no resource tree is
   ever computed, nothing is deleted, and the finalizer holds the app forever.

Deleting the service breaks the very thing that makes deleting it possible. The
finalizer is not missing here, it is *stuck* — which reads exactly like "the finalizer
didn't work", and sends you chasing the wrong bug.

**Safe procedure — two commits:**

1. `git rm gitops/services/<env>/<service>/app.yaml` — the generator stops emitting the
   service and the Application is deleted, while `values.yaml` remains so rendering
   still succeeds and the cascade completes normally.
2. Once the Application is gone, `git rm -r` the rest of the folder.

**Why not `helm.ignoreMissingValueFiles: true`** (the tempting one-line fix): it does
work for deletion — verified live, folder removed in one commit, app and resources both
cleanly deleted. But it cannot distinguish "folder deleted on purpose" from "values file
missing by mistake", and `syncPolicy.automated` here is `prune: true, selfHeal: true`.
Verified live on the same harness: with the flag on, deleting **only** `values.yaml`
(keeping `app.yaml`) made the app silently re-render on chart defaults and auto-apply
them to the live cluster in **under 10 seconds**, reporting `Synced/Healthy` throughout —
no error, no warning. For a real service that means chart-default image tags, replica
counts and resource limits landing in prod, plus pruning of anything gated behind a
value. Without the flag that same mistake fails loudly and changes nothing. Don't enable
it without re-deriving this trade.

A structural alternative that gets both properties (single-commit delete *and*
fail-loud) is moving per-service values out of the service folder — e.g.
`gitops/values/<env>/<service>.yaml` — so deleting the folder removes only `app.yaml`
and never breaks rendering. Costs the repo's "adding a service = one new folder"
ergonomics.

**Recovering a service already stuck this way:** restore only `values.yaml` and push —
rendering recovers, the pending cascade completes, and the resources are deleted
properly; then delete `values.yaml` in a follow-up commit. To instead *keep* the
service, clear the finalizer (`kubectl patch app <name> -n <ns> --type=merge -p
'{"metadata":{"finalizers":null}}'`), which drops the Application but leaves the
workloads running, then restore the folder in git — the recreated Application **adopts**
the live resources, because tracking is by the `app.kubernetes.io/instance` label they
already carry. No downtime, PVCs preserved.

Note the finalizer fix above only affects deletions from *now on*. Resources already
orphaned stay orphaned:
Argo no longer tracks them, so they must be cleaned up by hand (they still carry
`app.kubernetes.io/instance=<app>` / the `argocd.argoproj.io/tracking-id` annotation,
which is how you find them). Re-adding the service folder does **not** adopt them
cleanly either — the new Application collides with the live objects.

## Crossplane on OpenShift: two *different* SCC fixes, for two different pods

Crossplane's pods are rejected outright by OpenShift's `restricted-v2` SCC, which
allocates each namespace its own UID range (e.g. `1000970000-1000979999`) and
refuses any hardcoded UID outside it. The ReplicaSet then never creates a pod
(`unable to validate against any security context constraint`), so with
`helmDefaults.wait: true` the release just burns its timeout and fails. There are
**two separate offenders**, and the fix differs for each — don't assume one covers
the other.

**1. The crossplane core Deployments** (`crossplane`, `crossplane-rbac-manager`) —
the upstream chart pins `runAsUser`/`runAsGroup: 65532`. Fixed declaratively in
`helmfile.yaml.gotmpl` by nulling `securityContextCrossplane.runAsUser`/`runAsGroup`
(and the `securityContextRBACManager` pair). Nulling *removes the fields entirely*
from the rendered manifest, so the SCC assigns an in-range UID and mutates in the
`capabilities.drop: [ALL]` / `runAsNonRoot` / seccomp defaults it requires.

**2. The provider's own runtime pod** — a completely different object: its
Deployment is generated by Crossplane's *package manager* from the provider
package, which bakes in `runAsUser: 2000`. **No Helm value reaches it**, so fix #1
does nothing here; the symptom is a Provider stuck at `INSTALLED=True HEALTHY=False`
forever while `provider-http-config`'s presync `kubectl wait` times out.

The tempting fix — clearing the security context via a `DeploymentRuntimeConfig` —
**does not work**, verified on Crossplane 2.3.2: Crossplane honours an empty
*container* `securityContext: {}` but **re-applies the pod-level one
unconditionally**, so the pod keeps `runAsUser: 2000` either way. So instead
`charts/provider-http` keeps the package's non-root UID and *grants* it the
`nonroot-v2` SCC, whose `MustRunAsNonRoot` policy accepts any non-zero UID. This
also preserves the package's intended hardening instead of stripping it.

Granting an SCC needs a stable ServiceAccount to bind to, but Crossplane names the
provider SA after the *revision* (`provider-http-<hash>`), which changes on every
package upgrade and would silently break the binding. So
`templates/deploymentruntimeconfig.yaml` pins it via `serviceAccountTemplate`, and
`templates/scc-rolebinding.yaml` binds `system:openshift:scc:nonroot-v2` to that
stable name — the declarative equivalent of `oc adm policy add-scc-to-user`, so a
fresh cluster needs no out-of-band admin step. Both are gated on
`provider.enabled` because `provider-http-config` renders the *same chart* and
would otherwise collide on those objects.

Two gotchas if you edit the `DeploymentRuntimeConfig`:
- `spec.deploymentTemplate` is validated as a **full DeploymentSpec** — supplying it
  at all requires `selector` *and* `template.spec.containers`. The current chart
  sidesteps this by omitting `deploymentTemplate` entirely.
- Shrinking that field later leaves the live object half-populated under
  server-side apply (Helm drops only the subfields it owns), producing
  `spec.deploymentTemplate.spec.selector: Required value` on the next sync. Fix is
  `kubectl delete deploymentruntimeconfig <name>` and re-sync to recreate clean.

**Do not "simplify" this to a single mechanism** — set `deploymentRuntimeConfig.enabled=false`
on vanilla Kubernetes, where no SCC admission exists and the package UID is used as-is.

## Why Postgres/Mongo are separate releases, not bundled subcharts

`temporal-stack`'s schema-init Job originally ran as a `post-install,post-upgrade`
Helm hook. With `helmDefaults.wait: true`, Helm waits for all Deployments to be
`Ready` *before* running post-install hooks — but the Temporal server pods can't
become ready without the schema existing yet. Deadlock: pods crash-loop on
`pq: relation "schema_version" does not exist`, the release sits in
`pending-install` until it times out.

Fix (in `team-redbull/temporal-stack`, commit `0e213ad`): the schema Job is now
`pre-install,pre-upgrade`. But a `pre-install` hook runs *before any resource in
the chart is created* — including a bundled Postgres subchart's StatefulSet. So
Postgres can no longer live inside `temporal-stack`; it has to already exist
when that chart installs.

Solution: `temporal-postgresql` (`charts/temporal-postgresql`, wrapping the
Bitnami `postgresql` chart) is its own helmfile release, sequenced before
`temporal-stack` via `needs:`. `segments-manager-mongodb` exists for the
identical reason relative to `segments-manager` (its Deployment can't come up
without Mongo already reachable, and helmfile's wait would otherwise block
similarly at scale — plus segments-manager has no schema-job pattern of its own,
this was done proactively for the same "DB must precede app" invariant).

**Do not re-bundle these into subcharts of their consuming chart *under Helmfile***
without re-deriving this deadlock first.

### Exception under Argo CD: `temporal` bundles Postgres (this is intentional)

The whole deadlock above is a **Helmfile artifact** — it is caused by
`helmDefaults.wait: true`, which has no Argo CD equivalent. Argo uses **sync waves**
and waits for each wave to be Healthy before the next, which expresses
Postgres→schema→server ordering natively. So the Argo-managed `temporal` chart
(`helm-charts-temporal`, the combined + renamed successor to `temporal-stack` +
`temporal-postgresql`) **does** bundle Bitnami PostgreSQL as a subchart, safely:

- Postgres subchart → sync-wave `"0"`.
- Schema Job → an **Argo `Sync` hook** at sync-wave `"1"` with
  `hook-delete-policy: BeforeHookCreation`. It must **NOT** carry Helm
  `pre-install`/`pre-upgrade` annotations — Argo maps those to `PreSync`, which runs
  *before* the Postgres subchart, reintroducing the exact original deadlock.
- Temporal server/frontend/UI → sync-wave `"2"`.

This bundling applies **only** to the Argo-managed `temporal` chart. `segments-manager`
+ `segments-manager-mongodb` stay split (Mongo is a separate Helmfile release). Don't
"unify" them by analogy without re-deriving — the two live under different tools.

## Why Postgres/Mongo are separate releases, not bundled subcharts

`temporal-stack`'s schema-init Job originally ran as a `post-install,post-upgrade`
Helm hook. With `helmDefaults.wait: true`, Helm waits for all Deployments to be
`Ready` *before* running post-install hooks — but the Temporal server pods can't
become ready without the schema existing yet. Deadlock: pods crash-loop on
`pq: relation "schema_version" does not exist`, the release sits in
`pending-install` until it times out.

Fix (in `team-redbull/temporal-stack`, commit `0e213ad`): the schema Job is now
`pre-install,pre-upgrade`. But a `pre-install` hook runs *before any resource in
the chart is created* — including a bundled Postgres subchart's StatefulSet. So
Postgres can no longer live inside `temporal-stack`; it has to already exist
when that chart installs.

Solution: `temporal-postgresql` (`charts/temporal-postgresql`, wrapping the
Bitnami `postgresql` chart) is its own helmfile release, sequenced before
`temporal-stack` via `needs:`. `segments-manager-mongodb` exists for the
identical reason relative to `segments-manager` (its Deployment can't come up
without Mongo already reachable, and helmfile's wait would otherwise block
similarly at scale — plus segments-manager has no schema-job pattern of its own,
this was done proactively for the same "DB must precede app" invariant).

**Do not re-bundle these into subcharts of their consuming chart** without
re-deriving this deadlock first.

## Why the htpasswd identity provider is a postsync hook, and merges into the existing provider

`charts/htpasswd-idp` provisions a bootstrap cluster login (`ocpadmin`,
granted cluster-admin) on every cluster this platform deploys onto. It
templates **no Kubernetes resources at all** — the release exists purely to
carry a `postsync` hook (`charts/htpasswd-idp/scripts/apply-oauth.sh`).

Two reasons this is imperative rather than Helm-templated:

1. `oauth.config.openshift.io/cluster`, the object that actually wires an
   identity provider into cluster login, is a singleton created by the
   cluster-version-operator (owned by a `ClusterVersion` ownerReference) that
   already exists before this Helmfile ever touches the cluster. A Helm
   template for `kind: OAuth, name: cluster` would try to *create* a resource
   that's already there, hitting the identical "invalid ownership metadata"
   failure documented below for the segments-manager-mongodb Secret and the
   workflows Namespace — just for this singleton instead.
2. Most clusters already have an HTPasswd provider configured out of band
   (this platform's dev sandbox shipped with one, `htpasswd_provider` /
   Secret `htpasswd`, containing users unrelated to this repo). Adding a
   *second* htpasswd provider just to stay Helm-native would show up as a
   confusing second option on the OpenShift login screen and fragment
   cluster users across two providers — an earlier version of this chart did
   exactly that (a standalone `redbull-platform` provider) before being
   corrected to merge into the existing one instead.

So the hook merges `htpasswdIdp.users` into whichever Secret backs the
cluster's existing HTPasswd-type provider (found via `oc get oauth cluster
-o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")]...}'`), skipping
any username already present rather than overwriting it. Only on a cluster
with **no** HTPasswd provider at all does it fall back to creating one from
scratch, via `htpasswdIdp.bootstrapProviderName`/`bootstrapSecretName`, using
a JSON-patch `add` on `/spec/identityProviders/-` (never a `--type=merge`
replace of the whole list — that would delete every other provider already
configured on the cluster).

**Do not turn this into a Helm-owned `kind: OAuth`/`Secret` template**, and
do not make the "bootstrap a new provider" fallback the default behavior,
without re-deriving both points above first.

**Gotcha if you ever change which provider a username is issued through**:
OpenShift's identity-to-user mapping is sticky. The first successful login
permanently creates a `User` + `Identity` object (e.g. `identity
htpasswd_provider:ocpadmin`), and `mappingMethod: claim` (the default, used
here) refuses to let a *different* provider claim that same username
afterward — logins fail with a 500 (`AuthenticationError: user "X" cannot be
claimed by identity "Y" because it is already mapped to [Z]`), not a clean
401, which is easy to misdiagnose as a broken htpasswd file. Fix is `oc
delete identity <old-provider>:<user>` + `oc delete user <user>` before
retrying under the new provider.

## Naming collision gotcha

Bitnami subchart resources (Secrets, etc.) are commonly named after
`fullnameOverride`. The segments-manager Helm chart's own `fullname` template
collapses to `segments-manager` when the release is named `segments-manager`
(see its `_helpers.tpl` — `contains $name .Release.Name` logic), producing a
secret literally named `segments-manager-mongodb`. Naming the Mongo release's
`fullnameOverride` the same string causes a Helm ownership conflict on install
("invalid ownership metadata"). This is why `charts/segments-manager-mongodb`
uses `fullnameOverride: segments-mongodb` (no `-manager`) instead of the more
obvious `segments-manager-mongodb`.

## workflows charts: no chart ever creates its own Namespace

`team-redbull/workflows` used to ship a single `helm/segment-connectivity` chart with
its own `templates/namespace.yaml` (unconditionally, then later gated behind
`.Values.createNamespace`) — handy for standalone use (e.g. a local kind
cluster) where nothing else provisions the namespace first, but a source of
Helm ownership conflicts here: this platform's `namespaces` release already
pre-creates `redbull-workflows` up front (same pattern as `temporal`,
`segments-manager`, etc.), so a second chart trying to create/adopt that same
`Namespace` object hits the same "invalid ownership metadata" failure as the
segments-manager-mongodb Secret collision above, just for a `Namespace`
instead of a `Secret`.

As of the `helm/workflows` + `helm/segment-connectivity` split (the brain now
has its own chart, decoupled from any one workflow domain — see
`team-redbull/workflows`' CLAUDE.md §1–2), **neither chart has a
`templates/namespace.yaml` or a `createNamespace`/`namespace` value at all**.
Both releases below rely entirely on `helmDefaults.createNamespace: false` +
their Helmfile-level `namespace: redbull-workflows` field, which requires that
namespace to already exist by the time they sync — guaranteed by `needs:
[default/namespaces]` on both releases.

**Do not add a per-chart Namespace template or `createNamespace` value back
into any `team-redbull/workflows` chart (or any future per-domain chart under
`helm/<domain>/`), and do not remove `redbull-workflows` from
`charts/namespaces/values.yaml`**, without re-deriving this conflict first —
every workflow-domain chart shares this one namespace, so its ownership
belongs solely to the `namespaces` release.

Now that `workflows`/`segment-lifecycle` are **Argo-managed**, the `namespaces`
release is the **sole** namespace mechanism: it pre-creates `redbull-workflows` and
stamps the `argocd.argoproj.io/managed-by` label that grants this namespaced GitOps
instance its in-namespace RBAC. The ApplicationSet deliberately does **NOT** use
`CreateNamespace=true`/`managedNamespaceMetadata` — verified live: the namespaced
`user1-argo` application-controller has no cluster RBAC for the cluster-scoped
Namespace object and gets `forbidden` trying to create or patch one. This is fine
because the `namespaces` release runs in the bootstrap of *every* environment (it
builds namespaces from a static list, independent of whether the DBs/mock are
deployed there — so even the air-gapped "external DBs" case has its namespaces
pre-created). The charts themselves still template **no** Namespace.

**If you ever want Argo to create namespaces itself** (a cluster-scoped instance, or
an env without the namespaces release), grant the application-controller SA a
ClusterRole for `namespaces` create/patch and re-add `CreateNamespace=true` — but
that weakens the namespaced instance's isolation; keeping the namespaces release is
preferred.

## No GHCR pull secret (images are public)

All `ghcr.io/team-redbull/*` images (including `segments-manager`) are public
packages — verified 2026-07-10 via `gh api orgs/team-redbull/packages`
(`"visibility":"public"`) and by pulling a manifest anonymously with no
credentials. There used to be a `ghcr-pull-secret` created by
`charts/namespaces` from `requiredEnv "GHCR_USER"`/`requiredEnv "GHCR_TOKEN"`,
which forced every developer to export a personal PAT before every
`helmfile sync`. That machinery has been removed entirely (not just disabled)
— it was solving a problem that doesn't exist for a public registry.

**If a `team-redbull` image ever goes private again**, pulls will fail with no
warning (no pull secret exists to catch it). At that point, re-add a
`kubernetes.io/dockerconfigjson` Secret (a prior version of this lived at
`charts/namespaces/templates/ghcr-pull-secret.yaml`, git history has it) and
wire it via `imagePullSecrets`/`image.pullSecrets` in that release's `values:`
block — but prefer a shared robot/service-account token created once directly
in-cluster over per-developer `requiredEnv` PATs, since the credential doesn't
need to vary per developer.

## OCI chart references in helmfile

Don't add a `repositories:` entry with `oci: true` for Bitnami/OCI charts —
that produces a double `oci://oci://...` URL bug in this helmfile version.
Reference OCI charts directly in the release's `chart:` field instead:
`chart: oci://registry-1.docker.io/bitnamicharts/postgresql`.

## Local machine gotcha (not project state, but recurring)

This developer's `~/Library/Caches/helm*` and `~/Library/Preferences/helm`
have previously ended up root-owned (residue from some earlier `sudo helm`
invocation), which breaks `helmfile template`/`sync` with permission-denied
errors. Fix is `sudo chown -R $(whoami):staff` on those paths — not a repo
issue, don't try to "fix" it in the helmfile.

## The `helm-charts` git group (Argo CD chart source)

Every Argo-managed service's chart lives in its **own repo** in a `helm-charts` git
group, chart at repo **root**, referenced by `gitops/appset.yaml` as
`helm-charts-<service>`:

- `helm-charts-temporal` — the combined + renamed successor to `team-redbull/temporal-stack`
  (bundles Bitnami PostgreSQL; schema Job is an Argo Sync hook — see the temporal
  exception section above). Created by renaming `temporal-stack` in place.
- `helm-charts-segments-manager` — extracted from `team-redbull/segments-manager`'s
  `deploy/helm`.
- `helm-charts-workflows` — extracted from `team-redbull/workflows`' `helm/workflows`.
- `helm-charts-segment-lifecycle` — extracted from `team-redbull/workflows`'
  `helm/segment-connectivity` (renamed with the domain).

Each `helm-charts-<name>` repo is the **sole, hand-edited copy** of its chart; the
source chart folder is deleted from the code repo after extraction. CI (the shared
`ghcr-build-push.yml`) cross-commits image-tag bumps into these repos using the
`REDBULL_WRITE_TOKEN` PAT (the default `GITHUB_TOKEN` can't write to another repo).

**GitHub is flat (`helm-charts-<name>`); the air-gapped GitLab uses a real subgroup
(`helm-charts/<name>`)** — the only difference when moving there is the `repoURL` host
in `gitops/appset.yaml` + `sourceRepos` in `gitops/project.yaml`. See README.

## Related repos

- `team-redbull/temporal-stack` → **renamed to `helm-charts-temporal`** (Argo-managed;
  see the `helm-charts` group above). Schema Job hook timing still originates here.
- `team-redbull/segment_manager` — original segments-manager chart/source,
  `deploy/helm` path. Still on the old Docker Hub-based build workflow.
- `team-redbull/segments-manager` (also cloned locally at
  `/Users/itayherzberg/Projctes/segments-manager`) — newer rework in progress,
  actively developed on `feature/mongodb-no-vrf`. Chart is still internally
  named/labeled `vlan-manager` (stale branding, not yet renamed) even though
  the repo and GHCR image are `segments-manager`. Its chart moves to
  `helm-charts-segments-manager`; the `deploy/helm` folder is deleted after extraction.
- `team-redbull/.github` — org-wide reusable workflows repo. Hosts
  `ghcr-build-push.yml`, the canonical build/version/GHCR-push/Helm-bump flow. Needs a
  `chart-repo` input + `REDBULL_WRITE_TOKEN` to cross-commit bumps into the `helm-charts`
  repos. `segments-manager`'s `build.yml` is a 9-line caller into it. Other service
  repos (`segment_manager`, `workflows`, `BareMetalHostUCS`, `ServerScanner`,
  `dhcp_scope_manager`) still have their own inline copies.
- `team-redbull/workflows` — Temporal worker code + charts. `helm/workflows` →
  `helm-charts-workflows` and `helm/segment-connectivity` → `helm-charts-segment-lifecycle`
  (both Argo-managed, deleted from this repo after extraction). `helm/mock-segment-connectivity`
  **stays here** — it's the only chart still Helmfile-pulled (`git::`), a test-only
  stand-in for the real "next" firewall service `segment-lifecycle` talks to (e2e/test
  environments only, never alongside a production `segment-lifecycle` release).

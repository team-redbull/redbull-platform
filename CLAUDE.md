# redbull-platform — context for future sessions

CD is **split in two**: a **Helmfile bootstrap layer** (this repo's
`helmfile.yaml.gotmpl` + `charts/`) plus an **Argo CD service layer** (this repo's
`gitops/`). See `README.md` for the release table, usage, and configuration. This
file covers the non-obvious *why* behind the current shape, so it doesn't get
re-litigated or accidentally reverted.

**One repo, one environment.** Every Argo-managed chart lives here under
`gitops/charts/<service>/`, and that chart's own `values.yaml` is the entire
configuration of the service — there is no per-environment values layer and no second
`$values` source. The air-gapped deployment is NOT modelled as a second environment: it
runs its own Argo architecture over its own mirror of this repo. Do not reintroduce an
`<env>` path segment to serve it.

## The CD split: Helmfile bootstrap + Argo CD service layer

**Helmfile** (`helmfile.yaml.gotmpl`) owns only the **bootstrap + order-sensitive**
layer: `namespaces`, `htpasswd-idp` (local-shell postsync hook, see below),
`crossplane` → `provider-http` → `provider-http-config` (the one genuinely hard
CRD-before-CR ordering), plus the still-Helmfile-managed `segments-manager-mongodb`
and `mock-segment-connectivity`, and the not-yet-migrated `bmh-generator-operator`,
`server-scanner-dashboard`, `hosted-cluster-integration`. Argo CD is **already
installed** (OpenShift GitOps, namespace `openshift-gitops`) — this platform does not
deploy it.

**Argo CD** owns the stateless service layer via **one generic ApplicationSet**
(`gitops/appset.yaml`) over `gitops/services/<service>/app.yaml`: `temporal`,
`segments-manager`, `workflows-orchestrator`, `segment-lifecycle-worker`,
`workflows-docs`, `dhcp-scope-manager`, `rhokp`. Each service's chart is a folder in
**this** repo at `gitops/charts/<service>/` — the sole, hand-edited copy; the code repos
no longer carry a `helm/` chart folder (except `workflows` keeps
`helm/mock-segment-connectivity`), and neither do the retired `helm-charts-*` repos.

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

Removing a `gitops/services/<service>/` folder makes the git generator stop
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
bit (and which the single-source layout has since defused for the common case).

So `gitops/appset.yaml` now declares the finalizer **explicitly** in
`template.metadata`. **Do not remove it** because "Argo adds it anyway" — that is only
true on new enough controllers, and the failure mode is silent. Equally, do not set
`spec.syncPolicy.preserveResourcesOnDeletion: true`, which suppresses the same cascade.

### Deleting a service: safe now, but only in the right order

Historically, deleting a `gitops/services/<env>/<service>/` folder in a single commit hung
the Application in `Unknown`/`Progressing` forever with its finalizer set, and **nothing
was deleted from the cluster** (observed on the air-gapped env, 2026-07-28, deleting
`temporal`). The cause was the appset's multi-source design: every Application rendered
from the chart repo *plus* this repo as `$values`, with a valueFile at
`$values/gitops/services/<env>/<service>/values.yaml`. So `app.yaml` (what the generator
watches) and `values.yaml` (what the app renders from) sat in the **same folder**, and one
commit removed both. Then:

1. the generator stops emitting the service → the ApplicationSet deletes the Application;
2. `resources-finalizer.argocd.argoproj.io` blocks removal until the cascade runs;
3. the cascade needs a successful reconcile, which needs a successful **manifest render**;
4. rendering now fails — `values file $values/… does not exist` — so no resource tree is
   ever computed, nothing is deleted, and the finalizer holds the app forever.

Deleting the service broke the very thing that made deleting it possible. The finalizer
was not missing, it was *stuck* — which reads exactly like "the finalizer didn't work",
and sends you chasing the wrong bug.

**The single-source layout removes this for the common case.** An Application now renders
from one source, `gitops/charts/<service>`, and nothing it renders lives in the folder the
generator watches. So:

- **Retiring a service is ONE commit**: `git rm -r gitops/services/<service>/`. The
  Application is deleted, the chart it renders from still exists, the cascade computes the
  resource tree and the workloads are deleted properly.
- **Deleting the chart too takes TWO commits.** `git rm -r gitops/charts/<service>/` in the
  same commit puts you straight back in the deadlock above — the render fails with `app
  path does not exist` instead of a missing values file, and the finalizer hangs exactly
  the same way. Delete the service folder first, wait for the Application to be **gone**,
  then delete the chart folder.
- The same applies to a declared override: if a service references
  `gitops/overrides/<file>.yaml`, that file must outlive its Application too. This is why
  override files live in `gitops/overrides/` and never inside `gitops/services/<service>/`.

**Why not `helm.ignoreMissingValueFiles: true`** (the tempting one-line fix, and still not
enabled): it does work for deletion — verified live, folder removed in one commit, app and
resources both cleanly deleted. But it cannot distinguish "folder deleted on purpose" from
"values file missing by mistake", and `syncPolicy.automated` here is `prune: true,
selfHeal: true`. Verified live on the same harness: with the flag on, deleting **only**
`values.yaml` (keeping `app.yaml`) made the app silently re-render on chart defaults and
auto-apply them to the live cluster in **under 10 seconds**, reporting `Synced/Healthy`
throughout — no error, no warning. For a real service that means chart-default image tags,
replica counts and resource limits landing in prod, plus pruning of anything gated behind a
value. Without the flag that same mistake fails loudly and changes nothing. Don't enable it
without re-deriving this trade.

**Recovering a service already stuck this way:** restore the missing file (the chart
folder, or the override) and push — rendering recovers, the pending cascade completes, and
the resources are deleted properly; then delete it again in a follow-up commit. To instead
*keep* the service, clear the finalizer (`kubectl patch app <name> -n <ns> --type=merge -p
'{"metadata":{"finalizers":null}}'`), which drops the Application but leaves the workloads
running, then restore the folder in git — the recreated Application **adopts** the live
resources, because tracking is by the `app.kubernetes.io/instance` label they already
carry. No downtime, PVCs preserved.

Note the finalizer fix only affects deletions from *now on*. Resources already orphaned
stay orphaned: Argo no longer tracks them, so they must be cleaned up by hand (they still
carry `app.kubernetes.io/instance=<app>` / the `argocd.argoproj.io/tracking-id` annotation,
which is how you find them). Re-adding the service folder does **not** adopt them cleanly
either — the new Application collides with the live objects.

### Migrating an EXISTING installation to this layout needs a temporary guard

This does not apply to a fresh cluster (the GitHub-side cluster was empty when the
layout landed, so no guard was used there). It matters for the air-gapped environment,
which still runs the previous env-scoped ApplicationSet.

The hazard: the old generator is `gitops/services/*/*/app.yaml`, one level deeper than
the new folders, so it matches nothing once the old folders leave `main`. **A generator
emitting zero services is exactly what makes the controller delete every Application it
owns** — and the finalizer cascade for those deletions needs a render from files the same
commit removed, so they hang instead, which is the 2026-07-28 failure mode again.

Procedure:

1. Patch the **live, old** ApplicationSet first, so the window is protected regardless of
   which side lands next:
   `oc patch appset redbull-services -n <argo-ns> --type=merge -p
   '{"spec":{"syncPolicy":{"applicationsSync":"create-update"}}}'`
   `create-update` withholds the *delete* verb from the controller. It is NOT
   `preserveResourcesOnDeletion` (which CLAUDE.md forbids): that one keeps the workloads
   when an Application *is* deleted; this one prevents the deletion itself.
2. **Verify it is actually honoured.** The per-appset field only applies when the
   controller allows policy override — `--enable-policy-override` defaults to true only
   if no `--policy` flag is set. Check the controller's args/env
   (`--policy`, `--enable-policy-override`, `ARGOCD_APPLICATIONSET_CONTROLLER_POLICY`)
   before relying on it; if override is off, use two commits instead (remove the old
   folders only after the new appset is applied and confirmed).
3. Apply the new appset, push the commit, restart the applicationset-controller pod (its
   git generator caches, and a hard-refresh annotation does not bust it).
4. Confirm every app is on the new single `source`, then **remove the guard** — left on,
   deleting a service folder no longer deletes its Application, which is the orphaning
   failure the finalizer exists to prevent.

One wrinkle worth knowing during the window: whether the old generator matches nothing at
all, or briefly matches the *new* folders, depends on
`ARGOCD_APPLICATIONSET_ENABLE_NEW_GIT_FILE_GLOBBING`. With the legacy globbing (the
default), `*` can cross `/`, so the old pattern may still match and produce apps pointing
at a chart path that isn't on `main` yet — a ComparisonError, not a deletion. Either way
nothing is pruned: a failed render blocks sync.

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
(`gitops/charts/temporal`, the combined + renamed successor to `temporal-stack` +
`temporal-postgresql`) **does** bundle Bitnami PostgreSQL as a subchart, safely:

- Postgres subchart → sync-wave `"0"`.
- Schema Job → an **Argo `Sync` hook** at sync-wave `"1"` with
  `hook-delete-policy: BeforeHookCreation`. It must **NOT** carry Helm
  `pre-install`/`pre-upgrade` annotations — Argo maps those to `PreSync`, which runs
  *before* the Postgres subchart, reintroducing the exact original deadlock.
- Temporal server/frontend/UI → sync-wave `"2"`.
- The packaged subchart (`charts/postgresql-*.tgz`) is **committed**, and the root
  `.gitignore`'s global `*.tgz` rule is negated for `gitops/charts/**` to allow it. Argo
  renders straight from git and cannot pull an OCI dependency at render time — in the
  air-gapped env it has no route to `registry-1.docker.io` at all. Do not "clean up" that
  negation; the chart stops rendering.

This bundling applies **only** to the Argo-managed `temporal` chart. `segments-manager`
+ `segments-manager-mongodb` stay split (Mongo is a separate Helmfile release). Don't
"unify" them by analogy without re-deriving — the two live under different tools.

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
Under Argo they rely entirely on the `namespace:` field in
`gitops/services/<service>/app.yaml`, which requires that namespace to already exist by
the time they sync (the ApplicationSet does not set `CreateNamespace=true` — see below).
`mock-segment-connectivity`, still Helmfile-managed, relies on
`helmDefaults.createNamespace: false` + `needs: [default/namespaces]`.

**Do not add a per-chart Namespace template or `createNamespace` value back
into any workflow chart (`gitops/charts/workflows-orchestrator`,
`gitops/charts/segment-lifecycle-worker`, `gitops/charts/workflows-docs`, or any future
per-domain chart), and do not remove `redbull-workflows` from
`charts/namespaces/values.yaml`**, without re-deriving this conflict first —
every workflow-domain chart shares this one namespace, so its ownership
belongs solely to the `namespaces` release.

Now that the workflow charts are **Argo-managed**, the `namespaces` release is the
**sole** namespace mechanism: it pre-creates `redbull-workflows` and stamps the
`argocd.argoproj.io/managed-by` label. The ApplicationSet deliberately does **NOT** use
`CreateNamespace=true`/`managedNamespaceMetadata`.

Be careful with the reason, because it changed with the target instance:

- The original reason was a hard constraint. This repo used to target `user1-argo`, a
  **namespaced** instance in `user1-argocd`, whose application-controller has no cluster
  RBAC for the cluster-scoped Namespace object — verified live, it gets `forbidden`
  trying to create OR patch one. There, the label was not documentation, it was what
  granted the instance its in-namespace RBAC at all.
- The current target, `openshift-gitops`, is the operator's **default, CLUSTER-scoped**
  instance (its application-controller holds a ClusterRoleBinding). It *could* create
  namespaces, and the `managed-by` label is a no-op for it.

The setting stays off anyway, for reasons that outlive the instance choice: the
`namespaces` release runs in the bootstrap of *every* environment (it builds namespaces
from a static list, independent of whether the DBs/mock are deployed there — so even the
air-gapped "external DBs" case has its namespaces pre-created), and one owner per
namespace means it is never a race between two tools. The label is likewise kept, so the
repo still works unchanged in an environment running a namespaced instance. The charts
themselves template **no** Namespace.

**If you do want Argo to create namespaces itself** (an env without the namespaces
release), re-add `CreateNamespace=true` — and if that env runs a *namespaced* instance,
grant its application-controller SA a ClusterRole for `namespaces` create/patch first, at
the cost of that instance's isolation.

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

## Charts live in this repo (`gitops/charts/`), not in a `helm-charts` group

Every Argo-managed service's chart is a folder here, at `gitops/charts/<service>/`, with
the chart at the folder root. The ApplicationSet derives the path from the service folder
name — there is no chart repo to name, pin, or credential.

This replaced a `helm-charts` git group where each chart had **its own repo**
(`helm-charts-<name>`, chart at repo root, pinned per-app by a `revision:` branch). That
shape cost a repo, a cross-repo PAT write and a second review surface per service, and it
did not scale past the seven services it reached. Those repos still exist and still hold
the history; they are no longer read by anything here.

What the consolidation bought, beyond the obvious:

- **The chart and the Application that deploys it move in one commit**, rendered from one
  revision. The whole class of "the appset points at a chart revision that doesn't have
  this value yet" is gone.
- **One source per Application.** The `$values` second source is gone, and with it the
  deletion deadlock in its common form (see the deletion section above).
- **No per-service chart branches.** `revision:` is gone from `app.yaml`; deploying a
  version means merging to `main` here. A *branch* build of a service is a hand-edit of
  the image tag in its chart values, because CI only bumps the chart on `main`.

What it costs, and where the sharp edges moved to:

- **CI writes into this repo.** The shared `ghcr-build-push.yml` cross-commits image bumps
  with the `REDBULL_WRITE_TOKEN` PAT (the default `GITHUB_TOKEN` can't write to another
  repo) — the target is now `team-redbull/redbull-platform` +
  `gitops/charts/<service>/values.yaml`. Because that repo is shared, the workflow
  namespaces its version tags per chart (`<chart>/vX.Y.Z`), scopes its commit to the chart
  directory instead of `git add -A`, and retries its push with `pull --rebase` — every
  service now pushes to the same branch. Removing any of those three reintroduces a
  collision, not a merge conflict you'd notice.
- **Every commit here re-renders every app.** Harmless (Argo applies nothing when the
  manifests are unchanged), but it does mean a docs commit shows up as a reconcile.

The air-gapped GitLab now differs only by the **host** — the charts travel with the repo,
so there is no flat-vs-subgroup naming translation left. Change the two `repoURL`s in
`gitops/appset.yaml` and `sourceRepos` in `gitops/project.yaml`. See README.

## Related repos

- `team-redbull/helm-charts-*` — the seven **retired** chart repos (`-temporal`,
  `-segments-manager`, `-workflows-orchestrator`, `-workflows-docs`,
  `-segment-lifecycle-worker`, `-dhcp-scope-manager`, `-rhokp`). Their contents were
  vendored into `gitops/charts/` and they are no longer referenced. Archive them once the
  cutover is confirmed — but check first that nothing outside this repo still points at
  one. (`helm-charts-hostedclusters-setup` is a different chart, belongs to `gitops-day1`,
  and is NOT part of this consolidation.)
- `team-redbull/temporal-stack` → renamed to `helm-charts-temporal`, now
  `gitops/charts/temporal`. Schema Job hook timing originates here.
- `team-redbull/segment_manager` — original segments-manager chart/source,
  `deploy/helm` path. Still on the old Docker Hub-based build workflow.
- `team-redbull/segments-manager` (also cloned locally at
  `/Users/itayherzberg/Projctes/segments-manager`) — the active service repo. Its chart is
  `gitops/charts/segments-manager` here; `deploy/helm` was deleted from it after
  extraction. The `refactor/segments-manager` branch has merged to its main, which is what
  the vendored chart tracks (image `v0.1.4`).
- `team-redbull/.github` — org-wide reusable workflows repo. Hosts `ghcr-build-push.yml`,
  the canonical build/version/GHCR-push/Helm-bump flow. Its `chart-repo` input +
  `REDBULL_WRITE_TOKEN` now target this repo; see the monorepo caveats above.
  `segments-manager`, `workflows` and `dhcp_scope_manager` call it. Other service repos
  (`segment_manager`, `BareMetalHostUCS`, `ServerScanner`) still have inline copies.
- `team-redbull/workflows` — Temporal worker code. Its three Argo charts are
  `gitops/charts/workflows-orchestrator`, `gitops/charts/segment-lifecycle-worker` and
  `gitops/charts/workflows-docs`. `helm/mock-segment-connectivity` **stays in that repo**
  — it's the only chart still Helmfile-pulled (`git::`), a test-only stand-in for the real
  "next" firewall service `segment-lifecycle-worker` talks to (e2e/test environments only,
  never alongside a production `segment-lifecycle-worker` release).
- `team-redbull/dhcp_scope_manager` — the DHCP scope API's code repo; its chart is
  `gitops/charts/dhcp-scope-manager`. Note that chart carries a `dhcp-api-token` subchart
  whose committed token is also consumed **outside** this platform (per-MCE standalone
  deploys, and `helm-charts-hostedclusters-setup`'s `dhcp_api.tokenSecretRef`) — see
  `gitops/SECRETS.md`; its path moved with the chart.

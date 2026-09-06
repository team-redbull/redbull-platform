# redbull-platform

CD is **split in two**:

- **Helmfile bootstrap layer** ([helmfile.yaml.gotmpl](helmfile.yaml.gotmpl) + `charts/`) —
  the cluster-scoped, order-sensitive releases + the databases, deployed with
  [Helmfile](https://helmfile.readthedocs.io/).
- **Argo CD service layer** ([gitops/](gitops/)) — the stateless services, deployed
  pull-based by **one generic ApplicationSet** ([gitops/appset.yaml](gitops/appset.yaml))
  over per-service config files, each pointing at a chart **in this repo** under
  [gitops/charts/](gitops/charts/).

There is **one environment**. The air-gapped deployment runs its own Argo architecture on
its own mirror of this repo; it is not modelled here as a second env.

Argo CD is assumed **already installed** (OpenShift GitOps, namespace `user1-argocd`).
See [gitops/README](gitops/) and `CLAUDE.md §"The CD split"` for the why.

## What Helmfile deploys (bootstrap)

Service charts are pulled **dynamically from their own repos at sync time**
(Helmfile `git::` refs). Nothing is vendored here except three small platform-owned
glue charts under `charts/` (`namespaces`, `htpasswd-idp`, `provider-http`) plus the
two database wrappers.

| Release | Namespace | Source | Depends on |
|---|---|---|---|
| `namespaces` | (cluster) | local `charts/namespaces` | — |
| `htpasswd-idp` | `openshift-config` | local `charts/htpasswd-idp` | — |
| `crossplane` | `crossplane-system` | crossplane-stable repo | namespaces |
| `provider-http` | `crossplane-system` | local glue (Provider CR) | crossplane |
| `provider-http-config` | `crossplane-system` | local glue (ProviderConfig `dhcp-http`) | provider-http |
| `segments-manager-mongodb` | `segments-manager` | local `charts/segments-manager-mongodb` (Bitnami MongoDB) | namespaces |
| `mock-segment-connectivity` | `redbull-workflows` | `team-redbull/workflows` (`helm/mock-segment-connectivity`) | namespaces |
| `bmh-generator-operator` | `bmh-system` | `team-redbull/BareMetalHostUCS` | namespaces |
| `server-scanner-dashboard` | `server-scanner` | `team-redbull/ServerScanner` | namespaces |
| `hosted-cluster-integration` | `crossplane-system` | `team-redbull/dhcp_scope_manager` (`helm`) | provider-http-config |

## What Argo CD deploys (services)

One `Application` per row, generated from `gitops/services/<service>/app.yaml` by the
`redbull-services` ApplicationSet. Each chart lives in **this** repo at
`gitops/charts/<service>/`, and that chart's own `values.yaml` is the whole configuration
— the ApplicationSet passes no value files.

| App | Namespace | Chart | Notes |
|---|---|---|---|
| `temporal` | `temporal` | `gitops/charts/temporal` | **combined** temporal-stack + PostgreSQL subchart (sync waves) |
| `segments-manager` | `segments-manager` | `gitops/charts/segments-manager` | uses the Helmfile-managed `segments-manager-mongodb` |
| `workflows-orchestrator` | `redbull-workflows` | `gitops/charts/workflows-orchestrator` | the shared workflow "brain"; owns `workflows-orchestrator-config` |
| `segment-lifecycle-worker` | `redbull-workflows` | `gitops/charts/segment-lifecycle-worker` | the segment-lifecycle domain's activity limb; `nextUrl` → `mock-segment-connectivity` |
| `workflows-docs` | `redbull-workflows` | `gitops/charts/workflows-docs` | static docs site for the workflow layer; depends on nothing |
| `dhcp-scope-manager` | `dhcp-scope-manager` | `gitops/charts/dhcp-scope-manager` | Linux API driving a remote Windows DHCP server over PSRP/WinRM |
| `rhokp` | `rhokp` | `gitops/charts/rhokp` | Red Hat Offline Knowledge Portal; ships with placeholder registry/access-key secrets — see its `values.yaml` TODO |

The app name, the chart path and the Helm release name are all the folder name, so a
service's resources are named the same in every cluster.

Cross-app ordering is **not** enforced (soft deps self-heal via `retry`/`selfHeal`); the
only ordering is intra-chart in `temporal` (Postgres → schema → server, via sync waves).

`htpasswd-idp` provisions a bootstrap cluster login (`ocpadmin`, cluster-admin)
on whatever OpenShift cluster this platform deploys onto. It templates no
Kubernetes resources itself — a postsync hook merges the configured users
into whichever HTPasswd identity provider already exists on the cluster (the
normal case; most clusters are bootstrapped with one out of band), so the
login screen keeps a single htpasswd option and any pre-existing users are
preserved. It only creates a brand-new provider + Secret as a fallback, on a
cluster with no HTPasswd provider at all. It has no `needs:` of its own but the
Argo-managed `temporal` app's Temporal UI oauth-proxy only admits the users in
`ui.auth.allowedUsers` (`gitops/charts/temporal/values.yaml`, kept in sync with
`htpasswdIdp.clusterAdmins`), so the grant must land before that UI is reachable. See
`CLAUDE.md`.

`workflows-orchestrator` (Argo app) is the Temporal workflow-brain — ONE shared release
for every workflow domain, not per-domain. `segment-lifecycle-worker` (Argo app) is the
first per-domain activity-worker limb; future domains add their own
`gitops/charts/<domain>-worker/` chart + a `gitops/services/<domain>-worker/` folder, all
still consuming the one orchestrator. `mock-segment-connectivity` (**Helmfile**) is a
test-only stand-in for the real "next" (firewall) service `segment-lifecycle-worker` talks
to — it lets e2e tests run the full submit -> poll -> complete cycle without the real,
air-gapped next service; never install it alongside a production
`segment-lifecycle-worker` (repoint `config.nextUrl` in that chart's values at the real
next endpoint first). None of the charts creates its own namespace — see `CLAUDE.md`.

**Ordering** — Helmfile `needs:` still sequences the bootstrap layer (Crossplane first,
then the `provider-http` package, then a `presync` `kubectl wait` gates the
`ProviderConfig` on the provider being `Healthy`). The Argo service layer has **no**
cross-app ordering — soft deps self-heal via `retry`/`selfHeal`, and the only real
ordering (Postgres → schema → server) is intra-chart in `temporal` via sync waves.

## GitOps (Argo CD service layer)

Everything under [gitops/](gitops/):

- [gitops/appset.yaml](gitops/appset.yaml) — the one generic ApplicationSet (git *files*
  generator over `gitops/services/*/app.yaml`).
- [gitops/project.yaml](gitops/project.yaml) — the `redbull-platform` AppProject.
- `gitops/charts/<service>/` — **the service's Helm chart, and its `values.yaml` is the
  single source of truth for how that service is configured.**
- `gitops/services/<service>/app.yaml` — Argo config: `namespace`, plus the optional
  `valueFiles`, `destination` and `overrides` keys. The folder name is the app name, the
  chart path and the release name.
- [gitops/overrides/](gitops/overrides/) — the escape hatch for a per-cluster/per-site
  value override. **Empty today**, and nothing references it; see its README for why the
  files live there and not next to `app.yaml`.
- [gitops/SECRETS.md](gitops/SECRETS.md) — the (not-yet-wired) ESO + Vault plan.

There is no per-environment values layer and no second `$values` source: an Application
renders from exactly one source, this repo, at `gitops/charts/<service>`.

**Bring-up** (Argo CD already installed in `user1-argocd`):

```sh
# one-time: register a repo credential for this repo
#   (a Secret labeled argocd.argoproj.io/secret-type: repo-creds, URL prefix
#    https://github.com/team-redbull/, in namespace user1-argocd)
oc apply -f gitops/project.yaml
oc apply -f gitops/appset.yaml
oc get applications -n user1-argocd
```

**Add a service:** add `gitops/charts/<name>/` (the chart) and
`gitops/services/<name>/app.yaml` (one line: `namespace:`). The ApplicationSet picks it
up. No ApplicationSet edit.

**Remove a service:** delete `gitops/services/<name>/` — one commit is enough, because
the chart it renders from still exists, so the finalizer cascade can compute the resource
tree and delete the workloads properly. Delete `gitops/charts/<name>/` only in a **later**
commit, once the Application is gone; removing both at once fails the render and hangs
the deletion (see `CLAUDE.md`).

**Migrating an existing installation** that still runs the old env-scoped ApplicationSet
(i.e. the air-gapped environment) is not a plain `oc apply` — the old generator matches
nothing under the new layout, which makes the controller delete every Application it owns.
See `CLAUDE.md` for the guarded procedure.

### Air-gapped GitLab: the git host

The only thing that changes when this repo is mirrored to the air-gapped GitLab is the
git **host**. There is no longer a per-chart repo naming convention to translate — the
charts are folders in this repo, so they travel with it. Edit the two `repoURL`s in
`gitops/appset.yaml` (the generator's and the source's) and `sourceRepos` in
`gitops/project.yaml`:

```yaml
# GitHub (today):        https://github.com/team-redbull/redbull-platform.git
# GitLab (air-gapped):   https://gitlab.airgap.local/redbull/redbull-platform.git
```

**If your internal mirror also drops the `gitops/` top-level folder** (e.g. a leaner
layout with `services/`, `charts/`, `project.yaml`, `appset.yaml` at repo root) — this is
a *further* deviation beyond the host-only change, and needs three more edits in
`gitops/appset.yaml`, which must stay consistent with each other:

- the git generator's `files: path:` pattern,
- the source's `path:` (`gitops/charts/{{ .path.basename }}`),
- the `../../../` prefix in `templatePatch` — it is the depth of the chart folder from
  the repo root, so a flattened `charts/<service>` needs `../../` instead.

`.path.basename` is unaffected (always the last path segment). Track this as a local
divergence in your fork so a future sync from the canonical repo doesn't reintroduce a
mismatch.

### Overriding a value for one cluster or site (`valueFiles`)

The chart's `values.yaml` is the configuration; nothing is layered on top of it by
default. For the case that genuinely varies **per cluster or per site** — the air-gapped
deployments onto a specific MCE or hosted cluster — put the override in
`gitops/overrides/` and reference it from that service's `app.yaml`, repo-root relative:

```yaml
# gitops/services/segments-manager/app.yaml
namespace: segments-manager
valueFiles:
  - gitops/overrides/segments-manager.yaml
```

Files are applied in the order listed, after the chart's own `values.yaml`, so the last
one wins. The ApplicationSet rewrites each path to be chart-relative; no ApplicationSet
edit is needed to use this. An absent `valueFiles` (every service today) adds nothing.

Override files live in `gitops/overrides/` and **not** in `gitops/services/<service>/`
on purpose: a value file inside the folder the generator watches is removed by the very
commit that retires the service, which breaks the render the deletion cascade depends on
and hangs the Application forever. See [gitops/overrides/README.md](gitops/overrides/).

A chart may also ship extra value files of its own next to its `values.yaml` (e.g. an
air-gapped image-registry overlay). Reference those the same way, by their path in this
repo: `gitops/charts/temporal/values-airgapped.yaml`.

### Sourcing a chart from outside this repo (`overrides`)

`overrides:` in a service's `app.yaml` is deep-merged onto the generated Application
last, so it can set anything — including replacing the source outright for the rare chart
that cannot live here:

```yaml
# gitops/services/<service>/app.yaml
namespace: some-namespace
overrides:
  spec:
    source:
      repoURL: https://github.com/some-other-org/some-other-repo.git
      targetRevision: main
      path: .
```

It is also how a service targets a different cluster (`spec.destination`), though the
dedicated `destination:` key is the shorter route for that.

## Prerequisites

- `helm` 3.x, `helmfile` 1.x, and the `helm-diff` plugin
  (`helm plugin install https://github.com/databus23/helm-diff`)
- `kubectl`/`oc` logged into the target cluster (the hooks use `kubectl wait`)

All `ghcr.io/team-redbull/*` images are public, so no pull secret or GHCR
credentials are needed to sync this platform.

## Usage

```sh
helmfile deps          # resolve repos
helmfile template      # render everything locally (no cluster needed)
helmfile diff          # preview changes against the cluster
helmfile sync          # install/upgrade everything, in order
helmfile destroy       # tear it all down
```

Target a different environment (see `environments/`):

```sh
helmfile -e prod sync
```

## Installing specific services only

Use Helmfile's `-l` / `--selector` to act on a subset of releases. Every release
can be selected by its built-in `name` or `namespace` labels — no chart changes
needed. The same selector works with `template`, `diff`, `sync`, and `destroy`.

```sh
# One release
helmfile -l name=crossplane sync
helmfile -l name=segments-manager-mongodb sync

# Several at once (repeat -l = OR)
helmfile -l name=crossplane -l name=provider-http sync

# Everything in a namespace
helmfile -l namespace=crossplane-system sync
```

Helmfile release names (bootstrap layer): `namespaces`, `htpasswd-idp`, `crossplane`,
`provider-http`, `provider-http-config`, `segments-manager-mongodb`,
`mock-segment-connectivity`, `bmh-generator-operator`, `server-scanner-dashboard`,
`hosted-cluster-integration`. (`temporal`, `segments-manager`, `workflows-orchestrator`,
`segment-lifecycle-worker`, `workflows-docs`, `dhcp-scope-manager` and `rhokp` are Argo CD
apps now — select them with `argocd app`/`kubectl get applications -n user1-argocd`, not
`helmfile -l`.)

> **Dependencies aren't pulled in automatically.** With a selector, Helmfile acts
> on *only* the matched releases and skips their `needs:`. So `helmfile -l
> name=provider-http sync` will fail if `crossplane` isn't already installed. Add
> `--include-needs` to also install everything a selection depends on, in order:
>
> ```sh
> helmfile -l name=provider-http-config --include-needs sync   # also brings up crossplane + provider-http
> ```

Recommended first-time bring-up of the Crossplane layer, one step at a time:

```sh
helmfile -l name=namespaces sync
helmfile -l name=crossplane sync
helmfile -l name=provider-http sync
helmfile -l name=provider-http-config sync
```

Tip: to make custom groupings (e.g. all apps vs. the platform layer), add a
`labels:` block to releases in `helmfile.yaml.gotmpl` and select on it, e.g.
`labels: { tier: platform }` → `helmfile -l tier=platform sync`.

## Configuration

**Bootstrap tunables** live in `environments/default.yaml`:

- **`refs.*`** — the git ref each **Helmfile** chart is pulled from (`workflows` for the
  mock, `dhcp`, `bmh`, `serverScanner`). Defaults to `main`; **pin to tags for prod**.
- **`htpasswdIdp.*`** — `users` merged into the cluster's existing HTPasswd identity
  provider (or a new `bootstrapProviderName`/`bootstrapSecretName` provider on a cluster
  with none), plus `clusterAdmins` to grant. Ships with `ocpadmin`/`Password1` for
  throwaway/sandbox clusters — **override both before anything long-lived.** Also the
  source of truth for the Argo `temporal` app's `ui.auth.allowedUsers` — keep in sync.
- **`segmentsManagerMongodb.{rootPassword,password}`** — credentials for the in-cluster
  MongoDB backing segments-manager. The Argo `segments-manager` app reuses `password` in
  its Mongo URL — see `gitops/charts/segments-manager/values.yaml`, kept in sync by hand.
- **`dhcp.apiUrl`** — backend DHCP API the Crossplane `Request` talks to. **(TODO.)**
- **`providerHttp.*`** — provider-http package image + the shared ProviderConfig name.

**Service tunables** live in each chart's own values file under `gitops/charts/`:

- **`gitops/charts/<service>/values.yaml`** — everything about that service. There is no
  second file layered on top of it, so what you read there is what the cluster runs.
  The ones worth knowing:
  - `gitops/charts/workflows-orchestrator/values.yaml` → `config.temporalHost` /
    `temporalNamespace` / `domain` / `segmentsManagerUrl`. One place to change for the
    whole workflow layer: every limb reads the same facts at runtime from the
    `workflows-orchestrator-config` ConfigMap this chart publishes, so no other chart
    carries a copy.
  - `gitops/charts/segments-manager/values.yaml` → `mongodb.url` (in-cluster Mongo, with
    the password inline — see `SECRETS.md`) and `siteNetworks`.
  - `gitops/charts/segment-lifecycle-worker/values.yaml` → `config.nextUrl` + the URI
    paths, `config.dhcpApiUrl`, the two `secrets.existing*` references, and its own copy
    of `siteNetworks`.
  - `gitops/charts/temporal/values.yaml` → `ui.auth.allowedUsers`.
  - **`siteNetworks` is defined twice on purpose** — segments-manager and
    segment-lifecycle-worker run in different namespaces and cannot share a ConfigMap, so
    each chart renders its own copy. Change both in the same commit.
- **`image.repository`/`image.tag` in those files are CI-owned.** The service's code repo
  commits the bump here on every push to its main. Hand-editing them is transient: the
  next build overwrites the edit.
- **`gitops/services/<service>/app.yaml`** — `namespace`, plus the optional `valueFiles`
  / `destination` / `overrides` keys described above.
- Secrets are still plaintext/out-of-band for now; the ESO+Vault plan is in
  **`gitops/SECRETS.md`**.

### Chart versions move with this repo

An Argo app has no `revision:` any more: the chart is a folder in this repo, so it is
rendered from the same commit as the ApplicationSet that deploys it. **Merging to `main`
here rolls the change out to the cluster.** There is no per-service chart branch to pick,
and no chart-repo tag for Argo to pin.

This is deliberately the *opposite* of the Helmfile-pulled charts above, whose `refs.*`
should still **pin tags** for prod: Helmfile caches a git chart by its mutable branch name
and won't re-fetch on a new commit (the branch-ref staleness this project already hit).
Argo re-renders from this repo on every reconcile, so there is nothing to go stale.

**Image** tags stay immutable and are still the unit of release for the service code
(`vX.Y.Z` on `main`, `<branch-slug>-<sha>` off it). CI commits the new tag into the
chart's `values.yaml` here; deploying a **branch** build is a hand-edit of that value,
because CI only bumps the chart on `main`.

## Air-gapped install

Helmfile still needs to *fetch the charts*, so mirror both **chart sources** and
**images** internally.

1. **Charts** — the Argo service charts travel with this repo (`gitops/charts/`), so
   mirroring the repo is enough for them; only the two `repoURL`s in `gitops/appset.yaml`
   change (see "Air-gapped GitLab" above). The **Helmfile** layer still fetches charts at
   sync time: host those git repos on your internal Git (or push them to an Artifactory
   Helm repo) and repoint the `chart:` refs in `helmfile.yaml.gotmpl` (and the
   `crossplane-stable` repository URL) at the internal mirror.
2. **Images** — each service chart has its own image values; pull/retag/push to
   Artifactory and override per release. The platform-level ones:
   - Crossplane core: set `image.repository` via a `crossplane` release `values:` block.
   - provider-http package: `providerHttp.package` → your Artifactory path, and add
     `providerHttp.packagePullSecrets: [artifactory]`.
   - Service images (temporal, segments-manager, etc.) — see each chart's README under
     `gitops/charts/<service>/` (e.g. `gitops/charts/temporal/README.md` documents its
     full image list and air-gap steps).
3. **Pull secrets** — GHCR images are public, so this platform has no pull-secret
   machinery today. An internal Artifactory mirror is presumably private, so
   you'll need to add your own: create a `kubernetes.io/dockerconfigjson`
   `Secret` per namespace that needs it and reference it via each chart's
   `imagePullSecrets` / `image.pullSecrets`.

## Notes / caveats

- **MongoDB is deployed in-cluster** as its own Helmfile release
  (`segments-manager-mongodb`) rather than bundled, so it's ready before the
  Argo-managed `segments-manager` starts. The Argo-managed `temporal` chart, by
  contrast, **bundles** PostgreSQL as a subchart — safe under Argo because sync waves
  express Postgres → schema → server ordering (no `helmDefaults.wait` deadlock). See
  `CLAUDE.md` for the full story on both.
- **`workflows-orchestrator`, `segment-lifecycle-worker` and `workflows-docs` (Argo apps) all deploy into
  `redbull-workflows`**, pre-created and labeled `argocd.argoproj.io/managed-by:
  user1-argocd` by the `namespaces` release. Neither chart has a Namespace template of
  its own, and the ApplicationSet does **not** use `CreateNamespace=true` — a
  namespaced GitOps instance can't create/patch cluster-scoped Namespaces, so the
  `namespaces` release is the sole mechanism (it runs in every env). See `CLAUDE.md`.
- **OpenShift SCC**: Crossplane and provider-http pods run as nonroot and generally
  work under `restricted-v2`; if a provider pod is denied, grant its service account
  the appropriate SCC.
- `hosted-cluster-integration` renders a DHCP scope `Request` only when the chart's
  `dhcp_values.scopeName` is set (its repo default has a sample scope).
- **CI/CD for service repos**: `team-redbull/.github` hosts a shared reusable
  workflow (`ghcr-build-push.yml`) for building/versioning/pushing images to GHCR
  and bumping the consuming Helm chart's values. `segments-manager`, `workflows` and
  `dhcp_scope_manager` call it; other service repos should be migrated to it too.
  Non-`main` branches get tagged `<branch-slug>-<short-sha>` and **do not touch the
  chart** — deploying a branch build is a hand-edit of `gitops/charts/<svc>/values.yaml`.
- **Image bumps still need the cross-repo PAT (`REDBULL_WRITE_TOKEN`)**: a service's
  chart lives in **this** repo, not in its code repo, so CI must commit the `image.tag`
  bump into *another* repo — which the default `GITHUB_TOKEN` cannot do (repo-scoped; it
  fails with `startup_failure` before any job). The fine-grained PAT with **Contents:
  Read and write**, stored as the **organization** Actions secret `REDBULL_WRITE_TOKEN`
  (the `GITHUB_` prefix is reserved by GitHub), is unchanged — only its target moved from
  the `helm-charts-*` repos to `redbull-platform`. Callers set
  `chart-repo: team-redbull/redbull-platform` and
  `helm-values-path: gitops/charts/<service>/values.yaml`.
- **The chart is now a subdirectory of a shared repo, and the workflow accounts for it**:
  the `vX.Y.Z` sequence is namespaced per chart (tags are `<chart>/vX.Y.Z` in this repo,
  so each service keeps its own counter and they don't collide), the bump commit is
  scoped to the chart directory rather than `git add -A`, and the push retries with
  `pull --rebase` because every service now pushes to the same repo. See
  `team-redbull/.github`.
- **New service repo → Actions doesn't run silently**: GitHub Actions must be
  enabled per-repo (repo Settings → Actions → General), separately from the
  org-wide "Allow all actions and reusable workflows" policy. A repo with
  Actions disabled shows zero workflow runs via the UI *and* the API — no
  error, no failed run, just nothing — which looks identical to a billing/quota
  block. Check `Settings → Actions → General` on the specific repo first.
- **New service repo → `startup_failure` with zero jobs**: once Actions is
  enabled, a repo's default `GITHUB_TOKEN` permissions are `read`-only unless
  changed. `ghcr-build-push.yml` needs `contents: write` + `packages: write`,
  which exceeds that default and gets rejected before any job starts (no logs,
  no job entries — just `startup_failure`). The caller workflow (e.g.
  `segments-manager/.github/workflows/build.yml`) must declare
  `permissions: {contents: write, packages: write}` explicitly rather than
  relying on the repo's default setting.

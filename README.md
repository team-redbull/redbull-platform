# redbull-platform

CD is **split in two**:

- **Helmfile bootstrap layer** ([helmfile.yaml.gotmpl](helmfile.yaml.gotmpl) + `charts/`) —
  the cluster-scoped, order-sensitive releases + the databases, deployed with
  [Helmfile](https://helmfile.readthedocs.io/).
- **Argo CD service layer** ([gitops/](gitops/)) — the stateless services, deployed
  pull-based by **one generic ApplicationSet** ([gitops/appset.yaml](gitops/appset.yaml))
  over per-service config files, each pointing at a chart in the `helm-charts` git group.

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

One `Application` per row, generated from `gitops/services/<env>/<service>/` by the
`redbull-services` ApplicationSet. Charts come from the `helm-charts` group
(`helm-charts-<service>`, chart at repo root, pinned by `revision:` in each `app.yaml`).

| App | Namespace | Chart repo | Notes |
|---|---|---|---|
| `temporal` | `temporal` | `helm-charts-temporal` | **combined** temporal-stack + PostgreSQL subchart (sync waves) |
| `segments-manager` | `segments-manager` | `helm-charts-segments-manager` | uses the Helmfile-managed `segments-manager-mongodb` |
| `workflows` | `redbull-workflows` | `helm-charts-workflows` | the shared workflow "brain"; owns `workflows-config` |
| `segment-connectivity` | `redbull-workflows` | `helm-charts-segment-connectivity` | activity limb; `nextUrl` → `mock-segment-connectivity` in dev |
| `rhokp` | `rhokp` | `helm-charts-rhokp` | Red Hat Offline Knowledge Portal; ships with placeholder registry/access-key secrets — see `values.yaml` TODO |

Cross-app ordering is **not** enforced (soft deps self-heal via `retry`/`selfHeal`); the
only ordering is intra-chart in `temporal` (Postgres → schema → server, via sync waves).
Names are `<env>-<service>` except `prod`, which is unprefixed.

`htpasswd-idp` provisions a bootstrap cluster login (`ocpadmin`, cluster-admin)
on whatever OpenShift cluster this platform deploys onto. It templates no
Kubernetes resources itself — a postsync hook merges the configured users
into whichever HTPasswd identity provider already exists on the cluster (the
normal case; most clusters are bootstrapped with one out of band), so the
login screen keeps a single htpasswd option and any pre-existing users are
preserved. It only creates a brand-new provider + Secret as a fallback, on a
cluster with no HTPasswd provider at all. It has no `needs:` of its own but the
Argo-managed `temporal` app's Temporal UI oauth-proxy only admits the users in
its `ui.auth.allowedUsers` (kept in sync with `htpasswdIdp.clusterAdmins`), so the
grant must land before that UI is reachable. See `CLAUDE.md`.

`workflows` (Argo app) is the Temporal workflow-brain — ONE shared release for every
workflow domain, not per-domain. `segment-connectivity` (Argo app) is the first
per-domain activity-worker limb; future domains add their own `helm-charts-<domain>`
chart + a `gitops/services/<env>/<domain>/` folder, all still consuming the one
`workflows`. `mock-segment-connectivity` (**Helmfile**) is a test-only stand-in for the
real "next" (firewall) service `segment-connectivity` talks to — it lets e2e tests run
the full submit -> poll -> complete cycle without the real, air-gapped next service;
never install it alongside a production `segment-connectivity` (pin that app's `revision`
to a real tag and override `config.nextUrl` at the real next endpoint). None of the
charts creates its own namespace — see `CLAUDE.md`.

**Ordering** — Helmfile `needs:` still sequences the bootstrap layer (Crossplane first,
then the `provider-http` package, then a `presync` `kubectl wait` gates the
`ProviderConfig` on the provider being `Healthy`). The Argo service layer has **no**
cross-app ordering — soft deps self-heal via `retry`/`selfHeal`, and the only real
ordering (Postgres → schema → server) is intra-chart in `temporal` via sync waves.

## GitOps (Argo CD service layer)

Everything under [gitops/](gitops/):

- [gitops/appset.yaml](gitops/appset.yaml) — the one generic ApplicationSet (git *files*
  generator over `gitops/services/*/*/app.yaml`).
- [gitops/project.yaml](gitops/project.yaml) — the `redbull-platform` AppProject.
- `gitops/services/<env>/<service>/app.yaml` — Argo config (`namespace`, `revision`;
  optional `destination`, `overrides`). Service name + chart repo derive from the folder.
- `gitops/services/<env>/<service>/values.yaml` — the service's Helm values.
- `gitops/values/<env>.yaml` — shared globals merged **under** every service's values.
- [gitops/SECRETS.md](gitops/SECRETS.md) — the (not-yet-wired) ESO + Vault plan.

**Bring-up** (Argo CD already installed in `user1-argocd`):

```sh
# one-time: register a repo credential covering the whole team-redbull group
#   (a Secret labeled argocd.argoproj.io/secret-type: repo-creds, URL prefix
#    https://github.com/team-redbull/, in namespace user1-argocd)
oc apply -f gitops/project.yaml
oc apply -f gitops/appset.yaml
oc get applications -n user1-argocd
```

**Add a service:** create `gitops/services/<env>/<name>/{app.yaml,values.yaml}` where
`<name>` matches a `helm-charts-<name>` repo — the ApplicationSet picks it up. No
ApplicationSet edit. **Add an environment:** add a `gitops/services/<env>/` folder + a
`gitops/values/<env>.yaml`.

### Air-gapped GitLab: the chart host

The only thing that changes deploying to the air-gapped GitLab is the git **host/layout**
— GitHub is flat (`helm-charts-<name>`), GitLab uses a real subgroup
(`helm-charts/<name>`). Edit the three `repoURL`s in `gitops/appset.yaml` and
`sourceRepos` in `gitops/project.yaml`:

```yaml
# GitHub (today):        https://github.com/team-redbull/helm-charts-{{ .path.basename }}.git
# GitLab (air-gapped):   https://gitlab.airgap.local/team-redbull/helm-charts/{{ .path.basename }}.git
```

dev and prod share the host, so they remain the **one** ApplicationSet in both.

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
`hosted-cluster-integration`. (The `temporal`, `segments-manager`, `workflows` and
`segment-connectivity` services are Argo CD apps now — select them with
`argocd app`/`kubectl get applications -n user1-argocd`, not `helmfile -l`.)

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
  its Mongo URL — see `gitops/services/<env>/segments-manager/values.yaml`.
- **`dhcp.apiUrl`** — backend DHCP API the Crossplane `Request` talks to. **(TODO.)**
- **`providerHttp.*`** — provider-http package image + the shared ProviderConfig name.

**Service tunables** live under `gitops/`:

- **`gitops/services/<env>/<service>/app.yaml`** — `revision:` (the chart tag to deploy —
  pin to tags), `namespace`, optional `destination`/`overrides`.
- **`gitops/services/<env>/<service>/values.yaml`** — that service's Helm values (e.g.
  segment-connectivity's `config.nextUrl`/URI paths + `secrets.existingSecret`).
- **`gitops/values/<env>.yaml`** — shared globals (the Temporal endpoint + orchestrator
  `domain`/`segmentsManagerUrl`) — one place to change for the whole workflow layer.
- Secrets are still plaintext/out-of-band for now; the ESO+Vault plan is in
  **`gitops/SECRETS.md`**.

## Air-gapped install

Helmfile still needs to *fetch the charts*, so mirror both **chart sources** and
**images** internally.

1. **Charts** — host the chart git repos on your internal Git (or push the charts to
   an Artifactory Helm repo) and repoint `chart:` refs in `helmfile.yaml.gotmpl`
   (and the `crossplane-stable` repository URL) at the internal mirror.
2. **Images** — each service chart has its own image values; pull/retag/push to
   Artifactory and override per release. The platform-level ones:
   - Crossplane core: set `image.repository` via a `crossplane` release `values:` block.
   - provider-http package: `providerHttp.package` → your Artifactory path, and add
     `providerHttp.packagePullSecrets: [artifactory]`.
   - Service images (temporal, segments-manager, etc.) — see each chart's README
     (e.g. `temporal-stack` documents its full image list and air-gap steps).
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
- **`workflows` and `segment-connectivity` (Argo apps) both deploy into
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
  and bumping each repo's Helm chart values. `team-redbull/segments-manager` calls
  it; other service repos should be migrated to it too. Non-`main` branches get tagged
  `<branch-slug>-<short-sha>` instead of bumping the shared `vX.Y.Z` sequence.
- **Chart-repo image bumps need a cross-repo PAT (`REDBULL_WRITE_TOKEN`)**: now that
  each Argo service's chart lives in its **own** `helm-charts-<name>` repo (not the
  service code repo), CI must commit the `image.tag` bump into *another* repo — which
  the default `GITHUB_TOKEN` cannot do (repo-scoped; it fails with `startup_failure`
  before any job). Create a **fine-grained PAT** with **Contents: Read and write** on
  the `helm-charts-*` repos, store it as an **organization** Actions secret named
  `REDBULL_WRITE_TOKEN` (the `GITHUB_` prefix is reserved by GitHub), and pass it to
  `ghcr-build-push.yml` (which checks out the chart repo, bumps `helm-image-path`,
  commits, and tags — the tag a service `app.yaml`'s `revision` pins to).
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

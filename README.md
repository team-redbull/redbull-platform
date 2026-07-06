# redbull-platform

One command deploys **every team-redbull service** — each into its own namespace,
in dependency order — using [Helmfile](https://helmfile.readthedocs.io/).

Service charts are pulled **dynamically from their own repos at sync time**
(Helmfile `git::` refs). Nothing is vendored here except four small platform-owned
glue charts under `charts/` (`namespaces`, `provider-http`, `temporal-postgresql`,
`segments-manager-mongodb`).

## What it deploys

| Release | Namespace | Source | Depends on |
|---|---|---|---|
| `namespaces` | (cluster) | local `charts/namespaces` | — |
| `crossplane` | `crossplane-system` | crossplane-stable repo | namespaces |
| `provider-http` | `crossplane-system` | local glue (Provider CR) | crossplane |
| `provider-http-config` | `crossplane-system` | local glue (ProviderConfig `dhcp-http`) | provider-http |
| `temporal-postgresql` | `temporal` | local `charts/temporal-postgresql` (Bitnami PostgreSQL) | namespaces |
| `temporal-stack` | `temporal` | `team-redbull/temporal-stack` | namespaces, temporal-postgresql |
| `segments-manager-mongodb` | `segments-manager` | local `charts/segments-manager-mongodb` (Bitnami MongoDB) | namespaces |
| `segments-manager` | `segments-manager` | `team-redbull/segment_manager` (`deploy/helm`) | namespaces, segments-manager-mongodb |
| `segment-allocation` | `segment-allocation`¹ | `team-redbull/workflows` (`helm/segment-allocation`) | temporal-stack, segments-manager |
| `bmh-generator-operator` | `bmh-system` | `team-redbull/BareMetalHostUCS` | namespaces |
| `server-scanner-dashboard` | `server-scanner` | `team-redbull/ServerScanner` | namespaces |
| `hosted-cluster-integration` | `crossplane-system` | `team-redbull/dhcp_scope_manager` (`helm`) | provider-http-config |

¹ The `workflows` chart creates and owns the `segment-allocation` namespace itself, so
that release's *record* lives in `redbull-platform` to avoid a Helm namespace-ownership clash.

**Ordering** is enforced with Helmfile `needs:`. Crossplane installs first; the
`provider-http` Provider package installs next; a `presync` hook waits for the
provider to be `Healthy` before its `ProviderConfig` (and the dhcp `Request` CRs
that reference it) are applied.

## Prerequisites

- `helm` 3.x, `helmfile` 1.x, and the `helm-diff` plugin
  (`helm plugin install https://github.com/databus23/helm-diff`)
- `kubectl`/`oc` logged into the target cluster (the hooks use `kubectl wait`)
- A **GitHub personal access token** with `read:packages` scope, so Kubernetes can
  pull the private `ghcr.io/team-redbull/*` images. Each developer creates their
  own — nothing shared, nothing committed to git:

  1. https://github.com/settings/tokens → **Generate new token (classic)** → check
     `read:packages` → generate, copy it (shown once).
  2. Export it in the shell you run `helmfile` from (e.g. add to `~/.zshrc`):

     ```sh
     export GHCR_USER="your-github-username"
     export GHCR_TOKEN="ghp_xxxxxxxxxxxx"
     ```

  `helmfile sync` reads these each run and (re)creates the `ghcr-pull-secret` in
  `segments-manager`, so it survives a namespace/cluster rebuild without any
  manual `kubectl create secret` step. Missing either var fails the sync with a
  clear "requiredEnv" error rather than a silent bad deploy.

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
helmfile -l name=temporal-stack sync

# Several at once (repeat -l = OR)
helmfile -l name=crossplane -l name=provider-http sync

# Everything in a namespace
helmfile -l namespace=crossplane-system sync
```

Release names: `namespaces`, `crossplane`, `provider-http`, `provider-http-config`,
`temporal-postgresql`, `temporal-stack`, `segments-manager-mongodb`, `segments-manager`,
`segment-allocation`, `bmh-generator-operator`, `server-scanner-dashboard`,
`hosted-cluster-integration`.

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

All tunables live in `environments/default.yaml`:

- **`refs.*`** — the git ref each service chart is pulled from. Defaults to `main`;
  **pin to tags for production** (e.g. `temporalStack: v0.1.0`).
- **`temporalPostgresql.password`** — password for the in-cluster PostgreSQL
  backing Temporal (`charts/temporal-postgresql`).
- **`segmentsManagerMongodb.{rootPassword,password}`** — credentials for the
  in-cluster MongoDB backing segments-manager (`charts/segments-manager-mongodb`).
- **`segmentAllocation.*`** — wiring of the Temporal workers to the in-cluster
  Temporal frontend and segments-manager service (pre-filled with cluster DNS).
- **`dhcp.apiUrl`** — backend DHCP API the Crossplane `Request` talks to.
  **(TODO: set real endpoint.)**
- **`providerHttp.*`** — provider-http package image + the shared ProviderConfig name.

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
3. **Pull secrets** — `charts/namespaces` already creates `ghcr-pull-secret` in
   `segments-manager` from `GHCR_USER`/`GHCR_TOKEN` (see Prerequisites above).
   For other namespaces/registries, add entries the same way and reference them
   via each chart's `imagePullSecrets` / `image.pullSecrets`.

## Notes / caveats

- **PostgreSQL and MongoDB are deployed in-cluster** as their own releases
  (`temporal-postgresql`, `segments-manager-mongodb`) rather than bundled as
  subcharts, so they exist and are ready before `temporal-stack`'s pre-install
  schema job and `segments-manager` start. See `needs:` in `helmfile.yaml.gotmpl`,
  and `CLAUDE.md` for the full story on why this shape was necessary.
- **OpenShift SCC**: Crossplane and provider-http pods run as nonroot and generally
  work under `restricted-v2`; if a provider pod is denied, grant its service account
  the appropriate SCC.
- `hosted-cluster-integration` renders a DHCP scope `Request` only when the chart's
  `dhcp_values.scopeName` is set (its repo default has a sample scope).
- **CI/CD for service repos**: `team-redbull/.github` hosts a shared reusable
  workflow (`ghcr-build-push.yml`) for building/versioning/pushing images to GHCR
  and bumping each repo's Helm chart values. `team-redbull/segments-manager` calls
  it; other service repos should be migrated to it too rather than keeping their
  own copy of the build flow.

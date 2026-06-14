# redbull-platform

One command deploys **every team-redbull service** — each into its own namespace,
in dependency order — using [Helmfile](https://helmfile.readthedocs.io/).

Service charts are pulled **dynamically from their own repos at sync time**
(Helmfile `git::` refs). Nothing is vendored here except two small platform-owned
glue charts under `charts/` (`namespaces`, `provider-http`).

## What it deploys

| Release | Namespace | Source | Depends on |
|---|---|---|---|
| `namespaces` | (cluster) | local `charts/namespaces` | — |
| `crossplane` | `crossplane-system` | crossplane-stable repo | namespaces |
| `provider-http` | `crossplane-system` | local glue (Provider CR) | crossplane |
| `provider-http-config` | `crossplane-system` | local glue (ProviderConfig `dhcp-http`) | provider-http |
| `temporal-stack` | `temporal` | `team-redbull/temporal-stack` | namespaces |
| `segments-manager` | `segments-manager` | `team-redbull/segment_manager` (`deploy/helm`) | namespaces |
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

## Configuration

All tunables live in `environments/default.yaml`:

- **`refs.*`** — the git ref each service chart is pulled from. Defaults to `main`;
  **pin to tags for production** (e.g. `temporalStack: v0.1.0`).
- **`segmentsManager.mongodbUrl`** — segments-manager needs an external MongoDB.
  **(TODO: set to your real instance.)**
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
3. **Pull secrets** — create a docker-registry secret in each namespace and reference
   it via each chart's `imagePullSecrets`.

## Notes / caveats

- **MongoDB** is *not* deployed — `segments-manager` expects an external instance.
- **OpenShift SCC**: Crossplane and provider-http pods run as nonroot and generally
  work under `restricted-v2`; if a provider pod is denied, grant its service account
  the appropriate SCC.
- `hosted-cluster-integration` renders a DHCP scope `Request` only when the chart's
  `dhcp_values.scopeName` is set (its repo default has a sample scope).

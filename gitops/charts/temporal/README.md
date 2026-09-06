# temporal-stack

> This chart is deployed by the `redbull-services` ApplicationSet from this repo
> (`gitops/services/temporal/app.yaml`). Its `values.yaml` here is the single source of
> truth for the running configuration — no other values file is layered on top.


A self-contained Helm chart that deploys a **production-style Temporal cluster** on
OpenShift, with a bundled PostgreSQL and the Temporal Web UI. Everything lives in a
single namespace; the only cluster-scoped objects are the ClusterRole/Binding
created when `ui.auth.allowedGroups` is set (Groups are cluster-scoped).

## What it deploys

| Component   | Detail |
|-------------|--------|
| PostgreSQL  | Bitnami subchart (`postgresql`), persistent volume, SQL visibility store |
| Temporal    | Split services — `frontend`, `history`, `matching`, `worker` (2 replicas each) |
| Schema      | Job (Argo CD Sync hook, wave 1 — after postgres, before the servers): creates `temporal` + `temporal_visibility` DBs & schemas |
| Setup       | Job (Helm post-install/upgrade hook → Argo PostSync): registers the `default` namespace + search attributes |
| Hardening   | Dedicated ServiceAccounts (no API token on server pods), PodDisruptionBudgets per role, optional NetworkPolicies (`networkPolicy.enabled`) |
| Web UI      | `temporalio/ui` Deployment + Service + OpenShift **Route** (edge TLS; optional OpenShift OAuth login — see below) |

Service topology and the `cluster_membership`-table based ringpop discovery mean the
server pods find each other by pod IP — no headless service required.

## Prerequisites

- OpenShift 4.x (tested on 4.18) with a default `StorageClass`
- `helm` 3.8+ (OCI support) and `oc`
- Outbound pull access to `docker.io` and `quay.io`

## Install

```sh
helm dependency build .
oc new-project temporal
helm install temporal . -n temporal
```

Watch it come up:

```sh
oc get pods -n temporal -w
```

Open the UI:

```sh
oc get route temporal-ui -n temporal -o jsonpath='https://{.spec.host}{"\n"}'
```

Connect a Temporal client (in-cluster, gRPC):

```
temporal-frontend.temporal.svc.cluster.local:7233
```

## OpenShift login for the Web UI (`ui.auth`)

By default the UI Route is wide open. Setting `ui.auth.enabled=true` puts an
[`oauth-proxy`](https://github.com/openshift/oauth-proxy) sidecar in front of
it: browsers are sent to the cluster's OAuth login page and come back as their
existing OpenShift user — the same experience as ArgoCD's "log in with
OpenShift". No identity provider to deploy, no `OAuthClient` object: the UI's
ServiceAccount is annotated as an OAuth client whose redirect URI is derived
from the Route, and the sidecar's TLS cert is minted/rotated by the service-ca
operator. The Route switches to `reencrypt` termination automatically.

```yaml
ui:
  auth:
    enabled: true
    # Optional: restrict WHO may log in (default: any authenticated user).
    # A SubjectAccessReview every user must pass, e.g. only people who can
    # read services in the temporal namespace:
    sar: { namespace: temporal, resource: services, verb: get }
    # ...or only cluster-admins — the wildcard only matches RBAC rules that
    # themselves grant verb=* on resource=*:
    # sar: { resource: "*", verb: "*" }
```

The session-cookie secret is generated on first install and preserved across
upgrades (`lookup`). Two overrides: `ui.auth.cookieSecret` renders a literal
you supply (deterministic — see the Argo CD note below; never commit it, this
repo is public), and `ui.auth.existingCookieSecret` (key `session_secret`)
points at a Secret you created yourself and takes precedence over both.
Requires `ui.route.enabled=true` (enforced at render time) — this is
OpenShift-only, leave it disabled on plain Kubernetes.

**Session lifetime.** oauth-proxy re-validates the user's OpenShift token
(and the `sar`, if set) only when it refreshes the session cookie, and its
upstream default is to never refresh — a revoked token (`oc logout`, deleted
`UserOAuthAccessToken`) or a lost permission would otherwise keep working for
the cookie's full 168h. The chart therefore sets `ui.auth.cookieRefresh: 1h`
(re-validate at most an hour later) and `ui.auth.cookieExpire: 24h` (hard
cap — log in again). The identity allowlist below is separate: it is checked
on **every** request.

> **Under Argo CD the cookie value must be deterministic.** Argo renders the
> chart with `helm template` and no cluster access, so the `lookup` above
> always comes back empty and a *generated* Secret is re-rendered with a fresh
> random value on **every** reconcile: the Application never settles on Synced,
> and each sync invalidates every open UI session. Either pass
> `ui.auth.cookieSecret` as an Application parameter (out of git), or —
> better — pre-create the Secret once, out of band, and point the chart at it:
>
> ```sh
> oc create secret generic temporal-ui-cookie -n temporal \
>   --from-literal=session_secret="$(openssl rand -hex 16)"
> ```
>
> ```yaml
> ui:
>   auth:
>     existingCookieSecret: temporal-ui-cookie
> ```
>
> (oauth-proxy wants a 16, 24, or 32-byte secret; `openssl rand -hex 16` gives
> 32 characters, the same length the chart generates. A wrong length is
> rejected at render time.)

**Restricting who may log in** has two kinds of gate, because they answer
different questions:

- `ui.auth.sar` — a *permission* gate (SubjectAccessReview): "can this user do
  X". Good for "anyone who can administer this namespace", useless for
  singling out a person: `cluster-admin` is unconditional `verb=*`/`resource=*`,
  so it satisfies **every** possible SAR. There is no SAR that admits one
  cluster-admin while excluding another.
- `ui.auth.allowedUsers` / `ui.auth.allowedGroups` — an *identity* gate:
  exact OpenShift usernames, and/or the members of named OpenShift Groups.
  This excludes everyone not covered, **cluster-admins included**, because it
  never consults RBAC at all. Use it when the requirement is "these people",
  not "anyone with some permission level".

```yaml
ui:
  auth:
    enabled: true
    allowedGroups: ["platform-team"]  # every member of this OpenShift Group
    allowedUsers:  ["admin-master"]   # ...plus this exact account
```

The two identity values are **OR**'d — a user gets in by being in any listed
Group *or* by being named. `sar`, if also set, is an independent **AND** on
top, since oauth-proxy requires every check to pass.

Both are enforced inside oauth-proxy via `--authenticated-emails-file`, so the
allowlist is re-checked on **every request**, not just at login. You write
plain usernames; the chart writes them to that file as
`<username>@ui.auth.usernameDomain` (default `cluster.local`), because the
`openshift` provider rewrites each login to that form and validates the
rewritten string. It also pins `--email-domain` to an unmatchable value — the
proxy admits a user matching the file **or** an accepted email domain, and the
default domain rule accepts every cluster user, which would swallow the
allowlist entirely. Verify both in
[AIRGAPPED-AUTH.md](AIRGAPPED-AUTH.md) §7 before trusting the gate. For
`allowedGroups` a small `group-sync` sidecar re-reads each Group's members
every `ui.auth.groupSync.refreshInterval` seconds and rewrites that file —
which means adding someone grants access without a restart, and removing
someone **drops their already-open session** within one refresh. If the API
read fails the previous list is kept, so a blip cannot lock everyone out.

`allowedGroups` needs the OpenShift `Group` objects to exist. On LDAP-backed
clusters those come from `oc adm groups sync`, **not** from the LDAP login
itself — the LDAP identity provider only maps user attributes. The chart
creates a ClusterRole/ClusterRoleBinding scoped by `resourceNames` to exactly
the Groups you list, so installing with this set needs permission to create
ClusterRoles. See [AIRGAPPED-AUTH.md](AIRGAPPED-AUTH.md) for the full
LDAP-backed, air-gapped runbook.

Scope: this authenticates the **web UI Route only**. All users who pass see
the full UI (no per-user roles), and the gRPC frontend (`:7233`) remains
unauthenticated for in-cluster clients. Per-user authorization would need
Temporal's own JWT/claim-mapper auth with a real OIDC provider (Dex/Keycloak)
— out of scope for this chart today.

## OpenShift specifics (why this chart "just works")

- **Arbitrary UID (restricted-v2 SCC):** no container pins `runAsUser`/`fsGroup`.
  An init container seeds the image's `/etc/temporal/config` into a writable
  `emptyDir` so the entrypoint can render its config.
- **PostgreSQL:** `global.compatibility.openshift.adaptSecurityContext: auto`
  strips the incompatible security context from the Bitnami subchart.
- **Probes** target each role's membership port — the `worker` service has no
  client gRPC listener, only membership.
- **Namespace/search-attribute provisioning** is done once by the setup Job
  (per-pod auto-setup provisioning is disabled), so it scales cleanly.

## Air-gapped install

In an air-gapped (offline) environment you must do three things: **mirror every
image** into your private Artifactory registry, **point the chart at those
images**, and (usually) **use an existing managed PostgreSQL** instead of the
bundled one. The PostgreSQL subchart is already vendored under `charts/`, so no
Helm OCI pull is needed at install time.

Every image reference in this chart (Temporal, UI, wait, the auth sidecars,
and — via the Bitnami subchart's own convention — the bundled PostgreSQL) is
built from a single `global.imageRegistry` prefix plus each component's
`repository`/`tag`, which never change between environments. So mirroring only
requires **(1)** getting every image across as a tar file *preserving its
repository path exactly* when it's pushed into Artifactory on the other side,
**(2)** setting one value.

### 1. Pull and save the images

These are every image the chart pulls. From a workstation with internet
access, pull each one and save it to a tar for transfer — tagging/pushing into
Artifactory on the air-gapped side is handled separately:

| Source image | Used by |
|--------------|---------|
| `docker.io/temporalio/auto-setup:1.29.7` | server pods (frontend/history/matching/worker) + config init |
| `docker.io/temporalio/admin-tools:1.29.7-tctl-1.18.4-cli-1.7.2` | schema Job + namespace-setup Job |
| `docker.io/temporalio/ui:2.51.0` | Web UI |
| `docker.io/busybox:1.36` | wait-for init containers in the hook Jobs |
| `docker.io/bitnamilegacy/postgresql:17.6.0-debian-12-r4` | bundled PostgreSQL **(skip if using external DB)** |
| `quay.io/openshift/origin-oauth-proxy:4.20` | UI login sidecar **(skip unless `ui.auth.enabled`)** — note the `quay.io` source |
| `quay.io/openshift/origin-cli:4.18` | UI group-sync sidecar **(skip unless `ui.auth.allowedGroups` is set)** |

> Both `quay.io/openshift/*` tags track your **cluster's** minor version, not
> the chart's. On OCP 4.20 mirror and pin `4.20`: the `oc`/`kubectl` skew
> policy is ±1 minor, so a 4.18 `oc` against a 4.20 API server is outside the
> supported window.

```sh
mkdir -p images

# Docker Hub images
for img in \
  temporalio/auto-setup:1.29.7 \
  temporalio/admin-tools:1.29.7-tctl-1.18.4-cli-1.7.2 \
  temporalio/ui:2.51.0 \
  busybox:1.36 \
  bitnamilegacy/postgresql:17.6.0-debian-12-r4 \
  nginxinc/nginx-unprivileged:1.27-alpine ; do   # drop this last one if ui.auth.allowedUsers is unused
    podman pull docker.io/$img
    podman save -o "images/$(echo $img | tr '/:' '__').tar" docker.io/$img
done

# quay.io images (only with ui.auth): the registry host is KEPT on retag —
# the chart prefixes the repository verbatim, so the mirror path must include
# the quay.io/ segment.
for img in openshift/origin-oauth-proxy:4.20 openshift/origin-cli:4.18 ; do
    docker pull quay.io/$img
    docker tag  quay.io/$img $ARTIFACTORY/quay.io/$img
    docker push $ARTIFACTORY/quay.io/$img
done
```

When these get pushed into Artifactory on the air-gapped side, each one needs
to land at **exactly the `repository` path written in
[`values.yaml`](values.yaml)**, just under the Artifactory host — nothing is
rewritten. So
`temporalio/auto-setup:1.29.7` becomes
`artifactory.example.com/temporal-docker/temporalio/auto-setup:1.29.7`, and
`quay.io/openshift/origin-oauth-proxy:4.20` becomes
`artifactory.example.com/temporal-docker/quay.io/openshift/origin-oauth-proxy:4.20`
(the `quay.io/` segment is kept, matching the retag loop above). The two paths
look asymmetric because they are: the Docker Hub images carry no `docker.io/`
segment in their `repository` values, so they land host-less, while the two
`openshift/*` sidecars keep the `quay.io/` host written into theirs. Mirror
each one at the path it is written with and a single `global.imageRegistry`
value resolves every image correctly.

### 2. Point the chart at Artifactory

Edit the chart's own [`values.yaml`](values.yaml) — there is no second values
file. The blocks below show only the keys that change; everything else keeps
its default.

If a GitOps repo deploys this chart, it layers its own `values.yaml` files on
top of the chart's, so the same blocks go there instead. Helm deep-merges
**maps** but **replaces lists wholesale**, so a higher layer that sets
`imagePullSecrets` or `ui.auth.allowedGroups` discards the lower layer's list
rather than appending to it. And if the chart is consumed as a **dependency of
a wrapper chart** rather than directly, nest everything one level deeper under
the subchart's key (`temporal-stack:`).

```yaml
# Registry prefixed to every image the release renders — the chart's own AND
# the bundled PostgreSQL's (it is the key the Bitnami subchart reads natively).
# Empty (the default) means "pull from the public registries".
global:
  imageRegistry: artifactory.example.com/temporal-docker
  security:
    allowInsecureImages: true   # only matters with the bundled DB — see 3b

# Pull secret — only if your Artifactory requires credentials
# imagePullSecrets:
#   - name: artifactory
```

That single field rewrites all of the chart's images to
`<registry>/<repository>:<tag>`, taking each `repository` verbatim — including
the `quay.io/` host baked into the two sidecar repositories — which is the
exact layout the retag loop above produces.

| Default | Rendered with `global.imageRegistry` set |
| --- | --- |
| `temporalio/auto-setup:1.29.7` | `artifactory.example.com/temporal-docker/temporalio/auto-setup:1.29.7` |
| `temporalio/admin-tools:1.29.7-…` | `artifactory.example.com/temporal-docker/temporalio/admin-tools:1.29.7-…` |
| `temporalio/ui:2.51.0` | `artifactory.example.com/temporal-docker/temporalio/ui:2.51.0` |
| `busybox:1.36` | `artifactory.example.com/temporal-docker/busybox:1.36` |
| `quay.io/openshift/origin-oauth-proxy:4.20` | `artifactory.example.com/temporal-docker/quay.io/openshift/origin-oauth-proxy:4.20` |
| `quay.io/openshift/origin-cli:4.18` | `artifactory.example.com/temporal-docker/quay.io/openshift/origin-cli:4.18` |

So there is no need to restate a full path per image. You still override an
individual `image.repository`/`tag` when your mirror uses a *different* path
(or to pin the OCP minor for the two `openshift/*` sidecars) — whatever you put
there is treated as relative to the registry prefix in the same way.

If the registry needs credentials, create the pull secret once:

```sh
oc create secret docker-registry artifactory -n temporal \
  --docker-server=artifactory.example.com \
  --docker-username=<user> --docker-password=<token-or-api-key>
```

### 3a. Use an existing (hosted) PostgreSQL — recommended for air-gapped

Disable the bundled database and point Temporal at your managed instance. The
schema/namespace Jobs and all server pods read the password from a Secret you
create.

```yaml
postgresql:
  enabled: false          # do not deploy the bundled PostgreSQL

database:
  driver: postgres12      # works with PostgreSQL 12..17
  host: pg.internal.example.com   # your hosted PostgreSQL host
  port: 5432
  user: temporal_admin    # must be allowed to CREATE DATABASE (for schema setup)
  existingSecret: temporal-db      # Secret you create (see below)
  secretKey: password              # key in that Secret holding the password
  temporalDb: temporal
  visibilityDb: temporal_visibility
```

Create the password Secret the chart references:

```sh
oc create secret generic temporal-db -n temporal \
  --from-literal=password='<db-password>'
```

Notes for an external DB:
- The schema hook Job runs `create-database` for `temporal` and
  `temporal_visibility`, so the `database.user` needs `CREATEDB`. If your DBA
  pre-creates the two databases, the Job's create step is a harmless no-op.
- TLS: the Temporal `postgres12` plugin connects without TLS by default. If your
  hosted DB enforces TLS, that requires extra server config beyond these values —
  open an issue / extend the dynamic config template.

### 3b. Or keep the bundled PostgreSQL with a mirrored image

If you do want the in-cluster database, push the Bitnami image to Artifactory
(it's in the loop in step 1). The `global.imageRegistry` you already set in
step 2 covers it; `allowInsecureImages: true` is what lets Bitnami's chart
render once its image no longer points at the stock `docker.io` path:

```yaml
global:
  imageRegistry: artifactory.example.com/temporal-docker
  security:
    allowInsecureImages: true

postgresql:
  enabled: true
  auth:
    existingSecret: temporal-postgres   # optional; the chart follows it for
                                        # the server pods/Jobs automatically
```

That yields
`artifactory.example.com/temporal-docker/bitnamilegacy/postgresql:17.6.0-debian-12-r4`
— the same path the retag loop pushed.

> Why `bitnamilegacy`? Docker Hub's `bitnami/postgresql` now only publishes
> `:latest`; concrete, reproducible tags moved to `bitnamilegacy`. Any
> PostgreSQL 12+ Bitnami image works if you prefer a different one — just
> change `postgresql.image.repository`/`tag`, the registry still comes from
> `global.imageRegistry`.

### 3c. Everything above, merged

The complete set of `values.yaml` edits — sections 2–3 plus the UI login from
[AIRGAPPED-AUTH.md](AIRGAPPED-AUTH.md). Delete what you don't use; adjust the
registry host, the OCP minor, and the group name.

```yaml
# One prefix for every image the release renders (bundled DB included)
global:
  imageRegistry: artifactory.example.com/temporal-docker
  security:
    allowInsecureImages: true

ui:
  route:
    enabled: true                    # required by ui.auth
  auth:
    enabled: true
    allowedGroups: ["redbull"]    # members of this OpenShift Group only
    allowedUsers: []                 # optional break-glass accounts (OR'd)
    existingCookieSecret: temporal-ui-cookie   # required under Argo CD
    image:
      tag: "4.20"                    # track the CLUSTER's OCP minor, not 4.18
    groupSync:
      image:
        tag: "4.20"
      refreshInterval: 60

# --- Option A: external/hosted PostgreSQL (see 3a) ---
postgresql:
  enabled: false
database:
  driver: postgres12
  host: pg.internal.example.com
  port: 5432
  user: temporal_admin
  existingSecret: temporal-db
  secretKey: password
  temporalDb: temporal
  visibilityDb: temporal_visibility

# --- Option B: bundled PostgreSQL instead (see 3b) — replace the two blocks above
# postgresql:
#   enabled: true
#   auth:
#     existingSecret: temporal-postgres   # key: postgres-password
```

Secrets referenced above are created out of band, once, in the target
namespace:

```sh
oc create secret generic temporal-db -n temporal \
  --from-literal=password='<db-password>'

oc create secret generic temporal-ui-cookie -n temporal \
  --from-literal=session_secret="$(openssl rand -hex 16)"
```

### 4. Install offline

```sh
oc new-project temporal
helm install temporal . -n temporal
```

Under Argo CD there is no `helm install` — point the Application at this chart
path and let it sync.

No external network calls are made: images come from Artifactory and the
PostgreSQL subchart is vendored in `charts/`.

## Secrets in production

The default `postgresql.auth.postgresPassword` in `values.yaml` is a **non-secret
placeholder** for the bundled-DB test path. For production:

- External DB → use `database.existingSecret` (section 3a); never put the password
  in values.
- Bundled DB → set `postgresql.auth.existingSecret` (key `postgres-password`)
  and remove the inline password; the server pods and Jobs follow that Secret
  automatically.

## Network policy

Off by default (`networkPolicy.enabled: false`) so a first sync cannot lock
anything out; turn it on once the two peer lists match your cluster:

- `networkPolicy.frontendFrom` — who may dial the frontend gRPC port
  (workers/SDK clients). Default: any pod in the release's namespace.
- `networkPolicy.uiFrom` — where Route traffic enters from. Default: the
  OpenShift router namespace **and** host-network (bare-metal routers run
  with `hostNetwork`, so their traffic carries the host-network label).

Server roles then accept only this release's own pods, and the UI pod accepts
only the router on the one port its Service exposes — with `ui.auth` that is
the oauth-proxy port, which closes the plain-HTTP bypass around the login.

The bundled PostgreSQL's own (Bitnami) policy is allow-all on 5432 by
default. Every Temporal pod already carries the `temporal-postgresql-client:
"true"` label that policy selects, so locking it down is one value:

```yaml
postgresql:
  primary:
    networkPolicy:
      allowExternal: false
```

## Availability

Each Temporal role with more than one replica gets a `PodDisruptionBudget`
(`minAvailable: 1`) so node drains roll one pod at a time. Disable with
`podDisruptionBudget.enabled: false`.

## Workflow retention

Temporal keeps a **closed** workflow (Completed, Failed, Terminated — any final
state) in history/visibility only for a retention period, then purges it
automatically. Open (Running) workflows are never purged. The chart default is
**`temporal.setup.retention: 168h` (1 week)**; the minimum Temporal allows is
`24h`.

**Important — this value only applies when the namespace is first created.**
The setup Job (`templates/namespace-setup-job.yaml`) runs
`temporal operator namespace create --retention <value>` **only if the
namespace doesn't already exist**; on a cluster where it does, changing
`retention` and re-running `helm upgrade`/`helmfile sync` has **no effect** (the
Job takes its "already exists" branch). So there are two cases:

- **New cluster / new namespace** — set `temporal.setup.retention` in values
  (or your Helmfile override) before the first install and you're done.
- **Namespace already exists** — update it live; the chart won't do it for you:

  ```sh
  oc exec -n temporal deploy/temporal-frontend -- \
    temporal operator namespace update --address temporal-frontend:7233 \
    --namespace default --retention 168h
  ```

  This takes effect immediately for workflows that close afterward. It does
  **not** resurrect already-purged workflows. Confirm with:

  ```sh
  oc exec -n temporal deploy/temporal-frontend -- \
    temporal operator namespace describe --address temporal-frontend:7233 \
    --namespace default | grep -i retention
  ```

Keep the values file and the live namespace in agreement, so a future
reinstall on a fresh cluster reproduces the same retention.

> Retention above the cluster's max (Temporal's default cap is 30 days) is
> rejected with an `invalid retention period` error — if you need a longer
> window, raise the cap first via `temporal.dynamicConfig` (see Temporal's
> dynamic-config reference for the current max-retention key).

## Deleting workflows

The bundled `temporalio/ui:2.51.0` does not reliably expose a per-workflow
Delete action in the workflow detail page's menu (only Reset/Terminate/etc.,
version-dependent) — **Reset is not a delete**, it starts a new run from an
earlier point in history and leaves the original in place. Deletion is done
via the `temporal` CLI, from any pod that can reach the frontend (the
`temporal-frontend` Deployment's own container has the CLI built in):

```sh
# Single workflow, by ID
oc exec -n temporal deploy/temporal-frontend -- \
  temporal workflow delete --address temporal-frontend:7233 --namespace default \
  --workflow-id <workflow-id>

# Bulk, by visibility query — e.g. every Completed workflow in the namespace
oc exec -n temporal deploy/temporal-frontend -- \
  temporal workflow delete --address temporal-frontend:7233 --namespace default \
  --query "ExecutionStatus='Completed'"
```

Deletion is asynchronous and removes the workflow's Event History; if the
workflow is still Running, the server terminates it first. This is immediate
and manual — independent of (and faster than) waiting for retention to expire
it automatically (see "Workflow retention" above).

## Common overrides

```yaml
# Larger DB volume on a specific StorageClass (bundled DB)
postgresql:
  primary:
    persistence:
      size: 50Gi
      storageClass: my-fast-rwo

# Closed-workflow retention (NEW namespaces only — see "Workflow retention")
temporal:
  setup:
    retention: 720h   # 30 days

# Scale a role
temporal:
  services:
    history:
      replicaCount: 4

# Pin the UI Route hostname / disable the Route. With a pinned host the UI's
# CORS origin is set to it instead of "*" (see ui.corsOrigins).
ui:
  route:
    host: temporal.apps.example.com   # empty => auto-assigned
    # enabled: false                  # ClusterIP only
```

## Uninstall

```sh
helm uninstall temporal -n temporal
oc delete pvc -n temporal --all   # PVCs are retained by default
```

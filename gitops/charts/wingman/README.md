# Wingman Helm Chart

Helm chart for deploying the Wingman platform on OpenShift (or, for local use, Kubernetes).

## Prerequisites

- OpenShift 4.12+ (the chart creates a Route and, unless `auth.oauthClient.create` is false, an
  `OAuthClient`), or Kubernetes 1.24+ with an ingress controller and dev login, for local use only
- Helm 3.x
- A GitLab with the day1 project, the specs project and the sigs group of team projects, and a
  service account token for them (see [GitLab token](#gitlab-token))
- The platform's workflows orchestrator, with `provision-cluster`, and server-scan
  (`workflows.url`, `serverScan.url`): every create starts provision-cluster (ADR-0042), and
  the chart fails without them unless `environment` is `development`
- (Optional) the Prometheus Operator CRDs, for monitoring (`docs/ops/metrics.md`)

## Quick Start

### Local Development (Minikube)

`scripts/minikube-dev-setup.sh` does all of this, including a local GitLab seeded with the
fixture repos. By hand:

```bash
minikube start --cpus=4 --memory=8g
minikube addons enable ingress

# Build the images into minikube (scripts/build-images.sh does the same)
eval $(minikube docker-env)
docker build -t wingman-day1:latest -f apps/day1-service/Dockerfile .
docker build -t wingman-day2:latest -f apps/day2-service/Dockerfile .
docker build -t wingman-web:latest -f apps/web/Dockerfile .

# Install with the minikube values: dev login, an Ingress, the local GitLab, the images above
helm upgrade --install wingman ./deploy/helm/wingman -n wingman --create-namespace \
  -f deploy/helm/wingman/values.minikube.yaml \
  --set gitlab.accessToken=<token> \
  --set auth.jwtSecret=$(openssl rand -hex 32) \
  --set devAuth.secret=$(openssl rand -hex 16)

# Add "$(minikube ip) wingman.local" to /etc/hosts, then open http://wingman.local
```

### Production (OpenShift)

The chart renders the `wingman-secrets` Secret and the `OAuthClient` from its values: pass the
secrets as values, and do not create that Secret yourself.

```bash
oc new-project wingman

helm upgrade --install wingman ./deploy/helm/wingman -n wingman \
  --set gitlab.url=https://gitlab.example.com \
  --set gitlab.accessToken=<token> \
  --set gitlab.day1ProjectId=gitops-day1/platform-config \
  --set gitlab.specsProjectId=wingman/cluster-specs \
  --set gitlab.day2SigsGroupPath=gitops-day2-prod/sigs \
  --set auth.openshiftOAuthHost=oauth-openshift.apps.example.com \
  --set auth.openshiftApiHost=api.example.com:6443 \
  --set auth.jwtSecret=$(openssl rand -hex 32) \
  --set auth.oauthClientSecret=$(openssl rand -hex 32) \
  --set route.host=wingman.apps.example.com \
  --set workflows.url=http://workflows-orchestrator-api.<ns>.svc:8080 \
  --set serverScan.url=http://server-scan-api.<ns>.svc:8000 \
  --set image.day1.tag=<version> --set image.day2.tag=<version> --set image.web.tag=<version>
```

Keep the generated secrets for later upgrades (in a values file outside Git, passed with `-f`):
a new `auth.jwtSecret` signs everyone out.

### From a GitOps repository (Argo CD)

A Git repository that deploys the chart holds no secret: redbull-platform, whose ApplicationSet
deploys every release of Wingman by itself, is public (ADR-0070). Two switches keep every secret
out of the values:

- `secrets.existingSecret: <name>`: the chart renders no Secret, and day1 and day2 load the named
  one with `envFrom`. Its keys are the variables: `GITLAB_TOKEN`, `JWT_SECRET_KEY`,
  `OPENSHIFT_OAUTH_CLIENT_SECRET`, and optionally `GITLAB_WEBHOOK_SECRET` (without it day1's GitLab
  webhook answers 404) and `DEV_AUTH_SECRET` (dev login only). The render fails while
  `gitlab.accessToken`, `gitlab.webhookSecret`, `auth.oauthClientSecret`, `auth.jwtSecret` or
  `devAuth.secret` is set, naming it: the Secret holds it, and a value beside it would be ignored.
- `auth.oauthClient.create: false`: the chart renders no `OAuthClient`, whose secret it would have
  to write inline. With `secrets.existingSecret` it is required (the render says so) wherever the
  chart would render one (`openshiftRoute.enabled` without `devAuth.enabled`).

Create both once, in Wingman's namespace, before the first sync (the same commands are at the top
of `values.yaml`, under SECRETS):

```bash
oauth_secret=$(openssl rand -hex 32)
oc create secret generic wingman-credentials -n wingman \
  --from-literal=GITLAB_TOKEN='<the GitLab token>' \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=OPENSHIFT_OAUTH_CLIENT_SECRET="$oauth_secret"
oc apply -f - <<EOF
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: wingman-app                  # auth.oauthClientId
secret: $oauth_secret
grantMethod: auto
redirectURIs:
  - https://<route.host>/login       # or auth.oauthRedirectUri
EOF
unset oauth_secret
```

Then the values hold no secret:

```yaml
secrets:
  existingSecret: wingman-credentials
auth:
  oauthClient:
    create: false
```

day1 and day2 read the Secret when they start, and the chart cannot see it change: after changing
a key, `oc rollout restart deploy/wingman-day1 deploy/wingman-day2 -n wingman`. An `ExternalSecret`
that writes a Secret of that name with those keys (redbull-platform's `gitops/SECRETS.md`) works
the same. `ci/existing-secret-values.yaml` renders this mode in CI.

## Configuration

### Key Values

Every variable the services read is set from these (`templates/configmap.yaml`, `templates/secret.yaml`
or the Secret `secrets.existingSecret` names, and day1's `env` in `templates/day1-deployment.yaml`
for the server-scan token);
the names are explained in the root README's [Environment Variables](../../../README.md#environment-variables).

| Key | Sets | Default | Description |
|-----|------|---------|-------------|
| `gitlab.url` | `GITLAB_URL` | `https://gitlab.internal` | The GitLab instance |
| `gitlab.accessToken` | `GITLAB_TOKEN` (Secret) | `""` | The one service account token ([GitLab token](#gitlab-token)) |
| `gitlab.day1ProjectId` | `DAY1_GITLAB_PROJECT_ID` | `""` | The day1 project: a numeric id or a `group/project` path |
| `gitlab.specsProjectId` | `SPECS_GITLAB_PROJECT_ID` | `""` | The specs project |
| `gitlab.specsRoot` | `SPECS_ROOT_PATH` | `specs` | The spec files' folder in the specs project |
| `gitlab.day2SigsGroupPath` | `DAY2_SIGS_GROUP_PATH` | `""` | The sigs group: every project directly in it is a team |
| `gitlab.day2GitopsBranch` | `DAY2_GITOPS_BRANCH` | `main` | The branch the platform reads; day2's MRs target it |
| `gitlab.verifyTls` | `GITLAB_VERIFY_TLS` | `true` | An internal CA goes in `tls.caBundle`, not here |
| `gitlab.webhookSecret` | `GITLAB_WEBHOOK_SECRET` (Secret) | `""` | Empty: day1's GitLab webhook answers 404 |
| `environment` | `WINGMAN_ENVIRONMENT` | `production` | `production` refuses the in-memory GitLab (ADR-0009); only `development` may leave `workflows.url` empty (ADR-0042) |
| `day1.clusterNameStripPrefix` | `DAY1_CLUSTER_NAME_STRIP_PREFIX` | `ocp4-` | ADR-0015: `""` for the GitHub sandbox |
| `day1.cacheTtlSeconds` | `DAY1_CACHE_TTL_SECONDS` | `30` | Per replica, at most 60 (ADR-0011) |
| `day1.upgrades.enabled` | `DAY1_UPGRADES` | `false` | Upgrades through the platform's `upgrade-cluster` workflow (ADR-0055): the cluster page starts it, shows its run and sends its decisions, and an edit may no longer change `mastertag` or a `workertag`. Needs `workflows.url`; the workflow must read the same day1 repo as Wingman. On, the Route's timeout is 130 s (`haproxy.router.openshift.io/timeout`), for the targets read |
| `day1.placementMinFreePods` | `PLACEMENT_MIN_FREE_PODS` | `70` | MCE placement (ADR-0050), checked with `clusterStatus.enabled` (without it, not checked): the cost of one hosted control plane. An MCE is offered for a new cluster only with at least this many free pods (allocatable less in use) on its workers: masters, infra nodes and tainted, cordoned or NotReady nodes are left out ([Live cluster status](#live-cluster-status-mce-hubs)) |
| `day1.addServers.enabled` | `DAY1_ADD_SERVERS` | `false` | Inventory Management (ADR-0057): admins add servers to an MCE's InfraEnv pool by starting the platform's `add-server-to-mce` workflow, by count or by name. Needs `workflows.url`; the page needs `serverScan.url`, and the InfraEnvs come from the MCE (`clusterStatus.enabled`) |
| `day1.scaleNodepools.enabled` | `DAY1_SCALE_NODEPOOLS` | `true` | Scale on the cluster page's Nodes tab (ADR-0062): admins start the platform's `update-nodepool` workflow for one NodePool at a time; it commits the replicas to day1 `main` and syncs Argo CD itself. While on, no Wingman merge request changes an existing NodePool's replicas: an edit that does is refused, a flavor's sync or rollout leaves them out and offers Restore. **On by default since 3.53.0** (update-nodepool is in production) wherever `workflows.url` is set: the chart renders `"true"` only then, and without `workflows.url` there is no Scale and the render does not fail. `false` turns it off. The workflow must read the same day1 repo as Wingman; live status is not needed. Before upgrading, check that the orchestrator and every MCE's worker have update-nodepool ([upgrade guide](../../../docs/upgrade/3.52-to-3.53.md)): without it a start says it is not deployed and starts nothing, and no existing NodePool's replicas change from Wingman until it is. A NodePool's own scale-down policy (`redbull.io/scale-down-policy`) reaches it only with the hostedclusters-setup chart patch 0001 (`docs/upgrade/patches/hostedclusters-setup/`); Scale itself does not need it |
| `day1.multiInfraEnvNodepools.enabled` | `DAY1_MULTI_INFRAENV_NODEPOOLS` | `false` | A nodepool may draw Agents from several InfraEnvs (ADR-0064): the create form and the flavor editor offer more InfraEnvs beside a nodepool's own, written as `nodepool[].additionalInfraEnvNames`. **Parked, leave it off** (ADR-0064's 2026-11-23 amendment): the team runs no such NodePool for now, so the hostedclusters-setup chart (which without the change silently selects the first InfraEnv alone) and the specs-project template don't carry the key ([upgrade guide](../../../docs/upgrade/3.46-to-3.47.md)). Off, Wingman never writes the key, and an edit leaves it as it is |
| `day1.excludedAgentLabels` | `DAY1_EXCLUDED_AGENT_LABELS` | `[]` | Agent label keys every agent NodePool excludes, each a `DoesNotExist` in its selector (ADR-0065): herzi's label for used Agents, `["redbull.io/ever-installed"]` and nothing else, so a freed used Agent is never bound again before herzi removes it. Written on each new cluster's nodepools (`excludeAgentLabels`); an existing cluster takes them through its own merge request (`POST /api/day1/clusters/{name}/excluded-agent-labels`). Set it only once herzi's release that accepts the exclusion runs on every MCE, with the hostedclusters-setup chart patch 0002 (`docs/upgrade/patches/hostedclusters-setup/`) and the specs-project template lines ([3.54-to-3.55.md](../../../docs/upgrade/3.54-to-3.55.md) step 6; [3.48-to-3.49.md](../../../docs/upgrade/3.48-to-3.49.md) §9): herzi's `main` blocks the pool of any NodePool that carries it. Empty: no NodePool changes, and placement and Inventory Management still treat an Agent carrying herzi's label as used (ADR-0050, ADR-0057) |
| `day2.cacheTtlSeconds` | `DAY2_CACHE_TTL_SECONDS` | `15` | Per replica, at most 60 (ADR-0011) |
| `auth.openshiftOAuthHost` | `OPENSHIFT_OAUTH_HOST` | | The OAuth server's host ([Login](#login-openshift-oauth)) |
| `auth.openshiftApiHost` | `OPENSHIFT_API_HOST` | | The API server, `host:port` |
| `auth.oauthClientId` | `OPENSHIFT_OAUTH_CLIENT_ID` | `wingman-app` | Also the name of the `OAuthClient` the chart creates |
| `auth.oauthClient.create` | | `true` | The chart renders the `OAuthClient` (with `openshiftRoute.enabled`, without `devAuth.enabled`). `false`: none, it is created by hand ([From a GitOps repository](#from-a-gitops-repository-argo-cd)); needed with `secrets.existingSecret` |
| `auth.oauthClientSecret` | `OPENSHIFT_OAUTH_CLIENT_SECRET` (Secret) | `""` | Also the `OAuthClient`'s secret |
| `auth.oauthRedirectUri` | `OPENSHIFT_OAUTH_REDIRECT_URI` | `""` | Empty: `https://{route.host}/login` |
| `auth.sslVerify` | `OPENSHIFT_SSL_VERIFY` | `"false"` | `"true"`, `"false"` or a CA bundle path |
| `auth.jwtSecret` | `JWT_SECRET_KEY` (Secret) | `""` | At least 32 characters: `openssl rand -hex 32` |
| `auth.jwtExpiryHours` | `JWT_EXPIRY_HOURS` | `8` | How long a session lasts |
| `auth.adminGroups` | `WINGMAN_ADMIN_GROUPS` | `wingman-admins` | Comma-separated OpenShift groups |
| `auth.viewerGroups` | `WINGMAN_VIEWER_GROUPS` | `""` | Empty: no viewer role |
| `devAuth.enabled` | `DEV_AUTH_ENABLED` | `false` | Dev login instead of OpenShift: local use only |
| `devAuth.secret` | `DEV_AUTH_SECRET` (Secret) | `""` | At least 32 characters |
| `secrets.existingSecret` | | `""` | An existing Secret day1 and day2 read instead of the chart's `wingman-secrets`, which is then not rendered; its keys are the five variables marked (Secret) here. Every secret value must then be empty, and `auth.oauthClient.create` false where an `OAuthClient` would render ([From a GitOps repository](#from-a-gitops-repository-argo-cd), ADR-0070) |
| `clusterStatus.enabled` | `CLUSTER_STATUS_ENABLED` | `false` | Live status and the cluster nodes, from the MCE hubs ([Live cluster status](#live-cluster-status-mce-hubs)) |
| `clusterStatus.mceDomain` | `MCE_API_DOMAIN` | `""` | A hub is `https://api.{mce}.{mceDomain}:6443`, unless the tokens Secret gives it its own `url` (ADR-0045) |
| `clusterStatus.sslVerify` | `MCE_SSL_VERIFY` | `"false"` | `"true"`, `"false"` or a CA bundle path |
| `clusterStatus.tokensSecretName` | | `mce-sa-tokens` | The Secret whose key `tokens` (a YAML map of MCE name to token, or to `{token, url}`) is mounted as `MCE_TOKENS_FILE` |
| `serverScan.url` | `SERVER_SCAN_URL` | `""` | server-scan's API, e.g. `http://server-scan-api.<ns>.svc:8000`. The nodes' servers, placement's spare servers, Inventory Management, and the top bar's link for admins ([Cluster nodes](#cluster-nodes-server-scan-and-the-workflows-orchestrator)). Empty: nodes are listed without their servers, no Inventory Management, no link |
| `serverScan.uiUrl` | `SERVER_SCAN_UI_URL` | `""` | server-scan's UI, where the top bar's link and the node links point. Empty: `serverScan.url` |
| `serverScan.sslVerify` | `SERVER_SCAN_SSL_VERIFY` | `"true"` | `"true"`, `"false"` or a CA bundle path |
| `serverScan.timeoutSeconds` | `SERVER_SCAN_TIMEOUT_SECONDS` | `10` | Per request, at most 60 |
| `serverScan.tokenSecret.name` | `SERVER_SCAN_TOKEN` (day1 only) | `""` | An existing Secret with a server-scan viewer token, for every read. Empty: no token, for a server-scan with auth off |
| `serverScan.tokenSecret.key` | `SERVER_SCAN_TOKEN` (day1 only) | `token` | The token's key in that Secret |
| `workflows.url` | `WORKFLOWS_API_URL` | `""` | The workflows orchestrator, e.g. `http://workflows-orchestrator-api.<ns>.svc:8080`. **Required**: every create starts its `provision-cluster` workflow (ADR-0042), and the chart fails without it unless `environment` is `development` (then creates start an in-memory stand-in that writes nothing). Node uninstall, upgrades, Scale and adding servers start its other workflows. Needs `serverScan.url` |
| `workflows.sslVerify` | `WORKFLOWS_SSL_VERIFY` | `"true"` | `"true"`, `"false"` or a CA bundle path |
| `workflows.timeoutSeconds` | `WORKFLOWS_TIMEOUT_SECONDS` | `10` | Per request, at most 60 |
| `workflows.targetsTimeoutSeconds` | `WORKFLOWS_TARGETS_TIMEOUT_SECONDS` | `65` | An upgrade's targets read, at most 120: the orchestrator waits up to 60 s for it. nginx gives that one path 130 s |
| `segmentsManager.url` | `SEGMENTS_MANAGER_URL` | `""` | segments-manager's API, e.g. `http://segments-manager.<ns>.svc:8000`. The cluster page shows its EPG for the cluster's segment and where it disagrees with the file, and admins get the top bar's link to it ([segments-manager](#segments-manager)). Empty: no EPG, no link |
| `segmentsManager.uiUrl` | `SEGMENTS_MANAGER_UI_URL` | `""` | segments-manager's UI. The top bar links to it for admins, and the cluster page to it and to its search for the cluster's segment. Empty: `segmentsManager.url`; both empty: no link |
| `segmentsManager.sslVerify` | `SEGMENTS_MANAGER_SSL_VERIFY` | `"true"` | `"true"`, `"false"` or a CA bundle path |
| `segmentsManager.timeoutSeconds` | `SEGMENTS_MANAGER_TIMEOUT_SECONDS` | `5` | Per request, at most 60 |
| `quickLinks.hubName` | `QUICK_LINKS_HUB_NAME` | `""` | The hub Wingman runs on, as in `apps.<hubName>.<domain>`: its card on Quick Links ([Quick Links](#quick-links)). Empty: no hub card |
| `quickLinks.hubDomain` | `QUICK_LINKS_HUB_DOMAIN` | `""` | The hub's domain. Empty: `quickLinks.domain` |
| `quickLinks.domain` | `QUICK_LINKS_DOMAIN` | `""` | The MCEs' domain. Empty: `clusterStatus.mceDomain` |
| `quickLinks.argocdUrlTemplate` | `QUICK_LINKS_ARGOCD_URL_TEMPLATE` | `https://openshift-gitops-server-openshift-gitops.apps.{cluster}.{domain}` | A cluster's ArgoCD |
| `quickLinks.consoleUrlTemplate` | `QUICK_LINKS_CONSOLE_URL_TEMPLATE` | `https://console-openshift-console.apps.{cluster}.{domain}` | A cluster's console |
| `quickLinks.clusters` | | `{}` | A cluster's own `argocd` and `console` addresses, for one that does not follow the templates (the ConfigMap `wingman-quick-links`) |
| `quickLinks.sections` | | `[]` | The team's links (the ConfigMap `wingman-quick-links`, re-read by day1 on every page load) |
| `tls.caBundle` | | `""` | An internal CA (PEM), mounted in every pod |
| `tls.caBundleMountPath` | `SSL_CERT_FILE` | `/etc/pki/tls/certs/ca-bundle.crt` | Where it is mounted (set only with a `tls.caBundle`) |
| `route.host` | | `wingman.apps.your-cluster.internal` | The Route's host |
| `openshiftRoute.enabled` | | `true` | A Route and the `OAuthClient`; `false` on plain Kubernetes |
| `ingress.enabled` | | `false` | An Ingress instead (`ingress.host`, `ingress.className`) |
| `image.registry` | | `""` | Prefix of every image, nginx's included: `<registry>/<repository>:<tag>` |
| `image.{day1,day2,web}.tag` | | `""`, **required** | The release you deploy, the same for all three (`3.33.0`; docs/ops/images.md). Empty fails the render, naming the key (ADR-0059) |
| `image.{day1,day2,web}.repository` | | `wingman-day1`, `wingman-day2`, `wingman-web` | |
| `image.nginx.{repository,tag,digest}` | | `registry.access.redhat.com/ubi9/nginx-124`, `9.8`, `sha256:d5cec86a…` | Red Hat's UBI nginx, the one entry point (ADR-0058), pulled by digest. Change the tag and the digest together ([Images](#images)) |
| `image.{day1,day2,web}.digest` | | `""` | Optional: the image is then pulled as `<repository>:<tag>@<digest>` |
| `image.{day1,day2,web,nginx}.pullPolicy` | | `IfNotPresent` | |
| `replicaCount.{day1,day2,web,nginx}` | | `1` | |
| `imagePullSecret` | | `""` | An existing registry Secret |
| `monitoring.{serviceMonitor,prometheusRule,grafanaDashboard}.enabled` | | `false` | [Monitoring](#monitoring), `docs/ops/metrics.md`, `docs/ops/runbook.md` |

`values.yaml` has the rest (resources, the service account) with comments. Every key is in
`values.schema.json`, which refuses any other ([Values schema](#values-schema)).

### Images

The three Wingman images are one release: set `image.day1.tag`, `image.day2.tag` and
`image.web.tag` to it (`3.33.0`, no `v`). They have no default: an empty one fails the render
with `image.day1.tag is empty: set it to the release to deploy, for example --set
image.day1.tag=3.33.0`. Never `latest`, `3.33` or `3`, which move (docs/ops/images.md).

nginx is Red Hat's UBI nginx, `registry.access.redhat.com/ubi9/nginx-124:9.8`, pinned by the
digest of its manifest list (ADR-0058): nodes pull `<repository>:<tag>@<digest>`, so the same
line runs on amd64 and arm64 and never moves. The image's own command is an S2I usage note,
so the chart starts `nginx` itself. To move it to a newer build, change the tag and the digest
together (docs/ops/images.md, "The nginx image"). A tag of another image kept from earlier
values beside the chart's digest fails the render (`image.nginx.tag is "…" but
image.nginx.digest is the chart's`): set that image's digest, or `image.nginx.digest: ""` to
pull it by its tag.

For air-gapped environments, mirror the images, nginx by digest, and point the chart at the
mirror. `image.registry` prefixes every image, nginx's included:

```yaml
image:
  registry: registry.example.com/wingman
  day1:
    tag: "<version>"     # the release, e.g. "3.33.0"
  day2:
    tag: "<version>"
  web:
    tag: "<version>"
  nginx:
    repository: ubi9/nginx-124   # its path in the mirror; tag and digest stay the chart's
```

On OpenShift with an `ImageDigestMirrorSet` for `registry.access.redhat.com` (how Red Hat's
images usually reach a disconnected cluster), leave `image.registry` empty and give each Wingman
image its full path instead (`repository: registry.example.com/wingman/wingman-day1`): nginx's
digest is then redirected to the mirror as is.

### Security context

Every pod runs as OpenShift's `restricted-v2` SCC expects, with no SCC of its own to grant (the
set server-scan's and herzi's charts use):

- the pod: `runAsNonRoot: true` and `seccompProfile: RuntimeDefault`, no `runAsUser` (OpenShift
  assigns the UID from the namespace's range; each image's numeric USER satisfies
  `runAsNonRoot` elsewhere), and `automountServiceAccountToken: false`: no pod calls the
  Kubernetes API with its own token (day1 reads the MCE hubs with the tokens Secret's);
- each container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` and
  `readOnlyRootFilesystem: true`.

Only these paths are writable, each an `emptyDir` with a size limit:

| Pod | Path | Why |
|---|---|---|
| nginx | `/tmp` (256Mi) | nginx's pid and temp files: a request or an answer larger than its buffers waits there |
| web | `/app/apps/web/.next/cache` (64Mi) | Next.js's runtime cache. The pages never write it; its image optimizer (`/_next/image`) does |
| day1, day2 | none | They write no file: GitLab's archives are read in memory |

Checked with podman as `restricted-v2` runs them (docs/ops/images.md, "Read-only root"). The
chart renders no NetworkPolicy (network restrictions are the site's; CLAUDE.md convention 15).

### Values schema

`values.schema.json` checks the values of every `helm install`, `upgrade`, `template` and `lint`
(ADR-0059). It refuses:

- a key the chart does not read, at the root or in any map: `at '/serverScan': additional
  properties 'tokenSecert' not allowed`;
- a wrong type: a switch is `true` or `false`, not `"false"`; numbers are numbers. The five
  `sslVerify` keys take either: `true`, `false`, `"true"`, `"false"` or a CA bundle path,
  rendered the same by one helper (before 3.33, a boolean `false` in `serverScan`,
  `workflows` or `segmentsManager` was silently turned into `"true"`);
- a value outside its list (`environment`, the Route's TLS settings,
  `pullPolicy`), its range (cache TTLs and timeouts at most 60 s, the upgrade targets' 120 s,
  `jwtExpiryHours` 1 to 24, a Quick Links section's `columns` 1 to 6) or its shape (URLs, host
  names, Kubernetes names, image tags and digests, Prometheus durations, `openshiftApiHost`
  without `https://`).

Keys an older release documented and then dropped are accepted and ignored, marked deprecated
in the schema: `quickLinks.status`, `quickLinks.sslVerify`, `quickLinks.argocdTokensSecret` and a
link's `ping` and `argocd` (3.13.1), `day1.serverScanRefresh`, `day1.segmentsArea`,
`day1.serverScanArea` and `serverScan.tokenSecret.adminKey` and `auditorKey` (the Segments
and Server Scan areas, removed in 3.52.1), `day1.provisioner` (3.56.0: every create starts
the provision-cluster workflow), and the legacy chart's `cache`, `paths`,
`gitlab.defaultBranch`, `gitlab.sslVerify` and `clusterStatus.clusterNamePrefix`. Delete them
when convenient.

Check a values file before an upgrade, without touching the cluster:

```bash
helm template <release> $CHART -n <ns> -f my-values.yaml \
  --set image.day1.tag=<tag> --set image.day2.tag=<tag> --set image.web.tag=<tag> > /dev/null
```

An unknown key named there is a typo of a real key (fix its name) or a key no release reads
(delete it; with `--reset-then-reuse-values`, `--set <key>=null`). `docs/upgrade/3.32-to-3.33.md`
does this for a running release.

### Login (OpenShift OAuth)

Users sign in with OpenShift, and their OpenShift groups decide their role (`auth.adminGroups`,
`auth.viewerGroups`). With `openshiftRoute.enabled` and without `devAuth.enabled`, the chart
creates an `OAuthClient` named `auth.oauthClientId` with the secret `auth.oauthClientSecret` and the
redirect URI `https://{route.host}/login` (or `auth.oauthRedirectUri`); the installing user needs
the right to create that cluster-scoped resource. With `auth.oauthClient.create: false` it creates
none, and the `OAuthClient` is made once by hand with the same name, secret and redirect URI
([From a GitOps repository](#from-a-gitops-repository-argo-cd)). Set:

- `auth.openshiftOAuthHost`: `oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}'`
- `auth.openshiftApiHost`: `oc whoami --show-server`, without `https://`

`devAuth` replaces OpenShift login with a shared secret, for minikube and local use only.

### GitLab token

One token, `gitlab.accessToken`, with the `api` scope, of an account that is a member (not an
instance admin without membership: Wingman reads its role from its memberships). It needs:

- the day1 project and the specs project: at least Developer (it pushes branches and opens merge
  requests) and the right to merge into the branches the MRs target;
- each team project in the sigs group (`sigs/<team>`): **per team, the team's choice** (ADR-0043).
  A team that gives the account Developer or higher on its own project is writable in Wingman (new
  add-ons, team and fleet defaults, install, update, remove, approvals); a team that gives it less
  is read-only there, with the reason shown, and every day2 write for it is refused. Reporter is
  enough for its pages to load; with no membership at all, a private project is not seen.

Group membership is inherited: Developer on the sigs group (or a group above it) makes **every**
team writable. For per-team opt-in, give the account Reporter on the sigs group (so every team can
be read) and Developer on each opting-in project, never Developer on the group. Wingman notices a
changed membership within `DAY2_CACHE_TTL_SECONDS`. A team turns its writes on by having a
maintainer of `sigs/<team>` add the account to the project as a Developer, and off by lowering or
removing that membership. `docs/ops/runbook.md` (WingmanGitLabTokenRejected) says how to replace the
token.

### Live cluster status (MCE hubs)

With `clusterStatus.enabled`, day1 reads each MCE hub at `https://api.<mce>.<domain>:6443`
(`clusterStatus.mceDomain`) with that MCE's service-account token, from the Secret
`clusterStatus.tokensSecretName` (key `tokens`, a YAML map of MCE name to token). It reads the
HostedCluster and NodePools for live status, the InfraEnvs for the create form, for a cluster's
nodes (`GET /api/day1/clusters/{name}/nodes`) each NodePool's Machines and Agents, and, for MCE
placement (`GET /api/day1/placement`, ADR-0050), the hub's own nodes and pods.

A hub whose API is not at that address gets its own beside its token (ADR-0045); the plain form
keeps working for the others:

```yaml
ocp4-prod-mce-site1-a: <token>                      # https://api.ocp4-prod-mce-site1-a.<domain>:6443
ocp4-prod-mce-site1-b:
  token: <token>
  url: https://api.hub-b.example.com:6443           # https://<host>[:<port>], nothing after it
```

```bash
oc create secret generic mce-sa-tokens -n <ns> --from-file=tokens=./tokens.yaml \
  --dry-run=client -o yaml | oc apply -f -          # then restart day1: it reads the file at start
```

A `url` that is not `https://<host>[:<port>]` (a path, `http://`, credentials) stops day1 at start,
naming the MCE and never the token.

The service account behind each token needs `get` and `list` on:

| Resources | API group | Namespace |
|---|---|---|
| hostedclusters, nodepools | `hypershift.openshift.io` | `hcp-<clusterName>` |
| machines, machinesets | `cluster.x-k8s.io` | the control plane's, `hcp-<clusterName>-ocp4-<clusterName>` |
| agentmachines | `capi-provider.agent-install.openshift.io` | the control plane's |
| agents, infraenvs | `agent-install.openshift.io` | the HostedCluster's `spec.platform.agent.agentNamespace` |
| nodes, pods (`list` only) | core (`""`) | the whole hub: placement's free pods |

Placement lists the pods as Table rows (name, status, node), only those not `Succeeded` or
`Failed`, never their objects, logs or Secrets. Its servers check lists the Agents of the needed
InfraEnvs across the hub (or in `MCE_INFRAENV_NAMESPACE`), and Inventory Management lists the used
Agents herzi removes there (`<label>,!agentMachineRef`, since 3.55.0): the `agents` rule above already allows
it, because the binding is cluster-wide.

A control-plane namespace is created per cluster, so the grant is a ClusterRole with a
ClusterRoleBinding. Apply it on every hub that has a token, binding the service account whose token
is in the Secret:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wingman-mce-reader
rules:
  - apiGroups: [hypershift.openshift.io]
    resources: [hostedclusters, nodepools]
    verbs: [get, list]
  - apiGroups: [cluster.x-k8s.io]
    resources: [machines, machinesets]
    verbs: [get, list]
  - apiGroups: [capi-provider.agent-install.openshift.io]
    resources: [agentmachines]
    verbs: [get, list]
  - apiGroups: [agent-install.openshift.io]
    resources: [agents, infraenvs]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [nodes, pods]
    verbs: [list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wingman-mce-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wingman-mce-reader
subjects:
  - kind: ServiceAccount
    name: <service account>
    namespace: <its namespace>
```

```bash
oc apply -f wingman-mce-reader.yaml      # logged in to the hub
oc auth can-i list machines.cluster.x-k8s.io -n hcp-<clusterName>-ocp4-<clusterName> \
  --as=system:serviceaccount:<its namespace>:<service account>   # yes
oc auth can-i list pods --all-namespaces \
  --as=system:serviceaccount:<its namespace>:<service account>   # yes
```

No Secrets: Wingman never reads a hosted cluster's own API, so the drain before an in-place
reboot, and which node goes next, are not shown (`docs/ecosystem/notes/hypershift-node-state.md`).
Without the grant the nodes read answers `502 DEPENDENCY_UNAVAILABLE`, naming the path the hub
denied; with live status off, `501 FEATURE_DISABLED`. Without `list` on nodes and pods, placement
marks that MCE unreadable and never picks it; the other MCEs are not affected. A running Wingman's steps are in
`docs/upgrade/3.3-to-3.4.md`.

### Cluster nodes (server-scan and the workflows orchestrator)

A cluster's nodes come from its MCE ([Live cluster status](#live-cluster-status-mce-hubs)). With
`serverScan.url`, day1 adds each node's server record from server-scan (health, a link to its
page) and the servers server-scan places in the cluster that no Machine leads to; with
`workflows.url` (required, since every create starts provision-cluster there), it also starts the
platform's `uninstall-server-from-hc` workflow for one of them and shows its run. The orchestrator has no auth. An uninstall checks the
server in server-scan first, so `workflows.url` without `serverScan.url` fails the chart.

The server-scan token never goes in values: put a viewer token in a Secret and name the Secret.

```bash
oc create secret generic server-scan-viewer -n wingman --from-literal=token=<token>
```

```yaml
serverScan:
  url: http://server-scan-api.<ns>.svc:8000
  uiUrl: https://server-scan.example      # its UI: node links and the top bar's link
  tokenSecret: { name: server-scan-viewer }
workflows:
  url: http://workflows-orchestrator-api.<ns>.svc:8080
```

day1 reads the token at start: restart it (`oc rollout restart deploy/wingman-day1`) after
replacing the Secret.

The same `serverScan.url` puts **Server Scan** in the top bar's platform switch for
Wingman's admins: a link to server-scan's own UI (`uiUrl`, else `url`), in a new tab. The
team keeps server-scan apart from Wingman (ADR-0048's 2026-11-23 amendment): its in-app
Server Scan area was removed in 3.52.1, with `day1.serverScanRefresh` and
`day1.serverScanArea` and the Secret's `adminKey` and `auditorKey`, which a values file may
still set: they are accepted and ignored ([upgrade guide](../../../docs/upgrade/3.52.0-to-3.52.1.md)).
Set `uiUrl` to server-scan's browser address when `url` is its in-cluster API Service, or the
links name an address a laptop cannot reach.

### segments-manager

Off by default. The cluster page's **HostedCluster & network** card shows the cluster's VLAN and
segment from its file either way (Git is the source of truth, ADR-0039). With
`segmentsManager.url`, day1 also reads that one segment from segments-manager's API (its
reads are open: no token) and shows its EPG, with a warning where
segments-manager disagrees with the file (another VLAN, another cluster, a segment not
Allocated, or none). day1 never writes to segments-manager, and segments-manager down only
hides the EPG.

The same setting puts **Segments** in the top bar's platform switch for Wingman's admins: a
link to segments-manager's own UI (`uiUrl`, else `url`), in a new tab. The team keeps
segments-manager apart from Wingman (ADR-0047's 2026-11-23 amendment): its in-app Segments
area was removed in 3.52.1, with `day1.segmentsArea`, which a values file may still set:
it is accepted and ignored. Viewers have no link.

The card also links to segments-manager's UI, names the cluster to search for there (its UI
opens no single cluster), and links to its open search API for the cluster's segment as JSON.
The links use `uiUrl`, or `url` when `uiUrl` is empty; the browser needs to reach them.

```yaml
segmentsManager:
  url: http://segments-manager.<ns>.svc:8000
  uiUrl: https://segments-manager.example
```

A running 3.4 adds it with `docs/upgrade/3.4-to-3.5.md`.

### Quick Links

The **Quick Links** page (`/quick-links`, admins only) is a launcher: a card for the hub Wingman
runs on (`quickLinks.hubName`) and one for every MCE of the day1 repo, by site, each opening the
cluster's ArgoCD with its console beside it, at `quickLinks.argocdUrlTemplate` and
`quickLinks.consoleUrlTemplate` in `quickLinks.domain` (default `clusterStatus.mceDomain`). Then
the team's own links, `quickLinks.sections`. With a domain set, every MCE has its card and nothing
else is needed.

Wingman only lists the links: neither day1 nor the browser calls them, so the page shows no
status dots and no ArgoCD application counts (both removed in 3.13.1; the ArgoCD shows its own
counts one click away). day1 needs no route to the links, and no token for any of them. Values
kept from 3.9 to 3.13.0 that still set the checks or the ArgoCD tokens are ignored (the schema
accepts them as deprecated); what to delete is at the top of `docs/upgrade/3.8-to-3.9.md`.

`quickLinks.sections` and `quickLinks.clusters` are rendered into the ConfigMap
`wingman-quick-links`, mounted in day1 as a directory. day1 reads it on every page load, so an
edit (`helm upgrade`, or `oc edit cm wingman-quick-links`) shows within about a minute, without a
restart. A mistake in it never breaks the page: the page lists each problem and shows the rest.
The file's shape and every icon key: `docs/notes/2026-11-12-quick-links-api.md`.

```yaml
quickLinks:
  hubName: hub-prod
  clusters:                       # a cluster that does not follow the templates
    hub-prod:
      console: https://console.hub-prod.example.internal
  sections:
    - name: Core GitOps
      columns: 2                  # 1 to 6, default 4
      links:
        - name: GitLab GitOps Project
          url: https://gitlab.example.internal/platform/gitops
          description: Main GitOps repository
          icon: gitlab
        - name: ArgoCD Main
          url: https://argocd.example.internal
          icon: argocd
```

A running Wingman adds all of this with `docs/upgrade/3.8-to-3.9.md`.

### Monitoring

`monitoring.serviceMonitor`, `monitoring.prometheusRule` and
`monitoring.grafanaDashboard` (all off by default) add a ServiceMonitor for
both services' `/metrics`, the alert rules (`files/alerts.rules.yaml`, with
`docs/ops/runbook.md`) and the Grafana dashboard (`dashboards/wingman.json`)
as a ConfigMap for Grafana's sidecar. The dashboard has five rows: Overview
(targets, builds, the alerts' counts, and over the dashboard's range the MRs
opened, merged and approved, workflow runs started and
the external systems failing now), Activity (MRs, workflow starts, flavor
rollouts and MCE placement over time), API (load, errors, latency, the
slowest routes and the routes answering 5xx), External systems (calls,
outcomes, latency and failures per system, with a `dependency` variable)
and GitLab (calls, outcomes, latency, and write safety). It reads only
Wingman's metrics and `up`, so it works through Thanos Querier's tenancy
port on user-workload monitoring. `docs/ops/metrics.md` describes each
panel's metrics.

## Loading Pre-built Images (Air-gapped)

```bash
VERSION=3.0.1   # the release, built as the README's Docker section shows

# On build machine
docker save wingman-day1:$VERSION | gzip > wingman-day1-$VERSION.tar.gz
docker save wingman-day2:$VERSION | gzip > wingman-day2-$VERSION.tar.gz
docker save wingman-web:$VERSION | gzip > wingman-web-$VERSION.tar.gz

# Transfer to air-gapped environment, then:
docker load < wingman-day1-$VERSION.tar.gz
docker load < wingman-day2-$VERSION.tar.gz
docker load < wingman-web-$VERSION.tar.gz

# Tag and push to internal registry
docker tag wingman-day1:$VERSION registry.example.com/wingman/wingman-day1:$VERSION
docker push registry.example.com/wingman/wingman-day1:$VERSION
# ... repeat for the other images
```

nginx is mirrored by digest, all architectures, so the chart's digest still names it
(`image.nginx.digest` in `values.yaml`):

```bash
skopeo copy --all \
  docker://registry.access.redhat.com/ubi9/nginx-124:9.8@sha256:d5cec86a9adf972dbfa0d87b134e7c404706cc1920fc2e6a2b146e290276f219 \
  docker://registry.example.com/wingman/ubi9/nginx-124:9.8
```

## Troubleshooting

### Render Errors

`values don't meet the specifications of the schema(s)` names each key the schema refused
([Values schema](#values-schema)); `image.<name>.tag is empty` asks for the release
([Images](#images)). Nothing reaches the cluster until the render passes.

### Health Check Failures

nginx answers its own `/healthz` for both probes: a restarting nginx is nginx itself (its log is
the pod's), never the web. An API call that answers `DEPENDENCY_UNAVAILABLE` with "Wingman's day1
service could not be reached" (or "did not answer in time") is nginx's own problem: the service
named has no ready pod, or is too slow; check that service.

If pods restart due to liveness probe timeouts, or never become ready:
- Liveness is `/health/live` (the process answers); readiness is
  `/health/ready`, which also needs GitLab to answer once after the pod
  starts (ADR-0054). A pod that is live but never ready cannot reach GitLab,
  or the token cannot read what the service checks: day1 the
  `gitlab.day1ProjectId` and `gitlab.specsProjectId` projects, day2 the
  `gitlab.day2SigsGroupPath` group and the day1 project. Check `gitlab.url`,
  the token, those values and the CA; `/health/ready` on the pod's port names
  the error.
- Once ready, a pod stays ready through a GitLab outage: readiness no longer
  asks GitLab, so users get Wingman's own error (a 503 `GIT_UNAVAILABLE`
  problem) instead of a proxy error page, and cached reads still answer for
  up to a minute. The GitLab alerts (`docs/ops/runbook.md`) report the outage.
- `kubectl logs deploy/wingman-day1` (or `-day2`): a configuration the
  service refuses (ADR-0009) is logged at start-up, and the pod exits.

### GitLab API Errors

A 401 or 403 from GitLab to every user means the token: see [GitLab token](#gitlab-token).

### SSL/TLS Issues

For an internal CA, paste it into `tls.caBundle`; it is mounted in every pod
and named by `SSL_CERT_FILE`. `gitlab.verifyTls: false` turns verification
off (never in production).

## Uninstall

```bash
helm uninstall wingman -n wingman
kubectl delete namespace wingman
```

# Air-gapped: LDAP-backed login for the Temporal Web UI

Runbook for restricting the Temporal UI to members of an OpenShift Group on an
LDAP-backed, air-gapped cluster. Worked example: OCP **4.20.12**, group
**`redbull`**.

Companion to the "Air-gapped install" section of [README.md](README.md), which
covers mirroring the base images and pointing the chart at Artifactory. This
document only covers the authentication layer.

---

## 1. What you get

- Users hit the UI Route, get the **OpenShift login form**, and type their LDAP
  credentials. The cluster's OAuth server binds them against LDAP.
- Only members of `redbull` reach the UI. Everyone else is rejected —
  **including cluster-admins who are not in the group**.
- Membership changes take effect within ~60s without restarting anything, in
  both directions: removing someone drops their **already-open session**.

Nothing to write, nothing to deploy beyond this chart. No custom API, no Dex,
no Keycloak.

## 2. Why not just a SubjectAccessReview

The chart also has `ui.auth.sar`, which is the usual way to gate an
oauth-proxy. It cannot express this requirement:

> `cluster-admin` is unconditional `verb=*` / `resource=*`, so it satisfies
> **every** possible SubjectAccessReview — including one bound to
> `redbull`. There is no SAR that admits one cluster-admin and excludes
> another.

Since the requirement is "members of this group, and nobody else", the gate has
to be based on **identity**, not permission. That is what `ui.auth.allowedGroups`
does: it resolves the Group to its actual member list and matches usernames.

## 3. Prerequisites

**a. LDAP identity provider on the cluster OAuth server.** Already in place if
users log into the OpenShift console with LDAP credentials. Nothing in this
chart configures it.

**b. The OpenShift Group must exist.**

```sh
oc get group redbull -o jsonpath='{.users}{"\n"}'
```

This must print the member list. If the Group is missing or empty, **that is
the problem to fix first — not something this chart can work around.** The
LDAP identity provider only maps user attributes at login; it does not create
Groups. Group objects come from `oc adm groups sync` (usually a CronJob) or
from the `group-sync-operator`. That sync talks directly to your LDAP server,
so it works air-gapped.

**c. Install permissions.** With `allowedGroups` set, the chart creates a
ClusterRole and ClusterRoleBinding (`Group` is a cluster-scoped resource, so a
namespaced Role cannot grant read access to it). Argo CD's service account
normally has this; a plain namespace-admin does not.

## 4. Mirror the images

Two `quay.io/openshift/*` images are needed. **Both track your cluster's minor
version, not the chart's** — the chart defaults to `4.18`, and on a 4.20
cluster you want `4.20`. The `oc`/`kubectl` skew policy is ±1 minor, so a 4.18
`oc` against a 4.20 API server is outside the supported window.

| Source image | Used by |
|--------------|---------|
| `quay.io/openshift/origin-oauth-proxy:4.20` | the login sidecar |
| `quay.io/openshift/origin-cli:4.20` | the group-sync sidecar (provides `oc`) |

```sh
ARTIFACTORY=artifactory.example.com/temporal-docker

# The quay.io/ host is KEPT in the mirrored path — the chart prefixes each
# repository verbatim, so these must land at $ARTIFACTORY/quay.io/openshift/...
for img in openshift/origin-oauth-proxy:4.20 openshift/origin-cli:4.20 ; do
    docker pull quay.io/$img
    docker tag  quay.io/$img $ARTIFACTORY/quay.io/$img
    docker push $ARTIFACTORY/quay.io/$img
done
```

`nginxinc/nginx-unprivileged` is **no longer used** — skip that row of the
README's mirror table.

> With Red Hat entitlements, `registry.redhat.io/openshift4/ose-cli:v4.20` and
> `registry.redhat.io/openshift4/ose-oauth-proxy:v4.20` are the supported
> equivalents of these community builds, and a drop-in `repository`/`tag` swap.
> The `repository` you set is prefixed with `global.imageRegistry` verbatim, so
> whatever path you write is the path they must be mirrored to — either keep
> the host (`registry.redhat.io/openshift4/ose-cli`, pushed to
> `$ARTIFACTORY/registry.redhat.io/openshift4/ose-cli`) or drop it on both
> sides (`openshift4/ose-cli` pushed to `$ARTIFACTORY/openshift4/ose-cli`).

## 5. Configure

Merge into the chart's [`values.yaml`](values.yaml), alongside the
`global.imageRegistry` setting from the README's air-gapped section:

```yaml
# Set once for the whole release (README step 2). Both sidecar images below are
# rewritten to <registry>/quay.io/openshift/...  — the quay.io host in their
# default repository is kept, matching the retag loop above.
global:
  imageRegistry: artifactory.example.com/temporal-docker

ui:
  route:
    enabled: true          # required: the OAuth redirect URI derives from it
  auth:
    enabled: true
    # Members of these OpenShift Groups may log in. Cluster-admins who are
    # NOT members are rejected.
    allowedGroups: ["redbull"]
    # Optional break-glass account, OR'd with the group above.
    allowedUsers: []
    # Login sidecar — pinned to the CLUSTER minor, not the chart default
    image:
      tag: "4.20"
    groupSync:
      image:
        tag: "4.20"
      # Seconds between refreshes of the member list.
      refreshInterval: 60
```

Then install or upgrade as usual:

```sh
helm upgrade --install temporal . -n temporal
```

Under Argo CD, sync the Application instead. That path needs the session-cookie
Secret to render **deterministically**: Argo renders with `helm template` and no
cluster access, so the chart's `lookup` for a *generated* cookie comes back
empty on every reconcile — the Application never reaches Synced and each sync
logs every UI user out. Passing `ui.auth.cookieSecret` as an Application
parameter fixes that (keep the value out of git — this repo is public), but
pre-creating the Secret out of band is the better answer:

```sh
oc create secret generic temporal-ui-cookie -n temporal \
  --from-literal=session_secret="$(openssl rand -hex 16)"
```

```yaml
ui:
  auth:
    existingCookieSecret: temporal-ui-cookie
```

### How the values combine

| Value | Kind of gate | Combines as |
|---|---|---|
| `allowedGroups` | identity — members of the named Groups | **OR** with `allowedUsers` |
| `allowedUsers` | identity — exact usernames | **OR** with `allowedGroups` |
| `sar` | permission — a SubjectAccessReview | **AND** on top of the above |

So `allowedGroups: ["redbull"]` plus `allowedUsers: ["breakglass"]` admits
group members *and* that one account. Leave `sar` empty unless you want an
additional, independent permission requirement.

## 6. What the chart deploys

With `allowedGroups` set, the UI pod gains:

- an **initContainer** (`group-sync-init`) that writes the allowlist once
  before oauth-proxy starts — oauth-proxy exits fatally if its allowlist file
  is missing;
- a **`group-sync` sidecar** that re-reads the Group every `refreshInterval`
  and rewrites that file;
- `--authenticated-emails-file` on the **oauth-proxy** sidecar, which is what
  actually enforces the list.

Plus a ClusterRole + ClusterRoleBinding, scoped with `resourceNames` to exactly
the Groups you listed — the sidecar can read those and nothing else, and cannot
even list Groups:

```sh
oc get clusterrole temporal-temporal-ui-groups -o yaml
```

> Why an allowlist file rather than asking OpenShift "is this user in the
> group": oauth-proxy has no group check. Its `--openshift-group` flag is
> defined in the source but never read — it is dead code, do not use it.

## 7. Verify

**The sidecar resolved the group:**

```sh
oc logs deploy/temporal-ui -c group-sync -n temporal
# => group-sync: allowlist updated (N entries)

oc exec deploy/temporal-ui -c oauth-proxy -n temporal -- cat /etc/proxy/allowed/users
# => alice@cluster.local
#    bob@cluster.local
# the same members as:
oc get group redbull -o jsonpath='{.users}{"\n"}'
```

**The entries carry the `@cluster.local` suffix.** That is not cosmetic. The
openshift provider rewrites every login to `<username>@<usernameDomain>` and
validates *that* string, so a file of bare usernames matches nobody — and
matching nobody does not deny everybody. Check the suffix your cluster
actually issues and set `ui.auth.usernameDomain` to it:

```sh
oc logs deploy/temporal-ui -c oauth-proxy -n temporal | grep 'authentication complete'
# => ... authentication complete Session{alice@cluster.local token:true}
#                                              ^^^^^^^^^^^^^^ must match the file
```

**The email-domain rule is pinned off:**

```sh
oc get deploy temporal-ui -n temporal \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="oauth-proxy")].args[*]}{@}{"\n"}{end}' \
  | grep email-domain
# => --email-domain=disabled.invalid
```

oauth-proxy admits an identity that matches the emails file **OR** ends in an
accepted email domain. Under `--provider=openshift` the default domain rule
accepts every login, which swallows the file check whole: the allowlist looks
configured and gates nothing. The unmatchable domain forces the decision onto
the file. If this flag is missing, the deployment predates the fix — upgrade
before trusting any of the browser checks below.

**oauth-proxy is watching the file:**

```sh
oc logs deploy/temporal-ui -c oauth-proxy -n temporal | grep watching
# => watching /etc/proxy/allowed/users for updates
```

**Browser checks — all four must hold:**

| Who | Expected |
|---|---|
| A member of `redbull` | logs in via the LDAP form, reaches the UI |
| A valid LDAP user not in the group | rejected |
| **A cluster-admin not in the group** | **rejected** |
| A member removed from the group mid-session | bounced to login within `refreshInterval` |

The third row is the one a SAR-based setup would fail. Test it explicitly —
and treat rows two and three as the acceptance test for the whole feature, not
a formality. A misconfigured allowlist fails *open* here, so "the right people
can log in" proves nothing on its own.

## 8. Operations

**Adding or removing people.** Change the LDAP group, let your `oc adm groups
sync` update the OpenShift Group, and the sidecar picks it up within
`refreshInterval`. No `helm upgrade`, no restart. Because oauth-proxy
re-validates on every proxied request rather than only at login, a removal ends
an active session instead of waiting for the cookie to expire.

**If the API is unreachable.** The sidecar logs
`group-sync: API read failed, keeping previous allowlist` and leaves the last
known-good list in place, so a transient blip cannot lock everyone out. It
retries on the next cycle.

**If someone reports being rejected:**

```sh
# 1. Are they in the OpenShift Group at all?
oc get group redbull -o jsonpath='{.users}{"\n"}' | tr ' ' '\n' | grep -i <user>

# 2. Is the Group current, or is the LDAP sync stale?
oc get group redbull -o jsonpath='{.metadata.annotations}{"\n"}'

# 3. What does the sidecar see?
oc logs deploy/temporal-ui -c group-sync -n temporal --tail=20

# 4. What did oauth-proxy decide?
oc logs deploy/temporal-ui -c oauth-proxy -n temporal | grep -i 'permission denied'
```

Username matching is case-insensitive, so LDAP case differences are not the
cause.

## 9. Someone who should be rejected gets in — checks

Run these **in order** on the air-gapped cluster. Each one narrows the cause;
stop when a check fails. Substitute your namespace for `temporal` and your
group name for `redbull`.

```sh
NS=temporal
GROUP=redbull
```

### 9.1 What is actually deployed

The repo is not the cluster. Read the release's real values and the proxy's
real arguments before anything else.

```sh
oc -n $NS get deploy temporal-ui \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="oauth-proxy")].args[*]}{@}{"\n"}{end}'
```

The live Deployment is the authority — read it first, whatever installed it.
For the values behind it:

```sh
# helm install:
helm -n $NS get values temporal

# Argo CD (`helm get values` returns nothing — Argo applies manifests, it does
# not create a Helm release). Read the Application instead:
oc -n openshift-gitops get application <app> \
  -o jsonpath='{.spec.source.repoURL}{"@"}{.spec.source.targetRevision}{"\n"}{.spec.source.helm}{"\n"}'
```

Confirm the Application points at the chart revision you think it does, and
check for `spec.syncPolicy.automated.prune` — with pruning off, objects from a
pre-auth release (an extra Route, an old Service) survive forever. See 9.6.

Two things to look for in the argument list:

- **`--authenticated-emails-file=/etc/proxy/allowed/users` must be present.**
  Missing means the release rendered with `allowedUsers` *and* `allowedGroups`
  empty, and oauth-proxy is admitting every authenticated cluster user by
  design. That is the whole bug — set `allowedGroups`/`allowedUsers` and
  upgrade.
- **`--email-domain` must be absent.** `--email-domain=*` admits everyone
  regardless of the allowlist file. The chart never sets it; a hand-edited
  Deployment might.

### 9.2 What the proxy is enforcing right now

```sh
oc -n $NS exec deploy/temporal-ui -c oauth-proxy -- cat /etc/proxy/allowed/users
```

- **The entries are bare usernames** (`alice`, not `alice@cluster.local`) →
  this is the bug, and the gate has never rejected anyone. See §7: oauth-proxy
  validates `<user>@<usernameDomain>`, so the file matches nobody, and its
  domain rule then admits everybody. Fix by upgrading to a chart that sets
  `ui.auth.usernameDomain` and pins `--email-domain`, then re-test with an
  account that should be denied.
- **The user who got in is listed** → the allowlist is being enforced
  correctly and the list itself is wrong. Go to 9.3 and 9.4.
- **The file is empty** → the list is empty because the Group could not be
  read (9.3/9.5). An empty list is *supposed* to deny everyone, so if people
  are still getting in there are two possible reasons and 9.6 tells them
  apart: the requests bypass the proxy, or this oauth-proxy build is not
  enforcing the file at all.
- **`exec` fails / container restarting** → check 9.5.

### 9.3 Where those names came from — the Group

**This env has no LDAP, so nothing maintains this Group.** `oc adm groups sync`
is an LDAP-only command; without it a Group object only exists if someone
created it by hand, and its membership is frozen at whatever they typed.

```sh
oc get group $GROUP -o jsonpath='{.users}{"\n"}'
oc get groups
```

- **Group missing** → the sidecar cannot resolve it (confirm in 9.5) and falls
  back to the previous allowlist, which after a fresh start is empty.
- **Group contains people who should not have access** → this is the answer.
  Fix the membership; the sidecar picks it up within `refreshInterval`:

  ```sh
  oc adm groups remove-users $GROUP <user>
  # or rebuild it from scratch (`new` fails if the Group already exists):
  oc delete group $GROUP
  oc adm groups new $GROUP <user1> <user2>
  ```

### 9.4 Where those names came from — the static list

`allowedUsers` is merged into the same file and is easy to forget.

```sh
oc -n $NS get cm temporal-ui-allowed-users -o jsonpath='{.data.users}{"\n"}'
```

A break-glass account left here admits that user no matter what the Group says.

### 9.5 Is the sync working

```sh
oc -n $NS logs deploy/temporal-ui -c group-sync --tail=30
oc -n $NS logs deploy/temporal-ui -c oauth-proxy | grep -iE 'watching|invalid session|permission denied' | tail -20
```

| Log line | Meaning |
|---|---|
| `group-sync: allowlist updated (N entries)` | working |
| `group-sync: cannot read group <g>: ...` | Group missing, or the ClusterRole does not cover it — see below |
| `group-sync: API read failed, keeping previous allowlist` | the list on disk is stale, not current |
| `watching /etc/proxy/allowed/users for updates` | oauth-proxy did pick up the file |

If the Group name in values does not match the ClusterRole's `resourceNames`
(a rename without a `helm upgrade`), the read is denied:

```sh
oc get clusterrole temporal-temporal-ui-groups -o jsonpath='{.rules[0].resourceNames}{"\n"}'
```

### 9.6 Is the traffic even passing through oauth-proxy

This is the check that explains "the allowlist is empty but people still get
in". The UI container listens on `:8080` with no authentication of its own; the
proxy only protects the path that goes through it.

```sh
# The Route must target the proxy port with reencrypt TLS.
oc -n $NS get route temporal-ui \
  -o jsonpath='{.spec.port.targetPort}{" "}{.spec.tls.termination}{"\n"}'
# expected: proxy reencrypt

# The Service must expose ONLY the proxy port.
oc -n $NS get svc temporal-ui -o jsonpath='{.spec.ports[*].name}{"\n"}'
# expected: proxy      (an "http" entry here is an auth bypass)

# Any second Route or Ingress pointing at the UI — including leftovers from a
# pre-auth release that Argo CD never pruned?
oc get route,ingress -A | grep -i temporal

# Every pod behind the Service must be a current, three-container one.
oc -n $NS get endpoints temporal-ui -o wide
oc -n $NS get pods -l app.kubernetes.io/component=ui \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name,AGE:.metadata.creationTimestamp'
```

Then watch the proxy while the test user loads the page:

```sh
oc -n $NS logs -f deploy/temporal-ui -c oauth-proxy
```

A page that loads while this log stays silent did not go through the proxy at
all — a stale Route, a hand-made Route, or a `port-forward`.

If instead the log **does** show the request and the user is still admitted
while the allowlist file is empty, the proxy itself is doing the admitting.
Populate the list (9.3, or switch to `allowedUsers` per 9.9), then re-run 9.7
with an account that is *not* on it and confirm it now returns 403. That
re-test is the only thing that proves this build enforces the file at all — if
an unlisted account still returns 200 with a populated list, the allowlist
mechanism is not working on this image and no amount of list-editing will gate
anything.

### 9.7 Per-user test without a browser

The definitive check: does the proxy admit *this specific account*.

```sh
ROUTE="https://$(oc -n $NS get route temporal-ui -o jsonpath='{.spec.host}')"

oc login -u <user> -p <password>
curl -sk -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $(oc whoami -t)" "$ROUTE/"
# 200 = admitted, 403 = rejected by the allowlist
```

Repeat for the htpasswd cluster-admin, a plain user, and a real group member.
Check the username the cluster actually knows each account by — that string,
not the login you typed, is what oauth-proxy matches against the file:

```sh
oc whoami
```

If every account returns `302` to the login page instead, this oauth-proxy
build is not accepting bearer tokens — use a private browser window per account
instead, and read the verdict from the log in 9.6.

### 9.8 In-cluster bypass

Not how a browser gets in, but worth closing while you are here: any other pod
in the cluster can reach `temporal-ui:8080` directly, and the gRPC frontend on
`:7233` is unauthenticated.

```sh
oc -n $NS get networkpolicy
```

Empty means nothing is stopping that. Set `networkPolicy.enabled: true`.

### 9.9 Recommended shape for an env with no LDAP

Group sync exists to track an LDAP-backed Group. With no LDAP there is nothing
to track — a hand-maintained Group is just a list of names kept in a second
place, with a sidecar, a ClusterRole and a ClusterRoleBinding to read it. Drop
all three and keep the list in values:

```yaml
ui:
  auth:
    enabled: true
    allowedGroups: []
    allowedUsers: ["alice", "bob"]
```

oauth-proxy then reads the ConfigMap directly and still re-checks it on every
request, so `helm upgrade` with a changed list applies live — no rollout, and a
removed user's open session ends on their next click.

## 10. Scope — what this does not cover

This authenticates the **UI Route only**.

- Everyone who passes sees the **full UI**. There are no per-user roles.
- The Temporal **gRPC frontend (`:7233`) stays unauthenticated** for in-cluster
  clients. Workers and SDK clients are unaffected by any of this.
- In-cluster callers can still reach the UI pod's plain HTTP port directly.
  The Service stops exposing it, but the pod listens on all interfaces.
  `networkPolicy.enabled: true` closes that (README "Network policy").
- An open session is re-validated against OpenShift every
  `ui.auth.cookieRefresh` (1h) and expires after `ui.auth.cookieExpire`
  (24h); the group allowlist itself is checked on every request.

Per-user authorization inside Temporal, or authentication on the gRPC frontend,
would require Temporal's own JWT claim-mapper auth against a JWT-issuing OIDC
provider. OpenShift's OAuth server issues **opaque** tokens, not JWTs, so it
cannot serve that path — it would need Keycloak (LDAP user federation) or Dex
(LDAP connector). Out of scope for this chart.

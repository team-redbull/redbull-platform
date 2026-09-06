# dhcp-scope-manager (chart)

> This chart is deployed by the `redbull-services` ApplicationSet from this repo
> (`gitops/services/dhcp-scope-manager/app.yaml`). Its `values.yaml` here is the single source of
> truth for the running configuration — no other values file is layered on top.


Helm chart for the **DHCP Scope Manager API**, deployed by Argo CD via
`redbull-platform`'s `redbull-services` ApplicationSet.

The API runs on **Linux** and drives a **Windows** DHCP server remotely over
PSRP/WinRM — the Windows host is not managed by this platform. Crossplane
`provider-http` consumes the API in-cluster through its Service.

| | |
|---|---|
| Code repo | `team-redbull/dhcp_scope_manager` |
| Image | `ghcr.io/team-redbull/dhcp-scope-manager` |
| Argo app | `gitops/services/prod/dhcp-scope-manager` in `redbull-platform` |
| Namespace | `dhcp-scope-manager` |

`image.repository` / `image.tag` in `values.yaml` are **owned by CI** — the
reusable `ghcr-build-push.yml` bumps them on every push to the code repo. Do not
pin them by hand in the platform's per-service `values.yaml`, or the deployment
sticks on a stale tag.

## Required configuration

`dhcp.serverHost` must be set, and with `winrm.auth: ntlm` a Secret must supply
the password. Both are enforced at render time (`templates/_helpers.tpl`), so a
misconfiguration fails the Argo sync rather than producing pods that return 503.

The password never lives in git. Create the Secret out of band:

```bash
oc create secret generic dhcp-scope-manager-winrm \
  --from-literal=winrm-password='...' -n dhcp-scope-manager
```

See `gitops/SECRETS.md` in `redbull-platform` for the Vault/ESO plan that will
populate this Secret later without changing the chart.

## No Namespace template

Deliberate, and load-bearing: `redbull-platform`'s `namespaces` release
pre-creates the namespace and stamps the `argocd.argoproj.io/managed-by` label
that grants the namespaced GitOps instance its RBAC. A chart that also templated
the Namespace would hit a Helm ownership conflict. See that repo's CLAUDE.md.

## Probes

Liveness is a **TCP** check; readiness uses `/healthz`. That split is
intentional: `/healthz` performs a real PSRP round trip to the Windows host, so
wiring it to liveness would restart the pod whenever that remote host blipped —
turning someone else's outage into a crash-loop it cannot fix.

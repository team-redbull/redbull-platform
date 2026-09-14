# operator-olm

Generic OLM operator install: **OperatorGroup + Subscription**. Nothing else.

**Never deployed on its own.** There is deliberately no
`gitops/services/operator-olm/app.yaml` — this chart is vendored as a subchart into each
`gitops/charts/<operator>/` chart, which supplies the operator-specific values and owns
the operator's configuration CR.

## Consuming it

```yaml
# gitops/charts/<operator>/Chart.yaml
dependencies:
  - name: operator-olm
    version: 0.1.0
    repository: ""        # already-present; see "Vendoring" below
```

```yaml
# gitops/charts/<operator>/values.yaml
operator-olm:
  subscription:
    name: <olm-package-name>     # `oc get packagemanifest -n openshift-marketplace`
    namespace: <operator-ns>
    channel: stable
  operatorGroup:
    targetNamespaces:
      - <operator-ns>            # see the AllNamespaces trap below
```

`source` / `sourceNamespace` are **inherited** — this cluster runs one shared catalog
(`gitops/charts/generic-cs`) and the defaults already point at it.

Then run `./vendor.sh` from the repo root to drop the packaged artifact into the
consumer's `charts/`.

## Checklist for a new operator

1. `gitops/charts/<operator>/` — Chart.yaml (with the dependency), values.yaml, and any
   config CR in `templates/` at **sync-wave 10 or higher**.
2. `gitops/services/<operator>/app.yaml` — with `namespace:`.
3. `charts/namespaces/values.yaml` — add the namespace. `CreateNamespace` is off and the
   `namespaces` Helmfile release is the sole owner of every namespace (see CLAUDE.md).
4. `./vendor.sh` to materialise the subchart.

## Sync waves

| Wave | Object | Argo health check |
|---|---|---|
| 0 | OperatorGroup | none → Healthy on apply |
| 1 | Subscription | **built-in** → a real gate |
| 10+ | the consumer's config CRs | depends on the CRD |

This chart owns waves **0–9**. Consumers start at **10**.

Wave 1 genuinely gates: Argo reports a Subscription Healthy only at
`status.state == AtLatestKnown`, so a config CR at wave 10 is applied against a cluster
that already has the CRD. Keep `argocd.argoproj.io/sync-options:
SkipDryRunOnMissingResource=true` on those config CRs anyway — there is a real window
where the CRD is registered but the operator's validating webhook is not yet serving.
Do **not** put that annotation on the two objects this chart renders; the
`operators.coreos.com` CRDs ship with every OpenShift cluster.

## Traps

**One OperatorGroup per namespace.** A second one puts *every* CSV in that namespace into
`TooManyOperatorGroups` and breaks all operator installs there — not just yours, and not
recoverable by retry. Set `operatorGroup.enabled: false` in any chart installing into a
namespace another chart already owns. `openshift-operators` is handled automatically (it
ships a global OperatorGroup, so nothing is rendered there).

**An empty `targetNamespaces` means AllNamespaces**, not "default". A CSV supporting only
OwnNamespace/SingleNamespace — OpenShift Virtualization, for one — then fails to install.
Always set it explicitly.

**`installPlanApproval: Manual` stalls under GitOps.** The Subscription sits at
`InstallPlanPending`, Argo reports Progressing, and no later wave ever runs, so the
consumer's config CRs are never applied. Nothing here approves an InstallPlan,
deliberately — a self-approving Job defeats the point of choosing `Manual`.

**Lists replace, they do not merge.** A consumer setting `targetNamespaces` replaces the
default wholesale; it can never append.

**Uninstalling is not `git rm`.** Deleting the Subscription removes only the standing
intent — the CSV, the CRDs, the operator Deployment and every operand keep running.
Deleting the Argo app leaves the operator installed. Uninstall is
`oc delete subscription` → `oc delete csv` → CRDs by hand, in that order.

**Operator-mutated config CRs go perpetually `OutOfSync`.** Many operators default dozens
of spec fields. The fix is `spec.ignoreDifferences`, which lives on the *Application* —
the `overrides:` block in `gitops/services/<operator>/app.yaml` — not in the chart.

## Two operators from one copy

Helm `alias` lets one consumer install two operators from a single vendored subchart:

```yaml
dependencies:
  - {name: operator-olm, version: 0.1.0, repository: "", alias: cnv}
  - {name: operator-olm, version: 0.1.0, repository: "", alias: nmstate}
```

with values under `cnv:` and `nmstate:`. Object names derive from
`subscription.name`, not `.Release.Name`, precisely so the two do not collide. If both
aliases target the **same** namespace, exactly one may set `operatorGroup.enabled: true`.

## Vendoring

`repository: ""` marks the dependency as already-present, so `helm dependency build`
never tries to resolve it — and it must not, because on the air-gapped GitLab each chart
is its own repo under the `helm-charts` group, with no shared checkout. A consumer chart
directory has to be copyable to its own repo root verbatim, which is why the artifact is
committed rather than referenced by `file://`. No `Chart.lock` is committed.

**Never run `helm dependency build` in this repo.**

# APPLY-HC-DEFAULTS — fewer values per hosted-cluster file

Standalone apply guide for one change across the three day-1 repos. Today
every hosted-cluster file repeats values that are the same across the fleet,
or that something else in the file already says: its own name,
`platform: agent`, `hostInventory: inventory`, three `'''`-quoted labels and a
three-line `agentLabelSelector` per nodepool, a `workertag` equal to
`mastertag`, and an `mcFiles` list that is the nodepools' `configs` again.
After this change those are **defaults**. A cluster file holds what is
specific to the cluster, and any default is overridden by writing the key.

**One cluster file, the part people write** (CI and the segment-allocation
workflow still append their blocks below it):

Before — the mirror's `cluster-storage-test.yaml`, 52 lines:

```yaml
clusterName: test-storage-site-a-a

owner:
  merkaz: "7180"
  anaf: "890"
  mador: "894"

platform: agent

hostInventory: inventory

mastertag: 4.22.8-x86_64
  
nodepool:
- name: test-storage-site-a-a-dell-r660-site-a-128c-1024gb-5tb
  replicas: 2
  labels:
    maxReplicas: '''2'''
    minReplicas: '''1'''
    allowDeletion: '''false'''
  agentLabelSelector:
    nodeLabelKey: infraenvs.agent-install.openshift.io
    nodeLabelValue: dell-r660-site-a-128c-1024gb-5tb
  configs:
  - name: nm-conf-test-storage-site-a-a-dell-data
  - name: worker-kubeletconfig-reserved
  - name: nic-ring-buffer
  - name: workers-chrony-configuration
  workertag: 4.22.8-x86_64

- name: test-storage-site-a-a-kubevirt-site-a-32c-256gb
  replicas: 0
  labels:
    maxReplicas: '''0'''
    minReplicas: '''0'''
    allowDeletion: '''false'''
  agentLabelSelector:
    nodeLabelKey: infraenvs.agent-install.openshift.io
    nodeLabelValue: kubevirt-site-a-32c-256gb
  configs:
  - name: nm-conf-test-storage-site-a-a-kubevirt
  - name: worker-kubeletconfig-reserved
  - name: nic-ring-buffer
  - name: workers-chrony-configuration
  workertag: 4.22.8-x86_64

mcFiles:
- nm-conf-test-storage-site-a-a-dell-data
- nm-conf-test-storage-site-a-a-kubevirt
- nic-ring-buffer
- worker-kubeletconfig-reserved
- workers-chrony-configuration
```

After — the same file as `ocp4-test-storage-site-a-a.yaml`, slimmed by the
script, 27 lines; with the new chart it renders exactly the same objects as the
file before:

```yaml
owner:
  merkaz: "7180"
  anaf: "890"
  mador: "894"

mastertag: 4.22.8-x86_64
  
nodepool:
- infraEnvName: dell-r660-site-a-128c-1024gb-5tb
  replicas: 2
  labels:
    allowDeletion: false
  configs:
  - name: nm-conf-test-storage-site-a-a-dell-data
  - name: worker-kubeletconfig-reserved
  - name: nic-ring-buffer
  - name: workers-chrony-configuration

- infraEnvName: kubevirt-site-a-32c-256gb
  replicas: 0
  labels:
    allowDeletion: false
  configs:
  - name: nm-conf-test-storage-site-a-a-kubevirt
  - name: worker-kubeletconfig-reserved
  - name: nic-ring-buffer
  - name: workers-chrony-configuration
```

`mastertag: 4.22.8` would do just as well: the chart adds `-x86_64` to a bare
version. The script leaves tags as they are written.

**The defaults** (write a key only when its value differs):

| Key | Default | Comes from |
|---|---|---|
| `clusterName` | the file name minus `.yaml` and `ocp4-` | `hcAppset.yaml` helm parameter; CI: `resolve_cluster_name` |
| `platform` | Agent. Written only as `platform: kubevirt` | chart (`hc.yaml`, `nodepool.yaml`) |
| `hostInventory` | `inventory` | chart `values.yaml` |
| `mastertag` | none, required. `4.22.8` and `4.22.8-x86_64` are both fine: a bare `X.Y.Z` gets `-x86_64` | chart `_helpers.tpl` (`hc.releaseTag`); CI accepts both |
| `workertag` (top level) | `mastertag`. Written only during an upgrade (§10); bare `X.Y.Z` allowed as for `mastertag` | chart `nodepool.yaml` |
| `mcFiles` | every `nodepool[*].configs[*].name`, first-seen order, each once. A written `mcFiles` replaces the list completely | CI: `resolve_mc_files` |
| `nodepool[].name` | `<clusterName>-<infraEnvName>` | chart |
| `nodepool[].infraEnvName` | none, required on the agent platform. It is the `infraenvs.agent-install.openshift.io` label value; `agentLabelSelector` still works, and is only needed for another label key | chart |
| `nodepool[].labels.allowDeletion` | `"false"` — but **keep `allowDeletion: false` written in every nodepool**: it is the nodepool's visible safety switch, and the slim script never removes it | chart |
| `nodepool[].labels.maxReplicas` | `replicas` | chart |
| `nodepool[].labels.minReplicas` | `replicas - 1`, never below 0 | chart |
| `nodepool[].workertag` | the top-level `workertag`, else `mastertag` (bare `X.Y.Z` allowed) | chart |
| `nodepool[].nodeDrainTimeout` | `0s` (drain without a time limit — what an unset field already means) | chart |

**Do the labels need `'''`?** Not any more. `'''8'''` is YAML for the string
`'8'` *with* the quotes; the old template needed that because a label value
must be a string and it printed the value bare. The chart now quotes every
label itself, so `maxReplicas: 8` and `allowDeletion: false` work as written,
and the old `'''8'''` spelling keeps working (the quotes are stripped). The
slim script rewrites the labels it keeps to the plain spelling.

**What changes where:**

| Repo | Change | Live effect |
|---|---|---|
| `helm-charts/hostedclusters-setup` | nodepool defaults, nil-safe `platform`, `hostInventory` default, bare `X.Y.Z` tags completed with `-x86_64`, `replicas: 0` fix | two, by design (§2) |
| `gitops-day1/argocd-platform` | `hcAppset.yaml` passes `clusterName` as a helm parameter | none |
| `gitops-day1/platform-config` | CI reads `clusterName` / `mcFiles` through two defaults; new migration script `slim_hc_values.py`; docs | none |
| cluster files | slimmed MCE by MCE with the script | none |

> `<chart>` below is a `helm-charts/hostedclusters-setup` checkout,
> `<platform>` a `gitops-day1/argocd-platform` checkout, `<config>` a
> `gitops-day1/platform-config` checkout. "On an MCE" means `oc` logged in to
> that MCE hub, where its hosted-cluster Applications live in
> `openshift-gitops`.

Everything below was applied to the stack-export mirror and verified there
(§7.5). The mirror is sanitized: names, hosts and some syntax differ from the
air-gap, which is why §1 checks your real files first and every patch is
checked before it is applied.

---

## 1. Before you start — checks to run in the air-gap

Run every check before you change anything. **Do not start §3 until all are
green or their fix is applied.**

### Check 1 — tooling

```bash
helm version --short                        # -> v3.x or later
python3 -c 'import yaml; print(yaml.__version__)'   # -> a version (the CI image has pyyaml)
git --version
```

### Check 2 — the audit (read-only)

Save this as `hc_audit.py` anywhere and run it from `<config>`. It reads the
cluster files and prints one section per question; it writes nothing.

<details><summary><code>hc_audit.py</code></summary>

```python
#!/usr/bin/env python3
"""Read-only audit of the hosted-cluster files before the defaults change.

Run from a platform-config checkout: python3 hc_audit.py [prefix]
Prints one section per check in APPLY-HC-DEFAULTS.md §1. Changes nothing.
"""
import collections
import glob
import os
import re
import sys

import yaml

PREFIX = sys.argv[1] if len(sys.argv) > 1 else "ocp4-"
KEY = "infraenvs.agent-install.openshift.io"


def load(path):
    return (yaml.safe_load(open(path)) or {}) if os.path.isfile(path) else {}


files = sorted(glob.glob("sites/*/mces/*/hostedClusters/*.yaml"))
print(f"cluster files: {len(files)}")

bad_names, cn_mismatch, mc_diff, dup_names, dup_keys = [], [], [], [], []
platforms = collections.Counter()
np_total = np_convention = no_drain = 0
zero_replicas, other_keys = [], []
for f in files:
    d = load(f)
    keys = re.findall(r'^([A-Za-z_][\w-]*):', open(f).read(), re.M)
    twice = sorted({k for k in keys if keys.count(k) > 1})
    if twice:
        dup_keys.append(f"{f}: {', '.join(twice)}")
    stem = os.path.basename(f)[:-len(".yaml")]
    if not stem.startswith(PREFIX):
        bad_names.append(f)
    cn = d.get("clusterName")
    derived = stem[len(PREFIX):] if stem.startswith(PREFIX) else stem
    if cn and cn != derived:
        cn_mismatch.append(f"{f}: clusterName {cn!r}, file name derives {derived!r}")
    platforms[str(d.get("platform", "<unset>"))] += 1
    union, names = [], []
    for np in d.get("nodepool") or []:
        np_total += 1
        sel = np.get("agentLabelSelector") or {}
        ie = np.get("infraEnvName") or sel.get("nodeLabelValue")
        if sel.get("nodeLabelKey", KEY) != KEY:
            other_keys.append(f"{f}: {np.get('name')} uses nodeLabelKey {sel['nodeLabelKey']}")
        if np.get("name") == f"{cn or derived}-{ie}":
            np_convention += 1
        names.append(np.get("name"))
        if "nodeDrainTimeout" not in np:
            no_drain += 1
        if np.get("replicas") == 0:
            zero_replicas.append(f"{f}: {np.get('name')}")
        for c in np.get("configs") or []:
            if c.get("name") not in union:
                union.append(c.get("name"))
    if d.get("mcFiles") is not None and set(d["mcFiles"]) != set(union):
        listed = set(d["mcFiles"])
        mc_diff.append(f"{f}: " + " ".join([f"+{n}" for n in sorted(listed - set(union))] +
                                          [f"-{n}" for n in sorted(set(union) - listed)]))
    for n, c in collections.Counter(names).items():
        if c > 1:
            dup_names.append(f"{f}: {n!r} x{c}")


def section(title, items, ok):
    print(f"\n[{title}] {len(items)}{'' if items else '  ' + ok}")
    for item in items:
        print(f"    {item}")


section("1 files not named " + PREFIX + "*", bad_names, "-> ok")
section("2 clusterName differs from the file name (these keep clusterName)", cn_mismatch, "-> ok")
cv = load("sites/configValues.yaml")
layers = collections.Counter()
for path in glob.glob("sites/*/values.yaml") + glob.glob("sites/*/mces/*/values.yaml"):
    for key in ("platform", "hostInventory", "workertag"):
        if key in load(path):
            layers[f"{path}: {key}={load(path)[key]}"] += 1
print(f"\n[4] platform in cluster files: {dict(platforms)}")
print(f"    configValues.yaml: platform={cv.get('platform', '<unset>')} "
      f"hostInventory={cv.get('hostInventory', '<unset>')} workertag={cv.get('workertag', '<unset>')}")
for line in sorted(layers):
    print(f"    {line}")
section("6c top-level key written twice (YAML keeps the last; fix by hand before step d)",
        dup_keys, "-> ok")
section("6 mcFiles differ from the nodepool configs (these keep mcFiles)", mc_diff, "-> ok")
print(f"\n[6b] nodepools: {np_total}; named <clusterName>-<infraEnvName>: {np_convention}; "
      f"the rest keep their name")
section("6b duplicate nodepool names inside one file", dup_names, "-> ok")
section("6b nodepools with a nodeLabelKey other than " + KEY + " (keep agentLabelSelector)",
        other_keys, "-> ok")
print(f"\n[7a] nodepools without nodeDrainTimeout (the chart adds 0s): {no_drain}")
section("7b nodepools with replicas: 0 (scale 1 -> 0 at the chart MR; owner sign-off)",
        zero_replicas, "-> none")
```

</details>

```bash
cd <config> && python3 /path/to/hc_audit.py
```

| Section | Good result | Otherwise |
|---|---|---|
| `[1] files not named ocp4-*` | `0` | Those files keep `clusterName` (the script does that by itself). **Never rename a cluster file to fix it**: the Application name is the file name, and a renamed file is a new Application |
| `[2] clusterName differs from the file name` | `0` | Same: these files keep `clusterName` for good. It is the cluster's identity (`hcp-<name>`, every secret, DNS record and the DHCP scope name derive from it) |
| `[4] platform …` | cluster files: only `agent`, `kubevirt` or unset. `configValues.yaml` is shown with its `platform` / `hostInventory` / `workertag`, and every site/MCE `values.yaml` that sets one is listed | A layer setting `platform` / `hostInventory` / `workertag` is fine — the slim script compares against what each file inherits. A `platform` other than agent/kubevirt renders as Agent today and still will; the script only removes `agent`, so it stays |
| `[6c] top-level key written twice` | `0` | YAML keeps the **last** occurrence, so the first is dead text. The slim script refuses these files. Delete the dead block by hand (after checking which one renders today), then slim |
| `[6] mcFiles differ from the nodepool configs` | `0` (expected in the air-gap) | Listed files keep their `mcFiles`. `+name` = in `mcFiles`, no nodepool uses it; `-name` = a nodepool uses it, `mcFiles` lacks it. Review them separately; this guide never changes them |
| `[6b] nodepools …named <clusterName>-<infraEnvName>` | any number | Information only. Every other nodepool keeps its `name`: a renamed NodePool is deleted and recreated, nodes and all |
| `[6b] duplicate nodepool names inside one file` | `0` | They render as today (Argo keeps the last of the duplicates). Fix separately |
| `[6b] … nodeLabelKey other than …` | `0` | Those nodepools keep `agentLabelSelector` |
| `[7a] nodepools without nodeDrainTimeout` | any number — note it | These NodePools get `nodeDrainTimeout: 0s` at step a (§2). It is the count you will see in §7.2 |
| `[7b] nodepools with replicas: 0` | `none` | **Each listed NodePool runs one node today** (`replicas: 0` rendered as `1`) and scales to 0 at step a — the node is drained and released. Get the owner's OK for each one, or change its `replicas` to `1` in a commit before step a |

### Check 3 — the `hcAppset.yaml` shape

```bash
cd <platform>
grep -c 'parameters:' hostedClusters/templates/hcAppset.yaml                       # -> 0
grep -c clusterFilePrefix hostedClusters/templates/hcAppset.yaml hostedClusters/values.yaml   # -> 0 and 0
```

| Output | Meaning | What to do |
|---|---|---|
| as shown | the mirror's shape | §5.1 |
| `parameters:` is `1` | the connected-side shape (the DHCP port passes `clusterName`, `site`, `mce`) | §5.2 — and read its warning first |
| `clusterFilePrefix` non-zero | this guide was (partly) applied | compare with §5 by hand |

### Check 4 — the patches apply

§4, §5 and §6 give each patch as one block per file. Save a heading's blocks,
in order, into the one file the heading names, in the repo they belong to, then:

```bash
cd <chart>    && git apply --check chart.patch
cd <platform> && git apply --check platform.patch          # §5.1 only
cd <config>   && git apply --check config-scripts.patch config-new.patch config-docs.patch
```

All silent = good. A rejected hunk means your file differs from the mirror's
around it: apply that hunk by hand, each is small and self-describing.
`git apply --ignore-whitespace` helps when only trailing spaces differ
(`hcAppset.yaml` has a `{{- end}}  ` line with two).

### Check 5 — `nodeDrainTimeout` semantics, on one MCE

```bash
oc explain nodepool.spec.nodeDrainTimeout
# -> "...The default value is 0, meaning that the node can be drained without any time limitations..."
```

That is why defaulting it to `0s` changes nothing for the nodes. If your
HyperShift says otherwise, stop and drop the `nodeDrainTimeout` default from
§4 (keep the old `{{- if .nodeDrainTimeout }}` block).

### Check 6 — Argo's Helm, on one MCE

```bash
oc -n openshift-gitops exec deploy/openshift-gitops-repo-server -- helm version --short
```

Any v3 works. (Unset `platform` already renders `type: Agent` with a modern
Helm; the chart's `| default ""` guard also covers the old Helm 3 builds that
fail `eq` on a missing value.)

### Check 7 — nothing else reads the removed keys

day2 reads the day-1 cluster files as value files (`ref: day1`). It must only
use `mastertag` from them:

```bash
cd <argocd-day2-platform>
grep -rhoE '\.Values\.[A-Za-z]+' operators clusters | sort -u
# -> no clusterName, platform, hostInventory, workertag, mcFiles or nodepool
```

Then the other tools that read `platform-config` (the workflows orchestrator,
`dhcp_scope_manager`'s CI validator, anything else your team runs):

```bash
grep -rnE 'mcFiles|hostInventory|workertag|agentLabelSelector|nodeLabelValue' <each repo> | grep -v test
# -> nothing that reads them from a hosted-cluster file
```

In the connected copies, the orchestrator only appends `vlanId`/`dhcp_values`
by file name, and `cluster-navigator` reads live objects, not files.

day2 also hands the whole cluster file to every team chart as a values file.
A team chart that uses the tag itself would see `4.22.8` instead of
`4.22.8-x86_64` once someone writes the short form:

```bash
grep -rnE '\.Values\.(mastertag|workertag)' <every day2 team chart repo>
# -> nothing (day2's own templates only take the version before the first '-')
```

---

## 2. Why this is safe

**Explicit values always win.** Every default is "the file's value, else X".
The one new helm parameter, `clusterName`, passes the file's own
`clusterName` when it has one. A parameter outranks every values file, so
passing anything else would override it.

**Every existing file renders the same, with two exceptions by design.** In
the mirror, today's setup (old chart, no parameter) against the new one (new
chart plus the `clusterName` parameter), over all 51 cluster files, gives
exactly the following. It also shows that the parameter equals what every
file renders today:

```
  44  NodePool  spec.nodeDrainTimeout  '<absent>' -> '0s'
   2  NodePool  spec.replicas  1 -> 0
```

- `nodeDrainTimeout: 0s` is added where it was unset, which is what unset
  already meant (check 5). It is a drain setting: no node is replaced.
- `replicas: 0` NodePools stop being rendered as `1` (check 2 `[7b]`). This
  is the one change that removes nodes, which is why each needs an owner's OK.

Label values render as `"8"` where they rendered as `'8'`. That is the same
string, and Argo compares objects, not text. Tags written with `-x86_64` are
used as written; a bare `4.22.8` renders exactly like `4.22.8-x86_64`.

**Nothing is renamed.**
- Application names stay the full file name; only the parameter strips `ocp4-`.
- `clusterName` stays what it is for every file (check 2 `[2]`).
- NodePool names: every existing name stays written unless it already equals
  the derived name.

**The chart's new guards fail the render, never a live object.** These
conditions stop the render, Argo shows ComparisonError for that one app, and
nothing is applied:
- `infraEnvName` and `agentLabelSelector.nodeLabelValue` disagree.
- A nodepool on the agent platform has no infraEnv; without one it would
  claim any free Agent.
- Two nodepools derive the same name.

**CI treats a slimmed file like any changed file.**
- The chain runs for it.
- `filter_frozen.py` gives the same verdict as before: in the mirror, all 51
  verdicts are identical on the slimmed files.
- A frozen cluster stays untouched. An included one is regenerated from the
  same sources; only the order of its `mcConfigMap` entries may follow the
  nodepool order.

---

## 3. Order of work and gates

Steps a, b and c are independent of each other: each one is a no-op for files
that still carry their explicit values. Step d needs all three live.

| Step | What | Gate before the next step |
|---|---|---|
| a | §4, the chart MR | **before merge:** §7.2 shows only the two expected changes, with counts equal to check 2's `[7a]` and `[7b]`, and every `[7b]` NodePool has its owner's OK. **After merge:** §9.1 on each MCE |
| b | §6, the platform-config MR (scripts, the new script, docs) | **before merge:** `python3 -m pytest tests/ -q` shows no new failures (§6.4), and `python3 scripts/validate_all_clusters.py` passes |
| c | §5, the argocd-platform MR | **before merge:** §7.3 shows no differences. **After merge:** §9.2 on each MCE |
| d | §8, slimming, one MR per MCE | **before merge:** the script reports no errors; §7.4 shows no differences; CI is green. **After merge:** §9.3 |

**Rollback.**
- **a, b, c:** revert the MR. While the cluster files are not slimmed, each
  revert is a no-op for the clusters. The exception is a `[7b]` NodePool: it
  goes back to 1 replica, so a node is provisioned again.
- **After d:** revert the slimming MRs **first**, then a, b or c. A slimmed
  file without the defaults it relies on fails to render (a, ComparisonError),
  derives the wrong `clusterName` (c), or loses its `mcFiles` (b).

---

## 4. Chart — `helm-charts/hostedclusters-setup` → `chart.patch`

Four files, one block each. Together, in order, they are `chart.patch`.

**`values.yaml`:** `hostInventory: inventory`.

```diff
diff --git a/values.yaml b/values.yaml
--- a/values.yaml
+++ b/values.yaml
@@ -1,3 +1,6 @@
+# Namespace the hosted cluster's Agents come from (spec.platform.agent.agentNamespace).
+hostInventory: inventory
+
 scheduler:
   config:
     mastersSchedulable: false
```

**`templates/_helpers.tpl` (new):** `hc.releaseTag`, which completes a bare
`X.Y.Z` with `-x86_64`.

```diff
diff --git b/templates/_helpers.tpl b/templates/_helpers.tpl
new file mode 100644
--- /dev/null
+++ b/templates/_helpers.tpl
@@ -0,0 +1,13 @@
+{{/*
+A release tag as a cluster file writes it (mastertag, workertag), completed:
+a bare X.Y.Z (4.22.8) gets the -x86_64 arch suffix of the mirrored release
+images; anything else (4.22.8-x86_64, another arch) is used as written.
+*/}}
+{{- define "hc.releaseTag" -}}
+{{- $tag := toString (. | default "") -}}
+{{- if regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+$" $tag -}}
+{{- printf "%s-x86_64" $tag -}}
+{{- else -}}
+{{- $tag -}}
+{{- end -}}
+{{- end -}}
```

**`templates/hc.yaml`:** the nil-safe `platform` test, and `mastertag`
through `hc.releaseTag`.

```diff
diff --git a/templates/hc.yaml b/templates/hc.yaml
--- a/templates/hc.yaml
+++ b/templates/hc.yaml
@@ -1,3 +1,4 @@
+{{- $mastertag := include "hc.releaseTag" .Values.mastertag -}}
 {{- $ICSdefaults := .Values.defaultImageContentSources | default (list) -}}
 {{- $ICSextras := .Values.imageContentSources | default (list) -}}
 {{- $ICS := concat $ICSdefaults $ICSextras | uniq -}}
@@ -26,9 +27,9 @@ metadata:
   annotations:
     argocd.argoproj.io/sync-wave: "2"
     {{- if not .Values.imageHc }}
-    hypershift.openshift.io/control-plane-operator-image: {{ .Values.imagePath }}/openshift/release:{{ .Values.mastertag }}-hypershift
+    hypershift.openshift.io/control-plane-operator-image: {{ .Values.imagePath }}/openshift/release:{{ $mastertag }}-hypershift
     {{- else }}
-    hypershift.openshift.io/control-plane-operator-image: {{ .Values.imageHc }}/openshift/release:{{ .Values.mastertag }}-hypershift
+    hypershift.openshift.io/control-plane-operator-image: {{ .Values.imageHc }}/openshift/release:{{ $mastertag }}-hypershift
     {{- end }}
   name: openshift-{{ .Values.clusterName }}
   namespace: hcp-{{ .Values.clusterName }}
@@ -42,9 +43,9 @@ spec:
   fips: false
   release:
     {{- if not .Values.imageHc }}
-    image: "{{ .Values.imagePath }}/openshift/release-images:{{ .Values.mastertag }}"
+    image: "{{ .Values.imagePath }}/openshift/release-images:{{ $mastertag }}"
     {{- else }}
-    image: "{{ .Values.imageHc }}/openshift/release-images:{{ .Values.mastertag }}"
+    image: "{{ .Values.imageHc }}/openshift/release-images:{{ $mastertag }}"
     {{- end }}    
   dns:
     baseDomain: {{ .Values.baseDomain | default "example.internal" }}
@@ -66,7 +67,7 @@ spec:
 {{- toYaml .Values.imageContentSources | nindent 4}} 
 {{- end }}
   platform:
-    {{- if eq .Values.platform "kubevirt" }}
+    {{- if eq (.Values.platform | default "") "kubevirt" }}
     kubevirt:
       credentials:
         infraKubeConfigSecret:
```

**`templates/nodepool.yaml`:**
- The defaults table above.
- The `replicas: 0` fix: `spec.replicas` honours an explicit 0, using the same
  `hasKey` rule as the labels.
- `workertag` through `hc.releaseTag`.
- The three guards from §2.

```diff
diff --git a/templates/nodepool.yaml b/templates/nodepool.yaml
--- a/templates/nodepool.yaml
+++ b/templates/nodepool.yaml
@@ -1,26 +1,55 @@
 {{- $clusterName := .Values.clusterName}}
-{{- $platform := .Values.platform}}
+{{- $platform := .Values.platform | default "" }}
 {{- $imagePath := .Values.imagePath }}
 {{- $vlanId := .Values.vlanId }}
+{{- /* Workers follow mastertag unless pinned: a cluster-level workertag pins every
+       nodepool (written only during an upgrade, masters first), a nodepool's own
+       workertag pins just that one. */}}
+{{- $workertag := .Values.workertag | default .Values.mastertag }}
+{{- /* name -> was it derived; catches two nodepools deriving the same name. */}}
+{{- $seen := dict }}
 {{- range .Values.nodepool }}
+{{- $labels := .labels | default dict }}
+{{- $selector := .agentLabelSelector | default dict }}
+{{- $infraEnv := .infraEnvName | default $selector.nodeLabelValue }}
+{{- if and .infraEnvName $selector.nodeLabelValue (ne .infraEnvName $selector.nodeLabelValue) }}
+{{- fail (printf "nodepool %q: infraEnvName %q and agentLabelSelector.nodeLabelValue %q disagree. Set only infraEnvName." (.name | default .infraEnvName) .infraEnvName $selector.nodeLabelValue) }}
+{{- end }}
+{{- if not (or .name $infraEnv) }}
+{{- fail "every nodepool needs infraEnvName (its name derives as <clusterName>-<infraEnvName>) or an explicit name." }}
+{{- end }}
+{{- $derived := not .name }}
+{{- $name := .name | default (printf "%s-%s" $clusterName $infraEnv) }}
+{{- if and (ne $platform "kubevirt") (not $infraEnv) }}
+{{- fail (printf "nodepool %q: infraEnvName is required on the agent platform; without it the nodepool would claim any free Agent." $name) }}
+{{- end }}
+{{- if and (hasKey $seen $name) (or $derived (get $seen $name)) }}
+{{- fail (printf "nodepool name %q is used twice. A derived name is <clusterName>-<infraEnvName>, so nodepools sharing an infraEnv must each set name." $name) }}
+{{- end }}
+{{- $_ := set $seen $name $derived }}
+{{- /* hasKey rather than default throughout: an explicit 0 or false must win. */}}
+{{- $replicas := ternary .replicas 1 (hasKey . "replicas") | int }}
+{{- $allowDeletion := ternary $labels.allowDeletion "false" (hasKey $labels "allowDeletion") }}
+{{- $maxReplicas := ternary $labels.maxReplicas $replicas (hasKey $labels "maxReplicas") }}
+{{- $minReplicas := ternary $labels.minReplicas (max 0 (sub $replicas 1)) (hasKey $labels "minReplicas") }}
 ---
 apiVersion: hypershift.openshift.io/v1beta1
 kind: NodePool
 metadata:
   annotations:
     argocd.argoproj.io/sync-wave: "4"
-  name: {{ .name }}
+  name: {{ $name }}
   namespace: hcp-{{ $clusterName }}
   finalizers:
     - hypershift.openshift.io/finalizer 
   labels:
-    allowDeletion: {{ toString .labels.allowDeletion | default "false" }}
-    maxReplicas: {{ .labels.maxReplicas | default .replicas | toString }}
-    minReplicas: {{ .labels.minReplicas | default .replicas | toString }}
+    {{- /* Label values must be strings. quote makes them so; trimAll keeps the
+           older '''8''' spelling (a value that carries its own quotes) working. */}}
+    allowDeletion: {{ $allowDeletion | toString | trimAll "'" | quote }}
+    maxReplicas: {{ $maxReplicas | toString | trimAll "'" | quote }}
+    minReplicas: {{ $minReplicas | toString | trimAll "'" | quote }}
 spec:
-  {{- if .nodeDrainTimeout }}
-  nodeDrainTimeout: {{ .nodeDrainTimeout }}
-  {{- end }}
+  nodeDrainTimeout: {{ .nodeDrainTimeout | default "0s" }}
   {{- if .nodeVolumeDetachTimeout }}
   nodeVolumeDetachTimeout: {{ .nodeVolumeDetachTimeout }}
   {{- end }}
@@ -63,16 +92,14 @@ spec:
     type: KubeVirt
   {{- else }}
     agent:
-      {{- if .agentLabelSelector.nodeLabelKey }}
       agentLabelSelector:
         matchLabels:
-          {{ .agentLabelSelector.nodeLabelKey }}: {{ .agentLabelSelector.nodeLabelValue }}
-      {{- end }}
+          {{ $selector.nodeLabelKey | default "infraenvs.agent-install.openshift.io" }}: {{ $infraEnv }}
     type: Agent
   {{- end }}
   release:
-    image: "{{ $imagePath }}/openshift/release-images:{{ .workertag }}"
-  replicas: {{ .replicas | default "1" }}
+    image: "{{ $imagePath }}/openshift/release-images:{{ include "hc.releaseTag" (.workertag | default $workertag) }}"
+  replicas: {{ $replicas }}
   {{- if .nodeLabels }}
   nodeLabels:
   {{- range $key, $value := .nodeLabels }}
```

---

## 5. Platform — `gitops-day1/argocd-platform`

### 5.1 `platform.patch` — the mirror's shape (check 3: `parameters:` is `0`)

The parameter goes in front of `valueFiles` (key order inside `helm:` does not
matter), so the hunk's context holds no repo URL.

`hostedClusters/templates/hcAppset.yaml`:

```diff
diff --git a/hostedClusters/templates/hcAppset.yaml b/hostedClusters/templates/hcAppset.yaml
--- a/hostedClusters/templates/hcAppset.yaml
+++ b/hostedClusters/templates/hcAppset.yaml
@@ -27,6 +27,13 @@ spec:
           releaseName: {{ .Values.folder }}
         {{- end}}  
           ignoreMissingValueFiles: true
+          # clusterName: the file's own clusterName when it sets one, otherwise the file
+          # name without .yaml and clusterFilePrefix. A parameter outranks every value
+          # file, so the file's own value is passed through instead of being overridden.
+          parameters:
+            - name: clusterName
+              value: '{{"{{"}}index . "clusterName" | default (.path.filename | trimSuffix ".yaml" | trimPrefix "{{ .Values.clusterFilePrefix }}"){{"}}"}}'
+              forceString: true
           valueFiles:
             - $values/sites/configValues.yaml
             - $values/sites/{{ .Values.site }}/values.yaml
```

`hostedClusters/values.yaml`:

```diff
diff --git a/hostedClusters/values.yaml b/hostedClusters/values.yaml
--- a/hostedClusters/values.yaml
+++ b/hostedClusters/values.yaml
@@ -2,6 +2,12 @@
 # This is a YAML-formatted file.
 # Declare variables to be passed into your templates.
 
+# Hosted-cluster files are named <clusterFilePrefix><clusterName>.yaml; hcAppset strips
+# the prefix to pass clusterName to the chart when a file does not set its own.
+# platform-config's scripts/generate_from_template.py carries the same prefix as
+# CLUSTER_FILE_PREFIX — change one, change both.
+clusterFilePrefix: ocp4-
+
 # This will set the replicaset count more information can be found here: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
 replicaCount: 1
 
```

Rendered, the parameter reads (`helm template x hostedClusters --set site=<site>,mce=<mce>`):

```yaml
parameters:
  - name: clusterName
    value: '{{index . "clusterName" | default (.path.filename | trimSuffix ".yaml" | trimPrefix "ocp4-")}}'
    forceString: true
```

The git-files generator exposes the file's own top-level keys, so
`index . "clusterName"` is the file's `clusterName` when it sets one.
`index` (not `.clusterName`) is what keeps a file without it from failing
under `missingkey=error`.

### 5.2 The connected-side shape (check 3: `parameters:` is `1`)

> **Warning.** If `parameters:` holds
> `- name: clusterName` with `value: '{{ "{{" }}.path.filename | trimSuffix ".yaml" …'`,
> that parameter already **overrides** every file's `clusterName` with the
> full file name, `ocp4-` included. If that is live, your clusters' names
> carry the prefix today. Re-run check 2 `[2]` with
> `python3 hc_audit.py ''` (empty prefix) and talk to the cluster owners
> before going further. A wrong `clusterName` renames every object of the
> cluster.

If it is not live yet (or check 2 is clean either way), edit by hand:
replace that entry's `value:` line with the one from §5.1, keep its
`forceString: true` and the other entries, and add the `clusterFilePrefix`
block from §5.1 to `hostedClusters/values.yaml`.

---

## 6. Values repo — `gitops-day1/platform-config`

### 6.1 `config-scripts.patch` — the CI scripts

These two functions in `generate_from_template.py`, next to its other shared
helpers, are now the only readers of `clusterName` and `mcFiles`:
- `resolve_cluster_name(data, yaml_file)`
- `resolve_mc_files(data)`

`inject_configs.py`, `filter_frozen.py` and `verify_missing_configs.py` call
them. `CLUSTER_FILE_PREFIX = 'ocp4-'` must match `clusterFilePrefix` in §5.

`validate_mastertag` accepts a bare `X.Y.Z` as well as `X.Y.Z-ARCH`; the
butane version it derives is the same.

`validate_all_clusters.py` also gets a one-line fix. It staged each cluster
in `<tmp>/<file stem>`, so two MCEs holding a file of the same name crashed
it; it now uses a unique temp dir, as `filter_frozen.py` already does.

`scripts/generate_from_template.py`:

```diff
diff --git a/scripts/generate_from_template.py b/scripts/generate_from_template.py
--- a/scripts/generate_from_template.py
+++ b/scripts/generate_from_template.py
@@ -6,7 +6,9 @@ Usage:
     python scripts/generate_from_template.py <sites_yaml_file> [<sites_yaml_file> ...]
 
 The script will:
-1. Validate each sites YAML file (clusterName, mastertag, vlanId when needed)
+1. Validate each sites YAML file (mastertag, vlanId when needed); clusterName
+   and mcFiles default from the file name and the nodepool configs
+   (resolve_cluster_name, resolve_mc_files)
 2. For each mcFile, find the matching template in mc-files/templates/
    (or copy a static file from mc-files/, root or subfolder)
 3. Replace placeholders (VLAN_ID, CLUSTER_NAME, OPENSHIFT_VERSION)
@@ -38,8 +40,14 @@ TEMPLATES_DIR = Path('mc-files/templates')
 MC_FILES_DIR = Path('mc-files')
 CI_HEADER = "# === Added by CI ==="
 
-# Pattern for validating mastertag format: X.Y.Z-ARCH (e.g., 4.20.12-x86_64)
-MASTERTAG_PATTERN = re.compile(r'^\d+\.\d+\.\d+-[a-zA-Z0-9_]+$')
+# Hosted-cluster files are named <CLUSTER_FILE_PREFIX><clusterName>.yaml. Must
+# match clusterFilePrefix in argocd-platform's hostedClusters/values.yaml: the
+# appset strips the same prefix to pass clusterName to the chart.
+CLUSTER_FILE_PREFIX = 'ocp4-'
+
+# Pattern for validating mastertag format: X.Y.Z-ARCH (e.g., 4.20.12-x86_64),
+# or a bare X.Y.Z (4.20.12) — the chart completes that with -x86_64.
+MASTERTAG_PATTERN = re.compile(r'^\d+\.\d+\.\d+(-[a-zA-Z0-9_]+)?$')
 
 # Butane header of an OpenShift .bu file: group 1 anchors the rewrite,
 # group 2 is the version the file would render at.
@@ -103,6 +111,39 @@ def is_false_value(value):
     return False
 
 
+def resolve_cluster_name(data, yaml_file):
+    """The cluster's name, as the chart receives it from the appset.
+
+    The file's own clusterName when it sets one, otherwise the file name minus
+    .yaml and CLUSTER_FILE_PREFIX — the same expression hcAppset.yaml passes
+    as the clusterName parameter.
+    """
+    if data.get('clusterName'):
+        return str(data['clusterName'])
+    stem = Path(yaml_file).stem
+    if stem.startswith(CLUSTER_FILE_PREFIX):
+        return stem[len(CLUSTER_FILE_PREFIX):]
+    return stem
+
+
+def resolve_mc_files(data):
+    """The config names to render: mcFiles when the file lists them,
+    otherwise every nodepool's configs, in first-seen order, each once.
+
+    Nodepools of one cluster often share configs; the chart renders one
+    ConfigMap per name, so a name shared by several nodepools appears once.
+    """
+    if data.get('mcFiles') is not None:
+        return list(data['mcFiles'])
+    names = []
+    for nodepool in data.get('nodepool') or []:
+        for config in (nodepool or {}).get('configs') or []:
+            name = config.get('name') if isinstance(config, dict) else None
+            if name and name not in names:
+                names.append(name)
+    return names
+
+
 def add_ci_header(yaml_file):
     """Append the CI header to a YAML file if it is not already present."""
     with open(yaml_file, 'r', encoding='utf-8') as f:
@@ -131,13 +172,13 @@ def validate_mastertag(mastertag):
     if not mastertag:
         raise ValueError("mastertag is empty or None")
 
-    if not MASTERTAG_PATTERN.match(mastertag):
+    if not MASTERTAG_PATTERN.match(str(mastertag)):
         raise ValueError(
             f"Invalid mastertag format: '{mastertag}'. "
-            f"Expected format: X.Y.Z-ARCH (e.g., '4.20.12-x86_64')"
+            f"Expected format: X.Y.Z-ARCH or X.Y.Z (e.g., '4.20.12-x86_64' or '4.20.12')"
         )
 
-    version_parts = mastertag.split('-')[0].split('.')
+    version_parts = str(mastertag).split('-')[0].split('.')
     return f"{version_parts[0]}.{version_parts[1]}.0"
 
 
@@ -149,7 +190,7 @@ def validate_cluster_yaml(data, yaml_file):
     Raises ValueError on validation failure.
     Returns a tuple of (cluster_name, vlan_id, openshift_version).
     """
-    cluster_name = data.get('clusterName')
+    cluster_name = resolve_cluster_name(data, yaml_file)
     if not cluster_name:
         raise ValueError(f"clusterName missing in {yaml_file}")
 
@@ -300,9 +341,9 @@ def process_yaml_file(yaml_file, template_map=None):
         logger.error(f"Validation failed for {yaml_file}: {e}")
         return False
 
-    mc_files = data.get('mcFiles', [])
+    mc_files = resolve_mc_files(data)
     if not mc_files:
-        logger.warning(f"mcFiles missing in {yaml_file}")
+        logger.warning(f"no mcFiles and no nodepool configs in {yaml_file}")
         return False
 
     # Names already in the cluster's mcConfigMap: their static sources are
```

`scripts/inject_configs.py`:

```diff
diff --git a/scripts/inject_configs.py b/scripts/inject_configs.py
--- a/scripts/inject_configs.py
+++ b/scripts/inject_configs.py
@@ -16,7 +16,8 @@ import verify_missing_configs
 # generate_from_template.py owns the shared YAML-error formatter and the
 # CI-header constant (it appends the same header for manual-allocation
 # clusters).
-from generate_from_template import format_yaml_error, CI_HEADER
+from generate_from_template import (format_yaml_error, CI_HEADER,
+                                    resolve_cluster_name, resolve_mc_files)
 
 
 def find_file_in_directory(base_dir, target_name):
@@ -131,12 +132,12 @@ def process_target_files():
             print(f"Error: Expected dictionary in {target_file}")
             sys.exit(1)
 
-        mc_files = data.get('mcFiles') or []
+        mc_files = resolve_mc_files(data)
         if not mc_files:
-            print("No mcFiles found. Clearing mcConfigMap.")
+            print("No mcFiles and no nodepool configs found. Clearing mcConfigMap.")
             mc_config_map = []
         else:
-            cluster_name = data.get('clusterName')
+            cluster_name = resolve_cluster_name(data, target_file)
             mc_config_map, missing = build_mc_config_map(
                 mc_files, converted_dir, non_butane_dir, cluster_name)
             if missing:
```

`scripts/filter_frozen.py`:

```diff
diff --git a/scripts/filter_frozen.py b/scripts/filter_frozen.py
--- a/scripts/filter_frozen.py
+++ b/scripts/filter_frozen.py
@@ -51,9 +51,11 @@ from pathlib import Path
 import yaml
 
 # Same-directory reuse: the payload comparator (verify_missing_configs), the
-# env-line writer (get_changed_clusters), and the generator (staged in temp).
+# env-line writer (get_changed_clusters), the clusterName/mcFiles defaults
+# (generate_from_template), and the generator itself (staged in temp).
 from verify_missing_configs import normalize, _decode
 from get_changed_clusters import format_env_line
+from generate_from_template import resolve_cluster_name, resolve_mc_files
 
 REPO_ROOT = Path(__file__).resolve().parent.parent
 GENERATE_SCRIPT = Path(__file__).resolve().parent / "generate_from_template.py"
@@ -146,7 +148,7 @@ def classify(cluster_file, work_root):
     if not isinstance(data, dict):
         return NEEDS_DECISION, ["not a YAML mapping"]
 
-    mc_files = data.get('mcFiles') or []
+    mc_files = resolve_mc_files(data)
     entries = {e.get('name'): e.get('config') for e in (data.get('mcConfigMap') or [])
                if isinstance(e, dict)}
     lines = []
@@ -180,7 +182,7 @@ def classify(cluster_file, work_root):
         return NEEDS_DECISION, [
             f"generation failed: {(result.stderr or result.stdout).strip().splitlines()[-1]}"]
 
-    staged_dir = work_dir / "mc-files" / str(data.get('clusterName'))
+    staged_dir = work_dir / "mc-files" / resolve_cluster_name(data, cluster_file)
     verdict = FROZEN
     for name, config in sorted(entries.items()):
         source = None
```

`scripts/verify_missing_configs.py`:

```diff
diff --git a/scripts/verify_missing_configs.py b/scripts/verify_missing_configs.py
--- a/scripts/verify_missing_configs.py
+++ b/scripts/verify_missing_configs.py
@@ -150,10 +150,11 @@ def main():
 
     # Late import: reuse inject's by-name lookup without a circular import
     from inject_configs import load_config_content
+    from generate_from_template import resolve_mc_files
 
     with open(target_file, 'r') as f:
         data = yaml.safe_load(f)
-    mc_files = data.get('mcFiles') or []
+    mc_files = resolve_mc_files(data)
     existing = {e.get('name'): e.get('config') for e in (data.get('mcConfigMap') or [])
                 if isinstance(e, dict)}
     unresolved = [n for n in mc_files
```

`scripts/validate_all_clusters.py`:

```diff
diff --git a/scripts/validate_all_clusters.py b/scripts/validate_all_clusters.py
--- a/scripts/validate_all_clusters.py
+++ b/scripts/validate_all_clusters.py
@@ -65,7 +65,9 @@ def stage_work_dir(work_root, cluster_file, repo_root):
     verify_output() can only pass on files this validation itself generated.
     All mutations (the CI header, mc-files/<cluster>/) land in the copy.
     """
-    work_dir = work_root / cluster_file.stem
+    # mkdtemp, not work_root/stem: two MCEs may hold a cluster file of the same
+    # name (ocp4-<clusterName>.yaml), and copytree onto an existing dir crashes.
+    work_dir = Path(tempfile.mkdtemp(dir=str(work_root), prefix=f"{cluster_file.stem}-"))
     mc_files_src = repo_root / "mc-files"
     mc_files_dst = work_dir / "mc-files"
     shutil.copytree(mc_files_src / "templates", mc_files_dst / "templates")
```

### 6.2 `config-new.patch` — the migration script and the tests

`scripts/slim_hc_values.py` (§8), `tests/test_hc_defaults.py` (the two
defaults, and generate / inject / the frozen filter on a file without
`clusterName` and `mcFiles`), `tests/test_slim_hc_values.py`.

<details><summary><code>scripts/slim_hc_values.py</code></summary>

```diff
diff --git b/scripts/slim_hc_values.py b/scripts/slim_hc_values.py
new file mode 100644
--- /dev/null
+++ b/scripts/slim_hc_values.py
@@ -0,0 +1,497 @@
+#!/usr/bin/env python3
+"""
+Remove values from hosted-cluster files that the chart, the appset or CI now
+default — only where removing them leaves the effective value unchanged.
+
+Usage:
+    python3 scripts/slim_hc_values.py [--write] [<cluster.yaml|glob> ...]
+
+Without arguments every sites/*/mces/*/hostedClusters/*.yaml is processed.
+Without --write nothing is written: the report says what would change.
+
+What is removed, and only when equal to what it defaults to:
+  clusterName        the file name minus .yaml and CLUSTER_FILE_PREFIX
+  hostInventory      the value inherited from the values layers, else inventory
+  platform           agent (any case), unless a values layer sets kubevirt
+  workertag          (top level) mastertag, when no values layer sets workertag
+  mcFiles            the nodepools' configs, compared as a set
+per nodepool:
+  agentLabelSelector -> one infraEnvName line (default nodeLabelKey only)
+  name               <clusterName>-<infraEnvName>, when no other nodepool
+                     in the file resolves to the same name
+  labels.*           maxReplicas = replicas, minReplicas = replicas - 1
+                     (never below 0). allowDeletion always stays, as the
+                     nodepool's visible safety switch; the labels that stay
+                     are rewritten without the old '''x''' quoting
+  workertag          the cluster's workertag (top level, else mastertag);
+                     tags compare as the chart completes them (4.22.8 is
+                     4.22.8-x86_64)
+  nodeDrainTimeout   0s
+
+Edits are line-based, so comments, the CI / workflow headers and the
+mcConfigMap block stay byte-identical. Before writing, the result is parsed
+back and its effective values (the four values layers merged as hcAppset
+passes them, chart and CI defaults applied) are compared with the original's.
+Any difference leaves that file untouched and fails the run.
+"""
+
+import argparse
+import glob
+import re
+import sys
+from pathlib import Path
+
+import yaml
+
+# Same-directory reuse: the clusterName/mcFiles defaults CI itself applies.
+from generate_from_template import (CLUSTER_FILE_PREFIX, format_yaml_error,
+                                    resolve_cluster_name, resolve_mc_files)
+
+ALL_CLUSTERS_GLOB = "sites/*/mces/*/hostedClusters/*.yaml"
+DEFAULT_NODE_LABEL_KEY = "infraenvs.agent-install.openshift.io"
+CHART_DEFAULTS = {'hostInventory': 'inventory'}
+
+TOP_KEY_RE = re.compile(r'^([A-Za-z_][\w-]*):(.*)$')
+LABEL_LINE_RE = re.compile(r'^(\s+)([\w-]+):\s*(.*?)\s*$')
+QUOTED_VALUE_RE = re.compile(r'''^('[^#]*'|"[^#]*")$''')
+
+
+# ---------------------------------------------------------------- values model
+
+def merge(base, override):
+    """Helm's coalesce for values files: maps merge, anything else replaces,
+    and a null in the higher layer deletes the key."""
+    result = dict(base)
+    for key, value in override.items():
+        if value is None:
+            result.pop(key, None)
+        elif isinstance(value, dict) and isinstance(result.get(key), dict):
+            result[key] = merge(result[key], value)
+        else:
+            result[key] = value
+    return result
+
+
+def values_layers(cluster_file):
+    """The values files hcAppset passes before the cluster file:
+    sites/configValues.yaml, sites/<site>/values.yaml, sites/<site>/mces/<mce>/values.yaml."""
+    mce_dir = cluster_file.parent.parent
+    site_dir = mce_dir.parent.parent
+    layers = []
+    for path in (site_dir.parent / "configValues.yaml", site_dir / "values.yaml",
+                 mce_dir / "values.yaml"):
+        if path.is_file():
+            layers.append(yaml.safe_load(path.read_text()) or {})
+    return layers
+
+
+def inherited(layers):
+    """What the cluster file inherits when it does not set a key."""
+    merged = dict(CHART_DEFAULTS)
+    for layer in layers:
+        merged = merge(merged, layer)
+    return merged
+
+
+def label_value(value):
+    """A label as the chart renders it: toString, then trimAll "'"."""
+    if isinstance(value, bool):
+        return 'true' if value else 'false'
+    return str(value).strip("'")
+
+
+def release_tag(tag):
+    """A tag as the chart's hc.releaseTag completes it: a bare X.Y.Z gets -x86_64."""
+    tag = '' if tag is None else str(tag)
+    return f"{tag}-x86_64" if re.fullmatch(r'\d+\.\d+\.\d+', tag) else tag
+
+
+def plain_label(raw):
+    """The label written without quoting ('''2''' -> 2), or None when the
+    plain spelling would not parse back to the same label value."""
+    text = label_value(raw)
+    try:
+        same = label_value(yaml.safe_load(f"v: {text}")['v']) == text
+    except yaml.YAMLError:
+        return None
+    return text if same else None
+
+
+def effective(data, cluster_file, layers):
+    """The values the chart and CI act on, with every default applied."""
+    values = inherited(layers)
+    values = merge(values, data)
+    values['clusterName'] = resolve_cluster_name(data, cluster_file)
+    values['mcFiles'] = sorted(set(resolve_mc_files(data)))
+    # Exact match, like the chart's `eq ... "kubevirt"`: anything else renders Agent.
+    values['platform'] = 'kubevirt' if values.get('platform') == 'kubevirt' else 'agent'
+    values['mastertag'] = release_tag(values.get('mastertag'))
+    workertag = values.pop('workertag', None) or values['mastertag']
+    nodepools = []
+    for nodepool in values.get('nodepool') or []:
+        nodepool = dict(nodepool or {})
+        selector = nodepool.pop('agentLabelSelector', None) or {}
+        infra_env = nodepool.pop('infraEnvName', None) or selector.get('nodeLabelValue')
+        replicas = int(nodepool.pop('replicas')) if 'replicas' in nodepool else 1
+        labels = dict(nodepool.pop('labels', None) or {})
+        nodepool.update({
+            'name': nodepool.get('name') or f"{values['clusterName']}-{infra_env}",
+            'selector': (selector.get('nodeLabelKey') or DEFAULT_NODE_LABEL_KEY, infra_env),
+            'replicas': replicas,
+            'labels': {
+                'allowDeletion': label_value(labels.pop('allowDeletion', 'false')),
+                'maxReplicas': label_value(labels.pop('maxReplicas', replicas)),
+                'minReplicas': label_value(labels.pop('minReplicas', max(0, replicas - 1))),
+                **labels,
+            },
+            'workertag': release_tag(nodepool.get('workertag') or workertag),
+            'nodeDrainTimeout': nodepool.get('nodeDrainTimeout') or '0s',
+        })
+        nodepools.append(nodepool)
+    values['nodepool'] = nodepools
+    return values
+
+
+# ---------------------------------------------------------------- what to drop
+
+def plan(data, cluster_file, layers):
+    """Decide what can go. Returns (top_keys, nodepool_plans, kept):
+    top_keys is a set of top-level keys to delete; nodepool_plans has one dict
+    per nodepool ({'selector': None|'convert'|'drop', 'drop': set,
+    'labels': set to remove, 'relabel': {key: plain value}});
+    kept lists human-readable reasons for values that stay."""
+    up = inherited(layers)
+    kept = []
+    top = set()
+
+    name = data.get('clusterName')
+    if name:
+        stem = cluster_file.stem
+        if stem == f"{CLUSTER_FILE_PREFIX}{name}":
+            top.add('clusterName')
+        else:
+            kept.append(f"clusterName '{name}': the file name derives "
+                        f"'{resolve_cluster_name({}, cluster_file)}'")
+
+    if 'hostInventory' in data and data['hostInventory'] == up.get('hostInventory'):
+        top.add('hostInventory')
+    if str(data.get('platform', '')).lower() == 'agent' and up.get('platform') != 'kubevirt':
+        top.add('platform')
+    if 'workertag' in data and 'workertag' not in up and \
+            release_tag(data['workertag']) == release_tag(data.get('mastertag')):
+        top.add('workertag')
+
+    if data.get('mcFiles') is not None:
+        derived = set(resolve_mc_files({'nodepool': data.get('nodepool')}))
+        listed = set(data['mcFiles'])
+        if listed == derived:
+            top.add('mcFiles')
+        else:
+            parts = [f"+{n}" for n in sorted(listed - derived)] + \
+                    [f"-{n}" for n in sorted(derived - listed)]
+            kept.append(f"mcFiles: differs from the nodepool configs ({' '.join(parts)})")
+
+    cluster = resolve_cluster_name(data, cluster_file)
+    cluster_workertag = data.get('workertag') or up.get('workertag') or data.get('mastertag')
+    nodepools = [np if isinstance(np, dict) else {} for np in data.get('nodepool') or []]
+
+    def infra_env(np):
+        return np.get('infraEnvName') or (np.get('agentLabelSelector') or {}).get('nodeLabelValue')
+
+    resolved = [np.get('name') or f"{cluster}-{infra_env(np)}" for np in nodepools]
+    plans = []
+    for i, np in enumerate(nodepools):
+        p = {'selector': None, 'drop': set(), 'labels': set(), 'relabel': {}}
+        selector = np.get('agentLabelSelector')
+        if isinstance(selector, dict) and set(selector) <= {'nodeLabelKey', 'nodeLabelValue'} \
+                and selector.get('nodeLabelValue') \
+                and selector.get('nodeLabelKey', DEFAULT_NODE_LABEL_KEY) == DEFAULT_NODE_LABEL_KEY \
+                and np.get('infraEnvName') in (None, selector['nodeLabelValue']):
+            # With infraEnvName already written, the selector only repeats it.
+            p['selector'] = 'convert' if np.get('infraEnvName') is None else 'drop'
+        if np.get('name') and infra_env(np):
+            if np['name'] != f"{cluster}-{infra_env(np)}":
+                kept.append(f"nodepool[{i}].name '{np['name']}': not <clusterName>-<infraEnvName>")
+            elif resolved.count(np['name']) > 1:
+                kept.append(f"nodepool[{i}].name '{np['name']}': another nodepool resolves to the same name")
+            else:
+                p['drop'].add('name')
+        replicas = int(np['replicas']) if 'replicas' in np else 1
+        labels = np.get('labels')
+        if isinstance(labels, dict):
+            defaults = {'maxReplicas': str(replicas), 'minReplicas': str(max(0, replicas - 1))}
+            for key, default in defaults.items():
+                if key in labels:
+                    if label_value(labels[key]) == default:
+                        p['labels'].add(key)
+                    else:
+                        kept.append(f"nodepool[{i}].labels.{key} {label_value(labels[key])!r}: "
+                                    f"default would be {default!r}")
+            for key in ('allowDeletion', 'maxReplicas', 'minReplicas'):
+                if key in labels and key not in p['labels'] and isinstance(labels[key], str):
+                    plain = plain_label(labels[key])
+                    if plain is not None and plain != labels[key]:
+                        p['relabel'][key] = plain
+        if 'workertag' in np and release_tag(np['workertag']) == release_tag(cluster_workertag):
+            p['drop'].add('workertag')
+        if np.get('nodeDrainTimeout') == '0s':
+            p['drop'].add('nodeDrainTimeout')
+        plans.append(p)
+    return top, plans, kept
+
+
+# ---------------------------------------------------------------- text edits
+
+def top_level_blocks(lines):
+    """{key: (start, end)} for top-level keys; end is exclusive. A block runs
+    over indented lines and column-0 sequence items; trailing blank lines and
+    column-0 comments (e.g. the CI header) are not part of it."""
+    blocks = {}
+    i = 0
+    while i < len(lines):
+        match = TOP_KEY_RE.match(lines[i])
+        if not match:
+            i += 1
+            continue
+        last = i
+        j = i + 1
+        while j < len(lines):
+            line = lines[j]
+            if line.strip() == '':
+                j += 1
+                continue
+            if line[0] in ' \t-':
+                last = j
+                j += 1
+                continue
+            break
+        blocks[match.group(1)] = (i, last + 1)
+        i = last + 1
+    return blocks
+
+
+def duplicate_top_keys(text):
+    """Top-level keys written twice. YAML keeps only the last, so the first
+    is dead text a line-based edit would leave behind half-slimmed."""
+    keys = [m.group(1) for m in map(TOP_KEY_RE.match, text.split('\n')) if m]
+    return sorted({k for k in keys if keys.count(k) > 1})
+
+
+def delete_block(lines, start, end):
+    """Delete lines[start:end] without leaving a double blank line behind."""
+    before_blank = start == 0 or lines[start - 1].strip() == ''
+    after = end
+    if before_blank and after < len(lines) and lines[after].strip() == '':
+        after += 1
+    del lines[start:after]
+
+
+def split_items(block):
+    """Split a nodepool block's lines (after the 'nodepool:' line) into items.
+    Returns (lead, items, indent): lines before the first item, a list of
+    line lists, and the items' dash indent; or None when the shape is not the
+    plain block style this script edits."""
+    starts = [i for i, line in enumerate(block) if re.match(r'^\s*- ', line)]
+    if not starts:
+        return None
+    indent = len(block[starts[0]]) - len(block[starts[0]].lstrip())
+    item_starts = [i for i in starts if len(block[i]) - len(block[i].lstrip()) == indent]
+    if any(block[i][indent + 2:].lstrip().startswith('{') for i in item_starts):
+        return None
+    bounds = item_starts + [len(block)]
+    items = [block[bounds[k]:bounds[k + 1]] for k in range(len(item_starts))]
+    return block[:item_starts[0]], items, indent
+
+
+def edit_item(item, indent, p):
+    """Apply one nodepool's plan to its lines. Returns the new lines, or None
+    when the item's layout is not one this script can edit safely."""
+    keycol = indent + 2
+    # Normalize the dash away so every key sits at keycol, then segment.
+    first = item[0]
+    lines = [first[:indent] + '  ' + first[indent + 2:]] + item[1:]
+    tail = []
+    while lines and lines[-1].strip() == '':
+        tail.insert(0, lines.pop())
+    segments = []
+    for line in lines:
+        stripped = line[keycol:] if line.startswith(' ' * keycol) else None
+        is_key = (stripped is not None and len(line) - len(line.lstrip()) == keycol
+                  and re.match(r'^[A-Za-z_][\w-]*:', stripped))
+        if is_key or not segments:
+            segments.append([re.match(r'^([A-Za-z_][\w-]*):', stripped).group(1) if is_key else None, [line]])
+        else:
+            segments[-1][1].append(line)
+
+    infra_line = None
+    out = []
+    for key, seg in segments:
+        if key == 'agentLabelSelector' and p['selector'] == 'drop':
+            continue
+        if key == 'agentLabelSelector' and p['selector']:
+            raw = next((m.group(1) for m in (re.match(r'^\s*nodeLabelValue:\s*(.*?)\s*$', l) for l in seg)
+                        if m), None)
+            if raw is None or seg[0].split(':', 1)[1].strip():
+                return None
+            infra_line = [' ' * keycol + f"infraEnvName: {raw}"]
+            out.append(['infraEnvName', infra_line])
+            continue
+        if key in p['drop']:
+            if len([l for l in seg if l.strip()]) != 1:
+                return None
+            continue
+        if key == 'labels' and (p['labels'] or p['relabel']):
+            if seg[0].split(':', 1)[1].strip():
+                if p['labels']:
+                    return None   # flow style: leave it
+                out.append([key, seg])
+                continue
+            body = []
+            for line in seg[1:]:
+                match = LABEL_LINE_RE.match(line)
+                if match and match.group(2) in p['labels']:
+                    continue
+                # Only a value that is one quoted scalar is respelled, so a
+                # trailing comment is never lost.
+                if match and match.group(2) in p['relabel'] and QUOTED_VALUE_RE.match(match.group(3)):
+                    line = f"{match.group(1)}{match.group(2)}: {p['relabel'][match.group(2)]}"
+                body.append(line)
+            if any(l.strip() for l in body):
+                out.append([key, [seg[0]] + body])
+            continue
+        out.append([key, seg])
+
+    if not out:
+        return None
+    if 'name' in p['drop']:
+        lead = next((k for k, (key, _) in enumerate(out) if key == 'infraEnvName'), 0)
+        out.insert(0, out.pop(lead))
+    head = out[0][1][0]
+    if not head.startswith(' ' * keycol):
+        return None
+    out[0][1][0] = ' ' * indent + '- ' + head[keycol:]
+    return [l for _, seg in out for l in seg] + tail
+
+
+def slim_text(text, top, plans):
+    """Apply the plan to the file's text. Returns the new text, or None when
+    the layout defeats a safe line-based edit."""
+    lines = text.split('\n')
+    blocks = top_level_blocks(lines)
+
+    if 'nodepool' in blocks and any(p['selector'] or p['drop'] or p['labels'] or p['relabel']
+                                    for p in plans):
+        start, end = blocks['nodepool']
+        split = split_items(lines[start + 1:end])
+        if split is None:
+            return None
+        lead, items, indent = split
+        if len(items) != len(plans):
+            return None
+        new_items = []
+        for item, p in zip(items, plans):
+            edited = edit_item(item, indent, p)
+            if edited is None:
+                return None
+            new_items.extend(edited)
+        lines[start + 1:end] = lead + new_items
+        blocks = top_level_blocks(lines)
+
+    for key in sorted(top, key=lambda k: blocks[k][0], reverse=True):
+        delete_block(lines, *blocks[key])
+    return '\n'.join(lines)
+
+
+# ---------------------------------------------------------------- driver
+
+def describe(top, plans):
+    """(removed, rewritten): report lines for what goes and what is respelled."""
+    removed = sorted(top)
+    rewritten = []
+    for i, p in enumerate(plans):
+        parts = sorted(p['drop'])
+        if p['selector']:
+            parts.append('agentLabelSelector' if p['selector'] == 'drop'
+                         else 'agentLabelSelector->infraEnvName')
+        if p['labels']:
+            parts.append(f"labels({','.join(sorted(p['labels']))})")
+        if parts:
+            removed.append(f"nodepool[{i}]: {' '.join(parts)}")
+        if p['relabel']:
+            rewritten.append(f"nodepool[{i}]: labels {','.join(sorted(p['relabel']))} "
+                             f"written without quotes")
+    return removed, rewritten
+
+
+def process(cluster_file, write):
+    """Returns 'changed', 'unchanged' or 'error'."""
+    text = cluster_file.read_text()
+    try:
+        data = yaml.safe_load(text)
+    except yaml.YAMLError as e:
+        print(f"ERROR {format_yaml_error(cluster_file, e)}")
+        return 'error'
+    if not isinstance(data, dict):
+        print(f"ERROR {cluster_file}: not a YAML mapping")
+        return 'error'
+    duplicates = duplicate_top_keys(text)
+    if duplicates:
+        print(f"ERROR {cluster_file}: top-level key written twice ({', '.join(duplicates)}); "
+              f"YAML keeps the last — delete the dead one by hand, then re-run")
+        return 'error'
+    layers = values_layers(cluster_file)
+    top, plans, kept = plan(data, cluster_file, layers)
+    removed, rewritten = describe(top, plans)
+    if not removed and not rewritten:
+        print(f"SAME  {cluster_file}")
+        for reason in kept:
+            print(f"  kept     {reason}")
+        return 'unchanged'
+
+    new_text = slim_text(text, top, plans)
+    if new_text is None:
+        print(f"ERROR {cluster_file}: layout not editable line by line — slim it by hand")
+        return 'error'
+    new_data = yaml.safe_load(new_text)
+    if effective(new_data, cluster_file, layers) != effective(data, cluster_file, layers):
+        print(f"ERROR {cluster_file}: self-check failed — the slimmed file would not "
+              f"render the same; left untouched")
+        return 'error'
+
+    print(f"{'WROTE' if write else 'WOULD'} {cluster_file}")
+    for item in removed:
+        print(f"  removed  {item}")
+    for item in rewritten:
+        print(f"  rewrote  {item}")
+    for reason in kept:
+        print(f"  kept     {reason}")
+    if write:
+        cluster_file.write_text(new_text)
+    return 'changed'
+
+
+def main(argv=None):
+    parser = argparse.ArgumentParser(description="Remove defaulted values from hosted-cluster files.")
+    parser.add_argument('--write', action='store_true', help="write the changes (default: report only)")
+    parser.add_argument('paths', nargs='*', help=f"cluster files or globs (default: {ALL_CLUSTERS_GLOB})")
+    args = parser.parse_args(argv)
+
+    files = []
+    for pattern in args.paths or [ALL_CLUSTERS_GLOB]:
+        files.extend(sorted(glob.glob(pattern)) or [pattern])
+    files = [Path(f) for f in dict.fromkeys(files)]
+    missing = [f for f in files if not f.is_file()]
+    if missing:
+        for f in missing:
+            print(f"ERROR {f}: no such file")
+        sys.exit(1)
+
+    results = [process(f, args.write) for f in files]
+    print(f"\n{len(files)} files: {results.count('changed')} "
+          f"{'slimmed' if args.write else 'to slim'}, {results.count('unchanged')} unchanged, "
+          f"{results.count('error')} errors")
+    sys.exit(1 if 'error' in results else 0)
+
+
+if __name__ == '__main__':
+    main()
```

</details>

<details><summary><code>tests/test_hc_defaults.py</code></summary>

```diff
diff --git b/tests/test_hc_defaults.py b/tests/test_hc_defaults.py
new file mode 100644
--- /dev/null
+++ b/tests/test_hc_defaults.py
@@ -0,0 +1,156 @@
+"""Tests for the clusterName / mcFiles defaults (generate_from_template's
+resolve_cluster_name and resolve_mc_files) and for the scripts that use them.
+
+A cluster file may omit clusterName (it derives from the file name minus .yaml
+and CLUSTER_FILE_PREFIX, as hcAppset.yaml passes it to the chart) and mcFiles
+(it derives from the nodepools' configs). Explicit values always win.
+"""
+
+import base64
+from pathlib import Path
+
+import pytest
+import yaml
+
+# conftest.py puts scripts/ on sys.path.
+import filter_frozen
+import generate_from_template as generator
+import inject_configs
+from generate_from_template import resolve_cluster_name, resolve_mc_files
+
+HOSTED_CLUSTERS = Path("sites/site-a/mces/cluster-mce-site-a/hostedClusters")
+
+
+class TestResolveClusterName:
+
+    def test_explicit_clusterName_wins(self):
+        assert resolve_cluster_name({'clusterName': 'given'}, 'x/ocp4-other.yaml') == 'given'
+
+    def test_prefix_stripped_from_file_name(self):
+        assert resolve_cluster_name({}, 'sites/a/ocp4-prod-tenant-4.yaml') == 'prod-tenant-4'
+
+    def test_file_name_without_prefix_is_kept(self):
+        assert resolve_cluster_name({}, 'cluster-tenant-4-prod.yaml') == 'cluster-tenant-4-prod'
+
+    def test_empty_clusterName_counts_as_unset(self):
+        assert resolve_cluster_name({'clusterName': ''}, 'ocp4-a.yaml') == 'a'
+
+
+class TestResolveMcFiles:
+
+    def test_explicit_mcFiles_win(self):
+        data = {'mcFiles': ['x'], 'nodepool': [{'configs': [{'name': 'y'}]}]}
+        assert resolve_mc_files(data) == ['x']
+
+    def test_explicit_empty_mcFiles_win(self):
+        assert resolve_mc_files({'mcFiles': [], 'nodepool': [{'configs': [{'name': 'y'}]}]}) == []
+
+    def test_union_in_first_seen_order_each_once(self):
+        data = {'nodepool': [
+            {'configs': [{'name': 'nm-conf-a'}, {'name': 'chrony'}]},
+            {'configs': [{'name': 'chrony'}, {'name': 'kubelet'}]},
+            {'configs': [{'name': 'nm-conf-a'}]},
+        ]}
+        assert resolve_mc_files(data) == ['nm-conf-a', 'chrony', 'kubelet']
+
+    def test_nodepools_without_configs(self):
+        assert resolve_mc_files({'nodepool': [{'replicas': 1}, None]}) == []
+        assert resolve_mc_files({}) == []
+
+
+class TestBareMastertag:
+    """mastertag may omit the -x86_64 suffix; the chart completes it."""
+
+    def test_bare_and_suffixed_give_the_same_butane_version(self):
+        assert generator.validate_mastertag('4.22.8') == '4.22.0'
+        assert generator.validate_mastertag('4.22.8-x86_64') == '4.22.0'
+
+    def test_still_rejects_a_partial_version(self):
+        with pytest.raises(ValueError):
+            generator.validate_mastertag('4.22')
+
+
+DERIVED_CLUSTER = """\
+AutomateAllocation: "false"
+mastertag: 4.16.27-x86_64
+vlanId: 422
+nodepool:
+- infraEnvName: dell-a
+  replicas: 1
+  configs:
+  - name: static-config
+- infraEnvName: dell-b
+  replicas: 1
+  configs:
+  - name: static-config
+"""
+
+
+def test_generate_derives_cluster_name_and_mc_files(run_in_repo_tmp):
+    """No clusterName and no mcFiles: output lands in mc-files/<name minus ocp4->/."""
+    path = run_in_repo_tmp / HOSTED_CLUSTERS / "ocp4-derived-cluster.yaml"
+    path.write_text(DERIVED_CLUSTER)
+
+    assert generator.process_yaml_file(str(path)) is True
+    assert (run_in_repo_tmp / "mc-files" / "derived-cluster" / "static-config.bu").exists()
+
+
+def test_inject_derives_cluster_name_and_mc_files(tmp_path, monkeypatch):
+    """mcConfigMap is filled from the nodepool configs, and the cluster's own
+    render copy is found under the derived name."""
+    cluster = tmp_path / "ocp4-derived-cluster.yaml"
+    cluster.write_text(
+        "nodepool:\n"
+        "- configs:\n  - name: own-config\n  - name: shared-config\n"
+        "- configs:\n  - name: shared-config\n")
+    converted = tmp_path / "converted"
+    (converted / "derived-cluster").mkdir(parents=True)
+    (converted / "derived-cluster" / "own-config.yaml").write_text("cluster copy")
+    (converted / "own-config.yaml").write_text("shared root render")
+    (converted / "shared-config.yaml").write_text("shared render")
+    monkeypatch.setenv("TARGET_YAML_FILES", str(cluster))
+    monkeypatch.setenv("CONVERTED_BUTANE_DIR", str(converted))
+    monkeypatch.setenv("NON_BUTANE_DIR", str(tmp_path / "non_butane"))
+
+    inject_configs.process_target_files()
+
+    entries = yaml.safe_load(cluster.read_text())['mcConfigMap']
+    assert [e['name'] for e in entries] == ['own-config', 'shared-config']
+    assert entries[0]['config'].strip() == "cluster copy"
+
+
+def test_filter_frozen_with_derived_mc_files(tmp_path, monkeypatch):
+    """A frozen cluster stays frozen when its mcFiles key is dropped: the derived
+    set equals its mcConfigMap entry names, and the staged copy is found under
+    the derived cluster name."""
+    fixtures = Path(__file__).parent / "fixtures"
+    (tmp_path / "mc-files" / "templates").mkdir(parents=True)
+    for f in (fixtures / "mc-files" / "templates").iterdir():
+        (tmp_path / "mc-files" / "templates" / f.name).write_text(f.read_text())
+    (tmp_path / "mc-files" / "static-config.bu").write_text(
+        (fixtures / "mc-files" / "static-config.bu").read_text())
+    monkeypatch.setattr(filter_frozen, "REPO_ROOT", tmp_path)
+    monkeypatch.chdir(tmp_path)
+
+    payload = base64.b64encode(b"static content").decode()
+    entry = yaml.safe_dump({
+        'apiVersion': 'machineconfiguration.openshift.io/v1',
+        'kind': 'MachineConfig',
+        'metadata': {'name': 'static-config'},
+        'spec': {'config': {
+            'ignition': {'version': '3.2.0'},
+            'storage': {'files': [{'path': '/etc/static-test', 'mode': 420,
+                                   'contents': {'source': f'data:;base64,{payload}'}}]}}},
+    }, sort_keys=True)
+    cluster = tmp_path / HOSTED_CLUSTERS / "ocp4-frozen-derived.yaml"
+    cluster.parent.mkdir(parents=True)
+    cluster.write_text(yaml.safe_dump({
+        'AutomateAllocation': "false",
+        'mastertag': '4.16.27-x86_64',
+        'vlanId': 422,
+        'nodepool': [{'infraEnvName': 'dell-a', 'configs': [{'name': 'static-config'}]}],
+        'mcConfigMap': [{'name': 'static-config', 'config': entry}],
+    }, sort_keys=False))
+
+    verdict, lines = filter_frozen.classify(cluster, tmp_path / "work")
+    assert verdict == filter_frozen.FROZEN, lines
```

</details>

<details><summary><code>tests/test_slim_hc_values.py</code></summary>

```diff
diff --git b/tests/test_slim_hc_values.py b/tests/test_slim_hc_values.py
new file mode 100644
--- /dev/null
+++ b/tests/test_slim_hc_values.py
@@ -0,0 +1,266 @@
+"""Tests for scripts/slim_hc_values.py.
+
+Each test writes a small sites/ tree into tmp_path (configValues, site and MCE
+values plus one cluster file) and runs the script on it. The contract pinned
+here: a value goes only when its default gives the same effective value, the
+rest of the file (the CI block above all) stays byte-identical, and a second
+run changes nothing.
+"""
+
+from pathlib import Path
+
+import pytest
+
+# conftest.py puts scripts/ on sys.path.
+import slim_hc_values as slim
+
+CI_BLOCK = """\
+# === Added by CI ===
+mcConfigMap:
+- name: nm-conf-a
+  config: |
+    kind: MachineConfig
+
+    spec: {}
+"""
+
+FULL = """\
+clusterName: demo
+
+owner:
+  merkaz: "1"
+
+platform: agent
+
+hostInventory: inventory
+
+mastertag: 4.16.27-x86_64
+
+nodepool:
+- name: demo-dell-a
+  replicas: 3
+  labels:
+    maxReplicas: '''3'''
+    minReplicas: '''2'''
+    allowDeletion: '''false'''
+  agentLabelSelector:
+    nodeLabelKey: infraenvs.agent-install.openshift.io
+    nodeLabelValue: dell-a
+  configs:
+  - name: nm-conf-a
+  - name: chrony
+  workertag: 4.16.27-x86_64
+  nodeDrainTimeout: 0s
+
+- name: zone-b
+  replicas: 2
+  labels:
+    maxReplicas: '''2'''
+    minReplicas: '''2'''
+    allowDeletion: '''false'''
+  agentLabelSelector:
+    nodeLabelKey: infraenvs.agent-install.openshift.io
+    nodeLabelValue: dell-b
+  configs:
+  - name: chrony
+  workertag: 4.16.20-x86_64
+
+mcFiles:
+- nm-conf-a
+- chrony
+
+""" + CI_BLOCK
+
+SLIM = """\
+owner:
+  merkaz: "1"
+
+mastertag: 4.16.27-x86_64
+
+nodepool:
+- infraEnvName: dell-a
+  replicas: 3
+  labels:
+    allowDeletion: false
+  configs:
+  - name: nm-conf-a
+  - name: chrony
+
+- name: zone-b
+  replicas: 2
+  labels:
+    minReplicas: 2
+    allowDeletion: false
+  infraEnvName: dell-b
+  configs:
+  - name: chrony
+  workertag: 4.16.20-x86_64
+
+""" + CI_BLOCK
+
+
+def make_tree(tmp_path, name, text, site_values="", mce_values=""):
+    sites = tmp_path / "sites"
+    cluster_dir = sites / "site-a" / "mces" / "mce-a" / "hostedClusters"
+    cluster_dir.mkdir(parents=True)
+    (sites / "configValues.yaml").write_text("platform: agent\nhostInventory: inventory\n")
+    (sites / "site-a" / "values.yaml").write_text(site_values)
+    (sites / "site-a" / "mces" / "mce-a" / "values.yaml").write_text(mce_values)
+    path = cluster_dir / name
+    path.write_text(text)
+    return path
+
+
+def run(path, *flags):
+    with pytest.raises(SystemExit) as exc:
+        slim.main([*flags, str(path)])
+    return exc.value.code
+
+
+def test_full_slim(tmp_path):
+    path = make_tree(tmp_path, "ocp4-demo.yaml", FULL)
+    assert run(path, "--write") == 0
+    assert path.read_text() == SLIM
+
+
+def test_ci_block_byte_identical(tmp_path):
+    path = make_tree(tmp_path, "ocp4-demo.yaml", FULL)
+    run(path, "--write")
+    assert path.read_text().endswith(CI_BLOCK)
+
+
+def test_idempotent(tmp_path, capsys):
+    path = make_tree(tmp_path, "ocp4-demo.yaml", FULL)
+    run(path, "--write")
+    capsys.readouterr()
+    assert run(path, "--write") == 0
+    assert path.read_text() == SLIM
+    assert "0 slimmed, 1 unchanged" in capsys.readouterr().out
+
+
+def test_dry_run_writes_nothing(tmp_path, capsys):
+    path = make_tree(tmp_path, "ocp4-demo.yaml", FULL)
+    assert run(path) == 0
+    assert path.read_text() == FULL
+    assert "WOULD" in capsys.readouterr().out
+
+
+def test_clusterName_kept_when_file_name_differs(tmp_path, capsys):
+    path = make_tree(tmp_path, "cluster-demo.yaml", FULL)
+    run(path, "--write")
+    text = path.read_text()
+    assert text.startswith("clusterName: demo\n")
+    # The derived nodepool name uses the kept clusterName, so it still goes.
+    assert "- infraEnvName: dell-a" in text
+    assert "clusterName 'demo'" in capsys.readouterr().out
+
+
+def test_mcFiles_kept_when_not_the_union(tmp_path, capsys):
+    path = make_tree(tmp_path, "ocp4-demo.yaml",
+                     FULL.replace("- nm-conf-a\n- chrony\n", "- nm-conf-a\n- chrony\n- extra\n"))
+    run(path, "--write")
+    assert "mcFiles:\n- nm-conf-a\n- chrony\n- extra\n" in path.read_text()
+    assert "+extra" in capsys.readouterr().out
+
+
+def test_layer_values_decide(tmp_path):
+    """A values layer setting another hostInventory or platform keeps the file's own."""
+    path = make_tree(tmp_path, "ocp4-demo.yaml", FULL,
+                     site_values="hostInventory: other\n", mce_values="platform: kubevirt\n")
+    run(path, "--write")
+    text = path.read_text()
+    assert "hostInventory: inventory\n" in text
+    assert "platform: agent\n" in text
+
+
+def test_shared_derived_name_kept(tmp_path):
+    """Two nodepools resolving to one name: neither name is removed."""
+    text = """\
+mastertag: 4.16.27-x86_64
+nodepool:
+- name: demo-same
+  infraEnvName: same
+  replicas: 1
+- name: demo-same
+  infraEnvName: same
+  replicas: 1
+"""
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    run(path, "--write")
+    assert path.read_text().count("name: demo-same") == 2
+
+
+def test_indented_items_and_zero_replicas(tmp_path):
+    text = """\
+mastertag: 4.16.27-x86_64
+nodepool:
+  - name: demo-dell-a
+    replicas: 0
+    labels:
+      maxReplicas: 0
+      minReplicas: 0
+      allowDeletion: false
+    agentLabelSelector:
+      nodeLabelKey: infraenvs.agent-install.openshift.io
+      nodeLabelValue: dell-a
+"""
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    run(path, "--write")
+    assert path.read_text() == ("mastertag: 4.16.27-x86_64\nnodepool:\n"
+                                "  - infraEnvName: dell-a\n    replicas: 0\n"
+                                "    labels:\n      allowDeletion: false\n")
+
+
+def test_selector_dropped_when_infraEnvName_already_written(tmp_path):
+    """A half-migrated nodepool loses the repeated selector, never gains a
+    second infraEnvName line."""
+    text = """\
+mastertag: 4.16.27-x86_64
+nodepool:
+- name: zone-a
+  infraEnvName: dell-a
+  agentLabelSelector:
+    nodeLabelKey: infraenvs.agent-install.openshift.io
+    nodeLabelValue: dell-a
+  replicas: 1
+"""
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    run(path, "--write")
+    assert path.read_text() == ("mastertag: 4.16.27-x86_64\nnodepool:\n"
+                                "- name: zone-a\n  infraEnvName: dell-a\n  replicas: 1\n")
+
+
+def test_bare_mastertag_compares_as_x86_64(tmp_path):
+    """mastertag 4.16.27 is 4.16.27-x86_64 to the chart, so a workertag
+    spelled either way equal to it goes."""
+    text = """\
+mastertag: 4.16.27
+workertag: 4.16.27-x86_64
+nodepool:
+- name: zone-a
+  infraEnvName: dell-a
+  replicas: 1
+  workertag: 4.16.27-x86_64
+"""
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    run(path, "--write")
+    assert path.read_text() == ("mastertag: 4.16.27\nnodepool:\n"
+                                "- name: zone-a\n  infraEnvName: dell-a\n  replicas: 1\n")
+
+
+def test_duplicate_top_level_key_left_untouched(tmp_path, capsys):
+    """Two nodepool: keys — YAML keeps the last; the file is reported, not edited."""
+    text = ("mastertag: 4.16.27-x86_64\nnodepool:\n- name: demo-a\n  infraEnvName: a\n"
+            "nodepool:\n- name: demo-b\n  infraEnvName: b\n")
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    assert run(path, "--write") == 1
+    assert path.read_text() == text
+    assert "written twice (nodepool)" in capsys.readouterr().out
+
+
+def test_unsupported_layout_left_untouched(tmp_path, capsys):
+    text = "mastertag: 4.16.27-x86_64\nnodepool:\n- {name: demo-a, infraEnvName: a, workertag: 4.16.27-x86_64}\n"
+    path = make_tree(tmp_path, "ocp4-demo.yaml", text)
+    assert run(path, "--write") == 1
+    assert path.read_text() == text
+    assert "slim it by hand" in capsys.readouterr().out
```

</details>

### 6.3 `config-docs.patch` — README, SCRIPTS.md, TESTS.md

The README gains the *Defaults* table and the upgrade rule; the onboarding
steps say to name the file `ocp4-<clusterName>.yaml` and leave defaults out.

<details><summary><code>README.md</code></summary>

```diff
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -39,17 +39,49 @@ the CI.
 
 ## The cluster YAML
 
-One file per hosted cluster, e.g.
-`sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml`. The keys split
+One file per hosted cluster, named
+`sites/<site>/mces/<mce>/hostedClusters/ocp4-<clusterName>.yaml`. The keys split
 three ways by **who writes them**:
 
 | Key | Who writes it | Meaning |
 |---|---|---|
-| `clusterName`, `platform`, `mastertag`, `etcd`, `nodepool`, `imageContentSources`, `hostInventory`, `Network` (static routes/firewall ports between segments), ... | **you** | The cluster spec. `mastertag` (`4.16.32-x86_64`) is the OpenShift version the butane render targets |
-| `mcFiles:` | **you** | Ordered list of config *names* the cluster wants — names only, no content |
+| `mastertag`, `nodepool`, `owner`, `etcd`, `imageContentSources`, `Network` (static routes/firewall ports between segments), ... | **you** | The cluster spec. `mastertag` (`4.16.32` or `4.16.32-x86_64` — a bare version gets `-x86_64`) is the OpenShift version the butane render targets, and the default for every nodepool's `workertag` |
+| `clusterName`, `platform`, `hostInventory`, `workertag`, `mcFiles` | **you, only to override a default** | See *Defaults* below. `mcFiles` defaults to the config *names* of all nodepools, each once |
 | `vlanId:` / `dhcp_values:` | the **segment-allocation workflow** | Network segment for a NEW cluster (pushed onto the branch by the orchestrator). Present ⇒ the cluster is not new |
 | `mcConfigMap:` | **CI** | The rendered content for each name in `mcFiles` — a full gzip+base64 ignition/MachineConfig blob per entry, written under a `# === Added by CI ===` header. Absent until the chain has run on the cluster at least once. Existing entries are **frozen**: `filter_frozen.py` keeps the chain away from clusters whose entries are present, so CI never overwrites a frozen entry |
 
+### Defaults
+
+Write a key only when its value differs from the default:
+
+| Key | Default |
+|---|---|
+| `clusterName` | the file name minus `.yaml` and `ocp4-` (`clusterFilePrefix` in argocd-platform). A file whose name does not match its cluster keeps `clusterName` — never rename a cluster file instead, that renames the cluster |
+| `platform` | Agent. Written only as `platform: kubevirt` |
+| `hostInventory` | `inventory` |
+| `workertag` (top level) | `mastertag`. Written only during an upgrade, see below. Like `mastertag`, `4.16.32` means `4.16.32-x86_64` |
+| `mcFiles` | every `nodepool[*].configs[*].name`, first-seen order, each once. A written `mcFiles` replaces this list completely |
+| `nodepool[].name` | `<clusterName>-<infraEnvName>`. Nodepools sharing an infraEnv must each set `name` (the render fails otherwise). An existing name stays written: renaming a NodePool recreates it |
+| `nodepool[].infraEnvName` | none — required on the agent platform; it is the `infraenvs.agent-install.openshift.io` label value. `agentLabelSelector` still works and is only needed for a different label key |
+| `nodepool[].labels.allowDeletion` | `"false"` — but write `allowDeletion: false` in every nodepool anyway: it is the nodepool's visible safety switch, and the slim script never removes it |
+| `nodepool[].labels.maxReplicas` | `replicas` |
+| `nodepool[].labels.minReplicas` | `replicas - 1`, never below 0 |
+| `nodepool[].workertag` | the top-level `workertag`, else `mastertag` |
+| `nodepool[].nodeDrainTimeout` | `0s` (no drain time limit) |
+
+Label values need no `'''` quoting: `8` and `false` render as the strings
+`"8"` and `"false"`. The old `'''8'''` spelling still works, and the slim
+script rewrites it.
+
+**Upgrades, masters first.** In ONE commit, bump `mastertag` and pin the
+workers with a top-level `workertag: <old version>`; a `mastertag` bump on
+its own upgrades the workers together with the control plane. Then move
+nodepools one at a time with a nodepool `workertag: <new version>` if you
+want, and finally delete every `workertag` line.
+
+`scripts/slim_hc_values.py` removes the values that equal their default from
+existing files (report only without `--write`).
+
 Two things to never do by hand: edit anything under `mcConfigMap:` (CI owns
 it — for a frozen cluster your edit would persist silently and drift from
 every source; for an included cluster the next run overwrites it), and add a
@@ -118,9 +150,10 @@ the MR run is the evidence behind the merge decision:
 
 1. Copy an existing cluster YAML (same MCE, similar hardware) into
    `sites/<site>/mces/<mce>/hostedClusters/<name>.yaml`.
-2. Edit the spec: `clusterName`, `mastertag`, `nodepool`
-   (agentLabelSelector must match your inventory labels), `mcFiles`, image
-   content sources.
+2. Name it `ocp4-<clusterName>.yaml` and edit the spec: `mastertag`,
+   `nodepool` (`infraEnvName` must match your inventory's infraEnv,
+   `labels: {allowDeletion: false}`, `configs` lists the configs to render),
+   image content sources. Leave out what defaults (see *Defaults*).
 3. **Do not** set `vlanId` / `dhcp_values` — push without them.
 4. Push. The chain allocates a segment (the orchestrator pushes the block
    back onto your branch), renders the mcFiles, and commits the
```

</details>

<details><summary><code>scripts/SCRIPTS.md</code></summary>

```diff
diff --git a/scripts/SCRIPTS.md b/scripts/SCRIPTS.md
--- a/scripts/SCRIPTS.md
+++ b/scripts/SCRIPTS.md
@@ -52,12 +52,12 @@ spaces included.
 ## The data model (what the scripts actually operate on)
 
 One file per hosted cluster, e.g.
-`sites/<site>/mces/<mce>/hostedClusters/<cluster>.yaml`:
+`sites/<site>/mces/<mce>/hostedClusters/ocp4-<clusterName>.yaml`:
 
 | Key | Who writes it | Meaning |
 |---|---|---|
-| `clusterName`, `mastertag`, `nodepool`, `imageContentSources`, ... | human | The cluster spec. `mastertag` (`4.20.1-x86_64`) is the OpenShift version the butane render targets |
-| `mcFiles:` | human | Ordered list of config *names* the cluster wants, e.g. `nm-conf-<cluster>-dell` — names only, no content |
+| `mastertag`, `nodepool`, `imageContentSources`, ... | human | The cluster spec. `mastertag` (`4.20.1-x86_64`) is the OpenShift version the butane render targets |
+| `clusterName`, `mcFiles:` | human, **only to override** | Default: `resolve_cluster_name` (file name minus `.yaml` and `CLUSTER_FILE_PREFIX`, the expression hcAppset passes the chart) and `resolve_mc_files` (every `nodepool[*].configs[*].name`, first-seen order, each once). A written `mcFiles` replaces the derived list completely. Every script reads them through these two functions |
 | `vlanId:` / `dhcp_values:` | **segment-allocation workflow** (via `allocate_segments.py`) | Network segment for a NEW cluster. Present ⇒ the cluster is not new; the chain never touches these |
 | `mcConfigMap:` | **CI** (via `inject_configs.py`), for included clusters only | The rendered content for each name in `mcFiles` — a full gzip+base64 ignition/MachineConfig blob per entry. `filter_frozen.py` keeps the chain away from clusters whose entries are present (frozen) — CI never overwrites a frozen entry |
 
@@ -69,8 +69,8 @@ hardware type: dell, cisco, nvidia-dgx, ...), static files in the root
 `mc-files/<clusterName>/` but is **never committed** — only the
 `mcConfigMap` content in the sites YAML is.
 
-**End-to-end for one new cluster** (push a YAML with `clusterName`,
-`mastertag`, `mcFiles: [nm-conf-X-dell]`, no vlanId):
+**End-to-end for one new cluster** (push `ocp4-X.yaml` with `mastertag` and
+a nodepool whose `configs` lists `nm-conf-X-dell`, no vlanId):
 
 1. `get_changed_clusters.py` → `targets.env` names that one file.
 2. `filter_frozen.py` → a new cluster has no `mcConfigMap` ⇒ included.
@@ -210,8 +210,10 @@ are copied verbatim (frozen content must not drift).
 | `find_template(mc_file_name, template_map)` | Longest-suffix match, so `-dell-data` beats `-dell` |
 | `is_false_value(value)` | Logical false for both `False` and the string `"false"` (common in cluster YAMLs) |
 | `add_ci_header(yaml_file)` | Append the `# === Added by CI ===` marker if absent (matches the old shell wrapper's blank-line behavior) |
-| `validate_mastertag(mastertag)` | Regex `X.Y.Z-ARCH` → base version `X.Y.0` (butane only supports base versions) |
-| `validate_cluster_yaml(data, yaml_file)` | Required fields: `clusterName`, `mastertag`, and `vlanId` when `AutomateAllocation=false` (also adds the CI header in that case) |
+| `validate_mastertag(mastertag)` | Regex `X.Y.Z-ARCH` or bare `X.Y.Z` (the chart adds `-x86_64`) → base version `X.Y.0` (butane only supports base versions) |
+| `resolve_cluster_name(data, yaml_file)` | `clusterName` when the file sets it, else the file name minus `.yaml` and `CLUSTER_FILE_PREFIX` (`ocp4-`, must match argocd-platform's `clusterFilePrefix`) |
+| `resolve_mc_files(data)` | `mcFiles` when the file lists them, else the nodepools' config names, first-seen order, each once |
+| `validate_cluster_yaml(data, yaml_file)` | Required fields: `mastertag`, and `vlanId` when `AutomateAllocation=false` (also adds the CI header in that case); resolves the cluster name |
 | `find_static_source(mc_file_name, output_dir)` | Locate a static source in `mc-files/` root then subfolders, skipping `templates/` and the cluster's own output dir; deterministic ordering |
 | `copy_static_file(...)` | Copy a static file into the cluster dir; rewrite the butane version header iff the file is `.bu` AND new to the cluster |
 | `generate_from_template(...)` | One mcFile: template render (replace `VLAN_ID`, `{CLUSTER_NAME}`, `{OPENSHIFT_VERSION}`) or static copy; warn-and-continue when neither exists |
@@ -324,7 +326,7 @@ not render. Non-mutating: each cluster renders inside a throwaway temp copy of
 |---|---|
 | `cluster_name_of(cluster_file)` | File stem — the cluster's identity |
 | `discover_all_clusters(repo_root)` | Sorted glob of all clusters (same pattern as `HOSTED_CLUSTER_YAML_PATH`) |
-| `stage_work_dir(work_root, cluster_file, repo_root)` | Copy `mc-files/` (templates + root static files only — deliberately *not* per-cluster output dirs from past runs) and the cluster YAML into the temp dir, so `verify_output()` can only pass on freshly generated files |
+| `stage_work_dir(work_root, cluster_file, repo_root)` | Copy `mc-files/` (templates + root static files only — deliberately *not* per-cluster output dirs from past runs) and the cluster YAML into a fresh `mkdtemp` dir (two MCEs may hold files of the same name), so `verify_output()` can only pass on freshly generated files |
 | `validate_cluster(cluster_file, ...)` | Run `generate_from_template.py` in the staged dir via subprocess; `(ok, captured_log)` |
 | `main` | Iterate all clusters, per-cluster OK/FAIL lines, failure report with full generator logs, exit 1 on any failure. No skip list — deferring a failure is a decision to fix the cluster, not to silence the validator |
 
@@ -332,6 +334,27 @@ not render. Non-mutating: each cluster renders inside a throwaway temp copy of
 
 ---
 
+## `slim_hc_values.py` — manual, not in the chain
+
+**Purpose:** one-off migration. Removes values from existing cluster files that
+the chart, the appset or CI now default — only where the effective value stays
+the same (rules in its docstring: `clusterName`, `platform`, `hostInventory`,
+top-level `workertag`, `mcFiles`, and per nodepool `agentLabelSelector` →
+`infraEnvName`, `name`, `maxReplicas` / `minReplicas`, `workertag`,
+`nodeDrainTimeout`). `allowDeletion` always stays, respelled without `'''`;
+tags compare as the chart completes them (`4.22.8` = `4.22.8-x86_64`). A file
+with a top-level key written twice is reported, never edited. Report only
+unless `--write`.
+
+| Function | Purpose |
+|---|---|
+| `merge`, `values_layers`, `inherited` | The four valueFiles merged the way Helm does, so a key is only dropped when what the file inherits from configValues / site / MCE values equals it |
+| `effective(data, cluster_file, layers)` | The values the chart and CI act on with every default applied — the self-check compares this for the original and the slimmed file |
+| `plan(...)` | What can go, plus a reason for every value that stays |
+| `top_level_blocks`, `split_items`, `edit_item`, `slim_text` | Line-based edits in the idiom of `inject_configs`' writer: the `mcConfigMap` block, comments and headers stay byte-identical. Layouts it cannot edit safely (flow-style nodepools) are reported, never guessed |
+
+---
+
 ## Ponytail findings (review notes, not yet applied)
 
 1. **`generate_from_template.py:316-324` — dead error tracking.**
```

</details>

<details><summary><code>tests/TESTS.md</code></summary>

```diff
diff --git a/tests/TESTS.md b/tests/TESTS.md
--- a/tests/TESTS.md
+++ b/tests/TESTS.md
@@ -152,6 +152,45 @@ keep-vs-fail decision by normalized payload comparison.
 
 ---
 
+## `test_hc_defaults.py` (13 tests)
+
+**What it pins:** the clusterName / mcFiles defaults every script reads through
+(`resolve_cluster_name`, `resolve_mc_files` in `generate_from_template.py`).
+
+| Class / test | Tests | The contract |
+|---|---|---|
+| `TestResolveClusterName` | 4 | An explicit `clusterName` wins; otherwise the file name minus `.yaml` and `ocp4-`; a name without the prefix is kept as is; `clusterName: ""` counts as unset (Helm's `default` semantics, which the appset uses) |
+| `TestBareMastertag` | 2 | `4.22.8` and `4.22.8-x86_64` give the same butane version; `4.22` is still rejected |
+| `TestResolveMcFiles` | 4 | An explicit `mcFiles` wins, even `[]`; otherwise the nodepools' config names in first-seen order, each once; nodepools without configs contribute nothing |
+| `test_generate_derives_cluster_name_and_mc_files` | 1 | `ocp4-derived-cluster.yaml` with neither key renders into `mc-files/derived-cluster/` |
+| `test_inject_derives_cluster_name_and_mc_files` | 1 | `mcConfigMap` is filled from the nodepool configs, and the cluster's own render copy is found under the derived name |
+| `test_filter_frozen_with_derived_mc_files` | 1 | A frozen cluster whose `mcFiles` key is gone stays FROZEN — without the default it would be INCLUDE (empty set ≠ entry names) and get regenerated |
+
+---
+
+## `test_slim_hc_values.py` (13 tests)
+
+**What it pins:** the migration script removes a value only when its default
+gives the same effective value. Each test writes a `sites/` tree with all four
+values layers into `tmp_path`.
+
+| Test | The contract |
+|---|---|
+| `test_full_slim` | The exact slimmed text for a file carrying every removable key; `allowDeletion` and the labels that differ from their default stay, respelled without `'''`, and so do an off-convention nodepool name and a pinned `workertag` |
+| `test_ci_block_byte_identical` | The `# === Added by CI ===` block, blank lines inside the block literal included, is untouched |
+| `test_idempotent` / `test_dry_run_writes_nothing` | A second run finds nothing; without `--write` the file is not touched |
+| `test_clusterName_kept_when_file_name_differs` | `clusterName` stays when the file name derives another name, and the derived nodepool names use the kept one |
+| `test_mcFiles_kept_when_not_the_union` | `mcFiles` with a name no nodepool references stays, and the report names it |
+| `test_layer_values_decide` | A site or MCE layer setting another `hostInventory` / `platform` keeps the file's own value |
+| `test_shared_derived_name_kept` | Two nodepools resolving to one name keep both names (the chart would fail the render otherwise) |
+| `test_indented_items_and_zero_replicas` | Indented sequence style; `replicas: 0` labels compare against max 0 / min 0 |
+| `test_selector_dropped_when_infraEnvName_already_written` | A nodepool with both `infraEnvName` and the same selector loses the selector, never gains a second `infraEnvName` line |
+| `test_bare_mastertag_compares_as_x86_64` | `mastertag: 4.16.27` equals a `4.16.27-x86_64` workertag, so the workertags go |
+| `test_duplicate_top_level_key_left_untouched` | Two `nodepool:` keys: exit 1, file byte-identical |
+| `test_unsupported_layout_left_untouched` | A flow-style nodepool exits 1 and leaves the file byte-identical |
+
+---
+
 ## `test_validate_all_clusters.py` (8 tests)
 
 **What it pins:** cluster-file selection (only hosted-cluster YAMLs count) and the
```

</details>

### 6.4 Tests

```bash
cd <config> && python3 -m pytest tests/ -q
```

The 26 new tests must pass, and nothing that passed before may fail. In the
mirror, five tests fail on the untouched repo too, from fixture names the
sanitization mangled:
- `test_template_entry_roundtrip`
- `TestValidation::test_automate_true_allows_missing_vlan_id`
- `TestGeneration::test_template_rendering`
- `TestMain::test_main_accepts_multiple_files`
- `test_root_commit_without_before_sha_counts_everything`

Compare against a run on `origin/main`, not against zero.

---

## 7. Offline render check — `helm` and `python3` only

`render_compare.py` renders every cluster file twice and compares the results
as parsed objects. Each render emulates `hcAppset.yaml`: the four value files
in order, plus optionally the `clusterName` parameter. Save it anywhere.

<details><summary><code>render_compare.py</code></summary>

```python
#!/usr/bin/env python3
"""Render every hosted-cluster file with two chart/values combinations and compare.

Emulates hcAppset.yaml: the four valueFiles in order (configValues, site, MCE,
cluster file; a missing file is skipped, as with ignoreMissingValueFiles) and,
with --new-param / --old-param, the clusterName helm parameter (the file's own
clusterName when it sets one, otherwise the file name minus .yaml and --prefix).

Objects are compared parsed, keyed by kind/namespace/name, so quoting or key
order never counts as a difference. Prints every difference, then a summary of
the distinct (kind, field, old -> new) changes with their counts.

Needs python3 with pyyaml, and helm.
"""
import argparse
import collections
import subprocess
import sys
from pathlib import Path

import yaml

ABSENT = "<absent>"


def param_value(cluster_file, prefix):
    data = yaml.safe_load(cluster_file.read_text()) or {}
    if data.get("clusterName"):
        return str(data["clusterName"])
    stem = cluster_file.name[:-len(".yaml")]
    return stem[len(prefix):] if stem.startswith(prefix) else stem


def render(chart, sites_root, rel, with_param, prefix):
    cluster_file = sites_root / rel
    mce_dir = cluster_file.parent.parent
    site_dir = mce_dir.parent.parent
    cmd = ["helm", "template", "x", str(chart)]
    for values in (sites_root / "configValues.yaml", site_dir / "values.yaml",
                   mce_dir / "values.yaml", cluster_file):
        if values.is_file():
            cmd += ["-f", str(values)]
    if with_param:
        cmd += ["--set-string", f"clusterName={param_value(cluster_file, prefix)}"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip().splitlines()[-1]
    objects, seen = {}, collections.Counter()
    for doc in yaml.safe_load_all(result.stdout):
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata") or {}
        key = (doc.get("kind"), meta.get("namespace"), meta.get("name"))
        seen[key] += 1
        objects[key + (seen[key],)] = doc
    return objects, None


def diff(old, new, path=""):
    if isinstance(old, dict) and isinstance(new, dict):
        for k in sorted(set(old) | set(new), key=str):
            yield from diff(old.get(k, ABSENT), new.get(k, ABSENT), f"{path}.{k}" if path else str(k))
    elif isinstance(old, list) and isinstance(new, list) and len(old) == len(new):
        for i, (o, n) in enumerate(zip(old, new)):
            yield from diff(o, n, f"{path}[{i}]")
    elif old != new:
        yield path, old, new


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--old-chart", required=True, type=Path)
    p.add_argument("--new-chart", required=True, type=Path)
    p.add_argument("--old-sites", required=True, type=Path, help="sites/ dir for the old render")
    p.add_argument("--new-sites", type=Path, help="sites/ dir for the new render (default: --old-sites)")
    p.add_argument("--old-param", action="store_true", help="pass clusterName as the appset parameter to the old render")
    p.add_argument("--new-param", action="store_true", help="pass clusterName as the appset parameter to the new render")
    p.add_argument("--prefix", default="ocp4-", help="clusterFilePrefix (default: ocp4-)")
    args = p.parse_args()
    new_sites = args.new_sites or args.old_sites

    rels = sorted(f.relative_to(args.old_sites)
                  for f in args.old_sites.glob("*/mces/*/hostedClusters/*.yaml"))
    if not rels:
        sys.exit(f"no hosted-cluster files under {args.old_sites}")
    summary = collections.Counter()
    failures = 0
    for rel in rels:
        if not (new_sites / rel).is_file():
            print(f"MISSING {rel}: not in --new-sites")
            failures += 1
            continue
        old, old_err = render(args.old_chart, args.old_sites, rel, args.old_param, args.prefix)
        new, new_err = render(args.new_chart, new_sites, rel, args.new_param, args.prefix)
        if old_err or new_err:
            print(f"FAIL  {rel}: old: {old_err or 'ok'} | new: {new_err or 'ok'}")
            failures += 1
            continue
        lines = []
        for key in sorted(set(old) | set(new), key=str):
            label = f"{key[0]} {key[1]}/{key[2]}"
            if key not in old or key not in new:
                lines.append(f"  {label}: only in {'new' if key not in old else 'old'}")
                summary[(key[0], "<whole object>", "only in new" if key not in old else "only in old")] += 1
                continue
            for path, o, n in diff(old[key], new[key]):
                lines.append(f"  {label}: {path}: {o!r} -> {n!r}")
                summary[(key[0], path.split("[")[0], f"{o!r} -> {n!r}")] += 1
        print(f"{'DIFF' if lines else 'SAME'}  {rel}")
        print("\n".join(lines)) if lines else None
    print(f"\n{len(rels)} files, {failures} failed to render")
    if summary:
        print("distinct changes (count  kind  field  old -> new):")
        for (kind, path, change), count in sorted(summary.items()):
            print(f"  {count:4}  {kind}  {path}  {change}")
    else:
        print("no differences")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
```

</details>

### 7.1 Worktrees of `main`

```bash
git -C <chart>  fetch && git -C <chart>  worktree add /tmp/chart-main  origin/main
git -C <config> fetch && git -C <config> worktree add /tmp/config-main origin/main
```

### 7.2 Gate a — the chart MR

```bash
python3 render_compare.py --old-chart /tmp/chart-main --new-chart <chart> \
    --old-sites <config>/sites
```

Expected tail:

```
N files, 0 failed to render
distinct changes (count  kind  field  old -> new):
  <[7a]>  NodePool  spec.nodeDrainTimeout  '<absent>' -> '0s'
  <[7b]>  NodePool  spec.replicas  1 -> 0
```

Anything else means a default does not match what your files say. Look at
that file's `DIFF` lines, and do not merge.

### 7.3 Gate c — the `clusterName` parameter

```bash
python3 render_compare.py --old-chart <chart> --new-chart <chart> \
    --old-sites <config>/sites --new-param
# -> no differences
```

This proves the parameter equals what every file renders today.

### 7.4 Gate d — a slimming MR

With the merged chart on `main` (run `git -C /tmp/chart-main pull` first):

```bash
python3 render_compare.py --old-chart /tmp/chart-main --new-chart /tmp/chart-main \
    --old-sites /tmp/config-main/sites --new-sites <config>/sites --old-param --new-param
# -> no differences
```

### 7.5 What was verified in the mirror

- **Today's setup against the new one, all 51 files** (old chart with no
  parameter, against the new chart with the `clusterName` parameter): only
  the two expected changes (44 and 2).
- **The new chart on its own:**
  - With `platform` and `hostInventory` unset everywhere: `type: Agent`,
    `agentNamespace: inventory`.
  - Every default and override: derived name, label defaults including
    `replicas: 0`, cluster-level and nodepool `workertag`.
  - Each guard fails with its message, and explicit duplicate names still
    render.
- **The `clusterName` expression,** evaluated with Helm's template engine (the
  same Go templates and sprig functions Argo uses) under `helm lint --strict`
  (`missingkey=error`). Cases: an explicit value wins; `ocp4-x.yaml` gives `x`;
  a name without the prefix is kept; `clusterName: ""` counts as unset.
- **Every `mastertag` and `workertag` written bare** (153 tags, `-x86_64`
  stripped): renders identically, and CI generation passes.
- **Slimming all 51 files:** 49 slimmed. The 2 with a `nodepool:` key
  written twice are refused and left byte-identical.
  - Renders identically.
  - `allowDeletion` stays in every nodepool, respelled `false` / `true`.
  - A second run changes nothing.
  - Every CI and workflow block is byte-identical.
  - All frozen-filter verdicts are unchanged.
  - `validate_all_clusters.py` passes.
- **The same files renamed to `ocp4-<clusterName>.yaml`,** so `clusterName`
  is derived too: renders identically. The old chart on the original files,
  against the new chart and parameter on the slimmed `ocp4-*` files, shows
  only the two expected changes.
- **Live, on a connected OpenShift GitOps 1.18 cluster** (a throwaway
  ApplicationSet with no sync policy, deleted afterwards):
  - A list generator under `missingkey=error`: an explicit `clusterName`
    wins, `ocp4-x.yaml` gives `x`, a name without the prefix is kept, and
    `clusterName: ""` counts as unset.
  - Then this exact `hcAppset.yaml` rendered with Helm, with only its repo
    URLs retargeted, over the GitHub mirror's real `ocp4-*.yaml` files, which
    set no `clusterName`. The Applications kept the full file name
    (`…-ocp4-prep-itay-site1`) and got `clusterName: prep-itay-site1`.

  §9.2 still checks the same thing on your first MCE.

---

## 8. Slimming the cluster files — step d

One MR per MCE, so each gate stays small:

```bash
cd <config>
python3 scripts/slim_hc_values.py 'sites/<site>/mces/<mce>/hostedClusters/*.yaml'          # report only
python3 scripts/slim_hc_values.py --write 'sites/<site>/mces/<mce>/hostedClusters/*.yaml'
git diff
```

The report has one block per file:
- `removed …` lines are what goes.
- `rewrote …` lines are labels that stay but lose the `'''` quoting
  (`allowDeletion` always stays).
- `kept …` lines say why something stays: a name off the convention, a label
  that is not its default, an `mcFiles` that differs, a `clusterName` the
  file name does not give.
- `ERROR` means the file is left untouched. Either a top-level key is written
  twice (check 2 `[6c]`), its layout is not one the script edits line by line
  (a flow-style nodepool), or its self-check failed. Fix or slim that file by
  hand, or leave it.

The script removes a value only when its default gives the same effective
value. For `hostInventory`, `platform` and the top-level `workertag`, that
compares against what the file inherits from `configValues.yaml` and its site
and MCE `values.yaml`. Before writing, it parses the result back and compares
the effective values with the original's.

Then §7.4, push, and let CI run. Optional, once every MCE is slimmed:
`platform: agent` and `hostInventory: inventory` in `sites/configValues.yaml`
are chart defaults now and can go too. Do that as its own MR, with §7.4.

---

## 9. Verify live

### 9.1 After step a, on each MCE

```bash
oc get applications -n openshift-gitops | grep -v 'Synced *Healthy'   # -> header only, once synced
oc get nodepools -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DRAIN:.spec.nodeDrainTimeout,REPLICAS:.spec.replicas,MAX:.metadata.labels.maxReplicas
# -> DRAIN 0s everywhere it was unset; labels unchanged
oc get machines.cluster.x-k8s.io -A --sort-by=.metadata.creationTimestamp | tail
# -> no new Machines; the only change is a [7b] NodePool's Machine going away
```

Do the first MCE alone and wait for its sync before letting the others pick it
up, if your sync policy allows that.

### 9.2 After step c, on each MCE

```bash
oc get application <ocp4-…> -n openshift-gitops -o jsonpath='{.spec.sources[0].helm.parameters}{"\n"}'
# -> [{"forceString":true,"name":"clusterName","value":"<the file's clusterName>"}]
oc get applicationset -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="ErrorOccurred")].status}{"\n"}{end}'
# -> False for every <mce>-hc appset
```

Every hosted-cluster app stays Synced with no diff.

### 9.3 After each step d MR

Apps stay Synced/Healthy, and the CI chain is green for the slimmed files.

---

## 10. Upgrades — masters first

`workertag` follows `mastertag` now, so bumping `mastertag` alone upgrades the
workers together with the control plane. To keep upgrading masters first:

1. **One commit:** `mastertag: <new>` **and** a top-level
   `workertag: <old>` (either spelling: `4.22.8` or `4.22.8-x86_64`). The control plane upgrades; every nodepool stays on
   `<old>`.
2. Optional: move nodepools one at a time with a nodepool
   `workertag: <new>`.
3. Delete every `workertag` line. All nodepools follow `mastertag` again. The
   rendered image is the same, so this commit does nothing live.

Whatever automates upgrades must write step 1 as one commit.

---

## 11. New clusters

Name the file `ocp4-<clusterName>.yaml`. Write `owner`, `mastertag` (`4.22.8`
is enough), and per nodepool `infraEnvName`, `replicas`,
`labels: {allowDeletion: false}` and `configs`, plus whatever your cluster
really differs in (`nodeLabels`, `tuningConfig`, other labels, …). Nodepools that
share an infraEnv (zones) each need a `name`. Push without `vlanId` /
`dhcp_values` as before.

---

## 12. Seen, not changed

- **`nodepool.yaml` renders `tuningConfig:` twice** when it is set: once by
  the old single-name block, once by the list block. It is pre-existing and
  left alone.
- **`dhcp_scope_manager`'s `validate_dhcp_values.py`** derives the DHCP
  `scopeName` from the cluster file's full stem (`OCP4-…`). The chart derives
  it from `clusterName` (no prefix). That mismatch exists today and this
  change does not touch it. Check which one your CI uses.
- **Testing an appset change with throwaway Applications:** the connected
  `helm-charts-hostedclusters-setup` has a PostDelete hook,
  `release-segment-hook.yaml`. Deleting an Application rendered from it runs
  a Job that asks the orchestrator to release that `clusterName`'s VLAN
  segment. Point test Applications at a destination namespace that does not
  exist (so the hook Job cannot be created), then delete them and clear their
  `metadata.finalizers` right after. If the hook is ported to the air-gap,
  that applies there too.
- **The connected-side `_day2-helpers.tpl`** (day2 registration in the
  connected `helm-charts-hostedclusters-setup`) expects `clusterName` to be
  `ocp4-<env>-<name>-<site>`. If it is ported to the air-gap, it must build
  that from `ocp4-` + `clusterName`.

---

## 13. Final gate

```bash
cd <chart>    && grep -c 'default "0s"' templates/nodepool.yaml && grep -c '^hostInventory: inventory' values.yaml   # -> 1 and 1
cd <chart>    && grep -c 'hc.releaseTag' templates/_helpers.tpl templates/hc.yaml templates/nodepool.yaml   # -> 1, 1 and 1
cd <platform> && grep -c 'trimPrefix' hostedClusters/templates/hcAppset.yaml && grep -c '^clusterFilePrefix: ocp4-' hostedClusters/values.yaml   # -> 1 and 1
cd <config>   && grep -n "data.get('mcFiles')\|data.get('clusterName')" scripts/inject_configs.py scripts/filter_frozen.py scripts/verify_missing_configs.py   # -> nothing
cd <config>   && python3 scripts/slim_hc_values.py | tail -1    # after step d: "N files: 0 to slim, N unchanged, 0 errors"
                                                                #   (errors only for files you chose to slim by hand)
```

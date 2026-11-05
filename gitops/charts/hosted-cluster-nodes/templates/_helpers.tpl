{{/*
Shared labels for every object this chart renders.

NOTE the naming rule here differs from the service charts in this repo, which derive
every object name from .Release.Name. These objects cannot: each VM is paired 1:1 with
a BareMetalHost on the management cluster whose `bootMACAddress` must match this VM's
interface MAC, so the VM name is an explicit, stable identity from values — not
something derived from the release. The VM classes (instancetypes, preference) are
cluster-scoped and referenced BY NAME from every VM, so their names are fixed in
values for the same reason.
*/}}
{{- define "nodes.baseLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* The compute-node VirtualMachines. */}}
{{- define "nodes.labels" -}}
{{ include "nodes.baseLabels" . }}
app.kubernetes.io/component: compute-node
{{- end }}

{{/* The cluster-scoped VM classes: instancetypes and the preference. */}}
{{- define "nodes.classLabels" -}}
{{ include "nodes.baseLabels" . }}
app.kubernetes.io/component: vm-class
{{- end }}

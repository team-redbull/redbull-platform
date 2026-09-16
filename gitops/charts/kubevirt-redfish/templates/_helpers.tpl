{{/*
Every object's name derives from the RELEASE name, which both deployment paths set to the
service/chart folder name "kubevirt-redfish": the redbull-platform ApplicationSet via
releaseName: path.basename, and the day2 platform via releaseName: .Values.operator.

Deriving instead of hardcoding is what keeps the CLUSTER-SCOPED ClusterRole and
ClusterRoleBinding from colliding when this chart is installed twice on one cluster —
fixed literals made that collision silent.

Do NOT set day2's `oldConvention: true` for this chart: it makes the release name
<cluster>-<team>-<chart>, renaming every object below with it.
*/}}
{{- define "redfish.fullname" -}}
{{- .Release.Name -}}
{{- end }}

{{/*
Shared labels for every KubeVirt Redfish object. The Deployment's selector and the
Service's selector both key off name+component=server, so those two labels are
emitted separately (below) and must NOT be folded into this helper — changing a
selector on a live Deployment is an immutable-field error.
*/}}
{{- define "redfish.labels" -}}
app.kubernetes.io/name: kubevirt-redfish
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "redfish.selectorLabels" -}}
app.kubernetes.io/name: kubevirt-redfish
app.kubernetes.io/component: server
{{- end }}

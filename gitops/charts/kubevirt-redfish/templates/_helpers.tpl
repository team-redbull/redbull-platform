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

{{/* Every object is named from the RELEASE name (the service/chart folder name under both
deployment paths), so two releases on one cluster — the lab's several-clusters-on-one — never
collide on the CLUSTER-scoped ClusterRole and ClusterRoleBinding. */}}
{{- define "kvcap.fullname" -}}
{{- .Release.Name -}}
{{- end }}
{{- define "kvcap.labels" -}}
app.kubernetes.io/name: kv-capacity
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "kvcap.selectorLabels" -}}
app.kubernetes.io/name: kv-capacity
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

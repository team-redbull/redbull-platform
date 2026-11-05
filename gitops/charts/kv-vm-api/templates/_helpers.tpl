{{- define "kvvm.fullname" -}}
{{- .Release.Name -}}
{{- end }}
{{- define "kvvm.labels" -}}
app.kubernetes.io/name: kv-vm-api
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "kvvm.selectorLabels" -}}
app.kubernetes.io/name: kv-vm-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

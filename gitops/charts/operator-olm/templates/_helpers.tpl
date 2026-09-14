{{/*
Namespace for the OperatorGroup. Defaults to the Subscription's namespace: OLM only
installs into a namespace that HAS an OperatorGroup, so the two can never legitimately
differ. Split only so a consumer with an unusual layout can say so explicitly.
*/}}
{{- define "operator-olm.namespace" -}}
{{- .Values.operatorGroup.namespace | default (required "operator-olm: subscription.namespace is required" .Values.subscription.namespace) -}}
{{- end -}}

{{/*
OperatorGroup object name. Defaults off the PACKAGE name, not .Release.Name, so that a
consumer installing two operators from one vendored copy (Helm `alias`) gets two
distinct names instead of a collision.
*/}}
{{- define "operator-olm.operatorGroupName" -}}
{{- .Values.operatorGroup.name | default (printf "%s-group" (include "operator-olm.subscriptionName" .)) -}}
{{- end -}}

{{- define "operator-olm.subscriptionName" -}}
{{- required "operator-olm: subscription.name is required (the OLM package name, from `oc get packagemanifest`)" .Values.subscription.name -}}
{{- end -}}

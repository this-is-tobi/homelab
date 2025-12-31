{{/*
Generate the full name for an application
*/}}
{{- define "homelab-core.appName" -}}
{{- printf "%s%s%s" .Values.instanceAppset.prefix.name .app .Values.instanceAppset.suffix.name -}}
{{- end -}}

{{/*
Generate the namespace for an application
*/}}
{{- define "homelab-core.namespace" -}}
{{- printf "%s%s%s" .Values.instanceAppset.prefix.namespace .app .Values.instanceAppset.suffix.namespace -}}
{{- end -}}

{{/*
Generate the ApplicationSet name
*/}}
{{- define "homelab-core.instanceAppsetName" -}}
{{- printf "%s-%s" .Values.instanceAppset.name .Values.instanceAppset.env -}}
{{- end -}}

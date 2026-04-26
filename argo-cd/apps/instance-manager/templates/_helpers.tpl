{{/*
Per-instance label set propagated to every generated Application.
*/}}
{{- define "instance-manager.labels" -}}
ohmlab.fr/instance-name: {{ .Values.instance.name | quote }}
ohmlab.fr/instance-env: {{ .Values.instance.env | default "" | quote }}
ohmlab.fr/instance-provider: {{ .Values.instance.provider | default "" | quote }}
ohmlab.fr/instance-region: {{ .Values.instance.region | default "" | quote }}
{{- end -}}

{{/*
Resolve the values repo. Defaults to .Values.repoURL when valuesRepoURL is empty.
*/}}
{{- define "instance-manager.valuesRepo" -}}
{{ default .Values.repoURL .Values.valuesRepoURL }}
{{- end -}}

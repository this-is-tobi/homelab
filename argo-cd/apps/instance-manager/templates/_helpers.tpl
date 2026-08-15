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

{{/*
RollingSync strategy block (progressive sync). Steps come from
.Values.progressiveSync.steps; a final catch-all step matches every wave not
explicitly listed so no Application can be left unmatched.
*/}}
{{- define "instance-manager.rollingSyncStrategy" -}}
{{- if .Values.progressiveSync.enabled }}
{{- $all := list }}
{{- range $step := .Values.progressiveSync.steps }}
{{- range $w := $step }}
{{- $all = append $all (printf "w%v" $w) }}
{{- end }}
{{- end }}
strategy:
  type: RollingSync
  rollingSync:
    steps:
    {{- range $step := .Values.progressiveSync.steps }}
    - matchExpressions:
      - key: ohmlab.fr/sync-wave
        operator: In
        values:
        {{- range $w := $step }}
        - {{ printf "w%v" $w | quote }}
        {{- end }}
    {{- end }}
    - matchExpressions:
      - key: ohmlab.fr/sync-wave
        operator: NotIn
        values:
        {{- range $w := $all }}
        - {{ $w | quote }}
        {{- end }}
{{- end }}
{{- end -}}

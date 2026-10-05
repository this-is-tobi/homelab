{{- /* Policy name, with the optional shadow suffix. */}}
{{- define "kyverno.cel.name" -}}
{{ .name }}{{ .root.Values.policies.celNameSuffix | default "" }}
{{- end }}

{{- /* validationActions for a failureAction value (Enforce -> Deny). */}}
{{- define "kyverno.cel.actions" -}}
{{- $action := ternary "Audit" .failureAction .root.Values.policies.shadow -}}
[{{ ternary "Deny" "Audit" (eq $action "Enforce") }}]
{{- end }}

{{- /* namespaceSelector excluding namespaces by name. */}}
{{- define "kyverno.cel.excludeNamespaces" -}}
matchExpressions:
- key: kubernetes.io/metadata.name
  operator: NotIn
  values:
  {{- toYaml . | nindent 2 }}
{{- end }}

{{- /* Everything the validation policies share: background scan, pods only,
       autogen for the five pod controllers (no ReplicaSet), no extra webhook
       settings so every policy shares Kyverno's aggregated webhook. */}}
{{- define "kyverno.cel.common" -}}
evaluation:
  background:
    enabled: true
matchConstraints:
  {{- with .namespaceSelector }}
  namespaceSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  resourceRules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
autogen:
  podControllers:
    controllers: [deployments, statefulsets, daemonsets, jobs, cronjobs]
{{- end }}

{{- /* validationActions for a failureAction value (Enforce -> Deny). */}}
{{- define "kyverno.cel.actions" -}}
[{{ ternary "Deny" "Audit" (eq . "Enforce") }}]
{{- end }}

{{- /* The `outOfScope` variable every scoped validation starts with
       (`variables.outOfScope ||`). Scoping is done in CEL because a
       namespaceSelector that differs between policies gives each policy its
       own Kyverno webhook, and so one extra admission call per policy and pod.
       Takes `exclude` (a list of namespace names) or `tenantOnly`. */}}
{{- define "kyverno.cel.scope" -}}
- name: outOfScope
  {{- if .tenantOnly }}
  expression: >-
    namespaceObject.metadata.?labels[?'ohmlab.fr/instance-scope'].orValue('') != 'tenant'
  {{- else }}
  expression: >-
    object.metadata.namespace in {{ .exclude | toJson }}
  {{- end }}
{{- end }}

{{- /* Everything the validation policies share: background scan, pods only,
       autogen for the five pod controllers (no ReplicaSet), no namespace
       selector and no extra webhook settings, so every policy shares one
       Kyverno webhook. */}}
{{- define "kyverno.cel.common" -}}
evaluation:
  background:
    enabled: true
matchConstraints:
  resourceRules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
autogen:
  podControllers:
    controllers: [deployments, statefulsets, daemonsets, jobs, cronjobs]
{{- end }}

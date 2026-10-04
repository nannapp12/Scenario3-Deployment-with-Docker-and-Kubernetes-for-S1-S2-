{{/* Common labels. */}}
{{- define "ai.labels" -}}
app.kubernetes.io/part-of: ai-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Image for an app: its own `image`, else <registry>/<name>:<tag>.  (list root name config) */}}
{{- define "ai.image" -}}
{{- $root := index . 0 }}{{ $name := index . 1 }}{{ $c := index . 2 -}}
{{- if $c.image -}}
{{ $c.image }}
{{- else -}}
{{ required "image.registry is required" $root.Values.image.registry }}/{{ $name }}:{{ $root.Values.image.tag }}
{{- end }}
{{- end }}

{{/* Workload identity settings for an identity key.  (list root identity) */}}
{{- define "ai.identity" -}}
{{- $root := index . 0 }}{{ $key := index . 1 -}}
{{- $id := index $root.Values.azure.identities $key | default dict -}}
{{- if not $id }}{{ fail (printf "azure.identities.%s is not defined" $key) }}{{ end -}}
{{- toYaml $id }}
{{- end }}

{{/* Plain env vars; values are rendered with tpl.  (list root envMap) */}}
{{- define "ai.env" -}}
{{- $root := index . 0 -}}
{{- range $k, $v := (index . 1 | default dict) }}
- name: {{ $k }}
  value: {{ tpl (toString $v) $root | quote }}
{{- end }}
{{- end }}

{{/* Env vars from the Kubernetes Secret synced from Key Vault.  (list name secretsMap) */}}
{{- define "ai.secretEnv" -}}
{{- $name := index . 0 -}}
{{- range $envName, $kvName := (index . 1 | default dict) }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ $name }}-kv
      key: {{ $kvName }}
{{- end }}
{{- end }}

{{/* SecretProviderClass: Key Vault secrets -> CSI volume + Kubernetes Secret "<name>-kv".
     (list root name identity secretsMap) */}}
{{- define "ai.secretProviderClass" -}}
{{- $root := index . 0 }}{{ $name := index . 1 }}{{ $identity := index . 2 }}{{ $secrets := index . 3 -}}
{{- $id := include "ai.identity" (list $root $identity) | fromYaml -}}
{{- $objects := values $secrets | uniq | sortAlpha -}}
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: {{ $name }}-kv
  labels:
    {{- include "ai.labels" $root | nindent 4 }}
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: {{ required (printf "azure.identities.%s.clientId is required" $identity) $id.clientId | quote }}
    keyvaultName: {{ required (printf "azure.identities.%s.keyVaultName is required" $identity) $id.keyVaultName | quote }}
    tenantId: {{ required "azure.tenantId is required" $root.Values.azure.tenantId | quote }}
    objects: |
      array:
{{- range $objects }}
        - |
          objectName: {{ . }}
          objectType: secret
{{- end }}
  secretObjects:
    - secretName: {{ $name }}-kv
      type: Opaque
      data:
{{- range $objects }}
        - objectName: {{ . }}
          key: {{ . }}
{{- end }}
{{- end }}

{{/* Pod-level security context.  (uid) */}}
{{- define "ai.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ . }}
runAsGroup: {{ . }}
fsGroup: {{ . }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "ai.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/* Pod metadata labels + ServiceAccount for an identity.  (list root name identity) */}}
{{- define "ai.podLabels" -}}
{{- $root := index . 0 }}{{ $name := index . 1 }}{{ $identity := index . 2 -}}
{{ include "ai.labels" $root }}
app.kubernetes.io/name: {{ $name }}
{{- if $identity }}
azure.workload.identity/use: "true"
{{- end }}
{{- end }}

{{- define "ai.serviceAccountName" -}}
{{- if . }}{{ . }}-sa{{ else }}no-identity-sa{{ end -}}
{{- end }}

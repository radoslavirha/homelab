{{/*
Standard labels for all provisioner Jobs.
*/}}
{{- define "provisioner.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Common Job spec fields.
*/}}
{{- define "provisioner.jobSpec" -}}
restartPolicy: OnFailure
automountServiceAccountToken: false
{{- end }}

{{/*
Image used by all provisioner containers.
*/}}
{{- define "provisioner.image" -}}
ghcr.io/radoslavirha/homelab-provisioner:latest
{{- end }}

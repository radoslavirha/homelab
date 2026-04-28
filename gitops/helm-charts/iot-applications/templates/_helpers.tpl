{{/* Returns the subdomain with a trailing dot if provided */}}
{{- define "iot-applications.subdomain" -}}
{{- if . -}}
{{- printf "%s." . }}
{{- end -}}
{{- end -}}

{{/* Returns the provided tag or defaults to latest */}}
{{- define "iot-applications.defaults.tag" -}}
{{- default "latest" . -}}
{{- end -}}

{{/* Returns the provided port or defaults to 80 */}}
{{- define "iot-applications.defaults.port" -}}
{{- int (default 80 .) -}}
{{- end -}}

{{/* Validates port range.
     Expects an integer or string to be passed as the context.
     Input is dictionary with port: string/integer, applicationName: string
*/}}
{{- define "iot-applications.validators.portRange" -}}
{{- $sanitizedPort := int .port -}}
{{- if or (lt $sanitizedPort 1) (gt $sanitizedPort 65535) -}}
{{- fail (printf "Ports must always be between 1 and 65535. Provided value: %d. [apps.%s]." $sanitizedPort .applicationName) -}}
{{- end -}}
{{- end -}}

{{/* Validates image.
     Input is dictionary with image: dictionary, applicationName: string
*/}}
{{- define "iot-applications.validators.image" -}}
{{- $image := .image | default dict -}}
{{- if not (hasKey $image "repository") -}}
{{- fail (printf "Image must have a repository key. [apps.%s.image]." .applicationName) -}}
{{- end -}}

{{- if hasKey $image "pullPolicy" -}}
{{- $allowed := list "Always" "IfNotPresent" "Never" -}}
{{- if not (has $image.pullPolicy $allowed) -}}
{{- fail (printf "Image has invalid pullPolicy '%s'. Allowed values are: %s. [apps.%s.image]." $image.pullPolicy (join ", " $allowed) .applicationName) -}}
{{- end -}}
{{- end -}}

{{- end -}}

{{/* Validates services dict.
     Input is dictionary with services: dictionary, applicationName: string
*/}}
{{- define "iot-applications.validators.services" -}}
{{- $applicationName := .applicationName -}}
{{- range $serviceName, $svc := .services -}}
{{- if not (hasKey $svc "enabled") -}}
{{- fail (printf "Service '%s' must have an 'enabled' key. [apps.%s.services]." $serviceName $applicationName) -}}
{{- end -}}
{{- if $svc.enabled -}}
{{- if hasKey $svc "port" -}}
{{- include "iot-applications.validators.portRange" (dict "port" $svc.port "applicationName" $applicationName) -}}
{{- end -}}
{{- if hasKey $svc "targetPort" -}}
{{- include "iot-applications.validators.portRange" (dict "port" $svc.targetPort "applicationName" $applicationName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/* Validates ingress.
     Input is dictionary with ingress: dictionary, applicationName: string
*/}}
{{- define "iot-applications.validators.ingress" -}}
{{- if not (hasKey .ingress "enabled") -}}
{{- fail (printf "Ingress configuration must have an 'enabled' key with boolean value.. [apps.%s.ingress]." .applicationName) -}}
{{- end -}}
{{- end -}}

{{/* Validates udpIngress.
     Input is dictionary with udpIngress: dictionary, applicationName: string
*/}}
{{- define "iot-applications.validators.udpIngress" -}}
{{- if and (hasKey .udpIngress "enabled") (.udpIngress.enabled) -}}
{{- if not (hasKey .udpIngress "serviceRef") -}}
{{- fail (printf "udpIngress must have a 'serviceRef' key when enabled. [apps.%s.udpIngress]." .applicationName) -}}
{{- end -}}
{{- if not (hasKey .udpIngress "entrypoint") -}}
{{- fail (printf "udpIngress must have an 'entrypoint' key when enabled. [apps.%s.udpIngress]." .applicationName) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Validates template.
     Input is dictionary with name: string, template: dictionary, applicationName: string
*/}}
{{- define "iot-applications.validators.template" -}}
{{- if not (hasKey .template "content") -}}
{{- fail (printf "Template '%s' must have a content key. [apps.%s.templates]." .name .applicationName) -}}
{{- end -}}

{{- if not (hasKey .template "path") -}}
{{- fail (printf "Template '%s' must have a path key. [apps.%s.templates]." .name .applicationName) -}}
{{- end -}}

{{- if not (hasKey .template "file") -}}
{{- fail (printf "Template '%s' must have a file key. [apps.%s.templates]." .name .applicationName) -}}
{{- end -}}
{{- end -}}

{{/* Returns object identifier composed of component, partOf, and name */}}
{{- define "iot-applications.identifier" -}}
{{- $identifier := ternary (printf "%s-%s" .application.labels.component .name) (printf "%s-%s-%s" .application.labels.component .application.labels.partOf .name) (empty .application.labels.partOf) }}
{{- $identifier | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Returns helm.sh/chart label value */}}
{{- define "iot-applications.chart" -}}
{{- printf "%s-%s" .chart.Name .chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Returns service account name for the given application context */}}
{{- define "iot-applications.serviceAccountName" -}}
{{- $svcAccount := .application.serviceAccount | default dict -}}
{{- if $svcAccount.name -}}
{{ $svcAccount.name }}
{{- else -}}
{{ include "iot-applications.identifier" . }}
{{- end -}}
{{- end -}}

{{/* Returns labels for selector */}}
{{- define "iot-applications.labels.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release.Name -}}
{{- end -}}

{{/* Returns standard metadata labels */}}
{{- define "iot-applications.meta.labels" -}}
{{- include "iot-applications.validators.image" (dict "image" (.application.image | default dict) "applicationName" .name) -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/version: {{ include "iot-applications.defaults.tag" .application.image.tag }}
app.kubernetes.io/component: {{ .application.labels.component }}
app.kubernetes.io/part-of: {{ .application.labels.partOf }}
app.kubernetes.io/instance: {{ .release.Name }}
app.kubernetes.io/managed-by: {{ .release.Service }}
helm.sh/chart: {{ include "iot-applications.chart" . }}
{{- end -}}
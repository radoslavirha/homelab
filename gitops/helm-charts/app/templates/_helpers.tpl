{{/* Returns the hostname the app's HTTPRoute serves: ingress.hostname when set, else
     <component>.<vars.domain>. The one definition behind both the HTTPRoute and the
     {{ .app.host }} template variable, so a config URL cannot drift from the route.
     Input is dictionary with application: dictionary, applicationName: string, root: $
*/}}
{{- define "app.hostname" -}}
{{- $ingress := .application.ingress | default dict -}}
{{- if $ingress.hostname -}}
{{- $ingress.hostname -}}
{{- else -}}
{{- $domain := (.root.Values.vars | default dict).domain -}}
{{- if not $domain -}}
{{- fail (printf "vars.domain is required to compute the hostname; set it or ingress.hostname. [ingress].") -}}
{{- end -}}
{{- printf "%s.%s" .application.labels.component $domain -}}
{{- end -}}
{{- end -}}

{{/* Returns the HTTPRoute path prefix without its leading slash: ingress.pathName when the
     key is present — "" included, which serves the app at the root — else the app name.
     Input is dictionary with application: dictionary, applicationName: string
*/}}
{{- define "app.pathName" -}}
{{- $ingress := .application.ingress | default dict -}}
{{- ternary (toString $ingress.pathName) .applicationName (hasKey $ingress "pathName") -}}
{{- end -}}

{{/* Returns the provided tag or defaults to latest */}}
{{- define "app.defaults.tag" -}}
{{- default "latest" . -}}
{{- end -}}

{{/* Returns the provided port or defaults to 80 */}}
{{- define "app.defaults.port" -}}
{{- int (default 80 .) -}}
{{- end -}}

{{/* Validates port range.
     Expects an integer or string to be passed as the context.
     Input is dictionary with port: string/integer, applicationName: string
*/}}
{{- define "app.validators.portRange" -}}
{{- $sanitizedPort := int .port -}}
{{- if or (lt $sanitizedPort 1) (gt $sanitizedPort 65535) -}}
{{- fail (printf "Ports must always be between 1 and 65535. Provided value: %d. [services]." $sanitizedPort) -}}
{{- end -}}
{{- end -}}

{{/* Validates image.
     Input is dictionary with image: dictionary, applicationName: string
*/}}
{{- define "app.validators.image" -}}
{{- $image := .image | default dict -}}
{{- if not (hasKey $image "repository") -}}
{{- fail (printf "Image must have a repository key. [image].") -}}
{{- end -}}

{{- if hasKey $image "pullPolicy" -}}
{{- $allowed := list "Always" "IfNotPresent" "Never" -}}
{{- if not (has $image.pullPolicy $allowed) -}}
{{- fail (printf "Image has invalid pullPolicy '%s'. Allowed values are: %s. [image]." $image.pullPolicy (join ", " $allowed)) -}}
{{- end -}}
{{- end -}}

{{- end -}}

{{/* Validates services dict.
     Input is dictionary with services: dictionary, applicationName: string
*/}}
{{- define "app.validators.services" -}}
{{- $applicationName := .applicationName -}}
{{- range $serviceName, $svc := .services -}}
{{- if not (hasKey $svc "enabled") -}}
{{- fail (printf "Service '%s' must have an 'enabled' key. [services]." $serviceName) -}}
{{- end -}}
{{- if $svc.enabled -}}
{{- if hasKey $svc "port" -}}
{{- include "app.validators.portRange" (dict "port" $svc.port "applicationName" $applicationName) -}}
{{- end -}}
{{- if hasKey $svc "targetPort" -}}
{{- include "app.validators.portRange" (dict "port" $svc.targetPort "applicationName" $applicationName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/* Validates ingress.
     Input is dictionary with ingress: dictionary, applicationName: string
*/}}
{{- define "app.validators.ingress" -}}
{{- if not (hasKey .ingress "enabled") -}}
{{- fail (printf "Ingress configuration must have an 'enabled' key with boolean value.. [ingress].") -}}
{{- end -}}
{{- end -}}

{{/* Validates template.
     Input is dictionary with name: string, template: dictionary, applicationName: string
*/}}
{{- define "app.validators.template" -}}
{{- if not (hasKey .template "content") -}}
{{- fail (printf "Template '%s' must have a content key. [templates]." .name) -}}
{{- end -}}

{{- if not (hasKey .template "path") -}}
{{- fail (printf "Template '%s' must have a path key. [templates]." .name) -}}
{{- end -}}

{{- if not (hasKey .template "file") -}}
{{- fail (printf "Template '%s' must have a file key. [templates]." .name) -}}
{{- end -}}

{{- /* validate is optional. A typo that silently disables validation is exactly the
       failure this feature exists to prevent, so reject anything unexpected. */}}
{{- if hasKey .template "validate" -}}
{{- $validate := .template.validate -}}
{{- if not (or (kindIs "bool" $validate) (kindIs "map" $validate)) -}}
{{- fail (printf "Template '%s' has an invalid validate key. Allowed values are a boolean or a map. [templates]." .name) -}}
{{- end -}}
{{- if kindIs "map" $validate -}}
{{- $allowed := list "repository" "tag" "args" "runAsUser" -}}
{{- range $key, $_ := $validate -}}
{{- if not (has $key $allowed) -}}
{{- fail (printf "Template '%s' has an unknown validate key '%s'. Allowed keys are: %s. [templates]." $.name $key (join ", " $allowed)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* secrets is optional: a map of name -> OpenBao reference, read in the template as
       .secrets.<name>. */}}
{{- if hasKey .template "secrets" -}}
{{- if not (kindIs "map" .template.secrets) -}}
{{- fail (printf "Template '%s' has an invalid secrets key. It must be a map of variable name to {key, property}. [templates]." .name) -}}
{{- end -}}
{{- range $variable, $ref := .template.secrets -}}
{{- if not (and (kindIs "map" $ref) $ref.key) -}}
{{- fail (printf "Template '%s' secret '%s' must be a map with a key. [templates.%s.secrets]." $.name $variable $.name) -}}
{{- end -}}
{{- range $refKey, $_ := $ref -}}
{{- if not (has $refKey (list "key" "property")) -}}
{{- fail (printf "Template '%s' secret '%s' has an unknown key '%s'. Allowed keys are: key, property. [templates.%s.secrets]." $.name $variable $refKey $.name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Returns, as JSON, everything a config template can read apart from its secrets:
       .vars  the top-level `vars` map, whole — the chart never lists what is in it
       .app   built-ins derived from the application definition, so a config cannot
              drift from the Service and HTTPRoute the chart renders from the same fields
     Input is dictionary with root: $, application: dictionary, applicationName: string
*/}}
{{- define "app.template.context" -}}
{{- $application := .application -}}
{{- $ingress := $application.ingress | default dict -}}
{{- $mainService := get ($application.services | default dict) ($ingress.serviceRef | default "") | default dict -}}
{{- $app := dict
      "name" .applicationName
      "group" $application.labels.partOf
      "component" $application.labels.component
      "namespace" .root.Release.Namespace
      "containerPort" ($mainService.targetPort | default 80)
      "pathName" (include "app.pathName" .) -}}
{{- /* Only an app with a route has a host; a template reading .app.host without one
       fails in ESO rather than rendering a URL nothing serves. */}}
{{- if $ingress.enabled -}}
{{- $_ := set $app "host" (include "app.hostname" .) -}}
{{- end -}}
{{- toJson (dict "vars" (.root.Values.vars | default dict) "app" $app) -}}
{{- end -}}

{{/* Returns the ExternalSecret template body for a config template: a prelude that
     rebuilds .vars and .app from JSON and gathers the fetched secrets under .secrets,
     then the content verbatim inside `with`.

     ESO renders with missingkey=error: a typo fails the ExternalSecret and leaves the
     previous Secret — and so the running pods — untouched.

     The JSON is embedded as a double-quoted Go string (toJson twice), not a raw
     backtick string, so a value containing a backtick cannot end it early.
     Input is dictionary with root: $, application: dictionary, applicationName: string, template: dictionary
*/}}
{{- define "app.template.body" -}}
{{- $context := include "app.template.context" . -}}
{{- printf "{{- $context := %s | fromJson -}}\n" (toJson $context) -}}
{{- print "{{- $secrets := dict }}{{ range $name, $value := . }}{{ $_ := set $secrets $name $value }}{{ end -}}\n" -}}
{{- print "{{- $_ := set $context \"secrets\" $secrets -}}\n" -}}
{{- print "{{- with $context -}}\n" -}}
{{- .template.content -}}
{{- print "\n{{- end }}" -}}
{{- end -}}

{{/* initContainers for config templates: one validator per template that asks for it.
     Rendering happens in ESO, not in the pod, so a template without validate adds none.
     Input is dictionary with ctx: dictionary, application: dictionary, applicationName: string
*/}}
{{- define "app.template.initContainers" -}}
{{- $ctx := .ctx -}}
{{- $application := .application -}}
{{- range $templateName, $template := $application.templates | default dict }}
{{- include "app.validators.template" (dict "name" $templateName "template" $template "applicationName" $.applicationName) }}
{{- if $template.validate }}
- name: {{ include "app.identifier" $ctx }}-{{ $templateName }}-validate
  image: {{ include "app.template.validatorImage" (dict "application" $application "template" $template) }}
  imagePullPolicy: {{ $application.image.pullPolicy | default "IfNotPresent" }}
  args:
    {{- /* Where this container mounts the rendered Secret. Not $template.path — that
           is where the main container mounts it, which the validator never sees. */}}
    - "/config/{{ $template.file }}"
    {{- with (ternary dict $template.validate (kindIs "bool" $template.validate)).args }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  securityContext:
    runAsNonRoot: true
    {{- /* Defensive default, not a requirement. Both validator images declare
           `USER 1000` since qr-manager-ui@0.7.1 / homelab-dashboard-ui@0.4.1 and
           satisfy runAsNonRoot unaided — verified in-cluster with this securityContext
           and no runAsUser. It is kept because the chart cannot know what an arbitrary
           validate.repository override contains, and an image whose USER is a NAME
           fails with CreateContainerConfigError "non-numeric user". Supplying a
           known-good UID costs nothing; override via validate.runAsUser. */}}
    runAsUser: {{ (ternary dict $template.validate (kindIs "bool" $template.validate)).runAsUser | default 1000 }}
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
    seccompProfile:
      type: RuntimeDefault
  volumeMounts:
    - name: {{ include "app.identifier" $ctx }}-tpl-{{ $templateName }}
      mountPath: /config
      readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/* Main-container volumeMounts for config templates.
     Input is dictionary with ctx: dictionary, application: dictionary
*/}}
{{- define "app.template.volumeMounts" -}}
{{- $ctx := .ctx -}}
{{- range $templateName, $template := .application.templates | default dict }}
- name: {{ include "app.identifier" $ctx }}-tpl-{{ $templateName }}
  mountPath: {{ $template.path }}
  {{- if $template.subPath }}
  subPath: {{ $template.subPath }}
  {{- end }}
  readOnly: true
{{- end }}
{{- end -}}

{{/* Pod volumes for config templates: the Secret ESO rendered each template into.
     Input is dictionary with ctx: dictionary, application: dictionary
*/}}
{{- define "app.template.volumes" -}}
{{- $ctx := .ctx -}}
{{- range $templateName, $template := .application.templates | default dict }}
- name: {{ include "app.identifier" $ctx }}-tpl-{{ $templateName }}
  secret:
    secretName: {{ include "app.identifier" $ctx }}-tpl-{{ $templateName }}
{{- end }}
{{- end -}}

{{/* Returns the config validator image reference for a template.
     Defaults to <app image repository>-config-validator:<app image tag>, so the existing
     deploy.json tag bump moves both images and a mismatched pair is unrepresentable.
     Input is dictionary with application: dictionary, template: dictionary
*/}}
{{- define "app.template.validatorImage" -}}
{{- $validate := ternary dict .template.validate (kindIs "bool" .template.validate) -}}
{{- $repository := $validate.repository | default (printf "%s-config-validator" .application.image.repository) -}}
{{- $tag := $validate.tag | default (include "app.defaults.tag" .application.image.tag) -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

{{/* Returns object identifier composed of component, partOf, and name */}}
{{- define "app.identifier" -}}
{{- $identifier := ternary (printf "%s-%s" .application.labels.component .name) (printf "%s-%s-%s" .application.labels.component .application.labels.partOf .name) (empty .application.labels.partOf) }}
{{- $identifier | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Returns helm.sh/chart label value */}}
{{- define "app.chart" -}}
{{- printf "%s-%s" .chart.Name .chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Returns service account name for the given application context */}}
{{- define "app.serviceAccountName" -}}
{{- $svcAccount := .application.serviceAccount | default dict -}}
{{- if $svcAccount.name -}}
{{ $svcAccount.name }}
{{- else -}}
{{ include "app.identifier" . }}
{{- end -}}
{{- end -}}

{{/* ── Projected ServiceAccount token + CA bundle ────────────────────────────

     Gives a pod what it needs to call the Kubernetes apiserver — most
     immediately, to fetch the cluster JWKS and verify ServiceAccount tokens.
     Two things are required and neither works alone: a CA bundle (or TLS
     fails outright) and a bearer token (the apiserver runs
     `--anonymous-auth=false`, so an anonymous caller gets 401).

     The token deliberately has NO `audience`, so it is minted for the
     apiserver's own audience (`--api-audiences`, which is the issuer URL and
     differs per cluster). A token minted with a service audience — the kind
     the auth design wants for service-to-service calls — is REJECTED by the
     apiserver. Those belong in `audiences:` below, at their own paths,
     alongside this one; they do not replace it.

     Kept opt-in. `automountServiceAccountToken: false` on the ServiceAccount
     stays as it is: this volume is explicit, scoped and short-lived, which is
     the point. A workload that never calls the apiserver gets nothing.
*/}}

{{/* Mount path. The conventional location, so Kubernetes client libraries
     find the token and CA with no configuration. */}}
{{- define "app.projectedToken.mountPath" -}}
/var/run/secrets/kubernetes.io/serviceaccount
{{- end -}}

{{/* True when the app asked for a projected token.
     Input: application dictionary */}}
{{- define "app.projectedToken.enabled" -}}
{{- $sa := .serviceAccount | default dict -}}
{{- $pt := $sa.projectedToken | default dict -}}
{{- if $pt.enabled -}}true{{- end -}}
{{- end -}}

{{/* Validates projectedToken.
     Input is dictionary with projectedToken: dictionary, applicationName: string */}}
{{- define "app.validators.projectedToken" -}}
{{- if .projectedToken.enabled -}}
{{- range $audience := .projectedToken.audiences | default list -}}
{{- if not (kindIs "string" $audience) -}}
{{- fail (printf "serviceAccount.projectedToken.audiences must be a list of strings. [serviceAccount.projectedToken].") -}}
{{- end -}}
{{- if eq $audience "" -}}
{{- fail (printf "serviceAccount.projectedToken.audiences must not contain an empty string; omit the entry instead. [serviceAccount.projectedToken].") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The projected volume. Input: application dictionary + name (as $ctx). */}}
{{- define "app.projectedToken.volume" -}}
{{- $pt := (.application.serviceAccount | default dict).projectedToken | default dict -}}
{{- include "app.validators.projectedToken" (dict "projectedToken" $pt "applicationName" .name) -}}
- name: kube-api-access
  projected:
    defaultMode: 420
    sources:
      {{- /* Default audience: the only token the apiserver itself accepts. */}}
      - serviceAccountToken:
          path: token
          expirationSeconds: {{ $pt.expirationSeconds | default 3600 }}
      {{- /* Published by Kubernetes into every namespace. Supplies the trust
             root without turning automountServiceAccountToken back on. */}}
      - configMap:
          name: kube-root-ca.crt
          items:
            - key: ca.crt
              path: ca.crt
      {{- /* One token per callee, each useless against any other service. */}}
      {{- range $audience := $pt.audiences | default list }}
      - serviceAccountToken:
          path: token-{{ $audience }}
          audience: {{ $audience | quote }}
          expirationSeconds: {{ $pt.expirationSeconds | default 3600 }}
      {{- end }}
{{- end -}}

{{/* The matching read-only mount. */}}
{{- define "app.projectedToken.volumeMount" -}}
- name: kube-api-access
  mountPath: {{ include "app.projectedToken.mountPath" . }}
  readOnly: true
{{- end -}}

{{/* Returns labels for selector */}}
{{- define "app.labels.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .release.Name -}}
{{- end -}}

{{/* Returns standard metadata labels */}}
{{- define "app.meta.labels" -}}
{{- include "app.validators.image" (dict "image" (.application.image | default dict) "applicationName" .name) -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/version: {{ include "app.defaults.tag" .application.image.tag }}
app.kubernetes.io/component: {{ .application.labels.component }}
app.kubernetes.io/part-of: {{ .application.labels.partOf }}
app.kubernetes.io/instance: {{ .release.Name }}
app.kubernetes.io/managed-by: {{ .release.Service }}
helm.sh/chart: {{ include "app.chart" . }}
{{- end -}}
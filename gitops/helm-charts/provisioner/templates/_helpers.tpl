{{/*
Standard labels for all provisioner Jobs.
*/}}
{{- define "provisioner.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Common pod-spec fields for every provisioner Job.

`automountServiceAccountToken: false` is the repo-wide default (docs/architecture.md) and
stays: an ambient, full-audience, pod-lifetime token is exactly what this chart must not
carry. The projected volume below is the deliberate opposite — one short-lived token, minted
for this pod, used once at startup to log in to OpenBao. Same reasoning, and same shape, as
`app.projectedToken.volume` (gitops/helm-charts/app), minus its `ca.crt` source and audience list: a
provisioner Job never calls the apiserver, so it needs no trust root and no RBAC. OpenBao
verifies the token itself via TokenReview, using the reviewer JWT on its own auth mount.

The ServiceAccount is NOT created by this chart -- emqx-server1 and influxdb2-server1 both
render it into `iot`, so a chart-owned SA would be one object claimed by two Applications.
It is a raw manifest: gitops/k8s-manifests/server1/{iot,mongodb}/ServiceAccount.provisioner.yaml
*/}}
{{- define "provisioner.jobSpec" -}}
restartPolicy: OnFailure
serviceAccountName: {{ .Values.global.serviceAccountName | default "provisioner" }}
automountServiceAccountToken: false
volumes:
  - name: {{ include "provisioner.baoLoginVolumeName" . }}
    projected:
      defaultMode: 420
      sources:
        - serviceAccountToken:
            path: token
            # 600s is the kubelet's floor. A Job logs in once, within seconds of starting,
            # and never re-reads the file -- there is nothing here to keep alive.
            expirationSeconds: 600
{{- end }}

{{/*
Name of the projected-token volume, and the matching read-only mount.

Mounted at the conventional path so `jwt=@...` in the login below needs no explanation, and
so the file lands exactly where it would have with automount on -- without the rest of what
automount brings.
*/}}
{{- define "provisioner.baoLoginVolumeName" -}}
bao-login-token
{{- end }}

{{- define "provisioner.baoLoginVolumeMount" -}}
- name: {{ include "provisioner.baoLoginVolumeName" . }}
  mountPath: /var/run/secrets/kubernetes.io/serviceaccount
  readOnly: true
{{- end }}

{{/*
Image used by all provisioner containers.

Digest-pinned -- see the `image` block in values.yaml for why. The digest wins over the
tag when both are present; the tag stays for readability in `kubectl describe`.
*/}}
{{- define "provisioner.image" -}}
{{- $img := .Values.image | default dict -}}
{{- $repo := $img.repository | default "ghcr.io/radoslavirha/homelab-provisioner" -}}
{{- $tag := $img.tag | default "latest" -}}
{{- if $img.digest -}}
{{ $repo }}:{{ $tag }}@{{ $img.digest }}
{{- else -}}
{{ $repo }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/*
Shell prelude shared by every provisioner Job. Logs in to OpenBao, validates the token it
got before any datastore is touched, and provides read/write helpers that never mistake an
auth or network failure for "secret does not exist".

Requires BAO_HOST and CLUSTER to be set beforehand.
*/}}
{{- define "provisioner.baoPrelude" -}}
# Exchange this pod's ServiceAccount token for a short-lived OpenBao token. Replaces the
# hand-minted, year-long token that used to arrive as a Secret and died on a 768h clamp
# (outage 2026-09-06). The mount is per-cluster and validates only its own API server, so
# the name derives from CLUSTER. Role: iac/modules/vault-config/kubernetes.tf.
BAO_TOKEN=$(bao write -address="${BAO_HOST}" -field=token \
  "auth/kubernetes-${CLUSTER}/login" role=provisioner \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token) || {
  echo "ERROR: Kubernetes auth login to ${BAO_HOST} failed -- refusing to touch any datastore."
  exit 1
}
export BAO_TOKEN

# Fail fast on a dead token. Without this a 403 is indistinguishable from "secret absent"
# further down, and the Job rotates a datastore password it then cannot persist. Still needed
# after the login above: a login can succeed and hand back a token bound to the wrong policy.
if ! bao token lookup -address="${BAO_HOST}" > /dev/null 2>&1; then
  echo "ERROR: OpenBao token invalid/expired or ${BAO_HOST} unreachable — refusing to touch any datastore."
  exit 1
fi

# Echo a field from OpenBao, or nothing when the secret/field genuinely does not exist.
# Any other failure (403, 5xx, network) aborts instead of being read as "absent".
bao_read_field() {
  if _out=$(bao kv get -address="${BAO_HOST}" -field="$2" "$1" 2>&1); then
    printf '%s' "${_out}"
    return 0
  fi
  case "${_out}" in
    *"No value found at"*|*"No data found at"*|*"not present in secret"*) return 0 ;;
  esac
  echo "ERROR: reading '$1' from OpenBao failed: ${_out}" >&2
  exit 1
}

# Persist a secret, retrying briefly. The datastore password has already been rotated by
# the time this runs, so giving up here strands the credential.
bao_write() {
  _path=$1
  shift
  _attempt=1
  while [ "${_attempt}" -le 3 ]; do
    if bao kv put -address="${BAO_HOST}" "${_path}" "$@" > /dev/null; then
      return 0
    fi
    echo "WARN: writing '${_path}' to OpenBao failed (attempt ${_attempt}/3)." >&2
    _attempt=$((_attempt + 1))
    sleep 5
  done
  echo "ERROR: could not write '${_path}' to OpenBao — credential is now out of sync." >&2
  exit 1
}
{{- end }}

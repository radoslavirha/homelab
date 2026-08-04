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

{{/*
Shell prelude shared by every provisioner Job. Validates the OpenBao token before any
datastore is touched, and provides read/write helpers that never mistake an auth or
network failure for "secret does not exist".

Requires BAO_HOST to be set beforehand.
*/}}
{{- define "provisioner.baoPrelude" -}}
# Fail fast on a dead token. Without this a 403 is indistinguishable from "secret absent"
# further down, and the Job rotates a datastore password it then cannot persist.
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

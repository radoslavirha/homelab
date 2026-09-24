# qr-manager-api — sandbox raw manifests

Intentionally empty. The QrManagerApi ApplicationSet renders
`k8s-manifests/<cluster>/qr-manager-api/<env>` for every stage, because production needs
it for the `qr.irha.cz` shortcut (HTTPRoute + addPrefix Middleware); sandbox has no
shortcut. The directory must exist or the sandbox Application fails to compare.

Credentials do not belong here: the chart's ExternalSecret renders them straight into
the config file (`templates.config.secrets` in `helm-values/server1/apps/qr-manager-api/`).

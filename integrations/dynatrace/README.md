# Optional Dynatrace OneAgent integration

This module installs OneAgent only on the blue and green runtime IIS VMs. It is
disabled by default and does not modify the reusable Windows image, image-builder
VM or smoke-test VM.

## Security model

- The Dynatrace token requires only the `InstallerDownload` scope.
- The token value is stored in GCP Secret Manager, never Git or VM metadata.
- A dedicated runtime service account can read only that secret.
- Cloud Build can attach the runtime identity but cannot read the token through
  the startup script or deployment metadata.
- OneAgent is downloaded from the configured Dynatrace environment and its
  Authenticode signature is validated before execution.

## Configure

From the Codespace, run:

```bash
./integrations/dynatrace/setup-dynatrace.sh \
  PROJECT_ID \
  https://ENVIRONMENT_ID.live.dynatrace.com \
  dynatrace-installer-token \
  dynatrace-demo-runtime \
  CLOUD_BUILD_SERVICE_ACCOUNT_EMAIL
```

The command securely prompts for the token and prints the substitutions to set
on both the `reconcile-development-demo` and `reconcile-production-demo` Cloud Build triggers. Keep
`_DYNATRACE_ENABLED=false` to run the original demo.

## Deployment behavior

When enabled, every new application VM retrieves the token, downloads and
installs OneAgent, restarts IIS, validates both the OneAgent service and the IIS
health page, and writes `DYNATRACE_READY` to the serial console. Cloud Build
waits for every VM in the active worker group to report that marker before it can receive
load-balancer traffic. `DYNATRACE_FAILED` blocks promotion and the standard 10-minute failure
teardown still runs.

The host is tagged with application, color, version, environment and ephemeral
metadata. Deleting the worker group removes OneAgent with the VM; historical host records
remain subject to the Dynatrace tenant's retention policy.

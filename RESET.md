# Resetting the demo safely

Use this when a demonstration run is interrupted or you want to clean demo-only
runtime resources before starting over.

The reset path is intentionally guarded:

- it prints a plan by default;
- it only deletes resources when `--apply` is supplied;
- it targets this repository's demo naming conventions;
- it preserves environment load-balancer frontends by default;
- image deletion is opt-in with `--delete-images`.

## Dry run

```bash
infrastructure/deployment/reset-demo.sh --project PROJECT_ID --environment all --zone us-central1-a
```

## Apply cleanup

```bash
infrastructure/deployment/reset-demo.sh --project PROJECT_ID --environment all --zone us-central1-a --apply
```

## Clean only one environment

```bash
infrastructure/deployment/reset-demo.sh --project PROJECT_ID --environment dev --zone us-central1-a
infrastructure/deployment/reset-demo.sh --project PROJECT_ID --environment prod --zone us-central1-a
```

## Also remove generated images

Only do this when you intentionally want to rebuild all image artifacts:

```bash
infrastructure/deployment/reset-demo.sh \
  --project PROJECT_ID \
  --environment all \
  --zone us-central1-a \
  --delete-images \
  --apply
```

## What it targets

- unmanaged instance groups matching `dev-iis-demo-(blue|green)-*` or `prod-iis-demo-(blue|green)-*`;
- runtime VMs attached to those groups;
- optional management stations named `dev-iis-demo-management` or `prod-iis-demo-management`;
- temporary image-build VMs matching `win-image-*` or `win-test-*`;
- temporary IAP firewall rules matching `win-image-*-iap-ssh` or `win-image-*-iap-rdp`;
- optionally, generated images matching `windows-github-runner-*`.

Before a live demo, run the read-only readiness check:

```bash
validation/preflight.sh PROJECT_ID us-central1-a
```

# GitOps blue/green design

## Control flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub-hosted Linux runner
    participant Git as GitHub
    participant Build as Cloud Build
    participant Win as Temporary Windows VM in GCP
    participant GCE as Compute Engine runtime
    participant DT as Dynatrace
    participant LB as Load balancer

    Dev->>Git: Merge app and VERSION change
    Git->>GH: Trigger GitHub Actions workflow
    GH->>Build: Authenticate via OIDC and submit image pipeline
    Build->>Win: Create Windows builder VM
    Win->>Win: Install IIS, .NET, VS, app and smoke-test tools
    Win-->>Build: Windows image passes validation
    Build-->>Git: Publish immutable image metadata
    Git->>Git: Open inactive-color promotion PR
    Dev->>Git: Review and merge desired state
    Git->>Build: Reconcile production
    Build->>GCE: Update inactive-color MIG
    Build->>GCE: Wait for healthy instances
    opt Dynatrace enabled
        GCE->>DT: Download and connect OneAgent
        Build->>GCE: Wait for DYNATRACE_READY on every VM
    end
    Build->>LB: Activate new color
    Build->>LB: Set old color capacity to zero
    Build->>Build: Keep demo available for 10 minutes
    Build->>LB: Delete demo frontend and backend
    Build->>GCE: Delete both MIGs, disks and templates
```

The GitHub-hosted runner is Linux-only and performs orchestration. The actual
Windows image build, Windows installation steps, and validation run inside a
temporary Windows VM launched by Cloud Build in GCP.

## State ownership

| State | Authority |
| --- | --- |
| Application source and semantic version | `projects/sample/` in Git |
| Desired blue/green image versions | `environments/prod/deployment.env` |
| Built application release | Immutable Compute Engine image |
| Running instances | Temporary managed instance groups reconciled from Git |
| Traffic selection | Backend capacity derived from `ACTIVE_COLOR` during the demo |
| Rollback | Git revert of the promotion commit |
| Demo lifetime | Automatic teardown 10 minutes after success or failure |
| Dynatrace enablement | GitHub variables and Secret Manager reference |
| Dynatrace token value | GCP Secret Manager only |
| OneAgent identity | Created independently at runtime on each MIG VM |

The image-build workflow never changes production directly. The deployment
workflow never invents a version; it reconciles the reviewed manifest. This
separation supplies the minimum useful GitOps approval boundary. For this
cost-controlled demonstration, runtime state is intentionally ephemeral: the
manifest and image remain, while both MIGs and the load-balancer resources are
removed after the viewing window.

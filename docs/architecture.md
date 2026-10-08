# GitOps blue/green design

## Control flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant ImageTrigger as Image-build Cloud Build trigger
    participant DevTrigger as Dev Cloud Build trigger
    participant ProdTrigger as Prod Cloud Build trigger
    participant Git as GitHub
    participant Build as Cloud Build
    participant Win as Temporary Windows VM in GCP
    participant GCE as Compute Engine runtime
    participant DT as Dynatrace
    participant DevLB as Dev load balancer
    participant ProdLB as Prod load balancer

    Dev->>Git: Merge app and VERSION change
    Git->>ImageTrigger: Application push
    ImageTrigger->>Build: Run image pipeline
    Build->>Win: Create Windows builder VM
    Win->>Win: Install IIS, .NET, VS, app and smoke-test tools
    Win-->>Build: Windows image passes validation
    Build-->>Dev: Publish immutable image name in build logs
    Dev->>Git: Review Dev or Prod manifest update
    alt Dev manifest changed
        Git->>DevTrigger: Push event
        DevTrigger->>Build: Deploy 2 IIS workers from environments/dev
        Build->>GCE: Reconcile Dev color and backend
        Build->>DevLB: Publish Dev endpoint
    else Prod manifest changed
        Git->>ProdTrigger: Push event
        ProdTrigger->>Build: Deploy 4 IIS workers from environments/prod
        Build->>GCE: Reconcile Prod color and backend
        Build->>ProdLB: Publish Prod endpoint
    end
    opt Dynatrace enabled
        GCE->>DT: Download and connect OneAgent
        Build->>GCE: Wait for DYNATRACE_READY on every VM
    end
    Build->>Build: Keep demo available for 10 minutes
    Build->>GCE: Delete that environment's temporary workers and disks
```

Cloud Build is the CI/CD control plane. It runs repository validation on pull
requests, builds images on matching pushes to `main`, and runs deployment
builds when reviewed deployment state changes. The Windows image build and
validation still run inside temporary Windows VMs launched by Cloud Build.

## State ownership

| State | Authority |
| --- | --- |
| Application source and semantic version | `applications/sample/` in Git |
| Environment topology and desired images | `environments/dev/` and `environments/prod/` |
| Built application release | Immutable Compute Engine image |
| Running instances | Dev: 2; Prod: 4 temporary IIS workers, reconciled from Git |
| Traffic selection | Environment backend group selected by `ACTIVE_COLOR` |
| Rollback | Git revert of the promotion commit |
| Demo lifetime | Each environment is torn down 10 minutes after its deployment |
| Dynatrace enablement | Cloud Build trigger substitutions and Secret Manager reference |
| Dynatrace token value | GCP Secret Manager only |
| OneAgent identity | Created independently at runtime on each worker VM |

The image-build trigger never changes either environment directly. Separate
deployment triggers never invent a version; each reconciles its reviewed
manifest and has a dedicated backend service, health check, address, and
frontend. This separation supplies the minimum useful GitOps approval boundary. For this
cost-controlled demonstration, worker VMs are intentionally ephemeral: each
environment's manifest, image, and load-balancer resources remain, while its
workers are removed after the viewing window.

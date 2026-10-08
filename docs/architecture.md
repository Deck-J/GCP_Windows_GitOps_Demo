# GitOps blue/green design

## Control flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Actions as GitHub Actions workflows
    participant Git as GitHub
    participant Build as Cloud Build
    participant Win as Temporary Windows VM in GCP
    participant GCE as Compute Engine runtime
    participant Mgmt as Optional private management station
    participant DT as Dynatrace
    participant DevLB as Dev load balancer
    participant ProdLB as Prod load balancer

    Dev->>Git: Merge app and VERSION change
    Git->>Actions: Application push to main
    Actions->>Build: Submit image build with Workload Identity Federation
    Build-->>Actions: Stream logs and return final status
    Build->>Win: Create Windows builder VM
    Win->>Win: Install IIS, .NET, VS, app and smoke-test tools
    Win-->>Build: Windows image passes validation
    Build-->>Dev: Publish immutable image name in build logs
    Dev->>Git: Review Dev or Prod manifest update
    alt Dev manifest changed
        Git->>Actions: Dev manifest push
        Actions->>Build: Submit deployment with Workload Identity Federation
        Build->>GCE: Reconcile Dev color and backend
        opt Dev management station enabled
            Build->>Mgmt: Ensure private station and IAP-only RDP ingress
            Mgmt->>GCE: RDP to private Dev workers
        end
        Build->>DevLB: Publish Dev endpoint
    else Prod manifest changed
        Git->>Actions: Prod manifest push
        Actions->>Build: Submit deployment with Workload Identity Federation
        Build->>GCE: Reconcile Prod color and backend
        opt Prod management station enabled
            Build->>Mgmt: Ensure private station and IAP-only RDP ingress
            Mgmt->>GCE: RDP to private Prod workers
        end
        Build->>ProdLB: Publish Prod endpoint
    end
    opt Dynatrace enabled
        GCE->>DT: Download and connect OneAgent
        Build->>GCE: Wait for DYNATRACE_READY on every VM
    end
    Build->>Build: Keep demo available for 10 minutes
    Build->>GCE: Delete that environment's temporary workers and disks
    Build-->>Actions: Stream logs and return final status
```

GitHub Actions starts repository validation on pull requests and submits
matching image builds and reviewed deployments to Cloud Build. Workload
Identity Federation authenticates the submitter without a stored service
account key. Each Action waits for Cloud Build to finish and reports its final
success or failure through the GitHub Actions run. Image creation and image
smoke tests run inside temporary Windows VMs launched by Cloud Build.

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
| Dynatrace enablement | GitHub Actions repository variables and Secret Manager reference |
| Dynatrace token value | GCP Secret Manager only |
| OneAgent identity | Created independently at runtime on each worker VM |

The image workflow never changes either environment directly. Separate
deployment workflows never invent a version; each reconciles its reviewed
manifest and has a dedicated backend service, health check, address, and
frontend. This separation supplies the minimum useful GitOps approval boundary. For this
cost-controlled demonstration, worker VMs are intentionally ephemeral: each
environment's manifest, image, and load-balancer resources remain, while its
workers are removed after the viewing window.

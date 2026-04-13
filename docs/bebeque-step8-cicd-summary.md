# Step 8 — GitHub Actions CI/CD
## Bebeque Energy Platform

---

## What We Built

A production-grade CI/CD pipeline using GitHub Actions that automatically builds, tests, and deploys all four Bebeque microservices to EKS. The pipeline uses a **reusable workflow pattern** — one pipeline definition shared by all four services. A new service gets CI/CD by adding a single caller file, not by copying hundreds of lines of YAML.

---

## Architecture Overview

```
Developer pushes to main
        ↓
Caller workflow triggers (paths filter — only if relevant files changed)
        ↓
Reusable workflow: deploy-service.yml
        ↓
┌─────────────────────────────────┐
│  Job 1: Build and Push to ECR   │
│  - OIDC auth to AWS             │
│  - Docker build                 │
│  - Push with Git SHA tag        │
└─────────────────┬───────────────┘
                  ↓
┌─────────────────────────────────┐
│  Job 2: Deploy to Staging       │
│  - OIDC auth to AWS             │
│  - helm upgrade --install       │
│  - Namespace: staging           │
└─────────────────┬───────────────┘
                  ↓
         ⏸ APPROVAL GATE
    nnnennaorjiugo-source must approve
                  ↓
┌─────────────────────────────────┐
│  Job 3: Deploy to Production    │
│  - OIDC auth to AWS             │
│  - helm upgrade --install       │
│  - Namespace: production        │
└─────────────────────────────────┘
```

---

## Files Created

```
.github/
└── workflows/
    ├── deploy-service.yml              ← reusable workflow (platform team owns this)
    ├── deploy-analytics-api.yml        ← caller
    ├── deploy-biomass-ingestion.yml    ← caller
    ├── deploy-data-ingestion.yml       ← caller
    └── deploy-notification-service.yml ← caller
```

### Reusable Workflow — `deploy-service.yml`

The core pipeline. All four services call this file. It accepts three inputs:
- `service-name` — used to find the Docker context and ECR repo
- `helm-values-staging` — path to the staging values file
- `helm-values-production` — path to the production values file

### Caller Workflows

Thin files, roughly 25 lines each. They define:
- Which branch triggers the pipeline (`main` only)
- Which file paths trigger the pipeline (paths filter)
- Which values files to pass to the reusable workflow

Example — if only `services/analytics-api/` changes, only the analytics-api pipeline triggers. The other three services do not redeploy. If `helm/bebeque-service/` changes, all four services redeploy because all four use the same base chart.

---

## Key Decision 1 — OIDC Authentication (No Static Keys)

### The Problem With Static Keys
The naive approach is to create an IAM user, generate access keys, and store them in GitHub Secrets as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. This is wrong for several reasons:
- Keys are long-lived — if leaked, they work until manually rotated
- Keys have no context — any system that has them can use them from anywhere
- Keys are easy to accidentally commit to Git

### What OIDC Does Instead
GitHub Actions can prove its identity to AWS using a short-lived cryptographic token. The flow works like this:

1. GitHub Actions requests a token from GitHub's OIDC provider
2. The token contains claims: which repo, which branch, which environment
3. AWS verifies the token signature against GitHub's OIDC provider (which we registered in AWS IAM)
4. AWS issues temporary credentials scoped to the IAM role
5. Credentials expire after the job ends — typically 15 minutes

No long-lived secrets are stored anywhere. The credentials cannot be reused outside the pipeline context.

### What We Built in Terraform
A new Terraform file `modules/iam/github-actions.tf` that creates:

**`aws_iam_openid_connect_provider.github`**
Registers GitHub's OIDC provider (`token.actions.githubusercontent.com`) in AWS IAM. This is what allows AWS to verify GitHub's tokens. Two thumbprints are registered — GitHub's published certificate fingerprints.

**`aws_iam_role.github_actions`** (`bebeque-github-actions-role`)
The role the pipeline assumes. The trust policy has two conditions:
- `aud` must equal `sts.amazonaws.com`
- `sub` must match one of:
  - `repo:Hannahmoney/Bebeque-Energy-Platform:ref:refs/heads/main`
  - `repo:Hannahmoney/Bebeque-Energy-Platform:environment:staging`
  - `repo:Hannahmoney/Bebeque-Energy-Platform:environment:production`

This means only your specific repo, on the main branch or in a named environment, can assume this role. A forked repo, a feature branch, or any other AWS account cannot.

**`aws_iam_role_policy.github_actions_ecr`**
Grants the role permission to push images to ECR repos under the `bebeque/` prefix. `GetAuthorizationToken` must be account-wide (AWS requirement). All other ECR actions are scoped to `arn:aws:ecr:us-east-1:478544567935:repository/bebeque/*`.

**`aws_iam_role_policy.github_actions_eks`**
Grants `eks:DescribeCluster` on the bebeque cluster only. This is required so Helm can generate a kubeconfig and talk to the Kubernetes API server.

### EKS Access Entry
The pipeline role also needed a Kubernetes-level access entry. AWS IAM authentication gets you past the AWS API, but Kubernetes has its own RBAC layer. We created an access entry and associated `AmazonEKSClusterAdminPolicy` so Helm can create and update resources in both namespaces.

```powershell
aws eks create-access-entry `
  --cluster-name bebeque-eks-cluster `
  --principal-arn arn:aws:iam::478544567935:role/bebeque-github-actions-role `
  --type STANDARD

aws eks associate-access-policy `
  --cluster-name bebeque-eks-cluster `
  --principal-arn arn:aws:iam::478544567935:role/bebeque-github-actions-role `
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy `
  --access-scope type=cluster
```

---

## Key Decision 2 — Git SHA Tags (Not `latest`)

Every Docker image is tagged with the short Git SHA of the commit that built it — the first 7 characters of `GITHUB_SHA`. For example: `478544567935.dkr.ecr.us-east-1.amazonaws.com/bebeque/analytics-api:a335454`

### Why Not `latest`
- `latest` tells you nothing — you cannot trace it to a commit
- With immutable ECR tags enabled, `latest` cannot be overwritten once pushed — the pipeline would fail on every subsequent push
- In incident response you need to know exactly what code is running — a SHA gives you that instantly

### Why SHA Tags Are Better
- Every deployment is fully traceable to a specific commit
- You can see in ECR exactly which commit produced each image
- Rollbacks are explicit — you redeploy a specific SHA, not "the previous latest"
- The Helm `--set image.tag=<sha>` command records the exact image in the Helm release history

The SHA is generated in the pipeline with:
```bash
echo "tag=${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
```

---

## Key Decision 3 — Paths Filters

Each caller workflow specifies exactly which file paths trigger it:

```yaml
on:
  push:
    branches:
      - main
    paths:
      - 'services/analytics-api/**'
      - 'helm/bebeque-service/**'
      - '.github/workflows/deploy-analytics-api.yml'
      - '.github/workflows/deploy-service.yml'
```

This means:
- Pushing a Terraform change does not trigger any application pipeline
- Pushing a README change does not trigger any pipeline
- Pushing a change to `services/analytics-api/` triggers only analytics-api
- Pushing a change to `helm/bebeque-service/` triggers all four services — because all four use the same base chart and a chart change affects every service

This is important for cost and speed. Unnecessary pipeline runs waste GitHub Actions minutes and slow down feedback loops.

---

## Key Decision 4 — GitHub Environments and Approval Gate

### What GitHub Environments Are
A named deployment target in GitHub with configurable protection rules. We created two environments:
- `staging` — no protection rules, deploys automatically
- `production` — requires approval from `nnnennaorjiugo-source` before deployment proceeds

### How the Approval Gate Works
When the staging deploy job completes, the pipeline pauses. GitHub sends a notification to `nnnennaorjiugo-source`. That person reviews the staging deploy, then clicks Approve in the GitHub Actions UI. Only then does the production job start.

**Prevent self-review is enabled.** The person who pushed the code cannot approve their own production deployment. This enforces a four-eyes control — two people must be involved in every production change.

### Why This Matters
This is an audit control. Every production deployment has:
- A Git commit SHA — what changed
- A GitHub username — who pushed it
- A GitHub username — who approved it
- A timestamp — when it happened

This is the minimum viable change management process for a platform serving 120 B2B clients.

---

## Bugs Encountered and Fixed

### Bug 1 — Filename Typo
`deploy-analytics-appi.yaml` (double p) was saved instead of `deploy-analytics-api.yml`. GitHub could not find the reusable workflow. Fix: rename the file.

### Bug 2 — OIDC Permissions on Caller Workflows
The reusable workflow requests `id-token: write` for OIDC. GitHub requires the caller workflow to also explicitly grant this permission. Without it, the nested job is blocked. Fix: add `permissions: id-token: write / contents: read` to all four caller workflows.

### Bug 3 — `latest` Tag Rejected by ECR
ECR repos are configured with immutable tags. The `latest` tag already existed from manual pushes in Step 7. ECR rejected the overwrite. Fix: remove `latest` from the pipeline entirely — push only the Git SHA tag.

### Bug 4 — OIDC Sub Claim Format for Environments
The IAM trust policy originally only allowed `ref:refs/heads/main` in the `sub` claim. But when a job runs in a GitHub Environment, the sub claim changes format to `environment:staging` or `environment:production`. The role assumption was rejected for the deploy-staging and deploy-production jobs. Fix: update the trust policy to allow all three formats.

### Bug 5 — Same Values File for Staging and Production
The original reusable workflow had one `helm-values-file` input used for both staging and production deploys. The production job was deploying with the staging values file, which caused Helm ownership conflicts — a NetworkPolicy owned by the staging Helm release could not be imported into the production release. Fix: split into two inputs, `helm-values-staging` and `helm-values-production`.

### Bug 6 — KEDA CRDs Not Installed
The data-ingestion and biomass-ingestion Helm charts render a KEDA `ScaledObject` resource. Helm cannot create a resource type that does not exist in the cluster. Fix: install KEDA 2.13.0 via Helm in the `keda` namespace before deploying those services.

### Bug 7 — Bash Comments in Multiline Run Block
Commented-out lines (`# --wait`) inside a YAML multiline `run` block are passed to bash as commands, which fails. Fix: remove the comments entirely.

---

## Deliberate Gaps — To Fix in Later Steps

### `--wait` Removed From Helm Commands
`--wait` tells Helm to wait until all pods are Ready before marking the deploy successful. This is the correct behaviour in production. It was removed because analytics-api pods cannot start without `DATABASE_URL` and `REDIS_URL` — the deploy would always time out at 5 minutes.

**Fix in Step 11:** External Secrets Operator wires the secrets. Once analytics-api starts cleanly, re-add `--wait --timeout 5m` to both Helm deploy steps.

### HPA Shows `cpu: <unknown>`
The Horizontal Pod Autoscaler needs Metrics Server to read pod CPU usage. Metrics Server is not installed.

**Fix in Step 10:** kube-prometheus-stack includes Metrics Server. Once installed, HPA will show real CPU percentages and begin scaling correctly.

### Trivy and SonarCloud Not Yet in Pipeline
Container image vulnerability scanning (Trivy) and static code analysis (SonarCloud) belong in this pipeline but are not yet added.

**Fix in Step 12:** Trivy runs after Docker build, before ECR push — blocks the pipeline if a critical CVE is found. SonarCloud runs on Python source code before the build.

---

## What the Pipeline Does NOT Do (By Design)

- **Does not run Terraform.** Infrastructure changes are applied manually by the platform team with `terraform apply`. Separating infrastructure changes from application deploys is correct practice at Bebeque's current maturity level.
- **Does not push `latest` tag.** Immutable ECR tags, Git SHA only.
- **Does not deploy feature branches.** Only pushes to `main` trigger deployments.
- **Does not skip the approval gate.** Even in an emergency, production requires a second person to approve.

---

## Rollback Methods

### Method 1 — Helm Rollback
```powershell
helm history analytics-api -n staging
helm rollback analytics-api 4 -n staging
```
Rolls back to a previous Helm revision. Fast, surgical. Does not require a new pipeline run. Use when a bad chart or values change needs to be undone immediately.

### Method 2 — Kubernetes Rollout Undo
```powershell
kubectl rollout undo deployment/analytics-api -n staging
```
Swaps back to the previous ReplicaSet in seconds. Does not update Helm state — Helm still thinks the latest revision is current. Use in emergencies when production is down and you need pods back immediately.

### Method 3 — Pipeline Rollback (Preferred)
Re-run a previous successful pipeline run in the GitHub Actions UI. This redeploys a known good Git SHA through the full pipeline — OIDC auth, ECR push, Helm upgrade, approval gate. Full audit trail, no manual kubectl commands on production. This is the answer you give in incident retrospectives and interviews.

---

## Final State After Step 8

| Service | Staging | Production |
|---|---|---|
| analytics-api | 1/1 Running (old pod) | 0/2 crashlooping |
| notification-service | 1/1 Running | 2/2 Running |
| biomass-ingestion | 0/0 (KEDA — correct) | 0/0 (KEDA — correct) |
| data-ingestion | 0/0 (KEDA — correct) | 0/0 (KEDA — correct) |

analytics-api crashlooping is expected and intentional — missing database secrets. Fixed in Step 11.

notification-service is fully healthy in both namespaces — no database dependency.

KEDA workers scaling to zero is correct — SQS queues are empty so KEDA scales them down. They will scale up automatically when messages arrive.

---

## AWS Resources Created in This Step

| Resource | Type | Purpose |
|---|---|---|
| `token.actions.githubusercontent.com` | IAM OIDC Provider | Trust GitHub Actions tokens |
| `bebeque-github-actions-role` | IAM Role | Pipeline assumes this via OIDC |
| `bebeque-github-actions-ecr` | IAM Role Policy | Push to ECR repos |
| `bebeque-github-actions-eks` | IAM Role Policy | Describe EKS cluster for Helm |

---

*Bebeque Energy Platform — Step 8 complete. Pipeline fully operational.*

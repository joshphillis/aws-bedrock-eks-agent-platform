# AWS Bedrock EKS Agent Platform

A secure, event-driven multi-agent AI platform running on **Amazon EKS** with
**Amazon Bedrock** (Claude 3 Haiku via cross-region inference profile) as the
primary LLM and **OpenAI GPT-4o** as a hot-standby fallback. All inter-agent
communication is asynchronous via **Amazon SQS**. Infrastructure is defined in
Terraform; Kubernetes manifests are managed with Kustomize.

---

## Architecture Overview

```
                         ┌─────────────────────────────────────────────┐
                         │                Amazon EKS                   │
  Client (HTTP)          │  ┌─────────────┐                            │
      │                  │  │Orchestrator │                            │
      │  POST /tasks      │  │  (FastAPI)  │                            │
      └─────────────────►│  │             │─── research-tasks ──►┐     │
                         │  │  Bedrock    │─── analysis-tasks ──►│     │
      GET /tasks/{id}    │  │  Decompose  │─── writer-tasks   ──►│     │
      ◄─────────────────┤  └──────┬──────┘    (SQS queues)      │     │
                         │         │ ▲                            ▼     │
                         │         │ └─── agent-results ◄── Workers    │
                         │         │      (SQS queue)    ┌──────────┐  │
                         │         │                     │ Research │  │
                         │         │                     │ Analysis │  │
                         │         │                     │  Writer  │  │
                         │         │                     └──────────┘  │
                         └─────────┼─────────────────────────────────┘
                                   │  IRSA (per-agent IAM roles)
                    ┌──────────────┼──────────────────────────────┐
                    │              ▼                               │
                    │  ┌─────────────────┐  ┌──────────────────┐  │
                    │  │  Bedrock Runtime │  │ Secrets Manager  │  │
                    │  │  (Claude Haiku) │  │  aiplatform/dev/ │  │
                    │  └─────────────────┘  └──────────────────┘  │
                    │  ┌──────────┐  ┌──────┐  ┌───────────────┐  │
                    │  │   SQS    │  │ SNS  │  │  CloudWatch   │  │
                    │  │ (KMS enc)│  │      │  │  Logs/Alarms  │  │
                    │  └──────────┘  └──────┘  └───────────────┘  │
                    └──────────────────────────────────────────────┘
```

### AWS Services Used

| Service | Purpose |
|---------|---------|
| Amazon EKS (1.32) | Hosts all four agent pods |
| Amazon Bedrock | Primary LLM — Claude 3 Haiku inference profile |
| Amazon SQS | Async task queues and results queue (KMS-encrypted) |
| Amazon SNS | Fan-out topics wired 1:1 to SQS queues |
| AWS Secrets Manager | Shared config + OpenAI fallback key |
| Secrets Store CSI Driver | Mounts Secrets Manager values as K8s Secrets |
| Amazon ECR | Private Docker image registry (one repo per agent) |
| AWS CodeBuild | CI builds and ECR pushes (triggered manually or via GitHub Actions) |
| AWS IAM / IRSA | Per-agent IAM roles bound to K8s ServiceAccounts via OIDC |
| AWS KMS | SQS/SNS message encryption with automatic key rotation |
| Amazon VPC | Private subnets, NAT gateway, VPC endpoints for ECR/SQS/Bedrock |
| CloudWatch | Log groups, alarms, dashboard, budget alerts |

---

## The Four Agents

### Orchestrator
- Exposes `POST /tasks` (HTTP) as the platform entry point.
- Uses Bedrock to decompose the user prompt into three sub-tasks: research, analysis, and writing.
- Publishes each sub-task to the appropriate SQS queue.
- Polls `agent-results` in a background loop and aggregates results.
- Responds to `GET /tasks/{job_id}` with status (`pending` / `complete`) and aggregated results.

### Research Agent
- Long-polls `research-tasks` SQS queue.
- Calls Bedrock with a research specialist prompt; returns structured JSON with `key_findings`, `sources_consulted`, `confidence`, and `summary`.
- Publishes the result to `agent-results`.

### Analysis Agent
- Long-polls `analysis-tasks` SQS queue.
- Calls Bedrock with an analysis specialist prompt.
- Publishes the result to `agent-results`.

### Writer Agent
- Long-polls `writer-tasks` SQS queue.
- Calls Bedrock with a writing specialist prompt.
- Publishes the result to `agent-results`.

All agents fall back to OpenAI GPT-4o when Bedrock returns an error, using the
`OPENAI_API_KEY` sourced from Secrets Manager.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.10 (uses S3 native locking — no DynamoDB required) |
| AWS CLI | 2.15 |
| kubectl | 1.29 |
| Helm | 3.14 |
| kustomize | 5.0 (or `kubectl apply -k`) |

AWS credentials: an IAM user or role with `AdministratorAccess` is sufficient
for a first deploy. IRSA handles all runtime credentials — no long-lived keys
are baked into pods.

---

## Deployment Runbook

### Step 1 — Bootstrap the Terraform state bucket

```bash
aws s3 mb s3://tfstate-aiplatform-dev --region us-east-1
# Enable versioning so use_lockfile works (Terraform >= 1.10 S3 native locking)
aws s3api put-bucket-versioning \
  --bucket tfstate-aiplatform-dev \
  --versioning-configuration Status=Enabled
```

### Step 2 — Enable Bedrock model access

In the AWS Console → Amazon Bedrock → Model access → enable
**Claude 3 Haiku** for `us-east-1`.

The model ID in use is the cross-region inference profile:
```
us.anthropic.claude-3-haiku-20240307-v1:0
```

This is already set in `infra/environments/dev/terraform.tfvars`.

### Step 3 — Review and adjust tfvars

`infra/environments/dev/terraform.tfvars`:
```hcl
aws_region          = "us-east-1"
name                = "aiplatform"
environment         = "dev"
owner_tag           = "joshua"
alert_email         = "you@example.com"
admin_principal_arn = "arn:aws:iam::YOUR_ACCOUNT_ID:user/your-iam-user"
bedrock_model_id    = "us.anthropic.claude-3-haiku-20240307-v1:0"
monthly_budget_usd  = 100
```

### Step 4 — Deploy infrastructure

```bash
cd infra/environments/dev
terraform init
terraform apply
```

After apply, note the outputs — you will need them in later steps:

```bash
terraform output agent_role_arns
terraform output ecr_repository_urls
terraform output eks_cluster_name
```

After apply, activate the GitHub CodeStar connection in the AWS Console:
**Developer Tools → Connections → select the pending connection → Update pending connection**

### Step 5 — Force-delete and repopulate Secrets Manager

On a fresh account Terraform creates the secrets with placeholder values.
If a previous partial apply left stale secrets with `PENDING_DELETION` state,
force-delete them first:

```bash
aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/config \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/openai \
  --force-delete-without-recovery
```

Then re-run `terraform apply` to recreate them, and populate the OpenAI key:

```bash
aws secretsmanager put-secret-value \
  --secret-id aiplatform/dev/openai \
  --secret-string '{"api_key":"sk-..."}'
```

The config secret (`aiplatform/dev/config`) is populated automatically by
Terraform with the correct queue URLs and model ID — no manual edit needed.

### Step 6 — Configure kubectl

```bash
aws eks update-kubeconfig \
  --name eks-aiplatform-dev \
  --region us-east-1
```

### Step 7 — Install the Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager \
  https://aws.github.io/secrets-store-csi-driver-provider-aws
helm repo update

helm install secrets-store-csi-driver \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --wait

helm install aws-secrets-provider \
  aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system \
  --wait
```

### Step 8 — Deploy Kubernetes manifests

```bash
kubectl apply -k k8s/overlays/dev
```

Verify the namespace and pods come up:

```bash
kubectl get pods -n agents
```

Pods will enter `Init` or `Pending` state until images exist in ECR — proceed
to the next step.

### Step 9 — Build and push Docker images via CodeBuild

Trigger a build for each agent. The CodeBuild projects are named
`aiplatform-<agent>-dev`:

```bash
for AGENT in orchestrator research-agent analysis-agent writer-agent; do
  aws codebuild start-build \
    --project-name "aiplatform-${AGENT}-dev" \
    --region us-east-1
done
```

Watch build status:

```bash
# List recent builds for one project
aws codebuild list-builds-for-project \
  --project-name aiplatform-orchestrator-dev \
  --query 'ids[0]' --output text \
| xargs aws codebuild batch-get-builds --ids \
| jq '.builds[0] | {status: .buildStatus, phase: .currentPhase}'
```

### Step 10 — Roll out updated deployments

Once all four builds succeed and images are in ECR:

```bash
kubectl rollout restart deployment -n agents
kubectl rollout status deployment -n agents --timeout=120s
```

---

## Testing the Platform

```bash
# Port-forward the orchestrator service
kubectl -n agents port-forward svc/orchestrator 8080:80

# Submit a task (in a second terminal)
curl -s -X POST http://localhost:8080/tasks \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Analyse the impact of generative AI on software engineering productivity"}' \
  | jq .
# → {"job_id": "abc-123", "status": "pending", "message": "Dispatched 3 sub-tasks"}

# Poll for results using the job_id from above
curl -s http://localhost:8080/tasks/abc-123 | jq .
# → {"job_id": "abc-123", "status": "complete", "results": {...}}

# Health check
curl -s http://localhost:8080/health | jq .
curl -s http://localhost:8080/health/ready | jq .
```

---

## Known-Good Model IDs

| Model | Inference profile ID | Notes |
|-------|---------------------|-------|
| Claude 3 Haiku | `us.anthropic.claude-3-haiku-20240307-v1:0` | Cross-region profile — **use this** |
| Claude 3.5 Sonnet | `us.anthropic.claude-3-5-sonnet-20241022-v2:0` | Higher cost; must enable in console |

> Cross-region inference profiles (`us.*`) require the Bedrock IAM policy to include
> both `arn:aws:bedrock:*::foundation-model/*` **and**
> `arn:aws:bedrock:<region>:<account>:inference-profile/*`. This is already wired
> in `infra/modules/secrets/main.tf`.

---

## Repository Structure

```
.
├── agents/
│   ├── orchestrator/        FastAPI — HTTP entry point, Bedrock decompose, SQS dispatch + results aggregation
│   ├── research-agent/      FastAPI — SQS consumer, Bedrock research specialist
│   ├── analysis-agent/      FastAPI — SQS consumer, Bedrock analysis specialist
│   └── writer-agent/        FastAPI — SQS consumer, Bedrock writing specialist
├── k8s/
│   ├── base/                Namespace, ServiceAccounts, Deployments, NetworkPolicies, SecretProviderClasses
│   └── overlays/dev/        Dev-specific replicas, image tags, IRSA role ARN patches
├── infra/
│   ├── modules/
│   │   ├── networking/      VPC, subnets, NAT gateway, VPC endpoints, security groups
│   │   ├── eks/             EKS cluster 1.32, OIDC provider, node groups (t3.medium / t3.large)
│   │   ├── ecr/             4 ECR repos, lifecycle policies, node-pull permissions
│   │   ├── sqs-sns/         4 SQS queues + DLQs + SNS topics, KMS encryption, queue policies
│   │   ├── secrets/         Secrets Manager secrets, per-agent IRSA roles, Bedrock/SQS/KMS policies
│   │   ├── codebuild/       CodeBuild projects (one per agent), S3 layer cache, GitHub OIDC connection
│   │   └── monitoring/      CloudWatch log groups, alarms, dashboard, AWS Budgets alert
│   └── environments/dev/    Root module wiring all modules, S3 backend (native locking)
└── .github/workflows/
    ├── infra.yml            Terraform validate → plan → apply
    └── agents.yml           Detect changes → CodeBuild trigger → verify
```

---

## Troubleshooting

**Pods stuck in `CreateContainerConfigError`**
The CSI driver could not mount Secrets Manager. Check:
```bash
kubectl describe pod -n agents <pod-name>
# Look for: "failed to mount secrets store" or "error fetching secret"
```
Ensure the IRSA role ARN in `k8s/overlays/dev/kustomization.yaml` matches the
Terraform output `agent_role_arns`, and that the CSI driver pods in `kube-system`
are running.

**Bedrock `AccessDeniedException`**
The inference profile ARN format requires model access to be enabled in the
AWS Console for your region AND the IAM policy must allow both
`foundation-model/*` and `inference-profile/*` resources. Both are set in
`infra/modules/secrets/main.tf`.

**SQS `KMS.KmsDisabledException` or `AccessDenied` on receive/send**
The `sqs_kms` IAM policy attached to each agent role grants
`kms:GenerateDataKey`, `kms:Decrypt`, and `kms:DescribeKey` on the SQS KMS key.
If you recreated the KMS key, re-run `terraform apply` and restart pods.

**`PENDING_DELETION` secret blocks terraform apply**
Force delete with `--force-delete-without-recovery` (see Step 5), then re-apply.

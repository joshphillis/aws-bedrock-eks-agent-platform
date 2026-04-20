# AWS Bedrock EKS Agent Platform

A secure, event-driven multi-agent AI platform running on **Amazon EKS** with
**Amazon Bedrock** (Claude 3.5 Sonnet) as the primary LLM and **OpenAI GPT-4o** as a
hot-standby fallback. All inter-agent communication is asynchronous via **Amazon SQS**.
Infrastructure is defined in Terraform; delivery is GitOps via Flux CD.

Refactored from the [Azure OpenAI AKS Agent Platform](../azure-openai-aks-agent-platform).

---

## Architecture

```
Client → Orchestrator (HTTP) → SQS task queues → Worker Agents (Bedrock)
                     ↑                                      │
                     └──────── SQS agent-results ←──────────┘
```

See [`docs/architecture.md`](docs/architecture.md) for the full component map,
request flow, IRSA identity model, and Architecture Decision Records.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | ≥ 1.7 |
| AWS CLI | ≥ 2.15 |
| kubectl | ≥ 1.29 |
| kustomize | ≥ 5.0 |
| Docker | ≥ 24 |
| Flux CLI | ≥ 2.0 |

AWS credentials: configure OIDC federation for GitHub Actions (`role/github-actions-terraform`
and `role/github-actions-ecr`), or use a local IAM profile with `AdministratorAccess`
for initial bootstrapping.

---

## Getting Started (7 steps)

### 1. Bootstrap Terraform state backend

```bash
aws s3 mb s3://tfstate-aiplatform-dev --region us-east-1
aws dynamodb create-table \
  --table-name tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Enable Bedrock model access

In the AWS Console → Amazon Bedrock → Model access → enable
**Claude 3.5 Sonnet** (`anthropic.claude-3-5-sonnet-20241022-v2:0`) for `us-east-1`.

### 3. Update tfvars

Edit `infra/environments/dev/terraform.tfvars`:
```hcl
admin_principal_arn = "arn:aws:iam::123456789012:user/your-iam-user"
alert_email         = "you@example.com"
```

### 4. Deploy infrastructure

```bash
cd infra/environments/dev
terraform init
terraform apply
```

Note the outputs — you need `agent_role_arns` and `ecr_repository_urls` for the next steps.

### 5. Populate secrets

```bash
# Update the OpenAI fallback key
aws secretsmanager put-secret-value \
  --secret-id aiplatform/dev/openai \
  --secret-string '{"api_key":"sk-..."}'
```

### 6. Patch Kubernetes overlays

Replace `851725205521` placeholders in `k8s/overlays/dev/kustomization.yaml` with the
real AWS account ID from the Terraform outputs.

```bash
851725205521=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/851725205521/${851725205521}/g" k8s/overlays/dev/kustomization.yaml
sed -i "s/851725205521/${851725205521}/g" k8s/base/namespace.yaml
```

### 7. Build images and bootstrap Flux

```bash
# Configure kubectl
aws eks update-kubeconfig --name eks-aiplatform-dev --region us-east-1

# Install Flux
flux bootstrap github \
  --owner=<your-github-org> \
  --repository=aws-bedrock-eks-agent-platform \
  --branch=main \
  --path=k8s/overlays/dev

# Install Secrets Store CSI Driver + AWS provider
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install secrets-store-csi-driver \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true

helm repo add aws-secrets-manager \
  https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install aws-secrets-provider aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system
```

Push a commit to main — GitHub Actions builds the images, pushes to ECR, updates the
kustomization image tags, and Flux reconciles within ~2 minutes.

---

## Testing

```bash
# Port-forward the orchestrator
kubectl -n agents port-forward svc/orchestrator 8080:80

# Submit a task
curl -s -X POST http://localhost:8080/tasks \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Analyse the impact of generative AI on software engineering productivity"}' \
  | jq .

# Poll for results (use the job_id from above)
curl -s http://localhost:8080/tasks/<job_id> | jq .
```

---

## Repository Structure

```
.
├── agents/
│   ├── orchestrator/        FastAPI + Bedrock decompose + SQS dispatch
│   ├── research-agent/      FastAPI + Bedrock research + SQS consumer
│   ├── analysis-agent/      FastAPI + Bedrock analysis + SQS consumer
│   └── writer-agent/        FastAPI + Bedrock writing + SQS consumer
├── k8s/
│   ├── base/                Namespace, ServiceAccounts, Deployments, NetworkPolicies
│   ├── overlays/dev/        Dev-specific replicas, image tags, IRSA role ARNs
│   └── flux/                Flux GitRepository + Kustomization
├── infra/
│   ├── modules/
│   │   ├── networking/      VPC, subnets, NAT, VPC endpoints, security groups
│   │   ├── eks/             EKS cluster, OIDC provider, node groups, add-ons
│   │   ├── ecr/             ECR repos, lifecycle policies, KMS encryption
│   │   ├── sqs-sns/         SQS queues, DLQs, SNS topics, KMS encryption
│   │   ├── secrets/         Secrets Manager, IRSA IAM roles, Bedrock/SQS policies
│   │   └── monitoring/      CloudWatch alarms, dashboards, log groups, budgets
│   └── environments/dev/    Root module wiring all modules together (S3 backend)
├── .github/workflows/
│   ├── infra.yml            Validate → Security scan → Plan → Apply → Smoke test
│   └── agents.yml           Detect changes → Build → Trivy → Push ECR → Update tags → Verify
└── docs/
    └── architecture.md      Component map, request flow, ADRs
```

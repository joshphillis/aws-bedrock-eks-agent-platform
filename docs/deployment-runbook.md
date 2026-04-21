# Deployment Runbook — AWS Bedrock EKS Agent Platform

Full from-scratch deployment guide for `aiplatform` in the `dev` environment
(`us-east-1`, account `851725205521`). Steps are ordered; do not skip ahead.

Commands are shown for **bash (Linux/Mac)** first. Where PowerShell differs
materially, a `> PowerShell` block follows.

---

## 1. Prerequisites

### Tools

| Tool | Minimum | Install |
|------|---------|---------|
| AWS CLI | 2.15 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | 1.10 | https://developer.hashicorp.com/terraform/downloads |
| kubectl | 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14 | https://helm.sh/docs/intro/install/ |
| jq | any | `brew install jq` / `choco install jq` |

### AWS credentials

Configure a profile or environment variables for an IAM user/role with
`AdministratorAccess`. Verify before proceeding:

```bash
aws sts get-caller-identity
```

```powershell
# PowerShell
aws sts get-caller-identity
```

Expected output includes your `Account` number and `Arn`. If this fails, fix
credentials before continuing.

### Bedrock model access

In the AWS Console → **Amazon Bedrock** → **Model access** → enable
**Claude 3 Haiku** for `us-east-1`. This must be done before `terraform apply`
and before any pod starts.

The model ID used is a cross-region inference profile:
```
us.anthropic.claude-3-haiku-20240307-v1:0
```

> **Gotcha — inference profile IAM:** Cross-region inference profiles require
> the IAM policy to allow resources matching *both*
> `arn:aws:bedrock:*::foundation-model/*` **and**
> `arn:aws:bedrock:<region>:<account>:inference-profile/*`. A policy that only
> allows `foundation-model/*` will produce `AccessDeniedException` at runtime
> even though Bedrock model access is enabled. The `secrets` Terraform module
> handles this correctly — do not override it.

---

## 2. One-Time Setup — Terraform State Backend

This is needed once per AWS account. Skip if the bucket already exists.

```bash
aws s3 mb s3://tfstate-aiplatform-dev --region us-east-1

# Enable versioning — required for Terraform S3 native locking (>= 1.10)
aws s3api put-bucket-versioning \
  --bucket tfstate-aiplatform-dev \
  --versioning-configuration Status=Enabled

# Confirm
aws s3api get-bucket-versioning --bucket tfstate-aiplatform-dev
```

```powershell
# PowerShell
aws s3 mb s3://tfstate-aiplatform-dev --region us-east-1

aws s3api put-bucket-versioning `
  --bucket tfstate-aiplatform-dev `
  --versioning-configuration Status=Enabled

aws s3api get-bucket-versioning --bucket tfstate-aiplatform-dev
```

> **Note:** This setup uses Terraform's S3 native locking (`use_lockfile = true`
> in `backend "s3"`). No DynamoDB lock table is required.

---

## 3. Terraform Apply

### 3a. Review tfvars

Edit `infra/environments/dev/terraform.tfvars` and confirm all values:

```hcl
aws_region          = "us-east-1"
name                = "aiplatform"
environment         = "dev"
owner_tag           = "joshua"
alert_email         = "joshua.l.phillis@gmail.com"
admin_principal_arn = "arn:aws:iam::851725205521:user/joshua"
bedrock_model_id    = "us.anthropic.claude-3-haiku-20240307-v1:0"
monthly_budget_usd  = 100
```

### 3b. Init and apply

```bash
cd infra/environments/dev
terraform init
terraform apply
```

```powershell
# PowerShell
cd infra/environments/dev
terraform init
terraform apply
```

Type `yes` when prompted. The apply takes approximately 15–20 minutes (EKS
cluster creation dominates).

### 3c. Save outputs

```bash
terraform output -json > /tmp/tf-outputs.json
cat /tmp/tf-outputs.json | jq '{
  cluster:    .eks_cluster_name.value,
  roles:      .agent_role_arns.value,
  ecr:        .ecr_repository_urls.value,
  config_arn: .config_secret_arn.value
}'
```

```powershell
# PowerShell
terraform output -json | Out-File -Encoding utf8 "$env:TEMP\tf-outputs.json"
Get-Content "$env:TEMP\tf-outputs.json" | jq '{
  cluster:    .eks_cluster_name.value,
  roles:      .agent_role_arns.value,
  ecr:        .ecr_repository_urls.value,
  config_arn: .config_secret_arn.value
}'
```

### 3d. Handle PENDING_DELETION secrets (if re-deploying)

> **Gotcha — 7-day retention window:** Secrets Manager keeps deleted secrets
> for 7 days by default. If you destroyed infrastructure and re-apply within
> that window, `terraform apply` will fail with:
> `InvalidRequestException: You can't create this secret because a secret with
> this name is already scheduled for deletion.`
>
> Fix: force-delete both secrets, then re-apply.

```bash
aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/config \
  --force-delete-without-recovery \
  --region us-east-1

aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/openai \
  --force-delete-without-recovery \
  --region us-east-1

# Wait ~10 seconds for propagation, then re-apply
terraform apply
```

```powershell
# PowerShell
aws secretsmanager delete-secret `
  --secret-id aiplatform/dev/config `
  --force-delete-without-recovery `
  --region us-east-1

aws secretsmanager delete-secret `
  --secret-id aiplatform/dev/openai `
  --force-delete-without-recovery `
  --region us-east-1

Start-Sleep -Seconds 10
terraform apply
```

### 3e. Activate the GitHub CodeStar connection

After apply, the CodeStar connection is in `PENDING` state — CodeBuild builds
will fail until it is activated.

AWS Console → **Developer Tools** → **Connections** →
select `aiplatform-github-dev` → **Update pending connection** →
authorize with your GitHub account.

---

## 4. Populate Secrets

Terraform creates both secrets with placeholder values. The `config` secret
(queue URLs, model ID, region) is populated correctly by Terraform automatically.
Only the `openai` secret needs a real value.

### Set the OpenAI API key

```bash
aws secretsmanager put-secret-value \
  --secret-id aiplatform/dev/openai \
  --secret-string '{"api_key":"sk-YOUR-KEY-HERE"}' \
  --region us-east-1
```

```powershell
# PowerShell — use [System.IO.File] to avoid shell escaping issues with JSON
$json = '{"api_key":"sk-YOUR-KEY-HERE"}'
aws secretsmanager put-secret-value `
  --secret-id aiplatform/dev/openai `
  --secret-string $json `
  --region us-east-1
```

> **PowerShell JSON gotcha:** Passing JSON strings with double quotes via
> PowerShell can corrupt the value if you use inline quoting. For complex JSON,
> write it to a temp file first:
>
> ```powershell
> $json = '{"api_key":"sk-YOUR-KEY-HERE"}'
> [System.IO.File]::WriteAllText("$env:TEMP\secret.json", $json)
> aws secretsmanager put-secret-value `
>   --secret-id aiplatform/dev/openai `
>   --secret-string file://$env:TEMP\secret.json `
>   --region us-east-1
> ```

### Verify both secrets are accessible

```bash
aws secretsmanager get-secret-value \
  --secret-id aiplatform/dev/config \
  --region us-east-1 \
  --query SecretString --output text | jq .

aws secretsmanager get-secret-value \
  --secret-id aiplatform/dev/openai \
  --region us-east-1 \
  --query SecretString --output text | jq .
```

```powershell
# PowerShell
aws secretsmanager get-secret-value `
  --secret-id aiplatform/dev/config `
  --region us-east-1 `
  --query SecretString --output text | jq .

aws secretsmanager get-secret-value `
  --secret-id aiplatform/dev/openai `
  --region us-east-1 `
  --query SecretString --output text | jq .
```

---

## 5. Connect kubectl to the EKS Cluster

```bash
aws eks update-kubeconfig \
  --name eks-aiplatform-dev \
  --region us-east-1

# Verify
kubectl get nodes
```

```powershell
# PowerShell
aws eks update-kubeconfig `
  --name eks-aiplatform-dev `
  --region us-east-1

kubectl get nodes
```

Expected: 2–3 nodes in `Ready` state (one system node group + agent node group).

---

## 6. Install the Secrets Store CSI Driver

The CSI driver and AWS provider must be installed before any agent pod can
start — pods mount Secrets Manager values through the CSI volume.

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

helm repo add aws-secrets-manager \
  https://aws.github.io/secrets-store-csi-driver-provider-aws

helm repo update
```

```powershell
# PowerShell (same commands, line-continuation with backtick)
helm repo add secrets-store-csi-driver `
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

helm repo add aws-secrets-manager `
  https://aws.github.io/secrets-store-csi-driver-provider-aws

helm repo update
```

### Install the CSI driver

```bash
helm install secrets-store-csi-driver \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --wait
```

```powershell
helm install secrets-store-csi-driver `
  secrets-store-csi-driver/secrets-store-csi-driver `
  --namespace kube-system `
  --set syncSecret.enabled=true `
  --wait
```

### Install the AWS Secrets Manager provider

```bash
helm install aws-secrets-provider \
  aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system \
  --wait
```

```powershell
helm install aws-secrets-provider `
  aws-secrets-manager/secrets-store-csi-driver-provider-aws `
  --namespace kube-system `
  --wait
```

### Verify CSI driver pods

```bash
kubectl get pods -n kube-system \
  -l app=secrets-store-csi-driver

kubectl get pods -n kube-system \
  -l app=csi-secrets-store-provider-aws
```

Both DaemonSets should show one pod per node in `Running` state.

### Apply the CSIDriver object

The `k8s/base/secret-provider-classes.yaml` includes the `CSIDriver` resource.
It is applied as part of Step 7 — no separate step needed.

---

## 7. Deploy Kubernetes Manifests

```bash
kubectl apply -k k8s/overlays/dev
```

```powershell
kubectl apply -k k8s/overlays/dev
```

This creates:
- `agents` namespace
- 4 `ServiceAccount` objects (IRSA role ARNs pre-patched in the overlay)
- `CSIDriver` + 4 `SecretProviderClass` objects
- 4 `Deployment` objects (orchestrator, research-agent, analysis-agent, writer-agent)
- `Service` for orchestrator (ClusterIP port 80 → 8080)
- `NetworkPolicy` objects
- `PodDisruptionBudget` for orchestrator

Pods will enter `Pending` or `ErrImagePull` until images exist in ECR.
That is expected — continue to Step 8.

```bash
# Confirm resources were created (pods may show ErrImagePull — that's fine here)
kubectl get all -n agents
```

---

## 8. Trigger CodeBuild Builds

Each agent has its own CodeBuild project named `aiplatform-<agent>-dev`.

```bash
for AGENT in orchestrator research-agent analysis-agent writer-agent; do
  echo "Starting build: aiplatform-${AGENT}-dev"
  aws codebuild start-build \
    --project-name "aiplatform-${AGENT}-dev" \
    --region us-east-1 \
    --query 'build.id' --output text
done
```

```powershell
# PowerShell
foreach ($agent in @("orchestrator","research-agent","analysis-agent","writer-agent")) {
  Write-Host "Starting build: aiplatform-$agent-dev"
  aws codebuild start-build `
    --project-name "aiplatform-$agent-dev" `
    --region us-east-1 `
    --query "build.id" --output text
}
```

> **Gotcha — CodeStar connection must be AVAILABLE:** If the connection is still
> `PENDING` (Step 3e not completed), builds will fail immediately with
> `INVALID_INPUT`. Activate the connection in the console before triggering
> builds.

---

## 9. Wait for Builds and Restart Pods

### Monitor build status

```bash
# Check status of the most recent build for each project
for AGENT in orchestrator research-agent analysis-agent writer-agent; do
  PROJECT="aiplatform-${AGENT}-dev"
  BUILD_ID=$(aws codebuild list-builds-for-project \
    --project-name "$PROJECT" \
    --region us-east-1 \
    --query 'ids[0]' --output text)
  STATUS=$(aws codebuild batch-get-builds \
    --ids "$BUILD_ID" \
    --region us-east-1 \
    --query 'builds[0].buildStatus' --output text)
  echo "${PROJECT}: ${STATUS}"
done
```

```powershell
# PowerShell
foreach ($agent in @("orchestrator","research-agent","analysis-agent","writer-agent")) {
  $project = "aiplatform-$agent-dev"
  $buildId = aws codebuild list-builds-for-project `
    --project-name $project `
    --region us-east-1 `
    --query "ids[0]" --output text
  $status = aws codebuild batch-get-builds `
    --ids $buildId `
    --region us-east-1 `
    --query "builds[0].buildStatus" --output text
  Write-Host "${project}: ${status}"
}
```

Wait until all four report `SUCCEEDED`. Each build takes approximately 3–5 minutes.

### Restart deployments to pull the new images

```bash
kubectl rollout restart deployment -n agents
kubectl rollout status deployment/orchestrator    -n agents --timeout=120s
kubectl rollout status deployment/research-agent  -n agents --timeout=120s
kubectl rollout status deployment/analysis-agent  -n agents --timeout=120s
kubectl rollout status deployment/writer-agent    -n agents --timeout=120s
```

```powershell
# PowerShell
kubectl rollout restart deployment -n agents
kubectl rollout status deployment/orchestrator   -n agents --timeout=120s
kubectl rollout status deployment/research-agent -n agents --timeout=120s
kubectl rollout status deployment/analysis-agent -n agents --timeout=120s
kubectl rollout status deployment/writer-agent   -n agents --timeout=120s
```

---

## 10. Verify Pods Are Running

```bash
kubectl get pods -n agents -o wide
```

Expected output — all pods `1/1 Running`:

```
NAME                              READY   STATUS    RESTARTS   AGE
orchestrator-<hash>               1/1     Running   0          2m
research-agent-<hash>             1/1     Running   0          2m
analysis-agent-<hash>             1/1     Running   0          2m
writer-agent-<hash>               1/1     Running   0          2m
```

If any pod is not `1/1 Running`, diagnose:

```bash
# Show events and volume mount errors
kubectl describe pod -n agents <pod-name>

# Show application logs
kubectl logs -n agents <pod-name> --previous
kubectl logs -n agents <pod-name>
```

### Common failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CreateContainerConfigError` | CSI driver could not mount the secret | Check IRSA role ARN in the overlay matches `terraform output agent_role_arns`; ensure CSI driver pods are Running |
| `ErrImagePull` / `ImagePullBackOff` | ECR image does not exist yet | Wait for CodeBuild to succeed (Step 8–9) |
| `CrashLoopBackOff` on readiness probe | Missing env var — secret key not found | Verify Secrets Manager JSON keys match the `SecretProviderClass` jmesPath aliases in `k8s/base/secret-provider-classes.yaml` |
| `AccessDeniedException` from Bedrock | IAM policy missing inference-profile resource | Re-run `terraform apply`; the policy in `secrets/main.tf` covers both `foundation-model/*` and `inference-profile/*` |

---

## 11. Test the Platform

### Port-forward the orchestrator

Open a dedicated terminal window and keep it running:

```bash
kubectl -n agents port-forward svc/orchestrator 8080:80
```

```powershell
# PowerShell (keep this window open)
kubectl -n agents port-forward svc/orchestrator 8080:80
```

### Submit a task

```bash
# In a second terminal
curl -s -X POST http://localhost:8080/tasks \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Analyse the impact of generative AI on software engineering productivity"}' \
  | jq .
```

```powershell
# PowerShell
$body = '{"prompt": "Analyse the impact of generative AI on software engineering productivity"}'
Invoke-RestMethod -Method Post `
  -Uri http://localhost:8080/tasks `
  -ContentType "application/json" `
  -Body $body | ConvertTo-Json -Depth 10
```

Expected response:

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "pending",
  "message": "Dispatched 3 sub-tasks"
}
```

### Poll for results

```bash
JOB_ID="550e8400-e29b-41d4-a716-446655440000"
curl -s http://localhost:8080/tasks/${JOB_ID} | jq .
```

```powershell
$jobId = "550e8400-e29b-41d4-a716-446655440000"
Invoke-RestMethod -Uri "http://localhost:8080/tasks/$jobId" | ConvertTo-Json -Depth 10
```

Poll until `"status": "complete"`. Each Bedrock call takes a few seconds; all
three sub-tasks run in parallel so total latency is roughly the slowest single
agent.

### Health checks

```bash
curl -s http://localhost:8080/health       | jq .
curl -s http://localhost:8080/health/ready | jq .
```

```powershell
Invoke-RestMethod http://localhost:8080/health       | ConvertTo-Json
Invoke-RestMethod http://localhost:8080/health/ready | ConvertTo-Json
```

---

## 12. Teardown

Destroys all AWS resources. **This is irreversible.** ECR images, SQS messages,
CloudWatch logs, and the EKS cluster are all deleted.

```bash
cd infra/environments/dev
terraform destroy
```

```powershell
cd infra/environments/dev
terraform destroy
```

Type `yes` when prompted. Takes approximately 15 minutes.

### Post-destroy cleanup

The S3 backend bucket and any Secrets Manager secrets still in the 7-day
retention window are NOT removed by `terraform destroy`. Clean up manually
if desired:

```bash
# Empty and delete the state bucket
aws s3 rm s3://tfstate-aiplatform-dev --recursive
aws s3 rb s3://tfstate-aiplatform-dev

# Force-delete secrets still in the retention window
aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/config \
  --force-delete-without-recovery \
  --region us-east-1

aws secretsmanager delete-secret \
  --secret-id aiplatform/dev/openai \
  --force-delete-without-recovery \
  --region us-east-1
```

```powershell
# PowerShell
aws s3 rm s3://tfstate-aiplatform-dev --recursive
aws s3 rb s3://tfstate-aiplatform-dev

aws secretsmanager delete-secret `
  --secret-id aiplatform/dev/config `
  --force-delete-without-recovery `
  --region us-east-1

aws secretsmanager delete-secret `
  --secret-id aiplatform/dev/openai `
  --force-delete-without-recovery `
  --region us-east-1
```

> After force-delete, wait 10–30 seconds before re-running `terraform apply`
> if you are immediately redeploying — the deletion needs time to propagate
> before Terraform can create secrets with the same name.

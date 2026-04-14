# AWS Bedrock EKS Agent Platform — Architecture

## Overview

A secure, event-driven multi-agent AI system deployed on Amazon EKS. Four specialist
agents (orchestrator, research, analysis, writer) coordinate work asynchronously via
Amazon SQS, with AWS Bedrock (Claude 3.5 Sonnet) as the primary LLM and OpenAI GPT-4o
as a hot standby fallback.

---

## Design Principles

| Principle | Implementation |
|-----------|---------------|
| Zero stored credentials | IRSA — pods exchange K8s service account tokens for scoped IAM role credentials via OIDC |
| Private by default | Interface VPC endpoints for Bedrock, SQS, ECR, Secrets Manager, CloudWatch; no services reachable from the internet |
| Event-driven | No synchronous agent-to-agent HTTP. Orchestrator publishes to SQS; workers consume independently and publish results back |
| Least-privilege IAM | Each agent has a dedicated IAM role with only the SQS queues and Bedrock models it actually needs |
| Immutable infrastructure | Every resource defined in Terraform; GitOps delivery via Flux CD |

---

## Component Map

```
Internet / Client
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                                           │
│                                                              │
│  Public Subnets  ───  NAT Gateways (one per AZ)             │
│                                                              │
│  Private Subnets                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  EKS Cluster (eks-aiplatform-dev)                    │   │
│  │                                                      │   │
│  │  System Node Pool (t3.medium × 2)                   │   │
│  │    coredns  kube-proxy  vpc-cni  ebs-csi             │   │
│  │                                                      │   │
│  │  AI-Agents Node Pool (t3.large, 1–3 nodes)          │   │
│  │  ┌──────────────┐  ┌───────────────┐               │   │
│  │  │ Orchestrator │  │ Research Agent│               │   │
│  │  │  (2 replicas)│  │ Analysis Agent│               │   │
│  │  │              │  │ Writer Agent  │               │   │
│  │  └──────┬───────┘  └──────┬────────┘               │   │
│  └─────────┼─────────────────┼────────────────────────┘   │
│            │ IRSA             │ IRSA                        │
│            ▼                  ▼                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  VPC Interface Endpoints                             │   │
│  │  bedrock-runtime · sqs · secretsmanager              │   │
│  │  ecr.api · ecr.dkr · sts · logs · monitoring        │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         │                │                │
         ▼                ▼                ▼
   Bedrock            SQS Queues    Secrets Manager
 (Claude 3.5)    research-tasks     aiplatform/dev/config
                 analysis-tasks     aiplatform/dev/openai
                 writer-tasks
                 agent-results
                 (+ 4 DLQs)
```

---

## Request Flow

```
1. Client → POST /tasks  (orchestrator ClusterIP Service)
2. Orchestrator → Claude (Bedrock) : "decompose this task"
3. Bedrock → JSON plan: {research_task, analysis_task, writer_task}
4. Orchestrator → SQS research-tasks queue
   Orchestrator → SQS analysis-tasks queue
   Orchestrator → SQS writer-tasks queue
5. Each worker polls its queue (long polling, WaitTimeSeconds=20)
6. Worker → Claude (Bedrock) : specialist prompt
7. Worker → SQS agent-results queue
8. Orchestrator background listener → receives results, stores in memory
9. Client → GET /tasks/{job_id} : poll until status == "complete"
```

---

## Identity Model (IRSA)

```
K8s ServiceAccount sa-orchestrator
  annotation: eks.amazonaws.com/role-arn = arn:aws:iam::ACCT:role/role-orchestrator-dev
      │
      │  OIDC token projected into pod
      ▼
IAM OIDC Provider (eks-aiplatform-dev)
      │
      │  AssumeRoleWithWebIdentity
      ▼
IAM Role: role-orchestrator-dev
  Policies:
    - policy-bedrock-aiplatform-dev       (bedrock:InvokeModel on *)
    - policy-sqs-orchestrator-dev         (SQS send on task queues, receive on results)
    - policy-secrets-aiplatform-dev       (secretsmanager:GetSecretValue)
    - policy-cloudwatch-agents-dev        (logs:PutLogEvents)
```

Same pattern for each of the four agents, with queue access scoped to only the
queues each agent sends/receives on.

---

## IAM Role Summary

| Agent | Sends to | Receives from |
|-------|----------|---------------|
| orchestrator | research-tasks, analysis-tasks, writer-tasks | agent-results |
| research-agent | agent-results | research-tasks |
| analysis-agent | agent-results | analysis-tasks |
| writer-agent | agent-results | writer-tasks |

---

## AWS vs Azure Service Mapping

| Azure | AWS |
|-------|-----|
| AKS | EKS |
| Azure OpenAI (GPT-4o) | Bedrock (Claude 3.5 Sonnet) |
| OpenAI SDK fallback | OpenAI SDK fallback (unchanged) |
| Service Bus Premium (topics/subscriptions) | SQS standard queues + SNS topics |
| Key Vault | Secrets Manager |
| ACR | ECR |
| Azure Storage (TF backend) | S3 + DynamoDB (TF backend) |
| Azure Monitor / Log Analytics | CloudWatch Logs + Container Insights |
| Managed Identity (per-pod) | IRSA (IAM Roles for Service Accounts) |
| Workload Identity Federation | EKS OIDC + `AssumeRoleWithWebIdentity` |
| Azure CSI secrets-store | AWS Secrets and Configuration Provider (ASCP) |
| Flux CD (Microsoft extension) | Flux CD (self-managed via Helm) |

---

## Architecture Decision Records

### ADR-001: SQS over EventBridge or MSK

SQS standard queues most closely mirror Service Bus Premium topics with a single
subscription. Long-polling (WaitTimeSeconds=20) keeps latency under 1 second while
eliminating busy-wait CPU cost. EventBridge adds filtering capability but is
unnecessary given the 1:1 topic-to-consumer mapping in this design.

### ADR-002: Bedrock + OpenAI Dual-LLM

Primary: Bedrock Claude 3.5 Sonnet — serverless, no quota management, native AWS
IAM auth, no API keys needed. Fallback: OpenAI GPT-4o via API key stored in Secrets
Manager — invoked only on Bedrock `ClientError` / `BotoCoreError`. Fallback is
synchronous; no circuit-breaker required at this scale.

### ADR-003: IRSA over Pod Identity

EKS Pod Identity (newer) requires the `eks-pod-identity-agent` DaemonSet add-on.
IRSA is more widely supported by tooling (Helm charts, ASCP, Cluster Autoscaler).
Migrating from IRSA to Pod Identity later is a drop-in annotation change.

### ADR-004: S3 + DynamoDB Terraform Backend

Replaces Azure Storage account + container. DynamoDB provides state locking
(equivalent to Storage account lease). Both the S3 bucket and DynamoDB table must be
created manually before `terraform init` (see bootstrap comment in main.tf).

### ADR-005: Separate Node Pools

System pool: `CriticalAddonsOnly=true:NoSchedule` — only kube-system add-ons.
Agents pool: `workload=ai-agents:NoSchedule` — only AI workloads. Agents pool is
autoscaled 1–3 nodes; system pool is fixed at 2. This prevents Bedrock-heavy agent
pods from starving cluster infrastructure.

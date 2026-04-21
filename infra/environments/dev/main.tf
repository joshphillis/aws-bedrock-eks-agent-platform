terraform {
  required_version = ">= 1.7"

  # S3 backend replaces Azure Storage backend.
  # Bootstrap: aws s3 mb s3://tfstate-aiplatform-dev
  # use_lockfile = true uses S3 native locking (no DynamoDB table required;
  # needs Terraform >= 1.10 and an S3 bucket with Object Lock or versioning).
  backend "s3" {
    bucket         = "tfstate-aiplatform-dev"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Owner       = var.owner_tag
      Project     = var.name
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cluster_name = "eks-${var.name}-${var.environment}"

  azs = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]

  tags = {
    Environment = var.environment
    Owner       = var.owner_tag
    Project     = var.name
  }
}

# ── Networking ────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name         = var.name
  environment  = var.environment
  aws_region   = var.aws_region
  cluster_name = local.cluster_name
  vpc_cidr     = "10.0.0.0/16"
  azs          = local.azs

  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

  tags = local.tags
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  name               = var.name
  environment        = var.environment
  aws_region         = var.aws_region
  kubernetes_version = "1.32"

  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  sg_nodes_id        = module.networking.sg_eks_nodes_id

  system_vm_size    = "t3.medium"
  system_node_count = 2

  agent_vm_size   = "t3.large"
  agent_min_count = 1
  agent_max_count = 3

  log_retention_days = 30

  tags = local.tags
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  name         = var.name
  environment  = var.environment
  node_role_arn = module.eks.node_role_arn

  tags = local.tags
}

# ── SQS Queues ────────────────────────────────────────────────────────────────
module "sqs_sns" {
  source = "../../modules/sqs-sns"

  name        = var.name
  environment = var.environment

  tags = local.tags
}

# ── Secrets Manager + IRSA Roles ─────────────────────────────────────────────
module "secrets" {
  source = "../../modules/secrets"

  name             = var.name
  environment      = var.environment
  aws_region       = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  bedrock_model_id = var.bedrock_model_id

  sqs_queue_urls = module.sqs_sns.queue_urls
  sqs_queue_arns = module.sqs_sns.queue_arns

  tags = local.tags
}

# ── CodeBuild (Docker image CI) ───────────────────────────────────────────────
module "codebuild" {
  source = "../../modules/codebuild"

  name        = var.name
  environment = var.environment
  aws_region  = var.aws_region

  github_repo = "joshphillis/aws-bedrock-eks-agent-platform"

  ecr_repository_urls = module.ecr.repository_urls
  ecr_repository_arns = module.ecr.repository_arns

  # Grants the existing GitHub Actions OIDC role permission to start builds.
  # Set to null to skip (e.g. if you manage that role elsewhere).
  github_actions_role_name = "github-actions-ecr"

  tags = local.tags
}

# ── CloudWatch Monitoring ─────────────────────────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  name             = var.name
  environment      = var.environment
  aws_region       = var.aws_region
  eks_cluster_name = module.eks.cluster_name

  sqs_queue_names = {
    research-tasks = "${var.name}-research-tasks-${var.environment}"
    analysis-tasks = "${var.name}-analysis-tasks-${var.environment}"
    writer-tasks   = "${var.name}-writer-tasks-${var.environment}"
    agent-results  = "${var.name}-agent-results-${var.environment}"
  }

  dlq_arns              = module.sqs_sns.dlq_arns
  alert_email_addresses = [var.alert_email]
  monthly_budget_usd    = var.monthly_budget_usd

  tags = local.tags
}

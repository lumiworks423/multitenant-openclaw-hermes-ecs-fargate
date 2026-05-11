# Multi-Tenant OpenClaw & Hermes on ECS Fargate

Multi-tenant AI Agent platform on AWS ECS Fargate (Graviton ARM64), supporting OpenClaw and Hermes agents with per-tenant isolation. Includes EKS + Spark Operator for Agent-driven data analysis.

## Architecture

- **ECS Fargate (ARM64)**: Per-slot independent services for OpenClaw and Hermes
- **EKS + Spark Operator**: Agent submits Spark Jobs via kubectl for data analysis
- **EFS**: Per-tenant Access Points for data isolation
- **ALB + CloudFront**: HTTPS routing with path-based rules per slot
- **Cognito**: OIDC SSO authentication
- **DynamoDB**: Slot management and user assignment
- **Amazon Bedrock**: Kimi K2.5 (Hermes) / DeepSeek V3.2 (OpenClaw)
- **Provisioning Service**: Self-service registration portal (FastAPI + Vanilla JS)

## Repository Structure

```
├── terraform/          # Infrastructure as Code (VPC, ECS, EKS, Cognito, CloudFront, IAM)
├── provisioning/       # Provisioning Service (FastAPI + JS SPA + OIDC)
├── hermes/             # Hermes custom image (Dockerfile: sudo + kubectl + aws cli)
├── spark-s3/           # Spark custom image (Dockerfile: Spark 4.0.2 + hadoop-aws + AWS SDK)
└── scripts/
    ├── deploy-infra.sh             # Terraform: S3 backend + all infrastructure
    ├── deploy.sh                   # Application: build + EFS config + start services
    ├── build-on-ec2.sh             # Runs on temp ARM64 EC2 via SSM
    ├── configure-feishu-hermes.sh  # Configure Feishu for Hermes (optional)
    └── batch-provision.sh          # Batch user creation (facilitator)
```

## Deployment

```bash
# Step 1: Infrastructure (Terraform)
cd scripts
bash deploy-infra.sh

# Step 2: Application (build + config + start)
bash deploy.sh

# Step 3: Feishu integration (optional)
bash configure-feishu-hermes.sh
```

## Multi-Region

All global resources (IAM roles, CloudFront, Cognito domain, S3 buckets) include region suffix to support multi-region deployment. Change `aws_region` in `terraform.tfvars` and redeploy.

## Custom Images

| Image | Registry | Purpose |
|-------|----------|---------|
| `hermes:2026.4.23` | `public.ecr.aws/w7t9b2j0/` | Hermes + sudo + kubectl + aws cli |
| `spark:4.0.2` | `public.ecr.aws/w7t9b2j0/` | Spark 4.0.2 + hadoop-aws + AWS SDK v1/v2 |
| `openclaw:2026.4.21` | `public.ecr.aws/w7t9b2j0/` | OpenClaw (upstream mirror) |

## Workshop

Part of the FlexAI Agentic Workshop on AWS Workshop Studio.

# Multi-Tenant OpenClaw & Hermes on ECS Fargate

Multi-tenant AI Agent platform on AWS ECS Fargate (Graviton ARM64), supporting OpenClaw and Hermes agents with per-tenant isolation.

## Architecture

- **ECS Fargate (ARM64)**: Per-slot independent services for OpenClaw and Hermes
- **EFS**: Per-tenant Access Points for data isolation
- **ALB + CloudFront**: HTTPS routing with path-based rules per slot
- **DynamoDB**: Slot management and user assignment
- **Provisioning Service**: Self-service registration portal (FastAPI + Vanilla JS)

## Repository Structure

```
├── terraform/          # Infrastructure as Code
├── provisioning/       # Provisioning Service (FastAPI + JS SPA)
└── scripts/
    ├── deploy.sh                   # Main deployment script
    ├── build-on-ec2.sh             # Runs on temp EC2 via SSM
    ├── configure-feishu-hermes.sh  # Configure Feishu for Hermes (optional)
    └── batch-provision.sh          # Batch user creation (facilitator)
```

## Usage

```bash
git clone https://github.com/lumiworks423/multitenant-openclaw-hermes-ecs-fargate.git
bash scripts/deploy.sh
```

## Workshop

Part of the FlexAI Agentic Workshop on AWS Workshop Studio.

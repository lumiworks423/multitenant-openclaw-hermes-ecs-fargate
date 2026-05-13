# 快速部署指南

## 前置条件

- AWS CLI 已配置
- Terraform >= 1.5
- 目标 Region 有 Kimi K2.5 模型（必须）

## 步骤 1：检查模型可用性

```bash
# 替换为目标 region
export AWS_REGION=ap-south-1

# 检查 Kimi K2.5 是否可用
aws bedrock list-foundation-models --region $AWS_REGION \
  --query 'modelSummaries[?modelId==`moonshotai.kimi-k2.5`].modelId' --output text

# 应该输出：moonshotai.kimi-k2.5
# 如果为空，换一个 region（已验证可用：ap-south-1, ap-southeast-2, eu-west-2, us-east-1, us-west-2, ap-northeast-1）
```

## 步骤 2：创建配置文件

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`，只需改两项：

```hcl
aws_region     = "ap-south-1"          # 改为你的目标 region
admin_password = "your-password-here"   # 改为你的管理员密码
```

其他保持默认即可：
- `project_name`：不需要改，多 region 不会冲突
- `slot_count`：默认 2，按需调整
- `openclaw_image` / `hermes_image`：ECR Public 镜像，全球可用，不需要改

## 步骤 3：部署基础设施

```bash
cd scripts
bash deploy-infra.sh
```

耗时约 20-25 分钟（EKS 集群 + CloudFront 创建较慢）。支持中断后重跑（幂等）。

## 步骤 4：部署应用

```bash
bash deploy.sh
```

耗时约 6 分钟。完成后 Provisioning Dashboard 和 OpenClaw 即可使用。

## 步骤 5：配置飞书（可选）

```bash
bash configure-feishu-hermes.sh
```

## 验证

部署完成后，访问 CloudFront URL（在 deploy.sh 输出中）：
- Provisioning Dashboard：注册用户、获取 Slot
- OpenClaw Control UI：`/i/slot-XX/`
- Hermes WebUI：`/h/slot-XX/`

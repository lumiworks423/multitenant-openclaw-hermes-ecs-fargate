# ============================================================
# Security Groups
# ============================================================

resource "aws_security_group" "ecs" {
  name_prefix = "${var.project_name}-ecs-"
  description = "ECS Fargate Tasks (OpenClaw + Provisioning)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-ecs-sg" }
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.project_name}-efs-"
  description = "EFS mount targets"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-efs-sg" }
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "Internal ALB - CloudFront VPC Origin"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-alb-sg" }
  lifecycle { create_before_destroy = true }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# --- ALB ingress ---

# CloudFront → ALB :80
resource "aws_security_group_rule" "alb_ingress_cf" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  description       = "HTTP from CloudFront VPC Origin"
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

# --- ECS egress ---

resource "aws_security_group_rule" "ecs_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS outbound (Bedrock, Feishu WebSocket, etc)"
  security_group_id = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP outbound"
  security_group_id = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_nfs" {
  type                     = "egress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.efs.id
  description              = "NFS to EFS"
  security_group_id        = aws_security_group.ecs.id
}

# --- ECS ingress ---

# ALB → OpenClaw tasks :18789 (direct, no Nginx)
resource "aws_security_group_rule" "ecs_ingress_alb_openclaw" {
  type                     = "ingress"
  from_port                = 18789
  to_port                  = 18789
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to OpenClaw tasks"
  security_group_id        = aws_security_group.ecs.id
}

# ALB → Provisioning Service :8000
resource "aws_security_group_rule" "ecs_ingress_alb_provisioning" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "ALB to Provisioning API"
  security_group_id        = aws_security_group.ecs.id
}

# --- EFS ingress ---

resource "aws_security_group_rule" "efs_ingress_nfs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  description              = "NFS from ECS"
  security_group_id        = aws_security_group.efs.id
}

# ============================================================
# IAM — ECS Execution Role
# ============================================================

resource "aws_iam_role" "execution" {
  name = "${var.project_name}-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# IAM — OpenClaw Task Role (Bedrock + EFS + ECS Exec)
# ============================================================

resource "aws_iam_role" "openclaw_task" {
  name = "${var.project_name}-openclaw-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "openclaw_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.openclaw_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel*", "bedrock:ListFoundationModels"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "openclaw_ecs_exec" {
  name = "ecs-exec"
  role = aws_iam_role.openclaw_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "openclaw_efs" {
  name = "efs-access"
  role = aws_iam_role.openclaw_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ]
      Resource = aws_efs_file_system.main.arn
    }]
  })
}

# ============================================================
# IAM — Provisioning Service Task Role (DynamoDB + ECS Exec)
# ============================================================

resource "aws_iam_role" "provisioning_task" {
  name = "${var.project_name}-provisioning-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "provisioning_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.provisioning_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ]
      Resource = [
        aws_dynamodb_table.slots.arn,
        "${aws_dynamodb_table.slots.arn}/index/*",
        aws_dynamodb_table.users.arn,
        "${aws_dynamodb_table.users.arn}/index/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "provisioning_ecs_exec" {
  name = "ecs-exec"
  role = aws_iam_role.provisioning_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# ============================================================
# IAM — SSM Instance Profile (临时 EC2 写 EFS 配置)
# ============================================================

resource "aws_iam_role" "ssm" {
  name = "${var.project_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project_name}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# ============================================================
# IAM — Hermes Task Role (Bedrock + EFS + ECS Exec)
# ============================================================

resource "aws_iam_role" "hermes_task" {
  name = "${var.project_name}-hermes-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "hermes_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.hermes_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel*", "bedrock:ListFoundationModels"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "hermes_efs" {
  name = "efs-access"
  role = aws_iam_role.hermes_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ]
      Resource = aws_efs_file_system.main.arn
    }]
  })
}

resource "aws_iam_role_policy" "hermes_ecs_exec" {
  name = "ecs-exec"
  role = aws_iam_role.hermes_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

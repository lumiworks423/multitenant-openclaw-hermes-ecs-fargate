# ============================================================
# Hermes Warm Pool — N ECS Services (one per slot)
# Each slot: Hermes Agent + Open WebUI (2 containers)
# Hermes connects to Bedrock natively (no LiteLLM needed)
# ============================================================

# ---- Variables ----

variable "hermes_image" {
  description = "Hermes Agent Docker image"
  type        = string
  default     = "nousresearch/hermes-agent:latest"
}

variable "openwebui_image" {
  description = "Open WebUI Docker image"
  type        = string
  default     = "ghcr.io/open-webui/open-webui:main"
}

variable "hermes_cpu" {
  description = "CPU units per Hermes task (1024 = 1 vCPU)"
  type        = number
  default     = 2048
}

variable "hermes_memory" {
  description = "Memory in MB per Hermes task"
  type        = number
  default     = 4096
}

variable "hermes_api_server_key" {
  description = "API Server Key for Hermes (used by Open WebUI to connect)"
  type        = string
  default     = "hermes-openwebui-2026"
  sensitive   = true
}

# ---- EFS Access Points for Hermes + Open WebUI ----

resource "aws_efs_access_point" "hermes" {
  count          = var.slot_count
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/tenant-${local.slot_ids[count.index]}/hermes"
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = "755"
    }
  }

  posix_user {
    gid = 0
    uid = 0
  }

  tags = { Name = "${var.project_name}-ap-hermes-${local.slot_ids[count.index]}" }
}

resource "aws_efs_access_point" "openwebui" {
  count          = var.slot_count
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/tenant-${local.slot_ids[count.index]}/openwebui"
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = "755"
    }
  }

  posix_user {
    gid = 0
    uid = 0
  }

  tags = { Name = "${var.project_name}-ap-openwebui-${local.slot_ids[count.index]}" }
}

# ---- IAM Role for Hermes Task ----

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

resource "aws_iam_role_policy" "hermes_task_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.hermes_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel*", "bedrock:ListFoundationModels", "bedrock:GetFoundationModel"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "hermes_task_ecs_exec" {
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

resource "aws_iam_role_policy" "hermes_task_efs" {
  name = "efs-access"
  role = aws_iam_role.hermes_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ]
      Resource = aws_efs_file_system.main.arn
    }]
  })
}

# ---- ECS Task Definition: Hermes + Open WebUI ----

resource "aws_ecs_task_definition" "hermes" {
  count                    = var.slot_count
  family                   = "${var.project_name}-hermes-${local.slot_ids[count.index]}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.hermes_cpu
  memory                   = var.hermes_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.hermes_task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    # ---- Hermes Agent ----
    {
      name      = "hermes-agent"
      image     = var.hermes_image
      command   = ["gateway", "run"]
      essential = true

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "API_SERVER_ENABLED", value = "true" },
        { name = "API_SERVER_KEY", value = var.hermes_api_server_key }
      ]

      mountPoints = [{
        sourceVolume  = "hermes-data"
        containerPath = "/opt/data"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "hermes-${local.slot_ids[count.index]}"
        }
      }
    },

    # ---- Open WebUI ----
    {
      name      = "open-webui"
      image     = var.openwebui_image
      essential = false

      dependsOn = [{
        containerName = "hermes-agent"
        condition     = "START"
      }]

      portMappings = [{
        containerPort = 8080
        protocol      = "tcp"
      }]

      environment = [
        { name = "OPENAI_API_BASE_URL", value = "http://localhost:8642/v1" },
        { name = "OPENAI_API_KEY", value = var.hermes_api_server_key },
        { name = "WEBUI_AUTH", value = "false" }
      ]

      mountPoints = [{
        sourceVolume  = "openwebui-data"
        containerPath = "/app/backend/data"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "openwebui-${local.slot_ids[count.index]}"
        }
      }
    }
  ])

  volume {
    name = "hermes-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.hermes[count.index].id
        iam             = "ENABLED"
      }
    }
  }

  volume {
    name = "openwebui-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.openwebui[count.index].id
        iam             = "ENABLED"
      }
    }
  }
}

# ---- ECS Service: Hermes ----

resource "aws_ecs_service" "hermes" {
  count            = var.slot_count
  name             = "${var.project_name}-hermes-${local.slot_ids[count.index]}"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.hermes[count.index].arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hermes[count.index].arn
    container_name   = "open-webui"
    container_port   = 8080
  }

  depends_on = [aws_efs_mount_target.main, aws_lb_listener.main]
}

# ---- ALB Target Group: Open WebUI per slot ----

resource "aws_lb_target_group" "hermes" {
  count       = var.slot_count
  name        = "${var.project_name}-h-${local.slot_ids[count.index]}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }
}

# ---- ALB Listener Rules: /h/slot-XX/* → Open WebUI ----

resource "aws_lb_listener_rule" "hermes" {
  count        = var.slot_count
  listener_arn = aws_lb_listener.main.arn
  priority     = 50 + count.index

  condition {
    path_pattern {
      values = ["/h/${local.slot_ids[count.index]}/*", "/h/${local.slot_ids[count.index]}"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hermes[count.index].arn
  }
}

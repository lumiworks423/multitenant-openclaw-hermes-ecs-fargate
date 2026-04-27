# ============================================================
# ECS Cluster
# ============================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ============================================================
# ECR — Provisioning Service image only (Nginx removed)
# ============================================================

resource "aws_ecr_repository" "provisioning" {
  name                 = "${var.project_name}-provisioning"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ============================================================
# OpenClaw Warm Pool — N ECS Services (one per slot)
# Each slot registers to its own ALB Target Group
# ============================================================

resource "aws_ecs_task_definition" "openclaw" {
  count                    = var.slot_count
  family                   = "${var.project_name}-${local.slot_ids[count.index]}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.openclaw_cpu
  memory                   = var.openclaw_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.openclaw_task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "openclaw"
      image     = var.openclaw_image
      essential = true

      portMappings = [{
        containerPort = 18789
        protocol      = "tcp"
      }]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "NODE_OPTIONS", value = "--max-old-space-size=1536" }
      ]

      mountPoints = [{
        sourceVolume  = "openclaw-data"
        containerPath = "/home/node/.openclaw"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = local.slot_ids[count.index]
        }
      }
    }
  ])

  volume {
    name = "openclaw-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.slot[count.index].id
        iam             = "ENABLED"
      }
    }
  }
}

resource "aws_ecs_service" "openclaw" {
  count            = var.slot_count
  name             = "${var.project_name}-${local.slot_ids[count.index]}"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.openclaw[count.index].arn
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
    target_group_arn = aws_lb_target_group.openclaw[count.index].arn
    container_name   = "openclaw"
    container_port   = 18789
  }

  service_registries {
    registry_arn = aws_service_discovery_service.slot[count.index].arn
  }

  depends_on = [aws_efs_mount_target.main, aws_lb_listener.main]
}

# ============================================================
# Provisioning Service — ECS Service
# ============================================================

resource "aws_ecs_task_definition" "provisioning" {
  family                   = "${var.project_name}-provisioning"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.provisioning_task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "provisioning"
      image     = "${aws_ecr_repository.provisioning.repository_url}:latest"
      essential = true

      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "DYNAMODB_SLOTS_TABLE", value = aws_dynamodb_table.slots.name },
        { name = "DYNAMODB_USERS_TABLE", value = aws_dynamodb_table.users.name },
        { name = "ADMIN_PASSWORD", value = var.admin_password },
        { name = "CLOUDFRONT_DOMAIN", value = aws_cloudfront_distribution.main.domain_name },
        { name = "SLOT_COUNT", value = tostring(var.slot_count) }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "provisioning"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "provisioning" {
  name             = "${var.project_name}-provisioning"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.provisioning.arn
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
    target_group_arn = aws_lb_target_group.provisioning.arn
    container_name   = "provisioning"
    container_port   = 8000
  }
}

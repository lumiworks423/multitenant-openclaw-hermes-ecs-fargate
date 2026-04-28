# ============================================================
# EFS — Shared file system, per-tenant Access Points
# ============================================================

resource "aws_efs_file_system" "main" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  tags             = { Name = "${var.project_name}-efs" }
}

resource "aws_efs_mount_target" "main" {
  count           = length(local.azs)
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# Per-tenant Access Points (warm pool slots)
# Each AP roots at /tenant-{slot_id}/openclaw with uid/gid 1000
# Note: EFS path segments cannot start with '.' (AWS API constraint)
resource "aws_efs_access_point" "slot" {
  count          = var.slot_count
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/tenant-${local.slot_ids[count.index]}/openclaw"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  posix_user {
    gid = 1000
    uid = 1000
  }

  tags = { Name = "${var.project_name}-ap-${local.slot_ids[count.index]}" }
}

# Per-tenant Hermes Access Points
# Each AP roots at /tenant-{slot_id}/hermes with uid/gid 10000 (Hermes container default user)
resource "aws_efs_access_point" "hermes" {
  count          = var.slot_count
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/tenant-${local.slot_ids[count.index]}/hermes"
    creation_info {
      owner_gid   = 10000
      owner_uid   = 10000
      permissions = "755"
    }
  }

  posix_user {
    gid = 10000
    uid = 10000
  }

  tags = { Name = "${var.project_name}-hermes-ap-${local.slot_ids[count.index]}" }
}

# Shared Access Point for Provisioning (read templates, etc)
resource "aws_efs_access_point" "shared" {
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/shared"
    creation_info {
      owner_gid   = 0
      owner_uid   = 0
      permissions = "755"
    }
  }

  tags = { Name = "${var.project_name}-ap-shared" }
}

# ============================================================
# DynamoDB — Slots table (warm pool)
# ============================================================

resource "aws_dynamodb_table" "slots" {
  name         = "${var.project_name}-slots"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "slot_id"

  attribute {
    name = "slot_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "slot_id"
    projection_type = "ALL"
  }

  tags = { Name = "${var.project_name}-slots" }
}

# ============================================================
# DynamoDB — Users table
# ============================================================

resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "username"

  attribute {
    name = "username"
    type = "S"
  }

  tags = { Name = "${var.project_name}-users" }
}

# ============================================================
# CloudWatch Log Group
# ============================================================

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 14
}

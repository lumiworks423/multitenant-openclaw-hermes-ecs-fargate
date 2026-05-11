# ============================================================
# SSM Parameter Store — Bridge between Terraform and deploy.sh
# deploy.sh reads these to configure EFS, build images, restart services
# ============================================================

resource "aws_ssm_parameter" "ecs_cluster_name" {
  name  = "/${var.project_name}/ecs-cluster-name"
  type  = "String"
  value = aws_ecs_cluster.main.name
}

resource "aws_ssm_parameter" "efs_id" {
  name  = "/${var.project_name}/efs-id"
  type  = "String"
  value = aws_efs_file_system.main.id
}

resource "aws_ssm_parameter" "private_subnet_id" {
  name  = "/${var.project_name}/private-subnet-id"
  type  = "String"
  value = aws_subnet.private[0].id
}

resource "aws_ssm_parameter" "ecs_sg_id" {
  name  = "/${var.project_name}/ecs-sg-id"
  type  = "String"
  value = aws_security_group.ecs.id
}

resource "aws_ssm_parameter" "ssm_instance_profile" {
  name  = "/${var.project_name}/ssm-instance-profile"
  type  = "String"
  value = aws_iam_instance_profile.ssm.name
}

resource "aws_ssm_parameter" "ecr_provisioning_url" {
  name  = "/${var.project_name}/ecr-provisioning-url"
  type  = "String"
  value = aws_ecr_repository.provisioning.repository_url
}

resource "aws_ssm_parameter" "cloudfront_domain" {
  name  = "/${var.project_name}/cloudfront-domain"
  type  = "String"
  value = aws_cloudfront_distribution.main.domain_name
}

resource "aws_ssm_parameter" "dynamodb_slots_table" {
  name  = "/${var.project_name}/dynamodb-slots-table"
  type  = "String"
  value = aws_dynamodb_table.slots.name
}

resource "aws_ssm_parameter" "dynamodb_users_table" {
  name  = "/${var.project_name}/dynamodb-users-table"
  type  = "String"
  value = aws_dynamodb_table.users.name
}

resource "aws_ssm_parameter" "slot_count" {
  name  = "/${var.project_name}/slot-count"
  type  = "String"
  value = tostring(var.slot_count)
}

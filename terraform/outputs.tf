output "workshop_url" {
  description = "Workshop URL (CloudFront HTTPS)"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "efs_file_system_id" {
  value = aws_efs_file_system.main.id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "ecs_sg_id" {
  value = aws_security_group.ecs.id
}

output "ssm_instance_profile_name" {
  value = aws_iam_instance_profile.ssm.name
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "ecr_provisioning_url" {
  value = aws_ecr_repository.provisioning.repository_url
}

output "dynamodb_slots_table" {
  value = aws_dynamodb_table.slots.name
}

output "dynamodb_users_table" {
  value = aws_dynamodb_table.users.name
}

output "slot_ids" {
  value = local.slot_ids
}

output "efs_access_point_ids" {
  description = "Map of slot_id → EFS Access Point ID"
  value       = { for i, id in local.slot_ids : id => aws_efs_access_point.slot[i].id }
}

output "efs_hermes_access_point_ids" {
  description = "Map of slot_id → Hermes EFS Access Point ID"
  value       = { for i, id in local.slot_ids : id => aws_efs_access_point.hermes[i].id }
}

output "efs_openwebui_access_point_ids" {
  description = "Map of slot_id → Open WebUI EFS Access Point ID"
  value       = { for i, id in local.slot_ids : id => aws_efs_access_point.openwebui[i].id }
}

output "slot_urls" {
  description = "Map of slot_id → {openclaw_url, openwebui_url}"
  value = {
    for i, id in local.slot_ids : id => {
      openclaw_url  = "https://${aws_cloudfront_distribution.main.domain_name}/i/${id}"
      openwebui_url = "https://${aws_cloudfront_distribution.main.domain_name}/h/${id}"
    }
  }
}

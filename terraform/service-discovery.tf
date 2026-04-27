# ============================================================
# AWS Cloud Map — Service Discovery for OpenClaw slots
# Each slot registers as {slot_id}.openclaw.local
# Task IP auto-registered on start, auto-deregistered on stop
# ============================================================

resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "openclaw.local"
  description = "OpenClaw multi-tenant service discovery"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "slot" {
  count = var.slot_count
  name  = local.slot_ids[count.index]

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

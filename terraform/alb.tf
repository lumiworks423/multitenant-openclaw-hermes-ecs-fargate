# ============================================================
# Internal ALB — Per-slot routing (no Nginx)
#   Default: /* → Provisioning Service (:8000) — UI + API
#   Rules:   /i/slot-XX/* → OpenClaw slot-XX (:18789)
# ============================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id
  tags               = { Name = "${var.project_name}-alb" }
}

# ---- Target Groups ----

# Per-slot Target Group → OpenClaw :18789
resource "aws_lb_target_group" "openclaw" {
  count       = var.slot_count
  name        = "${var.project_name}-${local.slot_ids[count.index]}-tg"
  port        = 18789
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/i/${local.slot_ids[count.index]}/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-404"
  }
}

resource "aws_lb_target_group" "provisioning" {
  name        = "${var.project_name}-prov-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/api/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

# ---- Listener :80 — default → Provisioning (UI + API) ----

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.provisioning.arn
  }
}

# ---- Per-slot Listener Rules: /i/slot-XX/* → OpenClaw slot-XX ----

resource "aws_lb_listener_rule" "openclaw" {
  count        = var.slot_count
  listener_arn = aws_lb_listener.main.arn
  priority     = 10 + count.index

  condition {
    path_pattern {
      values = ["/i/${local.slot_ids[count.index]}/*", "/i/${local.slot_ids[count.index]}"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openclaw[count.index].arn
  }
}

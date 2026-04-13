# --- ALB Security Group ---
# The ALB sits in public subnets and accepts traffic from the internet.
# We allow HTTP (80) and HTTPS (443) from anywhere.
# HTTP exists only to redirect to HTTPS — no traffic is served over HTTP.
# Outbound is scoped to the VPC CIDR only — the ALB only needs to
# talk to targets inside the VPC, not the open internet.

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Security group for ALB - allows inbound HTTP and HTTPS from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound to VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = {
    Name        = "${var.project}-alb-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# --- Application Load Balancer ---
# Internet-facing: sits in public subnets, accepts traffic from clients.
# The ALB is the single entry point for all traffic to the platform.
# During the strangler fig migration, the ALB routes some paths to EKS
# and everything else to the EC2 monolith.
# enable_deletion_protection: true — matches real production. You must
# disable this before terraform destroy, same as RDS deletion_protection.

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true

  tags = {
    Name        = "${var.project}-alb"
    Project     = var.project
    Environment = var.environment
  }
}

# --- HTTP Listener ---
# Listens on port 80 and immediately redirects all traffic to HTTPS.
# No content is ever served over plain HTTP.
# This is the production standard — HTTP exists only as a convenience
# redirect for clients that type http:// by habit.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# --- HTTPS Listener ---
# Listens on port 443. Default action returns 404 for any path that
# does not match a listener rule. This is intentional — unknown paths
# should not be forwarded anywhere silently.
# certificate_arn is a variable because the ACM certificate must exist
# before this listener can be created. We reference it by ARN.
# The actual routing rules (which paths go to EKS, which to monolith)
# are added as aws_lb_listener_rule resources below.

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"not found\"}"
      status_code  = "404"
    }
  }
}

# --- Target Groups ---
# One target group per EKS service that the ALB routes to.
# target_type = "ip": required for EKS. Traffic goes directly to pod
# IP addresses, not to node IPs. This is the correct pattern for EKS
# with the AWS Load Balancer Controller.
# Health check paths match the /health endpoints in our service code.

locals {
  target_groups = {
    analytics-api = {
      port              = 8000
      health_check_path = "/health"
    }
    notification-service = {
      port              = 8003
      health_check_path = "/health"
    }
  }
}

resource "aws_lb_target_group" "services" {
  for_each = local.target_groups

  name        = "${var.project}-${each.key}-tg"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = each.value.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name        = "${var.project}-${each.key}-tg"
    Project     = var.project
    Environment = var.environment
    Service     = each.key
  }
}

# --- Listener Rules ---
# These implement the strangler fig routing.
# Path-based rules send specific prefixes to EKS services.
# Anything not matched falls through to the default action (404)
# until we add a rule forwarding remaining traffic to the EC2 monolith.
# Priority 10 and 20 — leaving gaps so we can insert rules later
# without renumbering. Lower number = evaluated first.

resource "aws_lb_listener_rule" "analytics_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services["analytics-api"].arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/analytics/*"]
    }
  }
}

resource "aws_lb_listener_rule" "notification_service" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.services["notification-service"].arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/notifications/*"]
    }
  }
}
# --- ACM Certificate ---
# We request a wildcard certificate covering the apex domain and all
# subdomains. This means one certificate works for:
#   inspireherinitiative.xyz        (apex)
#   api.inspireherinitiative.xyz    (API endpoint)
#   *.inspireherinitiative.xyz      (any future subdomain)
#
# validation_method = "DNS": ACM gives us a CNAME record to add to
# Route53. Once the record exists, ACM validates we own the domain
# and issues the certificate. This is fully automated below.

resource "aws_acm_certificate" "main" {
  domain_name               = "inspireherinitiative.xyz"
  subject_alternative_names = ["*.inspireherinitiative.xyz"]
  validation_method         = "DNS"

  lifecycle {
    # Must create replacement before destroying the old certificate.
    # If you destroy first, the ALB listener has no certificate and
    # goes down. create_before_destroy prevents that.
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project}-acm-cert"
    Project     = var.project
    Environment = var.environment
  }
}

# --- DNS Validation Records ---
# ACM tells us what CNAME records to create to prove domain ownership.
# We create those records automatically in Route53.
# for_each over domain_validation_options handles the wildcard correctly
# — ACM returns one validation record that covers both the apex and
# the wildcard, so we deduplicate by domain_name to avoid creating
# duplicate records.

data "aws_route53_zone" "main" {
  zone_id = "Z10419911AKMOI3T9LUDA"
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

# --- Certificate Validation ---
# Terraform waits here until ACM confirms the certificate is issued.
# This can take up to 5 minutes. The ALB HTTPS listener depends on
# this resource so it cannot be created until the certificate is valid.

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# --- Route53 A Record ---
# Points api.inspireherinitiative.xyz at the ALB.
# This is what clients will use to reach the platform.
# type = "A" with alias = true is the correct pattern for ALB —
# you cannot use a CNAME for an apex domain, and an alias record
# is free whereas a CNAME lookup costs per query.

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.inspireherinitiative.xyz"
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}
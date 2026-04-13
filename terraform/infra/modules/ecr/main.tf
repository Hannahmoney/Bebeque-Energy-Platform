# --- ECR Repositories ---
# One repository per service. This is the production pattern — separate
# repos means separate access controls and separate lifecycle policies.
# You can grant a service permission to pull only its own image.
#
# image_tag_mutability = "IMMUTABLE": once an image is pushed with a tag,
# that tag cannot be overwritten. This is critical for production — you
# always know exactly what is running and you can't accidentally overwrite
# a deployed image. Mutable tags (the default) are a common source of
# "why did production change without a deploy" incidents.
#
# scan_on_push = true: ECR scans every image for known CVEs on push.
# Free, automatic, and gives you visibility into vulnerabilities before
# they reach the cluster.

locals {
  services = [
    "analytics-api",
    "biomass-ingestion",
    "data-ingestion",
    "notification-service"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project}/${each.key}"
    Project     = var.project
    Environment = var.environment
    Service     = each.key
  }
}

# --- Lifecycle Policy ---
# Automatically removes untagged images older than 7 days and keeps
# only the last 10 tagged images per repository.
# Without this, ECR fills up with old images and storage costs grow
# silently. This is a common oversight in demo projects.

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = toset(local.services)
  repository = aws_ecr_repository.services[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
# --- IRSA IAM Roles ---
# IRSA = IAM Roles for Service Accounts.
# Each service gets its own IAM role. The trust policy locks the role to
# one specific Kubernetes service account in one specific namespace.
# This means even if a pod is compromised, it can only access what its
# own role allows — it cannot assume another service's role.
#
# The OIDC provider is what makes this work. When a pod requests AWS
# credentials, EKS presents a signed JWT token to AWS STS. AWS STS
# validates the token against the OIDC provider and checks the
# StringEquals condition before issuing temporary credentials.

locals {
  # Namespace where all services run in production
  namespace = "production"
}

# --- analytics-api ---
# Needs to: connect to RDS, send to notifications queue, read both secrets.
# Does NOT need: S3, biomass queue, data-ingestion queue.

resource "aws_iam_role" "analytics_api" {
  name = "${var.project}-analytics-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:${local.namespace}:analytics-api"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-analytics-api-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "analytics_api" {
  name = "${var.project}-analytics-api-policy"
  role = aws_iam_role.analytics_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = "arn:aws:rds-db:${var.aws_region}:${var.account_id}:dbuser:*/${var.project}_analytics"
      },
      {
        Sid    = "SQSSendNotifications"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueUrl"
        ]
        Resource = var.sqs_queue_arns["notifications"]
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/database-*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/redis-*"
        ]
      }
    ]
  })
}

# --- biomass-ingestion ---
# Needs to: receive and delete from biomass queue only, read database secret.
# GetQueueUrl is required — the SDK needs it to resolve the queue endpoint.

resource "aws_iam_role" "biomass_ingestion" {
  name = "${var.project}-biomass-ingestion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:${local.namespace}:biomass-ingestion"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-biomass-ingestion-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "biomass_ingestion" {
  name = "${var.project}-biomass-ingestion-policy"
  role = aws_iam_role.biomass_ingestion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = var.sqs_queue_arns["biomass"]
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/database-*"
      }
    ]
  })
}

# --- data-ingestion ---
# Needs to: receive and delete from data-ingestion queue, get objects
# from S3 uploads prefix, delete processed files from S3, read database secret.
# Scoped to uploads/* prefix only — cannot touch reports/.

resource "aws_iam_role" "data_ingestion" {
  name = "${var.project}-data-ingestion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:${local.namespace}:data-ingestion"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-data-ingestion-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "data_ingestion" {
  name = "${var.project}-data-ingestion-policy"
  role = aws_iam_role.data_ingestion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = var.sqs_queue_arns["data-ingestion"]
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/database-*"
      },
      {
        Sid    = "S3GetUploads"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${var.s3_bucket_arn}/uploads/*"
      },
      {
        Sid    = "S3ListUploads"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = var.s3_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["uploads/*"]
          }
        }
      }
    ]
  })
}

# --- notification-service ---
# Needs to: receive and delete from notifications queue only, read database secret.

resource "aws_iam_role" "notification_service" {
  name = "${var.project}-notification-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:${local.namespace}:notification-service"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-notification-service-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "notification_service" {
  name = "${var.project}-notification-service-policy"
  role = aws_iam_role.notification_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = var.sqs_queue_arns["notifications"]
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/database-*"
      }
    ]
  })
}


# --- external-secrets-operator ---
# ESO needs permission to read all Bebeque secrets from Secrets Manager.
# This role is assumed by the ESO service account in the external-secrets namespace.

resource "aws_iam_role" "external_secrets" {
  name = "${var.project}-external-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-external-secrets-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "${var.project}-external-secrets-policy"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/database-*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:bebeque/production/redis-*"
        ]
      }
    ]
  })
}
# terraform/infra/modules/iam/fluent-bit.tf

data "aws_iam_policy_document" "fluent_bit_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:logging:fluent-bit"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fluent_bit" {
  name               = "bebeque-fluent-bit-role"
  assume_role_policy = data.aws_iam_policy_document.fluent_bit_assume_role.json

  tags = {
    Project     = "bebeque"
    ManagedBy   = "terraform"
    Component   = "logging"
  }
}

data "aws_iam_policy_document" "fluent_bit_cloudwatch" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups"
    ]
    resources = ["arn:aws:logs:us-east-1:478544567935:log-group:/bebeque/*"]
  }
}

resource "aws_iam_policy" "fluent_bit_cloudwatch" {
  name        = "bebeque-fluent-bit-cloudwatch-policy"
  description = "Allows Fluent Bit to write logs to CloudWatch"
  policy      = data.aws_iam_policy_document.fluent_bit_cloudwatch.json
}

resource "aws_iam_role_policy_attachment" "fluent_bit_cloudwatch" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = aws_iam_policy.fluent_bit_cloudwatch.arn
}

output "fluent_bit_role_arn" {
  description = "IRSA role ARN for Fluent Bit"
  value       = aws_iam_role.fluent_bit.arn
}
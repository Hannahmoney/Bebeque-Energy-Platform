# GitHub Actions OIDC provider
# Tells AWS to trust identity tokens issued by GitHub Actions.
# The thumbprint is GitHub's OIDC certificate thumbprint — this is
# the standard value published by GitHub, not something we generate.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub's OIDC thumbprint — stable, published by GitHub
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  tags = {
    Project     = "bebeque-energy"
    ManagedBy   = "terraform"
  }
}

# IAM role for GitHub Actions pipeline
# The trust policy restricts assumption to:
# - Only your specific repo (Hannahmoney/Bebeque-Energy-Platform)
# - Only the main branch
# A forked repo or a feature branch cannot assume this role.
resource "aws_iam_role" "github_actions" {
  name = "bebeque-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"

        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:Hannahmoney/Bebeque-Energy-Platform:ref:refs/heads/main",
              "repo:Hannahmoney/Bebeque-Energy-Platform:environment:staging",
              "repo:Hannahmoney/Bebeque-Energy-Platform:environment:production"
            ]
          }


          }
        }
    ]
  })

  tags = {
    Project   = "bebeque-energy"
    ManagedBy = "terraform"
  }
}

# ECR permissions — pipeline needs to push images to all four repos
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "bebeque-github-actions-ecr"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is account-wide — cannot be scoped to a repo
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # All other ECR actions scoped to bebeque repos only
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:us-east-1:478544567935:repository/bebeque/*"
      }
    ]
  })
}

# EKS permissions — pipeline needs to describe the cluster
# so that helm can generate a kubeconfig and talk to the API server
resource "aws_iam_role_policy" "github_actions_eks" {
  name = "bebeque-github-actions-eks"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = "arn:aws:eks:us-east-1:478544567935:cluster/bebeque-eks-cluster"
      }
    ]
  })
}
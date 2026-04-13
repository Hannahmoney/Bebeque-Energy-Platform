data "aws_partition" "current" {}

locals {
  cluster_name = "${var.project}-eks-cluster"
}

# --- Cluster IAM Role ---
# EKS control plane needs this role to manage AWS resources on your behalf

resource "aws_iam_role" "cluster" {
  name = "${var.project}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project}-eks-cluster-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Node IAM Role ---
# EC2 nodes need this role to register with the cluster and pull from ECR

resource "aws_iam_role" "node_group" {
  name = "${var.project}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project}-eks-node-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- Control Plane Security Group ---
# Sits on the EKS API server. We allow HTTPS (443) from within the VPC only.
# The control plane uses this to accept traffic from nodes and kubectl.

resource "aws_security_group" "cluster" {
  name        = "${var.project}-eks-cluster-sg"
  description = "Security group for EKS control plane"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-eks-cluster-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# --- Node Security Group ---
# This is the fix for Bug 2. We create this SG explicitly so we own its ID.
# RDS and ElastiCache will use this ID to allow inbound traffic from nodes only.
# Without this, we were trying to read a SG that only exists when SSH is enabled.

resource "aws_security_group" "node" {
  name        = "${var.project}-eks-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  # Nodes must be able to talk to each other freely (pod-to-pod traffic)
  ingress {
    description = "Inter-node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Nodes must receive traffic from the control plane (kubelet, health checks)
  ingress {
    description     = "Control plane to nodes"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]
  }

  # Nodes need outbound internet to reach ECR, S3, SQS, and AWS APIs
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-eks-node-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# --- EKS Cluster ---

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.31"

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]

  tags = {
    Name        = local.cluster_name
    Project     = var.project
    Environment = var.environment
  }
}

# --- Launch Template ---
# A launch template is a reusable EC2 boot configuration.
# By pointing the node group at this template, we control which security group
# gets attached to nodes at launch. This is how we attach our explicit node SG.
# Instance type lives here too — one place to change it if needed.

resource "aws_launch_template" "node" {
  name_prefix = "${var.project}-eks-node-"
  description = "Launch template for ${var.project} EKS worker nodes"

  instance_type = "c7i-flex.large"

  vpc_security_group_ids = [aws_security_group.node.id]

  # Required for EKS managed node groups using a launch template
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project}-eks-node"
      Project     = var.project
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Node Group ---
# managed node group — AWS handles node registration and OS patching.
# We reference the launch template so our node SG is attached.
# Cluster Autoscaler tags are required — without them the autoscaler
# cannot discover this ASG and scaling silently does nothing.

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-node-group"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.private_subnet_ids

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy
  ]

  tags = {
    Name        = "${var.project}-node-group"
    Project     = var.project
    Environment = var.environment
    # Cluster Autoscaler discovery tags — must match cluster name exactly
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
  }
}

# --- OIDC Provider ---
# Enables IRSA (IAM Roles for Service Accounts).
# Pods can assume IAM roles directly without static credentials.
# The TLS certificate thumbprint is how AWS verifies the OIDC issuer is legitimate.

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.project}-eks-oidc"
    Project     = var.project
    Environment = var.environment
  }
}

# --- Cluster Autoscaler IAM Role ---
# IRSA role scoped to the cluster-autoscaler service account in kube-system.
# The StringEquals condition ensures only that exact service account can assume it.

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.project}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project}-cluster-autoscaler-role"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.project}-cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstanceTypes"
        ]
        Resource = "*"
      }
    ]
  })
}





# data "aws_partition" "current" {}

# locals {
#   cluster_name = "${var.project}-eks-cluster"
# }

# resource "aws_iam_role" "cluster" {
#   name = "${var.project}-eks-cluster-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect    = "Allow"
#       Principal = { Service = "eks.amazonaws.com" }
#       Action    = "sts:AssumeRole"
#     }]
#   })

#   tags = {
#     Name        = "${var.project}-eks-cluster-role"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_iam_role_policy_attachment" "cluster_policy" {
#   role       = aws_iam_role.cluster.name
#   policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
# }

# resource "aws_iam_role" "node_group" {
#   name = "${var.project}-eks-node-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect    = "Allow"
#       Principal = { Service = "ec2.amazonaws.com" }
#       Action    = "sts:AssumeRole"
#     }]
#   })

#   tags = {
#     Name        = "${var.project}-eks-node-role"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_iam_role_policy_attachment" "node_worker_policy" {
#   role       = aws_iam_role.node_group.name
#   policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
# }

# resource "aws_iam_role_policy_attachment" "node_cni_policy" {
#   role       = aws_iam_role.node_group.name
#   policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
# }

# resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
#   role       = aws_iam_role.node_group.name
#   policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
# }

# resource "aws_security_group" "cluster" {
#   name        = "${var.project}-eks-cluster-sg"
#   description = "Security group for EKS control plane"
#   vpc_id      = var.vpc_id

#   ingress {
#     description = "HTTPS from VPC"
#     from_port   = 443
#     to_port     = 443
#     protocol    = "tcp"
#     cidr_blocks = ["10.0.0.0/16"]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = {
#     Name        = "${var.project}-eks-cluster-sg"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_eks_cluster" "main" {
#   name     = local.cluster_name
#   role_arn = aws_iam_role.cluster.arn
#   version  = "1.31"

#   vpc_config {
#     subnet_ids              = var.private_subnet_ids
#     security_group_ids      = [aws_security_group.cluster.id]
#     endpoint_private_access = true
#     endpoint_public_access  = true
#   }

#   access_config {
#     authentication_mode = "API_AND_CONFIG_MAP"
#   }

#   depends_on = [
#     aws_iam_role_policy_attachment.cluster_policy
#   ]

#   tags = {
#     Name        = local.cluster_name
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_eks_node_group" "main" {
#   cluster_name    = aws_eks_cluster.main.name
#   node_group_name = "${var.project}-node-group"
#   node_role_arn   = aws_iam_role.node_group.arn
#   subnet_ids      = var.private_subnet_ids

#   instance_types = ["t3.medium"]

#   scaling_config {
#     desired_size = 2
#     min_size     = 1
#     max_size     = 3
#   }

#   update_config {
#     max_unavailable = 1
#   }

#   depends_on = [
#     aws_iam_role_policy_attachment.node_worker_policy,
#     aws_iam_role_policy_attachment.node_cni_policy,
#     aws_iam_role_policy_attachment.node_ecr_policy
#   ]

#   tags = {
#     Name        = "${var.project}-node-group"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# data "tls_certificate" "cluster" {
#   url = aws_eks_cluster.main.identity[0].oidc[0].issuer
# }

# resource "aws_iam_openid_connect_provider" "cluster" {
#   client_id_list  = ["sts.amazonaws.com"]
#   thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
#   url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

#   tags = {
#     Name        = "${var.project}-eks-oidc"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_iam_role" "cluster_autoscaler" {
#   name = "${var.project}-cluster-autoscaler-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect = "Allow"
#       Principal = {
#         Federated = aws_iam_openid_connect_provider.cluster.arn
#       }
#       Action = "sts:AssumeRoleWithWebIdentity"
#       Condition = {
#         StringEquals = {
#           "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
#           "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud" = "sts.amazonaws.com"
#   }
# }
#     }]
#   })

#   tags = {
#     Name        = "${var.project}-cluster-autoscaler-role"
#     Project     = var.project
#     Environment = var.environment
#   }
# }

# resource "aws_iam_role_policy" "cluster_autoscaler" {
#   name = "${var.project}-cluster-autoscaler-policy"
#   role = aws_iam_role.cluster_autoscaler.id

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect = "Allow"
#         Action = [
#           "autoscaling:DescribeAutoScalingGroups",
#           "autoscaling:DescribeAutoScalingInstances",
#           "autoscaling:DescribeLaunchConfigurations",
#           "autoscaling:DescribeScalingActivities",
#           "autoscaling:DescribeTags",
#           "autoscaling:SetDesiredCapacity",
#           "autoscaling:TerminateInstanceInAutoScalingGroup",
#           "ec2:DescribeLaunchTemplateVersions",
#           "ec2:DescribeInstanceTypes"
#         ]
#         Resource = "*"
#       }
#     ]
#   })
# }
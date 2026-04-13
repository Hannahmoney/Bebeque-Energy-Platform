terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket       = "bebeque-terraform-state-us-east-1"
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "./modules/vpc"

  project         = var.project
  environment     = var.environment
  vpc_cidr        = var.vpc_cidr
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
}

module "eks" {
  source = "./modules/eks"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
}

module "rds" {
  source = "./modules/rds"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_password        = var.db_password
  eks_node_sg_id     = module.eks.node_security_group_id
}

module "elasticache" {
  source = "./modules/elasticache"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  redis_auth_token   = var.redis_auth_token
}

module "sqs" {
  source = "./modules/sqs"

  project     = var.project
  environment = var.environment
}

module "ecr" {
  source = "./modules/ecr"

  project     = var.project
  environment = var.environment
}

module "s3" {
  source = "./modules/s3"

  project     = var.project
  environment = var.environment
}

module "iam" {
  source = "./modules/iam"

  project           = var.project
  environment       = var.environment
  aws_region        = var.aws_region
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider     = module.eks.oidc_provider
  oidc_provider_arn = module.eks.oidc_provider_arn
  sqs_queue_arns    = module.sqs.queue_arns
  s3_bucket_arn     = module.s3.bucket_arn
}

module "alb" {
  source = "./modules/alb"

  project           = var.project
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  eks_cluster_name  = module.eks.cluster_name
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn
}
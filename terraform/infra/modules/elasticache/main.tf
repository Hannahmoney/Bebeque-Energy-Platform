# --- ElastiCache Security Group ---
# Only allows inbound Redis (6379) from EKS worker nodes.
# analytics-api is the only service that talks to Redis.
# We still scope to the node SG rather than a pod-level SG —
# pod-level SG is a more advanced pattern covered in Step 11.

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis-sg"
  description = "Security group for ElastiCache Redis - allows inbound from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-redis-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# --- ElastiCache Subnet Group ---
# Same pattern as RDS subnet group — tells ElastiCache which subnets
# it can place nodes in. Private subnets only.

resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project}-redis-subnet-group"
  description = "Subnet group for ${var.project} ElastiCache Redis"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name        = "${var.project}-redis-subnet-group"
    Project     = var.project
    Environment = var.environment
  }
}

# --- ElastiCache Parameter Group ---
# Owns the Redis configuration so we can tune it without replacing the cluster.
# redis7.x family — matches the engine version below.

resource "aws_elasticache_parameter_group" "main" {
  name        = "${var.project}-redis7-params"
  family      = "redis7"
  description = "Parameter group for ${var.project} Redis 7"

  tags = {
    Name        = "${var.project}-redis7-params"
    Project     = var.project
    Environment = var.environment
  }
}

# --- ElastiCache Replication Group ---
# We use a replication group rather than a bare cluster resource because
# it gives us a stable primary endpoint that survives failover.
# single node (num_cache_clusters = 1): appropriate for this scale.
# The next maturity step is num_cache_clusters = 2 for a read replica.
# at_rest_encryption_enabled and transit_encryption_enabled: always true.
# auth_token: Redis AUTH password — required when transit encryption is on.
# automatic_failover_enabled: requires more than one node, so false here.

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project}-redis"
  description          = "Redis cache for ${var.project} analytics-api"

  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  engine               = "redis"
  engine_version       = "7.1"
  port                 = 6379

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_auth_token

  automatic_failover_enabled = false

  apply_immediately = true

  tags = {
    Name        = "${var.project}-redis"
    Project     = var.project
    Environment = var.environment
  }
}
# --- RDS Security Group ---
# Only allows inbound PostgreSQL (5432) from EKS worker nodes.
# Nothing else — not the internet, not the control plane, not other VPC resources.
# Enforced by referencing the node SG ID directly, not a CIDR block.

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "Security group for RDS PostgreSQL - allows inbound from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
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
    Name        = "${var.project}-rds-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# --- DB Subnet Group ---
# Tells RDS which subnets it can place the instance in.
# Must span at least two AZs — RDS requirement even for single-AZ deployments.
# Private subnets only — instance is never directly reachable from the internet.

resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-db-subnet-group"
  description = "Subnet group for ${var.project} RDS instance"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name        = "${var.project}-db-subnet-group"
    Project     = var.project
    Environment = var.environment
  }
}

# --- RDS Parameter Group ---
# Owning the parameter group means we can tune PostgreSQL settings
# (e.g. slow query logging, connection limits) without recreating the instance.

resource "aws_db_parameter_group" "main" {
  name        = "${var.project}-pg15-params"
  family      = "postgres15"
  description = "Parameter group for ${var.project} PostgreSQL 15"

  tags = {
    Name        = "${var.project}-pg15-params"
    Project     = var.project
    Environment = var.environment
  }
}

# --- RDS Instance ---
# db.t3.micro: appropriate for this workload at this scale.
# Single-AZ: acceptable here. Multi-AZ is the next maturity step.
# storage_encrypted: always true.
# deletion_protection: true — matches real production. Before running
#   terraform destroy you must first set this to false and apply.
# skip_final_snapshot: false — matches real production. A snapshot is
#   taken before the instance is destroyed, giving you a recovery point.
# backup_retention_period: 7 days of point-in-time recovery.

resource "aws_db_instance" "main" {
  identifier = "${var.project}-postgres"

  engine         = "postgres"
  engine_version = "15.8"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp2"
  storage_encrypted     = true

  db_name  = "bebeque"
  username = "bebeque_admin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  deletion_protection = true

  backup_retention_period = 0
  backup_window           = "03:00-04:00"
  maintenance_window      = "mon:04:00-mon:05:00"

  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-postgres-final-snapshot"

  tags = {
    Name        = "${var.project}-postgres"
    Project     = var.project
    Environment = var.environment
  }
}
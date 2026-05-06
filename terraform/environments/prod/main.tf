terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

variable "project" {
  type        = string
  description = "Project name."
  default     = "fintech"
}

variable "primary_region" {
  type        = string
  description = "Primary AWS region."
  default     = "us-east-1"
}

variable "secondary_region" {
  type        = string
  description = "Secondary AWS region for failover."
  default     = "us-west-2"
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
}

locals {
  environment = "prod"
  common_tags = {
    Owner = "student"
    Cost  = "devops-assignment"
  }
}

module "primary_vpc" {
  source    = "../../modules/vpc"
  providers = { aws = aws.primary }

  project               = var.project
  environment           = "${local.environment}-primary"
  vpc_cidr              = "10.0.0.0/16"
  azs                   = ["${var.primary_region}a", "${var.primary_region}b"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.11.0/24", "10.0.12.0/24"]
  database_subnet_cidrs = ["10.0.21.0/24", "10.0.22.0/24"]
  enable_nat_gateway    = true
  common_tags           = local.common_tags
}

module "primary_eks" {
  source    = "../../modules/eks"
  providers = { aws = aws.primary }

  project             = var.project
  environment         = "${local.environment}-primary"
  cluster_name        = "${var.project}-${local.environment}-primary"
  vpc_id              = module.primary_vpc.vpc_id
  private_subnet_ids  = module.primary_vpc.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 2
  node_desired_size   = 2
  node_max_size       = 6
  common_tags         = local.common_tags
}

module "primary_db" {
  source    = "../../modules/db"
  providers = { aws = aws.primary }

  project                    = var.project
  environment                = "${local.environment}-primary"
  db_identifier              = "${var.project}-${local.environment}-primary-postgres"
  vpc_id                     = module.primary_vpc.vpc_id
  database_subnet_ids        = module.primary_vpc.database_subnet_ids
  allowed_security_group_ids = [module.primary_eks.node_security_group_id]
  instance_class             = "db.t4g.small"
  multi_az                   = true
  deletion_protection        = true
  common_tags                = local.common_tags
}

module "secondary_vpc" {
  source    = "../../modules/vpc"
  providers = { aws = aws.secondary }

  project               = var.project
  environment           = "${local.environment}-secondary"
  vpc_cidr              = "10.1.0.0/16"
  azs                   = ["${var.secondary_region}a", "${var.secondary_region}b"]
  public_subnet_cidrs   = ["10.1.1.0/24", "10.1.2.0/24"]
  private_subnet_cidrs  = ["10.1.11.0/24", "10.1.12.0/24"]
  database_subnet_cidrs = ["10.1.21.0/24", "10.1.22.0/24"]
  enable_nat_gateway    = true
  common_tags           = local.common_tags
}

module "secondary_eks" {
  source    = "../../modules/eks"
  providers = { aws = aws.secondary }

  project             = var.project
  environment         = "${local.environment}-secondary"
  cluster_name        = "${var.project}-${local.environment}-secondary"
  vpc_id              = module.secondary_vpc.vpc_id
  private_subnet_ids  = module.secondary_vpc.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 1
  node_desired_size   = 1
  node_max_size       = 6
  common_tags         = local.common_tags
}

resource "aws_kms_key" "secondary_rds" {
  provider                = aws.secondary
  description             = "KMS key for ${var.project} secondary region RDS read replica"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name        = "${var.project}-${local.environment}-secondary-rds-kms"
    Project     = var.project
    Environment = "${local.environment}-secondary"
    ManagedBy   = "terraform"
  })
}

resource "aws_kms_alias" "secondary_rds" {
  provider      = aws.secondary
  name          = "alias/${var.project}-${local.environment}-secondary-rds"
  target_key_id = aws_kms_key.secondary_rds.key_id
}

module "secondary_db_replica" {
  source    = "../../modules/db"
  providers = { aws = aws.secondary }

  project                    = var.project
  environment                = "${local.environment}-secondary"
  db_identifier              = "${var.project}-${local.environment}-secondary-postgres"
  vpc_id                     = module.secondary_vpc.vpc_id
  database_subnet_ids        = module.secondary_vpc.database_subnet_ids
  allowed_security_group_ids = [module.secondary_eks.node_security_group_id]
  instance_class             = "db.t4g.small"
  deletion_protection        = true
  replicate_source_db        = module.primary_db.db_instance_arn
  kms_key_id                 = aws_kms_key.secondary_rds.arn
  common_tags                = local.common_tags
}

resource "aws_ecr_repository" "backend_primary" {
  provider             = aws.primary
  name                 = "${var.project}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend_primary" {
  provider             = aws.primary
  name                 = "${var.project}-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend_secondary" {
  provider             = aws.secondary
  name                 = "${var.project}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend_secondary" {
  provider             = aws.secondary
  name                 = "${var.project}-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "primary_cluster_name" {
  value = module.primary_eks.cluster_name
}

output "secondary_cluster_name" {
  value = module.secondary_eks.cluster_name
}

output "primary_db_endpoint" {
  value = module.primary_db.db_endpoint
}

output "secondary_db_endpoint" {
  value = module.secondary_db_replica.db_endpoint
}

output "primary_db_secret_arn" {
  value = module.primary_db.master_user_secret_arn
}

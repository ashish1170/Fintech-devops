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

variable "aws_region" {
  type        = string
  description = "AWS region for the dev environment."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Project name."
  default     = "fintech"
}

variable "environment" {
  type        = string
  description = "Environment name."
  default     = "dev"
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Owner = "student"
    Cost  = "devops-assignment"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project               = var.project
  environment           = var.environment
  vpc_cidr              = "10.0.0.0/16"
  azs                   = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.11.0/24", "10.0.12.0/24"]
  database_subnet_cidrs = ["10.0.21.0/24", "10.0.22.0/24"]
  enable_nat_gateway    = true
  common_tags           = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  project             = var.project
  environment         = var.environment
  cluster_name        = "${var.project}-${var.environment}"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 1
  node_desired_size   = 2
  node_max_size       = 4
  common_tags         = local.common_tags
}

module "db" {
  source = "../../modules/db"

  project                    = var.project
  environment                = var.environment
  db_identifier              = "${var.project}-${var.environment}-postgres"
  vpc_id                     = module.vpc.vpc_id
  database_subnet_ids        = module.vpc.database_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = "db.t4g.micro"
  multi_az                   = false
  deletion_protection        = false
  common_tags                = local.common_tags
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project}-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "db_endpoint" {
  value = module.db.db_endpoint
}

output "db_secret_arn" {
  value = module.db.master_user_secret_arn
}

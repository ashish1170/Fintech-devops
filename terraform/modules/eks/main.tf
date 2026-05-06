terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "project" {
  type        = string
}

variable "environment" {
  type        = string
}

variable "cluster_name" {
  type        = string
}

variable "cluster_version" {
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  type        = string
}

variable "private_subnet_ids" {
  type        = list(string)
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type        = number
  default     = 2
}

variable "node_desired_size" {
  type        = number
  default     = 2
}

variable "node_max_size" {
  type        = number
  default     = 6
}

variable "common_tags" {
  type        = map(string)
  default     = {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  eks_managed_node_groups = {
    app = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      desired_size   = var.node_desired_size
      max_size       = var.node_max_size
    }
  }

  tags = merge(var.common_tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

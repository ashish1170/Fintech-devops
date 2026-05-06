terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "project" {
  type        = string
  description = "Project name used for resource names."
}

variable "environment" {
  type        = string
  description = "Environment name such as dev or prod."
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster."
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for EKS."
  default     = "1.30"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where EKS will run."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS worker nodes."
}

variable "node_instance_types" {
  type        = list(string)
  description = "EC2 instance types for EKS managed nodes."
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type        = number
  description = "Minimum number of worker nodes."
  default     = 2
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of worker nodes."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum number of worker nodes."
  default     = 6
}

variable "common_tags" {
  type        = map(string)
  description = "Common tags applied to EKS resources."
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

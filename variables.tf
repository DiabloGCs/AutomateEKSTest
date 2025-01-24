variable "region" {
  type        = string
  description = "AWS region to deploy EKS in"
  default     = "us-east-1"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
  default     = "my-eks-cluster"
}

variable "eks_version" {
  type        = string
  description = "EKS Kubernetes version"
  default     = "1.28"
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC"
}

variable "private_subnets" {
  type        = list(string)
  description = "List of private subnet IDs where EKS nodes will run"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to associate with AWS resources"
  default     = {}
}

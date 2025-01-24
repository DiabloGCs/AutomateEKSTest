#______________#
# Providers
#______________#
provider "aws" {
  region = var.region
}

# This provider is used to manage Kubernetes resources via Terraform.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

#______________#
# Data Sources
#______________#
data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_id
}

#______________#
# EKS Cluster
#______________#
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 21.0"  # or latest version of the EKS module
  cluster_name    = var.cluster_name
  cluster_version = var.eks_version
  subnets         = var.private_subnets
  vpc_id          = var.vpc_id

  # We do NOT create worker node groups here because Karpenter will manage them
  manage_aws_auth = true

  # If you need to customize the cluster role, or existing roles, adjust here
  create_iam_role   = true
  iam_role_name     = "${var.cluster_name}-eks-cluster-role"

  # EKS module recommended tags for subnets, etc. 
  # If needed, ensure your subnets are properly tagged for Karpenter
  tags = var.tags
}

#______________#
# IAM Role for Karpenter Controller
#______________#
# OIDC provider for IRSA
resource "aws_iam_openid_connect_provider" "this" {
  url            = module.eks.cluster_oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json
}

# Inline policy for Karpenter Controller 
data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid     = "AllowLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    effect    = "Allow"
    resources = ["arn:aws:logs:*:*:*"]
  }

  # See Karpenter docs for the full recommended policy. For brevity, partial below:
  statement {
    sid     = "AllowEC2Actions"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:Describe*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "iam:PassRole",
      "ssm:GetParameter"
    ]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "${var.cluster_name}-karpenter-controller-policy"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

#______________#
# Karpenter Installation via Helm
#______________#

# Create the Karpenter namespace
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

# Create a dedicated ServiceAccount for Karpenter that uses IRSA
resource "kubernetes_service_account" "karpenter" {
  metadata {
    name      = "karpenter"
    namespace = kubernetes_namespace.karpenter.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
    }
  }
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "https://charts.karpenter.sh"
  chart            = "karpenter"
  # Check https://github.com/aws/karpenter/releases for the latest version:
  version          = "v0.29.2"
  namespace        = kubernetes_namespace.karpenter.metadata[0].name
  create_namespace = false

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.karpenter.metadata[0].name
  }

  set {
    name  = "controller.clusterName"
    value = module.eks.cluster_id
  }

  set {
    name  = "controller.clusterEndpoint"
    value = data.aws_eks_cluster.this.endpoint
  }
  
  # If you used IRSA for the EKS cluster, pass the settings here as needed:
  # set {
  #   name  = "controller.aws.defaultInstanceProfile"
  #   value = "<arn-of-instance-profile-if-using-instance-profile>"
  # }
}

#______________#
# Example: Default Karpenter Provisioner
#______________#
# This Provisioner will allow scheduling on Spot or On-Demand with both AMD64 & ARM64
# You must ensure your subnets and security groups have the correct Karpenter tags:
#   karpenter.sh/discovery = var.cluster_name
resource "kubernetes_manifest" "default_provisioner" {
  depends_on = [helm_release.karpenter]

  manifest = {
    "apiVersion" = "karpenter.sh/v1alpha5"
    "kind"       = "Provisioner"
    "metadata" = {
      "name" = "default"
    }
    "spec" = {
      # This constraint allows scheduling on either AMD64 or ARM64.
      "requirements" = [
        {
          "key"      = "karpenter.sh/capacity-type"
          "operator" = "In"
          "values"   = ["spot", "on-demand"]
        },
        {
          "key"      = "kubernetes.io/arch"
          "operator" = "In"
          "values"   = ["amd64", "arm64"]
        }
      ]

      # Example CPU limit. Adjust as needed for your environment.
      "limits" = {
        "resources" = {
          "cpu" = "1000"  # e.g. up to 1000 vCPUs across all scaled nodes
        }
      }

      "provider" = {
        "subnetSelector" = {
          "karpenter.sh/discovery" = var.cluster_name
        }
        "securityGroupSelector" = {
          "karpenter.sh/discovery" = var.cluster_name
        }
      }
    }
  }
}

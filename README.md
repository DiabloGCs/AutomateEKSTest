# AutomateEKSTest

# EKS + Karpenter (x86 & Arm64) Terraform Example

This Terraform configuration deploys:
1. An Amazon EKS cluster (using [terraform-aws-modules/eks/aws](https://github.com/terraform-aws-modules/terraform-aws-eks)).
2. Karpenter (autoscaler) via Helm.
3. A default Karpenter Provisioner capable of launching both **x86 (amd64)** and **Graviton (arm64)** instances on **Spot** or **On-Demand**.

## Prerequisites

- Terraform v1.3+
- AWS credentials with appropriate permissions (to create EKS, IAM roles, etc.)
- An **existing VPC** and **private subnets** for EKS worker nodes.
  - Ensure your subnets and security groups have the Karpenter discovery tags: 
    - `karpenter.sh/discovery = <cluster_name>`

## Usage

1. **Review and update variables** in `variables.tf`:
   - `region`
   - `cluster_name`
   - `eks_version`
   - `vpc_id`
   - `private_subnets` (list of your existing private subnet IDs)
   - `tags` (add your organization’s standard AWS resource tags)

2. **Initialize** Terraform:

   ```bash
   terraform init

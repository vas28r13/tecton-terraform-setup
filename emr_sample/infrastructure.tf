terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 3.0.0"
    }
  }
}
provider "aws" {
  region =  var.region
  assume_role {
    role_arn = var.tecton_account_role_arn
  }
}

resource "random_id" "external_id" {
  byte_length = 16
}

# Fill these in
variable "deployment_name" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

# Role used to run terraform with. Usually the admin role in the account.
variable "tecton_account_role_arn" {
  type = string
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC Tecton to be installed in."
}

variable "vpc_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks for the EKS subnets."
}

variable "availability_zone_count" {
  type        = number
  description = "The number of availability zones for Tecton to use EKS in. Please set this to 3 unless the region you are deploying to only has 2 AZs."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "IDs of empty public subnets (one in each AZ) sorted by the associated AZ's alphanumerical name."
}

variable "eks_subnet_ids" {
  type        = list(string)
  description = "IDs of empty private subnets for EKS (one in each AZ) sorted by the associated AZ's alphanumerical name."
}

variable "emr_subnet_ids" {
  type        = list(string)
  description = "IDs of empty private subnets for EMR (one in each AZ) sorted by the associated AZ's alphanumerical name."
}

variable "allowed_CIDR_blocks" {
  type          = list(string)
  description   = "CIDR blocks that should be able to access Tecton endpoint. Defaults to `0.0.0.0/0`."
  default       = null
}

# By default Redis is not enabled. You can re-run the terraform later
# with this enabled if you want
variable "elasticache_enabled" {
  type = bool
  default = false
}

variable "tecton_assuming_account_id" {
  type        = string
  description = "Get this from your Tecton rep"
  default     = "472542229217"
}

variable "apply_layer" {
  type        = number
  default     = 2
  description = "due to terraform issues with dynamic number of resources, we need to apply in layers. Layers start at 0 and should be incremented after each successful apply until the default value is reached"
}

module "eks_subnets" {
  providers = {
    aws = aws
  }
  source          = "../eks/vpc_subnets"
  deployment_name = var.deployment_name
  vpc_id      = var.vpc_id
  region          = var.region
  # Please make sure your region has enough AZs: https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
  availability_zone_count = var.availability_zone_count
  public_subnet_ids = var.public_subnet_ids
  eks_subnet_ids = var.eks_subnet_ids
}

module "eks_security_groups" {
  providers = {
    aws = aws
  }
  source              = "../eks/security_groups"
  deployment_name     = var.deployment_name
  vpc_id              = var.vpc_id
  allowed_CIDR_blocks = var.allowed_CIDR_blocks
  tags                = {"tecton-accessible:${var.deployment_name}": "true"}

  # Configure Tecton NLB to be private.
  eks_ingress_load_balancer_public = false
  vpc_cidr_blocks                  = var.vpc_cidr_blocks
}

# EMR Subnets and Security Groups; Uses same VPC as EKS.
# Make sure that the EKS and EMR CIDR blocks do not conflict.
module "emr_subnets" {
  count                     = var.apply_layer > 0 ? 1 : 0
  source                    = "../emr/vpc_subnets"
  deployment_name           = var.deployment_name
  region                    = var.region
  availability_zone_count   = var.availability_zone_count
  vpc_id                    = var.vpc_id
  emr_subnet_ids            = var.emr_subnet_ids
  nat_gateway_ids           = module.eks_subnets.nat_gateway_ids
  depends_on                = [
    module.eks_subnets
  ]
}

module "emr_security_groups" {
  count             = var.apply_layer > 0 ? 1 : 0
  source            = "../emr/security_groups"
  deployment_name   = var.deployment_name
  region            = var.region
  emr_vpc_id        = var.vpc_id
  eks_CIDR_blocks   = var.vpc_cidr_blocks
  depends_on        = [
    module.eks_subnets
  ]
}

module "roles" {
  providers = {
    aws = aws
    aws.databricks-account = aws
  }
  count                      = (var.apply_layer > 1) ? 1 : 0
  source                     = "../roles"
  deployment_name            = var.deployment_name
  account_id                 = var.account_id
  tecton_assuming_account_id = var.tecton_assuming_account_id
  region                     = var.region
  elasticache_enabled        = var.elasticache_enabled
}

module "notebook_cluster" {
  source = "../emr/notebook_cluster"
  # See https://docs.tecton.ai/v2/setting-up-tecton/04b-connecting-emr.html#prerequisites
  # You must manually set the value of TECTON_API_KEY in AWS Secrets Manager

  # Set count = 1 once your Tecton rep confirms Tecton has been deployed in your account
  count           = 0

  region          = var.region
  deployment_name = var.deployment_name
  instance_type   = "m5.xlarge"

  subnet_id            = var.emr_subnet_ids[0]
  instance_profile_arn = module.roles[0].spark_role_name
  emr_service_role_id  = module.roles[0].emr_master_role_name

  emr_security_group_id         = module.emr_security_groups[0].emr_security_group_id
  emr_service_security_group_id = module.emr_security_groups[0].emr_service_security_group_id

  # OPTIONAL
  # You can provide custom bootstrap action(s)
  # to be performed upon notebook cluster creation
  # extra_bootstrap_actions = [
  #   {
  #     name = "name_of_the_step"
  #     path = "s3://path/to/script.sh"
  #   }
  # ]

  has_glue        = true
  glue_account_id = var.account_id
}

# This module adds some IAM privileges to enable your Tecton technical support
# reps to open and execute EMR notebooks in your account to help troubleshoot
# or test code you are developing.
#
# Enable this module by setting count = 1
module "emr_debugging" {
  source = "../emr/debugging"

  count                   = 0
  deployment_name         = var.deployment_name
  cross_account_role_name = module.roles[0].devops_role_name
}

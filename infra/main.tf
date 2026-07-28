terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # OpenTofu native client-side state encryption.
  # State holds subnet IDs, instance IPs, and volume IDs for a SOC box —
  # treat it as sensitive, not as disposable metadata.
  encryption {
    key_provider "aws_kms" "airkit" {
      kms_key_id = var.kms_key_arn
    }
    method "aes_gcm" "airkit_method" {
      keys = [key_provider.aws_kms.airkit]
    }
    state {
      method = method.aes_gcm.airkit_method
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Networking: isolated VPC, zero-egress private subnet, ingress-only SG ---
module "network" {
  source = "./modules/network"

  vpc_cidr                = var.vpc_cidr
  private_subnet_cidr     = var.private_subnet_cidr
  aws_region              = var.aws_region
  internal_corporate_cidr = var.internal_corporate_cidr
  sglang_port             = var.sglang_port
  tags                    = var.tags
}

# --- Compute: GPU inference node + model weights storage ---
module "compute" {
  source = "./modules/compute"

  aws_region                   = var.aws_region
  instance_type                = var.instance_type
  deep_learning_ami_id         = var.deep_learning_ami_id
  subnet_id                    = module.network.private_subnet_id
  security_group_id            = module.network.security_group_id
  model_weights_volume_size_gb = var.model_weights_volume_size_gb
  model_weights_volume_iops    = var.model_weights_volume_iops
  weights_s3_bucket            = var.weights_s3_bucket
  sglang_port                  = var.sglang_port
  tags                         = var.tags
}

# --- Top-level resource references used by outputs.tf ---
# (aws_vpc, aws_subnet, aws_security_group, aws_instance, aws_ebs_volume are
#  declared inside the modules; these locals re-expose them at root scope so
#  outputs.tf and the installer's health checks have a single place to read from.)
locals {
  vpc_id                  = module.network.vpc_id
  private_subnet_id       = module.network.private_subnet_id
  security_group_id       = module.network.security_group_id
  instance_id             = module.compute.instance_id
  instance_private_ip     = module.compute.instance_private_ip
  model_weights_volume_id = module.compute.model_weights_volume_id
}

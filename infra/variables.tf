variable "aws_region" {
  description = "AWS region for the isolated SOC analysis node"
  type        = string
  default     = "us-east-1"
}

variable "kms_key_arn" {
  description = "KMS key ARN used for OpenTofu native state encryption"
  type        = string
}

variable "internal_corporate_cidr" {
  description = "CIDR block for the internal corporate network allowed to reach the SGLang API and console"
  type        = string
}

variable "deep_learning_ami_id" {
  description = "AMI ID for the GPU compute node (Deep Learning AMI with NVIDIA drivers + Docker pre-installed)"
  type        = string
}

variable "instance_type" {
  description = "GPU instance type for the inference node. Must have enough VRAM to serve GLM-5.2 FP8 (~1.5TB) with tensor parallelism."
  type        = string
  default     = "p5e.48xlarge"
}

variable "model_weights_volume_size_gb" {
  description = "Size in GB of the EBS volume holding model weights"
  type        = number
  default     = 2000
}

variable "model_weights_volume_iops" {
  description = "Provisioned IOPS for the model weights volume (io2)"
  type        = number
  default     = 64000
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated AIRKit VPC"
  type        = string
  default     = "10.100.0.0/16"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private, egress-blocked subnet"
  type        = string
  default     = "10.100.1.0/24"
}

variable "sglang_port" {
  description = "Port SGLang's OpenAI-compatible API listens on"
  type        = number
  default     = 3000
}

variable "weights_s3_bucket" {
  description = "Name of the internal S3 bucket (reached via VPC Gateway Endpoint, no public internet) holding pre-staged GLM-5.2 weights"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project = "airkit"
    Layer   = "step1-analysis-node"
  }
}

variable "aws_region" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "deep_learning_ami_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "model_weights_volume_size_gb" {
  type = number
}

variable "model_weights_volume_iops" {
  type = number
}

variable "weights_s3_bucket" {
  description = "Internal S3 bucket (reached via VPC Gateway Endpoint) holding pre-staged GLM-5.2 weights"
  type        = string
}

variable "sglang_port" {
  type = number
}

variable "tags" {
  type    = map(string)
  default = {}
}

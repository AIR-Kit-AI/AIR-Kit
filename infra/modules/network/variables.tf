variable "vpc_cidr" {
  type = string
}

variable "private_subnet_cidr" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "internal_corporate_cidr" {
  description = "CIDR allowed inbound to the SGLang API port. Never 0.0.0.0/0."
  type        = string
}

variable "sglang_port" {
  type = number
}

variable "tags" {
  type    = map(string)
  default = {}
}

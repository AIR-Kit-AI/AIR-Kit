# 1. Isolated VPC. No internet gateway is ever attached anywhere in this module.
resource "aws_vpc" "airkit_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "airkit-isolated-vpc" })
}

# 2. Private subnet. Deliberately has NO route to an Internet Gateway or NAT
# Gateway. This is what makes the subnet zero-egress, not the security group
# alone — a route table entry to an IGW would undermine the SG rules below.
resource "aws_subnet" "airkit_private_subnet" {
  vpc_id            = aws_vpc.airkit_vpc.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = merge(var.tags, { Name = "airkit-private-subnet" })
}

# 3. Route table with only a local route. Explicitly no 0.0.0.0/0 route.
resource "aws_route_table" "airkit_private_rt" {
  vpc_id = aws_vpc.airkit_vpc.id

  tags = merge(var.tags, { Name = "airkit-private-rt-no-egress" })
}

resource "aws_route_table_association" "airkit_private_rta" {
  subnet_id      = aws_subnet.airkit_private_subnet.id
  route_table_id = aws_route_table.airkit_private_rt.id
}

# 4. S3 Gateway Endpoint. Lets the node pull model weights and push analysis
# artifacts to a private S3 bucket over the AWS backbone, without ever
# touching the public internet. This is the ONLY route out of the subnet.
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.airkit_vpc.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.airkit_private_rt.id]

  tags = merge(var.tags, { Name = "airkit-s3-gateway-endpoint" })
}

# 5. Security group: ingress only from the internal corporate network,
# and NO egress rules defined. AWS security groups default-deny all
# outbound traffic unless an egress rule explicitly allows it, so the
# absence of an egress block here is the zero-egress enforcement point.
resource "aws_security_group" "airkit_sg" {
  name        = "airkit-soc-sg"
  description = "Ingress for internal SIEM/EDR telemetry and analyst console; zero egress to public internet"
  vpc_id      = aws_vpc.airkit_vpc.id

  ingress {
    from_port   = var.sglang_port
    to_port     = var.sglang_port
    protocol    = "tcp"
    cidr_blocks = [var.internal_corporate_cidr]
    description = "SGLang OpenAI-compatible API endpoint"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.internal_corporate_cidr]
    description = "SSH for operator/installer access from internal network only"
  }

  # Intentionally no egress block. Do not add one without updating the
  # threat model in docs/architecture.md — this is the single control
  # that makes the node "zero-egress" rather than merely "firewalled."

  tags = merge(var.tags, { Name = "airkit-soc-sg-zero-egress" })
}

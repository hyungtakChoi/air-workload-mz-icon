
# agent_result.tf
# CSP: AWS | Region: ap-northeast-2 | Workload: LLaMA 1/2 Inference
# Tags: project=ai-infra, environment=production

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# ── VPC ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name        = "ai-infra-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = {
    Name        = "ai-infra-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name        = "ai-infra-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────
resource "aws_security_group" "llama_sg" {
  name   = "llama-inference-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name        = "llama-inference-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── Key Pair ──────────────────────────────────────────
resource "aws_key_pair" "ai_key" {
  key_name   = "ai-infra-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# ── EC2 (g5.2xlarge / A10G GPU) ───────────────────────
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "llama_server" {
  ami                    = data.aws_ami.deep_learning.id
  instance_type          = "g5.2xlarge"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.llama_sg.id]
  key_name               = aws_key_pair.ai_key.key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
  }

  user_data = <<-EOF
    #!/bin/bash
    pip install torch transformers accelerate
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /app
    cd /app && python llama_inference.py &
  EOF

  tags = {
    Name        = "llama-inference-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# ── S3 (모델 가중치 저장) ──────────────────────────────
resource "aws_s3_bucket" "model_store" {
  bucket = "ai-infra-llama-model-store"
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_versioning" "model_store" {
  bucket = aws_s3_bucket.model_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── Outputs ───────────────────────────────────────────
output "instance_public_ip" {
  value = aws_instance.llama_server.public_ip
}
output "s3_bucket_name" {
  value = aws_s3_bucket.model_store.bucket
}

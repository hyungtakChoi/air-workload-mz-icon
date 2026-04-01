terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 구성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-car-sales-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 서브넷 구성
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-car-sales-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-car-sales-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-car-sales-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "ai-car-sales-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹
resource "aws_security_group" "ai_server_sg" {
  name        = "ai-car-sales-sg"
  description = "Allow SSH and web traffic"
  vpc_id      = aws_vpc.main.id

  # SSH 접근
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP 접근
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS 접근
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-car-sales-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 인스턴스 (g5.2xlarge - A10G GPU)
resource "aws_instance" "ai_server" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Amazon Linux 2 with GPU support
  instance_type          = "g5.2xlarge"
  key_name               = "ai-car-sales-key"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ai_server_sg.id]

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    encrypted   = true

    tags = {
      Name        = "ai-car-sales-root-volume"
      project     = "ai-infra"
      environment = "production"
    }
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip git

    # Install NVIDIA drivers
    wget https://us.download.nvidia.com/tesla/515.65.01/NVIDIA-Linux-x86_64-515.65.01.run
    chmod +x NVIDIA-Linux-x86_64-515.65.01.run
    ./NVIDIA-Linux-x86_64-515.65.01.run -s

    # Install CUDA
    wget https://developer.download.nvidia.com/compute/cuda/11.7.1/local_installers/cuda_11.7.1_515.65.01_linux.run
    chmod +x cuda_11.7.1_515.65.01_linux.run
    ./cuda_11.7.1_515.65.01_linux.run --silent

    # Setup app directory
    mkdir -p /opt/ai-car-sales
    cd /opt/ai-car-sales

    # Clone repository
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git .
    
    # Setup Python environment
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
  EOF

  tags = {
    Name        = "ai-car-sales-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 (모델 및 데이터용)
resource "aws_ebs_volume" "model_data" {
  availability_zone = "ap-northeast-2a"
  size              = 200
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "ai-car-sales-data-volume"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_volume_attachment" "model_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_data.id
  instance_id = aws_instance.ai_server.id
}

# S3 버킷 (모델 및 데이터 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-sales-models"

  tags = {
    Name        = "ai-car-sales-model-bucket"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_versioning" "model_bucket_versioning" {
  bucket = aws_s3_bucket.model_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_bucket_encryption" {
  bucket = aws_s3_bucket.model_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM 역할 및 정책
resource "aws_iam_role" "ec2_s3_access_role" {
  name = "ec2-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_iam_role_policy" "s3_access_policy" {
  name = "s3-access-policy"
  role = aws_iam_role.ec2_s3_access_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.model_bucket.arn,
          "${aws_s3_bucket.model_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "ec2-s3-profile"
  role = aws_iam_role.ec2_s3_access_role.name
}

# Elastic IP
resource "aws_eip" "ai_server_ip" {
  vpc = true
  tags = {
    Name        = "ai-car-sales-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_eip_association" "ai_server_eip_assoc" {
  instance_id   = aws_instance.ai_server.id
  allocation_id = aws_eip.ai_server_ip.id
}

# CloudWatch 경보
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-server-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm monitors EC2 CPU utilization"
  
  dimensions = {
    InstanceId = aws_instance.ai_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Application Load Balancer (향후 확장성 고려)
resource "aws_lb" "ai_app_lb" {
  name               = "ai-car-sales-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ai_server_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.private.id]

  enable_deletion_protection = false

  tags = {
    Name        = "ai-car-sales-alb"
    project     = "ai-infra"
    environment = "production"
  }
}

# Target Group
resource "aws_lb_target_group" "ai_target_group" {
  name     = "ai-car-sales-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    matcher             = "200-299"
  }

  tags = {
    Name        = "ai-car-sales-target-group"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_lb_target_group_attachment" "ai_server_attachment" {
  target_group_arn = aws_lb_target_group.ai_target_group.arn
  target_id        = aws_instance.ai_server.id
  port             = 80
}

# Listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.ai_app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_target_group.arn
  }
}

# 출력값
output "instance_public_ip" {
  description = "Public IP of the AI Server"
  value       = aws_eip.ai_server_ip.public_ip
}

output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.ai_app_lb.dns_name
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for models"
  value       = aws_s3_bucket.model_bucket.bucket
}
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-car-sales-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-car-sales-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷
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

# 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name        = "ai-car-sales-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹
resource "aws_security_group" "allow_ssh_http" {
  name        = "allow_ssh_http"
  description = "Allow SSH and HTTP inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API Port"
    from_port   = 8000
    to_port     = 8000
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
    Name        = "ai-car-sales-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 - 모델 저장용
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-sales-models"

  tags = {
    Name        = "ai-car-sales-models"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 ACL 설정
resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# S3 버킷 - 데이터 저장용
resource "aws_s3_bucket" "data_bucket" {
  bucket = "ai-car-sales-data"

  tags = {
    Name        = "ai-car-sales-data"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 ACL 설정
resource "aws_s3_bucket_ownership_controls" "data_bucket_ownership" {
  bucket = aws_s3_bucket.data_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# IAM 역할 생성
resource "aws_iam_role" "ec2_s3_access_role" {
  name = "ec2_s3_access_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 접근 정책
resource "aws_iam_policy" "s3_access_policy" {
  name        = "s3_access_policy"
  description = "Policy for EC2 to access S3 buckets"

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
          "${aws_s3_bucket.model_bucket.arn}/*",
          aws_s3_bucket.data_bucket.arn,
          "${aws_s3_bucket.data_bucket.arn}/*"
        ]
      }
    ]
  })
}

# 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access_attach" {
  role       = aws_iam_role.ec2_s3_access_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

# 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_s3_profile"
  role = aws_iam_role.ec2_s3_access_role.name
}

# EBS 볼륨
resource "aws_ebs_volume" "model_storage" {
  availability_zone = "ap-northeast-2a"
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name        = "ai-car-sales-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 인스턴스
resource "aws_instance" "ai_inference" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Amazon Linux 2 with GPU support
  instance_type          = "g5.2xlarge"  # GPU 인스턴스
  key_name               = "ai-car-sales-key"  # 사전에 생성된 키 페어 이름
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y git python3-pip
              pip3 install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              pip3 install fastapi uvicorn
              
              # Install NVIDIA drivers and CUDA
              dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
              dnf install -y gcc make
              
              # Clone repo
              mkdir -p /opt/app
              cd /opt/app
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git
              
              # Create service file
              cat > /etc/systemd/system/aiservice.service << 'EOL'
              [Unit]
              Description=AI Car Sales Service
              After=network.target
              
              [Service]
              User=ec2-user
              WorkingDirectory=/opt/app/air-workload-mz-icon
              ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
              Restart=always
              
              [Install]
              WantedBy=multi-user.target
              EOL
              
              systemctl daemon-reload
              systemctl enable aiservice.service
              systemctl start aiservice.service
              EOF

  tags = {
    Name        = "ai-car-sales-inference"
    project     = "ai-infra"
    environment = "production"
  }
}

# 볼륨 연결
resource "aws_volume_attachment" "model_storage_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_storage.id
  instance_id = aws_instance.ai_inference.id
}

# Elastic IP
resource "aws_eip" "ai_server_ip" {
  instance = aws_instance.ai_inference.id
  domain   = "vpc"

  tags = {
    Name        = "ai-car-sales-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 경보 - CPU 사용량
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-server-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    InstanceId = aws_instance.ai_inference.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값
output "instance_public_ip" {
  description = "Public IP of the AI inference instance"
  value       = aws_eip.ai_server_ip.public_ip
}

output "model_bucket_name" {
  description = "S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}

output "data_bucket_name" {
  description = "S3 bucket for data storage"
  value       = aws_s3_bucket.data_bucket.bucket
}
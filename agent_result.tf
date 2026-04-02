provider "aws" {
  region = "ap-northeast-2"
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-inference-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷 생성
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-inference-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷 생성
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-inference-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-inference-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "ai-inference-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷과 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT 게이트웨이를 위한 Elastic IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "ai-inference-nat-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# NAT 게이트웨이 생성
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name        = "ai-inference-nat"
    project     = "ai-infra"
    environment = "production"
  }

  depends_on = [aws_internet_gateway.igw]
}

# 프라이빗 라우팅 테이블
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name        = "ai-inference-private-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷과 라우팅 테이블 연결
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# 보안 그룹 생성
resource "aws_security_group" "app_sg" {
  name        = "ai-inference-sg"
  description = "Security group for AI inference app"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 접속 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS 접속 허용
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # API 서버 포트 허용
  ingress {
    from_port   = 8000
    to_port     = 8000
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
    Name        = "ai-inference-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-model-storage-bucket"

  tags = {
    Name        = "ai-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 버전 관리 활성화
resource "aws_s3_bucket_versioning" "versioning_example" {
  bucket = aws_s3_bucket.model_bucket.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM 역할 생성 (EC2에서 S3 접근용)
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
      },
    ]
  })

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 접근을 위한 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access_policy" {
  role       = aws_iam_role.ec2_s3_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# IAM 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-s3-profile"
  role = aws_iam_role.ec2_s3_access_role.name
}

# EC2 인스턴스 생성 (GPU 인스턴스)
resource "aws_instance" "ai_server" {
  ami                    = "ami-0f3a440bbcff3d043"  # Ubuntu Server 22.04 LTS Deep Learning AMI
  instance_type          = "g5.2xlarge"             # NVIDIA A10G GPU 1개, vCPU 8개, 메모리 32GB
  key_name               = "ai-inference-key"       # 키 페어 이름 (미리 생성 필요)
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y git python3-pip
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ubuntu/ai-app
    chown -R ubuntu:ubuntu /home/ubuntu/ai-app
    cd /home/ubuntu/ai-app
    pip3 install -r requirements.txt
    # 시작 스크립트 설정
    cat > /etc/systemd/system/ai-app.service << 'END'
    [Unit]
    Description=AI Car Sales Application
    After=network.target

    [Service]
    User=ubuntu
    WorkingDirectory=/home/ubuntu/ai-app
    ExecStart=/usr/bin/python3 /home/ubuntu/ai-app/app.py
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    END

    systemctl enable ai-app
    systemctl start ai-app
  EOF

  tags = {
    Name        = "ai-inference-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP for EC2 인스턴스
resource "aws_eip" "server_eip" {
  instance = aws_instance.ai_server.id
  domain   = "vpc"

  tags = {
    Name        = "ai-inference-server-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 설정 (CPU 사용률 80% 이상 시 알림)
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "ai-server-high-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"

  dimensions = {
    InstanceId = aws_instance.ai_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력값 정의
output "server_public_ip" {
  description = "The public IP address of the AI inference server"
  value       = aws_eip.server_eip.public_ip
}

output "s3_bucket_name" {
  description = "S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}
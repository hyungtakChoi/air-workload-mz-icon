# AWS 공급자 설정
provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-llama-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-llama-igw"
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
    Name        = "ai-llama-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-llama-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 - 퍼블릭
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "ai-llama-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결 - 퍼블릭
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹 - GPU 인스턴스
resource "aws_security_group" "gpu_instance" {
  name        = "ai-llama-sg"
  description = "Security group for LLaMA model inference"
  vpc_id      = aws_vpc.main.id

  # SSH 접속
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # API 엔드포인트
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "API endpoint"
  }

  # 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-llama-security-group"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 - 모델 저장용
resource "aws_s3_bucket" "model_storage" {
  bucket = "ai-llama-model-storage-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  
  tags = {
    Name        = "ai-llama-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 버전 관리 설정
resource "aws_s3_bucket_versioning" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 버킷 서버 측 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM 역할 - EC2 인스턴스용
resource "aws_iam_role" "ec2_role" {
  name = "ai-llama-ec2-role"

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

# IAM 정책 - S3 접근용
resource "aws_iam_policy" "s3_access" {
  name        = "ai-llama-s3-access"
  description = "Allow S3 access for model storage"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.model_storage.arn,
          "${aws_s3_bucket.model_storage.arn}/*"
        ]
      }
    ]
  })
}

# IAM 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-llama-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# GPU 인스턴스 생성 (g5.2xlarge - A10G GPU)
resource "aws_instance" "gpu_instance" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Amazon Linux 2023 AMI with NVIDIA drivers
  instance_type          = "g5.2xlarge"             # 24GB GPU Memory, 32GB RAM
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gpu_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = "llama-key-pair"         # 사전에 생성된 키 페어 이름

  root_block_device {
    volume_size           = 100  # 100GB 루트 볼륨
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y git python3 python3-pip
              pip3 install --upgrade pip
              pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers accelerate
              
              # 코드 저장소 복제
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ec2-user/app
              chown -R ec2-user:ec2-user /home/ec2-user/app
              
              # 모델 다운로드 디렉토리 생성
              mkdir -p /home/ec2-user/models
              chown -R ec2-user:ec2-user /home/ec2-user/models
              
              # 모델 파일 다운로드 (S3에서)
              aws s3 cp s3://${aws_s3_bucket.model_storage.id}/models/ /home/ec2-user/models/ --recursive
              EOF

  tags = {
    Name        = "ai-llama-gpu-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP
resource "aws_eip" "gpu_instance" {
  instance = aws_instance.gpu_instance.id
  domain   = "vpc"

  tags = {
    Name        = "ai-llama-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - CPU 사용량
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "ai-llama-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - 메모리 부족
resource "aws_cloudwatch_metric_alarm" "memory_low" {
  alarm_name          = "ai-llama-low-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryAvailable"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 2000000000  # 2GB
  alarm_description   = "This metric monitors available memory"
  
  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 정보
output "instance_id" {
  description = "ID of the GPU instance"
  value       = aws_instance.gpu_instance.id
}

output "instance_public_ip" {
  description = "Public IP of the GPU instance"
  value       = aws_eip.gpu_instance.public_ip
}

output "model_storage_bucket" {
  description = "S3 bucket for model storage"
  value       = aws_s3_bucket.model_storage.id
}
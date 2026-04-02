provider "aws" {
  region = "ap-northeast-2"  # Seoul region
}

# VPC 구성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "llama-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "llama-igw"
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
    Name        = "llama-public-subnet"
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
    Name        = "llama-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 구성
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "llama-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹 생성
resource "aws_security_group" "llama_sg" {
  name        = "llama-security-group"
  description = "Security group for LLaMA service"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 서비스 포트 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 모델 서빙 API 포트 (예시)
  ingress {
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
    Name        = "llama-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 역할 생성
resource "aws_iam_role" "llama_role" {
  name = "llama-role"

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

# IAM 정책 연결 - S3 접근
resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.llama_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# IAM 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "llama_profile" {
  name = "llama-profile"
  role = aws_iam_role.llama_role.name
}

# EC2 인스턴스 생성 (GPU 인스턴스 - g5.2xlarge)
resource "aws_instance" "llama_server" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Ubuntu 22.04 with GPU support
  instance_type          = "g5.2xlarge"             # A10G GPU 1개, 32GB RAM
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.llama_sg.id]
  key_name               = "llama-key"              # 키페어 이름 (미리 생성 필요)
  iam_instance_profile   = aws_iam_instance_profile.llama_profile.name

  root_block_device {
    volume_size = 100  # 100GB 스토리지
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip git
              pip3 install torch torchvision torchaudio
              
              # NVIDIA 드라이버 및 CUDA 설치
              apt-get install -y nvidia-driver-525 nvidia-cuda-toolkit
              
              # 애플리케이션 코드 클론
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ubuntu/llama-app
              
              # 필요한 Python 패키지 설치
              cd /home/ubuntu/llama-app
              pip3 install -r requirements.txt || echo "No requirements.txt found"
              
              # 모델 다운로드 (예시)
              mkdir -p /home/ubuntu/models
              # 실제 모델 다운로드 커맨드는 별도로 구성 필요
              EOF

  tags = {
    Name        = "llama-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 - 모델 저장용
resource "aws_s3_bucket" "model_storage" {
  bucket = "llama-model-storage-unique-name"  # 실제 배포 시 고유한 이름으로 변경 필요

  tags = {
    Name        = "llama-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 버전 관리 설정
resource "aws_s3_bucket_versioning" "model_storage_versioning" {
  bucket = aws_s3_bucket.model_storage.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# CloudWatch 로그 그룹 생성
resource "aws_cloudwatch_log_group" "llama_logs" {
  name = "/llama/application"
  
  retention_in_days = 30

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 변수
output "instance_public_ip" {
  value = aws_instance.llama_server.public_ip
  description = "The public IP address of the LLaMA server"
}

output "model_storage_bucket" {
  value = aws_s3_bucket.model_storage.bucket_domain_name
  description = "The domain name of the model storage bucket"
}
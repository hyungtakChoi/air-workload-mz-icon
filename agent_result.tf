provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-car-vpc"
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
    Name        = "ai-car-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-car-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 생성
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "ai-car-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블과 서브넷 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹 생성
resource "aws_security_group" "instance_sg" {
  name        = "ai-car-instance-sg"
  description = "Security group for AI car service instance"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS 허용
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 애플리케이션 포트 허용 (예: 8000)
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
    Name        = "ai-car-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# 딥러닝 AMI 조회 (Deep Learning AMI GPU PyTorch)
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# EC2 인스턴스 생성
resource "aws_instance" "ai_car" {
  ami                    = data.aws_ami.deep_learning.id
  instance_type          = "g5.2xlarge"  # NVIDIA A10G GPU 1개, 32GB 메모리
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name               = "ai-car-key"  # 미리 생성된 키 페어 이름

  root_block_device {
    volume_size = 100  # GB
    volume_type = "gp3"
  }

  tags = {
    Name        = "ai-car-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 생성 (모델 및 데이터 저장용)
resource "aws_ebs_volume" "model_data" {
  availability_zone = "ap-northeast-2a"
  size              = 200  # GB
  type              = "gp3"
  
  tags = {
    Name        = "ai-car-model-data"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 연결
resource "aws_volume_attachment" "model_data_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_data.id
  instance_id = aws_instance.ai_car.id
}

# Elastic IP 할당
resource "aws_eip" "instance_eip" {
  instance = aws_instance.ai_car.id
  domain   = "vpc"

  tags = {
    Name        = "ai-car-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 가중치 및 데이터 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-models-data-${random_string.bucket_suffix.result}"

  tags = {
    Name        = "ai-car-models"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 이름 중복 방지용 랜덤 문자열
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# S3 버킷 액세스 정책
resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "model_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.model_bucket_ownership]
  bucket     = aws_s3_bucket.model_bucket.id
  acl        = "private"
}

# IAM 역할 생성 (EC2가 S3에 접근할 수 있는 권한)
resource "aws_iam_role" "ec2_s3_access" {
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

# IAM 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access_policy" {
  role       = aws_iam_role.ec2_s3_access.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# IAM 인스턴스 프로필 생성
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-s3-profile"
  role = aws_iam_role.ec2_s3_access.name
}

# CloudWatch 로그 그룹 생성
resource "aws_cloudwatch_log_group" "ai_car_logs" {
  name = "/ai-car/application"
  retention_in_days = 30

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값 정의
output "instance_public_ip" {
  description = "The public IP address of the AI car service instance"
  value       = aws_eip.instance_eip.public_ip
}

output "s3_bucket_name" {
  description = "The name of the S3 bucket for model data"
  value       = aws_s3_bucket.model_bucket.bucket
}

output "instance_id" {
  description = "The ID of the AI car service instance"
  value       = aws_instance.ai_car.id
}
provider "aws" {
  region = "ap-northeast-2"
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-infra-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷 생성
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-northeast-2a"

  tags = {
    Name        = "ai-infra-public-subnet"
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
    Name        = "ai-infra-private-subnet"
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
    Name        = "ai-infra-public-rt"
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
resource "aws_security_group" "instance_sg" {
  name        = "ai-infra-sg"
  description = "Allow SSH and application traffic"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # 웹 서비스 포트 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  # HTTPS 허용
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  # 모델 서비스 API 포트 (예시)
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "API port"
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-infra-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 인스턴스 키 페어 생성 
resource "aws_key_pair" "deployer" {
  key_name   = "ai-infra-key"
  public_key = file("~/.ssh/id_rsa.pub")  # 실제 배포 시 공개 키 경로 설정 필요
}

# GPU 인스턴스 생성
resource "aws_instance" "gpu_instance" {
  ami                    = "ami-0f3a440bbcff3d043"  # Amazon Linux 2 with Deep Learning AMI
  instance_type          = "g5.2xlarge"  # A10G GPU 1개
  key_name               = aws_key_pair.deployer.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 100
    delete_on_termination = true
  }

  tags = {
    Name        = "ai-infra-gpu-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 생성 (모델 저장용)
resource "aws_ebs_volume" "model_storage" {
  availability_zone = "ap-northeast-2a"
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name        = "ai-infra-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 인스턴스에 연결
resource "aws_volume_attachment" "model_storage_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_storage.id
  instance_id = aws_instance.gpu_instance.id
}

# Elastic IP 할당
resource "aws_eip" "gpu_instance_eip" {
  vpc = true

  tags = {
    Name        = "ai-infra-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP 연결
resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.gpu_instance.id
  allocation_id = aws_eip.gpu_instance_eip.id
}

# CloudWatch 알람 설정 - CPU 사용률
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-infra-high-cpu-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = []  # 실제 배포 시 SNS 주제 ARN 설정 필요
  
  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 설정 - 메모리 사용률
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-infra-high-memory-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors memory utilization"
  alarm_actions       = []  # 실제 배포 시 SNS 주제 ARN 설정 필요

  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 가중치 및 데이터 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-infra-model-storage-bucket"

  tags = {
    Name        = "AI Infra Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 버전 관리 설정
resource "aws_s3_bucket_versioning" "model_bucket_versioning" {
  bucket = aws_s3_bucket.model_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 버킷 서버 사이드 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "model_bucket_encryption" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 출력 값 정의
output "instance_id" {
  description = "ID of the GPU EC2 instance"
  value       = aws_instance.gpu_instance.id
}

output "instance_public_ip" {
  description = "Public IP of the GPU EC2 instance"
  value       = aws_eip.gpu_instance_eip.public_ip
}

output "model_bucket_name" {
  description = "Name of S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}
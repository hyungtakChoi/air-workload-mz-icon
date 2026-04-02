provider "aws" {
  region = "ap-northeast-2"
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

# 프라이빗 서브넷
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

# 라우팅 테이블 (퍼블릭)
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

# 서브넷과 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹
resource "aws_security_group" "app_sg" {
  name        = "ai-car-sales-sg"
  description = "Security group for AI car sales application"
  vpc_id      = aws_vpc.main.id

  # SSH 접속용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 서비스용 (HTTP)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 서비스용 (HTTPS)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # API 서비스용
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
    Name        = "ai-car-sales-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# 서비스 인스턴스 (GPU 인스턴스)
resource "aws_instance" "app_server" {
  ami                    = "ami-0c9c942bd7bf113a2" # Amazon Linux 2023 AMI
  instance_type          = "g5.2xlarge"            # GPU 인스턴스
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = "ai-car-sales-key"      # 사전에 생성한 키 페어 이름

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    tags = {
      Name        = "ai-car-sales-root-volume"
      project     = "ai-infra"
      environment = "production"
    }
  }

  tags = {
    Name        = "ai-car-sales-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP
resource "aws_eip" "app_eip" {
  instance = aws_instance.app_server.id
  domain   = "vpc"

  tags = {
    Name        = "ai-car-sales-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 (모델 및 데이터 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-sales-models"

  tags = {
    Name        = "ai-car-sales-models"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 퍼블릭 액세스 차단
resource "aws_s3_bucket_public_access_block" "model_bucket_public_access" {
  bucket = aws_s3_bucket.model_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudWatch 알람 (CPU 사용률)
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-car-sales-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    InstanceId = aws_instance.app_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 (메모리 사용률)
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-car-sales-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors memory utilization"
  
  dimensions = {
    InstanceId = aws_instance.app_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 설정
output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.app_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip.app_eip.public_ip
}

output "model_bucket_name" {
  description = "Name of the S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.id
}
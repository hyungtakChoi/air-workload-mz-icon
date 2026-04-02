provider "aws" {
  region = "ap-northeast-2"
}

# VPC 구성
resource "aws_vpc" "ai_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-infra-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 공개 서브넷 구성
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.ai_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-infra-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷 구성
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.ai_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-infra-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.ai_vpc.id

  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 - 공개
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.ai_vpc.id

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

# 라우팅 테이블 - 프라이빗
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.ai_vpc.id

  tags = {
    Name        = "ai-infra-private-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_rta" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

# 보안 그룹
resource "aws_security_group" "app_sg" {
  name        = "ai-infra-app-sg"
  description = "Allow HTTP, HTTPS and SSH traffic"
  vpc_id      = aws_vpc.ai_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  # API 서버를 위한 포트
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
    Name        = "ai-infra-app-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨
resource "aws_ebs_volume" "app_data" {
  availability_zone = "ap-northeast-2a"
  size              = 100
  type              = "gp3"

  tags = {
    Name        = "ai-infra-app-data"
    project     = "ai-infra"
    environment = "production"
  }
}

# G5 인스턴스 (NVIDIA A10G GPU)
resource "aws_instance" "ai_app_server" {
  ami                    = "ami-0c9c942bd7bf113a2" # Amazon Linux 2 AMI (HVM), SSD Volume Type
  instance_type          = "g5.2xlarge"
  key_name               = "ai-infra-key"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = "ai-infra-app-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 연결
resource "aws_volume_attachment" "app_data_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.app_data.id
  instance_id = aws_instance.ai_app_server.id
}

# 탄력적 IP 할당
resource "aws_eip" "app_eip" {
  instance = aws_instance.ai_app_server.id
  domain   = "vpc"

  tags = {
    Name        = "ai-infra-app-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 (모델 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-infra-model-storage"

  tags = {
    Name        = "ai-infra-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# 버킷 공개 액세스 차단
resource "aws_s3_bucket_public_access_block" "model_bucket_block" {
  bucket = aws_s3_bucket.model_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버킷 서버 사이드 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "model_bucket_encryption" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudWatch 알람 (CPU 사용률)
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-infra-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm monitors EC2 CPU utilization"

  dimensions = {
    InstanceId = aws_instance.ai_app_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 (메모리 사용률)
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-infra-memory-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm monitors EC2 memory utilization"

  dimensions = {
    InstanceId = aws_instance.ai_app_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}
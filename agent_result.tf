provider "aws" {
  region = "ap-northeast-2" # 서울 리전
}

# VPC 생성
resource "aws_vpc" "ai_car_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-car-sales-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷 생성
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.ai_car_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-car-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷 생성
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.ai_car_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-car-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.ai_car_vpc.id

  tags = {
    Name        = "ai-car-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 생성
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.ai_car_vpc.id

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

# 라우팅 테이블 연결
resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 보안 그룹 생성
resource "aws_security_group" "ai_car_sg" {
  name        = "ai-car-sg"
  description = "Security group for AI car sales service"
  vpc_id      = aws_vpc.ai_car_vpc.id

  # SSH 접속용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 서비스용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 아웃바운드 트래픽 허용
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

# IAM 역할 생성
resource "aws_iam_role" "ec2_role" {
  name = "ai-car-ec2-role"

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

# S3 접근 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-car-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# GPU 인스턴스 생성
resource "aws_instance" "ai_car_instance" {
  ami                    = "ami-0ff56409a6e8ea2d0" # Deep Learning AMI GPU PyTorch 2.0.1 (Ubuntu 20.04)
  instance_type          = "g5.2xlarge"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ai_car_sg.id]
  key_name               = "ai-car-key" # 사전에 생성된 키페어 이름
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = "ai-car-gpu-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP 할당
resource "aws_eip" "ai_car_eip" {
  instance = aws_instance.ai_car_instance.id
  domain   = "vpc"

  tags = {
    Name        = "ai-car-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-sales-models"

  tags = {
    Name        = "ai-car-model-bucket"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 접근 제어
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

# CloudWatch 알람 설정 (CPU 사용률)
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-car-high-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This alarm monitors EC2 CPU utilization"
  
  dimensions = {
    InstanceId = aws_instance.ai_car_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값
output "instance_id" {
  value = aws_instance.ai_car_instance.id
}

output "instance_public_ip" {
  value = aws_eip.ai_car_eip.public_ip
}

output "model_bucket_name" {
  value = aws_s3_bucket.model_bucket.bucket
}
provider "aws" {
  region = "ap-northeast-2"
}

# VPC 생성
resource "aws_vpc" "ai_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-llama-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "ai_igw" {
  vpc_id = aws_vpc.ai_vpc.id

  tags = {
    Name        = "ai-llama-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷
resource "aws_subnet" "ai_public_subnet" {
  vpc_id                  = aws_vpc.ai_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-llama-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블
resource "aws_route_table" "ai_public_rt" {
  vpc_id = aws_vpc.ai_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ai_igw.id
  }

  tags = {
    Name        = "ai-llama-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "ai_public_rta" {
  subnet_id      = aws_subnet.ai_public_subnet.id
  route_table_id = aws_route_table.ai_public_rt.id
}

# 보안 그룹
resource "aws_security_group" "ai_sg" {
  name        = "ai-llama-sg"
  description = "Security group for AI LLaMA service"
  vpc_id      = aws_vpc.ai_vpc.id

  # SSH 접속
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP 접속
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS 접속
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # API 서버용 포트 (예: 8000)
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
    Name        = "ai-llama-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 (모델 저장용)
resource "aws_ebs_volume" "ai_model_volume" {
  availability_zone = "ap-northeast-2a"
  size              = 100
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name        = "ai-llama-model-volume"
    project     = "ai-infra"
    environment = "production"
  }
}

# G5 인스턴스 (GPU 포함)
resource "aws_instance" "ai_server" {
  ami                    = "ami-0c9c942bd7bf113a2" # Amazon Linux 2 with GPU support
  instance_type          = "g5.2xlarge"            # A10G GPU (24GB) 1개, vCPU 8개, 메모리 32GB
  subnet_id              = aws_subnet.ai_public_subnet.id
  vpc_security_group_ids = [aws_security_group.ai_sg.id]
  key_name               = "ai-llama-key" # 미리 생성한 키페어 이름

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
  }

  tags = {
    Name        = "ai-llama-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 연결
resource "aws_volume_attachment" "ai_model_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.ai_model_volume.id
  instance_id = aws_instance.ai_server.id
}

# Elastic IP
resource "aws_eip" "ai_eip" {
  vpc = true

  tags = {
    Name        = "ai-llama-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP 연결
resource "aws_eip_association" "ai_eip_assoc" {
  instance_id   = aws_instance.ai_server.id
  allocation_id = aws_eip.ai_eip.id
}

# CloudWatch 알람 (CPU 사용량)
resource "aws_cloudwatch_metric_alarm" "ai_cpu_alarm" {
  alarm_name          = "ai-llama-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
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

# S3 버킷 (백업 및 모델 저장)
resource "aws_s3_bucket" "ai_model_bucket" {
  bucket = "ai-llama-model-bucket-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  tags = {
    Name        = "ai-llama-model-bucket"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_public_access_block" "ai_bucket_access" {
  bucket = aws_s3_bucket.ai_model_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM 역할 (EC2가 S3에 접근할 수 있도록)
resource "aws_iam_role" "ai_ec2_role" {
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

# IAM 정책 (S3 접근 권한)
resource "aws_iam_policy" "ai_s3_access" {
  name        = "ai-llama-s3-access"
  description = "Allow access to S3 model bucket"

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
          aws_s3_bucket.ai_model_bucket.arn,
          "${aws_s3_bucket.ai_model_bucket.arn}/*"
        ]
      }
    ]
  })
}

# IAM 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "ai_s3_access_attachment" {
  role       = aws_iam_role.ai_ec2_role.name
  policy_arn = aws_iam_policy.ai_s3_access.arn
}

# 인스턴스 프로파일
resource "aws_iam_instance_profile" "ai_instance_profile" {
  name = "ai-llama-instance-profile"
  role = aws_iam_role.ai_ec2_role.name
}

# EC2 인스턴스에 프로파일 연결
resource "aws_instance" "ai_server_with_profile" {
  ami                    = aws_instance.ai_server.ami
  instance_type          = aws_instance.ai_server.instance_type
  subnet_id              = aws_instance.ai_server.subnet_id
  vpc_security_group_ids = aws_instance.ai_server.vpc_security_group_ids
  key_name               = aws_instance.ai_server.key_name
  iam_instance_profile   = aws_iam_instance_profile.ai_instance_profile.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
  }

  tags = {
    Name        = "ai-llama-server-with-profile"
    project     = "ai-infra"
    environment = "production"
  }
  
  # ai_server 리소스를 대체
  lifecycle {
    create_before_destroy = true
  }
}

# 예약 인스턴스 권장 (비용 절감)
# 실제 구매는 AWS 콘솔에서 수행해야 합니다.
# g5.2xlarge, ap-northeast-2, 1년 부분 선결제 예약 권장
provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
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

# 퍼블릭 서브넷 생성
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-infra-public-subnet"
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
resource "aws_security_group" "llama_sg" {
  name        = "llama-service-sg"
  description = "Security group for LLaMA-based used car AI service"
  vpc_id      = aws_vpc.main.id

  # SSH 접속 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP 접속 허용
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
    Name        = "llama-service-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 역할 생성 (EC2 인스턴스용)
resource "aws_iam_role" "ec2_role" {
  name = "ec2-llama-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
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

# S3 접근 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# SSM 접근 정책 연결 (원격 관리용)
resource "aws_iam_role_policy_attachment" "ssm_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 인스턴스 프로필 생성
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "llama-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# 모델 저장용 EBS 볼륨 생성
resource "aws_ebs_volume" "model_volume" {
  availability_zone = "ap-northeast-2a"
  size              = 100  # LLaMA 모델과 데이터를 위한 충분한 공간
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name        = "llama-model-volume"
    project     = "ai-infra"
    environment = "production"
  }
}

# 키 페어 생성
resource "aws_key_pair" "deployer" {
  key_name   = "llama-deployer-key"
  public_key = file("~/.ssh/id_rsa.pub")  # 이 부분은 실제 공개키 경로로 수정 필요
}

# GPU 인스턴스 생성
resource "aws_instance" "llama_server" {
  ami                    = "ami-0e735aba742568824"  # Ubuntu 22.04 딥 러닝 AMI, 실제 AMI ID로 수정 필요
  instance_type          = "g5.2xlarge"             # NVIDIA A10G GPU 포함
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.llama_sg.id]
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip git
              pip3 install torch torchvision torchaudio transformers
              mkdir -p /home/ubuntu/llama-service
              cd /home/ubuntu/llama-service
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git
              chown -R ubuntu:ubuntu /home/ubuntu/llama-service
              EOF

  tags = {
    Name        = "llama-ai-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 연결
resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_volume.id
  instance_id = aws_instance.llama_server.id
}

# S3 버킷 생성 (모델 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "used-car-llama-model-bucket"

  tags = {
    Name        = "llama-model-bucket"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 비공개 설정
resource "aws_s3_bucket_acl" "bucket_acl" {
  bucket = aws_s3_bucket.model_bucket.id
  acl    = "private"
}

# CloudWatch 대시보드 생성
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "LLaMA-Service-Dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.llama_server.id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.llama_server.id],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.llama_server.id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "Network Traffic"
        }
      }
    ]
  })
}

# CloudWatch 알람 생성 (높은 CPU 사용률)
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "llama-service-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = []  # SNS 토픽 ARN 추가 가능
  dimensions = {
    InstanceId = aws_instance.llama_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값 정의
output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.llama_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.llama_server.public_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.model_bucket.bucket
}

output "model_volume_id" {
  description = "ID of the EBS volume for model storage"
  value       = aws_ebs_volume.model_volume.id
}
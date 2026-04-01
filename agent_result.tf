provider "aws" {
  region = "ap-northeast-2" # 서울 리전
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
resource "aws_internet_gateway" "gw" {
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
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name        = "ai-infra-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 서브넷에 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹 생성
resource "aws_security_group" "allow_ssh_http" {
  name        = "allow_ssh_http"
  description = "Allow SSH and HTTP inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API port"
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
    Name        = "ai-infra-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 인스턴스를 위한 IAM 역할
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role_for_ai_infra"

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

# EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile_for_ai_infra"
  role = aws_iam_role.ec2_role.name
}

# EC2에 대한 S3 접근 정책
resource "aws_iam_policy" "s3_access" {
  name        = "s3_access_for_ai_infra"
  description = "Allow S3 access for model storage"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# IAM 정책 연결
resource "aws_iam_role_policy_attachment" "s3_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# GPU 인스턴스 생성
resource "aws_instance" "gpu_instance" {
  ami                    = "ami-0c55b159cbfafe1f0"  # Ubuntu 20.04 with GPU drivers (사용 가능한 AMI로 변경 필요)
  instance_type          = "g5.2xlarge"             # NVIDIA A10G GPU 장착 인스턴스
  key_name               = "ai-infra-key"           # 실제 키 페어 이름으로 변경 필요
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.allow_ssh_http.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y git python3-pip
              pip3 install torch torchvision torchaudio
              
              # 코드 클론
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ubuntu/app
              
              # 필요 패키지 설치
              cd /home/ubuntu/app
              pip3 install -r requirements.txt
              
              # 서비스 등록
              cat > /etc/systemd/system/aiapp.service << 'EOL'
              [Unit]
              Description=AI Car Sales Application
              After=network.target
              
              [Service]
              User=ubuntu
              WorkingDirectory=/home/ubuntu/app
              ExecStart=/usr/bin/python3 /home/ubuntu/app/app.py
              Restart=always
              
              [Install]
              WantedBy=multi-user.target
              EOL
              
              systemctl daemon-reload
              systemctl enable aiapp
              systemctl start aiapp
              EOF

  tags = {
    Name        = "ai-infra-gpu-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 저장용)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-infra-model-storage-bucket"

  tags = {
    Name        = "AI Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# 버킷 액세스 제어
resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "model_bucket_acl" {
  bucket = aws_s3_bucket.model_bucket.id
  acl    = "private"

  depends_on = [aws_s3_bucket_ownership_controls.model_bucket_ownership]
}

# CloudWatch 경보 (GPU 사용률)
resource "aws_cloudwatch_metric_alarm" "gpu_utilization_alarm" {
  alarm_name          = "high-gpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "GPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "90"
  alarm_description   = "This alarm monitors EC2 GPU utilization"
  alarm_actions       = []

  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 정보
output "instance_public_ip" {
  description = "Public IP of the GPU instance"
  value       = aws_instance.gpu_instance.public_ip
}

output "model_bucket_name" {
  description = "S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}
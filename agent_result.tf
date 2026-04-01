provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 구성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-model-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-model-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 서브넷 구성 - 퍼블릭
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-model-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 서브넷 구성 - 프라이빗
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-model-private-subnet"
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
    Name        = "ai-model-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결 - 퍼블릭
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT 게이트웨이용 EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  
  tags = {
    Name        = "ai-model-nat-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# NAT 게이트웨이
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  
  tags = {
    Name        = "ai-model-nat"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 - 프라이빗
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "ai-model-private-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결 - 프라이빗
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# 보안 그룹 - GPU 인스턴스
resource "aws_security_group" "gpu_instance" {
  name        = "ai-model-sg"
  description = "Security group for AI model GPU instance"
  vpc_id      = aws_vpc.main.id

  # SSH 접근
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # API 접근
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  # HTTPS 접근
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  # 모델 서빙 포트 (예: 8000)
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Model serving port"
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "ai-model-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 역할 - EC2
resource "aws_iam_role" "ec2_role" {
  name = "ai-model-ec2-role"

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

# IAM 정책 - S3 접근
resource "aws_iam_policy" "s3_access" {
  name        = "ai-model-s3-access"
  description = "Allow access to S3 for model storage"

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
          "arn:aws:s3:::ai-model-bucket",
          "arn:aws:s3:::ai-model-bucket/*"
        ]
      }
    ]
  })
}

# IAM 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "s3_access_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# SSM 접근 정책 연결 (EC2 인스턴스에 접속하기 위한 Systems Manager)
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 인스턴스 프로필
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-model-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 버킷 - 모델 저장용
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-model-bucket-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "AI Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 액세스 제어
resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# S3 버킷 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "model_bucket_encryption" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 랜덤 ID 생성기 (S3 버킷 이름 고유성을 위해)
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# GPU 인스턴스 (g5.2xlarge)
resource "aws_instance" "gpu_instance" {
  ami                    = "ami-0ab04b3ccbadfae1f" # Ubuntu 22.04 LTS with Deep Learning AMI
  instance_type          = "g5.2xlarge"            # A10G 24GB GPU, 8 vCPUs, 32GB RAM
  key_name               = "ai-model-key"          # 키 페어 이름 (미리 생성 필요)
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gpu_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 100    # 100GB 루트 볼륨
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y python3-pip git
              pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              pip3 install flask gunicorn

              # Clone repository
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ubuntu/app
              chown -R ubuntu:ubuntu /home/ubuntu/app

              # Create service file
              cat > /etc/systemd/system/aimodel.service << 'EOL'
              [Unit]
              Description=AI Model Service
              After=network.target

              [Service]
              User=ubuntu
              WorkingDirectory=/home/ubuntu/app
              ExecStart=/usr/bin/python3 /home/ubuntu/app/llama_inference.py
              Restart=always

              [Install]
              WantedBy=multi-user.target
              EOL

              systemctl daemon-reload
              systemctl enable aimodel.service
              systemctl start aimodel.service
              EOF

  tags = {
    Name        = "ai-model-gpu-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP
resource "aws_eip" "gpu_instance" {
  domain = "vpc"
  
  tags = {
    Name        = "ai-model-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP 연결
resource "aws_eip_association" "gpu_instance" {
  instance_id   = aws_instance.gpu_instance.id
  allocation_id = aws_eip.gpu_instance.id
}

# CloudWatch 알람 - CPU 사용량
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-model-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값
output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.gpu_instance.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip.gpu_instance.public_ip
}

output "model_bucket_name" {
  description = "Name of the S3 bucket for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}
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

# 퍼블릭 서브넷
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

# 프라이빗 서브넷
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2b"

  tags = {
    Name        = "ai-infra-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# NAT 게이트웨이용 EIP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "ai-infra-nat-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# NAT 게이트웨이
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name        = "ai-infra-nat"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "ai-infra-public-route"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 라우팅 테이블
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name        = "ai-infra-private-route"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# 보안 그룹 - 모델 서버
resource "aws_security_group" "model_server" {
  name        = "model-server-sg"
  description = "Security group for LLaMA model server"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "API access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "ai-infra-model-server-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 역할 - EC2
resource "aws_iam_role" "ec2_role" {
  name = "ai-infra-ec2-role"

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

# IAM 정책 연결 - SSM 접속용
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM 정책 연결 - S3 접근용
resource "aws_iam_role_policy_attachment" "s3_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# IAM 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-infra-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 버킷 - 모델 저장용
resource "aws_s3_bucket" "model_storage" {
  bucket = "ai-infra-model-storage"

  tags = {
    Name        = "ai-infra-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_public_access_block" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# GPU 인스턴스 - 모델 서비스용
resource "aws_instance" "model_server" {
  ami                    = "ami-0ea5eb4b05645aa8a" # Amazon Linux 2 for Deep Learning
  instance_type          = "g5.2xlarge"            # A10G GPU
  key_name               = "ai-infra-key"          # 사전에 생성된 키 페어 이름
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.model_server.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 200
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y git python3-pip
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    pip3 install transformers
    mkdir -p /home/ec2-user/app
    cd /home/ec2-user/app
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git .
    pip3 install -r requirements.txt
    # 시작 스크립트 설정
    cat > /etc/systemd/system/llama-service.service <<'EOT'
    [Unit]
    Description=LLaMA Model Service
    After=network.target

    [Service]
    User=ec2-user
    WorkingDirectory=/home/ec2-user/app
    ExecStart=/usr/bin/python3 llama_inference.py
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    EOT

    systemctl enable llama-service
    systemctl start llama-service
    EOF

  tags = {
    Name        = "ai-infra-model-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP
resource "aws_eip" "model_server" {
  domain   = "vpc"
  instance = aws_instance.model_server.id

  tags = {
    Name        = "ai-infra-model-server-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 경보 - CPU 사용률
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-infra-high-cpu-usage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "CPU usage above 80%"
  
  dimensions = {
    InstanceId = aws_instance.model_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 경보 - 메모리 사용률 (requires CloudWatch Agent)
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-infra-high-memory-usage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "Memory usage above 80%"
  
  dimensions = {
    InstanceId = aws_instance.model_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값
output "model_server_public_ip" {
  value       = aws_eip.model_server.public_ip
  description = "Public IP of the model server"
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.model_storage.bucket
  description = "S3 bucket for model storage"
}
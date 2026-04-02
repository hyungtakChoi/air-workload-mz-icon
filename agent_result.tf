provider "aws" {
  region = "ap-northeast-2"
}

# VPC 구성
resource "aws_vpc" "ai_infra_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-infra-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.ai_infra_vpc.id
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
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.ai_infra_vpc.id
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
  vpc_id = aws_vpc.ai_infra_vpc.id

  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 라우팅 테이블 - 퍼블릭
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.ai_infra_vpc.id

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

# 라우팅 테이블 연결 - 퍼블릭
resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 보안 그룹 - AI 서버
resource "aws_security_group" "ai_server_sg" {
  name        = "ai-server-sg"
  description = "Security Group for AI Server"
  vpc_id      = aws_vpc.ai_infra_vpc.id

  # SSH 접근
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # API 서버 포트
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "API server access"
  }

  # 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-server-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# GPU EC2 인스턴스를 위한 IAM 역할
resource "aws_iam_role" "ec2_role" {
  name = "ai-server-ec2-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 접근 정책
resource "aws_iam_policy" "s3_access" {
  name        = "ai-server-s3-access"
  description = "Allow access to S3 for model storage"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::ai-model-storage-bucket",
        "arn:aws:s3:::ai-model-storage-bucket/*"
      ]
    }
  ]
}
EOF
}

# IAM 정책 연결
resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# CloudWatch 로깅 정책
resource "aws_iam_role_policy_attachment" "cloudwatch_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-server-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 버킷 - 모델 스토리지
resource "aws_s3_bucket" "model_storage" {
  bucket = "ai-model-storage-bucket"
  
  tags = {
    Name        = "AI Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 설정 - 버전 관리
resource "aws_s3_bucket_versioning" "model_versioning" {
  bucket = aws_s3_bucket.model_storage.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 버킷 설정 - 서버 사이드 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "model_encryption" {
  bucket = aws_s3_bucket.model_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# EC2 GPU 인스턴스
resource "aws_instance" "ai_server" {
  ami                    = "ami-0c9c942bd7bf113a2" # Amazon Deep Learning AMI GPU PyTorch 2.0 (Amazon Linux 2)
  instance_type          = "g5.2xlarge"
  key_name               = "ai-server-key" # 별도로 생성된 SSH 키 사용
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ai_server_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags = {
      Name        = "ai-server-root-volume"
      project     = "ai-infra"
      environment = "production"
    }
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y git python3-pip
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    
    # Clone application repository
    mkdir -p /opt/ai-service
    cd /opt/ai-service
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git .
    
    # Install application dependencies
    pip3 install -r requirements.txt
    
    # Setup application as a service
    cat <<EOT > /etc/systemd/system/ai-service.service
    [Unit]
    Description=AI Car Sales Service
    After=network.target
    
    [Service]
    User=ec2-user
    WorkingDirectory=/opt/ai-service
    ExecStart=/usr/bin/python3 app.py
    Restart=always
    
    [Install]
    WantedBy=multi-user.target
    EOT
    
    systemctl daemon-reload
    systemctl enable ai-service
    systemctl start ai-service
    
    # Setup CloudWatch agent
    yum install -y amazon-cloudwatch-agent
    cat <<EOT > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    {
      "metrics": {
        "append_dimensions": {
          "InstanceId": "${aws:InstanceId}"
        },
        "metrics_collected": {
          "gpu": {
            "measurement": [
              "utilization_gpu",
              "memory_used",
              "memory_total"
            ]
          },
          "mem": {
            "measurement": ["mem_used_percent"]
          },
          "disk": {
            "measurement": ["disk_used_percent"],
            "resources": ["/"]
          }
        }
      },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/opt/ai-service/logs/*.log",
                "log_group_name": "ai-service-logs",
                "log_stream_name": "{instance_id}"
              }
            ]
          }
        }
      }
    }
    EOT
    
    systemctl enable amazon-cloudwatch-agent
    systemctl start amazon-cloudwatch-agent
  EOF

  tags = {
    Name        = "ai-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - GPU 사용률
resource "aws_cloudwatch_metric_alarm" "gpu_utilization" {
  alarm_name          = "high-gpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "utilization_gpu"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "This alarm monitors GPU utilization"
  alarm_actions       = []

  dimensions = {
    InstanceId = aws_instance.ai_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - 메모리 사용률
resource "aws_cloudwatch_metric_alarm" "memory_utilization" {
  alarm_name          = "high-memory-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This alarm monitors memory utilization"
  alarm_actions       = []

  dimensions = {
    InstanceId = aws_instance.ai_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS 볼륨 백업을 위한 Lifecycle 정책
resource "aws_dlm_lifecycle_policy" "ebs_backup" {
  description        = "EBS Snapshot Policy for AI Server"
  execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/AWSDataLifecycleManagerDefaultRole"
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily Snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      tags_to_add = {
        SnapshotType = "Daily"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "ai-server-root-volume"
    }
  }
}

# 현재 계정 정보 가져오기
data "aws_caller_identity" "current" {}
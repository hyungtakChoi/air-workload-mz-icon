provider "aws" {
  region = "ap-northeast-2"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "main-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "main-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ai_service" {
  name        = "ai-service-sg"
  description = "Security group for AI service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API Service"
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
    Name        = "ai-service-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "ai-service-ec2-role"

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

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "s3_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-service-instance-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_instance" "ai_service" {
  ami                    = "ami-04341a215040f91bb"  # Amazon Linux 2 with GPU support (Deep Learning AMI)
  instance_type          = "g5.2xlarge"  # GPU instance with A10G 24GB
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ai_service.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = "ai-service-key"  # Make sure to create this key pair in AWS console

  root_block_device {
    volume_size = 100  # GB
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y git python3-pip
              pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              pip3 install fastapi uvicorn
              
              # Clone the application repository
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /home/ec2-user/app
              chown -R ec2-user:ec2-user /home/ec2-user/app
              
              # Setup application as a service
              cat <<EOT > /etc/systemd/system/ai-service.service
              [Unit]
              Description=AI Service
              After=network.target
              
              [Service]
              User=ec2-user
              WorkingDirectory=/home/ec2-user/app
              ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
              Restart=always
              
              [Install]
              WantedBy=multi-user.target
              EOT
              
              systemctl daemon-reload
              systemctl enable ai-service
              systemctl start ai-service
              EOF

  tags = {
    Name        = "ai-service-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_eip" "ai_service" {
  domain   = "vpc"
  instance = aws_instance.ai_service.id
  
  tags = {
    Name        = "ai-service-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-service-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    InstanceId = aws_instance.ai_service.id
  }
  
  alarm_actions = []  # Add SNS topic ARN if needed
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-service-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This metric monitors ec2 memory utilization"
  
  dimensions = {
    InstanceId = aws_instance.ai_service.id
  }
  
  alarm_actions = []  # Add SNS topic ARN if needed
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

output "public_ip" {
  value = aws_eip.ai_service.public_ip
}

output "instance_id" {
  value = aws_instance.ai_service.id
}
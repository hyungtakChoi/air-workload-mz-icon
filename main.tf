
# ============================================================
# 중고차 판매 특화 AI 서비스 - AWS Terraform 코드
# CSP: AWS | Region: ap-northeast-2 (Seoul)
# Generated: 2026-05-19
# ============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      project     = "ai-infra"
      environment = "production"
      service     = "used-car-ai"
    }
  }
}

# ============================================================
# 1. VPC & 네트워크
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "used-car-ai-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "used-car-ai-igw"
  }
}

# Public Subnets (API 서버, ALB)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "used-car-ai-public-a"
  }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true

  tags = {
    Name = "used-car-ai-public-c"
  }
}

# Private Subnets (GPU 추론 서버, RDS, ElastiCache)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name = "used-car-ai-private-a"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Name = "used-car-ai-private-c"
  }
}

# NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "used-car-ai-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "used-car-ai-nat"
  }
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "used-car-ai-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "used-car-ai-private-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# 2. 보안 그룹
# ============================================================

# ALB 보안 그룹
resource "aws_security_group" "alb" {
  name        = "used-car-ai-alb-sg"
  description = "ALB Security Group"
  vpc_id      = aws_vpc.main.id

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "used-car-ai-alb-sg"
  }
}

# API 서버 보안 그룹
resource "aws_security_group" "api" {
  name        = "used-car-ai-api-sg"
  description = "API Server Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "used-car-ai-api-sg"
  }
}

# GPU 추론 서버 보안 그룹
resource "aws_security_group" "gpu" {
  name        = "used-car-ai-gpu-sg"
  description = "GPU Inference Server Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "used-car-ai-gpu-sg"
  }
}

# RDS 보안 그룹
resource "aws_security_group" "rds" {
  name        = "used-car-ai-rds-sg"
  description = "RDS Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  tags = {
    Name = "used-car-ai-rds-sg"
  }
}

# ElastiCache 보안 그룹
resource "aws_security_group" "redis" {
  name        = "used-car-ai-redis-sg"
  description = "ElastiCache Redis Security Group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }

  tags = {
    Name = "used-car-ai-redis-sg"
  }
}

# ============================================================
# 3. S3 버킷 (LLaMA 모델 가중치 저장)
# ============================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "model_weights" {
  bucket = "used-car-ai-llama-model-weights-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "used-car-ai-model-weights"
  }
}

resource "aws_s3_bucket_versioning" "model_weights" {
  bucket = aws_s3_bucket.model_weights.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_weights" {
  bucket = aws_s3_bucket.model_weights.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model_weights" {
  bucket                  = aws_s3_bucket.model_weights.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# 4. IAM Role (EC2 → S3 접근)
# ============================================================

resource "aws_iam_role" "ec2_role" {
  name = "used-car-ai-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_policy" {
  name = "used-car-ai-s3-access"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.model_weights.arn,
        "${aws_s3_bucket.model_weights.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "used-car-ai-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ============================================================
# 5. GPU 추론 서버 (g5.xlarge - Spot Instance)
# ============================================================

data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_spot_instance_request" "gpu_inference" {
  ami                    = data.aws_ami.deep_learning.id
  instance_type          = "g5.xlarge"
  spot_price             = "0.80"
  spot_type              = "persistent"
  wait_for_fulfillment   = true
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.gpu.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    aws s3 sync s3://${aws_s3_bucket.model_weights.bucket}/llama-model /opt/llama-model
    cd /opt/app
    pip install -r requirements.txt
    python llama_inference.py --host 0.0.0.0 --port 8080 --model-path /opt/llama-model &
    EOF
  )

  tags = {
    Name = "used-car-ai-gpu-inference"
  }
}

# ============================================================
# 6. API 서버 Auto Scaling (t3.medium)
# ============================================================

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_launch_template" "api" {
  name_prefix   = "used-car-ai-api-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.medium"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.api.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type = "gp3"
      volume_size = 30
      encrypted   = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    yum update -y
    yum install -y python3 python3-pip
    cd /opt/app
    pip3 install -r requirements.txt
    export GPU_INFERENCE_URL="http://${aws_spot_instance_request.gpu_inference.private_ip}:8080"
    export REDIS_URL="${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
    python3 main.py --host 0.0.0.0 --port 8000 &
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "used-car-ai-api-server"
      project     = "ai-infra"
      environment = "production"
    }
  }
}

resource "aws_autoscaling_group" "api" {
  name                = "used-car-ai-api-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 6
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.api.arn]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.api.id
        version            = "$Latest"
      }

      override {
        instance_type = "t3.medium"
      }

      override {
        instance_type = "t3.large"
      }
    }
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "used-car-ai-api-asg"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "api_scale_out" {
  name                   = "used-car-ai-api-scale-out"
  autoscaling_group_name = aws_autoscaling_group.api.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ============================================================
# 7. ALB (Application Load Balancer)
# ============================================================

resource "aws_lb" "main" {
  name               = "used-car-ai-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]

  enable_deletion_protection = false

  tags = {
    Name = "used-car-ai-alb"
  }
}

resource "aws_lb_target_group" "api" {
  name     = "used-car-ai-api-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  tags = {
    Name = "used-car-ai-api-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ============================================================
# 8. RDS PostgreSQL (차량 정보 DB)
# ============================================================

resource "aws_db_subnet_group" "main" {
  name       = "used-car-ai-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]

  tags = {
    Name = "used-car-ai-db-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier            = "used-car-ai-postgres"
  engine                = "postgres"
  engine_version        = "15.4"
  instance_class        = "db.t3.medium"
  allocated_storage     = 50
  max_allocated_storage = 200
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "usedcarai"
  username = "dbadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"
  skip_final_snapshot       = false
  final_snapshot_identifier = "used-car-ai-postgres-final"

  performance_insights_enabled = true

  tags = {
    Name = "used-car-ai-postgres"
  }
}

# ============================================================
# 9. ElastiCache Redis (추론 결과 캐싱)
# ============================================================

resource "aws_elasticache_subnet_group" "main" {
  name       = "used-car-ai-redis-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "used-car-ai-redis"
  description          = "LLaMA 추론 결과 캐싱"

  node_type          = "cache.t3.micro"
  num_cache_clusters = 1
  port               = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = {
    Name = "used-car-ai-redis"
  }
}

# ============================================================
# 10. CloudFront (CDN)
# ============================================================

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "used-car-ai CloudFront"
  default_root_object = "index.html"

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALB-used-car-ai"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ALB-used-car-ai"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "used-car-ai-cloudfront"
  }
}

# ============================================================
# 11. API Gateway (REST API)
# ============================================================

resource "aws_api_gateway_rest_api" "main" {
  name        = "used-car-ai-api"
  description = "중고차 AI 서비스 API Gateway"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "used-car-ai-api-gateway"
  }
}

resource "aws_api_gateway_resource" "inference" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "inference"
}

resource "aws_api_gateway_method" "inference_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.inference.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "inference" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.inference.id
  http_method             = aws_api_gateway_method.inference_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.main.dns_name}/inference"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.inference]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "prod"

  tags = {
    Name = "used-car-ai-api-stage-prod"
  }
}

# ============================================================
# 12. CloudWatch 모니터링
# ============================================================

resource "aws_cloudwatch_metric_alarm" "gpu_cpu_high" {
  alarm_name          = "used-car-ai-gpu-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "GPU 서버 CPU 사용률 85% 초과"

  dimensions = {
    InstanceId = aws_spot_instance_request.gpu_inference.spot_instance_id
  }

  tags = {
    Name = "used-car-ai-gpu-cpu-alarm"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "used-car-ai-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU 사용률 80% 초과"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  tags = {
    Name = "used-car-ai-rds-cpu-alarm"
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu_high" {
  alarm_name          = "used-car-ai-redis-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Redis CPU 사용률 75% 초과"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  tags = {
    Name = "used-car-ai-redis-cpu-alarm"
  }
}

# ============================================================
# 13. Variables
# ============================================================

variable "db_password" {
  description = "RDS PostgreSQL 관리자 비밀번호"
  type        = string
  sensitive   = true
}

# ============================================================
# 14. Outputs
# ============================================================

output "cloudfront_domain" {
  description = "CloudFront 도메인 (서비스 접속 URL)"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "api_gateway_url" {
  description = "API Gateway 엔드포인트"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/inference"
}

output "alb_dns_name" {
  description = "ALB DNS 이름"
  value       = aws_lb.main.dns_name
}

output "gpu_instance_private_ip" {
  description = "GPU 추론 서버 Private IP"
  value       = aws_spot_instance_request.gpu_inference.private_ip
}

output "rds_endpoint" {
  description = "RDS PostgreSQL 엔드포인트"
  value       = aws_db_instance.postgres.endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis 엔드포인트"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
  sensitive   = true
}

output "model_s3_bucket" {
  description = "LLaMA 모델 가중치 S3 버킷명"
  value       = aws_s3_bucket.model_weights.bucket
}

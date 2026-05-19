
# =====================================================
# 중고차 판매 특화 LLaMA AI 서비스 - GCP Terraform
# Region: asia-northeast3 (Seoul)
# Instance: g2-standard-4 (L4 GPU 24GB VRAM)
# =====================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "asia-northeast3"
  zone    = "asia-northeast3-a"
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH Public Key"
  type        = string
  default     = ""
}

# =====================================================
# VPC & Network
# =====================================================
resource "google_compute_network" "llama_vpc" {
  name                    = "llama-ai-vpc"
  auto_create_subnetworks = false

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "google_compute_subnetwork" "llama_subnet" {
  name          = "llama-ai-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.llama_vpc.id
}

# =====================================================
# Firewall Rules
# =====================================================
resource "google_compute_firewall" "allow_http_https" {
  name    = "llama-allow-http-https"
  network = google_compute_network.llama_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8000", "8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["llama-server"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "llama-allow-ssh"
  network = google_compute_network.llama_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["llama-server"]
}

# =====================================================
# Static External IP
# =====================================================
resource "google_compute_address" "llama_ip" {
  name   = "llama-ai-static-ip"
  region = "asia-northeast3"
}

# =====================================================
# GCS Bucket (모델 가중치 저장)
# =====================================================
resource "google_storage_bucket" "model_bucket" {
  name          = "${var.project_id}-llama-model-weights"
  location      = "ASIA-NORTHEAST3"
  force_destroy = false

  storage_class = "STANDARD"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# =====================================================
# GPU Compute Instance (g2-standard-4, L4 GPU)
# =====================================================
resource "google_compute_instance" "llama_gpu_server" {
  name         = "llama-ai-gpu-server"
  machine_type = "g2-standard-4"
  zone         = "asia-northeast3-a"

  tags = ["llama-server"]

  boot_disk {
    initialize_params {
      image = "projects/deeplearning-platform-release/global/images/family/pytorch-latest-gpu"
      size  = 100
      type  = "pd-ssd"
    }
  }

  # L4 GPU (24GB VRAM) - g2-standard-4에 포함
  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE"
    automatic_restart   = true
    # 비용 최적화: Spot VM 사용 (약 60~70% 절감)
    provisioning_model  = "SPOT"
    instance_termination_action = "STOP"
  }

  network_interface {
    network    = google_compute_network.llama_vpc.id
    subnetwork = google_compute_subnetwork.llama_subnet.id

    access_config {
      nat_ip = google_compute_address.llama_ip.address
    }
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
    startup-script = <<-EOF
      #!/bin/bash
      apt-get update -y
      apt-get install -y python3-pip git
      pip3 install torch transformers accelerate fastapi uvicorn
      # LLaMA 모델 가중치 GCS에서 다운로드
      gsutil -m cp -r gs://${google_storage_bucket.model_bucket.name}/models /opt/llama/
      # FastAPI 서버 실행
      cd /opt/llama && nohup uvicorn main:app --host 0.0.0.0 --port 8000 &
    EOF
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
    service     = "llama-inference"
  }
}

# =====================================================
# Cloud SQL (중고차 데이터 저장)
# =====================================================
resource "google_sql_database_instance" "car_db" {
  name             = "used-car-db"
  database_version = "POSTGRES_15"
  region           = "asia-northeast3"

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 20
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.llama_vpc.id
    }

    user_labels = {
      project     = "ai-infra"
      environment = "production"
    }
  }

  deletion_protection = true
}

resource "google_sql_database" "car_database" {
  name     = "used_car_db"
  instance = google_sql_database_instance.car_db.name
}

# =====================================================
# Memorystore Redis (추론 결과 캐싱)
# =====================================================
resource "google_redis_instance" "llama_cache" {
  name           = "llama-inference-cache"
  tier           = "BASIC"
  memory_size_gb = 2
  region         = "asia-northeast3"

  authorized_network = google_compute_network.llama_vpc.id

  redis_version = "REDIS_7_0"

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# =====================================================
# Load Balancer (HTTP)
# =====================================================
resource "google_compute_instance_group" "llama_group" {
  name      = "llama-instance-group"
  zone      = "asia-northeast3-a"
  instances = [google_compute_instance.llama_gpu_server.id]

  named_port {
    name = "http"
    port = 8000
  }
}

resource "google_compute_health_check" "llama_health" {
  name = "llama-health-check"

  http_health_check {
    port         = 8000
    request_path = "/health"
  }
}

resource "google_compute_backend_service" "llama_backend" {
  name                  = "llama-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_health_check.llama_health.id]

  backend {
    group = google_compute_instance_group.llama_group.id
  }
}

resource "google_compute_url_map" "llama_url_map" {
  name            = "llama-url-map"
  default_service = google_compute_backend_service.llama_backend.id
}

resource "google_compute_target_http_proxy" "llama_proxy" {
  name    = "llama-http-proxy"
  url_map = google_compute_url_map.llama_url_map.id
}

resource "google_compute_global_forwarding_rule" "llama_forwarding" {
  name                  = "llama-forwarding-rule"
  target                = google_compute_target_http_proxy.llama_proxy.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL"
}

# =====================================================
# Outputs
# =====================================================
output "gpu_server_external_ip" {
  value       = google_compute_address.llama_ip.address
  description = "LLaMA GPU 서버 외부 IP"
}

output "model_bucket_name" {
  value       = google_storage_bucket.model_bucket.name
  description = "모델 가중치 저장 GCS 버킷"
}

output "load_balancer_ip" {
  value       = google_compute_global_forwarding_rule.llama_forwarding.ip_address
  description = "로드밸런서 외부 IP"
}

output "redis_host" {
  value       = google_redis_instance.llama_cache.host
  description = "Redis 캐시 호스트"
}

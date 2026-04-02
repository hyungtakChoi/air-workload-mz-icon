terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = "my-project-id"  # 실제 프로젝트 ID로 변경 필요
  region  = "asia-northeast3"  # 서울 리전
  zone    = "asia-northeast3-a"
}

# VPC 네트워크
resource "google_compute_network" "vpc_network" {
  name                    = "ai-infra-vpc"
  auto_create_subnetworks = false
}

# 서브넷
resource "google_compute_subnetwork" "subnet" {
  name          = "ai-infra-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.vpc_network.id
}

# 방화벽 규칙 - SSH 접속 허용
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

# 방화벽 규칙 - 애플리케이션 포트 허용
resource "google_compute_firewall" "allow_app" {
  name    = "allow-app"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]  # 애플리케이션 포트
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app"]
}

# 인스턴스 템플릿
resource "google_compute_instance_template" "instance_template" {
  name_prefix  = "ai-infra-template-"
  machine_type = "g2-standard-8"  # GPU가 있는 인스턴스 유형
  tags         = ["ssh", "app"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
    disk_size_gb = 100  # LLaMA 모델을 위한 충분한 스토리지
  }

  # GPU 설정
  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "TERMINATE"  # GPU 인스턴스는 TERMINATE 필요
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      # 기본 외부 IP 할당
    }
  }

  metadata = {
    startup-script = <<-EOT
      #!/bin/bash
      apt-get update
      apt-get install -y python3 python3-pip git
      
      # NVIDIA 드라이버 및 CUDA 설치
      curl -O https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/cuda-keyring_1.0-1_all.deb
      dpkg -i cuda-keyring_1.0-1_all.deb
      apt-get update
      apt-get -y install cuda-drivers
      apt-get -y install cuda
      
      # 프로젝트 클론 및 의존성 설치
      cd /home
      git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git
      cd air-workload-mz-icon
      pip3 install -r requirements.txt
    EOT
  }

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 관리형 인스턴스 그룹
resource "google_compute_instance_group_manager" "instance_group" {
  name               = "ai-infra-instance-group"
  base_instance_name = "ai-infra-vm"
  zone               = "asia-northeast3-a"
  target_size        = 1  # 초기 인스턴스 수

  version {
    instance_template = google_compute_instance_template.instance_template.id
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }
}

# 헬스 체크
resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10

  http_health_check {
    request_path = "/health"
    port         = "80"
  }
}

# Cloud Storage 버킷 (모델 저장용)
resource "google_storage_bucket" "model_bucket" {
  name          = "ai-infra-model-bucket"  # 전역적으로 고유한 이름으로 변경 필요
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  
  uniform_bucket_level_access = true

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 부하 분산기
resource "google_compute_global_address" "lb_ip" {
  name = "ai-infra-lb-ip"
}

resource "google_compute_backend_service" "backend" {
  name        = "ai-infra-backend"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 10

  backend {
    group = google_compute_instance_group_manager.instance_group.instance_group
  }

  health_checks = [google_compute_health_check.autohealing.id]
}

resource "google_compute_url_map" "url_map" {
  name            = "ai-infra-url-map"
  default_service = google_compute_backend_service.backend.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "ai-infra-http-proxy"
  url_map = google_compute_url_map.url_map.id
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "ai-infra-forwarding-rule"
  target     = google_compute_target_http_proxy.http_proxy.id
  port_range = "80"
  ip_address = google_compute_global_address.lb_ip.address
}
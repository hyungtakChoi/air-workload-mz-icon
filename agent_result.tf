terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "google" {
  project = "ai-car-sales-project"
  region  = "asia-northeast3" # 서울 리전
}

# VPC 네트워크 생성
resource "google_compute_network" "ai_network" {
  name                    = "ai-car-sales-network"
  auto_create_subnetworks = false
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 서브넷 생성
resource "google_compute_subnetwork" "ai_subnet" {
  name          = "ai-car-sales-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.ai_network.id
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 방화벽 규칙 - SSH 접속 허용
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.ai_network.name
  
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ai-instance"]
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 방화벽 규칙 - 웹 서비스 포트 허용
resource "google_compute_firewall" "allow_web" {
  name    = "allow-web-service"
  network = google_compute_network.ai_network.name
  
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8000", "8080"]
  }
  
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ai-instance"]
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# GPU가 있는 Compute Engine VM 인스턴스
resource "google_compute_instance" "ai_instance" {
  name         = "ai-car-sales-server"
  machine_type = "g2-standard-8"  # NVIDIA L4 GPU, 8vCPU, 32GB 메모리
  zone         = "asia-northeast3-a"
  
  boot_disk {
    initialize_params {
      image = "projects/deeplearning-platform-release/global/images/family/common-gpu-debian-11"
      size  = 100 # GB
      type  = "pd-ssd"
    }
  }
  
  network_interface {
    network    = google_compute_network.ai_network.id
    subnetwork = google_compute_subnetwork.ai_subnet.id
    access_config {
      # 외부 IP 할당
    }
  }
  
  # GPU 설정
  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }
  
  scheduling {
    on_host_maintenance = "TERMINATE" # GPU VM 필요
    automatic_restart   = true
    preemptible         = false
  }
  
  # 시작 스크립트 - Git clone, 기본 환경 설정, 필요한 패키지 설치
  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y git python3-pip
    
    # Git 저장소 클론
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /opt/ai-car-sales
    
    # 필요한 Python 패키지 설치
    cd /opt/ai-car-sales
    pip install -r requirements.txt
    
    # NVIDIA 드라이버와 CUDA 설정 (이미 이미지에 포함되어 있음)
    # 기타 필요한 설정
  EOT
  
  service_account {
    scopes = ["cloud-platform"]
  }
  
  tags = ["ai-instance"]
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 영구 디스크 추가 - 모델 파일 저장용
resource "google_compute_disk" "model_data_disk" {
  name = "ai-model-data-disk"
  type = "pd-ssd"
  zone = "asia-northeast3-a"
  size = 200 # GB
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 영구 디스크 VM 연결
resource "google_compute_attached_disk" "model_disk_attachment" {
  disk     = google_compute_disk.model_data_disk.id
  instance = google_compute_instance.ai_instance.id
}

# Cloud Storage 버킷 - 모델 파일 및 데이터 저장
resource "google_storage_bucket" "model_storage" {
  name          = "ai-car-sales-models"
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  
  versioning {
    enabled = true
  }
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 서비스 계정 - VM에서 Cloud Storage 접근용
resource "google_service_account" "ai_service_account" {
  account_id   = "ai-service-account"
  display_name = "AI Service Account"
}

# IAM 권한 부여
resource "google_project_iam_binding" "storage_object_admin" {
  project = "ai-car-sales-project"
  role    = "roles/storage.objectAdmin"
  
  members = [
    "serviceAccount:${google_service_account.ai_service_account.email}"
  ]
}
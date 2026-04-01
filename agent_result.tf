terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = "ai-infra-project"
  region  = "asia-northeast3" # 서울 리전
}

# 네트워크 구성
resource "google_compute_network" "vpc" {
  name                    = "ai-infra-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "ai-infra-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.vpc.id
}

# 방화벽 규칙
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ai-infra-instance"]
}

resource "google_compute_firewall" "allow_http" {
  name    = "allow-http"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ai-infra-instance"]
}

# GPU 인스턴스
resource "google_compute_instance" "ai_instance" {
  name         = "ai-inference-server"
  machine_type = "g2-standard-8"  # 8 vCPU, 32GB 메모리
  zone         = "asia-northeast3-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 100  # 100GB 스토리지
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      // Ephemeral public IP
    }
  }

  guest_accelerator {
    type  = "nvidia-l4"  # L4 GPU
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE"  # GPU 인스턴스 필수 설정
  }

  # 시작 스크립트: Git 저장소 클론 및 기본 설정
  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y git python3-pip
    
    # NVIDIA 드라이버 및 CUDA 설치
    curl -O https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/cuda-keyring_1.0-1_all.deb
    dpkg -i cuda-keyring_1.0-1_all.deb
    apt-get update
    apt-get install -y cuda-drivers cuda
    
    # 프로젝트 클론 및 설정
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /opt/app
    cd /opt/app
    pip3 install -r requirements.txt
  EOT

  service_account {
    scopes = ["cloud-platform"]
  }

  tags = ["ai-infra-instance"]
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud Storage 버킷 (모델 및 데이터 저장용)
resource "google_storage_bucket" "model_bucket" {
  name          = "ai-infra-models-bucket"
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  
  uniform_bucket_level_access = true
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Google Cloud Monitoring - 알림 정책 설정
resource "google_monitoring_alert_policy" "gpu_utilization_alert" {
  display_name = "GPU Utilization Alert"
  combiner     = "OR"
  
  conditions {
    display_name = "GPU utilization exceeds 90%"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND resource.labels.instance_id = \"${google_compute_instance.ai_instance.instance_id}\" AND metric.type = \"compute.googleapis.com/instance/gpu/utilization\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = []  # 실제 사용 시 알림 채널 ID 추가
}

# 출력 변수
output "instance_external_ip" {
  value = google_compute_instance.ai_instance.network_interface[0].access_config[0].nat_ip
  description = "AI 추론 서버 공용 IP"
}
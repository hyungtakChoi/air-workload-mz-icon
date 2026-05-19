
# ============================================================
# Azure 중고차 판매 특화 LLaMA AI 서비스 인프라
# CSP     : Azure
# Region  : Korea Central
# Project : ai-infra
# Env     : production
# ============================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
  required_version = ">= 1.5.0"
}

provider "azurerm" {
  features {}
}

# ============================================================
# 1. Resource Group
# ============================================================
resource "azurerm_resource_group" "ai_infra" {
  name     = "rg-ai-infra-production"
  location = "Korea Central"

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# 2. Virtual Network & Subnets
# ============================================================
resource "azurerm_virtual_network" "main" {
  name                = "vnet-ai-infra"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_subnet" "public" {
  name                 = "subnet-public"
  resource_group_name  = azurerm_resource_group.ai_infra.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "subnet-private"
  resource_group_name  = azurerm_resource_group.ai_infra.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "subnet-db"
  resource_group_name  = azurerm_resource_group.ai_infra.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "mysql-delegation"
    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# ============================================================
# 3. Network Security Groups
# ============================================================
resource "azurerm_network_security_group" "api" {
  name                = "nsg-api-server"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name

  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_network_security_group" "llm" {
  name                = "nsg-llm-server"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name

  security_rule {
    name                       = "allow-internal-inference"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# 4. Public IP & Azure Load Balancer
# ============================================================
resource "azurerm_public_ip" "lb" {
  name                = "pip-load-balancer"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_lb" "main" {
  name                = "lb-ai-infra"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.lb.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_lb_backend_address_pool" "api" {
  name            = "backend-pool-api"
  loadbalancer_id = azurerm_lb.main.id
}

resource "azurerm_lb_probe" "http" {
  name            = "probe-http"
  loadbalancer_id = azurerm_lb.main.id
  protocol        = "Http"
  port            = 80
  request_path    = "/health"
}

resource "azurerm_lb_rule" "http" {
  name                           = "rule-http"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "frontend-ip"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api.id]
  probe_id                       = azurerm_lb_probe.http.id
}

# ============================================================
# 5. API 서버 - VMSS (Auto Scaling, t-series 비용 최적)
# ============================================================
resource "azurerm_linux_virtual_machine_scale_set" "api" {
  name                = "vmss-api-server"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name
  sku                 = "Standard_D2as_v5"   # ARM 기반, 비용 최적
  instances           = 2

  admin_username = "azureuser"

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  network_interface {
    name    = "nic-api"
    primary = true

    ip_configuration {
      name                                   = "ipconfig-api"
      primary                                = true
      subnet_id                              = azurerm_subnet.public.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.api.id]
    }
  }

  # Auto Scaling 설정
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT30M"
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_monitor_autoscale_setting" "api" {
  name                = "autoscale-api-server"
  resource_group_name = azurerm_resource_group.ai_infra.name
  location            = azurerm_resource_group.ai_infra.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.api.id

  profile {
    name = "default-profile"

    capacity {
      default = 2
      minimum = 1
      maximum = 5
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.api.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.api.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# 6. LLM 추론 서버 - NV36ads_A10_v5 (A10 GPU 24GB)
#    비용 최적: Azure Spot VM 활용 (최대 90% 절감)
# ============================================================
resource "azurerm_network_interface" "llm" {
  name                = "nic-llm-server"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name

  ip_configuration {
    name                          = "ipconfig-llm"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_linux_virtual_machine" "llm_inference" {
  name                = "vm-llm-inference"
  location            = azurerm_resource_group.ai_infra.location
  resource_group_name = azurerm_resource_group.ai_infra.name
  size                = "Standard_NV36ads_A10_v5"  # A10 GPU 24GB
  admin_username      = "azureuser"

  # Spot VM 설정 (비용 최적화 - 최대 90% 절감)
  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = 0.5  # On-Demand 대비 약 60% 수준

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  network_interface_ids = [azurerm_network_interface.llm.id]

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128  # LLaMA 모델 가중치 저장
  }

  # LLaMA 추론 환경 초기화 스크립트
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y python3-pip git
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
    pip3 install transformers accelerate vllm
    # LLaMA 모델 가중치 다운로드 (Azure Blob Storage에서)
    az storage blob download-batch \
      --destination /opt/llama-model \
      --source llama-models \
      --account-name ${azurerm_storage_account.main.name}
    # vLLM 서버 시작 (포트 8080)
    python3 -m vllm.entrypoints.api_server \
      --model /opt/llama-model \
      --port 8080 &
  EOF
  )

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# 7. Azure Blob Storage (모델 가중치 + 중고차 이미지)
# ============================================================
resource "azurerm_storage_account" "main" {
  name                     = "staiinfraprod001"
  resource_group_name      = azurerm_resource_group.ai_infra.name
  location                 = azurerm_resource_group.ai_infra.location
  account_tier             = "Standard"
  account_replication_type = "LRS"  # 비용 최적: 로컬 중복 스토리지

  blob_properties {
    # 비용 최적: 30일 후 Cool 티어로 자동 이동
    delete_retention_policy {
      days = 7
    }
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_storage_container" "llama_models" {
  name                  = "llama-models"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "car_images" {
  name                  = "car-images"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "blob"  # 중고차 이미지 공개 접근
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "move-to-cool-tier"
    enabled = true

    filters {
      prefix_match = ["car-images/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = 365
      }
    }
  }
}

# ============================================================
# 8. Azure Database for MySQL Flexible Server
# ============================================================
resource "azurerm_private_dns_zone" "mysql" {
  name                = "aiinfra.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.ai_infra.name

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  resource_group_name   = azurerm_resource_group.ai_infra.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_mysql_flexible_server" "main" {
  name                   = "mysql-ai-infra-prod"
  resource_group_name    = azurerm_resource_group.ai_infra.name
  location               = azurerm_resource_group.ai_infra.location
  administrator_login    = "adminuser"
  administrator_password = var.mysql_admin_password
  sku_name               = "B_Standard_B2ms"  # 비용 최적: Burstable 티어
  version                = "8.0.21"

  delegated_subnet_id    = azurerm_subnet.db.id
  private_dns_zone_id    = azurerm_private_dns_zone.mysql.id

  storage {
    size_gb = 32
    iops    = 396
  }

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false  # 비용 최적: 지역 중복 백업 비활성화

  high_availability {
    mode = "Disabled"  # 비용 최적: HA 비활성화 (필요 시 SameZone으로 변경)
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

resource "azurerm_mysql_flexible_database" "car_db" {
  name                = "used_car_db"
  resource_group_name = azurerm_resource_group.ai_infra.name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# ============================================================
# 9. Azure Monitor - Cost Alert (비용 이상 감지)
# ============================================================
resource "azurerm_monitor_action_group" "cost_alert" {
  name                = "ag-cost-alert"
  resource_group_name = azurerm_resource_group.ai_infra.name
  short_name          = "costalert"

  email_receiver {
    name          = "admin-email"
    email_address = "gwonsoo.che@mz.co.kr"
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# 10. Variables
# ============================================================
variable "mysql_admin_password" {
  description = "MySQL 관리자 비밀번호"
  type        = string
  sensitive   = true
}

# ============================================================
# 11. Outputs
# ============================================================
output "load_balancer_public_ip" {
  description = "Azure Load Balancer 공인 IP"
  value       = azurerm_public_ip.lb.ip_address
}

output "llm_server_private_ip" {
  description = "LLM 추론 서버 내부 IP"
  value       = azurerm_network_interface.llm.private_ip_address
}

output "storage_account_name" {
  description = "Blob Storage 계정명"
  value       = azurerm_storage_account.main.name
}

output "mysql_server_fqdn" {
  description = "MySQL 서버 FQDN"
  value       = azurerm_mysql_flexible_server.main.fqdn
}

output "estimated_monthly_cost" {
  description = "예상 월 비용 (Spot VM 적용 기준)"
  value       = "약 $320~420/월 (Spot VM + Reserved 1년 약정 적용 시 약 $220~280/월)"
}

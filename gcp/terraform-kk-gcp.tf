# GCP Terraform Configuration for KodeKloud Playground Max Usage
# This configuration maximizes resource usage within KodeKloud GCP playground constraints

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
  # Note: This should be set via environment variable or terraform.tfvars
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for resources"
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "kodekloud-playground"
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Enable required APIs
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "storage" {
  service = "storage.googleapis.com"
}

resource "google_project_service" "sql" {
  service = "sql-component.googleapis.com"
}

# VPC Network
resource "google_compute_network" "main" {
  name                    = "${var.environment}-vpc"
  auto_create_subnetworks = false
  
  depends_on = [google_project_service.compute]
}

# Subnets for different tiers
resource "google_compute_subnetwork" "web" {
  name          = "${var.environment}-web-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "192.168.1.0/24"
  }

  secondary_ip_range {
    range_name    = "pod-ranges"
    ip_cidr_range = "192.168.64.0/22"
  }
}

resource "google_compute_subnetwork" "app" {
  name          = "${var.environment}-app-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.main.id
}

resource "google_compute_subnetwork" "db" {
  name          = "${var.environment}-db-subnet"
  ip_cidr_range = "10.0.3.0/24"
  region        = var.region
  network       = google_compute_network.main.id
}

# Firewall Rules
resource "google_compute_firewall" "allow_web" {
  name    = "${var.environment}-allow-web"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web-server"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.environment}-allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh-access"]
}

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.environment}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/16"]
}

resource "google_compute_firewall" "allow_app" {
  name    = "${var.environment}-allow-app"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["8080", "8443"]
  }

  source_tags = ["web-server"]
  target_tags = ["app-server"]
}

# Static External IPs
resource "google_compute_address" "web" {
  count  = 2
  name   = "${var.environment}-web-ip-${count.index + 1}"
  region = var.region
}

# Instance Templates
resource "google_compute_instance_template" "web" {
  name_prefix  = "${var.environment}-web-template-"
  machine_type = "e2-micro"  # Free tier eligible
  region       = var.region

  tags = ["web-server", "ssh-access"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    subnetwork = google_compute_subnetwork.web.id
    
    access_config {
      # Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = "debian:${file("~/.ssh/id_rsa.pub")}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo "<h1>KodeKloud GCP Playground - Web Server $(hostname)</h1>" > /var/www/html/index.html
  EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_template" "app" {
  name_prefix  = "${var.environment}-app-template-"
  machine_type = "e2-micro"  # Free tier eligible
  region       = var.region

  tags = ["app-server", "ssh-access"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
    # No external IP for app tier
  }

  metadata = {
    ssh-keys = "debian:${file("~/.ssh/id_rsa.pub")}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3 python3-pip
    pip3 install flask
    echo "from flask import Flask; app = Flask(__name__); @app.route('/'); def hello(): return 'KodeKloud GCP App Server'; app.run(host='0.0.0.0', port=8080)" > /app.py
    python3 /app.py &
  EOF

  lifecycle {
    create_before_destroy = true
  }
}

# Compute Instances (within playground limits)
resource "google_compute_instance" "web" {
  count        = 2
  name         = "${var.environment}-web-${count.index + 1}"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["web-server", "ssh-access"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.web.id
    
    access_config {
      nat_ip = google_compute_address.web[count.index].address
    }
  }

  metadata = {
    ssh-keys = "debian:${tls_private_key.ssh.public_key_openssh}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo "<h1>KodeKloud GCP Playground - Web Server ${count.index + 1}</h1>" > /var/www/html/index.html
  EOF

  labels = {
    environment = var.environment
    tier        = "web"
  }

  depends_on = [google_project_service.compute]
}

resource "google_compute_instance" "app" {
  count        = 2
  name         = "${var.environment}-app-${count.index + 1}"
  machine_type = "e2-micro"
  zone         = var.zone

  tags = ["app-server", "ssh-access"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app.id
    # No external IP
  }

  metadata = {
    ssh-keys = "debian:${tls_private_key.ssh.public_key_openssh}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3 python3-pip
    pip3 install flask
    cat > /app.py << 'EOL'
from flask import Flask
app = Flask(__name__)
@app.route('/')
def hello():
    return f'KodeKloud GCP App Server ${count.index + 1}'
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOL
    nohup python3 /app.py > /var/log/app.log 2>&1 &
  EOF

  labels = {
    environment = var.environment
    tier        = "app"
  }

  depends_on = [google_project_service.compute]
}

# Instance Groups
resource "google_compute_instance_group" "web" {
  name      = "${var.environment}-web-group"
  zone      = var.zone
  instances = google_compute_instance.web[*].id

  named_port {
    name = "http"
    port = "80"
  }

  named_port {
    name = "https"
    port = "443"
  }
}

# HTTP Health Check
resource "google_compute_http_health_check" "web" {
  name         = "${var.environment}-web-health-check"
  request_path = "/"
  port         = "80"
}

# Load Balancer Components
resource "google_compute_backend_service" "web" {
  name        = "${var.environment}-web-backend"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 10

  health_checks = [google_compute_http_health_check.web.id]

  backend {
    group = google_compute_instance_group.web.id
  }
}

resource "google_compute_url_map" "web" {
  name            = "${var.environment}-web-url-map"
  default_service = google_compute_backend_service.web.id
}

resource "google_compute_target_http_proxy" "web" {
  name    = "${var.environment}-web-proxy"
  url_map = google_compute_url_map.web.id
}

resource "google_compute_global_forwarding_rule" "web" {
  name       = "${var.environment}-web-forwarding-rule"
  target     = google_compute_target_http_proxy.web.id
  port_range = "80"
}

# Cloud Storage Bucket
resource "google_storage_bucket" "main" {
  name     = "${var.project_id}-${var.environment}-bucket-${random_string.bucket_suffix.result}"
  location = var.region

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    environment = var.environment
  }

  depends_on = [google_project_service.storage]
}

# Cloud SQL Instance (if within playground limits)
resource "google_sql_database_instance" "main" {
  name             = "${var.environment}-db-${random_string.db_suffix.result}"
  database_version = "MYSQL_8_0"
  region           = var.region

  settings {
    tier = "db-f1-micro"  # Smallest instance size
    
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }

    backup_configuration {
      enabled = true
    }
  }

  depends_on = [google_project_service.sql]
}

resource "google_sql_database" "main" {
  name     = "${replace(var.environment, "-", "_")}_db"
  instance = google_sql_database_instance.main.name
}

# SSH Key for instances
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Random suffixes for unique naming
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "random_string" "db_suffix" {
  length  = 4
  special = false
  upper   = false
}

# Outputs
output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "vpc_network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.main.name
}

output "web_instance_external_ips" {
  description = "External IPs of web instances"
  value       = google_compute_address.web[*].address
}

output "web_instance_names" {
  description = "Names of web instances"
  value       = google_compute_instance.web[*].name
}

output "app_instance_names" {
  description = "Names of app instances"
  value       = google_compute_instance.app[*].name
}

output "load_balancer_ip" {
  description = "IP address of the load balancer"
  value       = google_compute_global_forwarding_rule.web.ip_address
}

output "storage_bucket_name" {
  description = "Name of the storage bucket"
  value       = google_storage_bucket.main.name
}

output "database_instance_name" {
  description = "Name of the Cloud SQL instance"
  value       = google_sql_database_instance.main.name
}

output "ssh_private_key" {
  description = "Private SSH key for accessing instances"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
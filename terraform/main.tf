terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "spaces_access_key" {
  description = "DigitalOcean Spaces access key"
  type        = string
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "DigitalOcean Spaces secret key"
  type        = string
  sensitive   = true
}

variable "public_key" {
  description = "SSH public key for droplet access"
  type        = string
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "node"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "digitaltest"
}

variable "node_env" {
  description = "Node environment"
  type        = string
  default     = "production"
}

variable "db_host" {
  description = "PostgreSQL host"
  type        = string
  default     = ""
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = string
  default     = "5432"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = ""
}

variable "db_user" {
  description = "PostgreSQL user"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "extra_env_vars" {
  description = "Additional environment variables as a map"
  type        = map(string)
  default     = {}
}

locals {
  safe_app_name     = lower(replace(replace(var.app_name, "_", "-"), " ", "-"))
  safe_project_name = lower(replace(replace(var.project_name, "_", "-"), " ", "-"))
  resource_prefix   = "${local.safe_project_name}-${local.safe_app_name}"
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_ssh_key" "app_key" {
  name       = "${local.resource_prefix}-key"
  public_key = var.public_key

  lifecycle {
    ignore_changes = [public_key]
  }
}

resource "digitalocean_droplet" "app" {
  name      = "${local.resource_prefix}-droplet"
  image     = "ubuntu-22-04-x64"
  region    = var.region
  size      = var.droplet_size
  ssh_keys  = [digitalocean_ssh_key.app_key.fingerprint]

  tags = [
    local.safe_project_name,
    local.safe_app_name,
    "terraform"
  ]
}

resource "digitalocean_firewall" "app_firewall" {
  name = "${local.resource_prefix}-fw"

  droplet_ids = [digitalocean_droplet.app.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "null_resource" "ansible_provisioner" {
  depends_on = [
    digitalocean_droplet.app,
    digitalocean_firewall.app_firewall
  ]

  triggers = {
    droplet_id = digitalocean_droplet.app.id
    droplet_ip = digitalocean_droplet.app.ipv4_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for SSH to be available on ${digitalocean_droplet.app.ipv4_address}..."
      timeout 120 bash -c 'until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes root@${digitalocean_droplet.app.ipv4_address} "echo ready" 2>/dev/null; do sleep 5; done'
      echo "SSH is available. Running Ansible..."
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        -i "${digitalocean_droplet.app.ipv4_address}," \
        -u root \
        --private-key "$SSH_PRIVATE_KEY_PATH" \
        -e "app_name=${local.safe_app_name}" \
        -e "project_name=${local.safe_project_name}" \
        -e "node_env=${var.node_env}" \
        -e "app_port=3000" \
        -e "db_host=${var.db_host}" \
        -e "db_port=${var.db_port}" \
        -e "db_name=${var.db_name}" \
        -e "db_user=${var.db_user}" \
        -e "db_password=${var.db_password}" \
        ansible/playbook.yml
    EOT

    environment = {
      ANSIBLE_FORCE_COLOR       = "1"
      ANSIBLE_ROLES_PATH        = "../ansible/roles"
      SSH_PRIVATE_KEY_PATH      = pathexpand("~/.ssh/id_rsa")
    }
  }
}

output "droplet_id" {
  description = "The ID of the deployed droplet"
  value       = digitalocean_droplet.app.id
}

output "droplet_ip" {
  description = "The public IPv4 address of the droplet"
  value       = digitalocean_droplet.app.ipv4_address
}

output "droplet_name" {
  description = "The name of the droplet"
  value       = digitalocean_droplet.app.name
}

output "droplet_region" {
  description = "The region of the droplet"
  value       = digitalocean_droplet.app.region
}

output "app_url" {
  description = "The URL to access the application"
  value       = "http://${digitalocean_droplet.app.ipv4_address}"
}

output "health_check_url" {
  description = "The URL to check application health"
  value       = "http://${digitalocean_droplet.app.ipv4_address}/health"
}

output "ssh_command" {
  description = "SSH command to connect to the droplet"
  value       = "ssh root@${digitalocean_droplet.app.ipv4_address}"
}
# One spot GPU VM for a Benchmark session: g2-standard-12 (1x L4, 48 GB),
# single-node RKE2. The VM deletes itself after max_hours, whatever happens
# on the laptop. `make bench-up` / `make bench-down` drive this.
terraform {
  required_version = ">= 1.9"
  required_providers {
    google = { source = "hashicorp/google", version = "8.5.0" }
  }
}

variable "project" { description = "GCP project ID (TF_VAR_project)" }
variable "billing_account" { description = "Billing account ID for the budget alert (TF_VAR_billing_account)" }
variable "region" { default = "us-central1" }
variable "zone" { default = "us-central1-a" } # L4 spot stock-outs happen: retry with -b or -c
variable "max_hours" { default = 5 }
variable "spot" { default = true }
variable "ssh_cidr" { description = "Your public IP, e.g. 1.2.3.4/32" }

provider "google" {
  project               = var.project
  region                = var.region
  billing_project       = var.project # the budgets API needs a quota project with user credentials
  user_project_override = true
}

resource "google_project_service" "budgets" {
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

# Own VPC: the default one lets SSH in from anywhere.
resource "google_compute_network" "bench" {
  name                    = "llm-bench"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "bench" {
  name          = "llm-bench"
  region        = var.region
  network       = google_compute_network.bench.id
  ip_cidr_range = "10.10.0.0/24"
}

resource "google_compute_firewall" "ssh" {
  name          = "llm-bench-ssh"
  network       = google_compute_network.bench.id
  source_ranges = [var.ssh_cidr]
  allow {
    protocol = "tcp"
    ports    = ["22"] # the Kubernetes API is reached through an SSH tunnel, never exposed
  }
}

resource "google_compute_instance" "bench" {
  name         = "llm-bench-l4"
  machine_type = "g2-standard-12" # the L4 comes with the machine type
  zone         = var.zone
  labels       = { purpose = "llm-bench" }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 200 # two vLLM images, the GPU Operator stack, 16 GB of BF16 weights
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.bench.id
    access_config {} # public IP for SSH and image/model pulls
  }

  scheduling {
    provisioning_model          = var.spot ? "SPOT" : "STANDARD"
    preemptible                 = var.spot
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE" # required with a GPU
    instance_termination_action = "DELETE"
    max_run_duration { seconds = var.max_hours * 3600 }
  }

  shielded_instance_config {
    enable_secure_boot = false # the GPU Operator builds an unsigned driver module
  }

  metadata = {
    startup-script = file("${path.module}/startup.sh")
  }
}

# Billing data lags by hours, so this is a backstop for a forgotten project,
# not a session limit. max_run_duration above is the real cap.
resource "google_billing_budget" "bench" {
  billing_account = var.billing_account
  display_name    = "llm-bench"
  budget_filter { projects = ["projects/${var.project}"] }
  amount {
    specified_amount {
      currency_code = "USD"
      units         = "30"
    }
  }
  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 1.0 }
  depends_on = [google_project_service.budgets]
}

output "name" { value = google_compute_instance.bench.name }
output "zone" { value = google_compute_instance.bench.zone }

variable "aws_region" {
  description = "AWS Region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "openclaw-mt"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.2.0.0/16"
}

variable "slot_count" {
  description = "Number of pre-provisioned OpenClaw instances (warm pool)"
  type        = number
  default     = 3
}

variable "openclaw_image" {
  description = "OpenClaw Docker image"
  type        = string
  default     = "ghcr.io/openclaw/openclaw:latest"
}

variable "openclaw_cpu" {
  description = "CPU units per OpenClaw task (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "openclaw_memory" {
  description = "Memory in MB per OpenClaw task"
  type        = number
  default     = 2048
}

variable "admin_password" {
  description = "Admin password for Provisioning Service"
  type        = string
  sensitive   = true
}

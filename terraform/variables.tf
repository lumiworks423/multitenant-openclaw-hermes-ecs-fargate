variable "aws_region" {
  description = "AWS Region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "mt-openclaw-hermes-ecs"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.2.0.0/16"
}

variable "slot_count" {
  description = "Number of pre-provisioned OpenClaw instances (warm pool)"
  type        = number
  default     = 2
}

variable "openclaw_image" {
  description = "OpenClaw Docker image (pinned to verified working version)"
  type        = string
  default     = "ghcr.io/openclaw/openclaw:2026.4.21"
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

variable "hermes_image" {
  description = "Hermes Agent Docker image (pinned to verified working version)"
  type        = string
  default     = "nousresearch/hermes-agent:v2026.4.23"
}

variable "hermes_cpu" {
  description = "CPU units per Hermes task (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "hermes_memory" {
  description = "Memory in MB per Hermes task"
  type        = number
  default     = 2048
}

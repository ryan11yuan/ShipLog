variable "subscription_id" {
  description = "Azure subscription to deploy into (kept in terraform.tfvars, never committed)"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "canadacentral"
}

variable "env" {
  description = "Environment name, used in resource names and tags"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag: who to ask about these resources"
  type        = string
}

variable "alert_email" {
  description = "Where the 5xx alert is emailed"
  type        = string
}

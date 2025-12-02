variable "aws_region" { default = "us-east-1" }
variable "cluster_name" { default = "codeblaze-eks" }
variable "cluster_version" { default = "1.29" }
variable "db_username" {}
variable "db_password" {}
variable "vpc_cidr" { default = "10.0.0.0/16" }
variable "public_subnets" { default = ["10.0.101.0/24","10.0.102.0/24","10.0.103.0/24"] }
variable "private_subnets" { default = ["10.0.1.0/24","10.0.2.0/24","10.0.3.0/24"] }
variable "vault_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access Vault (optional)"
  default     = []
}

variable "admin_cidr" {
  type        = string
  description = "Your IP for SSH access to Vault EC2"
  default     = ""
}
variable "ami_for_vault" {
  description = "AMI ID for Vault EC2 instance"
  type        = string
}

variable "vault_instance_type" {
  description = "Instance type for the Vault EC2 server"
  type        = string
  default     = "t3.micro"
}

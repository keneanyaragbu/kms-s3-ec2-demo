variable "ssh_public_key" {
  description = "SSH public key for EC2 access"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "Your IP in CIDR notation"
  type        = string
}

variable "GOOGLE_API_KEY" {
  type      = string
  sensitive = true
}

variable "rds_password" {
  type = string
}

variable "stats_username" {
  type    = string
  default = "bmlt"
}

variable "stats_password" {
  type      = string
  sensitive = true
}

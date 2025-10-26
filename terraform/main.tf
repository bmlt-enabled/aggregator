terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    bucket       = "mvana-account-terraform"
    key          = "aggregator/state.json"
    use_lockfile = true
    region       = "us-east-1"
    profile      = "mvana"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "mvana"
}

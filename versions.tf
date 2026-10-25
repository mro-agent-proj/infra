terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # bucket은 bootstrap/에서 만든 이름으로 바꿉니다. 잠금은 S3 lockfile(Terraform 1.10+)을 씁니다.
  backend "s3" {
    bucket       = "mro-agent-tfstate-REPLACE_ME"
    key          = "prod/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

# CloudFront 인증서는 us-east-1에서만 발급할 수 있습니다.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}

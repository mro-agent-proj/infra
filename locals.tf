data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "mro-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # CloudFront → ALB 구간에 쓰는 호스트. ALB 인증서와 이름이 맞아야 HTTPS로 붙습니다.
  origin_domain = "origin.${var.domain_name}"

  # 서비스 수. services_enabled=false면 전부 0
  desired = var.services_enabled ? 1 : 0

  tags = {
    Project     = "mro-agent"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

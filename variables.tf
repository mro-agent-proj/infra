variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "environment" {
  description = "dev 또는 prod. prod면 RDS 삭제 보호를 켭니다."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment는 dev 또는 prod여야 합니다."
  }
}

variable "hosted_zone_name" {
  description = "Route 53에 이미 있는 호스팅 영역. 예: example.com"
  type        = string
}

variable "domain_name" {
  description = "서비스 주소. 예: mro.example.com"
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "image_tag" {
  description = "ECR에 올린 이미지 태그 (보통 git 커밋 SHA). 새 버전 배포 = 이 값을 바꿔 apply."
  type        = string
  default     = "latest"
}

variable "services_enabled" {
  description = "false면 ECS 서비스를 0개로 둡니다. 최초 DB 초기화 전이나 비용을 아낄 때 씁니다."
  type        = bool
  default     = true
}

variable "llm_model" {
  description = "ai/app/main.py SUPPORTED_MODELS 중 하나"
  type        = string
  default     = "gpt-5.4-mini"
}

variable "db_instance_class" {
  description = "pgvector 인덱스를 메모리에 올리려면 small 이상을 권장합니다."
  type        = string
  default     = "db.t4g.small"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "mq_instance_type" {
  type    = string
  default = "mq.t3.micro"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "dockerhub_secret_name" {
  description = "ECR pull-through cache용 Docker Hub 자격 증명 비밀 ({\"username\",\"accessToken\"})"
  type        = string
  default     = "ecr-pullthroughcache/docker-hub"
}

variable "prometheus_image" {
  description = "Docker Hub 이미지 이름:태그 (pull-through cache로 받음)"
  type        = string
  default     = "prom/prometheus:v3.5.0"
}

variable "grafana_image" {
  description = "Docker Hub 이미지 이름:태그 (pull-through cache로 받음)"
  type        = string
  default     = "grafana/grafana-oss:12.1.0"
}

variable "prometheus_retention" {
  type    = string
  default = "15d"
}

variable "prometheus_scrape_targets" {
  description = <<-EOT
    수집 대상 (job 이름 => Service Connect 주소·경로). 앱에 메트릭 엔드포인트가 생긴 뒤 추가합니다.
    예: backend = { address = "backend:8080", metrics_path = "/actuator/prometheus" }
  EOT
  type = map(object({
    address      = string
    metrics_path = string
  }))
  default = {}
}

variable "github_repository" {
  description = "이미지·프론트 배포 역할을 assume할 GitHub 저장소 (owner/name)"
  type        = string
  default     = "mro-agent-proj/mro-agent-integration"
}

variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  type = string
}

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "desired_count" {
  type = number
}

variable "container_port" {
  type = number
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "환경변수 이름 => Secrets Manager valueFrom (ARN 또는 <ARN>:<JSON 키>::)"
  type        = map(string)
  default     = {}
}

variable "health_check_command" {
  description = "컨테이너 헬스체크. null이면 생략 (ALB 헬스체크만 사용)"
  type        = list(string)
  default     = null
}

variable "stop_timeout" {
  type    = number
  default = 30
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "service_connect_namespace_arn" {
  type = string
}

variable "service_connect_alias" {
  description = "다른 서비스가 부를 DNS 이름. null이면 클라이언트로만 참여"
  type        = string
  default     = null
}

variable "target_group_arn" {
  type    = string
  default = null
}

variable "efs" {
  type = object({
    file_system_id  = string
    access_point_id = string
    container_path  = string
  })
  default = null
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "log_retention_days" {
  type    = number
  default = 14
}

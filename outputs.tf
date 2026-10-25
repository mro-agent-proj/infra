output "app_url" {
  value = "https://${var.domain_name}"
}

output "grafana_url" {
  description = "로그인: admin / Secrets Manager <name>/app 의 grafana_admin_password"
  value       = "https://${var.domain_name}/grafana/"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.bucket
}

output "rag_data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "openai_secret_id" {
  description = "apply 뒤 put-secret-value로 OpenAI 키를 채울 비밀"
  value       = aws_secretsmanager_secret.openai.name
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

# 1회성 작업 실행에 쓰는 네트워크 설정
output "run_task_network_configuration" {
  value = "awsvpcConfiguration={subnets=[${join(",", aws_subnet.private[*].id)}],securityGroups=[${aws_security_group.ops.id}],assignPublicIp=DISABLED}"
}

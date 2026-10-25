# 앱 비밀값은 JSON 하나에 모읍니다. ECS는 "<arn>:<키>::"로 키 하나씩 꺼내 환경변수로 넣습니다.
# 값은 random_password로 만들므로 state에 남습니다. state 버킷은 암호화·비공개입니다.
resource "random_password" "app" {
  for_each = toset([
    "jwt_secret",
    "mcp_business_jwt_secret",
    "mcp_rag_jwt_secret",
    "rag_cursor_secret",
    "rag_reader_password",
    "business_reader_password",
    "origin_verify",
    "grafana_admin_password",
    "app_db_password",
  ])
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.name}/app"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    jwt_secret               = random_password.app["jwt_secret"].result
    mcp_business_jwt_secret  = random_password.app["mcp_business_jwt_secret"].result
    mcp_rag_jwt_secret       = random_password.app["mcp_rag_jwt_secret"].result
    rag_cursor_secret        = random_password.app["rag_cursor_secret"].result
    rag_reader_password      = random_password.app["rag_reader_password"].result
    business_reader_password = random_password.app["business_reader_password"].result
    rabbitmq_password        = random_password.rabbitmq.result
    grafana_admin_password   = random_password.app["grafana_admin_password"].result
    app_db_password          = random_password.app["app_db_password"].result

    # MCP와 AI는 비밀번호가 들어간 접속 URL 하나를 받습니다.
    # RDS PostgreSQL 16은 SSL을 강제(rds.force_ssl=1)하므로 asyncpg에 명시합니다.
    rag_database_url      = "postgresql+asyncpg://mro_reader:${random_password.app["rag_reader_password"].result}@${aws_db_instance.main.address}:5432/mro?ssl=require"
    business_database_url = "postgresql+asyncpg://mro_business_reader:${random_password.app["business_reader_password"].result}@${aws_db_instance.main.address}:5432/mro?ssl=require"
    # ai/app/config.py 기본값과 같은 형식 (끝의 / = 기본 vhost)
    rabbitmq_url = "amqps://mro:${random_password.rabbitmq.result}@${local.mq_host}:5671/"
  })
}

# OpenAI 키는 Terraform에 넣지 않습니다. apply 뒤 한 번 채웁니다:
#   aws secretsmanager put-secret-value --secret-id mro-prod/openai-api-key --secret-string 'sk-...'
resource "aws_secretsmanager_secret" "openai" {
  name                    = "${local.name}/openai-api-key"
  recovery_window_in_days = 7
}

locals {
  app_secret = aws_secretsmanager_secret.app.arn
  secret = {
    for k in [
      "jwt_secret", "mcp_business_jwt_secret", "mcp_rag_jwt_secret", "rag_cursor_secret",
      "rag_reader_password", "business_reader_password", "rabbitmq_password",
      "rag_database_url", "business_database_url", "rabbitmq_url", "grafana_admin_password",
      "app_db_password",
    ] : k => "${local.app_secret}:${k}::"
  }
  db_master_password = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
  openai_api_key     = aws_secretsmanager_secret.openai.arn
}

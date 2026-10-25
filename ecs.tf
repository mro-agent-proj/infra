# 로컬 scripts/up.sh 의 네 서비스를 Fargate로 옮긴 것입니다.
# 환경변수는 각 레포의 compose 파일·.env.example과 같은 이름을 씁니다.
resource "aws_ecs_cluster" "main" {
  name = local.name

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.main.arn
  }
}

resource "aws_service_discovery_http_namespace" "main" {
  name = "${local.name}.local"
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(["backend", "ai", "business-mcp", "rag-mcp", "rag-restore"])
  name                 = "mro/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 이미지 20개만 보관"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

locals {
  image = { for k, r in aws_ecr_repository.app : k => "${r.repository_url}:${var.image_tag}" }

  service_defaults = {
    cluster_name                  = aws_ecs_cluster.main.name
    cluster_arn                   = aws_ecs_cluster.main.arn
    region                        = var.region
    subnet_ids                    = aws_subnet.private[*].id
    execution_role_arn            = aws_iam_role.execution.arn
    service_connect_namespace_arn = aws_service_discovery_http_namespace.main.arn
    log_retention_days            = var.log_retention_days
  }
}

# ---------- backend (Spring Boot, :8080) ----------
module "backend" {
  source = "./modules/ecs-service"

  name           = "backend"
  image          = local.image["backend"]
  cpu            = 1024
  memory         = 2048
  desired_count  = local.desired
  container_port = 8080

  environment = {
    AI_MODE                     = "rabbit"
    DB_URL                      = "jdbc:postgresql://${aws_db_instance.main.address}:5432/mro"
    DB_USERNAME                 = aws_db_instance.main.username
    RABBITMQ_HOST               = local.mq_host
    RABBITMQ_PORT               = "5671"
    RABBITMQ_USERNAME           = "mro"
    SPRING_RABBITMQ_SSL_ENABLED = "true"
    SEED_DIR                    = "/app/seed"
    CORS_ORIGINS                = "https://${var.domain_name}"
  }
  secrets = {
    DB_PASSWORD             = local.db_master_password
    RABBITMQ_PASSWORD       = local.secret["rabbitmq_password"]
    JWT_SECRET              = local.secret["jwt_secret"]
    MCP_BUSINESS_JWT_SECRET = local.secret["mcp_business_jwt_secret"]
    MCP_RAG_JWT_SECRET      = local.secret["mcp_rag_jwt_secret"]
  }

  health_check_command = ["CMD-SHELL", "curl -fsS http://localhost:8080/actuator/health || exit 1"]
  target_group_arn     = aws_lb_target_group.backend.arn
  security_group_ids   = [aws_security_group.backend.id]
  task_role_arn        = aws_iam_role.task.arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days

  depends_on = [aws_lb_listener.https]
}

# ---------- business-mcp (:8101, 업무 DB 읽기 전용) ----------
module "business_mcp" {
  source = "./modules/ecs-service"

  name                  = "business-mcp"
  image                 = local.image["business-mcp"]
  cpu                   = 256
  memory                = 512
  desired_count         = local.desired
  container_port        = 8101
  service_connect_alias = "business-mcp"

  environment = {
    BUSINESS_ALLOWED_HOSTS  = "127.0.0.1:*,localhost:*,business-mcp:*"
    BUSINESS_SOURCE_VERSION = "backend-seed"
  }
  secrets = {
    BUSINESS_DATABASE_URL = local.secret["business_database_url"]
    BUSINESS_JWT_SECRET   = local.secret["mcp_business_jwt_secret"]
  }

  # mcp/docker/business-mcp.Dockerfile HEALTHCHECK와 같음 (ECS는 이미지의 HEALTHCHECK를 쓰지 않습니다)
  health_check_command = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8101/health/ready', timeout=2)"]
  security_group_ids   = [aws_security_group.mcp.id]
  task_role_arn        = aws_iam_role.task.arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days
}

# ---------- rag-mcp (:8102, RAG 검색 읽기 전용) ----------
module "rag_mcp" {
  source = "./modules/ecs-service"

  name                  = "rag-mcp"
  image                 = local.image["rag-mcp"]
  cpu                   = 256
  memory                = 512
  desired_count         = local.desired
  container_port        = 8102
  service_connect_alias = "rag-mcp"

  environment = {
    RAG_ALLOWED_HOSTS = "127.0.0.1:*,localhost:*,rag-mcp:*"
  }
  secrets = {
    RAG_DATABASE_URL   = local.secret["rag_database_url"]
    RAG_JWT_SECRET     = local.secret["mcp_rag_jwt_secret"]
    RAG_CURSOR_SECRET  = local.secret["rag_cursor_secret"]
    RAG_OPENAI_API_KEY = local.openai_api_key
  }

  health_check_command = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8102/health/ready', timeout=2)"]
  security_group_ids   = [aws_security_group.mcp.id]
  task_role_arn        = aws_iam_role.task.arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days
}

# ---------- ai (LangGraph 워커, RabbitMQ 소비자) ----------
# 실행 기록이 SQLite(EFS)라 항상 1개만 돌립니다. 배포 때도 새 태스크가 뜨기 전에 기존 것을 내립니다.
module "ai" {
  source = "./modules/ecs-service"

  name           = "ai"
  image          = local.image["ai"]
  cpu            = 512
  memory         = 1024
  desired_count  = local.desired
  container_port = 8100
  stop_timeout   = 30

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  environment = {
    AI_MODE                  = "rabbit"
    LLM_PROVIDER             = "openai"
    LLM_MODEL                = var.llm_model
    BUSINESS_MCP_URL         = "http://business-mcp:8101/mcp"
    RAG_MCP_URL              = "http://rag-mcp:8102/mcp"
    MCP_DELEGATION_TRANSPORT = "amqp_headers"
    STATE_DIR                = "/data"
    RUN_JOURNAL_PATH         = "/data/run-journal.sqlite"
    RUN_TIMEOUT_SECONDS      = "280"
    TOOL_TIMEOUT_SECONDS     = "10"
    TOOL_RETRIES             = "1"
    MODEL_TIMEOUT_SECONDS    = "45"
    MAX_TOOL_CALLS           = "8"
    MAX_REINVESTIGATION      = "2"
  }
  secrets = {
    LLM_API_KEY  = local.openai_api_key
    RABBITMQ_URL = local.secret["rabbitmq_url"]
  }

  efs = {
    file_system_id  = aws_efs_file_system.ai_state.id
    access_point_id = aws_efs_access_point.ai_state.id
    container_path  = "/data"
  }

  # /health/ready는 RabbitMQ 큐에 붙은 뒤에만 200입니다 (ai/app/main.py).
  health_check_command = ["CMD", "/service/.venv/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8100/health/ready', timeout=2)"]
  security_group_ids   = [aws_security_group.ai.id]
  task_role_arn        = aws_iam_role.ai_task.arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days

  # MCP가 Service Connect에 먼저 등록돼야 ai가 이름을 찾습니다.
  depends_on = [aws_efs_mount_target.ai_state, module.business_mcp, module.rag_mcp]
}

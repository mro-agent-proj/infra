# 서비스가 아닌 1회성 작업. `aws ecs run-task`로 실행합니다 (README 참고).
#   db-init     : MCP 조회 전용 계정 생성 (로컬 docker/postgres/init/01-readers.sh 대체, backend 첫 기동 전)
#   rag-restore : RAG 전달본을 S3에서 받아 backend/scripts/restore-data.sh 실행 (backend의 Flyway 이후)

# Release data-2026-10-22 첨부파일을 그대로 올려 두는 버킷
resource "aws_s3_bucket" "data" {
  bucket = "${local.name}-rag-data-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudwatch_log_group" "ops" {
  name              = "/ecs/${local.name}/ops"
  retention_in_days = var.log_retention_days
}

locals {
  ops_log = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.ops.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "ops"
    }
  }

  pg_env = [
    { name = "PGHOST", value = aws_db_instance.main.address },
    { name = "PGUSER", value = aws_db_instance.main.username },
    { name = "PGDATABASE", value = "mro" },
    { name = "PGSSLMODE", value = "require" },
  ]

  # 여러 번 실행해도 안전합니다. 권한(GRANT)은 backend Flyway V4가 부여합니다.
  # V4는 계정이 없으면 NOLOGIN으로 만들기 때문에, backend가 먼저 떴어도 여기서 LOGIN을 줍니다.
  db_init_sql = <<-SQL
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mro_reader') THEN
        CREATE ROLE mro_reader NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'mro_business_reader') THEN
        CREATE ROLE mro_business_reader NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
    END $$;
    ALTER ROLE mro_reader LOGIN PASSWORD :'rag_password';
    ALTER ROLE mro_business_reader LOGIN PASSWORD :'business_password';
  SQL
}

resource "aws_ecs_task_definition" "db_init" {
  family                   = "${local.name}-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "db-init"
    image     = "${local.dockerhub}/library/postgres:16-alpine"
    essential = true
    command = ["sh", "-c", join(" ", [
      "printf '%s\\n' \"$INIT_SQL\" |",
      "psql -v ON_ERROR_STOP=1",
      "-v rag_password=\"$RAG_READER_PASSWORD\"",
      "-v business_password=\"$BUSINESS_READER_PASSWORD\"",
    ])]
    environment = concat(local.pg_env, [{ name = "INIT_SQL", value = local.db_init_sql }])
    secrets = [
      { name = "PGPASSWORD", valueFrom = local.db_master_password },
      { name = "RAG_READER_PASSWORD", valueFrom = local.secret["rag_reader_password"] },
      { name = "BUSINESS_READER_PASSWORD", valueFrom = local.secret["business_reader_password"] },
    ]
    logConfiguration = local.ops_log
  }])
}

# 이미지: infra/ops/rag-restore.Dockerfile (backend 스크립트·마이그레이션 + psql + aws cli)
resource "aws_ecs_task_definition" "rag_restore" {
  family                   = "${local.name}-rag-restore"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 4096
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.ops_task.arn

  # 전달본 tar(약 380MB)를 풀 공간
  ephemeral_storage {
    size_in_gib = 30
  }

  container_definitions = jsonencode([{
    name      = "rag-restore"
    image     = local.image["rag-restore"]
    essential = true
    environment = concat(local.pg_env, [
      { name = "RAG_RESTORE_DIRECT", value = "1" },
      { name = "DATA_BUCKET", value = aws_s3_bucket.data.bucket },
      { name = "DATA_PREFIX", value = "data-2026-10-22" },
    ])
    secrets = [
      { name = "PGPASSWORD", valueFrom = local.db_master_password },
    ]
    logConfiguration = local.ops_log
  }])
}

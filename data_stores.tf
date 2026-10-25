# ---------- PostgreSQL (업무 + RAG, pgvector) ----------
# 마스터 비밀번호는 RDS가 만들어 Secrets Manager에 둡니다 (코드·state에 값이 남지 않음).
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = 30
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "mro"
  username                    = "mro"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = var.environment == "prod"
  skip_final_snapshot        = var.environment != "prod"
  final_snapshot_identifier  = "${local.name}-postgres-final"
}

# ---------- RabbitMQ (Amazon MQ) ----------
# 로컬 compose의 rabbitmq:4.1과 같은 AMQP 0-9-1. Amazon MQ는 TLS(5671)만 엽니다.
resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "aws_mq_broker" "rabbitmq" {
  broker_name                = "${local.name}-rabbitmq"
  engine_type                = "RabbitMQ"
  engine_version             = "3.13"
  host_instance_type         = var.mq_instance_type
  deployment_mode            = "SINGLE_INSTANCE"
  auto_minor_version_upgrade = true
  publicly_accessible        = false
  subnet_ids                 = [aws_subnet.private[0].id]
  security_groups            = [aws_security_group.mq.id]

  user {
    username = "mro"
    password = random_password.rabbitmq.result
  }

  logs {
    general = true
  }
}

locals {
  # endpoints[0] = "amqps://<broker-id>.mq.<region>.<domain>:5671"
  mq_host = regex("^amqps://([^:/]+)", aws_mq_broker.rabbitmq.instances[0].endpoints[0])[0]
}

# ---------- EFS (AI 실행 기록·체크포인트 SQLite) ----------
# ai/compose.yaml의 ai-state 볼륨에 해당합니다. 태스크가 바뀌어도 /data가 유지돼야 합니다.
resource "aws_efs_file_system" "ai_state" {
  creation_token = "${local.name}-ai-state"
  encrypted      = true
  tags           = { Name = "${local.name}-ai-state" }
}

resource "aws_efs_mount_target" "ai_state" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.ai_state.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# ai 이미지의 worker 사용자(uid 10001)로 /ai-state 디렉터리를 씁니다.
resource "aws_efs_access_point" "ai_state" {
  file_system_id = aws_efs_file_system.ai_state.id
  posix_user {
    uid = 10001
    gid = 10001
  }
  root_directory {
    path = "/ai-state"
    creation_info {
      owner_uid   = 10001
      owner_gid   = 10001
      permissions = "0750"
    }
  }
}

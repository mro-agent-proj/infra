# 통신 경로
#   CloudFront ─443─▶ ALB ─8080─▶ backend
#   ai ─8101/8102─▶ business-mcp / rag-mcp
#   backend·mcp·ops ─5432─▶ RDS,  backend·ai ─5671─▶ Amazon MQ,  ai ─2049─▶ EFS
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB: CloudFront origin-facing only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "backend" {
  name        = "${local.name}-backend"
  description = "Spring Boot backend"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "ai" {
  name        = "${local.name}-ai"
  description = "AI worker (RabbitMQ consumer, no inbound)"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "mcp" {
  name        = "${local.name}-mcp"
  description = "business-mcp and rag-mcp"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "ops" {
  name        = "${local.name}-ops"
  description = "One-off ECS tasks (db-init, rag-restore)"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "PostgreSQL"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "mq" {
  name        = "${local.name}-mq"
  description = "Amazon MQ RabbitMQ"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "EFS for AI state"
  vpc_id      = aws_vpc.main.id
}

# 모든 그룹의 아웃바운드는 열어 둡니다 (OpenAI API, ECR, Secrets Manager 등).
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    alb     = aws_security_group.alb.id
    backend = aws_security_group.backend.id
    ai      = aws_security_group.ai.id
    mcp     = aws_security_group.mcp.id
    ops     = aws_security_group.ops.id
  }
  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "mcp_from_ai" {
  for_each                     = { business = 8101, rag = 8102 }
  security_group_id            = aws_security_group.mcp.id
  referenced_security_group_id = aws_security_group.ai.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each = {
    backend = aws_security_group.backend.id
    mcp     = aws_security_group.mcp.id
    ops     = aws_security_group.ops.id
  }
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "mq" {
  for_each = {
    backend = aws_security_group.backend.id
    ai      = aws_security_group.ai.id
  }
  security_group_id            = aws_security_group.mq.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_ai" {
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = aws_security_group.ai.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

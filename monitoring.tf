# Prometheus + Grafana (같은 ECS 클러스터, private subnet)
#
#   CloudFront /grafana* ─▶ ALB ─▶ grafana :3000 ─┬─▶ prometheus:9090 (Service Connect)
#                                                  └─▶ CloudWatch (ECS·RDS·MQ·ALB 지표, 태스크 역할로 조회)
#   prometheus ──scrape──▶ var.prometheus_scrape_targets (backend:8080 등)
#
# 앱들은 아직 /metrics를 내보내지 않습니다. 각 레포에 메트릭이 추가되면 scrape 대상만 tfvars에 넣습니다.
# Prometheus는 외부에 노출하지 않습니다.

# ---------- 네트워크 ----------
resource "aws_security_group" "prometheus" {
  name        = "${local.name}-prometheus"
  description = "Prometheus (scrapes app services)"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "grafana" {
  name        = "${local.name}-grafana"
  description = "Grafana behind ALB"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "monitoring_efs" {
  name        = "${local.name}-monitoring-efs"
  description = "EFS for Prometheus TSDB and Grafana data"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "monitoring" {
  for_each = {
    prometheus = aws_security_group.prometheus.id
    grafana    = aws_security_group.grafana.id
  }
  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "grafana_from_alb" {
  security_group_id            = aws_security_group.grafana.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_ingress_rule" "prometheus_from_grafana" {
  security_group_id            = aws_security_group.prometheus.id
  referenced_security_group_id = aws_security_group.grafana.id
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090
}

# Prometheus → 각 서비스의 HTTP 포트 (메트릭 수집)
resource "aws_vpc_security_group_ingress_rule" "scrape" {
  for_each = {
    backend      = { sg = aws_security_group.backend.id, port = 8080 }
    ai           = { sg = aws_security_group.ai.id, port = 8100 }
    business-mcp = { sg = aws_security_group.mcp.id, port = 8101 }
    rag-mcp      = { sg = aws_security_group.mcp.id, port = 8102 }
  }
  security_group_id            = each.value.sg
  referenced_security_group_id = aws_security_group.prometheus.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_efs" {
  for_each = {
    prometheus = aws_security_group.prometheus.id
    grafana    = aws_security_group.grafana.id
  }
  security_group_id            = aws_security_group.monitoring_efs.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

# ---------- 저장소 (EFS) ----------
# 둘 다 단일 인스턴스로 돌리고 배포 때도 기존 태스크를 먼저 내립니다 (TSDB·SQLite 잠금).
resource "aws_efs_file_system" "monitoring" {
  creation_token = "${local.name}-monitoring"
  encrypted      = true
  tags           = { Name = "${local.name}-monitoring" }
}

resource "aws_efs_mount_target" "monitoring" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.monitoring.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.monitoring_efs.id]
}

# uid: prom/prometheus = nobody(65534), grafana = 472
resource "aws_efs_access_point" "monitoring" {
  for_each = {
    prometheus = { path = "/prometheus", uid = 65534 }
    grafana    = { path = "/grafana", uid = 472 }
  }
  file_system_id = aws_efs_file_system.monitoring.id
  posix_user {
    uid = each.value.uid
    gid = each.value.uid
  }
  root_directory {
    path = each.value.path
    creation_info {
      owner_uid   = each.value.uid
      owner_gid   = each.value.uid
      permissions = "0750"
    }
  }
}

# ---------- IAM ----------
data "aws_iam_policy_document" "monitoring_efs" {
  for_each                = aws_efs_access_point.monitoring
  source_policy_documents = [data.aws_iam_policy_document.ecs_exec.json]
  statement {
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.monitoring.arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [each.value.arn]
    }
  }
}

resource "aws_iam_role" "monitoring_task" {
  for_each           = aws_efs_access_point.monitoring
  name               = "${local.name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "monitoring_efs" {
  for_each = aws_iam_role.monitoring_task
  name     = "efs-and-exec"
  role     = each.value.id
  policy   = data.aws_iam_policy_document.monitoring_efs[each.key].json
}

# Grafana CloudWatch 데이터소스가 요구하는 읽기 권한 (Grafana 문서의 최소 정책)
data "aws_iam_policy_document" "grafana_cloudwatch" {
  statement {
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name   = "cloudwatch-read"
  role   = aws_iam_role.monitoring_task["grafana"].id
  policy = data.aws_iam_policy_document.grafana_cloudwatch.json
}

# ---------- 설정 파일 ----------
# Fargate에는 설정 파일을 마운트할 수 없어서, YAML을 환경변수로 넘기고 시작할 때 /tmp에 씁니다.
locals {
  prometheus_config = yamlencode({
    global = {
      scrape_interval     = "30s"
      evaluation_interval = "30s"
    }
    scrape_configs = concat(
      [{ job_name = "prometheus", static_configs = [{ targets = ["localhost:9090"] }] }],
      [for job, t in var.prometheus_scrape_targets : {
        job_name       = job
        metrics_path   = t.metrics_path
        static_configs = [{ targets = [t.address], labels = { environment = var.environment } }]
      }],
    )
  })

  grafana_datasources = yamlencode({
    apiVersion = 1
    datasources = [
      {
        name      = "Prometheus"
        uid       = "prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://prometheus:9090"
        isDefault = true
      },
      {
        name     = "CloudWatch"
        uid      = "cloudwatch"
        type     = "cloudwatch"
        jsonData = { authType = "default", defaultRegion = var.region }
      },
    ]
  })
}

# ---------- Prometheus ----------
module "prometheus" {
  source = "./modules/ecs-service"

  name                  = "prometheus"
  image                 = "${local.dockerhub}/${var.prometheus_image}"
  cpu                   = 256
  memory                = 1024
  desired_count         = local.desired
  container_port        = 9090
  service_connect_alias = "prometheus"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  environment = { PROMETHEUS_CONFIG = local.prometheus_config }
  entry_point = ["/bin/sh", "-c"]
  command = [join(" ", [
    "printf '%s' \"$PROMETHEUS_CONFIG\" > /tmp/prometheus.yml &&",
    "exec /bin/prometheus --config.file=/tmp/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=${var.prometheus_retention}",
  ])]

  efs = {
    file_system_id  = aws_efs_file_system.monitoring.id
    access_point_id = aws_efs_access_point.monitoring["prometheus"].id
    container_path  = "/prometheus"
  }

  health_check_command = ["CMD-SHELL", "wget -qO- http://localhost:9090/-/ready || exit 1"]
  security_group_ids   = [aws_security_group.prometheus.id]
  task_role_arn        = aws_iam_role.monitoring_task["prometheus"].arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days

  depends_on = [aws_efs_mount_target.monitoring]
}

# ---------- Grafana (https://<domain>/grafana/) ----------
resource "aws_lb_target_group" "grafana" {
  name                 = "${local.name}-grafana"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/grafana/api/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 5

  condition {
    path_pattern {
      values = ["/grafana", "/grafana/*"]
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.app["origin_verify"].result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

module "grafana" {
  source = "./modules/ecs-service"

  name           = "grafana"
  image          = "${local.dockerhub}/${var.grafana_image}"
  cpu            = 256
  memory         = 512
  desired_count  = local.desired
  container_port = 3000

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  environment = {
    GF_SERVER_ROOT_URL             = "https://${var.domain_name}/grafana/"
    GF_SERVER_SERVE_FROM_SUB_PATH  = "true"
    GF_SECURITY_ADMIN_USER         = "admin"
    GF_AUTH_ANONYMOUS_ENABLED      = "false"
    GF_USERS_ALLOW_SIGN_UP         = "false"
    GF_ANALYTICS_REPORTING_ENABLED = "false"
    GF_PATHS_PROVISIONING          = "/tmp/provisioning"
    GRAFANA_DATASOURCES            = local.grafana_datasources
  }
  secrets = {
    GF_SECURITY_ADMIN_PASSWORD = local.secret["grafana_admin_password"]
  }
  entry_point = ["/bin/sh", "-c"]
  command = [join(" ", [
    "mkdir -p /tmp/provisioning/datasources /tmp/provisioning/dashboards /tmp/provisioning/plugins /tmp/provisioning/alerting &&",
    "printf '%s' \"$GRAFANA_DATASOURCES\" > /tmp/provisioning/datasources/datasources.yaml &&",
    "exec /run.sh",
  ])]

  efs = {
    file_system_id  = aws_efs_file_system.monitoring.id
    access_point_id = aws_efs_access_point.monitoring["grafana"].id
    container_path  = "/var/lib/grafana"
  }

  target_group_arn   = aws_lb_target_group.grafana.arn
  security_group_ids = [aws_security_group.grafana.id]
  task_role_arn      = aws_iam_role.monitoring_task["grafana"].arn

  cluster_name                  = local.service_defaults.cluster_name
  cluster_arn                   = local.service_defaults.cluster_arn
  region                        = local.service_defaults.region
  subnet_ids                    = local.service_defaults.subnet_ids
  execution_role_arn            = local.service_defaults.execution_role_arn
  service_connect_namespace_arn = local.service_defaults.service_connect_namespace_arn
  log_retention_days            = local.service_defaults.log_retention_days

  depends_on = [aws_efs_mount_target.monitoring, aws_lb_listener_rule.grafana]
}

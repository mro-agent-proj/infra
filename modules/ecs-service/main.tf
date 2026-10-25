# Fargate 서비스 하나 = 태스크 정의 + 서비스 + 로그 그룹.
# Service Connect로 다른 서비스를 "http://<alias>:<port>"로 부르고, alias가 있으면 자신도 그 이름으로 노출합니다.
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.cluster_name}/${var.name}"
  retention_in_days = var.log_retention_days
}

locals {
  container = merge(
    {
      name         = var.name
      image        = var.image
      essential    = true
      stopTimeout  = var.stop_timeout
      portMappings = [{ name = "http", containerPort = var.container_port, protocol = "tcp", appProtocol = "http" }]
      environment  = [for k, v in var.environment : { name = k, value = v }]
      secrets      = [for k, v in var.secrets : { name = k, valueFrom = v }]
      mountPoints  = var.efs == null ? [] : [{ sourceVolume = "state", containerPath = var.efs.container_path, readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = var.name
        }
      }
    },
    var.health_check_command == null ? {} : {
      healthCheck = {
        command     = var.health_check_command
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }
    },
  )
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.cluster_name}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  container_definitions    = jsonencode([local.container])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "volume" {
    for_each = var.efs == null ? [] : [var.efs]
    content {
      name = "state"
      efs_volume_configuration {
        file_system_id     = volume.value.file_system_id
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }
}

resource "aws_ecs_service" "this" {
  name                   = var.name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true
  propagate_tags         = "SERVICE"

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.target_group_arn == null ? null : 90

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]
    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    dynamic "service" {
      for_each = var.service_connect_alias == null ? [] : [var.service_connect_alias]
      content {
        port_name      = "http"
        discovery_name = var.name
        client_alias {
          dns_name = service.value
          port     = var.container_port
        }
      }
    }
  }
}

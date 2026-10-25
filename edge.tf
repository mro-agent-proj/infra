# 사용자 ─▶ CloudFront ─┬─ /*            ─▶ S3 (dashboard 빌드)
#                       ├─ /api/*, /actuator/health ─▶ ALB ─▶ backend
#                       └─ /grafana*                ─▶ ALB ─▶ grafana (monitoring.tf)
# 프론트와 API가 같은 도메인이라 CORS·별도 리버스 프록시가 필요 없습니다.

data "aws_route53_zone" "main" {
  name = var.hosted_zone_name
}

# ---------- 인증서 ----------
resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "origin" {
  domain_name       = local.origin_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

locals {
  cert_validations = merge(
    { for o in aws_acm_certificate.cloudfront.domain_validation_options : o.domain_name => o },
    { for o in aws_acm_certificate.origin.domain_validation_options : o.domain_name => o },
  )
}

resource "aws_route53_record" "cert_validation" {
  for_each        = local.cert_validations
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [aws_route53_record.cert_validation[var.domain_name].fqdn]
}

resource "aws_acm_certificate_validation" "origin" {
  certificate_arn         = aws_acm_certificate.origin.arn
  validation_record_fqdns = [aws_route53_record.cert_validation[local.origin_domain].fqdn]
}

# ---------- ALB ----------
resource "aws_lb" "main" {
  name                       = local.name
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "backend" {
  name                 = "${local.name}-backend"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# CloudFront가 붙이는 비밀 헤더가 있을 때만 backend로 보냅니다. ALB 주소로 직접 오면 403.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.origin.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.app["origin_verify"].result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

# ---------- 프론트 정적 파일 (S3, 비공개) ----------
resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name}-frontend-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket.json
}

# ---------- CloudFront ----------
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Vue Router history 모드: 확장자 없는 경로는 index.html로.
# custom_error_response(403/404 → index.html)는 API 오류까지 바꿔 버려서 쓰지 않습니다.
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${local.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      if (!request.uri.includes('.')) {
        request.uri = '/index.html';
      }
      return request;
    }
  JS
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [var.domain_name]
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  http_version        = "http2and3"
  web_acl_id          = aws_wafv2_web_acl.edge.arn

  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    origin_id   = "backend"
    domain_name = local.origin_domain

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.app["origin_verify"].result
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/api/*", "/actuator/health", "/grafana*"]
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "backend"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ---------- WAF: Grafana 접근 제한 ----------
# Grafana는 관리 화면이라 허용한 IP 대역에서만 엽니다. 나머지 경로(/, /api)는 그대로 통과합니다.
# CloudFront용 WAF는 us-east-1에 만들어야 합니다.
locals {
  grafana_cidrs = {
    IPV4 = [for c in var.grafana_allowed_cidrs : c if !strcontains(c, ":")]
    IPV6 = [for c in var.grafana_allowed_cidrs : c if strcontains(c, ":")]
  }

  # 우선순위 0~2는 Grafana 규칙. 그 뒤로 평판 → 공격 패턴 → 횟수 제한 순서로 평가합니다.
  waf_managed_groups = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 3, count_rules = [] },
    { name = "AWSManagedRulesCommonRuleSet", priority = 4, count_rules = [
      "CrossSiteScripting_BODY", "SizeRestrictions_BODY", "GenericLFI_BODY", "GenericRFI_BODY",
    ] },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 5, count_rules = ["SQLi_BODY", "SQLiExtendedPatterns_BODY"] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 6, count_rules = [] },
  ]

  waf_rate_limits = [
    { name = "rate-limit-auth", priority = 7, limit = var.waf_auth_rate_limit, path_prefix = "/api/v1/auth/" },
    { name = "rate-limit-all", priority = 8, limit = var.waf_rate_limit, path_prefix = null },
  ]
}

resource "aws_wafv2_ip_set" "grafana" {
  for_each           = local.grafana_cidrs
  provider           = aws.us_east_1
  name               = "${local.name}-grafana-${lower(each.key)}"
  scope              = "CLOUDFRONT"
  ip_address_version = each.key
  addresses          = each.value
}

resource "aws_wafv2_web_acl" "edge" {
  provider = aws.us_east_1
  name     = "${local.name}-edge"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 우선순위 0·1: 허용 대역에서 온 /grafana 요청은 통과, 2: 그 밖의 /grafana 요청은 차단
  dynamic "rule" {
    for_each = { IPV4 = 0, IPV6 = 1 }
    content {
      name     = "grafana-allow-${lower(rule.key)}"
      priority = rule.value
      action {
        allow {}
      }
      statement {
        and_statement {
          statement {
            byte_match_statement {
              search_string         = "/grafana"
              positional_constraint = "STARTS_WITH"
              field_to_match {
                uri_path {}
              }
              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
          statement {
            ip_set_reference_statement {
              arn = aws_wafv2_ip_set.grafana[rule.key].arn
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "grafana-allow-${lower(rule.key)}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "grafana-block-others"
    priority = 2
    action {
      block {}
    }
    statement {
      byte_match_statement {
        search_string         = "/grafana"
        positional_constraint = "STARTS_WITH"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "grafana-block-others"
      sampled_requests_enabled   = true
    }
  }

  # ---------- 전체 트래픽 보호 ----------
  # AWS 관리형 규칙 그룹. 정비 신고 본문(symptom_text)은 자유 서술이라 본문 검사 규칙은
  # 오탐을 확인할 때까지 count(기록만)로 둡니다. 로그를 본 뒤 count_rules에서 빼면 차단으로 바뀝니다.
  dynamic "rule" {
    for_each = local.waf_managed_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
          dynamic "rule_action_override" {
            for_each = rule.value.count_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  # 같은 IP의 요청 횟수 제한 (5분 기준). 로그인·가입은 무차별 대입 방지를 위해 따로 낮게 둡니다.
  dynamic "rule" {
    for_each = local.waf_rate_limits
    content {
      name     = rule.value.name
      priority = rule.value.priority
      action {
        block {}
      }
      statement {
        rate_based_statement {
          limit                 = rule.value.limit
          aggregate_key_type    = "IP"
          evaluation_window_sec = 300
          dynamic "scope_down_statement" {
            for_each = rule.value.path_prefix == null ? [] : [rule.value.path_prefix]
            content {
              byte_match_statement {
                search_string         = scope_down_statement.value
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-edge"
    sampled_requests_enabled   = true
  }
}

# ---------- DNS ----------
resource "aws_route53_record" "app" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = var.domain_name
  type     = each.key

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.origin_domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

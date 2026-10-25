# GitHub Actions가 액세스 키 없이 AWS를 쓰도록 OIDC 역할 두 개를 둡니다.
#
#   서비스 레포 4개 (main 병합 후)  → 레포별 push 역할: 자기 이미지 ECR push, 프론트 빌드 업로드만
#   infra 레포 (production 승인 후) → terraform 역할: terraform apply (배포는 여기서만)
#
# 통합 레포는 조합 검증만 하므로 AWS 권한이 없습니다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # 서비스 레포 → 그 레포가 push할 수 있는 ECR 리포지토리
  service_repo_images = {
    backend   = ["backend"]
    LLM       = ["ai"]
    agent     = ["business-mcp", "rag-mcp"]
    dashboard = []
  }
}

# ---------- image-push 역할 (서비스 레포마다 하나) ----------
# OIDC 클레임은 신뢰 정책에서만 조건으로 쓸 수 있으므로, 레포별로 역할을 나눠 자기 산출물에만 쓰게 합니다.
data "aws_iam_policy_document" "github_image_push_assume" {
  for_each = local.service_repo_images
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # main 브랜치에서 돈 워크플로만 (release.yml은 CI 성공 후 main 기준으로 실행됩니다)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${each.key}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_image_push" {
  for_each           = local.service_repo_images
  name               = "${local.name}-github-push-${lower(each.key)}"
  assume_role_policy = data.aws_iam_policy_document.github_image_push_assume[each.key].json
}

data "aws_iam_policy_document" "github_image_push" {
  for_each = local.service_repo_images

  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(each.value) > 0 ? [each.value] : []
    content {
      actions = [
        "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:DescribeImages",
        "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      ]
      resources = [for i in statement.value : aws_ecr_repository.app[i].arn]
    }
  }

  # dashboard: 빌드 결과를 releases 버킷의 dashboard/<커밋 SHA>/ 아래에만 올립니다
  dynamic "statement" {
    for_each = each.key == "dashboard" ? [1] : []
    content {
      actions   = ["s3:PutObject", "s3:ListBucket"]
      resources = [aws_s3_bucket.releases.arn, "${aws_s3_bucket.releases.arn}/dashboard/*"]
    }
  }
}

resource "aws_iam_role_policy" "github_image_push" {
  for_each = local.service_repo_images
  name     = "push-own-artifacts"
  role     = aws_iam_role.github_image_push[each.key].id
  policy   = data.aws_iam_policy_document.github_image_push[each.key].json
}

# ---------- terraform 역할 (infra 레포, Deploy) ----------
# 인프라 전체를 바꿀 수 있는 역할이라 브랜치가 아니라 GitHub environment로 묶습니다.
# infra 레포 Settings → Environments에서 이 environment에 승인자(required reviewers)를 지정해야
# 사람이 승인한 실행만 이 역할을 받습니다.
data "aws_iam_policy_document" "github_terraform_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_infra_repo}:environment:${var.github_deploy_environment}"]
    }
  }
}

resource "aws_iam_role" "github_terraform" {
  name               = "${local.name}-github-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_terraform_assume.json
}

# IAM을 뺀 AWS 서비스 전반
resource "aws_iam_role_policy_attachment" "github_terraform_poweruser" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# IAM은 이 스택이 만드는 이름(mro-<env>-*)과 GitHub OIDC 공급자로만 한정
data "aws_iam_policy_document" "github_terraform_iam" {
  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags", "iam:PassRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*"]
  }
  statement {
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }
  # ECS·ELB·RDS·Amazon MQ가 처음 쓸 때 만드는 서비스 연결 역할
  statement {
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com",
        "mq.amazonaws.com", "elasticfilesystem.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "github_terraform_iam" {
  name   = "scoped-iam"
  role   = aws_iam_role.github_terraform.id
  policy = data.aws_iam_policy_document.github_terraform_iam.json
}

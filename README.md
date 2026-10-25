# AWS 배포 (Terraform)

`scripts/up.sh`로 로컬에서 띄우는 스택을 AWS에 그대로 옮긴 정의입니다.
서비스 이름·포트·환경변수는 각 레포의 compose 파일과 `.env.example`을 따릅니다.

> 상태: 코드 작성과 `terraform validate`까지 확인했습니다. 실제 AWS에 apply하지는 않았습니다.

```
사용자 ─▶ Route 53 ─▶ CloudFront ─┬─ /*                       ─▶ S3 (dashboard 빌드, OAC)
                    (ACM us-east-1) └─ /api/*, /actuator/health ─▶ ALB ─▶ ECS backend :8080
                                                                              │
 private subnet ───────────────────────────────────────────────────────────────┤
   ECS ai (RabbitMQ 소비자, EFS /data) ──Service Connect──▶ business-mcp :8101, rag-mcp :8102
   RDS PostgreSQL 16 (pgvector)   Amazon MQ RabbitMQ (amqps:5671)   NAT ─▶ OpenAI API
```

| 로컬 | AWS |
| --- | --- |
| `postgres` (pgvector) | RDS PostgreSQL 16, 마스터 비밀번호는 RDS 관리 비밀 |
| `rabbitmq` | Amazon MQ (RabbitMQ, TLS 5671) |
| `backend`, `business-mcp`, `rag-mcp`, `ai` | ECS Fargate 서비스 4개 |
| Docker 네트워크 이름 (`business-mcp:8101`) | ECS Service Connect (같은 이름) |
| `ai-state` 볼륨 | EFS access point (uid 10001) |
| `docker/postgres/init/01-readers.sh` | 1회성 태스크 `db-init` |
| `rag-restore` 서비스 | 1회성 태스크 `rag-restore` (전달본은 S3) |
| `pnpm dev` + vite proxy | S3 + CloudFront (`/api`는 ALB로) |
| `.env`, `.env.mcp` | Secrets Manager (`<name>/app` JSON, `<name>/openai-api-key`) |

## 파일

| 파일 | 내용 |
| --- | --- |
| `bootstrap/` | state용 S3 버킷 (최초 1회, 로컬 state) |
| `versions.tf` | provider, S3 backend (`use_lockfile`) |
| `network.tf` | VPC, 2 AZ public/private 서브넷, NAT 1개, S3 gateway endpoint |
| `security_groups.tf` | 서비스 간 허용 포트 (ALB는 CloudFront 대역만) |
| `data_stores.tf` | RDS, Amazon MQ, EFS |
| `secrets.tf` | JWT·MCP 서명 키·조회 계정 비밀번호 생성, 접속 URL 조립 |
| `iam.tf` | ECS 실행 역할, 태스크 역할 (ECS Exec, EFS, 전달본 읽기) |
| `ecs.tf`, `modules/ecs-service/` | 클러스터, ECR, 서비스 4개 |
| `edge.tf` | ACM, ALB, CloudFront, 프론트 S3, Route 53 |
| `ops.tf`, `ops/rag-restore.Dockerfile` | `db-init`, `rag-restore` 1회성 태스크 |
| `github_oidc.tf` | GitHub Actions 배포 역할 (이미지 push·프론트 업로드만) |

## 처음 배포

준비: AWS CLI 로그인, Route 53 호스팅 영역, Docker.

```bash
# 1. state 버킷
cd infra/bootstrap
terraform init && terraform apply -var state_bucket_name=mro-agent-tfstate-<계정ID>
#    → versions.tf의 backend bucket 값을 같은 이름으로 바꿉니다.

# 2. 인프라 (서비스는 0개로)
cd ..
cp terraform.tfvars.example terraform.tfvars    # 도메인 채우기
terraform init
terraform apply -var services_enabled=false

# 3. OpenAI 키
aws secretsmanager put-secret-value --secret-id "$(terraform output -raw openai_secret_id)" --secret-string 'sk-...'

# 4. 이미지 (레포 루트에서, TAG = git 커밋 SHA)
#    backend/  ai/  mcp/docker/business-mcp.Dockerfile  mcp/docker/rag-mcp.Dockerfile  infra/ops/rag-restore.Dockerfile
#    → terraform output ecr_repositories 의 주소로 push

# 5. MCP 조회 계정에 LOGIN·비밀번호 부여 (권한은 Flyway V4가 줍니다. 서비스보다 먼저 돌려야 MCP가 첫 기동부터 로그인됩니다)
aws ecs run-task --cluster "$(terraform output -raw ecs_cluster)" --launch-type FARGATE \
  --task-definition mro-prod-db-init \
  --network-configuration "$(terraform output -raw run_task_network_configuration)"

# 6. 서비스 기동
terraform apply -var image_tag=$TAG

# 7. RAG 전달본 복원 (backend가 healthy가 된 뒤)
gh release download data-2026-10-22 --repo mro-agent-proj/mro-agent-integration --dir /tmp/release
aws s3 cp --recursive /tmp/release "s3://$(terraform output -raw rag_data_bucket)/data-2026-10-22/"
aws ecs run-task ... --task-definition mro-prod-rag-restore ...   # 5번과 같은 옵션

# 8. 프론트
cd ../frontend && pnpm install && pnpm build
aws s3 sync dist "s3://$(terraform -chdir=../infra output -raw frontend_bucket)" --delete
aws cloudfront create-invalidation --distribution-id "$(terraform -chdir=../infra output -raw cloudfront_distribution_id)" --paths '/*'
```

## 새 버전 배포

이미지를 새 태그로 push한 뒤 `terraform apply -var image_tag=<새 SHA>`.
ECS가 롤링 배포하고, 헬스체크에 실패하면 이전 버전으로 되돌립니다(circuit breaker).
`ai`는 실행 기록이 SQLite라 항상 1개만 돌도록 기존 태스크를 먼저 내립니다.

## 비용 (서울 리전, 상시 가동 기준 대략)

월 약 $240, 하루 약 $8. NAT·ALB·RDS·Amazon MQ가 트래픽과 무관하게 고정으로 나갑니다.
안 쓸 때는 `terraform apply -var services_enabled=false`로 컨테이너 비용만 줄이거나,
`terraform destroy`로 전부 지웁니다. `environment=prod`는 RDS 삭제 보호가 켜져 destroy가 막히므로,
시연용으로 올렸다 내릴 거라면 처음부터 `environment=dev`로 만듭니다.

## 남은 과제

- 이미지 빌드·push와 프론트 배포를 GitHub Actions 워크플로로 만들기 (`github_deploy_role_arn` 사용)
- AI 오토스케일: 실행 기록을 SQLite 대신 Postgres(`CHECKPOINT_DATABASE_URL`)로 옮긴 뒤 큐 길이 기준으로
- dev/prod 분리 시 backend `key`와 tfvars를 환경별로

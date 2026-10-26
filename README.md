# 항공기 정비요청 Agent 인프라

AWS 인프라(Terraform)와 배포를 맡는 레포입니다. **운영 배포는 이 레포의 Deploy 워크플로에서만 합니다.**
로컬 `integration/scripts/up.sh` 스택을 AWS로 옮긴 정의이며, 서비스 이름·포트·환경변수는
각 서비스 레포의 compose 파일과 `.env.example`을 따릅니다.

> 아직 AWS에 apply하지 않은 정의입니다.

## 레포 구성

| 레포 | 역할 |
| --- | --- |
| [dashboard](https://github.com/mro-agent-proj/dashboard) | 신고자·정비팀·관리자 화면 (Vue 3) |
| [backend](https://github.com/mro-agent-proj/backend) | 계정·요청·배정 API, DB·RabbitMQ, MCP 토큰 발급 (Spring Boot) |
| [LLM](https://github.com/mro-agent-proj/LLM) | AI 서버: LLM1 분류 → LLM2 조사 → LLM3 검토 (FastAPI + LangGraph) |
| [agent](https://github.com/mro-agent-proj/agent) | MCP 서버 2개: business-mcp, rag-mcp (읽기 전용) |
| [integration](https://github.com/mro-agent-proj/integration) | 서비스 4개의 검증된 커밋 조합, 로컬 실행·평가 스크립트 (봇이 자동 갱신) |
| **infra** | **이 레포.** AWS 인프라(Terraform)와 운영 배포. 배포는 여기서만 합니다 |
| [deliverables](https://github.com/mro-agent-proj/deliverables) | 최종 결과보고서, 아키텍처 다이어그램 등 산출물 |
| [data](https://github.com/mro-agent-proj/data) | RAG 데이터 전달본 (비공개, 외부 저작물 가공 데이터 포함) |

## 배포 흐름

```
[서비스 레포 ×4]  PR → 리뷰 → main 병합 → CI 통과 → Release: 이미지를 ECR에 (태그 = 커밋 SHA)
      │ repository_dispatch (봇)
      ▼
[integration]  submodule을 각 레포 main으로 갱신 → 통합 검증 → 통과 시 커밋 + verified-* 태그
      │ repository_dispatch (봇)
      ▼
[infra]  Promote: deploy/release.json 갱신 PR → 리뷰·병합 → Deploy: production 승인 → terraform apply
```

| 레포 | 사람이 하는 일 | 자동으로 일어나는 일 |
| --- | --- | --- |
| backend · dashboard · agent · LLM | PR, 리뷰, 병합 | 이미지 빌드·ECR push, 통합 레포에 알림 |
| integration | 없음 (main은 봇만 push) | 조합 갱신, 검증, verified 태그, infra에 알림 |
| infra | release PR 리뷰·병합, 배포 승인, 인프라 변경 PR | 배포 |

- `deploy/release.json`이 **지금 운영에 나가 있는(나갈) 조합**입니다. 서비스별 커밋 SHA가 곧 이미지 태그입니다.
- 이미지는 서비스 레포에서 한 번만 빌드합니다. Deploy는 이미지가 ECR에 없으면 배포하지 않습니다.
- 되돌리기: `release.json`을 이전 조합으로 되돌리는 PR을 병합합니다.

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
| `docker/postgres/init/01-readers.sh` | 1회성 태스크 `db-init` (MCP 조회 계정 + backend 앱 계정 `mro_app`) |
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
| `ecs.tf`, `modules/ecs-service/` | 클러스터, ECR (앱 이미지 + Docker Hub pull-through cache), 서비스 4개 |
| `edge.tf` | ACM, ALB, CloudFront, 프론트 S3, Route 53, WAF |
| `ops.tf`, `ops/rag-restore.Dockerfile` | `db-init`, `rag-restore` 1회성 태스크 |
| `monitoring.tf` | Prometheus·Grafana (ECS, EFS 저장), Grafana는 `/grafana/` 경로로 노출 |
| `github_oidc.tf` | GitHub Actions 역할: 서비스 레포별 push 역할 4개(main), infra 레포 terraform 역할(production environment) |
| `releases.tf` | 서비스 레포 산출물 버킷 (dashboard 빌드) |
| `deploy/release.json` | 배포할 서비스별 커밋 SHA |
| `.github/workflows/` | `check`(PR 검사), `promote`(조합 → release PR), `deploy`(배포) |

## 처음 배포

준비: AWS CLI 로그인, Route 53 호스팅 영역, Docker.

```bash
# 1. state 버킷
cd bootstrap
terraform init && terraform apply -var state_bucket_name=mro-agent-tfstate-<계정ID>
#    → versions.tf의 backend bucket 값을 같은 이름으로 바꿉니다.

# 2. Docker Hub 자격 증명 (ECR pull-through cache용, Docker Hub → Account settings → Personal access tokens에서 읽기 전용 토큰 발급)
aws secretsmanager create-secret --name ecr-pullthroughcache/docker-hub \
  --secret-string '{"username":"<Docker Hub ID>","accessToken":"<토큰>"}'

# 3. 인프라 (서비스는 0개로)
cd ..
cp terraform.tfvars.example terraform.tfvars    # 도메인 채우기
terraform init
terraform apply -var services_enabled=false

# 4. OpenAI 키
aws secretsmanager put-secret-value --secret-id "$(terraform output -raw openai_secret_id)" --secret-string 'sk-...'

# 5. 이미지: 아래 'GitHub 설정'을 마친 뒤 각 서비스 레포의 Release 워크플로를 한 번씩 실행(workflow_dispatch)
#    → release.json의 SHA로 ECR 이미지와 dashboard 빌드가 올라갑니다

# 6. DB 계정 준비: MCP 조회 계정 LOGIN, backend 앱 계정 mro_app 생성·권한 (서비스보다 먼저 실행)
aws ecs run-task --cluster "$(terraform output -raw ecs_cluster)" --launch-type FARGATE \
  --task-definition mro-prod-db-init \
  --network-configuration "$(terraform output -raw run_task_network_configuration)"

# 7. 서비스 기동 (이후로는 Deploy 워크플로가 같은 일을 합니다)
terraform apply

# 8. RAG 전달본 복원 (backend가 healthy가 된 뒤)
gh release download data-2026-10-22 --repo mro-agent-proj/integration --dir /tmp/release
aws s3 cp --recursive /tmp/release "s3://$(terraform output -raw rag_data_bucket)/data-2026-10-22/"
aws ecs run-task ... --task-definition mro-prod-rag-restore ...   # 6번과 같은 옵션

# 9. 프론트: Deploy 워크플로를 한 번 실행(workflow_dispatch)하면 dashboard 빌드가 반영됩니다
```

## GitHub 설정 (한 번)

1. **GitHub App** (레포 간 자동화용 봇): 조직 Settings → Developer settings → GitHub Apps → New
   - 권한: Contents *Read and write*, Pull requests *Read and write*, Metadata *Read*
   - 설치: backend, dashboard, agent, LLM, integration, infra
   - 조직 변수 `RELEASE_APP_ID`(App ID), 조직 시크릿 `RELEASE_APP_PRIVATE_KEY`(발급한 private key)
2. **AWS 연결 변수** (`terraform output`으로 확인)
   - 서비스 레포 4개: 레포 변수 `AWS_PUSH_ROLE_ARN` = `github_push_role_arns`의 해당 값, 조직 변수 `RELEASES_BUCKET`, `AWS_REGION`
   - infra 레포: `AWS_TERRAFORM_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_HOSTED_ZONE_NAME`, `TF_DOMAIN_NAME`,
     `TF_GRAFANA_ALLOWED_CIDRS`(JSON 목록, 예: `["203.0.113.10/32"]`)
3. **infra 레포** Settings → Environments → `production`: Required reviewers 지정. main 브랜치 보호(PR·리뷰 필수).
4. **integration** Settings → Rules: main에 push·PR 병합을 막고 GitHub App만 우회(bypass) 허용.
   문서·스크립트는 관리자만 우회해서 고칩니다.

AWS 변수가 비어 있으면 Release의 ECR 단계와 Deploy가 건너뛰어지므로, 인프라를 올리기 전에도 워크플로는 실패하지 않습니다.

## DB 계정

| 계정 | 쓰는 곳 | 권한 |
| --- | --- | --- |
| `mro` (RDS 마스터) | backend Flyway 마이그레이션(`SPRING_FLYWAY_USER`), `db-init`, `rag-restore` | 스키마·테이블 소유 |
| `mro_app` | backend 실행 (`DB_USERNAME`) | `public`·`rag` 테이블 DML, 시퀀스 |
| `mro_reader`, `mro_business_reader` | rag-mcp, business-mcp | Flyway V4가 준 SELECT만 |

backend는 실행 중에 DDL을 쓰지 않습니다(직접 SQL은 SELECT·INSERT·UPDATE·DELETE와 advisory lock뿐).
`mro_app`에는 DEFAULT PRIVILEGES를 걸어 두어 Flyway가 나중에 만드는 테이블에도 권한이 갑니다.

## 새 버전 배포

서비스 레포에서 병합하면 위 흐름대로 release PR이 이 레포에 올라옵니다. 병합하고 Deploy의 `production` 승인을 누르면 배포됩니다.
Deploy가 쓰는 terraform 역할은 이 레포의 `production` environment에서만 받을 수 있습니다.
인프라 전체를 바꿀 수 있는 역할이라 승인 없이 쓰이지 않게 하는 것이 핵심입니다.
ECS가 롤링 배포하고, 헬스체크에 실패하면 이전 버전으로 되돌립니다(circuit breaker).
`ai`는 실행 기록이 SQLite라 항상 1개만 돌도록 기존 태스크를 먼저 내립니다.

## 보안 (WAF)

CloudFront에 붙은 WAF가 서비스로 들어오는 모든 요청을 아래 순서로 검사합니다.

| 순서 | 규칙 | 동작 |
| --- | --- | --- |
| 0~2 | Grafana | `/grafana*`는 `grafana_allowed_cidrs` 대역만 통과, 나머지는 차단 |
| 3 | `AmazonIpReputationList` | 알려진 봇·악성 IP 차단 |
| 4 | `CommonRuleSet` | XSS·경로 조작 등 OWASP 기본 공격 차단 |
| 5 | `SQLiRuleSet` | SQL 인젝션 차단 |
| 6 | `KnownBadInputsRuleSet` | Log4j 등 Java 계열 공격 패턴 차단 |
| 7 | `rate-limit-auth` | 같은 IP가 5분에 `/api/v1/auth/` 요청 `waf_auth_rate_limit`(기본 100)회 초과 시 차단 |
| 8 | `rate-limit-all` | 같은 IP가 5분에 `waf_rate_limit`(기본 2,000)회 초과 시 차단 |

정비 신고 본문(`symptom_text`)은 자유 서술이라 본문을 검사하는 항목(`*_BODY`)은 처음에 count(기록만)로 둡니다.
CloudWatch의 WAF 지표·샘플 요청으로 오탐이 없는지 확인한 뒤 `edge.tf`의 `count_rules`에서 빼면 차단으로 바뀝니다.

## 모니터링

- Grafana: `https://<domain>/grafana/`, 계정 `admin`, 비밀번호는 Secrets Manager `<name>/app`의 `grafana_admin_password`
- `/grafana*`는 WAF가 `grafana_allowed_cidrs` 대역에서만 열어 줍니다. 비워 두면 외부에서 접근할 수 없습니다.
- 데이터소스는 시작할 때 자동 등록됩니다: **CloudWatch**(ECS·RDS·Amazon MQ·ALB 지표, 태스크 역할로 조회), **Prometheus**
- Prometheus는 외부에 노출하지 않고 Grafana에서만 조회합니다. 설정 파일은 Terraform이 만들어 환경변수로 넘깁니다.
- 지금은 앱들이 메트릭 엔드포인트를 내보내지 않아 Prometheus는 자기 자신만 수집합니다.
  각 레포에 메트릭이 추가되면 `terraform.tfvars`의 `prometheus_scrape_targets` 주석을 풀고 apply합니다.
  보안 그룹(Prometheus → 각 서비스 포트)과 Service Connect 이름(`backend`, `ai`, `business-mcp`, `rag-mcp`)은 미리 열어 두었습니다.
- Prometheus TSDB는 EFS에 둡니다. Prometheus 공식 문서는 NFS를 지원 대상으로 보지 않으므로, 데이터가 커지거나
  장기 보관이 필요해지면 Amazon Managed Prometheus(remote_write)로 옮기는 것을 검토합니다.

## 비용 (서울 리전, 24시간 켜 둘 때 대략)

| 항목 | 월 비용 |
| --- | --- |
| **기본 구성** | **약 $240** (하루 약 $8) |
| + 모니터링 (Prometheus·Grafana 컨테이너 2개 + 저장소 EFS) | +$25~35 |
| + WAF (Web ACL, 규칙 9개 중 관리형 규칙 그룹 4개) | +약 $15 |

**사용하지 않아도 나가는 비용이 있습니다.** NAT 게이트웨이, 로드밸런서(ALB), DB(RDS), 메시지 큐(Amazon MQ)는 켜져 있기만 해도 요금이 붙습니다. 요청이 0건이어도 마찬가지입니다.

### 안 쓸 때 비용 줄이기

| 방법 | 명령어 | 결과 |
| --- | --- | --- |
| 컨테이너만 끄기 | `terraform apply -var services_enabled=false` | ECS 서비스가 0개가 되어 컨테이너 비용만 빠집니다. NAT·ALB·RDS·MQ 비용은 계속 나가고, DB 데이터는 남습니다. |
| 전부 삭제 | `terraform destroy` | 모든 리소스와 비용이 사라집니다. `dev`에서는 최종 스냅샷 없이 DB 데이터도 함께 지워집니다. |

### 시연용이면 처음부터 `environment=dev`로

`environment=prod`로 만들면 DB 삭제 보호가 켜져서 `terraform destroy`가 실패합니다. 잠깐 띄웠다 지울 거라면 처음 만들 때부터 `environment=dev`를 쓰세요.

## 남은 과제

- AI 오토스케일: 실행 기록을 SQLite 대신 Postgres(`CHECKPOINT_DATABASE_URL`)로 옮긴 뒤 큐 길이 기준으로
- dev/prod 분리 시 backend `key`와 `release.json`을 환경별로 (dev 자동 배포 → prod 승격)
- 앱 메트릭: backend `micrometer-registry-prometheus` + actuator 노출 목록에 `prometheus`, ai·MCP는 `/metrics` 추가 → scrape 대상 등록
- Grafana 대시보드 프로비저닝 (지금은 데이터소스만)

# RAG 전달본 복원용 1회성 이미지. 로컬 backend/docker-compose.yml의 rag-restore 서비스와 같은 스크립트를 씁니다.
# 빌드 컨텍스트는 backend 레포 체크아웃입니다 (deploy 워크플로가 release.json의 backend SHA로 빌드):
#   docker build -f ops/rag-restore.Dockerfile -t <ECR>/mro/rag-restore:<backend SHA> <backend 경로>
FROM pgvector/pgvector:0.8.2-pg16

RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY scripts scripts
COPY src/main/resources/db/migration src/main/resources/db/migration

# S3의 Release 첨부파일 → data/rag-dump/ (scripts/fetch-data.sh와 같은 배치) → 복원
ENTRYPOINT ["bash", "-c", "set -euo pipefail; \
  mkdir -p /tmp/release data/rag-dump; \
  aws s3 cp --recursive \"s3://$DATA_BUCKET/$DATA_PREFIX/\" /tmp/release/; \
  (cd /tmp/release && sha256sum -c SHA256SUMS --ignore-missing); \
  for t in sdr-jasc-amm_v2 airbus-safety-first_v2 sdr-embeddings_v1; do tar -xf /tmp/release/$t.tar -C data/rag-dump; done; \
  exec bash scripts/restore-data.sh"]

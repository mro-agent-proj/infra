# RAG 전달본 복원용 1회성 이미지. 로컬 backend/docker-compose.yml의 rag-restore 서비스와 같은 스크립트를 씁니다.
# 빌드 (레포 루트에서): docker build -f infra/ops/rag-restore.Dockerfile -t <ECR>/mro/rag-restore:<tag> .
FROM pgvector/pgvector:0.8.2-pg16

RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY backend/scripts scripts
COPY backend/src/main/resources/db/migration src/main/resources/db/migration

# S3의 Release 첨부파일 → data/rag-dump/ (scripts/fetch-data.sh와 같은 배치) → 복원
ENTRYPOINT ["bash", "-c", "set -euo pipefail; \
  mkdir -p /tmp/release data/rag-dump; \
  aws s3 cp --recursive \"s3://$DATA_BUCKET/$DATA_PREFIX/\" /tmp/release/; \
  (cd /tmp/release && sha256sum -c SHA256SUMS --ignore-missing); \
  for t in sdr-jasc-amm_v2 airbus-safety-first_v2 sdr-embeddings_v1; do tar -xf /tmp/release/$t.tar -C data/rag-dump; done; \
  exec bash scripts/restore-data.sh"]

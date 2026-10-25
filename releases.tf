# 서비스 레포가 올린 배포 산출물. 지금은 dashboard 빌드(dashboard/<커밋 SHA>/)만 둡니다.
# deploy 워크플로가 release.json의 SHA에 해당하는 빌드를 프론트 버킷으로 복사합니다.
resource "aws_s3_bucket" "releases" {
  bucket = "${local.name}-releases-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "releases" {
  bucket                  = aws_s3_bucket.releases.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "releases" {
  bucket = aws_s3_bucket.releases.id
  rule {
    id     = "expire-old-builds"
    status = "Enabled"
    filter {}
    expiration {
      days = 180
    }
  }
}

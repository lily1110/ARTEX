# PostgreSQL for docker-compose.yml.
# 基于 Docker 官方镜像（docker-library 构建，附 SLSA provenance 与 SBOM），按 digest 固定；
# 升级时同时改 tag 与 digest：docker buildx imagetools inspect postgres:16-alpine
FROM postgres:16-alpine@sha256:f2f98726820d0342055351c6e9d36e705f5bfffb3dd53ff556325114b08afb6d
# 补上官方镜像发布后 Alpine 已推出的安全更新（如 openssl / libxml2）。
RUN apk upgrade --no-cache

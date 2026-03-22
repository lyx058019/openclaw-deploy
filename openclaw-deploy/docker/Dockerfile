FROM node:22-alpine

# 安装 OpenClaw 依赖
RUN apk add --no-cache \
    python3 \
    make \
    g++ \
    git \
    curl

# 安装 OpenClaw CLI
RUN npm install -g openclaw

# 创建工作目录
WORKDIR /app

# 复制配置文件
COPY config/ ./config/
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 2026 3000

ENTRYPOINT ["/entrypoint.sh"]

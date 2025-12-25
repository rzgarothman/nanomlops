#!/bin/bash
set -e

# 该脚本在 Postgres 容器首次启动时执行
# 用于创建各服务所需的独立数据库

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE gitea;
    CREATE DATABASE mlflow;
    CREATE DATABASE prefect;
    CREATE DATABASE label_studio;
    GRANT ALL PRIVILEGES ON DATABASE gitea TO "$POSTGRES_USER";
    GRANT ALL PRIVILEGES ON DATABASE mlflow TO "$POSTGRES_USER";
    GRANT ALL PRIVILEGES ON DATABASE prefect TO "$POSTGRES_USER";
    GRANT ALL PRIVILEGES ON DATABASE label_studio TO "$POSTGRES_USER";
EOSQL
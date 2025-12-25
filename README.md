# 轻量化 MLOps 基础设施实施指南

本文档指导如何在单台高性能服务器（建议 Linux, Ubuntu 24.04+）上部署基于 Docker 的全栈 MLOps 平台。

## 1\. 环境准备 (Environment Setup)

本节提供在 **Ubuntu 24.04 LTS** 上安装基础环境的详细步骤。

### 1.1 基础工具与 Docker 安装

首先更新系统并安装 Docker Engine 及 Docker Compose 插件。

```bash
# 1. 更新软件包索引并安装依赖
sudo apt-get update
sudo apt-get install -y ca-certificates curl git

# 2. 添加 Docker 官方 GPG 密钥
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL [https://download.docker.com/linux/ubuntu/gpg](https://download.docker.com/linux/ubuntu/gpg) -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 3. 添加 Docker 仓库
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] [https://download.docker.com/linux/ubuntu](https://download.docker.com/linux/ubuntu) \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. 安装 Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. 验证安装并允许非 root 用户运行 (可选)
sudo docker run hello-world
sudo usermod -aG docker $USER
# 注意：执行完上一行后需要注销并重新登录才能生效
```

### 1.2 NVIDIA 驱动与容器工具包 (GPU 支持必选)

如果服务器配有 NVIDIA GPU，需安装驱动和 Container Toolkit 以便容器能够调用显卡。

```bash
# 1. 验证 GPU 是否被系统识别
lspci | grep -i nvidia

# 2. 安装 NVIDIA 驱动 (如果尚未安装)
# Ubuntu 24.04 通常可以通过 ubuntu-drivers 工具自动推荐
sudo ubuntu-drivers autoinstall
# 安装完成后需重启
sudo reboot

# 3. 安装 NVIDIA Container Toolkit
curl -fsSL [https://nvidia.github.io/libnvidia-container/gpgkey](https://nvidia.github.io/libnvidia-container/gpgkey) | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L [https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list](https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list) | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# 4. 配置 Docker 运行时并重启 Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# 5. 验证容器内的 GPU 访问
sudo docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

## 2\. 目录结构初始化

将生成的文件按照以下结构组织：

```markdown
mlops-platform/
├── .env                    # 环境变量配置
├── docker-compose.yml      # 主编排文件
├── build/
│   ├── Dockerfile.workspace # Workspace 镜像定义
│   ├── Dockerfile.mlflow    # MLflow 自定义镜像构建 (含 PG/S3 驱动)
│   └── Dockerfile.evidently # Evidently 自定义镜像构建
├── config/
│   ├── nginx/
│   │   ├── nginx.conf      # 网关配置
│   │   └── index.html      # 导航仪表盘页面
│   └── prometheus/
│       └── prometheus.yml  # 监控配置
└── scripts/
    └── init_db.sh          # 数据库初始化脚本
```

**执行权限设置：**

```bash
chmod +x scripts/init_db.sh
mkdir -p data/{postgres,minio,gitea,mlflow,redis,label-studio,prometheus,grafana,workspace,dvc_cache,evidently}
# 确保数据目录权限（防止容器内无权限写入）
sudo chown -R 1000:1000 data
```

## 3\. 部署流程

### 步骤 1: 检查配置

打开 `.env` 文件，根据实际情况修改：

- `ENABLE_GPU`: 如果没有 GPU，设置为 `false` （注意：需要在 docker-compose.yml 中注释掉 workspace 的 deploy 部分）。
- 修改 `POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD` 等敏感信息。

### 步骤 2: 构建并启动

首次启动需要构建 Workspace 镜像（耗时较长，因为包含 CUDA 和大量 Python 库）。

**注意** ：在安装 `docker-compose-plugin` 后，请使用 `docker compose` （中间有空格）而不是 `docker-compose` 。

```bash
docker compose up -d --build
```

### 步骤 3: 服务初始化与验证

启动后，按顺序执行以下初始化操作：

#### A. MinIO (对象存储)

1. 访问 `http://localhost:9001` (或点击导航页卡片)。
2. 登录 (默认: `minioadmin` / `minioadmin`)。
3. 创建以下 Buckets:
	- `mlflow` (用于存放模型制品)
	- `dvc` (用于存放数据集)
	- `prefect` (用于存放流程日志或结果)
4. 创建 Access Keys（如果未使用根用户），并在 `.env` 和 `docker-compose.yml` 中更新。

#### B. Gitea (代码仓库)

1. 访问 `http://localhost:3000` 。
2. 点击 "Register" 进行初始配置。
	- **数据库类型**: PostgreSQL
	- **主机**: `db:5432`
	- **用户名/密码**: 参考 `.env` (默认 `admin` / `secure_pg_password`)
	- **数据库名称**: `gitea`
3. 创建第一个管理员账号。

#### C. Prefect (工作流编排)

1. Prefect Server 已自动连接 Postgres 启动。
2. 访问 `http://localhost:4200` 确认 UI 可用。
3. 在 Workspace 容器内配置 API 地址：
	```bash
	prefect config set PREFECT_API_URL=http://prefect-server:4200/api
	```

#### D. 开发环境 (Workspace)

1. **JupyterLab**: 访问 `http://localhost:8888` (Token: `workspace_token`)。
2. **VSCode**: 访问 `http://localhost:8081` (Password: `workspace_password`)。
3. 验证 GPU (如果启用): 在 Jupyter 中运行:
	```python
	import torch
	print(torch.cuda.is_available())
	```

#### E. Grafana (可视化监控)

1. 访问 `http://localhost:3001` (或点击导航页卡片)。
2. 登录 (默认: `admin` / `admin`)，系统会提示修改密码。
3. **添加数据源 (Add Data Source)**:
	- 选择 **Prometheus** 。
	- 在 URL 栏输入: `http://prometheus:9090` (注意这里使用 Docker 服务名)。
	- 点击 "Save & Test"。
4. **导入仪表盘 (Import Dashboard)**:
	- 在左侧菜单选择 Dashboards -> New -> Import。
	- 输入以下 Grafana ID 并点击 Load，选择刚才创建的 Prometheus 数据源：
		- 宿主机硬件监控: ID 1860 (Node Exporter Full)
		- Docker 容器监控: ID 14282 (Cadvisor Exporter)
		- PostgreSQL 数据库: ID 9628 (PostgreSQL Database)
		- Redis 缓存: ID 763 (Redis Dashboard)

#### F. Feast (特征存储)

Feast 需要在 Workspace 容器内进行配置以连接离线存储 (Postgres) 和在线存储 (Redis)。

1. **进入 Workspace 容器**:

```bash
docker exec -it mlops-workspace bash
```


2. **初始化项目**:
```bash
feast init feature_repo
cd feature_repo
```


3. **修改配置 (`feature_store.yaml`)**:
编辑 `feature_store.yaml` 文件，将数据源指向 Docker 容器网络中的服务：
```yaml
project: feature_repo
registry: data/registry.db
provider: local
online_store:
    type: redis
    # 使用 docker-compose 服务名
    connection_string: "redis:6379"
offline_store:
    type: postgres
    # 使用 docker-compose 服务名
    host: db
    port: 5432
    database: postgres
    user: admin
    password: secure_pg_password
```

## 4\. 工作流示例 (Workflow Walkthrough)

以下是在 Workspace 容器内进行开发的典型场景。首先，请进入容器终端：

```bash
docker exec -it mlops-workspace bash
```

### 场景 1: 代码版本管理 (Gitea)

在开始任何项目前，先在 Gitea 上创建一个空仓库，然后在 Workspace 中初始化：

```bash
# 1. 初始化项目目录
mkdir my-project && cd my-project
git init

# 2. 配置 Git 用户
git config --global user.name "DataScientist"
git config --global user.email "ds@mlops.local"

# 3. 创建代码文件
echo "print('Hello MLOps')" > main.py

# 4. 推送到 Gitea
git add main.py
git commit -m "Initial commit"
git branch -M main
# 注意：使用 host.docker.internal 或宿主机 IP，端口 3000
git remote add origin [http://host.docker.internal:3000/your_username/my-project.git](http://host.docker.internal:3000/your_username/my-project.git)
git push -u origin main
```

### 场景 2: 代码与数据协同版本管理 (Git + DVC)

大文件（数据集、模型权重）不应存入 Git，而是使用 DVC 存入 MinIO，Git 只管理元数据。

```bash
# 1. 初始化 DVC
dvc init

# 2. 配置 DVC 远程存储 (MinIO)
# 注意：使用 minio 容器服务名，bucket 需提前在 Step 3-A 中创建
dvc remote add -d myremote s3://dvc/my-project
dvc remote modify myremote endpointurl http://minio:9000
dvc remote modify myremote access_key_id minioadmin
dvc remote modify myremote secret_access_key minioadmin

# 3. 追踪数据文件
# 假设有一个大文件 data/raw.csv
dvc add data/raw.csv

# 4. 提交更改
# DVC 会生成 data/raw.csv.dvc 文件，Git 只需要追踪这个小文件
git add data/raw.csv.dvc .gitignore
git commit -m "Add raw dataset"

# 5. 推送数据与代码
dvc push  # 数据上传到 MinIO
git push  # 代码上传到 Gitea
```

### 场景 3: Prefect 流程编排

使用 Python 定义工作流，并利用 Prefect 监控运行状态。

**创建 `flow.py`:**

```python
from prefect import flow, task
import time

@task(retries=3)
def load_data():
    print("Loading data...")
    time.sleep(1)
    return [1, 2, 3]

@task
def process_data(data):
    print(f"Processing {len(data)} records...")
    return [x * 10 for x in data]

@flow(name="Daily Training Flow", log_prints=True)
def training_pipeline():
    raw_data = load_data()
    processed = process_data(raw_data)
    print(f"Result: {processed}")

if __name__ == "__main__":
    # 本地运行并上报到 Prefect Server
    training_pipeline()
```

**运行与监控:**

1. 在终端运行: `python flow.py`
2. 打开浏览器 `http://localhost:4200` ，你将在 Dashboard 中看到刚才的运行记录、日志和任务状态。

### 场景 4: CI/CD 自动化 (Gitea Actions)

当代码推送到 Gitea 时，自动触发测试。

**1\. 在项目根目录创建工作流文件 `.gitea/workflows/ci.yaml`:**

```yaml
name: MLOps CI
on: [push]

jobs:
  test-model:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repository
        uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: |
          pip install --upgrade pip
          pip install pytest pandas scikit-learn

      - name: Run Data Integrity Tests
        run: |
          # 假设您有测试脚本 tests/test_data.py
          # pytest tests/
          echo "Running tests..."
          python -c "import pandas; print('Pandas imported successfully')"
```

**2\. 提交并推送:**

```bash
git add .gitea/workflows/ci.yaml
git commit -m "Add CI pipeline"
git push
```

**3\. 查看结果:**在 Gitea 仓库页面的 "Actions" 标签页中，您将看到流水线正在运行。如果配置了 Runner（本架构中需确保 Gitea Act Runner 已启用并连接到 Gitea 实例），它将自动执行这些步骤。

### 场景 5: 特征工程与服务 (Feast)

利用 Feast 管理特征并提供低延迟服务。

1. **应用特征定义**:
在 `feature_repo` 目录下（已在步骤 3-F 中配置好），运行：
```bash
# 将特征定义注册到 Registry，并同步到 Online Store (Redis)
feast apply
```

2. **物化特征 (Materialize)**:
将数据从离线存储加载到在线存储（Redis）中，以便实时服务。
```bash
# 将当前时间点的数据加载到 Redis
feast materialize-incremental $(date -u +"%Y-%m-%dT%H:%M:%S")
```

3. **获取在线特征 (Python)**:
```python
from feast import FeatureStore
import pandas as pd

store = FeatureStore(repo_path=".")

feature_vector = store.get_online_features(
    features=[
        "driver_hourly_stats:conv_rate",
        "driver_hourly_stats:acc_rate",
    ],
    entity_rows=[
        {"driver_id": 1001},
    ]
).to_dict()

print(feature_vector)
```

## 5\. 故障排查

- **容器无法启动**: 查看日志 `docker compose logs -f <service_name>` 。
- **权限错误**: 检查 `data/` 目录的归属权是否为 `1000:1000` 。
- **GPU 无法识别**: 确保宿主机运行 `nvidia-smi` 正常，且 Docker Compose 中 `runtime: nvidia` 或 `deploy.resources` 配置正确。
- **Gitea Actions 未运行**: 检查 Gitea 配置文件中是否启用了 Actions 功能 (`[actions] ENABLED = true`)，并确认 Runner 已注册。

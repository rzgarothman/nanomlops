# 轻量化 MLOps 基础设施实施指南

本文档指导如何在单台高性能服务器（建议 Linux, Ubuntu 24.04+）上部署基于 Docker 的全栈 MLOps 平台。本架构采用 **计算与存储分离** 模式，支持多租户独立工作区。

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

```bash
mlops-platform/
├── .env                        # 基础设施全局配置
├── .env.user1                  # [新增] 用户1 工作区配置
├── docker-compose.yml          # [核心] 基础设施编排 (Infra)
├── docker-compose.workspace.gpu.yml # [新增] GPU 工作区编排
├── docker-compose.workspace.cpu.yml # [新增] CPU 工作区编排
├── build/
│   ├── Dockerfile.workspace    # Workspace 镜像定义 (动态基础镜像)
│   ├── Dockerfile.mlflow       # MLflow 自定义镜像
│   └── Dockerfile.evidently    # Evidently 自定义镜像
├── config/
│   ├── nginx/
│   │   ├── nginx.conf          # 网关配置
│   │   └── index.html          # 导航仪表盘
│   └── prometheus/
│       └── prometheus.yml      # 监控配置
└── scripts/
    └── init_db.sh              # 数据库初始化脚本
```

**执行权限设置：**

```bash
chmod +x scripts/init_db.sh
mkdir -p data/{postgres,minio,gitea,mlflow,redis,label-studio,prometheus,grafana,evidently}
# 为用户数据预创建目录 (以 user1 为例)
mkdir -p data/workspace-user1/{work,dvc_cache,vscode,jupyter}
# 确保数据目录权限（防止容器内无权限写入）
sudo chown -R 1000:1000 data
```

## 3\. 部署流程

### 步骤 1: 初始化网络

创建一个共享网络，使基础设施和动态拉起的工作区能够互通。

```bash
docker network create mlops-shared-net
```

### 步骤 2: 启动基础设施 (Infra)

1. **检查配置**: 修改 `.env` 中的密码和版本号。
2. **启动服务**:
	```bash
	docker compose -f docker-compose.yml up -d --build
	```
	此命令将启动 Postgres, MinIO, Gitea, MLflow, Prefect, Nginx, Prometheus, Grafana 等所有后台服务。

### 步骤 3: 基础设施初始化

启动后，按顺序执行以下初始化操作：

#### A. MinIO (对象存储)

1. 访问 `http://localhost:9001` 。
2. 登录 (默认: `minioadmin` / `minioadmin`)。
3. 创建以下 Buckets: `mlflow`, `dvc`, `prefect` 。
4. 创建 Access Keys（建议为每个用户创建独立的 Key，这里演示使用根用户）。

#### B. Gitea (代码仓库)

1. 访问 `http://localhost:3000` 。
2. 点击 "Register" 进行初始配置。
	- 数据库主机: `mlops-postgres:5432` (注意：使用容器名)
	- 用户名/密码: 参考 `.env`
	- 域名/URL: 使用 `localhost` 或您的服务器 IP
3. 创建管理员账号。

#### C. Prefect (编排)

1. 访问 `http://localhost:4200` 确认 UI 可用。

#### D. Grafana (监控)

1. 访问 `http://localhost:3001` (默认: `admin` / `admin`)。
2. **添加数据源**: 选择 Prometheus，URL 输入 `http://mlops-prometheus:9090` 。
3. **导入仪表盘 (Import)**:
	- **宿主机监控**: ID `1860`
	- **容器监控**: ID `14282`
	- **Postgres**: ID `9628`
	- **Redis**: ID `763`

### 步骤 4: 启动工作区 (Workspace)

为用户（如 user1）启动独立的开发环境。根据服务器硬件情况选择 GPU 或 CPU 版本。

1. **创建用户配置**: 参考模板创建 `.env.user1` ，设置基本信息和端口（ **注意：PORT\_NAV 为该用户的统一导航入口端口** ）：
	```ini
	WORKSPACE_NAME=workspace-user1
	WORKSPACE_PASSWORD=mysecret
	WORKSPACE_TOKEN=mytoken
	# 导航仪表盘端口
	PORT_NAV=8080
	# 各服务端口 (确保不冲突)
	PORT_JUPYTER=8888
	PORT_VSCODE=8081
	PORT_BENTO=3002
	PORT_STREAMLIT=8501
	```
2. **启动容器 (选择其一)**:
	- **选项 A: 启用 GPU (需要 NVIDIA 显卡)**
		```bash
		docker compose -f docker-compose.workspace.gpu.yml --env-file .env.user1 up -d --build
		```
	- **选项 B: 仅 CPU (轻量模式)**
		```bash
		docker compose -f docker-compose.workspace.cpu.yml --env-file .env.user1 up -d --build
		```
3. **访问环境**:
	- **统一导航仪表盘**: `http://localhost:8080` (或您在 `.env.user1` 中配置的 `PORT_NAV`)
		- 打开此页面即可看到 JupyterLab, VSCode, Gitea, MLflow 等所有服务的快捷入口。
	- **直接访问**:
		- JupyterLab: `http://localhost:8888`
		- VSCode: `http://localhost:8081`
		- Streamlit: `http://localhost:8501`



## 4\. 工作流示例 (Workflow Walkthrough)

以下操作均在 **Workspace 容器内部** 执行。请先进入容器：

```bash
docker exec -it mlops-workspace-user1 bash
```

### 场景 1: 代码版本管理 (Gitea)

```bash
# 1. 配置 Git
git config --global user.email "user1@mlops.local"
git config --global user.name "User 1"

# 2. 克隆/推送
# 注意：使用 Infra 的容器名 "mlops-gitea" 进行内部通信
git clone http://mlops-gitea:3000/your_username/my-project.git
cd my-project
echo "print('Hello')" > main.py
git add . && git commit -m "init"
git push
```

### 场景 2: 代码与数据协同 (DVC)

```bash
dvc init
# 配置 MinIO (使用容器名 mlops-minio)
dvc remote add -d myremote s3://dvc/my-project
dvc remote modify myremote endpointurl http://mlops-minio:9000
dvc remote modify myremote access_key_id minioadmin
dvc remote modify myremote secret_access_key minioadmin

dvc add data/raw.csv
dvc push
git add data/raw.csv.dvc .gitignore
git commit -m "Add data" && git push
```

### 场景 3: Prefect 流程编排

无需额外配置，环境变量 `PREFECT_API_URL` 已自动指向 `http://mlops-prefect:4200/api` 。

```python
from prefect import flow, task

@task
def process():
    return "Done"

@flow
def my_flow():
    process()

if __name__ == "__main__":
    my_flow() # 运行结果会自动上报到 Prefect Server
```

### 场景 4: 特征工程 (Feast)

配置 Feast 连接到共享的基础设施。

1. **初始化**:
	```bash
	feast init feature_repo && cd feature_repo
	```
2. **修改 `feature_store.yaml`**:**关键**: `host` 必须指向 Infra 网络中的容器名。
	```yaml
	project: feature_repo
	registry: data/registry.db
	provider: local
	online_store:
	    type: redis
	    connection_string: "mlops-redis:6379"  # 使用容器名
	offline_store:
	    type: postgres
	    host: mlops-postgres               # 使用容器名
	    port: 5432
	    database: postgres
	    user: admin
	    password: secure_pg_password
	```
3. **应用与同步**:
	```bash
	feast apply
	feast materialize-incremental $(date -u +"%Y-%m-%dT%H:%M:%S")
	```

### 场景 5: CI/CD 自动化

在 Gitea 仓库中创建 `.gitea/workflows/ci.yaml` ：

```yaml
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-python@v4
        with:
          python-version: '3.12'
      - run: pip install pytest
      - run: pytest
```

## 5\. 故障排查

- **Workspace 无法连接 MinIO/Gitea**: 检查是否创建了 `mlops-shared-net` 网络，并确保 `docker-compose.workspace.yml` 中 `external: true` 配置正确。
- **权限错误**: 容器启动时会自动修复 `/home/jovyan/work` 的权限。如果手动挂载了其他目录，请确保宿主机目录权限为 `1000:1000` 。
- **GPU 不可用**: 确保宿主机安装了 NVIDIA Container Toolkit，并在启动 Workspace 时正确传递了 GPU 资源配置。
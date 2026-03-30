# Patroni PostgreSQL 高可用集群 - 自动扩缩容解决方案

## 项目概述

本项目提供在 Google Cloud Platform 上实现 PostgreSQL 高可用集群**零停机自动扩缩容**的解决方案，基于 **Patroni** 和 **Raft 共识协议**。

### 核心特性

- **零停机扩缩容**：增减节点不影响服务
- **Scale-Out 不触发 Failover**：新增节点时现有节点保持角色不变
- **Raft 共识**：无需外部 DCS（分布式配置存储）
- **私网部署**：所有节点仅使用内网 IP，通过 Cloud NAT 出站
- **负载均衡集成**：公网 IP 始终指向当前 Leader

---

## 架构图

```
                         ┌─────────────────────────────────────┐
                         │         GCP 外部负载均衡器            │
                         │   (pg-external-forwarding-rule)      │
                         │         端口 5432 → Leader           │
                         └──────────────┬──────────────────────┘
                                        │ 34.x.x.x (静态公网IP)
                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          pg-ha-vpc (自定义 VPC)                          │
│  ┌──────────────┐                                                       │
│  │  Cloud NAT   │◄──── 出站 (更新、apt、pip)                            │
│  └──────┬───────┘                                                       │
│         │                                                                │
│  ┌──────┴───────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │  pg-subnet-1 │  │  pg-subnet-2 │  │  pg-subnet-3 │                   │
│  │ 192.168.1.0/24│  │ 192.168.2.0/24│  │ 192.168.3.0/24│                   │
│  │              │  │              │  │              │                   │
│  │ pg-node-1    │  │ pg-node-2    │  │ pg-node-3    │                   │
│  │ (LEADER)     │  │ (REPLICA)    │  │ (REPLICA)    │                   │
│  │ 192.168.1.10 │  │ 192.168.2.10 │  │ 192.168.3.10 │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                   │
│         │                                                       Cloud Router
└─────────┼───────────────────────────────────────────────────────────────┘
          │
          │ 更多子网: pg-subnet-4 (192.168.4.0/24), pg-subnet-5 (192.168.5.0/24)
          │ 更多节点: pg-node-4, pg-node-5, ... 最多 pg-node-10
          │
```

### 组件说明

| 组件 | 说明 |
|------|------|
| **Patroni** | 基于 Raft 的 PostgreSQL 高可用解决方案 |
| **Raft** | 用于 Leader 选举的分布式共识协议 |
| **Cloud NAT** | 为私网实例提供出站互联网访问 |
| **外部负载均衡器** | 将 PostgreSQL 流量路由到当前 Leader |
| **目标池** | 经过健康检查的 VM 实例组 |

### 网络端口

| 端口 | 服务 | 访问范围 |
|------|------|----------|
| 5432 | PostgreSQL | 内网 + 外部负载均衡器 |
| 8008 | Patroni REST API | 内网（健康检查）|
| 2222 | Raft | 仅内网 |
| 22 | SSH | 仅通过 IAP 隧道 |

---

## 部署

### 前置条件

1. **GCP 项目**已启用计费
2. **gcloud CLI** 已认证 (`gcloud auth login`)
3. **Terraform** >= 1.0 已安装
4. **SSH 密钥对**（可选，用于 VM 访问）

### 配置步骤

1. 复制并配置 Terraform 变量文件：

```bash
cp terraform.tfvars.example terraform.tfvars
```

编辑 `terraform.tfvars`：

```hcl
project_id         = "your-gcp-project-id"
region             = "asia-northeast1"
pg_password        = "your-secure-password"
node_count         = 3
machine_type       = "e2-standard-2"
```

2. 配置扩缩容脚本：

编辑 `scripts/patroni-scale.sh`：

```bash
PROJECT_ID="your-gcp-project-id"
PG_PASSWORD="your-secure-password"
```

### 部署步骤

```bash
# 初始化 Terraform
terraform init

# 规划部署
terraform plan -out=tfplan

# 执行部署
terraform apply -auto-approve

# 验证集群状态
./scripts/patroni-scale.sh status
```

---

## 运维操作

### 扩容（新增节点）

```bash
# 添加单个节点
./scripts/patroni-scale.sh add 1

# 添加多个节点
./scripts/patroni-scale.sh add 3

# 查看状态
./scripts/patroni-scale.sh status
./scripts/patroni-scale.sh check
```

新节点通过 Raft 作为**副本**加入，现有节点保持角色不变。

### 缩容（删除节点）

```bash
# 删除副本节点
./scripts/patroni-scale.sh remove 5

# 查看状态
./scripts/patroni-scale.sh status
```

**限制条件**：
- 不能删除 Leader 节点
- 不能低于最小节点数 (3)
- 并发删除操作会被锁阻塞

### 健康检查

```bash
./scripts/patroni-scale.sh check
```

---

## 文件结构

```
pg_autoscale/
├── main.tf              # VPC、子网、NAT、防火墙、密钥管理
├── compute.tf           # VM 实例、负载均衡器、目标池
├── variables.tf         # 输入变量
├── outputs.tf           # Terraform 输出
├── terraform.tfvars     # 配置（已 gitignored）
├── scripts/
│   ├── patroni-scale.sh     # 自动扩缩容脚本
│   ├── startup.tpl          # Terraform 初始部署启动脚本
│   └── startup-scaling.tpl  # 扩缩容（添加节点）启动模板
└── docs/
    ├── README.md            # 英文文档
    ├── README_CN.md         # 中文文档
    └── OPERATIONS.md        # 详细运维手册
```

---

## 安全特性

- **无公网 IP**：所有 VM 实例使用 `--no-address` 标志
- **Cloud NAT**：仅出站互联网访问
- **防火墙规则**：仅允许内网 (192.168.0.0/16) 和负载均衡器健康检查
- **IAP**：SSH 访问仅通过 Identity-Aware Proxy
- **密钥管理**：PostgreSQL 密码存储在 GCP Secret Manager

---

## 故障排查

### 节点无法加入集群

1. 检查节点是否运行：
   ```bash
   gcloud compute instances list --filter="name~pg-node"
   ```

2. 查看串口输出：
   ```bash
   gcloud compute instances get-serial-port-output pg-node-X --zone=ZONE
   ```

3. 验证节点间网络连通性

### Leader 选举异常

1. 检查 Raft 连接：
   ```bash
   # SSH 到节点执行
   patronictl -c /etc/patroni/patroni.yml list
   ```

2. 确保至少大多数节点健康

### 扩容失败

1. 检查 VPC 网络是否存在：
   ```bash
   gcloud compute networks describe pg-ha-vpc
   ```

2. 验证子网容量（当前配置最多 10 节点）

---

## License

MIT License

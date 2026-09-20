# Mac 本地 Kubernetes + Spark · 一键部署与验收

在本地 Mac 上启动最小化单节点 Kubernetes，并部署一个 Spark 容器。提供三个可独立执行的 Shell 脚本，以及能触发真实脚本、展示日志和退出码的本地网页验收控制台。

**已实测：macOS 14.4.1 / Apple Silicon（arm64）。** 实测覆盖环境重建、部署、实际 SparkPi 计算、重复执行、停服检测和恢复。Intel Mac 尚未实测。历史记录见 [测试报告](docs/TEST-REPORT.md)。

## 题目要求与实现

| 题目要求 | 入口 | 成功判据 |
| --- | --- | --- |
| 一键拉起 Kubernetes | `01-start-k8s.sh` | 节点 Ready、CoreDNS rollout 成功，输出 `K8S_READY` |
| 一键拉起 Spark | `02-start-spark.sh` | 应用清单、等待 Deployment 就绪，再调用计算检测 |
| 探测 Spark 就绪 | `03-check-spark.sh` | Master ALIVE、Worker 注册、SparkPi 实际完成，输出 `SPARK_READY` |

## 运行架构

```text
Mac
 └─ Lima Linux VM：2 CPU / 4 GiB RAM / 12 GiB 稀疏磁盘
     └─ K3s 单节点 Kubernetes（自带 containerd）
         └─ spark-demo namespace
             └─ Spark Deployment：1 Pod / 1 容器
                 ├─ Standalone Master
                 └─ Worker → executor 执行 SparkPi
```

选择 K3s 减少本机依赖和集群组件；关闭 Traefik、ServiceLB 和 metrics-server。Lima 提供 Mac 上运行 Linux 容器需要的虚拟机。

这是 **Kubernetes 托管 Spark Standalone**，不是 Spark 原生 Kubernetes scheduler；单容器同时运行 Master 和 Worker 是本题的最小演示方案，不是生产高可用架构。

## 环境要求

- macOS 13+，可用的硬件虚拟化；仅 macOS 14.4.1 / arm64 有实测记录。
- 可分配 2 CPU、4 GiB RAM；建议主机至少 8 GiB RAM，并预留至少 12 GiB 磁盘空间及下载缓存空间。
- macOS 自带 Bash、curl、tar、shasum、OpenSSH。
- 可以访问 GitHub、Ubuntu Cloud Images、Ubuntu 软件源、get.k3s.io 和 Docker Hub。
- 不依赖 Docker Desktop、Homebrew、宿主机 kubectl 或宿主机 Java。
- **仅网页控制台需要 Ruby + WEBrick**。本机已验证系统 Ruby 2.6 自带 WEBrick；其他 Ruby 版本可能需要安装该 gem。

固定版本：Lima 2.2.0、Ubuntu 24.04 minimal（20260716）、K3s v1.37.0+k3s1、Spark 3.5.9 / Scala 2.12 / Java 17。Lima 与 Ubuntu 镜像校验 SHA-256；Spark 固定 tag，未固定 digest。

## 快速开始：命令行

使用下面的仓库地址克隆。私有仓库要求访问者已经登录且获得仓库权限。

```bash
git clone https://github.com/sunzongyao85-pixel/mac-k8s-spark.git
cd mac-k8s-spark
chmod +x 01-start-k8s.sh 02-start-spark.sh 03-check-spark.sh start-console.command tests/contract.sh

./01-start-k8s.sh && ./02-start-spark.sh && ./03-check-spark.sh
```

没有 Git 时，也可以选择 **Code → Download ZIP**，解压并进入项目根目录，再从 `chmod` 那行执行。首次执行下载依赖与镜像，耗时受网络影响；重复运行复用已有 VM 和 Kubernetes 资源。

第二个脚本部署后已经调用第三个脚本；最后再执行第三个脚本是演示独立检测能力。

### 输入、输出与退出码

三个脚本均不需要参数，支持 `--help`。

| 脚本 | 前置状态 | stdout 成功输出 | 退出码 |
| --- | --- | --- | --- |
| `01-start-k8s.sh` | 无集群亦可 | `K8S_READY instance=spark-k3s` | 成功 0；执行失败 1；参数错误 2 |
| `02-start-spark.sh` | 01 已成功 | `SPARK_READY namespace=spark-demo deployment=spark`，以及 Pi 结果 | 同上 |
| `03-check-spark.sh` | Spark 已部署 | 同上；重新提交一次真实 SparkPi | 同上 |

进度及诊断写入 stderr；成功标志仅在检查通过后写入 stdout。示例：

```text
SPARK_READY namespace=spark-demo deployment=spark
Pi is roughly 3.142051142051142
```

Pi 数值随随机采样变化，不要求每次一致。验证退出码时，请紧跟脚本执行 `echo $?`，中间不要插入其他命令：

```bash
./03-check-spark.sh
echo "退出码=$?"
```

### 就绪检测为何可信

1. Kubernetes 启动与 readiness 探针检查 Spark 服务；readiness 还检查 Worker 注册。
2. 脚本检查 Deployment rollout、Master 状态和 Worker 状态。
3. 向 `spark://<Pod IP>:7077` 提交 SparkPi，由 Worker 的 executor 实际执行，检查退出码和 Pi 输出。

没有以 `sleep`、容器存在或单纯打印成功标志替代计算验证。容器父进程监督 Master 与 Worker，子进程退出会导致容器退出，交由 Kubernetes 重启。

## 网页验收

在项目根目录执行，或在 Finder 中双击 `start-console.command`：

```bash
./start-console.command
```

保持该终端运行，浏览器打开 **http://127.0.0.1:8765**。

页面提供：

- **准备并启动环境**：检查 Mac，实际调用 01 脚本。
- **一键启动并验收**：依次启动 Kubernetes、部署 Spark、独立检测、查询节点和 Pod；失败则停止后续步骤。
- **逐项执行**：单独触发每个脚本，查看具体 Shell 命令、实时输出、退出码、耗时和步骤结果。
- **停服并验证失败**：确认后把本项目 Spark 缩容至 0，验证检测退出码为 1。
- **恢复 Spark**：重新部署并执行计算检查。
- **导出记录**：下载本轮 JSON 记录；后端同时保存至 `evidence/ui-runs/`（已忽略，不提交到 Git）。

阶段文字由真实日志驱动，页面每 1.2 秒刷新；不使用模拟百分比。控制台仅绑定本机回环地址，并只允许预定义命令，不能从页面传入任意 Shell。一次只执行一个任务；关闭网页不会中断后端命令，请等待任务结束后再用 Ctrl+C 关闭控制台服务。

直接双击 `console/index.html` 无法运行命令；GitHub Pages 也不能操作访问者本机的集群。必须通过本地 Ruby 服务使用。

默认端口被占用时：

```bash
ACCEPTANCE_PORT=8766 ./start-console.command
# 然后打开 http://127.0.0.1:8766
```

若启动器提示缺少 Ruby，请使用已安装的 Ruby 运行环境；若提示缺少 WEBrick，可在该 Ruby 环境执行 `gem install --user-install webrick`。三个 Shell 入口本身不依赖 Ruby。

## 建议面试官执行的验收步骤

先依次运行三个脚本，确认均退出 0，再在同一终端定义便捷函数：

```bash
export LIMA_HOME="${LIMA_HOME:-$HOME/.lima-mac-spark}"
k() { ./.tools/bin/limactl shell spark-k3s sudo k3s kubectl "$@"; }
k get nodes
k -n spark-demo get pods
```

预期节点为 `Ready`，Spark 为 `1/1 Running`。

验证停服不会误报就绪（会暂时停止本项目 Spark）：

```bash
k -n spark-demo scale deployment/spark --replicas=0
k -n spark-demo wait --for=delete pod -l app=spark --timeout=60s
./03-check-spark.sh
echo "退出码=$?"
```

预期退出 1，stdout 没有 `SPARK_READY`。此时大量失败诊断是预期行为。

恢复并验证重复执行：

```bash
./02-start-spark.sh
./01-start-k8s.sh && ./02-start-spark.sh && ./03-check-spark.sh
```

预期恢复成功，再次计算得到 Pi，重复运行不会新建第二个集群。以上操作也可以全部通过网页按钮完成。

## 文件结构

```text
01-start-k8s.sh           Kubernetes 启动入口
02-start-spark.sh         Spark 部署入口
03-check-spark.sh         独立就绪与计算检测
start-console.command    本地网页启动器
scripts/common.sh        路径、日志与 kubectl 共享函数
config/lima.yaml         Linux VM 与 K3s 安装配置
manifests/spark.yaml     Namespace / Deployment / Service
console/                 本地网页与 Ruby 后端
docs/                    历史验收记录
evidence/                选取的实际 stdout 与退出码
tests/contract.sh        18 项模拟输入输出契约检查
```

## 存储、日志与清理

Lima 二进制安装在项目 `.tools/`；VM、磁盘和 SSH 密钥位于 `~/.lima-mac-spark/`，镜像缓存由 Lima 管理。VM 不挂载宿主机目录，脚本不修改宿主机 kubeconfig。可通过 `LIMA_HOME` 改为其他较短目录，三个脚本及控制台必须使用一致的值。同一个 LIMA_HOME 中复用 `spark-k3s` 实例。

查看日志与 Spark UI：

```bash
export LIMA_HOME="${LIMA_HOME:-$HOME/.lima-mac-spark}"
.tools/bin/limactl shell spark-k3s sudo k3s kubectl -n spark-demo logs deployment/spark --tail=100
.tools/bin/limactl shell spark-k3s sudo k3s kubectl -n spark-demo port-forward --address 0.0.0.0 service/spark 8080:8080
```

最后一条保持运行，打开 http://127.0.0.1:8080 。`0.0.0.0` 是 VM 内的监听地址，Lima 默认向本机回环地址转发。Master RPC 没有通过 Service 暴露。

停止 VM 并保留数据：

```bash
LIMA_HOME="${LIMA_HOME:-$HOME/.lima-mac-spark}" .tools/bin/limactl stop spark-k3s
```

删除演示 VM 和全部集群数据（不可恢复）：

```bash
LIMA_HOME="${LIMA_HOME:-$HOME/.lima-mac-spark}" .tools/bin/limactl delete --force spark-k3s
```

## 常见问题与边界

| 情况 | 排查方式 |
| --- | --- |
| `Virtualization is not available on this hardware` | 在系统终端执行 `sysctl kern.hv_support`；需要返回 1。受限沙箱或嵌套 VM 可能不提供虚拟化能力。 |
| `ImagePullBackOff` / 下载超时 | 检查外部镜像站网络、代理和 DNS；用 kubectl describe / events 查看原因。 |
| `Permission denied` | 执行快速开始中的 chmod；不要把整个项目以 sudo 运行。 |
| Spark 未就绪 | 查看脚本输出的 Pod、事件与容器日志；核对资源是否足够。 |
| 网页显示未连接 | 确认 Ruby 服务在运行，并使用 localhost HTTP 地址而非直接打开 HTML。 |
| 首次启动较慢 | 需要下载 VM 镜像、K3s 与 Spark 镜像；观察实时日志，重复执行可复用缓存。 |

VM 启动等待上限 15 分钟；Spark 部署等待 10 分钟；独立检测 rollout 等待 2 分钟、SparkPi 运行上限 2 分钟。网络和诊断有额外耗时，以上不是脚本总耗时保证。网页对每条命令设 30 分钟硬超时。

单机演示通过不等于所有 Mac、所有网络或生产负载均通过。Intel、完整主机重启后的恢复及长期稳定性尚未验证；没有宣称这些范围已经通过。

## 开发检查

```bash
bash -n 01-start-k8s.sh 02-start-spark.sh 03-check-spark.sh scripts/common.sh tests/contract.sh
./tests/contract.sh
ruby -c console/server.rb
```

契约检查使用假的 Lima，不会创建集群，不能替代真实验收。真实测试细节见 [TEST-REPORT](docs/TEST-REPORT.md)。

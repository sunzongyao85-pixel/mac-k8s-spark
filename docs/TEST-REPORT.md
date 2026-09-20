# 本机实际验收记录

2026-09-20，macOS 14.4.1，Apple Silicon arm64，16 GiB 内存。初始未安装 Docker、Homebrew、kubectl 或 Lima。

**结果：真实 Kubernetes、Spark 部署与计算验证通过。本报告记录本机测试，仓库发布不等于新增平台验证。**

## 环境

- Lima 2.2.0 / Apple Virtualization.framework，2 CPU / 4 GiB 内存 / 12 GiB 稀疏磁盘。
- Ubuntu 24.04.4 LTS arm64，K3s v1.37.0+k3s1，containerd 2.3.4-k3s1。
- Spark 3.5.9 / Scala 2.12 / Java 17，一个 Pod、一个容器，容器内运行 Master + Worker。

## 验收结果

| 测试 | 实际结果 |
| --- | --- |
| 自动下载 Lima 与 SHA-256 校验 | 通过，移走项目 .tools 后由 01 脚本重新安装 |
| 新建 VM、安装 K3s、等待节点与 CoreDNS | 通过，删除本测试创建的旧 VM 后重新运行 01；Ubuntu 下载缓存被复用 |
| 一键部署 Spark | 通过，镜像重新拉取，Pod 1/1 Ready |
| 独立就绪检测 | 通过，Master ALIVE、Worker 注册、SparkPi 完成 |
| 重复执行 01 / 02 / 03 | 通过，复用 VM 与资源，无重复集群 |
| 缩容到 0 后检测 | 退出 1，无 SPARK_READY 成功标志 |
| 重新运行 02 恢复 | 通过，Pod 恢复并再次完成 SparkPi |
| Spark UI | 本机 HTTP 8080 返回 JSON：MASTER_STATUS=ALIVE，ALIVE_WORKERS=1，COMPLETED_APPS=2 |
| Bash、Lima 配置、YAML 与 18 项模拟契约检查 | 通过；仅作为真实运行的补充 |

## 三个入口的实际 stdout

`01-start-k8s.sh`，退出 0：

```text
K8S_READY instance=spark-k3s
```

`02-start-spark.sh`，退出 0：

```text
SPARK_READY namespace=spark-demo deployment=spark
Pi is roughly 3.1399231399231398
```

`03-check-spark.sh`，退出 0：

```text
SPARK_READY namespace=spark-demo deployment=spark
Pi is roughly 3.142051142051142
```

SparkPi 使用 Standalone Master 调度到 Worker 的 executor 执行，未使用 local 模式；Pi 结果随随机采样变化。选取的 stdout 与退出码保存在 [evidence/](../evidence/)。

## 实测修复

1. 首次启动时 CoreDNS 资源尚未创建：先等待资源创建，再等待 rollout。
2. 继承的宿主机 HTTP 代理干扰 API server 到 kubelet 的日志/exec 请求：安装时加入节点、Pod、Service 网段与集群域名的 NO_PROXY。
3. Spark 原先监听回环地址：Master 改用 Pod IP，UI 使用默认全接口监听，让 Kubernetes 探针与端口转发均可访问。
4. 开启 Bash ERR trap 继承，并限制无 Pod 时 exec/logs 的等待时间，让错误检测输出诊断并非零退出。

## 验证范围

最初沙箱限制导致 `Virtualization is not available on this hardware`。权限切换后，`kern.hv_support: 1`，虚拟机启动成功，已解除该阻塞。项目需在允许本地虚拟化的环境运行。

Intel Mac、生产负载、长时间稳定性及完整 Mac 重启后恢复未验证。报告记录测试当时的状态，不承诺当前状态；停止与清理命令见根目录 README。

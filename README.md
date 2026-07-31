# Synology acme.sh Auto-Deploy 🚀

这是一个专为群晖 (Synology) NAS 打造的，基于 Docker 版 `acme.sh` 的全自动 SSL 证书申请、续签与部署脚本。

通过将**核心逻辑代码**与**配置变量**彻底分离，并引入智能状态判断与容错回退机制，让群晖的证书管理变得前所未有的安全、简单和健壮。

## ✨ 核心特性

- **代码与配置完全分离**：主逻辑脚本 (`acme.sh`) 与配置文件 (`config.conf`) 物理隔离。更新脚本不再担心配置丢失，配置敏感信息也可独立设置严格的读写权限以确保安全。
- **智能自适应 Issue / Renew**：告别无脑 `--issue` 导致的强制覆盖报错死循环。脚本会自动检查内部记录，无记录则全新申请，有记录则智能续签并由 acme.sh 自动接管 30 天续期判定。
- **环境预检防患于未然 (Pre-flight Check)**：脚本执行前自动检测指定的 Docker 容器是否处于运行状态，防止产生冗长复杂的底层报错。
- **智能路径容错回退 (Graceful Fallback)**：极具鲁棒性的寻址机制。优先寻找 `config/config.conf`，若缺失则自动回退寻找同级目录的 `config.conf`，并输出友好的容错日志。
- **原生支持多域名复用**：只需维护一份核心代码！通过传入不同的配置文件参数，即可在群晖计划任务中无限扩展多域名管理，日志集中统一。

## 📂 推荐目录结构

建议在群晖中建立如下结构（例如放在 `/volume1/docker/acme.sh/auto/` 下）：

```text
auto/
 ├── acme.sh           <-- 永远不需要再改动的核心脚本
 ├── acmelog.txt       <-- 所有的运行日志统一输出到此处
 └── config/           <-- 专门存放配置文件的文件夹 (推荐)
      ├── config.conf
      ├── config_aaa.conf
      └── config_bbb.conf
```

## 🛠️ 前置准备

1. 确保群晖上已安装 Docker (Container Manager)。
2. 确保群晖后台已经有一个名为 `acme.sh` (可在配置文件中自定义) 的守护型容器正在常驻运行。
3. 你的群晖账户具备修改证书的权限。

## 🚀 快速上手

### 1. 准备配置文件
将本项目中的 `config.conf` 模板放入 `config` 文件夹中。
根据文件内的详尽注释，填入你的：
- Docker 容器名称 (`ACME_CONTAINER_NAME`)
- 域名 (`DOMAIN`)
- DNS 服务商 API Token (如 Cloudflare, DNSPod, 阿里云)
- 群晖账号、密码、Device_ID 等部署信息

### 2. 在群晖中设置计划任务
登录群晖 DSM：**控制面板 -> 任务计划 -> 新增 -> 计划的任务 -> 用户定义的脚本**。
建议将运行频率设置为：**每月运行一次**（例如每月 1 日凌晨 2 点）。

在“任务设置” -> “运行命令”面板中，根据你的使用场景填入以下命令：

#### 场景一：单域名默认执行
如果不加任何参数，脚本会自动去 `config` 文件夹下寻找 `config.conf`，找不到则回退寻找脚本同目录下的 `config.conf`。
```bash
bash /volume1/docker/acme.sh/auto/acme.sh >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
```

#### 场景二：多域名复用执行 (高级)
如果你有多个域名，请在 `config` 文件夹下复制多份配置文件（如 `config_aaa.conf`, `config_bbb.conf`），在计划任务中分多行执行并指定配置文件的绝对路径：
```bash
bash /volume1/docker/acme.sh/auto/acme.sh /volume1/docker/acme.sh/auto/config/config_aaa.conf >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
bash /volume1/docker/acme.sh/auto/acme.sh /volume1/docker/acme.sh/auto/config/config_bbb.conf >>/volume1/docker/acme.sh/auto/acmelog.txt 2>&1
```

## 📝 日志查看

得益于详尽的日志输出设计，你可以随时打开 `acmelog.txt` 像看流水账一样查看任务执行情况：
- 如果证书有效且剩余天数大于 30 天，你将看到：“⏳ 当前证书有效期依然充足，acme.sh 自动跳过更新。”
- 如果发生了路径容错，你将看到：“⚠️ 提示: 未在 config 目录找到配置文件，已智能回退...”
- 如果容器没有启动，你将看到：“❌ 致命错误: 找不到名为 'acme.sh' 的容器...”

## ⚠️ 常见问题
**Q: 执行后提示需要 `--force` 或 `--renew`，并且报错退出了？**
A: 本脚本已经彻底重构了判断逻辑，极大概率不会出现此问题。如果你是从旧版本脚本迁移过来的，通常是因为之前错误操作遗留了废弃的域名文件夹。请手动进入 Docker 容器，执行 `--remove -d 你的域名` 彻底清除旧记录后再次运行本脚本即可。
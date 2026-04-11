# OpenClaw 一键部署脚本

## 一条命令安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/openclaw/install.sh)"
```

## 功能特性

✅ **跨平台支持**: Linux / macOS / Windows(WSL)
✅ **自动检测安装Docker**: 如未安装可选择自动安装
✅ **交互式配置**: 数据目录、AI模型、API密钥
✅ **GitHub备份还原**: 记忆、技能、插件、配置文件云端同步
✅ **一键更新**: 镜像更新、配置备份、容器管理

## 使用方法

### 首次安装
1. 运行安装脚本
2. 选择"1) 全新安装"
3. 按提示配置数据目录、AI模型、GitHub备份
4. 自动启动容器

### 从GitHub还原
1. 运行安装脚本
2. 选择"2) 从GitHub还原配置"
3. 输入GitHub Token和仓库地址
4. 自动拉取配置并启动

### 备份到GitHub
1. 运行安装脚本
2. 选择"3) 备份当前配置到GitHub"
3. 自动推送配置到云端

## 配置文件说明

| 文件 | 说明 |
|------|------|
| workspace/MEMORY.md | 长期记忆 |
| workspace/HEARTBEAT.md | 定时任务 |
| workspace/AGENTS.md | 工作规则 |
| skills/ | 自定义技能 |
| plugins/ | 插件配置 |
| openclaw.json | 核心配置 |

## GitHub Token权限

需要以下权限：
- `repo` (完整仓库访问)

## 支持的模型提供商

1. OpenAI (GPT-4/3.5)
2. Claude (Anthropic)
3. 火山引擎 (豆包)
4. 讯飞星辰
5. 自定义

---

基于官方镜像: `ghcr.io/openclaw/openclaw:latest`

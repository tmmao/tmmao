#!/bin/bash
# OpenClaw 一键部署脚本
# 支持 Linux/macOS/Windows(WSL) 一键安装、配置、备份、还原
# 用法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/tmmao/openclaw-backup/main/install.sh)"

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest"
CONTAINER_NAME="openclaw"
DEFAULT_DATA_DIR="$HOME/.openclaw"
GITHUB_REPO="tmmao/openclaw-backup"
GITHUB_BRANCH="main"

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 检测操作系统
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "Linux";;
        Darwin*)    echo "macOS";;
        CYGWIN*)    echo "Windows";;
        MINGW*)     echo "Windows";;
        *)          echo "Unknown";;
    esac
}

# 检测Docker是否安装
check_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        return 0
    else
        return 1
    fi
}

# 安装Docker
install_docker() {
    log_step "正在安装 Docker..."
    
    local os=$(detect_os)
    
    case $os in
        Linux)
            # 使用官方安装脚本
            curl -fsSL https://get.docker.com | sh
            # 启动Docker服务
            sudo systemctl start docker
            sudo systemctl enable docker
            # 添加当前用户到docker组
            sudo usermod -aG docker $USER
            log_info "Docker 安装完成，请重新登录以应用权限"
            ;;
        macOS)
            log_warn "macOS 请手动安装 Docker Desktop: https://www.docker.com/products/docker-desktop"
            exit 1
            ;;
        Windows)
            log_warn "Windows 请手动安装 Docker Desktop: https://www.docker.com/products/docker-desktop"
            exit 1
            ;;
        *)
            log_error "不支持的操作系统: $os"
            exit 1
            ;;
    esac
}

# 拉取镜像
pull_image() {
    log_step "正在拉取 OpenClaw 镜像: $OPENCLAW_IMAGE"
    docker pull $OPENCLAW_IMAGE
    log_info "镜像拉取完成"
}

# 配置数据目录
configure_data_dir() {
    log_step "配置数据存储目录"
    echo -e "默认目录: ${YELLOW}$DEFAULT_DATA_DIR${NC}"
    read -p "使用默认目录? (y/n): " use_default
    
    if [[ $use_default == "y" || $use_default == "Y" ]]; then
        DATA_DIR=$DEFAULT_DATA_DIR
    else
        read -p "请输入自定义目录路径: " DATA_DIR
        DATA_DIR="${DATA_DIR/#\~/$HOME}"  # 替换 ~ 为 $HOME
    fi
    
    mkdir -p "$DATA_DIR"/{workspace,skills,plugins}
    log_info "数据目录: $DATA_DIR"
}

# 配置AI模型
configure_model() {
    log_step "配置 AI 模型和 API 密钥"
    
    echo -e "\n支持的模型提供商:"
    echo "1) OpenAI (GPT-4/3.5)"
    echo "2) Claude (Anthropic)"
    echo "3) 火山引擎 (豆包)"
    echo "4) 讯飞星辰"
    echo "5) 自定义"
    read -p "请选择模型提供商 (1-5): " provider_choice
    
    case $provider_choice in
        1)
            PROVIDER="openai"
            read -p "请输入 OpenAI API Key: " API_KEY
            MODEL="gpt-4"
            ;;
        2)
            PROVIDER="anthropic"
            read -p "请输入 Anthropic API Key: " API_KEY
            MODEL="claude-3-opus-20240229"
            ;;
        3)
            PROVIDER="volcengine-ark"
            read -p "请输入火山引擎 API Key: " API_KEY
            MODEL="doubao-seed-2-0-pro-260215"
            ;;
        4)
            PROVIDER="astroncodingplan"
            read -p "请输入讯飞星辰 API Key: " API_KEY
            MODEL="astron-code-latest"
            ;;
        5)
            read -p "请输入 Provider: " PROVIDER
            read -p "请输入 API Key: " API_KEY
            read -p "请输入模型名称: " MODEL
            ;;
        *)
            log_warn "使用默认配置"
            PROVIDER="openai"
            API_KEY=""
            MODEL="gpt-4"
            ;;
    esac
    
    # 写入配置文件
    cat > "$DATA_DIR/openclaw.json" << EOF
{
  "providers": [
    {
      "name": "$PROVIDER",
      "apiKey": "$API_KEY",
      "models": [
        {
          "id": "$MODEL",
          "name": "$MODEL",
          "contextWindow": 128000
        }
      ]
    }
  ],
  "agents": {
    "defaults": {
      "model": "$PROVIDER/$MODEL"
    }
  }
}
EOF
    
    log_info "模型配置完成"
}

# GitHub备份配置
configure_github() {
    log_step "GitHub 备份配置"
    
    read -p "是否配置 GitHub 自动备份? (y/n): " enable_github
    
    if [[ $enable_github == "y" || $enable_github == "Y" ]]; then
        read -p "请输入 GitHub Token (需要repo权限): " GITHUB_TOKEN
        read -p "GitHub 仓库 (默认: $GITHUB_REPO): " custom_repo
        GITHUB_REPO="${custom_repo:-$GITHUB_REPO}"
        
        # 保存配置
        echo "GITHUB_TOKEN=$GITHUB_TOKEN" > "$DATA_DIR/.github_config"
        echo "GITHUB_REPO=$GITHUB_REPO" >> "$DATA_DIR/.github_config"
        
        log_info "GitHub 备份配置完成"
    fi
}

# 从GitHub还原配置
restore_from_github() {
    log_step "从 GitHub 还原配置"
    
    if [[ ! -f "$DATA_DIR/.github_config" ]]; then
        read -p "请输入 GitHub Token: " GITHUB_TOKEN
        read -p "GitHub 仓库 (默认: $GITHUB_REPO): " custom_repo
        GITHUB_REPO="${custom_repo:-$GITHUB_REPO}"
    else
        source "$DATA_DIR/.github_config"
    fi
    
    log_info "正在从 $GITHUB_REPO 拉取配置..."
    
    # 克隆仓库
    TEMP_DIR=$(mktemp -d)
    git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" "$TEMP_DIR" 2>/dev/null || {
        log_error "克隆仓库失败，请检查 Token 和仓库权限"
        return 1
    }
    
    # 还原文件
    cp -r "$TEMP_DIR/workspace/"* "$DATA_DIR/workspace/" 2>/dev/null || true
    cp -r "$TEMP_DIR/skills/"* "$DATA_DIR/skills/" 2>/dev/null || true
    cp -r "$TEMP_DIR/plugins/"* "$DATA_DIR/plugins/" 2>/dev/null || true
    cp "$TEMP_DIR/openclaw.json" "$DATA_DIR/" 2>/dev/null || true
    cp "$TEMP_DIR/MEMORY.md" "$DATA_DIR/workspace/" 2>/dev/null || true
    
    rm -rf "$TEMP_DIR"
    
    log_info "配置还原完成"
}

# 备份到GitHub
backup_to_github() {
    log_step "备份配置到 GitHub"
    
    if [[ ! -f "$DATA_DIR/.github_config" ]]; then
        log_error "请先配置 GitHub 备份"
        return 1
    fi
    
    source "$DATA_DIR/.github_config"
    
    TEMP_DIR=$(mktemp -d)
    
    # 复制文件
    cp -r "$DATA_DIR/workspace" "$TEMP_DIR/"
    cp -r "$DATA_DIR/skills" "$TEMP_DIR/"
    cp -r "$DATA_DIR/plugins" "$TEMP_DIR/"
    cp "$DATA_DIR/openclaw.json" "$TEMP_DIR/" 2>/dev/null || true
    
    # 创建README
    cat > "$TEMP_DIR/README.md" << EOF
# OpenClaw 配置备份

备份时间: $(date)

## 内容
- workspace/: 工作空间（记忆、配置）
- skills/: 自定义技能
- plugins/: 插件配置
- openclaw.json: 核心配置

## 还原
运行安装脚本并选择"从GitHub还原"选项即可
EOF
    
    # 推送到GitHub
    cd "$TEMP_DIR"
    git init
    git add .
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')"
    git branch -M $GITHUB_BRANCH
    git remote add origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
    git push -f origin $GITHUB_BRANCH
    
    rm -rf "$TEMP_DIR"
    
    log_info "备份完成: https://github.com/$GITHUB_REPO"
}

# 启动容器
start_container() {
    log_step "启动 OpenClaw 容器"
    
    # 检查是否已有容器
    if docker ps -a | grep -q $CONTAINER_NAME; then
        read -p "发现已存在的容器，是否删除并重新创建? (y/n): " recreate
        if [[ $recreate == "y" || $recreate == "Y" ]]; then
            docker rm -f $CONTAINER_NAME
        else
            docker start $CONTAINER_NAME
            log_info "容器已启动"
            return
        fi
    fi
    
    # 启动新容器
    docker run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        -p 18789:18789 \
        -v "$DATA_DIR:/root/.openclaw" \
        $OPENCLAW_IMAGE
    
    log_info "容器启动成功"
    log_info "访问地址: http://localhost:18789"
}

# 显示菜单
show_menu() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   OpenClaw 一键部署脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "1) 全新安装（推荐首次使用）"
    echo "2) 从 GitHub 还原配置"
    echo "3) 备份当前配置到 GitHub"
    echo "4) 更新镜像"
    echo "5) 查看容器状态"
    echo "6) 查看日志"
    echo "7) 停止容器"
    echo "8) 退出"
    echo -e "${GREEN}========================================${NC}"
}

# 主流程
main() {
    # 检测Docker
    if ! check_docker; then
        read -p "Docker 未安装，是否自动安装? (y/n): " install_docker_choice
        if [[ $install_docker_choice == "y" || $install_docker_choice == "Y" ]]; then
            install_docker
        else
            log_error "请先安装 Docker"
            exit 1
        fi
    fi
    
    # 交互式菜单
    while true; do
        show_menu
        read -p "请选择操作 (1-8): " choice
        
        case $choice in
            1)
                pull_image
                configure_data_dir
                configure_model
                configure_github
                start_container
                ;;
            2)
                configure_data_dir
                restore_from_github
                start_container
                ;;
            3)
                backup_to_github
                ;;
            4)
                pull_image
                docker restart $CONTAINER_NAME
                log_info "更新完成"
                ;;
            5)
                docker ps -a | grep $CONTAINER_NAME
                ;;
            6)
                docker logs --tail 50 $CONTAINER_NAME
                ;;
            7)
                docker stop $CONTAINER_NAME
                log_info "容器已停止"
                ;;
            8)
                log_info "再见!"
                exit 0
                ;;
            *)
                log_error "无效选择"
                ;;
        esac
    done
}

# 运行
main "$@"

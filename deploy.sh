#!/bin/bash
# OpenClaw Docker 一键部署与恢复脚本
# 项目地址: https://github.com/yourusername/openclaw-deploy
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/yourusername/openclaw-deploy/main/deploy.sh)"

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
IMAGE_NAME="1186258278/openclaw-zh:latest"
CONTAINER_NAME="openclaw"
DATA_DIR="/opt/openclaw-data"
BACKUP_DIR="${DATA_DIR}/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_step() {
    echo -e "\n${GREEN}>>>${NC} ${BLUE}$1${NC}"
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker未安装，正在自动安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker && systemctl start docker
        print_success "Docker安装完成"
    else
        print_info "Docker已安装: $(docker --version)"
    fi
}

# 创建必要目录
create_directories() {
    mkdir -p "${DATA_DIR}" "${BACKUP_DIR}"
    print_success "数据目录创建: ${DATA_DIR}"
}

# 获取局域网IP
get_lan_ip() {
    LAN_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [ -z "${LAN_IP}" ]; then
        LAN_IP="0.0.0.0"
    fi
    read -p "请输入局域网IP地址 [${LAN_IP}]: " input_ip
    LAN_IP=${input_ip:-${LAN_IP}}
    print_info "使用IP地址: ${LAN_IP}"
}

# 配置访问令牌
configure_token() {
    read -sp "请输入访问令牌 (留空则自动生成): " TOKEN
    echo
    if [ -z "${TOKEN}" ]; then
        TOKEN=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
        print_warning "自动生成令牌: ${TOKEN}"
    else
        print_info "使用自定义令牌"
    fi
}

# 配置AI模型
configure_ai() {
    echo -e "\n请选择AI模型:"
    echo "1) OpenAI GPT-4"
    echo "2) OpenAI GPT-3.5-Turbo"
    echo "3) Anthropic Claude"
    echo "4) 自定义模型"
    read -p "请选择 [1-4]: " model_choice

    case ${model_choice} in
        1) AI_MODEL="gpt-4" ;;
        2) AI_MODEL="gpt-3.5-turbo" ;;
        3) AI_MODEL="claude-3-opus" ;;
        4) read -p "请输入模型名称: " AI_MODEL ;;
        *) AI_MODEL="gpt-3.5-turbo"; print_warning "使用默认模型: ${AI_MODEL}" ;;
    esac

    read -p "请输入API密钥: " API_KEY
    if [ -z "${API_KEY}" ]; then
        print_error "API密钥不能为空"
        exit 1
    fi
    print_success "AI模型配置完成: ${AI_MODEL}"
}

# 生成环境变量文件
generate_env() {
    cat > "${DATA_DIR}/.env" << EOF
# OpenClaw 环境配置
# 生成时间: $(date)

# 网络配置
LAN_IP=${LAN_IP}
ACCESS_TOKEN=${TOKEN}

# AI配置
AI_MODEL=${AI_MODEL}
API_KEY=${API_KEY}

# 容器配置
CONTAINER_NAME=${CONTAINER_NAME}
DATA_DIR=${DATA_DIR}
EOF
    print_success "配置文件生成: ${DATA_DIR}/.env"
}

# 运行Docker容器
run_container() {
    # 停止并删除已存在的容器
    if docker ps -a --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        print_warning "停止并删除已存在的容器..."
        docker stop ${CONTAINER_NAME} >/dev/null 2>&1 || true
        docker rm ${CONTAINER_NAME} >/dev/null 2>&1 || true
    fi

    print_info "启动Docker容器..."
    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        -p ${LAN_IP}:8080:8080 \
        -v ${DATA_DIR}:/app/data \
        -e ACCESS_TOKEN="${TOKEN}" \
        -e AI_MODEL="${AI_MODEL}" \
        -e API_KEY="${API_KEY}" \
        ${IMAGE_NAME}

    if [ $? -eq 0 ]; then
        print_success "容器启动成功!"
        print_info "访问地址: http://${LAN_IP}:8080"
        print_info "访问令牌: ${TOKEN}"
    else
        print_error "容器启动失败"
        exit 1
    fi
}

# 创建备份
create_backup() {
    print_step "创建配置备份..."
    BACKUP_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz"
    
    if [ -f "${DATA_DIR}/.env" ]; then
        tar -czf "${BACKUP_FILE}" -C "${DATA_DIR}" .env 2>/dev/null
        print_success "备份创建成功: ${BACKUP_FILE}"
    else
        print_warning "无配置文件可备份"
    fi
}

# 列出可用备份
list_backups() {
    if [ -d "${BACKUP_DIR}" ] && [ "$(ls -A ${BACKUP_DIR})" ]; then
        echo -e "\n${BLUE}可用的备份文件:${NC}"
        ls -1 ${BACKUP_DIR}/backup_*.tar.gz 2>/dev/null | nl -w2 -s') '
    else
        print_error "没有找到任何备份文件"
        return 1
    fi
    return 0
}

# 恢复备份
restore_backup() {
    print_step "恢复配置备份"
    
    if ! list_backups; then
        return 1
    fi
    
    read -p "请选择要恢复的备份编号: " backup_num
    BACKUP_FILE=$(ls -1 ${BACKUP_DIR}/backup_*.tar.gz 2>/dev/null | sed -n "${backup_num}p")
    
    if [ -z "${BACKUP_FILE}" ]; then
        print_error "无效的选择"
        return 1
    fi
    
    # 临时解压备份
    TEMP_DIR=$(mktemp -d)
    tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"
    
    if [ -f "${TEMP_DIR}/.env" ]; then
        # 读取备份中的配置
        source "${TEMP_DIR}/.env"
        print_success "从备份恢复配置:"
        print_info "  IP地址: ${LAN_IP}"
        print_info "  AI模型: ${AI_MODEL}"
        
        # 复制配置文件
        cp "${TEMP_DIR}/.env" "${DATA_DIR}/.env"
        
        # 重新启动容器
        docker stop ${CONTAINER_NAME} >/dev/null 2>&1 || true
        docker rm ${CONTAINER_NAME} >/dev/null 2>&1 || true
        
        run_container
        print_success "恢复完成!"
    else
        print_error "备份文件无效，缺少.env配置"
        rm -rf "${TEMP_DIR}"
        return 1
    fi
    
    rm -rf "${TEMP_DIR}"
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${BLUE}   OpenClaw Docker 部署管理工具   ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo "1) 全新部署"
    echo "2) 恢复备份"
    echo "3) 查看状态"
    echo "4) 创建备份"
    echo "5) 退出"
    echo -e "${GREEN}================================${NC}"
    read -p "请选择操作 [1-5]: " choice
    
    case ${choice} in
        1) fresh_deploy ;;
        2) restore_deploy ;;
        3) check_status ;;
        4) create_backup ;;
        5) exit 0 ;;
        *) print_error "无效选择"; sleep 2; main_menu ;;
    esac
}

# 全新部署
fresh_deploy() {
    print_step "开始全新部署"
    check_docker
    create_directories
    get_lan_ip
    configure_token
    configure_ai
    generate_env
    run_container
    create_backup
    print_success "部署完成!"
    echo -e "\n${GREEN}重要信息:${NC}"
    echo "  访问地址: http://${LAN_IP}:8080"
    echo "  访问令牌: ${TOKEN}"
    echo "  数据目录: ${DATA_DIR}"
    echo "  备份目录: ${BACKUP_DIR}"
}

# 恢复部署
restore_deploy() {
    print_step "开始恢复部署"
    check_docker
    create_directories
    
    if restore_backup; then
        print_success "恢复部署完成"
    else
        print_error "恢复失败"
        read -p "是否进行全新部署? [y/N]: " choice
        if [[ ${choice} =~ ^[Yy]$ ]]; then
            fresh_deploy
        fi
    fi
}

# 查看状态
check_status() {
    print_step "容器状态"
    docker ps -a --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    if docker ps --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "\n${GREEN}容器运行正常${NC}"
        print_info "访问地址: http://${LAN_IP:-localhost}:8080"
        if [ -f "${DATA_DIR}/.env" ]; then
            source "${DATA_DIR}/.env"
            print_info "访问令牌: ${ACCESS_TOKEN:-未设置}"
        fi
    else
        print_warning "容器未运行"
    fi
    
    read -p "按回车返回主菜单"
    main_menu
}

# 检查是否以root运行
if [ "$EUID" -ne 0 ]; then 
    print_error "请以root权限运行此脚本"
    exit 1
fi

# 启动主菜单
main_menu
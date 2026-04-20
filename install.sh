#!/bin/bash
# restore.sh - OpenClaw 一键恢复脚本
# 用法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh)"

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查环境
check_env() {
    log "检查环境..."
    
    # 检查是否在容器内
    if [ -f /.dockerenv ]; then
        log "检测到 Docker 容器环境"
    fi
    
    # 检查 OpenClaw 目录
    if [ ! -d "/root/.openclaw" ]; then
        warn "OpenClaw 配置目录不存在，可能未安装"
    fi
    
    # 检查备份目录
    if [ ! -d "/root/.openclaw/backups" ]; then
        error "备份目录不存在: /root/.openclaw/backups"
    fi
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        warn "Docker 未安装，部分功能可能受限"
    fi
}

# 显示备份列表
list_backups() {
    local backup_dir="$1"
    
    if [ ! -d "$backup_dir" ]; then
        echo "无备份目录: $backup_dir"
        return
    fi
    
    echo "可用备份:"
    echo "----------------------------------------"
    
    # 每日备份
    if [ -d "$backup_dir/daily" ]; then
        echo "每日备份:"
        ls -lh "$backup_dir/daily"/*.tar.gz 2>/dev/null | awk '{print "  " $6, $7, $8, "->", $9}' || echo "  无"
    fi
    
    # 每月备份
    if [ -d "$backup_dir/monthly" ]; then
        echo "每月备份:"
        ls -lh "$backup_dir/monthly"/*_full.tar.gz 2>/dev/null | awk '{print "  " $6, $7, $8, "->", $9}' || echo "  无"
    fi
    
    # 最新备份
    if [ -d "$backup_dir/latest" ]; then
        echo "最新备份: $(ls -la $backup_dir/latest/ | wc -l) 个文件"
    fi
}

# 验证备份完整性
verify_backup() {
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        error "备份文件不存在: $backup_file"
    fi
    
    log "验证备份: $backup_file"
    
    # 检查 tar 文件完整性
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        error "备份文件损坏或格式错误"
    fi
    
    # 检查关键文件
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" --wildcards "*/config/openclaw.json" 2>/dev/null || true
    
    if [ -f "$temp_dir"/*/config/openclaw.json ]; then
        log "✓ 备份包含 openclaw.json"
    else
        warn "⚠ 备份可能不包含 openclaw.json"
    fi
    
    rm -rf "$temp_dir"
    log "备份验证通过"
}

# 恢复备份
restore_backup() {
    local backup_file="$1"
    local restore_type="$2"  # daily/monthly
    
    log "开始恢复: $(basename $backup_file)"
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    
    # 解压备份
    log "解压备份..."
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # 根据备份类型恢复
    if [ "$restore_type" = "daily" ]; then
        restore_daily "$temp_dir"
    elif [ "$restore_type" = "monthly" ]; then
        restore_monthly "$temp_dir"
    else
        # 自动检测
        if [ -d "$temp_dir"/*/config ]; then
            restore_daily "$temp_dir"
        elif [ -d "$temp_dir"/*/skills ]; then
            restore_monthly "$temp_dir"
        else
            error "无法识别备份类型"
        fi
    fi
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    log "恢复完成"
}

# 恢复每日备份
restore_daily() {
    local temp_dir="$1"
    local backup_content=$(ls -d "$temp_dir"/* 2>/dev/null | head -1)
    
    log "恢复配置文件..."
    
    # 恢复 OpenClaw 配置
    if [ -f "$backup_content/config/openclaw.json" ]; then
        cp -p "$backup_content/config/openclaw.json" "/root/.openclaw/openclaw.json"
        log "✓ 恢复 openclaw.json"
    fi
    
    if [ -f "$backup_content/config/.env" ]; then
        cp -p "$backup_content/config/.env" "/root/.openclaw/.env"
        log "✓ 恢复 .env"
    fi
    
    if [ -f "$backup_content/config/acpx.json" ]; then
        cp -p "$backup_content/config/acpx.json" "/root/.openclaw/acpx.json"
        log "✓ 恢复 acpx.json"
    fi
    
    # 恢复 Cron
    if [ -f "$backup_content/cron/jobs.json" ]; then
        cp -p "$backup_content/cron/jobs.json" "/root/.openclaw/cron/jobs.json"
        log "✓ 恢复 cron/jobs.json"
    fi
    
    # 恢复身份文件
    if [ -f "$backup_content/identity/device.json" ]; then
        cp -p "$backup_content/identity/device.json" "/root/.openclaw/identity/device.json"
        log "✓ 恢复 device.json"
    fi
    
    # 恢复 Workspace MD 文件
    if [ -d "$backup_content/workspace" ]; then
        for md in "$backup_content/workspace"/*.md; do
            if [ -f "$md" ]; then
                cp -p "$md" "/mnt/sda1/folder/"
                log "✓ 恢复 $(basename $md)"
            fi
        done
    fi
    
    # 更新 latest 备份
    cp -r "$backup_content"/* "/root/.openclaw/backups/latest/" 2>/dev/null || true
}

# 恢复每月备份
restore_monthly() {
    local temp_dir="$1"
    local backup_content=$(ls -d "$temp_dir"/* 2>/dev/null | head -1)
    
    log "恢复完整备份..."
    
    # 先恢复每日备份部分
    if [ -f "$backup_content/daily_latest.tar.gz" ]; then
        log "包含每日备份，先恢复..."
        verify_backup "$backup_content/daily_latest.tar.gz"
        local daily_temp=$(mktemp -d)
        tar -xzf "$backup_content/daily_latest.tar.gz" -C "$daily_temp"
        restore_daily "$daily_temp"
        rm -rf "$daily_temp"
    fi
    
    # 恢复技能目录
    if [ -d "$backup_content/skills" ]; then
        rsync -av "$backup_content/skills/" "/mnt/sda1/folder/skills/" 2>/dev/null || true
        log "✓ 恢复技能目录 ($(ls -la $backup_content/skills/ | wc -l) 个技能)"
    fi
    
    # 恢复输出目录
    if [ -d "$backup_content/output" ]; then
        rsync -av "$backup_content/output/" "/mnt/sda1/folder/output/" 2>/dev/null || true
        log "✓ 恢复输出目录"
    fi
    
    # 恢复记忆目录
    if [ -d "$backup_content/memory" ]; then
        rsync -av "$backup_content/memory/" "/mnt/sda1/folder/memory/" 2>/dev/null || true
        log "✓ 恢复记忆目录"
    fi
    
    # 恢复脚本目录
    if [ -d "$backup_content/scripts" ]; then
        rsync -av "$backup_content/scripts/" "/root/.openclaw/scripts/" 2>/dev/null || true
        log "✓ 恢复脚本目录"
    fi
}

# 重启 OpenClaw 服务
restart_openclaw() {
    log "重启 OpenClaw 服务..."
    
    # 检查容器状态
    local container_id=$(docker ps -q --filter "name=openclaw" 2>/dev/null || true)
    
    if [ -n "$container_id" ]; then
        log "重启容器: $container_id"
        docker restart "$container_id" 2>/dev/null || warn "容器重启失败"
    else
        # 尝试通过 OpenClaw CLI 重启
        if command -v openclaw &> /dev/null; then
            log "通过 CLI 重启网关..."
            openclaw gateway restart 2>/dev/null || warn "网关重启失败"
        else
            warn "未找到 OpenClaw 服务，请手动重启"
        fi
    fi
    
    # 等待服务启动
    sleep 5
    log "服务重启完成"
}

# 显示帮助
show_help() {
    echo -e "${BLUE}OpenClaw 一键恢复脚本${NC}"
    echo "用法:"
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh)\""
    echo ""
    echo "选项:"
    echo "  --list          显示可用备份"
    echo "  --latest        恢复最新备份"
    echo "  --daily <file>  恢复指定每日备份"
    echo "  --monthly <file> 恢复指定每月备份"
    echo "  --help          显示此帮助"
    echo ""
    echo "示例:"
    echo "  # 恢复最新备份"
    echo "  bash -c \"\$(curl -fsSL ...)\" --latest"
    echo ""
    echo "  # 显示备份列表"
    echo "  bash -c \"\$(curl -fsSL ...)\" --list"
}

# 主程序
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}      OpenClaw 一键恢复工具${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # 检查环境
    check_env
    
    # 解析参数
    local action="interactive"
    local backup_file=""
    local restore_type=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --list)
                list_backups "/root/.openclaw/backups"
                exit 0
                ;;
            --latest)
                action="restore"
                backup_file=$(ls -t "/root/.openclaw/backups/daily"/*.tar.gz 2>/dev/null | head -1)
                if [ -z "$backup_file" ]; then
                    backup_file=$(ls -t "/root/.openclaw/backups/monthly"/*_full.tar.gz 2>/dev/null | head -1)
                    restore_type="monthly"
                else
                    restore_type="daily"
                fi
                ;;
            --daily)
                if [ -z "$2" ]; then
                    error "--daily 需要指定备份文件"
                fi
                action="restore"
                backup_file="$2"
                restore_type="daily"
                shift
                ;;
            --monthly)
                if [ -z "$2" ]; then
                    error "--monthly 需要指定备份文件"
                fi
                action="restore"
                backup_file="$2"
                restore_type="monthly"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                warn "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # 交互模式
    if [ "$action" = "interactive" ]; then
        echo ""
        echo "请选择操作:"
        echo "1) 显示备份列表"
        echo "2) 恢复最新备份"
        echo "3) 退出"
        echo -n "选择 [1-3]: "
        
        read choice
        case $choice in
            1)
                list_backups "/root/.openclaw/backups"
                exit 0
                ;;
            2)
                action="restore"
                backup_file=$(ls -t "/root/.openclaw/backups/daily"/*.tar.gz 2>/dev/null | head -1)
                if [ -z "$backup_file" ]; then
                    backup_file=$(ls -t "/root/.openclaw/backups/monthly"/*_full.tar.gz 2>/dev/null | head -1)
                    restore_type="monthly"
                else
                    restore_type="daily"
                fi
                ;;
            3)
                log "退出"
                exit 0
                ;;
            *)
                error "无效选择"
                ;;
        esac
    fi
    
    # 执行恢复
    if [ "$action" = "restore" ]; then
        if [ -z "$backup_file" ]; then
            error "未找到可用备份"
        fi
        
        verify_backup "$backup_file"
        
        echo -e "${YELLOW}警告: 这将覆盖当前配置，继续吗？ (y/N)${NC}"
        read -r confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log "已取消"
            exit 0
        fi
        
        restore_backup "$backup_file" "$restore_type"
        restart_openclaw
        
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}      恢复成功！${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo "下一步:"
        echo "1. 检查 OpenClaw 服务状态: openclaw status"
        echo "2. 验证配置: openclaw models list"
        echo "3. 测试技能是否正常工作"
        echo ""
    fi
}

# 捕获错误
trap 'error "脚本执行失败"' ERR

# 运行主程序
main "$@"
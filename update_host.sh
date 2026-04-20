#!/bin/bash
# update_openclaw_host.sh - OpenClaw 宿主机安全更新脚本
# 在 OpenWrt 路由器上执行，不是容器内！

echo "=========================================="
echo "    OpenClaw 宿主机安全更新脚本"
echo "=========================================="
echo ""
echo "⚠️  警告：必须在宿主机执行，不能在容器内！"
echo ""

# 检查是否在宿主机
if [ -f /.dockerenv ]; then
    echo "❌ 错误：请在宿主机执行此脚本"
    echo "    SSH 到路由器: ssh root@192.168.0.1"
    exit 1
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker 未安装"
    exit 1
fi

echo "当前容器状态:"
docker ps --filter "name=openclaw" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo ""
echo "选择更新方式:"
echo "1) 更新到最新稳定版 (openclaw/openclaw:latest)"
echo "2) 更新到 4.19 版本 (openclaw/openclaw:4.19)"
echo "3) 更新到指定版本"
echo "4) 只备份配置，不更新"
echo "5) 退出"
echo ""

read -p "选择 [1-5]: " choice

case $choice in
    1)
        IMAGE="openclaw/openclaw:latest"
        ;;
    2)
        IMAGE="openclaw/openclaw:4.19"
        ;;
    3)
        read -p "输入镜像标签 (如: openclaw/openclaw:2026.4.19): " IMAGE
        ;;
    4)
        echo "=== 只备份配置 ==="
        # 备份当前配置
        BACKUP_DIR="/root/openclaw_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        
        # 保存容器信息
        docker inspect openclaw > "$BACKUP_DIR/container_info.json" 2>/dev/null || true
        docker ps -a --filter "name=openclaw" --format "{{.Image}}" > "$BACKUP_DIR/current_image.txt" 2>/dev/null || true
        
        echo "✅ 配置备份完成: $BACKUP_DIR"
        echo "包含:"
        echo "  - container_info.json (容器详细信息)"
        echo "  - current_image.txt (当前镜像)"
        exit 0
        ;;
    5)
        echo "退出"
        exit 0
        ;;
    *)
        echo "无效选择"
        exit 1
        ;;
esac

echo ""
echo "=== 更新步骤 ==="
echo "1. 拉取新镜像: $IMAGE"
echo "2. 停止旧容器"
echo "3. 删除旧容器"
echo "4. 用新镜像重建容器"
echo "5. 验证更新"
echo ""

read -p "确认更新？ (y/N): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

# ==================== 开始更新 ====================

echo ""
echo "=== 1. 拉取新镜像 ==="
docker pull "$IMAGE" || {
    echo "❌ 拉取镜像失败"
    exit 1
}

echo "✅ 镜像拉取成功"

echo ""
echo "=== 2. 停止旧容器 ==="
docker stop openclaw 2>/dev/null && echo "✅ 容器已停止" || echo "⚠ 容器可能未运行"

echo ""
echo "=== 3. 删除旧容器 ==="
docker rm openclaw 2>/dev/null && echo "✅ 容器已删除" || echo "⚠ 容器可能不存在"

echo ""
echo "=== 4. 重建容器 ==="
echo "使用原挂载参数重建..."

# 重建容器（使用原挂载参数）
DOCKER_CMD="docker run -d \
  --name openclaw \
  --restart unless-stopped \
  -p 18789:18789 \
  -v /mnt/sda1/folder:/mnt/sda1/folder \
  -v /mnt/nvme0n1p6/OpenClaw:/mnt/nvme0n1p6/OpenClaw \
  $IMAGE"

echo "执行: $DOCKER_CMD"
eval "$DOCKER_CMD" || {
    echo "❌ 重建容器失败"
    exit 1
}

echo "✅ 容器重建成功"

echo ""
echo "=== 5. 验证更新 ==="
sleep 10

echo "容器状态:"
docker ps --filter "name=openclaw" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo ""
echo "检查版本:"
docker exec openclaw openclaw --version 2>&1 || echo "⚠ 无法获取版本"

echo ""
echo "检查服务健康:"
sleep 5
if curl -s http://localhost:18789/health 2>/dev/null; then
    echo "✅ 服务健康"
else
    echo "⚠ 服务可能未就绪，请稍后检查"
fi

echo ""
echo "=========================================="
echo "           更新完成！"
echo "=========================================="
echo ""
echo "如果遇到问题:"
echo "1. 查看日志: docker logs openclaw"
echo "2. 回滚到旧版本:"
echo "   docker stop openclaw"
echo "   docker rm openclaw"
echo "   docker run -d --name openclaw --restart unless-stopped -p 18789:18789 -v /mnt/sda1/folder:/mnt/sda1/folder -v /mnt/nvme0n1p6/OpenClaw:/mnt/nvme0n1p6/OpenClaw openclaw/openclaw:2026.4.15"
echo ""
echo "3. 使用 GitHub 恢复配置:"
echo "   bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh)\" --latest"
echo ""
echo "4. 检查技能是否正常:"
echo "   docker exec openclaw openclaw skills list"
echo "=========================================="
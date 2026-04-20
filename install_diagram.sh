#!/bin/bash
# install_diagram_for_doge.sh - 宿主机安装脚本
# 在 OpenWrt 路由器上执行

echo "=========================================="
echo "  安装 diagram-design 到 Doge Code"
echo "=========================================="

# 检查 Doge Code 容器
echo "检查 Doge Code 容器..."
if ! docker ps --filter "name=doge-code" --format "{{.Names}}" | grep -q doge-code; then
    echo "❌ Doge Code 容器未运行"
    exit 1
fi

echo "✅ Doge Code 容器运行中"

# 方法1: 在宿主机克隆，然后复制到容器
echo ""
echo "方法1: 宿主机克隆 + 复制到容器"

# 在宿主机克隆
TEMP_DIR="/tmp/diagram-design-$(date +%s)"
echo "克隆到宿主机: $TEMP_DIR"
git clone https://github.com/cathrynlavery/diagram-design.git "$TEMP_DIR"

# 复制到容器
echo "复制到 Doge Code 容器..."
docker cp "$TEMP_DIR" doge-code:/home/coder/.doge/skills/diagram-design

# 在容器内设置权限
echo "设置权限..."
docker exec doge-code chown -R coder:coder /home/coder/.doge/skills/diagram-design 2>/dev/null || true

# 清理
rm -rf "$TEMP_DIR"

# 验证
echo ""
echo "验证安装..."
docker exec doge-code ls -la /home/coder/.doge/skills/diagram-design/ 2>/dev/null | head -10

# 创建符号链接到 Claude 目录
echo ""
echo "创建符号链接到 Claude 目录..."
docker exec doge-code bash -c "
mkdir -p /home/coder/.claude/skills 2>/dev/null || true
ln -sf /home/coder/.doge/skills/diagram-design /home/coder/.claude/skills/diagram-design 2>/dev/null || true
echo '符号链接创建完成'
"

# 检查技能内容
echo ""
echo "技能内容预览:"
docker exec doge-code head -20 /home/coder/.doge/skills/diagram-design/SKILL.md 2>/dev/null || echo "无法读取 SKILL.md"

# 重启 Doge Code 容器
echo ""
read -p "是否重启 Doge Code 容器使技能生效？ (y/N): " restart_confirm
if [[ $restart_confirm =~ ^[Yy]$ ]]; then
    echo "重启 Doge Code 容器..."
    docker restart doge-code
    sleep 10
    echo "✅ 容器已重启"
else
    echo "⚠ 技能可能需要重启才能生效"
fi

echo ""
echo "=========================================="
echo "           安装完成！"
echo "=========================================="
echo ""
echo "🎯 13种图表类型:"
echo "1. Architecture - 架构图"
echo "2. Flowchart - 流程图"
echo "3. Sequence - 序列图"
echo "4. State - 状态机图"
echo "5. ER / Data model - 实体关系图"
echo "6. Timeline - 时间线图"
echo "7. Swimlane - 泳道图"
echo "8. Quadrant - 象限图"
echo "9. Nested - 嵌套图"
echo "10. Tree - 树状图"
echo "11. Layers - 分层图"
echo "12. Venn - 维恩图"
echo "13. Pyramid / Funnel - 金字塔/漏斗图"
echo ""
echo "📖 使用方式:"
echo "在 Doge Code 中直接说:"
echo "  'Make me an architecture diagram of my app'"
echo "  'I need a quadrant showing Q2 projects by impact vs effort'"
echo "  'Give me a sequence diagram of the OAuth handshake'"
echo ""
echo "🎨 品牌定制:"
echo "  'onboard diagram-design to https://yoursite.com'"
echo ""
echo "📍 技能位置:"
echo "  /home/coder/.doge/skills/diagram-design"
echo "  /home/coder/.claude/skills/diagram-design (符号链接)"
echo "=========================================="
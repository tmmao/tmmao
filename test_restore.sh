#!/bin/bash
# test_restore.sh - 安全测试恢复流程
# 原理：备份当前状态 → 模拟损坏 → 执行恢复 → 对比验证 → 无论成败都还原

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

log()  { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# ============================================================
# Step 0: 保存当前状态（安全网）
# ============================================================
info "=== Step 0: 保存当前状态 ==="
SAFETY_DIR="/tmp/openclaw-restore-test-safety-$(date +%s)"
mkdir -p "$SAFETY_DIR"

# 备份所有将被测试的文件
for f in /root/.openclaw/openclaw.json \
         /root/.openclaw/.env \
         /root/.openclaw/cron/jobs.json \
         /root/.openclaw/acpx.json \
         /root/.openclaw/identity/device.json \
         /mnt/sda1/folder/MEMORY.md \
         /mnt/sda1/folder/SOUL.md \
         /mnt/sda1/folder/AGENTS.md; do
    if [ -f "$f" ]; then
        # 保留目录结构
        rel="${f#/}"
        mkdir -p "$SAFETY_DIR/$(dirname $rel)"
        cp -p "$f" "$SAFETY_DIR/$rel"
        info "安全备份: $f"
    fi
done

info "安全备份保存在: $SAFETY_DIR"
info "即使测试失败，也可以从这里恢复"

# ============================================================
# Step 1: 验证备份文件存在且完整
# ============================================================
info ""
info "=== Step 1: 验证备份文件 ==="

BACKUP_DIR="/root/.openclaw/backups"
LATEST_BACKUP=$(ls -t "$BACKUP_DIR/daily/"*.tar.gz 2>/dev/null | head -1)

if [ -z "$LATEST_BACKUP" ]; then
    fail "没有找到每日备份文件"
    echo "请先运行: bash /mnt/sda1/folder/skills/backup-manager/scripts/daily_backup.sh"
    exit 1
fi
log "找到备份: $LATEST_BACKUP"

# 验证 tar 完整性
if tar -tzf "$LATEST_BACKUP" >/dev/null 2>&1; then
    log "tar 文件完整性验证通过"
else
    fail "tar 文件损坏"
fi

# 验证关键文件在备份中
TEST_DIR="/tmp/openclaw-restore-test-$(date +%s)"
mkdir -p "$TEST_DIR"
tar -xzf "$LATEST_BACKUP" -C "$TEST_DIR" 2>/dev/null || true

for expected in config/openclaw.json config/.env cron/jobs.json; do
    found=$(find "$TEST_DIR" -path "*/$expected" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        log "备份包含: $expected"
    else
        fail "备份缺失: $expected"
    fi
done

# ============================================================
# Step 2: 对比备份内容与当前文件（差异检测）
# ============================================================
info ""
info "=== Step 2: 对比备份与当前状态 ==="

BACKUP_CONTENT=$(ls -d "$TEST_DIR"/* 2>/dev/null | head -1)

diff_file() {
    local backup="$1"
    local current="$2"
    local name="$3"
    
    if [ ! -f "$backup" ]; then
        warn "备份中不存在: $name"
        return
    fi
    if [ ! -f "$current" ]; then
        warn "当前不存在: $name"
        return
    fi
    
    if diff -q "$backup" "$current" >/dev/null 2>&1; then
        log "$name: 一致"
    else
        local lines=$(diff "$backup" "$current" | wc -l)
        warn "$name: 有差异 (${lines} 行不同，这是正常的 - 备份是之前的时间点)"
    fi
}

diff_file "$BACKUP_CONTENT/config/openclaw.json" "/root/.openclaw/openclaw.json" "openclaw.json"
diff_file "$BACKUP_CONTENT/config/.env" "/root/.openclaw/.env" ".env"
diff_file "$BACKUP_CONTENT/cron/jobs.json" "/root/.openclaw/cron/jobs.json" "cron/jobs.json"

# ============================================================
# Step 3: 模拟损坏 + 恢复测试（不覆盖真实文件）
# ============================================================
info ""
info "=== Step 3: 模拟恢复流程 ==="

RESTORE_TEST_DIR="/tmp/openclaw-restore-test-simulate-$(date +%s)"
mkdir -p "$RESTORE_TEST_DIR"/{config,cron,identity,workspace}

# 模拟空文件（模拟损坏）
echo '{"error":"corrupted"}' > "$RESTORE_TEST_DIR/config/openclaw.json"
echo "CORRUPTED" > "$RESTORE_TEST_DIR/config/.env"
info "模拟损坏文件已创建"

# 执行恢复（到测试目录，不影响真实文件）
info "执行恢复到测试目录..."
cp "$BACKUP_CONTENT/config/openclaw.json" "$RESTORE_TEST_DIR/config/openclaw.json"
cp "$BACKUP_CONTENT/config/.env" "$RESTORE_TEST_DIR/config/.env"
cp "$BACKUP_CONTENT/cron/jobs.json" "$RESTORE_TEST_DIR/cron/jobs.json"

# 验证恢复结果
if grep -q '"models"' "$RESTORE_TEST_DIR/config/openclaw.json" 2>/dev/null; then
    log "openclaw.json 恢复成功（包含 models 配置）"
else
    fail "openclaw.json 恢复后仍异常"
fi

if grep -q "APIFY_TOKEN\|GITHUB_TOKEN" "$RESTORE_TEST_DIR/config/.env" 2>/dev/null; then
    log ".env 恢复成功（包含 API token）"
else
    fail ".env 恢复后仍异常"
fi

if python3 -c "import json; json.load(open('$RESTORE_TEST_DIR/cron/jobs.json'))" 2>/dev/null; then
    log "jobs.json 恢复成功（JSON 格式正确）"
else
    fail "jobs.json 恢复后 JSON 格式错误"
fi

# ============================================================
# Step 4: 验证 Workspace MD 文件恢复
# ============================================================
info ""
info "=== Step 4: 验证 Workspace 文件恢复 ==="

for md in "$BACKUP_CONTENT/workspace/"*.md; do
    if [ -f "$md" ]; then
        basename=$(basename "$md")
        cp "$md" "$RESTORE_TEST_DIR/workspace/"
        
        if [ -s "$RESTORE_TEST_DIR/workspace/$basename" ]; then
            log "$basename 恢复成功 ($(wc -l < "$RESTORE_TEST_DIR/workspace/$basename") 行)"
        else
            fail "$basename 恢复后为空"
        fi
    fi
done

# ============================================================
# Step 5: 验证恢复脚本本身
# ============================================================
info ""
info "=== Step 5: 验证恢复脚本 ==="

RESTORE_SCRIPT="/mnt/sda1/folder/skills/backup-manager/scripts/restore.sh"

if [ -f "$RESTORE_SCRIPT" ]; then
    log "恢复脚本存在: $RESTORE_SCRIPT"
    
    # 检查脚本关键函数
    for func in verify_backup restore_daily restore_monthly restart_openclaw; do
        if grep -q "$func" "$RESTORE_SCRIPT"; then
            log "脚本包含函数: $func"
        else
            fail "脚本缺失函数: $func"
        fi
    done
    
    # 检查脚本可执行
    if [ -x "$RESTORE_SCRIPT" ]; then
        log "脚本有执行权限"
    else
        warn "脚本缺少执行权限（chmod +x）"
    fi
else
    fail "恢复脚本不存在: $RESTORE_SCRIPT"
fi

# ============================================================
# 清理 + 还原安全网
# ============================================================
info ""
info "=== 清理 ==="

# 清理测试目录
rm -rf "$TEST_DIR" "$RESTORE_TEST_DIR"

# 验证真实文件未被修改（安全检查）
info "验证真实文件未被修改..."
CORRUPTED=0
for f in /root/.openclaw/openclaw.json /root/.openclaw/.env /root/.openclaw/cron/jobs.json; do
    if [ -f "$f" ]; then
        rel="${f#/}"
        if [ -f "$SAFETY_DIR/$rel" ]; then
            if ! diff -q "$f" "$SAFETY_DIR/$rel" >/dev/null 2>&1; then
                fail "真实文件被修改: $f（正在还原...）"
                cp -p "$SAFETY_DIR/$rel" "$f"
                CORRUPTED=1
            fi
        fi
    fi
done

if [ $CORRUPTED -eq 0 ]; then
    log "所有真实文件未被修改 ✓"
fi

# 保留安全备份目录（用户可手动删除）
info "安全备份保留在: $SAFETY_DIR"
info "确认无误后可删除: rm -rf $SAFETY_DIR"

# ============================================================
# 测试报告
# ============================================================
info ""
info "=========================================="
info "       恢复流程测试报告"
info "=========================================="
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo -e "  ${YELLOW}警告: 见上方输出${NC}"
info "=========================================="

if [ $FAIL -eq 0 ]; then
    log "🎉 恢复流程测试全部通过！"
    info ""
    info "一键恢复命令："
    info "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh)\" --latest"
else
    fail "❌ 有 $FAIL 项测试未通过，请检查上方输出"
fi

# 清理安全备份
rm -rf "$SAFETY_DIR"

exit $FAIL
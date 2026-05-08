#!/bin/bash
# ============================================================
# OpenWrt 智能恢复工具箱 v1.0.0
# 基于 Kejilion.sh 样式构建
# GitHub: https://github.com/tmmao/tmmao
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh > restore.sh
#   bash install.sh --list      查看备份
#   bash install.sh --latest    恢复最新备份
#   bash install.sh --help      帮助
# ============================================================

sh_v="1.0.0"

# ── 颜色 ──
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ── 路径 ──
BACKUP_ROOT="/mnt/sda1/docker-backups"
OPENCLAW_HOME="/root/.openclaw"
WORKSPACE_DIR="${OPENCLAW_HOME}/workspace"
OPENWRT_BACKUP="${BACKUP_ROOT}/openwrt"
OLD_BACKUP_DIR="/root/.openclaw/backups"
LOG_FILE="/tmp/recovery_$(date +%Y%m%d_%H%M%S).log"

# ── 工具函数 ──

install_pkg() {
	if [ $# -eq 0 ]; then return 1; fi
	for package in "$@"; do
		if ! command -v "$package" &>/dev/null; then
			echo -e "${gl_kjlan}正在安装 $package...${gl_bai}"
			if command -v apt &>/dev/null; then
				apt update -y &>/dev/null; apt install -y "$package" &>/dev/null
			elif command -v apk &>/dev/null; then
				apk update &>/dev/null; apk add "$package" &>/dev/null
			elif command -v opkg &>/dev/null; then
				opkg update &>/dev/null; opkg install "$package" &>/dev/null
			elif command -v dnf &>/dev/null; then
				dnf install -y "$package" &>/dev/null
			elif command -v yum &>/dev/null; then
				yum install -y "$package" &>/dev/null
			fi
		fi
	done
}

log() { echo -e "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${gl_huang}[WARN] $*${gl_bai}" | tee -a "$LOG_FILE"; }
error() { echo -e "${gl_hong}[ERROR] $*${gl_bai}" | tee -a "$LOG_FILE"; }
success() { echo -e "${gl_lv}[OK] $*${gl_bai}" | tee -a "$LOG_FILE"; }

break_end() {
	echo -e "${gl_lv}操作完成${gl_bai}"
	echo "按任意键继续..."
	read -n 1 -s -r -p ""
	echo ""
	clear
}

confirm() {
	local prompt=$1
	local default=${2:-n}
	local yn
	read -e -p "$prompt (y/N): " yn
	yn=${yn:-$default}
	[[ "$yn" == "y" || "$yn" == "Y" ]]
}

check_ssh_openwrt() {
	ssh -o ConnectTimeout=3 -o BatchMode=yes root@192.168.0.1 "echo OK" 2>/dev/null | grep -q "OK"
}

check_docker() {
	if ! command -v docker &>/dev/null; then
		warn "Docker 未安装"
		return 1
	fi
	return 0
}

is_compose_container() {
	docker inspect "$1" | jq -e '.[0].Config.Labels["com.docker.compose.project"]' >/dev/null 2>&1
}

# ════════════════════════════════════════════════════════════
# 备份清单
# ════════════════════════════════════════════════════════════

list_all_backups() {
	echo -e "${gl_kjlan}━━━ 可用备份 ━━━${gl_bai}"

	# Docker 容器备份
	echo -e "\n${gl_lv}📦 Docker 容器备份:${gl_bai}"
	local docker_backups=$(ls -1dt ${BACKUP_ROOT}/docker_backup_* 2>/dev/null)
	if [[ -n "$docker_backups" ]]; then
		echo "$docker_backups" | while read d; do
			echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $(basename "$d")"
		done
	else
		echo "  （无）"
	fi

	# OpenClaw 备份
	echo -e "\n${gl_lv}🧠 OpenClaw 备份:${gl_bai}"
	local oc_backups=$(ls -1dt ${BACKUP_ROOT}/openclaw_backup_* 2>/dev/null)
	if [[ -n "$oc_backups" ]]; then
		echo "$oc_backups" | while read d; do
			echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $(basename "$d")"
		done
	else
		echo "  （无）"
	fi

	# 旧版 OpenClaw 备份兼容
	if [[ -d "$OLD_BACKUP_DIR" ]]; then
		echo -e "\n${gl_lv}📁 旧版 OpenClaw 备份 (legacy):${gl_bai}"
		for type in daily monthly latest; do
			local files=$(ls "${OLD_BACKUP_DIR}/${type}"/*.tar.gz 2>/dev/null)
			if [[ -n "$files" ]]; then
				echo "$files" | while read f; do
					echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  [${type}] $(basename "$f")"
				done
			fi
		done
	fi

	# OpenWrt 备份
	echo -e "\n${gl_lv}🔧 OpenWrt 系统备份:${gl_bai}"
	local ow_backups=$(ls -1dt ${OPENWRT_BACKUP}/ow_backup_* 2>/dev/null)
	if [[ -n "$ow_backups" ]]; then
		echo "$ow_backups" | while read d; do
			echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $(basename "$d")"
		done
	else
		echo "  （无）"
	fi

	# MEMORY 历史
	echo -e "\n${gl_lv}📄 MEMORY.md 历史:${gl_bai}"
	local mem_files=$(ls -1t ${BACKUP_ROOT}/memory/MEMORY_*.md 2>/dev/null | head -5)
	if [[ -n "$mem_files" ]]; then
		echo "$mem_files" | while read f; do
			echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  $(basename "$f")"
		done
	else
		echo "  （无）"
	fi
}

# ════════════════════════════════════════════════════════════
# Docker 容器还原
# ════════════════════════════════════════════════════════════

restore_docker_containers() {
	log "开始 Docker 容器还原"
	check_docker || { break_end; return; }
	install_pkg tar jq gzip

	read -e -p "备份目录路径（留空从列表选）: " BACKUP_DIR
	if [[ -z "$BACKUP_DIR" ]]; then
		local dirs=($(ls -1dt ${BACKUP_ROOT}/docker_backup_* 2>/dev/null))
		if [[ ${#dirs[@]} -eq 0 ]]; then
			error "没有 Docker 备份"
			break_end; return
		fi
		echo -e "${gl_kjlan}可用:${gl_bai}"
		for i in "${!dirs[@]}"; do
			echo "  $((i+1)). $(basename ${dirs[$i]})  ($(du -sh "${dirs[$i]}" | cut -f1))"
		done
		read -e -p "编号: " idx
		BACKUP_DIR="${dirs[$((idx-1))]}"
	fi
	[[ ! -d "$BACKUP_DIR" ]] && { error "目录不存在"; break_end; return; }

	log "还原: $BACKUP_DIR"

	# Compose 项目
	for f in "$BACKUP_DIR"/backup_type_*; do
		[[ ! -f "$f" ]] && continue
		if grep -q "compose" "$f"; then
			pn=$(basename "$f" | sed 's/backup_type_//')
			pf="$BACKUP_DIR/compose_path_${pn}.txt"
			or=$(cat "$pf" 2>/dev/null) || or=""
			[[ -z "$or" ]] && read -e -p "原始路径: " or
			[[ $(docker ps --filter "label=com.docker.compose.project=$pn" --format '{{.Names}}' | wc -l) -gt 0 ]] && { warn "Compose [$pn] 已在运行，跳过"; continue; }
			mkdir -p "$or"
			tar -xzf "$BACKUP_DIR/compose_project_${pn}.tar.gz" -C "$or"
			(cd "$or" && docker compose up -d) && success "Compose [$pn] 已启动" || error "Compose [$pn] 启动失败"
		fi
	done

	# 普通容器
	local has_container=false
	for json in "$BACKUP_DIR"/*_inspect.json; do
		[[ ! -f "$json" ]] && continue
		has_container=true
		c=$(basename "$json" | sed 's/_inspect.json//')
		docker ps --format '{{.Names}}' | grep -q "^${c}$" && { warn "容器 [$c] 已在运行，跳过"; continue; }

		IMAGE=$(jq -r '.[0].Config.Image' "$json")
		[[ -z "$IMAGE" || "$IMAGE" == "null" ]] && { warn "无镜像信息，跳过: $c"; continue; }

		PORT_ARGS=""; ENV_ARGS=""; VOL_ARGS=""
		mapfile -t PORTS < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key | split("/")[0])"' "$json")
		for p in "${PORTS[@]}"; do [[ -n "$p" ]] && PORT_ARGS="$PORT_ARGS -p $p"; done
		mapfile -t ENVS < <(jq -r '.[0].Config.Env[]' "$json")
		for e in "${ENVS[@]}"; do ENV_ARGS="$ENV_ARGS -e \"$e\""; done
		mapfile -t VOLS < <(jq -r '.[0].Mounts[] | "\(.Source):\(.Destination)"' "$json")
		for v in "${VOLS[@]}"; do
			VS=$(echo "$v" | cut -d':' -f1); VD=$(echo "$v" | cut -d':' -f2)
			mkdir -p "$VS"; VOL_ARGS="$VOL_ARGS -v $VS:$VD"
			VF="$BACKUP_DIR/${c}_$(basename $VS).tar.gz"
			[[ -f "$VF" ]] && tar -xzf "$VF" -C / 2>/dev/null && log "  卷: $VS"
		done

		docker ps -a --format '{{.Names}}' | grep -q "^${c}$" && docker rm -f "$c" &>/dev/null
		eval "docker run -d --name \"$c\" $PORT_ARGS $VOL_ARGS $ENV_ARGS \"$IMAGE\"" && success "容器 [$c] 已启动" || error "容器 [$c] 启动失败"
	done

	[[ -f "$BACKUP_DIR/home_docker_files.tar.gz" ]] && confirm "还原 /home/docker 文件?" && tar -xzf "$BACKUP_DIR/home_docker_files.tar.gz" -C / && success "/home/docker 已还原"

	[[ "$has_container" == false ]] && warn "没有需要还原的容器"
	break_end
}

# ════════════════════════════════════════════════════════════
# Compose 批量还原
# ════════════════════════════════════════════════════════════

restore_all_compose() {
	log "批量还原 Compose"
	check_docker || { break_end; return; }

	local SCAN_DIRS=("/mnt/nvme0n1p6/docker" "/root/docker" "/home/docker" "/opt/docker")
	local found=false
	for dir in "${SCAN_DIRS[@]}"; do
		[[ ! -d "$dir" ]] && continue
		while IFS= read -r -d '' cf; do
			pd=$(dirname "$cf"); pn=$(basename "$pd")
			rc=$(docker ps --filter "label=com.docker.compose.project=$pn" --format '{{.Names}}' | wc -l)
			local s="${gl_lv}🟢${gl_bai}"; [[ "$rc" -eq 0 ]] && s="${gl_huang}🟡${gl_bai}"
			echo "  $s  $pd"
			found=true
		done < <(find "$dir" -maxdepth 3 -name "docker-compose.yml" -print0 2>/dev/null)
	done
	[[ "$found" == false ]] && echo -e "${gl_huang}未找到 Compose 文件${gl_bai}" && read -e -p "手动输入目录: " md && [[ -n "$md" ]] && SCAN_DIRS=("$md")

	read -e -p "指定项目目录（留空全部启动）: " td
	for dir in "${SCAN_DIRS[@]}"; do
		[[ ! -d "$dir" ]] && continue
		while IFS= read -r -d '' cf; do
			pd=$(dirname "$cf"); pn=$(basename "$pd")
			[[ $(docker ps --filter "label=com.docker.compose.project=$pn" --format '{{.Names}}' | wc -l) -eq 0 ]] && {
				(cd "$pd" && docker compose up -d) && success "Compose [$pn] 已启动" || error "Compose [$pn] 启动失败"
			}
		done < <(find "$dir" -maxdepth 3 -name "docker-compose.yml" -print0 2>/dev/null)
	done
	break_end
}

# ════════════════════════════════════════════════════════════
# 旧版 OpenClaw 备份兼容还原
# ════════════════════════════════════════════════════════════

verify_backup() {
	local f="$1"
	[[ ! -f "$f" ]] && { error "文件不存在: $f"; return 1; }
	tar -tzf "$f" >/dev/null 2>&1 || { error "文件损坏: $f"; return 1; }
	local tmp=$(mktemp -d)
	tar -xzf "$f" -C "$tmp" --wildcards "*/config/openclaw.json" 2>/dev/null || true
	if [[ -f "$tmp"/*/config/openclaw.json ]]; then success "备份包含 openclaw.json"; else warn "可能不包含 openclaw.json"; fi
	rm -rf "$tmp"
	return 0
}

restore_legacy_backup() {
	local backup_file="$1"
	local restore_type="$2"
	log "还原旧版备份: $(basename $backup_file)"
	install_pkg rsync
	local tmp=$(mktemp -d)
	tar -xzf "$backup_file" -C "$tmp"
	local bc=$(ls -d "$tmp"/* 2>/dev/null | head -1)

	if [[ -f "$bc/config/openclaw.json" ]]; then cp -p "$bc/config/openclaw.json" "${OPENCLAW_HOME}/openclaw.json"; success "restore openclaw.json"; fi
	if [[ -f "$bc/config/.env" ]]; then cp -p "$bc/config/.env" "${OPENCLAW_HOME}/.env"; success "restore .env"; fi
	if [[ -f "$bc/cron/jobs.json" ]]; then cp -p "$bc/cron/jobs.json" "${OPENCLAW_HOME}/cron/jobs.json"; success "restore cron"; fi
	if [[ -d "$bc/workspace" ]]; then
		for md in "$bc/workspace"/*.md; do [[ -f "$md" ]] && cp -p "$md" "$WORKSPACE_DIR/" && success "restore $(basename $md)"; done
	fi

	if [[ "$restore_type" == "monthly" ]]; then
		[[ -d "$bc/skills" ]] && rsync -a "$bc/skills/" "$WORKSPACE_DIR/skills/" 2>/dev/null && success "restore skills"
		[[ -d "$bc/memory" ]] && rsync -a "$bc/memory/" "$WORKSPACE_DIR/memory/" 2>/dev/null && success "restore memory"
	fi

	rm -rf "$tmp"
}

restore_latest_backup() {
	log "恢复最新备份"
	local latest=""

	# 优先新格式
	local oc_dirs=($(ls -1dt ${BACKUP_ROOT}/openclaw_backup_* 2>/dev/null))
	local docker_dirs=($(ls -1dt ${BACKUP_ROOT}/docker_backup_* 2>/dev/null))
	local legacy_files=($(ls -t ${OLD_BACKUP_DIR}/daily/*.tar.gz 2>/dev/null))

	if [[ ${#oc_dirs[@]} -gt 0 ]]; then
		restore_openclaw_auto "${oc_dirs[0]}"
	elif [[ ${#docker_dirs[@]} -gt 0 ]]; then
		restore_docker_backup_auto "${docker_dirs[0]}"
	elif [[ ${#legacy_files[@]} -gt 0 ]]; then
		verify_backup "${legacy_files[0]}" && restore_legacy_backup "${legacy_files[0]}" "daily"
		local monthly=($(ls -t ${OLD_BACKUP_DIR}/monthly/*_full.tar.gz 2>/dev/null))
		[[ ${#monthly[@]} -gt 0 ]] && verify_backup "${monthly[0]}" && restore_legacy_backup "${monthly[0]}" "monthly"
	fi

	success "最新备份已恢复"
}

restore_docker_backup_auto() {
	local d="$1"
	check_docker || return
	for f in "$d"/backup_type_*; do
		[[ ! -f "$f" ]] && continue
		grep -q "compose" "$f" || continue
		pn=$(basename "$f" | sed 's/backup_type_//')
		pf="$d/compose_path_${pn}.txt"
		or=$(cat "$pf" 2>/dev/null) || continue
		mkdir -p "$or"
		tar -xzf "$d/compose_project_${pn}.tar.gz" -C "$or" 2>/dev/null
		(cd "$or" && docker compose up -d 2>/dev/null) && success "Compose [$pn] 已启动"
	done
	for json in "$d"/*_inspect.json; do
		[[ ! -f "$json" ]] && continue
		c=$(basename "$json" | sed 's/_inspect.json//')
		docker ps --format '{{.Names}}' | grep -q "^${c}$" && continue
		IMAGE=$(jq -r '.[0].Config.Image' "$json") || continue
		[[ -z "$IMAGE" || "$IMAGE" == "null" ]] && continue
		PORT_ARGS=""; ENV_ARGS=""; VOL_ARGS=""
		mapfile -t PORTS < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | "\(.value[0].HostPort):\(.key | split("/")[0])"' "$json")
		for p in "${PORTS[@]}"; do [[ -n "$p" ]] && PORT_ARGS="$PORT_ARGS -p $p"; done
		mapfile -t ENVS < <(jq -r '.[0].Config.Env[]' "$json")
		for e in "${ENVS[@]}"; do ENV_ARGS="$ENV_ARGS -e \"$e\""; done
		mapfile -t VOLS < <(jq -r '.[0].Mounts[] | "\(.Source):\(.Destination)"' "$json")
		for v in "${VOLS[@]}"; do
			VS=$(echo "$v" | cut -d':' -f1); VD=$(echo "$v" | cut -d':' -f2)
			mkdir -p "$VS"; VOL_ARGS="$VOL_ARGS -v $VS:$VD"
			VF="$d/${c}_$(basename $VS).tar.gz"; [[ -f "$VF" ]] && tar -xzf "$VF" -C / 2>/dev/null
		done
		docker ps -a --format '{{.Names}}' | grep -q "^${c}$" && docker rm -f "$c" &>/dev/null
		eval "docker run -d --name \"$c\" $PORT_ARGS $VOL_ARGS $ENV_ARGS \"$IMAGE\"" && success "容器 [$c] 已启动"
	done
}

restore_openclaw_auto() {
	local d="$1"
	[[ -f "$d/workspace.tar.gz" ]] && tar -xzf "$d/workspace.tar.gz" -C "$WORKSPACE_DIR" && success "workspace 还原"
	[[ -f "$d/memory.tar.gz" ]] && tar -xzf "$d/memory.tar.gz" -C "$WORKSPACE_DIR" && success "memory 还原"
	[[ -f "$d/MEMORY.md" ]] && cp "$d/MEMORY.md" "${WORKSPACE_DIR}/MEMORY.md" && success "MEMORY.md 还原"
}

# ════════════════════════════════════════════════════════════
# OpenClaw 备份
# ════════════════════════════════════════════════════════════

backup_openclaw() {
	log "备份 OpenClaw"
	local ds=$(date +%Y%m%d_%H%M%S)
	local td="${BACKUP_ROOT}/openclaw_backup_${ds}"
	mkdir -p "$td"
	tar -czf "${td}/workspace.tar.gz" --exclude="memory" --exclude="node_modules" -C "$WORKSPACE_DIR" .
	[[ -d "$MEMORY_DIR" ]] && tar -czf "${td}/memory.tar.gz" -C "$WORKSPACE_DIR" memory/
	[[ -f "${WORKSPACE_DIR}/MEMORY.md" ]] && cp "${WORKSPACE_DIR}/MEMORY.md" "${td}/"
	[[ -d "${OPENCLAW_HOME}/skills" ]] && tar -czf "${td}/skills_config.tar.gz" -C "${OPENCLAW_HOME}" skills/
	[[ -d "${OPENCLAW_HOME}/plugins" ]] && tar -czf "${td}/plugins_config.tar.gz" -C "${OPENCLAW_HOME}" plugins/
	crontab -l > "${td}/crontab.txt" 2>/dev/null
	success "备份完成: $(du -sh "$td" | cut -f1)"
	break_end
}

restore_openclaw_menu() {
	local dirs=($(ls -1dt ${BACKUP_ROOT}/openclaw_backup_* 2>/dev/null))
	[[ ${#dirs[@]} -eq 0 ]] && { error "没有 OpenClaw 备份"; break_end; return; }
	echo -e "${gl_kjlan}可用:${gl_bai}"
	for i in "${!dirs[@]}"; do echo "  $((i+1)). $(basename ${dirs[$i]})  ($(du -sh "${dirs[$i]}" | cut -f1))"; done
	read -e -p "编号: " idx
	local d="${dirs[$((idx-1))]}"
	if confirm "覆盖当前 OpenClaw 文件?"; then
		[[ -f "$d/workspace.tar.gz" ]] && tar -xzf "$d/workspace.tar.gz" -C "$WORKSPACE_DIR" && success "workspace 还原"
		[[ -f "$d/memory.tar.gz" ]] && tar -xzf "$d/memory.tar.gz" -C "$WORKSPACE_DIR" && success "memory 还原"
		[[ -f "$d/MEMORY.md" ]] && cp "$d/MEMORY.md" "${WORKSPACE_DIR}/MEMORY.md" && success "MEMORY.md 还原"
		[[ -f "$d/skills_config.tar.gz" ]] && tar -xzf "$d/skills_config.tar.gz" -C "$OPENCLAW_HOME"
		[[ -f "$d/plugins_config.tar.gz" ]] && tar -xzf "$d/plugins_config.tar.gz" -C "$OPENCLAW_HOME"
	fi
	break_end
}

# ════════════════════════════════════════════════════════════
# OpenWrt 备份/还原
# ════════════════════════════════════════════════════════════

backup_openwrt() {
	log "备份 OpenWrt"
	check_ssh_openwrt || { error "无法连接 OpenWrt"; break_end; return; }
	local ds=$(date +%Y%m%d_%H%M%S)
	mkdir -p "${OPENWRT_BACKUP}/ow_backup_${ds}"
	ssh root@192.168.0.1 "tar -czf /tmp/ow_${ds}.tar.gz -C /etc/config ." && \
		scp root@192.168.0.1:/tmp/ow_${ds}.tar.gz "${OPENWRT_BACKUP}/ow_backup_${ds}/" && \
		ssh root@192.168.0.1 "rm /tmp/ow_${ds}.tar.gz"
	ssh root@192.168.0.1 "iptables-save" > "${OPENWRT_BACKUP}/ow_backup_${ds}/iptables.txt" 2>/dev/null
	ssh root@192.168.0.1 "ip addr" > "${OPENWRT_BACKUP}/ow_backup_${ds}/network.txt"
	ssh root@192.168.0.1 "opkg list-installed" > "${OPENWRT_BACKUP}/ow_backup_${ds}/packages.txt"
	success "备份完成: $(du -sh "${OPENWRT_BACKUP}/ow_backup_${ds}" | cut -f1)"
	break_end
}

restore_openwrt() {
	check_ssh_openwrt || { error "无法连接 OpenWrt"; break_end; return; }
	local dirs=($(ls -1dt ${OPENWRT_BACKUP}/ow_backup_* 2>/dev/null))
	[[ ${#dirs[@]} -eq 0 ]] && { error "没有 OpenWrt 备份"; break_end; return; }
	echo -e "${gl_kjlan}可用:${gl_bai}"
	for i in "${!dirs[@]}"; do echo "  $((i+1)). $(basename ${dirs[$i]})  ($(du -sh "${dirs[$i]}" | cut -f1))"; done
	read -e -p "编号: " idx
	local d="${dirs[$((idx-1))]}"
	echo -e "${gl_huang}⚠️  还原 OpenWrt 配置可能影响网络连接${gl_bai}"
	if ! confirm "确定继续?"; then break_end; return; fi
	local tf=$(ls ${d}/ow_*.tar.gz 2>/dev/null | head -1)
	[[ -f "$tf" ]] && scp "$tf" root@192.168.0.1:/tmp/ow_restore.tar.gz && \
		ssh root@192.168.0.1 "cd /etc/config && tar -xzf /tmp/ow_restore.tar.gz && rm /tmp/ow_restore.tar.gz" && \
		success "配置已还原" && confirm "立即重启 OpenWrt?" && ssh root@192.168.0.1 "reboot"
	break_end
}

# ════════════════════════════════════════════════════════════
# 全量恢复
# ════════════════════════════════════════════════════════════

full_recovery() {
	log "══════ 全量恢复 ══════"
	echo -e "${gl_huang}⚠️  将依次:${gl_bai}"
	echo "  1. Docker Compose 项目"
	echo "  2. Docker 容器"
	echo "  3. OpenClaw 工作区"
	! confirm "确定?" && { break_end; return; }

	local steps=0

	# Docker
	local db=($(ls -1dt ${BACKUP_ROOT}/docker_backup_* 2>/dev/null))
	if [[ ${#db[@]} -gt 0 ]]; then
		((steps++)); log "步骤 $steps: Docker 容器"
		restore_docker_backup_auto "${db[0]}"
	fi

	# OpenClaw
	local ob=($(ls -1dt ${BACKUP_ROOT}/openclaw_backup_* 2>/dev/null))
	if [[ ${#ob[@]} -gt 0 ]]; then
		((steps++)); log "步骤 $steps: OpenClaw"
		restore_openclaw_auto "${ob[0]}"
	fi

	# 启动 Compose
	((steps++)); log "步骤 $steps: 拉起 Compose 项目"
	for dir in "/mnt/nvme0n1p6/docker" "/root/docker" "/home/docker"; do
		[[ ! -d "$dir" ]] && continue
		while IFS= read -r -d '' cf; do
			pd=$(dirname "$cf"); pn=$(basename "$pd")
			[[ $(docker ps --filter "label=com.docker.compose.project=$pn" --format '{{.Names}}' | wc -l) -eq 0 ]] && \
				(cd "$pd" && docker compose up -d 2>/dev/null) && success "Compose [$pn] 启动"
		done < <(find "$dir" -maxdepth 3 -name "docker-compose.yml" -print0 2>/dev/null)
	done

	log "══════ 全量恢复完成 ══════"
	echo -e "${gl_kjlan}后续:${gl_bai}" " openclaw gateway restart | docker ps"
	break_end
}

# ════════════════════════════════════════════════════════════
# 系统诊断
# ════════════════════════════════════════════════════════════

system_diagnosis() {
	clear
	echo -e "${gl_kjlan}━━━ 容器 ━━━${gl_bai}"
	check_docker && {
		local t=$(docker ps -a -q 2>/dev/null | wc -l)
		local r=$(docker ps -q 2>/dev/null | wc -l)
		echo "  总: $t  运行: ${gl_lv}$r${gl_bai}  停止: ${gl_huang}$((t-r))${gl_bai}"
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -30
	}
	echo -e "\n${gl_kjlan}━━━ 磁盘 ━━━${gl_bai}"
	df -h | grep -E "sda|nvme" | awk '{printf "  %s: %s / %s (%s)\n", $NF, $3, $2, $5}'
	echo -e "\n${gl_kjlan}━━━ SSH OpenWrt ━━━${gl_bai}"
	check_ssh_openwrt && success "✅ 连接正常: $(ssh root@192.168.0.1 "uptime" 2>/dev/null)" || error "❌ 无法连接"
	read -n 1 -s -r -p "按任意键继续..."
	echo ""
}

# ════════════════════════════════════════════════════════════
# 主菜单
# ════════════════════════════════════════════════════════════

main_menu() {
	while true; do
		clear
		echo "═══════════════════════════════════"
		echo -e "${gl_kjlan}  🛠️  OpenWrt 智能恢复工具箱 v${sh_v}${gl_bai}"
		echo "═══════════════════════════════════"
		echo -e "  备份: ${gl_huang}${BACKUP_ROOT}${gl_bai}"
		echo "═══════════════════════════════════"
		echo ""
		echo -e "${gl_kjlan}  1.  ${gl_bai}📦 Docker 容器还原 ${gl_huang}★${gl_bai}"
		echo -e "${gl_kjlan}  2.  ${gl_bai}🐳 Compose 批量还原${gl_bai}"
		echo "  ─────────────────────────"
		echo -e "${gl_kjlan}  3.  ${gl_bai}🧠 OpenClaw 还原${gl_bai}"
		echo -e "${gl_kjlan}  4.  ${gl_bai}🔧 OpenWrt 系统还原 ${gl_huang}★${gl_bai}"
		echo "  ─────────────────────────"
		echo -e "${gl_kjlan}  5.  ${gl_bai}📤 OpenClaw 备份${gl_bai}"
		echo -e "${gl_kjlan}  6.  ${gl_bai}📤 OpenWrt 备份${gl_bai}"
		echo "  ─────────────────────────"
		echo -e "${gl_kjlan}  7.  ${gl_bai}🚀 全量恢复 ${gl_huang}★${gl_bai}"
		echo -e "${gl_kjlan}  8.  ${gl_bai}📋 备份清单${gl_bai}"
		echo -e "${gl_kjlan}  9.  ${gl_bai}🩺 诊断${gl_bai}"
		echo "  ─────────────────────────"
		echo -e "${gl_kjlan}  0.  ${gl_bai}退出${gl_bai}"
		echo "═══════════════════════════════════"
		read -e -p "选择: " c
		case $c in
			1) restore_docker_containers ;;
			2) restore_all_compose ;;
			3) restore_openclaw_menu ;;
			4) restore_openwrt ;;
			5) backup_openclaw ;;
			6) backup_openwrt ;;
			7) full_recovery ;;
			8) clear; list_all_backups; break_end ;;
			9) system_diagnosis ;;
			0) clear; echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;;
			*) echo -e "${gl_hong}无效${gl_bai}"; sleep 1 ;;
		esac
	done
}

# ── CLI 参数模式 ──

show_help() {
	echo -e "${gl_kjlan}OpenWrt 智能恢复工具箱 v${sh_v}${gl_bai}"
	echo ""
	echo "用法:"
	echo "  curl -fsSL https://raw.githubusercontent.com/tmmao/tmmao/main/install.sh | bash"
	echo "  bash install.sh             交互菜单"
	echo "  bash install.sh --list      查看备份"
	echo "  bash install.sh --latest    恢复最新备份"
	echo "  bash install.sh --help      帮助"
}

main() {
	case "${1:-}" in
		--list|list) clear; list_all_backups; ;;
		--latest|latest) clear; restore_latest_backup; ;;
		--help|help|-h) show_help; ;;
		*) main_menu ;;
	esac
}

main "$@"

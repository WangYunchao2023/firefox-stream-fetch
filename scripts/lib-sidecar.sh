# lib-sidecar.sh — sidecar JSON 持久化（Phase 2 状态）
#
# Sidecar JSON 存在 dump 文件旁边：${DUMP_FILE}.sidecar.json
# 用来记录：
#   - 当前播放进度（currentTime / duration / state）
#   - dump 文件断点（size / last_keyframe_pts）
#   - 中断历史（interrupt_reasons）
#   - 分段信息（parts[]）— 用于 ffmpeg concat
#
# 函数：
#   sidecar_init   — 初始化（或读已有 sidecar 实现 resume）
#   sidecar_set    — 写一个字段
#   sidecar_get    — 读一个字段（JSON 字段值）
#   sidecar_save   — 落盘
#   sidecar_add_part — 添加分段记录
#
# 依赖 jq，没有就装。

# 避免重复 source
[[ -n "${_LIB_SIDECAR_LOADED:-}" ]] && return 0
_LIB_SIDECAR_LOADED=1

# 检查 jq
_sidecar_require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "❌ 缺 jq：sudo apt install jq" >&2
        return 1
    fi
}

# 初始化 sidecar（如果不存在则创建空模板）
# 用法: sidecar_init <sidecar_path>
sidecar_init() {
    _sidecar_require_jq || return 1
    local path="$1"
    if [ -f "$path" ]; then
        # 已存在（resume 场景）
        return 0
    fi
    cat > "$path" << 'JSON'
{
  "version": 1,
  "started_at": null,
  "last_updated": null,
  "url": null,
  "dump_video": null,
  "dump_audio": null,
  "video_state": "unknown",
  "current_time": 0,
  "duration": null,
  "ready_state": 0,
  "buffered_end": 0,
  "last_dump_size_video": 0,
  "last_dump_size_audio": 0,
  "last_keyframe_pts": 0,
  "interrupt_count": 0,
  "interrupt_reasons": [],
  "parts": [],
  "last_ff_url": null,
  "ended_at": null
}
JSON
}

# 读字段（用 jq）
# 用法: sidecar_get <sidecar_path> <jq_filter>
#   sidecar_get $path .video_state  →  playing
sidecar_get() {
    _sidecar_require_jq || return 1
    local path="$1" filter="$2"
    jq -r "$filter" "$path"
}

# 写一个字段（深 merge）
# 用法: sidecar_set <sidecar_path> <key> <json_value>
#   sidecar_set $path video_state '"playing"'
#   sidecar_set $path current_time 123.4
sidecar_set() {
    _sidecar_require_jq || return 1
    local path="$1" key="$2" value="$3"
    local tmp="${path}.tmp.$$"
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v | .last_updated = (now | todate)' \
        "$path" > "$tmp" && mv "$tmp" "$path"
}

# 添加一个分段
# 用法: sidecar_add_part <sidecar_path> <part_file> <start_time> <end_time>
sidecar_add_part() {
    _sidecar_require_jq || return 1
    local path="$1" part="$2" start="$3" end="${4:-null}"
    local tmp="${path}.tmp.$$"
    jq --arg f "$part" --argjson s "$start" --argjson e "$end" \
        '.parts += [{"file": $f, "start": $s, "end": $e}] | .last_updated = (now | todate)' \
        "$path" > "$tmp" && mv "$tmp" "$path"
}

# 添加一个中断记录
# 用法: sidecar_log_interrupt <sidecar_path> <reason>
sidecar_log_interrupt() {
    _sidecar_require_jq || return 1
    local path="$1" reason="$2"
    local tmp="${path}.tmp.$$"
    jq --arg r "$reason" \
        '.interrupt_count += 1 | .interrupt_reasons += [$r] | .last_updated = (now | todate)' \
        "$path" > "$tmp" && mv "$tmp" "$path"
}

# 标记结束（写 ended_at）
sidecar_mark_ended() {
    _sidecar_require_jq || return 1
    local path="$1" reason="${2:-normal}"
    local tmp="${path}.tmp.$$"
    jq --arg r "$reason" '.ended_at = (now | todate) | .end_reason = $r' \
        "$path" > "$tmp" && mv "$tmp" "$path"
}
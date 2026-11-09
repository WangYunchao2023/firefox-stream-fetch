# lib-monitor.sh — Phase 2 智能监控主循环（daemon 模式）
#
# 替换 capture-generic.sh / capture-yfsp.sh 里简陋的 stall 逻辑：
#   - 启动 firefox + BiDi daemon（unix socket）
#   - 每 5s 通过 socket 查 video 状态
#   - 按 video.state 分场景处理（playing / paused / buffering / ended / no-video）
#   - stalled_count 累计规则：
#       playing + dump_growing    → 0
#       paused                    → 不增（用户主动）
#       buffering                 → 减半累计（网络问题，不是结束）
#       playing + !dump_growing   → 正常累计（异常停滞）
#   - ended → 立即结束
#   - no-video → 触发恢复（firefox 崩溃 / 视频元素消失）
#   - firefox 进程死了 → 自动重启 firefox + daemon + resume（seek 到 last_keyframe_pts）
#
# 依赖: lib-sidecar.sh, bidi-state.py
#
# 用法:
#   source lib-sidecar.sh
#   source lib-monitor.sh
#   monitor_run "$FF_BIN" "$PROFILE" "$URL" "$DUMP_VIDEO" "$DUMP_AUDIO" "$SIDECAR"

[[ -n "${_LIB_MONITOR_LOADED:-}" ]] && return 0
_LIB_MONITOR_LOADED=1

# 默认参数（可在调用前 export 覆盖）
: "${MONITOR_STALL_LIMIT:=36}"        # stall 累计阈值（5s/次 × 36 = 180s）
: "${MONITOR_PAUSED_LIMIT:=360}"      # 暂停无动作的最大轮询次数（30 min）
: "${MONITOR_MAX_INTERRUPTS:=3}"      # firefox 崩溃自动恢复最多几次
: "${MONITOR_BIDI_PORT:=9222}"
: "${MONITOR_INTERVAL:=5}"
: "${MONITOR_DEBUG:=0}"
: "${PROJECT_ROOT:=/home/wangyc/Documents/软件类工作/firefox-stream-fetch}"
: "${BIDI_STATE:=${PROJECT_ROOT}/scripts/bidi-state.py}"
: "${BIDI_SOCKET:=/tmp/bidi-monitor.sock}"

_monitor_log() {
    echo "[$(date +%H:%M:%S)] $*" >&2
}

_monitor_debug() {
    [ "${MONITOR_DEBUG}" = "1" ] && echo "[$(date +%H:%M:%S)] [debug] $*" >&2
}

# 启动 firefox
_monitor_start_firefox() {
    local ff_bin="$1" profile="$2" url="$3"
    local firefox_log="${4:-}"  # 可选第 4 参数: firefox stdout/stderr 重定向目标,默认 dump 同目录 .log
    # Firefox stdout/stderr (含 StreamDumper 帧日志) 写到 dump 同目录 .log，供后续 mux_to_mp4 提取时间戳
    # 预热阶段 MOZ_STREAM_DUMP_PATH=/dev/null,${...%.h264}.log 会变成 /dev/null.log（无写权限）
    # 这种情况 fallback 到 /dev/null,丢弃 firefox stdout/stderr
    if [ -z "$firefox_log" ]; then
        case "${MOZ_STREAM_DUMP_PATH:-}" in
            /dev/null|/dev/null.*)
                firefox_log="/dev/null"
                ;;
            *)
                firefox_log="${MOZ_STREAM_DUMP_PATH%.h264}.log"
                ;;
        esac
    fi
    setsid nohup env MOZ_STREAM_DUMP_PATH="$MOZ_STREAM_DUMP_PATH" MOZ_STREAM_DUMP_PTS_FILE="$MOZ_STREAM_DUMP_PTS_FILE" "$ff_bin" \
        -profile "$profile" \
        -no-remote --new-instance \
        -remote-debugging-port "$MONITOR_BIDI_PORT" \
        -remote-allow-origins '*' \
        about:blank \
        < /dev/null > "$firefox_log" 2>&1 &
    local pid=$!
    disown
    echo "$pid"
}

# 等 BiDi 端口 listen（纯 TCP 探测，不发 BiDi 命令）
# 原因：firefox BiDi 全局单 session，session.new 一次就占用，发其他命令会失败
_monitor_wait_for_bidi() {
    local timeout="${1:-30}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if (echo > "/dev/tcp/127.0.0.1/$MONITOR_BIDI_PORT") 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# 启动 bidi daemon（unix socket）
_monitor_daemon_start() {
    rm -f "$BIDI_SOCKET"
    # 输出重定向到 /dev/null 防止 BiDi daemon 启动 JSON 泄漏到 monitor stdout
    # 泄漏的 JSON（如 {"ok": true, "msg": "daemon ready"}）会污染 capture.sh 的 reason 解析
    setsid nohup "$BIDI_STATE" daemon --port "$MONITOR_BIDI_PORT" --socket "$BIDI_SOCKET" \
        >/dev/null 2>&1 &
    local pid=$!
    disown
    echo "$pid"
}

# 等 daemon socket ready
_monitor_daemon_wait() {
    local timeout="${1:-15}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if [ -S "$BIDI_SOCKET" ]; then
            # ping 一下确认
            if "$BIDI_STATE" call --socket "$BIDI_SOCKET" --cmd ping >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# 杀 daemon
_monitor_daemon_stop() {
    if [ -S "$BIDI_SOCKET" ]; then
        "$BIDI_STATE" call --socket "$BIDI_SOCKET" --cmd stop >/dev/null 2>&1 || true
        sleep 1
        rm -f "$BIDI_SOCKET"
    fi
    # 兜底
    pkill -f "bidi-state.py daemon.*$MONITOR_BIDI_PORT" 2>/dev/null || true
}

# 通过 daemon 调用 query
_monitor_query() {
    "$BIDI_STATE" call --socket "$BIDI_SOCKET" --cmd query 2>/dev/null
}

# 等待真页面 ready（用于 firefox 预热阶段）
#   判定: url 是 http(s) 且不在 CF challenge 子域 → 立即 ready
#         (StreamDumper 在新 firefox 进程里干净初始化即可, 不需等 video metadata 加载)
#   兜底: video.readyState>=3 + currentTime>=2 + duration>=30 (用户用 file:// 等)
#   timeout: 秒（默认 60s）
#   return 0: 真页面 ready / 1: timeout
_monitor_wait_real_video() {
    local timeout="${1:-60}"
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        local q
        q=$(_monitor_query 2>/dev/null)
        if [ -n "$q" ]; then
            local state ready cur dur url
            state=$(echo "$q" | jq -r '.state // empty' 2>/dev/null)
            ready=$(echo "$q" | jq -r '.readyState // 0' 2>/dev/null)
            cur=$(echo "$q" | jq -r '.currentTime // 0' 2>/dev/null)
            dur=$(echo "$q" | jq -r '.duration // 0' 2>/dev/null)
            url=$(echo "$q" | jq -r '.url // empty' 2>/dev/null)

            case "$url" in
                ""|about:*)
                    # about:home / about:newtab / about:blank 是 firefox 内部页（用户还没输入 URL）
                    _monitor_debug "   preheat: waiting url=$url (用户尚未输入 URL 或 firefox 内部页)"
                    ;;
                *challenges.cloudflare.com*)
                    # CF challenge 中,等通过
                    _monitor_debug "   preheat: CF challenge in progress ($url)"
                    ;;
                http://*|https://*)
                    # 真页面 URL，进一步等待视频元素 ready + 正在播放
                    # 【严格判定】避免被 1-3 秒广告/预览误判为"真视频"：
                    #   - readyState >= 2（有数据）
                    #   - dur > 30s（真视频不可能 < 30s，广告/预览通常 5-15s）
                    #   - cur > 1s（已经跳过了初始加载阶段）
                    # 某些站点需用户点击才 playing，但 click 后 dur > 30 才算真视频 ready
                    if [ "$ready" -ge 2 ] &&
                       [ "$(awk -v d="$dur" 'BEGIN{print (d>30)?1:0}')" = "1" ] &&
                       [ "$(awk -v t="$cur" 'BEGIN{print (t>1)?1:0}')" = "1" ]; then
                        _monitor_log "   ✅ 真视频 ready: $url (ct=${cur}s dur=${dur}s ready=$ready state=$state)"
                        return 0
                    fi
                    _monitor_debug "   preheat: url=$url state=$state ready=$ready ct=${cur}s dur=${dur}s (等待 dur>30 + ct>1)"
                    ;;
                *)
                    # 其他 URL（file:// 等），按 video metadata 兜底判定
                    if [ "$ready" -ge 3 ] && \
                       [ "$(awk -v t="$cur" 'BEGIN{print (t>=2)?1:0}')" = "1" ] && \
                       [ "$(awk -v d="$dur" 'BEGIN{print (d>30)?1:0}')" = "1" ]; then
                        _monitor_log "   ✅ 真视频 ready (其他 url): $url (ct=${cur}s dur=${dur}s ready=$ready)"
                        return 0
                    fi
                    _monitor_debug "   preheat: url=$url ready=$ready ct=${cur}s dur=${dur}s state=$state"
                    ;;
            esac
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# 手工 URL 模式：无限等待 state=playing（不超时 fallback）
# 用于 Phase 1 手工输入 URL 后，Phase 2 需等用户点击播放才开始抓取
_monitor_wait_real_video_manual() {
    while true; do
        local q
        q=$(_monitor_query 2>/dev/null)
        if [ -n "$q" ]; then
            local state ready cur dur url
            state=$(echo "$q" | jq -r '.state // empty' 2>/dev/null)
            ready=$(echo "$q" | jq -r '.readyState // 0' 2>/dev/null)
            cur=$(echo "$q" | jq -r '.currentTime // 0' 2>/dev/null)
            dur=$(echo "$q" | jq -r '.duration // 0' 2>/dev/null)
            url=$(echo "$q" | jq -r '.url // empty' 2>/dev/null)

            case "$url" in
                ""|about:*)
                    _monitor_debug "   preheat-manual: waiting url=$url (用户尚未输入 URL 或 firefox 内部页)"
                    ;;
                *challenges.cloudflare.com*)
                    _monitor_debug "   preheat-manual: CF challenge in progress ($url)"
                    ;;
                http://*|https://*)
                    # 真页面 URL，等待 playing
                    # 【严格判定】避免被 1-3 秒广告/预览误判为"真视频"：
                    #   - readyState >= 2（有数据）
                    #   - dur > 30s（真视频不可能 < 30s，广告/预览通常 5-15s）
                    #   - cur > 1s（已经跳过了初始加载阶段）
                    # 某些站点需用户点击才 playing，但 click 后 dur > 30 才算真视频 ready
                    if [ "$ready" -ge 2 ] &&
                       [ "$(awk -v d="$dur" 'BEGIN{print (d>30)?1:0}')" = "1" ] &&
                       [ "$(awk -v t="$cur" 'BEGIN{print (t>1)?1:0}')" = "1" ]; then
                        _monitor_log "   ✅ 真视频 ready: $url (ct=${cur}s dur=${dur}s ready=$ready state=$state)"
                        return 0
                    fi
                    _monitor_debug "   preheat-manual: url=$url state=$state ready=$ready ct=${cur}s dur=${dur}s (等待 dur>30 + ct>1)"
                    ;;
                *)
                    if [ "$ready" -ge 3 ] && \
                       [ "$(awk -v t="$cur" 'BEGIN{print (t>=2)?1:0}')" = "1" ] && \
                       [ "$(awk -v d="$dur" 'BEGIN{print (d>30)?1:0}')" = "1" ]; then
                        _monitor_log "   ✅ 真视频 ready (其他 url): $url (ct=${cur}s dur=${dur}s ready=$ready)"
                        return 0
                    fi
                    _monitor_debug "   preheat-manual: url=$url ready=$ready ct=${cur}s dur=${dur}s state=$state"
                    ;;
            esac
        fi
        sleep 2
    done
}

# 通过 daemon 调用 seek
_monitor_seek() {
    local seconds="$1"
    "$BIDI_STATE" call --socket "$BIDI_SOCKET" --cmd seek --seconds "$seconds" 2>/dev/null
}

# 滚动到 part N（resume 用）
# 原 dump_v / dump_a 重命名为 .p1.h264 / .p1.aac（如果有）
# 新文件名为 .p2.h264 / .p2.aac
_monitor_roll_dump() {
    local dump_v="$1" dump_a="$2" sidecar="$3"
    local base="${dump_v%.h264}"

    # 记录原文件为 part1（如果存在）
    if [ -f "$dump_v" ]; then
        local end_time
        end_time=$(jq -r '.current_time' "$sidecar")
        sidecar_add_part "$sidecar" "$dump_v" \
            "$(jq -r '.last_keyframe_pts' "$sidecar")" "$end_time"
        mv "$dump_v" "${base}.p1.h264"
    fi
    if [ -f "$dump_a" ]; then
        local end_time
        end_time=$(jq -r '.current_time' "$sidecar")
        sidecar_add_part "$sidecar" "$dump_a" \
            "$(jq -r '.last_keyframe_pts' "$sidecar")" "$end_time"
        mv "$dump_a" "${base}.p1.aac"
    fi
    # 同步滚动 log 文件（含 StreamDumper 时间戳）
    if [ -f "${base}.log" ]; then
        mv "${base}.log" "${base}.p1.log"
    fi

    # 下个 part 名（p2 起）
    local i=2
    while [ -f "${base}.p${i}.h264" ]; do i=$((i+1)); done
    echo "${base}.p${i}.h264|${base}.p${i}.aac"
}

# 主监控
monitor_run() {
    local ff_bin="$1" profile="$2" url="$3"
    local dump_video="$4" dump_audio="$5" sidecar="$6"
    local manual_url_mode="${7:-0}"

    local stall_count=0 paused_count=0 interrupt_count=0
    local last_size_v=0 last_size_a=0
    local state="init" ff_pid=""
    local end_reason="unknown"
    local is_resume=0
    local prev_was_ended=0

    # Resume 检测
    if [ -f "$sidecar" ] && [ "$(jq -r '.interrupt_count' "$sidecar")" -gt 0 ]; then
        is_resume=1
        local resume_time
        resume_time=$(jq -r '.last_keyframe_pts' "$sidecar")
        _monitor_log "🔄 检测到中断历史（$(jq -r '.interrupt_count' "$sidecar") 次），从 $resume_time s 续接"
        local rolled
        rolled=$(_monitor_roll_dump "$dump_video" "$dump_audio" "$sidecar")
        dump_video="${rolled%%|*}"
        dump_audio="${rolled##*|}"
    fi

    sidecar_init "$sidecar"
    sidecar_set "$sidecar" url "\"$url\""
    sidecar_set "$sidecar" dump_video "\"$dump_video\""
    sidecar_set "$sidecar" dump_audio "\"$dump_audio\""
    sidecar_set "$sidecar" started_at "\"$(date -Iseconds)\""
    # last_ff_url 用 firefox 实际 URL 初始化（firefox URL 变化时持久化比较）
    # 注意：firefox 跨 URL 切换时 window.__last_video_info 被销毁,bidi-state 的 next_episode 检测失效,
    # 这里 monitor_run 自己持久化 firefox URL,作为 next_episode 检测的权威信号
    sidecar_set "$sidecar" last_ff_url "\"$url\""

    export MOZ_STREAM_DUMP_PATH="$dump_video"
    local daemon_pid=""

    # 【v3.3 简化】去掉 preheat，只开一次 Firefox。
    # 原 preheat 机制：开 Firefox#1（dump=/dev/null）等视频 ready，杀掉重开 Firefox#2（dump=真实文件）
    # 原因：StreamDumper 首次写 SPS/PPS 后整个生命周期不再重写，避免抓 loading/ad 垃圾导致 SPS/PPS 错误。
    # 现在接受这个风险（手动点击播放后只会抓到广告/预览的 SPS/PPS，但大多情况下和真视频 codec 一致不会出问题）
    local preheat_done=0
    if [ "$manual_url_mode" = "1" ]; then
        _monitor_log "👆 手工 URL 模式：URL 已传入，等网站自动播放"
    else
        _monitor_log "🚀 启动 firefox 一次到位（dump 直接写真实文件，无 preheat）"
    fi
    _monitor_log "   url=$url dump_v=$dump_video dump_a=$dump_audio"

    ff_pid=$(_monitor_start_firefox "$ff_bin" "$profile" "$url")
    _monitor_log "   firefox PID=$ff_pid"

    if ! _monitor_wait_for_bidi 30; then
        _monitor_log "❌ firefox 启动后 BiDi 端口 30s 内未起来"
        kill -9 "$ff_pid" 2>/dev/null
        return 1
    fi

    # 【v3.3 强制导航】Firefox 启动在 about:blank，现在用 BiDi 主动 navigate 到目标 URL。
    # 用一次性 BiDi session（连上、navigate、关闭），不与下面 daemon 的常驻 session 冲突。
    if [[ "$url" == http://* || "$url" == https://* ]]; then
        _monitor_log "🔄 BiDi 一次性 navigate 到 URL..."
        if python3 "${PROJECT_ROOT}/scripts/bidi-state.py" navigate "$url" --port "$MONITOR_BIDI_PORT" 2>/dev/null; then
            _monitor_log "   ✅ BiDi navigate 成功"
        else
            _monitor_log "   ⚠️  BiDi navigate 失败（firefox 可能已在 URL上，继续）"
        fi
        sleep 3  # 等 navigate 生效 + 页面开始加载
    fi

    _monitor_log "   启动 bidi daemon（socket=$BIDI_SOCKET）"
    daemon_pid=$(_monitor_daemon_start)
    if ! _monitor_daemon_wait 15; then
        _monitor_log "❌ daemon 15s 内未 ready"
        kill -9 "$ff_pid" 2>/dev/null
        kill -9 "$daemon_pid" 2>/dev/null
        return 1
    fi
    _monitor_log "   daemon ready (PID=$daemon_pid)"

    # Resume: seek 到断点
    if [ $is_resume -eq 1 ]; then
        local resume_time
        resume_time=$(jq -r '.last_keyframe_pts' "$sidecar")
        _monitor_log "   seeking video to $resume_time s..."
        _monitor_seek "$resume_time"
        sleep 3
    fi

    # 下一集索引（写到 sidecar，供 capture.sh 主循环参考）
    local episode_index=1

    # === 主循环 ===
    while true; do
        sleep "$MONITOR_INTERVAL"

        # --- 1. firefox 进程检查 ---
        if ! kill -0 "$ff_pid" 2>/dev/null; then
            _monitor_log "⚠️  firefox PID=$ff_pid 已退出"
            interrupt_count=$((interrupt_count + 1))
            sidecar_log_interrupt "$sidecar" "firefox_crashed_${interrupt_count}"

            if [ $interrupt_count -ge "$MONITOR_MAX_INTERRUPTS" ]; then
                _monitor_log "❌ 恢复次数达到上限 ($MONITOR_MAX_INTERRUPTS)，放弃"
                end_reason="max_interrupts"
                break
            fi

            _monitor_log "🔄 自动恢复（$interrupt_count/$MONITOR_MAX_INTERRUPTS）"
            _monitor_daemon_stop
            local rolled
            rolled=$(_monitor_roll_dump "$dump_video" "$dump_audio" "$sidecar")
            dump_video="${rolled%%|*}"
            dump_audio="${rolled##*|}"
            export MOZ_STREAM_DUMP_PATH="$dump_video"

            ff_pid=$(_monitor_start_firefox "$ff_bin" "$profile" "$url")
            if ! _monitor_wait_for_bidi 30; then
                _monitor_log "❌ firefox 重启后 BiDi 未起来"
                continue
            fi
            daemon_pid=$(_monitor_daemon_start)
            _monitor_daemon_wait 15 || true

            local resume_time
            resume_time=$(jq -r '.last_keyframe_pts' "$sidecar")
            _monitor_seek "$resume_time"
            sleep 3
            stall_count=0
            continue
        fi

        # --- 2. 查 video 状态 ---
        local query_out
        query_out=$(_monitor_query)
        if [ -z "$query_out" ]; then
            _monitor_debug "query 返回空（daemon 可能挂了？）"
            stall_count=$((stall_count + 1))
            # 检查 daemon 是否还在
            if ! kill -0 "$daemon_pid" 2>/dev/null; then
                _monitor_log "⚠️  daemon 也死了，重启 daemon"
                daemon_pid=$(_monitor_daemon_start)
                _monitor_daemon_wait 15 || true
            fi
            continue
        fi

        local video_state current_time duration buffered_end ready_state
        video_state=$(echo "$query_out" | jq -r '.state' 2>/dev/null)
        current_time=$(echo "$query_out" | jq -r '.currentTime' 2>/dev/null)
        duration=$(echo "$query_out" | jq -r '.duration' 2>/dev/null)
        buffered_end=$(echo "$query_out" | jq -r '.bufferedEnd' 2>/dev/null)
        ready_state=$(echo "$query_out" | jq -r '.readyState' 2>/dev/null)

        # --- 兜底：某些播放器不置 ended，用 currentTime 接近 duration 判定 ---
        if [ "$video_state" = "ended" ]; then
            prev_was_ended=1
        elif [ "$video_state" != "ended" ] && [ "$duration" != "null" ] && [ -n "$duration" ] && [ "$duration" != "" ]; then
            local ct=${current_time:-0}
            local dur=${duration:-0}
            if [ "$(awk -v t="$ct" -v d="$dur" 'BEGIN{print (t >= d - 1)}')" = "1" ]; then
                video_state="ended"
                prev_was_ended=1
            fi
        fi

        # --- 检测下一集 ---
        # 三信号 OR 触发（任一满足即切集，不需要 ct/duration 守卫）:
        #   1. bidi-state 的 next_episode_url（SPA 内 playlist 切 src，window.__last_video_info 仍有效）
        #   2. firefox URL 变化到另一个真 URL（跨 firefox URL 切换可靠）
        #   3. dump 文件 PTS 跳变（新帧 PTS < 上一帧 PTS，表示新视频开始）
        # StreamDumper sFile 是 firefox 进程内的 static fd，firefox 活着时 fd 一直写同一文件。
        # 如果不先 kill 就 mv，firefox 会把下一集内容写到 mv 后的 .p1.h264（同 inode）。
        local cur_ff_url
        cur_ff_url=$(echo "$query_out" | jq -r '.url // empty' 2>/dev/null)
        # 调试：每轮 query 后打印 firefox 当前 URL（首次或变更时打，帮助诊断 URL 是否被加载）
        if [ "$cur_ff_url" != "$last_ff_url" ] || [ "${DEBUG_URL_LOGGED:-0}" = "0" ]; then
            _monitor_log "   🔍 firefox 当前 URL: ${cur_ff_url:-<空>}"
            DEBUG_URL_LOGGED=1
        fi
        local last_ff_url
        last_ff_url=$(jq -r '.last_ff_url // empty' "$sidecar" 2>/dev/null)
        local prev_pts_us
        prev_pts_us=$(jq -r '.last_dump_pts_us // 0' "$sidecar" 2>/dev/null)
        # v4.3.8: 比较完整 URL（含 ?query/#fragment）。目标站点换集就是同 path
        # 追加/改参数 —— query 变化即下一集；path-only 比较会漏掉真实切集。
        # SPA 内换 src 且 URL 不变的情况由信号 3（dump PTS 回跳）兜底。

        local next_ep_url=""
        local next_ep_source=""

        # 信号 1: bidi-state 的 next_episode_url（SPA 内 playlist 切 src 仍有效）
        local bidi_next
        bidi_next=$(echo "$query_out" | jq -r '.next_episode_url // empty' 2>/dev/null)
        if [ -n "$bidi_next" ] && [ "$bidi_next" != "null" ]; then
            next_ep_url="$bidi_next"
            next_ep_source="bidi-state"
        fi

        # 信号 2: firefox URL 变化（持久化在 sidecar，跨 firefox URL 切换可靠）
        if [ -n "$cur_ff_url" ] && [ "$cur_ff_url" != "null" ] && \
           [ "$cur_ff_url" != "$last_ff_url" ]; then
            case "$cur_ff_url" in
                about:*)
                    # firefox 跳到 about:* 是用户回退/输入中,不是下一集
                    _monitor_debug "firefox 跳到 about:*,跳过 next_episode"
                    sidecar_set "$sidecar" last_ff_url "\"$cur_ff_url\""
                    ;;
                *)
                    if [ -z "$next_ep_url" ]; then
                        next_ep_url="$cur_ff_url"
                        next_ep_source="firefox-url"
                    else
                        _monitor_debug "bidi-state 与 firefox-url 都触发 next_episode,取 bidi-state:$next_ep_url"
                    fi
                    ;;
            esac
        elif [ -n "$cur_ff_url" ] && [ "$cur_ff_url" != "null" ]; then
            sidecar_set "$sidecar" last_ff_url "\"$cur_ff_url\""
        fi

        # 信号 3: PTS 跳变（dump 文件最后帧 PTS < 上一帧记录的 PTS）
        # 不依赖 JS / BiDi，直接读 dump 文件最后一帧 PTS
        local cur_pts_us=""
        if [ -n "$dump_video" ] && [ -f "$dump_video" ]; then
            cur_pts_us=$(python3 "${PROJECT_ROOT}/scripts/sdfv_extract.py" "$dump_video" --last-pts-only 2>/dev/null || echo "")
        fi
        if [ -z "$next_ep_url" ] && [ -n "$cur_pts_us" ] && [ "$cur_pts_us" != "0" ] && [ "$prev_pts_us" != "0" ]; then
            # PTS 回跳（小于前一帧） = 新视频开始
            if [ "$cur_pts_us" -lt "$prev_pts_us" ]; then
                _monitor_log "⏭️  PTS 跳变检测到切集: ${prev_pts_us}us → ${cur_pts_us}us"
                next_ep_url="$cur_ff_url"  # 续用当前 URL（SPA 切 src 同页面）
                next_ep_source="pts-jump"
            fi
        fi
        # 更新 last_pts（无论是否切集，下一轮比较用）
        if [ -n "$cur_pts_us" ] && [ "$cur_pts_us" != "0" ]; then
            sidecar_set "$sidecar" last_dump_pts_us "$cur_pts_us"
        fi

        # 触发切集（OR 三个信号: bidi next_episode / firefox URL 变化 / PTS 跳变）
        # 三个信号都是权威的：要么是站点 JS 明确告知，要么是浏览器真实导航，要么是 dump 文件 PTS 回跳
        # 不需要 ct/duration 守卫：它们都被设计成只在"新内容出现"时才触发
        if [ -n "$next_ep_url" ]; then
            # 例外 1：如果视频刚 ended 且 firefox URL 还没变（页面刚播完但还未跳转），不要切集
            # 这时走 ended 分支正常结束，捕获最后一帧
            if [ "$video_state" = "ended" ] && [ "$cur_ff_url" = "$last_ff_url" ]; then
                _monitor_debug "⏭️  video_state=ended 且 URL 未变，走 ended 分支 ($next_ep_source: $next_ep_url)"
            else
                # 真切集信号：触发 roll
                # - bidi next_episode_url: 站点 JS 明确告知下一集 URL
                # - firefox-url: URL 栏变化 = 真实浏览器导航（新页面加载）
                # - pts-jump: dump 文件 PTS 回跳 = 新帧内容
                # 当前 current_time=0 不是"未播放"，而是"新页面刚加载新 video 元素"
                _do_next_episode_roll=1
                prev_was_ended=0

                if [ "${_do_next_episode_roll:-0}" = "1" ]; then
                    _monitor_log "⏭️  检测到下一集 ($next_ep_source): $next_ep_url"
                    sidecar_set "$sidecar" next_url "$next_ep_url"
                    sidecar_set "$sidecar" episode_index "$((episode_index + 1))"
                    sidecar_set "$sidecar" last_ff_url "\"$cur_ff_url\""
                    sidecar_set "$sidecar" last_dump_pts_us "0"  # 重置，新集重新建立基线

                    # 先 kill firefox 释放 StreamDumper sFile fd，避免下一集内容污染当前集 dump
                    _monitor_log "   停止 firefox 准备滚动 dump..."
                    _monitor_daemon_stop
                    if [ -n "$ff_pid" ]; then
                        kill -15 "$ff_pid" 2>/dev/null || true
                        sleep 1
                        kill -9 "$ff_pid" 2>/dev/null || true
                        ff_pid=""
                    fi

                    # 手写 mv（不调 _monitor_roll_dump：它的 echo 是函数返回值，会污染 stdout 进而污染 monitor_run 返回的字符串）
                    local _roll_base="${dump_video%.h264}"
                    if [ -f "$dump_video" ]; then
                        local _end_time
                        _end_time=$(jq -r '.current_time' "$sidecar" 2>/dev/null)
                        sidecar_add_part "$sidecar" "$dump_video" \
                            "$(jq -r '.last_keyframe_pts' "$sidecar" 2>/dev/null)" "$_end_time" 2>/dev/null || true
                        mv "$dump_video" "${_roll_base}.p1.h264"
                        dump_video="${_roll_base}.p1.h264"
                    fi
                    if [ -f "$dump_audio" ]; then
                        local _end_time
                        _end_time=$(jq -r '.current_time' "$sidecar" 2>/dev/null)
                        sidecar_add_part "$sidecar" "$dump_audio" \
                            "$(jq -r '.last_keyframe_pts' "$sidecar" 2>/dev/null)" "$_end_time" 2>/dev/null || true
                        mv "$dump_audio" "${_roll_base}.p1.aac"
                        dump_audio="${_roll_base}.p1.aac"
                    fi
                    if [ -f "${_roll_base}.log" ]; then
                        mv "${_roll_base}.log" "${_roll_base}.p1.log"
                    fi

                    end_reason="next_episode"
                    break
                fi
            fi
        fi
        # 更新 sidecar
        sidecar_set "$sidecar" video_state "\"$video_state\""
        sidecar_set "$sidecar" current_time "$current_time"
        [ "$duration" != "null" ] && sidecar_set "$sidecar" duration "$duration"
        sidecar_set "$sidecar" buffered_end "$buffered_end"
        sidecar_set "$sidecar" ready_state "$ready_state"

        # --- 3. dump 大小 ---
        local size_v=0 size_a=0
        [ -f "$dump_video" ] && size_v=$(stat -c%s "$dump_video")
        [ -f "$dump_audio" ] && size_a=$(stat -c%s "$dump_audio")
        local grew_v=0 grew_a=0
        [ "$size_v" -gt "$last_size_v" ] && grew_v=1
        [ "$size_a" -gt "$last_size_a" ] && grew_a=1
        sidecar_set "$sidecar" last_dump_size_video "$size_v"
        sidecar_set "$sidecar" last_dump_size_audio "$size_a"
        last_size_v=$size_v
        last_size_a=$size_a

        # --- 4. 按场景处理 ---
        case "$video_state" in
            ended)
                _monitor_log "✅ video.ended → 立即结束"
                end_reason="ended"
                break
                ;;
            no-video)
                _monitor_log "⚠️  页面没 video 元素"
                stall_count=$((stall_count + 2))
                state="no-video"
                ;;
            paused)
                _monitor_log "⏸️  paused (current=$current_time)"
                paused_count=$((paused_count + 1))
                state="paused"
                if [ $paused_count -ge "$MONITOR_PAUSED_LIMIT" ]; then
                    end_reason="paused_too_long"
                    _monitor_log "⏸️  暂停太久，结束"
                    break
                fi
                ;;
            buffering)
                _monitor_log "⏳ buffering (readyState=$ready_state, bufferedEnd=$buffered_end)"
                stall_count=$((stall_count / 2 + 1))
                state="buffering"
                ;;
            playing)
                if [ $grew_v -eq 1 ] || [ $grew_a -eq 1 ]; then
                    _monitor_log "▶  $current_time/$duration (v+$((size_v-last_size_v)) a+$((size_a-last_size_a)))"
                    stall_count=0
                    state="playing"
                    local kpts
                    kpts=$(awk -v t="$current_time" 'BEGIN{printf "%.2f", t-5}')
                    [ "$(awk -v t="$kpts" 'BEGIN{print (t<0)?1:0}')" = "1" ] && kpts=0
                    sidecar_set "$sidecar" last_keyframe_pts "$kpts"
                else
                    _monitor_log "▶  playing but no dump growth ($current_time)"
                    stall_count=$((stall_count + 1))
                    state="stalled"
                fi
                ;;
            *)
                _monitor_log "❓ unknown state: $video_state"
                stall_count=$((stall_count + 1))
                state="unknown"
                ;;
        esac

        if [ $stall_count -ge "$MONITOR_STALL_LIMIT" ]; then
            _monitor_log "📦 stall_count=$stall_count 超过 $MONITOR_STALL_LIMIT（$((MONITOR_STALL_LIMIT*MONITOR_INTERVAL))s）→ 兜底结束"
            end_reason="stall_limit"
            break
        fi
    done

    sidecar_mark_ended "$sidecar" "$end_reason"

    # 关 daemon + firefox（next_episode 路径已先 kill，ff_pid 此时为空，跳过）
    _monitor_daemon_stop
    if [ -n "$ff_pid" ]; then
        kill -15 "$ff_pid" 2>/dev/null || true
        sleep 2
        kill -9 "$ff_pid" 2>/dev/null || true
    fi

    _monitor_log "🏁 monitor 结束：reason=$end_reason interrupt_count=$interrupt_count"
    echo "$end_reason|$interrupt_count|$dump_video|$dump_audio"
}
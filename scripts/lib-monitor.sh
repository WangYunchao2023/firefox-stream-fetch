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
    setsid nohup "$ff_bin" \
        -profile "$profile" \
        -no-remote --new-instance \
        -remote-debugging-port "$MONITOR_BIDI_PORT" \
        -remote-allow-origins '*' \
        "$url" \
        < /dev/null > /tmp/firefox-monitor.log 2>&1 &
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
    setsid nohup "$BIDI_STATE" daemon --port "$MONITOR_BIDI_PORT" --socket "$BIDI_SOCKET" \
        > /tmp/bidi-daemon.log 2>&1 &
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

    # 下个 part 名（p2 起）
    local i=2
    while [ -f "${base}.p${i}.h264" ]; do i=$((i+1)); done
    echo "${base}.p${i}.h264|${base}.p${i}.aac"
}

# 主监控
monitor_run() {
    local ff_bin="$1" profile="$2" url="$3"
    local dump_video="$4" dump_audio="$5" sidecar="$6"

    local stall_count=0 paused_count=0 interrupt_count=0
    local last_size_v=0 last_size_a=0
    local state="init" ff_pid=""
    local end_reason="unknown"
    local is_resume=0

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

    export MOZ_STREAM_DUMP_PATH="$dump_video"

    _monitor_log "🚀 启动 firefox 监控（dump_v=$dump_video dump_a=$dump_audio）"
    ff_pid=$(_monitor_start_firefox "$ff_bin" "$profile" "$url")
    _monitor_log "   firefox PID=$ff_pid"

    if ! _monitor_wait_for_bidi 30; then
        _monitor_log "❌ firefox 启动后 BiDi 端口 30s 内未起来"
        kill -9 "$ff_pid" 2>/dev/null
        return 1
    fi

    # 启动 daemon
    _monitor_log "   启动 bidi daemon（socket=$BIDI_SOCKET）"
    local daemon_pid
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

    # 关 daemon + firefox
    _monitor_daemon_stop
    kill -15 "$ff_pid" 2>/dev/null
    sleep 2
    kill -9 "$ff_pid" 2>/dev/null

    _monitor_log "🏁 monitor 结束：reason=$end_reason interrupt_count=$interrupt_count"
    echo "$end_reason|$interrupt_count|$dump_video|$dump_audio"
}
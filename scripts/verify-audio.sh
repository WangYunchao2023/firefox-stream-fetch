#!/bin/bash
# 验证音频 dump：H.264 + AAC dump，确认 .aac 文件可读且合流 mp4 有音轨
set -e

PROJECT="/home/wangyc/Documents/软件类工作/firefox-stream-fetch"
PROFILE="/tmp/firefox-audio-verify-profile"
DUMP_DIR="/tmp/moz_stream_dumps"
mkdir -p "$DUMP_DIR"

rm -rf "$PROFILE"
mkdir -p "$PROFILE"

cat > "$PROFILE/user.js" << 'PJ'
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.allow-extension-background-events", true);
user_pref("security.sandbox.content.level", 0);
user_pref("security.sandbox.gmp.level", 0);
user_pref("security.sandbox.rdd.level", 0);
user_pref("security.sandbox.socket.level", 0);
user_pref("security.sandbox.utility.level", 0);
user_pref("browser.tabs.unloadOnLowMemory", false);
user_pref("media.suspend-bkgnd-video.enabled", false);
user_pref("media.video_stats.enabled", false);
PJ

FF=$(find -L "$PROJECT/obj-stream" -name "firefox" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && FF=$(find -L "$PROJECT/obj-stream" -name "firefox-bin" -type f -executable 2>/dev/null | head -1)
[ -z "$FF" ] && { echo "❌ 找不到 firefox 二进制"; exit 1; }
FF_DIR=$(dirname "$FF")
echo "✅ Firefox: $FF"

if [ ! -d "$FF_DIR/widevine" ]; then
    SRC="$PROJECT/firefox-dist/widevine"
    [ -d "$SRC" ] && cp -r "$SRC" "$FF_DIR/widevine" && echo "✅ Widevine 已部署"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DUMP_BASE="$DUMP_DIR/audio-verify-$STAMP"
DUMP_H264="$DUMP_BASE.h264"
DUMP_AAC="$DUMP_BASE.aac"
LOG="$DUMP_DIR/audio-firefox-$STAMP.log"

rm -f "$DUMP_H264" "$DUMP_AAC"
> "$LOG"

echo ""
echo "=== 启动参数 ==="
echo "  Video dump: $DUMP_H264"
echo "  Audio dump: $DUMP_AAC"
echo "  Log:        $LOG"
echo "  Page:       file:///tmp/test-audio.html (H.264+AAC test pattern)"
echo ""

export MOZ_STREAM_DUMP_PATH="$DUMP_H264"
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_ENABLE_WAYLAND=0
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority

setsid nohup "$FF" \
    -profile "$PROFILE" \
    -no-remote --new-instance \
    -remote-debugging-port 9222 \
    -remote-allow-origins '*' \
    "file:///tmp/test-audio.html" \
    < /dev/null > "$LOG" 2>&1 &
FF_PID=$!
disown

echo "Firefox PID: $FF_PID"
sleep 5

if ! kill -0 $FF_PID 2>/dev/null; then
    echo "❌ Firefox 退出"
    cat "$LOG"
    exit 1
fi

# 探测 25s（test video 是 10s，给足够时间触发解码）
for i in 1 2 3 4 5; do
    echo ""
    echo "=== 探测 #$i (等待 5s) ==="
    sleep 5
    H264_SIZE=$(stat -c%s "$DUMP_H264" 2>/dev/null || echo "0")
    AAC_SIZE=$(stat -c%s "$DUMP_AAC" 2>/dev/null || echo "0")
    echo "  video: $H264_SIZE bytes"
    echo "  audio: $AAC_SIZE bytes"
done

echo ""
echo "=== 最终验证 ==="
echo ""
echo "--- H.264 dump ---"
ffprobe -hide_banner "$DUMP_H264" 2>&1 | head -10 || echo "❌ ffprobe 失败"
echo ""
echo "--- AAC dump ---"
if [ -f "$DUMP_AAC" ]; then
    ffprobe -hide_banner "$DUMP_AAC" 2>&1 | head -10
else
    echo "❌ AAC dump 文件未生成"
fi
echo ""
echo "--- 合流验证 ---"
if [ -f "$DUMP_AAC" ] && [ -f "$DUMP_H264" ]; then
    MERGED="$DUMP_DIR/audio-verify-merged-$STAMP.mp4"
    ffmpeg -y -i "$DUMP_H264" -i "$DUMP_AAC" -c copy "$MERGED" 2>&1 | tail -5
    echo ""
    echo "--- 合流文件 ffprobe ---"
    ffprobe -hide_banner "$MERGED" 2>&1 | grep -E "Stream|Duration"
    AUDIO_STREAM=$(ffprobe -hide_banner "$MERGED" 2>&1 | grep -c "Audio:")
    VIDEO_STREAM=$(ffprobe -hide_banner "$MERGED" 2>&1 | grep -c "Video:")
    echo ""
    if [ "$AUDIO_STREAM" -ge 1 ] && [ "$VIDEO_STREAM" -ge 1 ]; then
        echo "✅ SUCCESS: 合流文件包含音视频双轨"
    else
        echo "❌ FAIL: 合流文件缺轨道 (video=$VIDEO_STREAM audio=$AUDIO_STREAM)"
    fi
fi
echo ""
echo "--- StreamDumper 调用记录 ---"
grep "StreamDumper" "$LOG" | head -20
echo "(共 $(grep -c 'StreamDumper' $LOG) 条)"
echo ""
echo "--- log 末尾 30 行 ---"
tail -30 "$LOG"
echo ""
echo "PID $FF_PID 仍在跑"
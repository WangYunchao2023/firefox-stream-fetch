#!/usr/bin/env python3
"""单一连接 BiDi：建 session → 查 video 状态"""
import json, time, websocket, sys

ws = websocket.create_connection("ws://localhost:9222/session", timeout=10, suppress_origin=True)
ws.settimeout(8)
print(f"✅ 已连接")

_id = 0
def call(method, params=None, timeout=8):
    global _id
    _id += 1
    msg_id = _id
    ws.send(json.dumps({"id": msg_id, "method": method, "params": params or {}}))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data = json.loads(ws.recv())
            if data.get("id") == msg_id:
                return data
        except websocket.WebSocketTimeoutException:
            continue
        except Exception as e:
            print(f"recv err: {e}")
            return None
    return None

# 1. 建 session
r = call("session.new", {"capabilities": {"alwaysMatch": {}}})
if not r or r.get("type") != "success":
    print("❌ session.new 失败:", r)
    sys.exit(1)
print(f"✅ session 创建: {r['result'].get('sessionId', '?')[:8]}...")

# 2. 启用
r = call("browsingContext.enable")
print(f"browsingContext.enable: {r.get('type', '?')}")

# 3. 等 3s 让 firefox 把测试页 load
print("\n等 3s 让 Firefox 加载测试页...")
time.sleep(3)

# 4. getTree
r = call("browsingContext.getTree", {"maxDepth": 3})
ctxs = (r or {}).get("result", {}).get("contexts", [])
print(f"\ngetTree: {len(ctxs)} contexts")
for c in ctxs:
    print(f"  - {c.get('context')} {c.get('url')[:60]}")
    for ch in c.get("children", []):
        print(f"    - {ch.get('context')} {ch.get('url')[:60]}")

# 5. 找 file:// context
file_ctx = None
def find_file(ctx):
    if ctx.get("url", "").startswith("file://"):
        return ctx
    for ch in ctx.get("children", []):
        r = find_file(ch)
        if r: return r
    return None
for c in ctxs:
    fc = find_file(c)
    if fc: file_ctx = fc; break

if not file_ctx:
    print("❌ 没找到 file:// context")
    sys.exit(1)

print(f"\n✅ file:// context: {file_ctx['context']}")

# 6. 查 video
script = """function() {
  const v = document.querySelector('video');
  if (!v) return JSON.stringify({err: 'no <video> in this page'});
  return JSON.stringify({
    src: (v.currentSrc||v.src||'').slice(-60),
    rs: v.readyState, ns: v.networkState,
    paused: v.paused, ended: v.ended,
    err: v.error ? v.error.code : 0,
    errMsg: v.error ? v.error.message : '',
    t: v.currentTime.toFixed(2),
    dur: v.duration ? v.duration.toFixed(2) : '?',
    w: v.videoWidth, h: v.videoHeight,
    visibility: document.visibilityState,
  });
}"""

r = call("script.callFunction", {
    "functionDeclaration": script,
    "target": {"context": file_ctx["context"]},
    "awaitPromise": False,
})

print("\n=== VIDEO STATE ===")
if r and "result" in r and "value" in r.get("result", {}):
    val = json.loads(r["result"]["value"])
    for k, vv in val.items():
        print(f"  {k}: {vv}")
else:
    print(json.dumps(r, indent=2)[:600])

# 7. 等 10s 看 video 进度
print("\n等 10s 后再查 video.currentTime...")
time.sleep(10)
r = call("script.callFunction", {
    "functionDeclaration": "function(){var v=document.querySelector('video');return v?JSON.stringify({t:v.currentTime,paused:v.paused,err:v.error?v.error.code:0}):'none';}",
    "target": {"context": file_ctx["context"]},
    "awaitPromise": False,
})
if r and "result" in r and "value" in r.get("result", {}):
    print(f"  10s 后: {r['result']['value']}")

ws.close()
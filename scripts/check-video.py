#!/usr/bin/env python3
"""通过 Firefox BiDi 协议查询视频元素状态"""
import json
import sys
import time
import websocket
from threading import Thread, Event

WS_URL = "ws://localhost:9222/session"

# 用 suppress_origin=True 不发 Origin 头，Firefox 才会接受
ws = websocket.create_connection(WS_URL, timeout=10, suppress_origin=True)
print(f"✅ 已连接到 {WS_URL}")
ws.settimeout(5)

# 事件队列
events = []
event_ready = Event()
shutdown = False

def listener():
    while not shutdown:
        try:
            resp = ws.recv()
            if not resp:
                continue
            try:
                data = json.loads(resp)
            except json.JSONDecodeError:
                continue
            if "method" in data and "id" not in data:
                events.append(data)
        except websocket.WebSocketTimeoutException:
            continue
        except Exception:
            break

t = Thread(target=listener, daemon=True)
t.start()

# 简单的请求-响应
_msg_id = 0
def call(method, params=None, timeout=5):
    global _msg_id
    _msg_id += 1
    msg_id = _msg_id
    msg = {"id": msg_id, "method": method, "params": params or {}}
    ws.send(json.dumps(msg))
    # 等响应
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = ws.recv()
            data = json.loads(resp)
            if data.get("id") == msg_id:
                return data
            elif "method" in data:
                events.append(data)
        except websocket.WebSocketTimeoutException:
            continue
        except Exception:
            return None
    return None

print("\n--- browsingContext.enable ---")
r = call("browsingContext.enable")
print(json.dumps(r, indent=2)[:300])

print("\n--- browsingContext.getTree ---")
r = call("browsingContext.getTree", {"maxDepth": 5})
contexts = r.get("result", {}).get("contexts", []) if r else []
print(f"  共 {len(contexts)} 个 context")
for c in contexts:
    print(f"  - {c.get('context')} url={c.get('url')} children={len(c.get('children', []))}")

print("\n--- 检查视频元素 ---")
all_contexts = []
for c in contexts:
    all_contexts.append(c)
    for child in c.get("children", []):
        all_contexts.append(child)

for ctx in all_contexts:
    ctx_id = ctx.get("context")
    url = ctx.get("url")
    print(f"\n  Context: {ctx_id}")
    print(f"  URL: {url}")
    
    # 1. 查询 video 元素状态
    script = """
(function() {
  const v = document.querySelector('video');
  if (!v) return JSON.stringify({error: 'no <video> in this page'});
  return JSON.stringify({
    src: v.currentSrc || v.src,
    readyState: v.readyState,
    networkState: v.networkState,
    paused: v.paused,
    ended: v.ended,
    error: v.error ? {code: v.error.code, message: v.error.message} : null,
    currentTime: v.currentTime,
    duration: v.duration,
    videoWidth: v.videoWidth,
    videoHeight: v.videoHeight,
    autoplay: v.autoplay,
    muted: v.muted,
  });
})();
"""
    r = call("script.callFunction", {
        "functionDeclaration": script,
        "target": {"context": ctx_id},
        "awaitPromise": False,
    })
    if r and r.get("result"):
        result = r["result"]
        if "value" in result:
            try:
                val = json.loads(result["value"])
                for k, v in val.items():
                    print(f"    {k}: {v}")
            except:
                print(f"    raw: {result['value']}")
        else:
            print(f"    result: {result}")
    elif r and "error" in r:
        print(f"    error: {r['error']}")
    else:
        print(f"    no response: {r}")

# 2. 收集 5s 内的 console 事件
print("\n--- 等 5s 收集 console 事件 ---")
initial_count = len(events)
time.sleep(5)
new_events = events[initial_count:]
print(f"  收到 {len(new_events)} 个事件")
for ev in new_events[:20]:
    print(f"  - {ev.get('method')}: {json.dumps(ev.get('params', {}))[:200]}")

# 3. 重新查 video 状态
if all_contexts:
    print("\n--- 第二次查 video（5s 后） ---")
    ctx = all_contexts[0]
    r = call("script.callFunction", {
        "functionDeclaration": """
(function() {
  const v = document.querySelector('video');
  if (!v) return JSON.stringify({error: 'no video'});
  return JSON.stringify({
    currentTime: v.currentTime,
    paused: v.paused,
    readyState: v.readyState,
    networkState: v.networkState,
    ended: v.ended,
    videoWidth: v.videoWidth,
    videoHeight: v.videoHeight,
  });
})();
""",
        "target": {"context": ctx.get("context")},
        "awaitPromise": False,
    })
    if r and r.get("result", {}).get("value"):
        val = json.loads(r["result"]["value"])
        print(f"  {val}")

shutdown = True
ws.close()
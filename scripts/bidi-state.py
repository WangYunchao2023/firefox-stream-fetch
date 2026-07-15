#!/usr/bin/env python3
"""bidi-state.py — 长驻 BiDi client 模式（推荐）

用法:
  bidi-state.py daemon --port 9222
    从 stdin 读 JSON 命令（一行一条），输出 JSON 响应（一行一条）
    命令格式: {"cmd": "query", "url_pattern": ".*"}  →  响应: {"state": "playing", ...}
    命令格式: {"cmd": "seek", "seconds": 120.5}     →  响应: {"ok": true, "newTime": 120.5}
    命令格式: {"cmd": "stop"}                       →  daemon 退出
    命令格式: {"cmd": "ping"}                        →  响应: {"ok": true}

  bidi-state.py query --port 9222 [--url-pattern ".*"]
    单次查询模式（每次新建 session，不推荐多次调用）

  bidi-state.py seek SECONDS --port 9222
    单次 seek 模式（同上）

设计：firefox BiDi 单 session 限制 + ws 关闭清理 session。
长驻 daemon 模式复用同一 ws + session，避开限制。
"""
import json
import sys
import time
import argparse
import socket

try:
    import websocket
except ImportError:
    print(json.dumps({"err": "missing websocket-client", "hint": "pip install websocket-client"}), file=sys.stderr)
    sys.exit(4)


QUERY_FN = """function() {
  const v = document.querySelector('video');
  if (!v) return JSON.stringify({state: 'no-video'});
  let bufferedEnd = 0;
  if (v.buffered.length > 0) {
    bufferedEnd = v.buffered.end(v.buffered.length - 1);
  }
  const dur = (isFinite(v.duration) && !isNaN(v.duration)) ? v.duration : null;
  let state = 'unknown';
  if (v.ended) state = 'ended';
  else if (v.paused) state = 'paused';
  else if (v.readyState < 3) state = 'buffering';
  else state = 'playing';
  return JSON.stringify({
    state: state,
    paused: v.paused,
    ended: v.ended,
    currentTime: v.currentTime,
    duration: dur,
    readyState: v.readyState,
    networkState: v.networkState,
    bufferedEnd: bufferedEnd,
    src: (v.currentSrc || v.src || '').slice(-120),
    error: v.error ? v.error.code : 0,
    errorMsg: v.error ? v.error.message : '',
    videoWidth: v.videoWidth,
    videoHeight: v.videoHeight,
    visibility: document.visibilityState,
    url: location.href,
  });
}"""

SEEK_FN_TPL = """function() {
  const v = document.querySelector('video');
  if (!v) return JSON.stringify({err: 'no-video'});
  v.currentTime = %s;
  return JSON.stringify({ok: true, newTime: v.currentTime});
}"""


def check_port(host, port, timeout=2):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (ConnectionRefusedError, socket.timeout, OSError):
        return False


class BidiSession:
    """长驻 firefox BiDi session，单 ws + 单 session"""
    def __init__(self, port):
        self.port = port
        self.ws = None
        self._id = 0
        self.session_id = None

    def connect(self, timeout=10):
        if not check_port("127.0.0.1", self.port):
            return False, f"port {self.port} not listening"
        url = f"ws://127.0.0.1:{self.port}/session"
        try:
            self.ws = websocket.create_connection(url, timeout=timeout, suppress_origin=True)
            self.ws.settimeout(8)
        except Exception as e:
            return False, f"ws connect failed: {e}"
        # 建 session
        r = self._call("session.new", {"capabilities": {"alwaysMatch": {}}}, timeout=5)
        if not r or r.get("type") != "success":
            err = r.get("error", r) if r else "no response"
            self.ws.close()
            # print full error to stderr for debug
            print(f"[bidi-state debug] session.new full response: {json.dumps(r)[:500]}", file=sys.stderr)
            return False, f"session.new failed: {err}"
        self.session_id = r["result"].get("sessionId")
        return True, None

    def _call(self, method, params=None, timeout=5):
        self._id += 1
        msg_id = self._id
        try:
            self.ws.send(json.dumps({"id": msg_id, "method": method, "params": params or {}}))
        except Exception as e:
            return {"err": f"send: {e}"}
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data = json.loads(self.ws.recv())
                if data.get("id") == msg_id:
                    return data
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as e:
                return {"err": f"recv: {e}"}
        return {"err": "timeout"}

    def find_context(self, url_pattern=None):
        r = self._call("browsingContext.getTree", {"maxDepth": 3}, timeout=5)
        if not r or r.get("type") != "success":
            return None
        contexts = r.get("result", {}).get("contexts", [])
        import re
        pat = re.compile(url_pattern) if url_pattern else None
        def walk(ctx):
            url = ctx.get("url", "")
            if url.startswith(("about:", "chrome:", "moz-extension:")):
                pass
            elif url and (pat is None or pat.search(url)):
                return ctx
            for ch in ctx.get("children", []):
                rr = walk(ch)
                if rr: return rr
            return None
        return walk(contexts[0]) if contexts else None

    def query(self, url_pattern=None):
        ctx = self.find_context(url_pattern)
        if not ctx:
            return {"err": "no matching context", "url_pattern": url_pattern}
        r = self._call("script.callFunction", {
            "functionDeclaration": QUERY_FN,
            "target": {"context": ctx["context"]},
            "awaitPromise": False,
            "resultOwnership": "root",
            "serializationOptions": {"maxObjectDepth": 5, "maxDomNodeDepth": 3},
        }, timeout=5)
        if not r or r.get("type") != "success":
            return {"err": "callFunction failed", "resp": r}
        # firefox BiDi 返回: result.result.{type, value}
        # 我返回的是 JSON 字符串，type=string, value='...'
        outer_result = r.get("result", {})
        inner = outer_result.get("result", {})
        val = inner.get("value")
        type_ = inner.get("type")
        if val is not None:
            if type_ == "string":
                try:
                    return json.loads(val)
                except Exception as e:
                    return {"err": f"value not JSON: {e}", "raw": val}
            else:
                # value 已经是 object 类型
                return val
        return {"err": "no value in result", "raw_outer": outer_result}

    def seek(self, seconds, url_pattern=None):
        ctx = self.find_context(url_pattern)
        if not ctx:
            return {"err": "no matching context"}
        js = SEEK_FN_TPL % repr(float(seconds))
        r = self._call("script.callFunction", {
            "functionDeclaration": js,
            "target": {"context": ctx["context"]},
            "awaitPromise": False,
            "resultOwnership": "root",
        }, timeout=5)
        if not r or r.get("type") != "success":
            return {"err": "seek failed", "resp": r}
        outer_result = r.get("result", {})
        inner = outer_result.get("result", {})
        val = inner.get("value")
        type_ = inner.get("type")
        if val is not None:
            if type_ == "string":
                try:
                    return json.loads(val)
                except Exception:
                    return {"raw": val}
            return val
        return {"ok": True}

    def close(self):
        if self.ws:
            try:
                self.ws.close()
            except Exception:
                pass


def cmd_daemon(args):
    """长驻 daemon 模式：stdin/stdout 或 unix socket"""
    sess = BidiSession(args.port)
    ok, err = sess.connect(timeout=15)
    if not ok:
        print(json.dumps({"err": f"connect failed: {err}", "port": args.port}), flush=True)
        sys.exit(3)
    print(json.dumps({"ok": True, "msg": "daemon ready", "session_id": sess.session_id}), flush=True)

    if args.socket:
        # unix socket 模式
        import os
        import socket as sock_mod
        import threading
        if os.path.exists(args.socket):
            os.unlink(args.socket)
        srv = sock_mod.socket(sock_mod.AF_UNIX, sock_mod.SOCK_STREAM)
        srv.bind(args.socket)
        srv.listen(5)
        os.chmod(args.socket, 0o600)
        print(json.dumps({"ok": True, "msg": f"listening on {args.socket}"}), flush=True)

        try:
            while True:
                conn, _ = srv.accept()
                t = threading.Thread(target=_handle_client, args=(conn, sess, False), daemon=True)
                t.start()
        except KeyboardInterrupt:
            pass
        finally:
            srv.close()
            if os.path.exists(args.socket):
                os.unlink(args.socket)
            sess.close()
    else:
        # stdin/stdout 模式
        try:
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    cmd_obj = json.loads(line)
                except json.JSONDecodeError as e:
                    print(json.dumps({"err": f"bad json: {e}"}), flush=True)
                    continue
                _handle_cmd(cmd_obj, sess)
        except KeyboardInterrupt:
            pass
        finally:
            sess.close()


def _handle_client(conn, sess, _dummy):
    """处理单个 unix socket client"""
    import os
    try:
        with conn.makefile('r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    cmd_obj = json.loads(line)
                    resp = _dispatch(cmd_obj, sess)
                    conn.sendall((json.dumps(resp) + "\n").encode())
                    if cmd_obj.get("cmd") == "stop":
                        break
                except json.JSONDecodeError as e:
                    conn.sendall((json.dumps({"err": f"bad json: {e}"}) + "\n").encode())
                except Exception as e:
                    conn.sendall((json.dumps({"err": f"handler: {e}"}) + "\n").encode())
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _handle_cmd(cmd_obj, sess):
    """stdin/stdout 模式的单条命令处理"""
    resp = _dispatch(cmd_obj, sess)
    print(json.dumps(resp), flush=True)
    if cmd_obj.get("cmd") == "stop":
        sys.exit(0)


def _dispatch(cmd_obj, sess):
    cmd = cmd_obj.get("cmd")
    if cmd == "stop":
        return {"ok": True, "msg": "stopping"}
    elif cmd == "ping":
        return {"ok": True}
    elif cmd == "query":
        return sess.query(cmd_obj.get("url_pattern"))
    elif cmd == "seek":
        return sess.seek(cmd_obj.get("seconds"), cmd_obj.get("url_pattern"))
    else:
        return {"err": f"unknown cmd: {cmd}"}


def cmd_call(args):
    """unix socket 客户端：发一条命令等响应"""
    import socket as sock_mod
    cmd_obj = {"cmd": args.cmd}
    if args.cmd == "seek":
        cmd_obj["seconds"] = args.seconds
    if args.url_pattern:
        cmd_obj["url_pattern"] = args.url_pattern
    try:
        s = sock_mod.socket(sock_mod.AF_UNIX, sock_mod.SOCK_STREAM)
        s.settimeout(15)
        s.connect(args.socket)
        s.sendall((json.dumps(cmd_obj) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
        s.close()
        resp = b"".join(chunks).decode().strip()
        print(resp)
        # 退出码：如果响应有 err 用 3
        try:
            obj = json.loads(resp)
            if "err" in obj:
                sys.exit(3)
        except Exception:
            sys.exit(1)
    except FileNotFoundError:
        print(json.dumps({"err": f"socket not found: {args.socket}"}), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"err": f"client: {e}"}), file=sys.stderr)
        sys.exit(1)


def cmd_query(args):
    sess = BidiSession(args.port)
    ok, err = sess.connect(timeout=10)
    if not ok:
        print(json.dumps({"err": err}), file=sys.stderr)
        sys.exit(3)
    try:
        result = sess.query(args.url_pattern)
        print(json.dumps(result))
    finally:
        sess.close()


def cmd_seek(args):
    sess = BidiSession(args.port)
    ok, err = sess.connect(timeout=10)
    if not ok:
        print(json.dumps({"err": err}), file=sys.stderr)
        sys.exit(3)
    try:
        result = sess.seek(args.seconds, args.url_pattern)
        print(json.dumps(result))
    finally:
        sess.close()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_daemon = sub.add_parser("daemon", help="长驻 daemon 模式（stdin/stdout 或 unix socket）")
    p_daemon.add_argument("--port", type=int, default=9222)
    p_daemon.add_argument("--socket", default=None, help="unix socket 路径（监听服务）")
    p_daemon.set_defaults(func=cmd_daemon)

    p_call = sub.add_parser("call", help="unix socket 客户端：发送一条 JSON 命令")
    p_call.add_argument("--socket", required=True, help="daemon 的 unix socket 路径")
    p_call.add_argument("--cmd", required=True, choices=["query", "seek", "ping", "stop"])
    p_call.add_argument("--seconds", type=float, help="seek 命令用")
    p_call.add_argument("--url-pattern", default=None)
    p_call.set_defaults(func=cmd_call)

    p_query = sub.add_parser("query", help="单次查询（每次新建 session）")
    p_query.add_argument("--port", type=int, default=9222)
    p_query.add_argument("--url-pattern", default=None)
    p_query.set_defaults(func=cmd_query)

    p_seek = sub.add_parser("seek", help="单次 seek")
    p_seek.add_argument("seconds", type=float)
    p_seek.add_argument("--port", type=int, default=9222)
    p_seek.add_argument("--url-pattern", default=None)
    p_seek.set_defaults(func=cmd_seek)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
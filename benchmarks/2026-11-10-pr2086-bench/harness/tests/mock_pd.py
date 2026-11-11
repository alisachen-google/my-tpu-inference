#!/usr/bin/env python3
"""A tiny stand-in for the SGLang P/D routers and engines, for dry runs of stress_driver.py on a CPU box.
mock_pd.py --port 18080 [--fail-above N] [--hang-above N] [--slow 0.002]
Implements /health, /metrics, /flush_cache, /generate (stream) and /v1/chat/completions (stream). Above
--fail-above concurrent requests it answers 503; above --hang-above it never sends a token."""
import argparse, json, threading, time, random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

A = None
STATE = {"inflight": 0, "prompt": 0, "cached": 0, "gen": 0, "reqs": 0, "used": 0}
LOCK = threading.Lock()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True})
        if self.path == "/metrics":
            with LOCK:
                s = dict(STATE)
            body = "\n".join([
                f'sglang:num_running_reqs{{m="x"}} {s["inflight"]}', f'sglang:num_queue_reqs{{m="x"}} 0',
                f'sglang:token_usage{{m="x"}} {s["used"]}', f'sglang:num_used_tokens{{m="x"}} {int(s["used"] * 1e6)}',
                f'sglang:prompt_tokens_total{{m="x"}} {s["prompt"]}', f'sglang:cached_tokens_total{{m="x"}} {s["cached"]}',
                f'sglang:generation_tokens_total{{m="x"}} {s["gen"]}', f'sglang:num_requests_total{{m="x"}} {s["reqs"]}', ""]).encode()
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)
            return
        self._json(404, {})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        if self.path == "/flush_cache":
            with LOCK:
                STATE["used"] = 0.0
            return self._json(200, {"ok": True})
        body = json.loads(raw or b"{}")
        with LOCK:
            STATE["inflight"] += 1; STATE["reqs"] += 1
            inflight = STATE["inflight"]
        try:
            if A.fail_above and inflight > A.fail_above:
                time.sleep(0.2)
                return self._json(503, {"error": "overloaded"})
            if A.hang_above and inflight > A.hang_above:
                time.sleep(3600)
            if self.path == "/generate":
                ids = body.get("input_ids") or []
                sp = body.get("sampling_params") or {}
                max_new = int(sp.get("max_new_tokens", 16))
                cached = int(len(ids) * 0.3) if len(ids) > 64 else 0
                return self._stream_generate(len(ids), cached, max_new)
            if self.path == "/v1/chat/completions":
                msgs = body.get("messages") or []
                ptoks = 0
                for m in msgs:
                    c = m.get("content")
                    if isinstance(c, str):
                        ptoks += len(c.split())
                    else:
                        for part in c or []:
                            ptoks += len((part.get("text") or "").split()) if part.get("type") == "text" else 400
                if not body.get("stream"):
                    time.sleep(A.slow * ptoks / 1000 + 0.05)
                    return self._json(200, {"choices": [{"message": {"role": "assistant", "content": "Step 1: 16-3-4=9. Step 2: 9*2=18.\n#### 18"}, "index": 0}],
                                            "usage": {"prompt_tokens": ptoks, "completion_tokens": 30}})
                return self._stream_chat(ptoks, int(body.get("max_tokens", 16)), body.get("ignore_eos", False))
            self._json(404, {})
        finally:
            with LOCK:
                STATE["inflight"] -= 1

    def _head(self):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()

    def _chunk(self, s):
        b = s.encode()
        self.wfile.write(f"{len(b):x}\r\n".encode() + b + b"\r\n"); self.wfile.flush()

    def _stream_generate(self, ptoks, cached, max_new):
        self._head()
        time.sleep(A.slow * max(1, ptoks - cached) / 1000 + 0.05)
        with LOCK:
            STATE["prompt"] += ptoks; STATE["cached"] += cached; STATE["used"] = min(0.9, STATE["used"] + ptoks / 2e6)
        for i in range(max_new):
            meta = {"prompt_tokens": ptoks, "completion_tokens": i + 1, "cached_tokens": cached, "finish_reason": None if i + 1 < max_new else {"type": "length"}}
            self._chunk("data: " + json.dumps({"text": f" w{i}", "output_ids": [1000 + i], "meta_info": meta}) + "\n\n")
            time.sleep(0.002)
        with LOCK:
            STATE["gen"] += max_new
        self._chunk("data: [DONE]\n\n"); self._chunk("")

    def _stream_chat(self, ptoks, max_new, ignore_eos):
        self._head()
        time.sleep(A.slow * ptoks / 1000 + 0.05)
        with LOCK:
            STATE["prompt"] += ptoks; STATE["used"] = min(0.9, STATE["used"] + ptoks / 2e6)
        n = max_new if ignore_eos else min(max_new, 40)
        for i in range(n):
            text = " w%d" % i if ignore_eos else (" step %d" % i if i < n - 1 else "\n#### 18")
            self._chunk("data: " + json.dumps({"choices": [{"delta": {"content": text}, "index": 0}]}) + "\n\n")
            time.sleep(0.002)
        self._chunk("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": ptoks, "completion_tokens": n, "prompt_tokens_details": {"cached_tokens": 0}}}) + "\n\n")
        with LOCK:
            STATE["gen"] += n
        self._chunk("data: [DONE]\n\n"); self._chunk("")


def main():
    global A
    ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=18080); ap.add_argument("--fail-above", type=int, default=0)
    ap.add_argument("--hang-above", type=int, default=0); ap.add_argument("--slow", type=float, default=0.002)
    A = ap.parse_args()
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", A.port), H).serve_forever()


if __name__ == "__main__":
    main()

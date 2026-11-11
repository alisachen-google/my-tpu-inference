#!/usr/bin/env python3
"""Mixed-load stress of a P/D deployment through its routers: ramp the concurrency until the system starts to
fail, drain, verify, repeat until the time is up.

Every request is drawn from a seeded mix:
  text      input_ids of a random length in [1, MAX_INPUT] (short / medium / long / very long buckets), greedy or
            sampled, 1..MAX_OUTPUT output tokens with ignore_eos, through /generate (token-exact);
  image     (multimodal profiles) 1..MAX_IMAGES noise JPEGs of random size plus random-length text, through
            /v1/chat/completions, streamed;
  gsm8k     a GSM8K question through /v1/chat/completions, greedy, answer checked (quality under load);
  return    a continuation of an earlier session (its prompt + its output + a new block), through the same pinned
            router when there is one (sticky routing), so the prefix is a cache hit, a host-tier load or a recall
            from decode DRAM;
  abort     a streaming request the client closes after the first token (pages must be freed).

A cycle ramps the concurrency geometrically (CONC_START, x CONC_FACTOR, up to CONC_MAX), holding each level for
STEP_SECONDS. A level fails the ramp when its error rate is above FAIL_ERROR_RATE, a request hangs (no token for
HANG_SECONDS), an engine or router stops answering /health, or TTFT p50 is above TTFT_SAT_SECONDS (saturation).
Then the traffic is drained (no new requests; in-flight ones finish within DRAIN_SECONDS), every engine must report
idle (no running, queued or in-transfer requests), a verification batch of VERIFY_N mixed requests must all succeed
with their full output, the GSM8K sample must stay within GSM8K_TOLERANCE of the idle baseline, and after a
flush_cache the KV pools must be empty (no leaked pages). The next cycle starts from CONC_START again with a new
seed. The verdict (PASS/FAIL with reasons) goes to <out>/<run>_stress_verdict.json; every request to
<out>/<run>_stress_requests.jsonl, every level to <out>/<run>_stress_levels.jsonl.
"""
from __future__ import annotations
import argparse, base64, io, json, os, random, statistics, sys, threading, time, uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gsm8k_eval  # noqa: E402

GAUGES = ("sglang:num_running_reqs", "sglang:num_queue_reqs", "sglang:token_usage", "sglang:num_used_tokens",
          "sglang:swa_token_usage", "sglang:num_prefill_inflight_queue_reqs", "sglang:num_decode_prealloc_queue_reqs",
          "sglang:num_decode_transfer_queue_reqs", "sglang:num_bootstrap_failed_reqs_total",
          "sglang:kv_transfer_oldest_inflight_age_seconds")
COUNTERS = ("sglang:prompt_tokens_total", "sglang:cached_tokens_total", "sglang:generation_tokens_total", "sglang:num_requests_total")


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())


def pct(v, p):
    if not v:
        return None
    s = sorted(v)
    return s[max(0, min(len(s) - 1, int(round((len(s) - 1) * p))))]


# ----------------------------------------------------------------------------------------------------------------
# Engines: health, metrics, idle and leak checks
# ----------------------------------------------------------------------------------------------------------------
class Engines:
    def __init__(self, prefills, decodes, lb, pins):
        self.prefills, self.decodes, self.lb, self.pins = prefills, decodes, lb, pins
        self.names = {u: f"prefill-{i}" for i, u in enumerate(prefills)}
        self.names.update({u: f"decode-{i}" for i, u in enumerate(decodes)})

    def health(self, timeout=30):
        """Endpoints that did not answer /health with 200 within `timeout`, as "<url> <why>" strings. A busy engine
        can take tens of seconds to answer (its HTTP loop is shared with request intake, see the slow-health
        observation in the report), so a single slow answer is not a dead server: the driver requires repeated
        failures, and a refused connection, before it calls one."""
        bad = []
        self.last_health_latency = {}
        for u in self.prefills + self.decodes + [self.lb] + list(self.pins.values()):
            t0 = time.perf_counter()
            try:
                r = requests.get(u.rstrip("/") + "/health", timeout=timeout)
                if r.status_code != 200:
                    bad.append(f"{u} http {r.status_code}")
            except Exception as e:  # noqa: BLE001
                bad.append(f"{u} {type(e).__name__} after {time.perf_counter() - t0:.0f} s")
            self.last_health_latency[self.names.get(u, u)] = round(time.perf_counter() - t0, 2)
        return bad

    def metrics(self, u):
        out = {}
        try:
            text = requests.get(u.rstrip("/") + "/metrics", timeout=15).text
        except Exception as e:  # noqa: BLE001
            return {"error": repr(e)[:120]}
        for line in text.splitlines():
            if not line or line.startswith("#"):
                continue
            name = line.split("{", 1)[0].split(" ", 1)[0]
            if name in GAUGES or name in COUNTERS:
                try:
                    v = float(line.rsplit(" ", 1)[1])
                except ValueError:
                    continue
                # gauges: the max over label sets (DP ranks); counters: the sum
                out[name] = (out.get(name, 0) + v) if name in COUNTERS else max(out.get(name, 0), v)
        return out

    def snapshot(self):
        return {self.names[u]: self.metrics(u) for u in self.prefills + self.decodes}

    @staticmethod
    def busy(m):
        keys = ("sglang:num_running_reqs", "sglang:num_queue_reqs", "sglang:num_prefill_inflight_queue_reqs",
                "sglang:num_decode_prealloc_queue_reqs", "sglang:num_decode_transfer_queue_reqs")
        return {k: m.get(k, 0) for k in keys if m.get(k, 0)}

    def wait_idle(self, timeout, settle=30):
        """Every engine reports no running / queued / in-transfer requests for `settle` seconds."""
        t_end = time.time() + timeout
        idle_since = None
        last = None
        while time.time() < t_end:
            snap = self.snapshot()
            last = {n: self.busy(m) for n, m in snap.items()}
            if not any(last.values()):
                idle_since = idle_since or time.time()
                if time.time() - idle_since >= settle:
                    return True, last, snap
            else:
                idle_since = None
            time.sleep(5)
        return False, last, self.snapshot()

    def flush(self):
        bad = []
        for u in self.decodes + self.prefills:
            ok = False
            for _ in range(12):
                try:
                    if requests.post(u.rstrip("/") + "/flush_cache", timeout=300).status_code == 200:
                        ok = True
                        break
                except Exception:  # noqa: BLE001
                    pass
                time.sleep(10)
            if not ok:
                bad.append(self.names[u])
        return bad


# ----------------------------------------------------------------------------------------------------------------
# Workload
# ----------------------------------------------------------------------------------------------------------------
class Corpus:
    """Token ids and text of the make_prompts.py corpus (<N>.jsonl rows of at least N tokens)."""

    def __init__(self, tok, prompts_dir, max_tokens):
        self.tok = tok
        self.rows = []
        best = None
        for p in sorted(Path(prompts_dir).glob("*.jsonl"), key=lambda p: int(p.stem)):
            if int(p.stem) >= max_tokens or best is None or int(p.stem) > int(best.stem):
                best = p
            if int(p.stem) >= max_tokens:
                break
        for l in open(best):
            if l.strip():
                text = json.loads(l)["text"]
                ids = tok(text, add_special_tokens=False)["input_ids"]
                self.rows.append(ids)
        self.max_len = min(len(r) for r in self.rows)
        self.cache = {}

    def ids(self, rng, n):
        row = rng.randrange(len(self.rows))
        start = rng.randrange(0, max(1, self.max_len - n)) if n < self.max_len else 0
        return self.rows[row][start:start + n]

    def text(self, rng, n):
        return self.tok.decode(self.ids(rng, n), skip_special_tokens=True)


def noise_jpeg(rng, side_min=64, side_max=1024):
    from PIL import Image, ImageDraw
    w, h = rng.randint(side_min, side_max), rng.randint(side_min, side_max)
    img = Image.new("RGB", (w, h), tuple(rng.randint(0, 255) for _ in range(3)))
    d = ImageDraw.Draw(img)
    for _ in range(rng.randint(3, 24)):
        x0, y0 = rng.randint(0, w - 1), rng.randint(0, h - 1)
        x1, y1 = rng.randint(x0, w), rng.randint(y0, h)
        d.rectangle([x0, y0, x1, y1], fill=tuple(rng.randint(0, 255) for _ in range(3)))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=rng.randint(50, 90))
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode(), (w, h)


class Workload:
    LENGTH_BUCKETS = (("short", 1, 256, 0.40), ("medium", 257, 8192, 0.25), ("long", 8193, 131072, 0.20), ("xlong", 131073, None, 0.15))

    def __init__(self, a, tok, corpus, gsm8k, pins):
        self.a, self.tok, self.corpus, self.gsm8k, self.pins = a, tok, corpus, gsm8k, pins
        self.sessions = []  # finished requests that can be continued
        self.lock = threading.Lock()
        self.pin_keys = sorted(pins)

    def length(self, rng, cap):
        r = rng.random()
        acc = 0
        for name, lo, hi, w in self.LENGTH_BUCKETS:
            acc += w
            if r <= acc or name == "xlong":
                hi = cap if hi is None else min(hi, cap)
                lo = min(lo, hi)
                return name, rng.randint(lo, hi)
        return "short", 1

    def build(self, rng, phase):
        a = self.a
        kind = "text"
        r = rng.random()
        with self.lock:
            have_sessions = len(self.sessions) > 0
        if have_sessions and r < a.p_return:
            kind = "return"
        elif r < a.p_return + a.p_gsm8k:
            kind = "gsm8k"
        elif a.multimodal and r < a.p_return + a.p_gsm8k + a.p_image:
            kind = "image"
        abort = kind in ("text", "image") and rng.random() < a.p_abort
        route = self.lb_for(rng)
        out_tokens = rng.randint(1, a.max_output) if rng.random() < 0.9 else rng.randint(a.max_output, 2 * a.max_output)
        greedy = rng.random() < 0.7
        req = {"kind": kind, "abort": abort, "route": route[0], "url": route[1], "phase": phase, "id": uuid.uuid4().hex[:12]}
        req = self._build(rng, req, kind, out_tokens, greedy)
        # prompt + output must fit the context (a request over it is a 400, not a stress finding)
        est = req.get("prompt_tokens") or 0
        req["out_tokens"] = max(1, min(req["out_tokens"], a.context_len - est - 64))
        return req

    def chat_tokens(self, messages):
        """Estimate of a chat prompt's tokens: text through the tokenizer, images at the per-image budget, plus template."""
        n = 64
        for m in messages:
            c = m.get("content")
            if isinstance(c, str):
                n += len(self.tok(c, add_special_tokens=False)["input_ids"]) + 8
            else:
                for part in c or []:
                    n += self.a.image_tokens if part.get("type") == "image_url" else len(self.tok(part.get("text") or "", add_special_tokens=False)["input_ids"])
                n += 8
        return n

    def _build(self, rng, req, kind, out_tokens, greedy):
        a = self.a
        if kind == "gsm8k":
            q = rng.choice(self.gsm8k)
            req.update(endpoint="chat", gold=q["gold"], out_tokens=512, ignore_eos=False, greedy=True,
                       messages=[{"role": "user", "content": gsm8k_eval.PROMPT.format(q=q["question"])}], bucket="gsm8k", prompt_tokens=256)
            return req
        if kind == "return":
            with self.lock:
                s = self.sessions.pop(rng.randrange(len(self.sessions)))
            req["route"], req["url"] = s["route"], s["url"]  # sticky: the pair that served the session
            req["session"] = s["id"]
            req["turn"] = s.get("turn", 1) + 1
            if s["endpoint"] == "generate":
                new = self.corpus.ids(rng, rng.randint(64, 16384))
                ids = (s["input_ids"] + (s.get("output_ids") or []) + new)[: a.max_input]
                req.update(endpoint="generate", input_ids=ids, prompt_tokens=len(ids), reusable=len(s["input_ids"]) + len(s.get("output_ids") or []),
                           out_tokens=out_tokens, ignore_eos=True, greedy=greedy, bucket="return")
            else:
                msgs = list(s["messages"]) + [{"role": "assistant", "content": s.get("output_text") or "..."}]
                used = s.get("prompt_tokens") or self.chat_tokens(msgs)
                room = a.max_input - used - 512
                if room < 256:
                    return self._build(rng, req, "text", out_tokens, greedy)  # the session is at the context cap: a new one
                add, k = [], 0
                if a.multimodal and rng.random() < 0.5:
                    k = rng.randint(1, max(1, min(a.max_images // 8, room // (2 * a.image_tokens))))
                    add = [{"type": "image_url", "image_url": {"url": noise_jpeg(rng)[0]}} for _ in range(k)]
                    req["images"] = k
                n = rng.randint(32, max(32, min(4096, room - k * a.image_tokens - 64)))
                msgs.append({"role": "user", "content": add + [{"type": "text", "text": self.corpus.text(rng, n) + "\nContinue."}]})
                req.update(endpoint="chat", messages=msgs, out_tokens=out_tokens, ignore_eos=True, greedy=greedy, bucket="return",
                           prompt_tokens=used + n + k * a.image_tokens + 16)
            return req
        if kind == "image":
            k = rng.randint(1, a.max_images)
            cap = max(1, a.max_input - k * a.image_tokens - 256)
            bucket, n = self.length(rng, cap)
            imgs = [noise_jpeg(rng) for _ in range(k)]
            content = [{"type": "image_url", "image_url": {"url": d}} for d, _ in imgs]
            content.append({"type": "text", "text": self.corpus.text(rng, n) + "\nDescribe the images and the text above."})
            req.update(endpoint="chat", messages=[{"role": "user", "content": content}], out_tokens=out_tokens, ignore_eos=True,
                       greedy=greedy, bucket=bucket, images=k, image_sizes=[s for _, s in imgs], text_tokens=n,
                       prompt_tokens=n + k * a.image_tokens + 80)
            return req
        bucket, n = self.length(rng, a.max_input - 64)
        salt = self.tok(f"Session {req['id']} {rng.random():.6f}\n", add_special_tokens=False)["input_ids"]
        ids = (salt + self.corpus.ids(rng, n))[: a.max_input]
        req.update(endpoint="generate", input_ids=ids, prompt_tokens=len(ids), out_tokens=out_tokens, ignore_eos=True, greedy=greedy, bucket=bucket)
        return req

    def lb_for(self, rng):
        if self.pin_keys and rng.random() < self.a.p_sticky:
            k = rng.choice(self.pin_keys)
            return k, self.pins[k]
        return "lb", self.a.lb

    def remember(self, req, res):
        if req["kind"] in ("gsm8k",) or req.get("abort") or res.get("error") or req.get("turn", 1) >= 4:
            return
        s = {"id": req.get("session") or req["id"], "route": req["route"], "url": req["url"], "endpoint": req["endpoint"],
             "turn": req.get("turn", 1), "prompt_tokens": req.get("prompt_tokens")}
        if res.get("prompt_tokens"):
            s["prompt_tokens"] = res["prompt_tokens"]
        if req["endpoint"] == "generate":
            out_ids = res.get("output_ids") or []
            if not out_ids and res.get("text"):
                out_ids = self.tok(res["text"], add_special_tokens=False)["input_ids"]
            s["input_ids"], s["output_ids"] = req["input_ids"], out_ids
        else:
            s["messages"], s["output_text"] = req["messages"], res.get("text") or ""
        with self.lock:
            self.sessions.append(s)
            if len(self.sessions) > self.a.max_sessions:
                self.sessions.pop(0)


# ----------------------------------------------------------------------------------------------------------------
# Sending
# ----------------------------------------------------------------------------------------------------------------
def send(req, timeout, ttft_timeout):
    """Streams one request; returns timings, token counts and the output (ids or text)."""
    url = req["url"].rstrip("/")
    t0 = time.perf_counter()
    res = {"ttft_s": None, "e2e_s": None, "completion_tokens": None, "cached_tokens": None, "error": None, "status": None, "chunks": 0}
    sp = {"temperature": 0 if req["greedy"] else 0.8, "max_new_tokens": req["out_tokens"], "ignore_eos": req["ignore_eos"]}
    try:
        if req["endpoint"] == "generate":
            body = {"input_ids": req["input_ids"], "sampling_params": sp, "stream": True, "return_logprob": False}
            path = "/generate"
        else:
            body = {"model": req.get("model"), "messages": req["messages"], "stream": True, "max_tokens": req["out_tokens"],
                    "temperature": sp["temperature"], "ignore_eos": req["ignore_eos"], "stream_options": {"include_usage": True}}
            path = "/v1/chat/completions"
        last_tok = time.perf_counter()
        text_parts, last, out_ids = [], None, []
        with requests.post(url + path, json=body, stream=True, timeout=(30, ttft_timeout)) as r:
            res["status"] = r.status_code
            if r.status_code != 200:
                res["error"] = f"http {r.status_code}: {r.text[:200]}"
                return res
            for line in r.iter_lines():
                if time.perf_counter() - t0 > timeout:
                    res["error"] = f"timeout after {timeout:.0f} s"
                    return res
                if not line or not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if payload == b"[DONE]":
                    break
                chunk = json.loads(payload)
                res["chunks"] += 1
                if res["ttft_s"] is None:
                    res["ttft_s"] = time.perf_counter() - t0
                    if req.get("abort"):
                        res["aborted"] = True
                        r.close()
                        break
                last_tok = time.perf_counter()
                if req["endpoint"] == "generate":
                    # streamed chunks carry incremental text / output_ids deltas; meta_info is cumulative
                    last = chunk
                    out_ids.extend(chunk.get("output_ids") or [])
                    text_parts.append(chunk.get("text") or "")
                else:
                    for c in chunk.get("choices") or []:
                        text_parts.append((c.get("delta") or {}).get("content") or "")
                    if chunk.get("usage"):
                        last = chunk
        res["e2e_s"] = time.perf_counter() - t0
        if req["endpoint"] == "generate":
            meta = (last or {}).get("meta_info", {})
            res.update(completion_tokens=meta.get("completion_tokens"), cached_tokens=meta.get("cached_tokens"),
                       prompt_tokens=meta.get("prompt_tokens"), cached_tokens_details=meta.get("cached_tokens_details"),
                       finish_reason=meta.get("finish_reason"), output_ids=out_ids, text="".join(text_parts))
        else:
            usage = (last or {}).get("usage") or {}
            res.update(completion_tokens=usage.get("completion_tokens"), prompt_tokens=usage.get("prompt_tokens"),
                       cached_tokens=(usage.get("prompt_tokens_details") or {}).get("cached_tokens"), text="".join(text_parts))
        if res["ttft_s"] is None and not res.get("aborted"):
            res["error"] = "no token received"
        return res
    except requests.exceptions.ReadTimeout:
        res["error"] = f"no token for {hang_seconds:.0f} s (saturated or stuck)"
        res["ttft_timeout"] = True
        res["e2e_s"] = time.perf_counter() - t0
        return res
    except Exception as e:  # noqa: BLE001
        res["error"] = repr(e)[:200]
        res["e2e_s"] = time.perf_counter() - t0
        return res


def judge(req, res):
    """A request passed when it returned 200, produced every token it asked for (ignore_eos) and, for gsm8k, an
    answer; an abort passed when the first token came."""
    if res.get("error"):
        return False, res["error"]
    if res.get("aborted"):
        return True, "aborted after first token"
    if req["kind"] == "gsm8k":
        pred = gsm8k_eval.parse_answer(res.get("text") or "")
        res["correct"] = gsm8k_eval.same(pred, req["gold"])
        return True, "ok"
    ct = res.get("completion_tokens")
    if ct is None or ct < req["out_tokens"]:
        return False, f"short output {ct} of {req['out_tokens']}"
    return True, "ok"


# ----------------------------------------------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------------------------------------------
class Driver:
    def __init__(self, a, engines, workload):
        self.a, self.eng, self.wl = a, engines, workload
        self.out = Path(a.out)
        self.req_f = open(self.out / f"{a.run}_stress_requests.jsonl", "a")
        self.lvl_f = open(self.out / f"{a.run}_stress_levels.jsonl", "a")
        self.log_f = open(self.out / f"{a.run}_stress.log", "a")
        self.lock = threading.Lock()
        self.failures = []  # verdict reasons
        self.health_slow = []  # (time, level, conc, what) for health probes that failed once but recovered
        self.health_latency_max = {}  # engine -> slowest successful /health answer seen, seconds
        self.last_completion = time.time()
        self.in_flight = 0
        self.stop = threading.Event()
        self.pool = ThreadPoolExecutor(max_workers=a.conc_max + 16)

    def log(self, msg):
        line = f"{now()} {msg}"
        print(line, flush=True)
        self.log_f.write(line + "\n"); self.log_f.flush()

    def record(self, req, res, level, cycle):
        ok, why = judge(req, res)
        rec = {"t": now(), "cycle": cycle, "level": level, "phase": req["phase"], "kind": req["kind"], "bucket": req.get("bucket"),
               "route": req["route"], "endpoint": req["endpoint"], "prompt_tokens": req.get("prompt_tokens") or res.get("prompt_tokens"),
               "images": req.get("images"), "out_tokens": req["out_tokens"], "greedy": req["greedy"], "abort": req.get("abort"),
               "turn": req.get("turn", 1), "ok": ok, "why": why, "ttft_s": res.get("ttft_s"), "e2e_s": res.get("e2e_s"),
               "completion_tokens": res.get("completion_tokens"), "cached_tokens": res.get("cached_tokens"),
               "cached_tokens_details": res.get("cached_tokens_details"), "status": res.get("status"), "hang": res.get("hang"),
               "correct": res.get("correct")}
        with self.lock:
            self.req_f.write(json.dumps(rec) + "\n"); self.req_f.flush()
        return rec

    def one(self, req, level, cycle, sink):
        req["model"] = self.a.served_model
        try:
            res = send(req, self.a.request_timeout, self.a.ttft_timeout)
        except Exception as e:  # noqa: BLE001
            res = {"error": repr(e)[:200]}
        rec = self.record(req, res, level, cycle)
        if rec["ok"]:
            self.wl.remember(req, res)
        with self.lock:
            self.in_flight -= 1
            self.last_completion = time.time()
            sink.append(rec)

    def run_level(self, conc, seconds, cycle, level, phase, min_requests):
        """Holds `conc` requests in flight for `seconds` (and at least min_requests), returns the level's stats."""
        rng = random.Random(self.a.seed * 1000 + cycle * 100 + level)
        recs = []
        t_end = time.time() + seconds
        submitted = 0
        health_t = time.time()
        fail = None
        health_bad_streak = 0
        while True:
            with self.lock:
                inflight = self.in_flight
            if (time.time() < t_end or submitted < min_requests) and inflight < conc and not self.stop.is_set():
                try:
                    req = self.wl.build(rng, phase)
                except Exception as e:  # noqa: BLE001
                    self.log(f"build failed: {e!r}")
                    time.sleep(1)
                    continue
                with self.lock:
                    self.in_flight += 1
                submitted += 1
                self.pool.submit(self.one, req, level, cycle, recs)
                continue
            if time.time() >= t_end and submitted >= min_requests:
                break
            time.sleep(0.2)
            if time.time() - health_t > 30:
                health_t = time.time()
                bad = self.eng.health()
                for n_, lat in (getattr(self.eng, "last_health_latency", None) or {}).items():
                    self.health_latency_max[n_] = max(self.health_latency_max.get(n_, 0), lat)
                if bad:
                    health_bad_streak += 1
                    self.health_slow.append((now(), level, conc, bad))
                    self.log(f"level {level} conc {conc}: health probe {health_bad_streak} failed: {bad}")
                    # dead when refused, or when three probes in a row (about 90 s plus timeouts) get no answer
                    if health_bad_streak >= 3 or any("ConnectionError" in b or "http 5" in b for b in bad):
                        fail = f"health: {bad} ({health_bad_streak} probes in a row)"
                        self.log(f"level {level} conc {conc}: {fail}")
                        break
                else:
                    health_bad_streak = 0
                with self.lock:
                    stalled = inflight > 0 and time.time() - self.last_completion > self.a.hang_seconds
                if stalled:
                    fail = f"hang: no completion for {self.a.hang_seconds:.0f} s with {inflight} in flight"
                    self.log(f"level {level} conc {conc}: {fail}")
                    break
        return recs, submitted, fail

    def level_stats(self, recs):
        ok = [r for r in recs if r["ok"]]
        err = [r for r in recs if not r["ok"]]
        hangs = [r for r in recs if r.get("hang")]
        g = [r for r in recs if r["kind"] == "gsm8k" and r["ok"]]
        ttft = [r["ttft_s"] for r in ok if r.get("ttft_s") is not None]
        e2e = [r["e2e_s"] for r in ok if r.get("e2e_s") is not None]
        comp = sum(r.get("completion_tokens") or 0 for r in ok)
        prompt = sum(r.get("prompt_tokens") or 0 for r in ok)
        cached = sum(r.get("cached_tokens") or 0 for r in ok)
        return {"requests": len(recs), "ok": len(ok), "errors": len(err), "hangs": len(hangs),
                "error_rate": len(err) / len(recs) if recs else 0, "ttft_p50": pct(ttft, 0.5), "ttft_p95": pct(ttft, 0.95),
                "e2e_p50": pct(e2e, 0.5), "e2e_p95": pct(e2e, 0.95), "completion_tokens": comp, "prompt_tokens": prompt,
                "cached_tokens": cached, "client_hit": cached / prompt if prompt else None,
                "gsm8k_acc": (sum(1 for r in g if r.get("correct")) / len(g)) if g else None, "gsm8k_n": len(g),
                "kinds": {k: sum(1 for r in recs if r["kind"] == k) for k in ("text", "image", "gsm8k", "return")},
                "buckets": {b: sum(1 for r in recs if r.get("bucket") == b) for b in ("short", "medium", "long", "xlong", "return", "gsm8k")},
                "max_prompt_tokens": max((r.get("prompt_tokens") or 0 for r in recs), default=0),
                "max_images": max((r.get("images") or 0 for r in recs), default=0),
                "aborts": sum(1 for r in recs if r.get("abort")),
                "error_samples": [r["why"][:160] for r in err[:5]]}

    def wait_inflight(self, timeout):
        t_end = time.time() + timeout
        while time.time() < t_end:
            with self.lock:
                if self.in_flight == 0:
                    return True
            time.sleep(2)
        with self.lock:
            return self.in_flight == 0

    def drain_and_verify(self, cycle, baseline, phase_name):
        a = self.a
        verdict = {"cycle": cycle, "phase": phase_name, "ok": True, "reasons": []}
        # 1. in-flight requests finish
        self.log(f"cycle {cycle}: draining (in flight {self.in_flight})")
        t0 = time.time()
        if not self.wait_inflight(a.drain_seconds):
            verdict["ok"] = False; verdict["reasons"].append(f"drain: {self.in_flight} requests still in flight after {a.drain_seconds} s")
        verdict["drain_s"] = round(time.time() - t0, 1)
        # 2. engines idle
        idle, busy, snap = self.eng.wait_idle(300)
        verdict["idle"] = idle; verdict["busy_after_drain"] = {k: v for k, v in busy.items() if v}
        if not idle:
            verdict["ok"] = False; verdict["reasons"].append(f"engines not idle after drain: {verdict['busy_after_drain']}")
        bad = self.eng.health()
        if bad:
            verdict["ok"] = False; verdict["reasons"].append(f"health after drain: {bad}")
        verdict["bootstrap_failed_total"] = {n: m.get("sglang:num_bootstrap_failed_reqs_total", 0) for n, m in snap.items()}
        # 3. verification batch: every request must pass
        self.log(f"cycle {cycle}: verification batch of {a.verify_n} at concurrency {a.verify_conc}")
        recs, _, fail = self.run_level(a.verify_conc, 0, cycle, 900 + cycle, "verify", a.verify_n)
        self.wait_inflight(a.drain_seconds)
        st = self.level_stats(recs)
        verdict["verify"] = st
        if fail or st["errors"] or st["requests"] < a.verify_n:
            verdict["ok"] = False; verdict["reasons"].append(f"verification batch: {st['errors']} of {st['requests']} failed ({fail or st['error_samples']})")
        # 4. quality gate
        self.log(f"cycle {cycle}: GSM8K gate ({a.gsm8k_n} questions)")
        g = gsm8k_eval.run(a.lb, a.served_model, gsm8k_eval.load(a.gsm8k, a.gsm8k_n, a.seed), a.gsm8k_conc)
        cmp_ = gsm8k_eval.compare(baseline, g)
        verdict["gsm8k"] = {"acc": g["acc"], "baseline_acc": baseline["acc"], "errors": g["errors"], **cmp_}
        json.dump(g, open(self.out / f"{a.run}_stress_gsm8k_c{cycle}.json", "w"))
        if g["acc"] is None or g["errors"] or g["acc"] < baseline["acc"] - a.gsm8k_tolerance:
            verdict["ok"] = False; verdict["reasons"].append(f"gsm8k: acc {g['acc']} vs baseline {baseline['acc']} (errors {g['errors']})")
        # 5. leak check: flush, then the pools must be empty
        idle, _, _ = self.eng.wait_idle(120)
        bad = self.eng.flush()
        if bad:
            verdict["ok"] = False; verdict["reasons"].append(f"flush_cache failed on {bad}")
        time.sleep(10)
        snap = self.eng.snapshot()
        usage = {n: round(m.get("sglang:token_usage", 0), 4) for n, m in snap.items()}
        verdict["token_usage_after_flush"] = usage
        leak = {n: u for n, u in usage.items() if u > a.leak_token_usage}
        if leak:
            verdict["ok"] = False; verdict["reasons"].append(f"KV pages left after flush (leak): {leak}")
        self.log(f"cycle {cycle}: verify {'PASS' if verdict['ok'] else 'FAIL'} {verdict['reasons']}")
        return verdict

    def run(self):
        a = self.a
        t_start = time.time()
        t_deadline = t_start + a.duration
        self.log(f"stress start: duration {a.duration} s, conc {a.conc_start}..{a.conc_max} x{a.conc_factor}, step {a.step_seconds} s, "
                 f"max input {a.max_input}, max images {a.max_images if a.multimodal else 0}, pins {sorted(self.wl.pins)}")
        bad = self.eng.health()
        if bad:
            self.failures.append(f"unhealthy at start: {bad}")
            return self.finish(t_start, [], None)
        self.log(f"GSM8K baseline on idle engines ({a.gsm8k_n} questions)")
        baseline = gsm8k_eval.run(a.lb, a.served_model, gsm8k_eval.load(a.gsm8k, a.gsm8k_n, a.seed), a.gsm8k_conc)
        json.dump(baseline, open(self.out / f"{a.run}_stress_gsm8k_baseline.json", "w"))
        self.log(f"GSM8K baseline acc {baseline['acc']} errors {baseline['errors']} e2e_p50 {baseline['e2e_p50']}")
        if baseline["acc"] is None or baseline["errors"]:
            self.failures.append(f"gsm8k baseline failed: {baseline['errors']} errors")
            return self.finish(t_start, [], baseline)
        cycles = []
        cycle = 0
        while time.time() < t_deadline and (a.cycles_max == 0 or cycle < a.cycles_max):
            cycle += 1
            conc, level = a.conc_start, 0
            cyc = {"cycle": cycle, "levels": [], "last_good_conc": None, "failed_at": None, "fail_reason": None, "t0": now()}
            while time.time() < t_deadline:
                level += 1
                remaining = t_deadline - time.time()
                hold = min(a.step_seconds, max(60, remaining))
                self.log(f"cycle {cycle} level {level}: concurrency {conc} for {hold:.0f} s")
                t0 = time.time()
                recs, submitted, fail = self.run_level(conc, hold, cycle, level, "ramp", a.step_min_requests)
                # let the level's own requests finish before judging it (but keep the next level flowing: cap the wait)
                self.wait_inflight(min(a.drain_seconds, 180))
                st = self.level_stats(recs)
                st.update(cycle=cycle, level=level, conc=conc, hold_s=round(time.time() - t0, 1), submitted=submitted, fail=fail, t=now())
                snap = self.eng.snapshot()
                st["engines"] = {n: {k.split(":")[1]: v for k, v in m.items() if k in GAUGES} for n, m in snap.items()}
                self.lvl_f.write(json.dumps(st) + "\n"); self.lvl_f.flush()
                cyc["levels"].append({k: st[k] for k in ("level", "conc", "requests", "errors", "hangs", "error_rate", "ttft_p50", "ttft_p95", "e2e_p95", "client_hit", "gsm8k_acc", "max_prompt_tokens", "max_images", "fail")})
                failed = fail is not None or st["error_rate"] > a.fail_error_rate or st["hangs"] > 0 \
                    or (st["ttft_p50"] is not None and st["ttft_p50"] > a.ttft_sat_seconds)
                self.log(f"cycle {cycle} level {level} conc {conc}: {st['ok']} ok / {st['errors']} err / {st['hangs']} hang, "
                         f"ttft p50 {st['ttft_p50'] and round(st['ttft_p50'], 1)} p95 {st['ttft_p95'] and round(st['ttft_p95'], 1)} s, "
                         f"hit {st['client_hit'] and round(100 * st['client_hit'], 1)}%, gsm8k {st['gsm8k_acc']} ({st['gsm8k_n']}), "
                         f"max prompt {st['max_prompt_tokens']} imgs {st['max_images']} -> {'FAIL' if failed else 'pass'}")
                if failed:
                    cyc["failed_at"] = conc
                    cyc["fail_reason"] = fail or (f"error rate {st['error_rate']:.3f}" if st["error_rate"] > a.fail_error_rate else
                                                  f"{st['hangs']} hangs" if st["hangs"] else f"ttft p50 {st['ttft_p50']:.0f} s")
                    cyc["fail_errors"] = st["error_samples"]
                    # a crash or hang is a verdict failure in itself; an error-rate or saturation failure is the
                    # expected end of the ramp, judged by what follows (drain and verify)
                    if fail and fail.startswith("health"):
                        self.failures.append(f"cycle {cycle}: server or router down at concurrency {conc}: {fail}")
                    if st["hangs"] or (fail and fail.startswith("hang")):
                        self.failures.append(f"cycle {cycle}: hang at concurrency {conc}: {fail or st['error_samples']}")
                    break
                cyc["last_good_conc"] = conc
                if conc >= a.conc_max:
                    self.log(f"cycle {cycle}: reached CONC_MAX {a.conc_max} without failing")
                    cyc["fail_reason"] = "reached CONC_MAX"
                    break
                conc = min(a.conc_max, max(conc + 1, int(round(conc * a.conc_factor))))
            v = self.drain_and_verify(cycle, baseline, "after-ramp")
            cyc["verify"] = v
            cyc["t1"] = now()
            if not v["ok"]:
                self.failures.append(f"cycle {cycle}: {'; '.join(v['reasons'])}")
            cycles.append(cyc)
            json.dump({"cycles": cycles}, open(self.out / f"{a.run}_stress_cycles.json", "w"), indent=1)
            if self.failures and a.stop_on_fail:
                break
        return self.finish(t_start, cycles, baseline)

    def finish(self, t_start, cycles, baseline):
        a = self.a
        verdict = {"run": a.run, "ok": not self.failures, "reasons": self.failures, "duration_s": round(time.time() - t_start),
                   "cycles": len(cycles), "last_good_conc": [c.get("last_good_conc") for c in cycles],
                   "failed_at": [c.get("failed_at") for c in cycles], "fail_reasons": [c.get("fail_reason") for c in cycles],
                   "gsm8k_baseline_acc": baseline and baseline.get("acc"),
                   "gsm8k_checks": [c.get("verify", {}).get("gsm8k") for c in cycles],
                   "health_slow_events": len(self.health_slow), "health_slow": self.health_slow[:50],
                   "health_latency_max_s": self.health_latency_max,
                   "health_end": self.eng.health(), "t_end": now()}
        json.dump(verdict, open(self.out / f"{a.run}_stress_verdict.json", "w"), indent=1)
        self.log(f"STRESS {'PASS' if verdict['ok'] else 'FAIL'}: {json.dumps({k: v for k, v in verdict.items() if k != 'gsm8k_checks'})}")
        try:
            self.pool.shutdown(wait=False, cancel_futures=True)
        except TypeError:  # python < 3.9
            self.pool.shutdown(wait=False)
        return 0 if verdict["ok"] else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lb", required=True); ap.add_argument("--pins", default="", help="name=url,name=url of the pinned routers")
    ap.add_argument("--prefill-urls", default=""); ap.add_argument("--decode-urls", default="")
    ap.add_argument("--tokenizer", required=True); ap.add_argument("--prompts", required=True); ap.add_argument("--gsm8k", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--run", required=True); ap.add_argument("--served-model", required=True)
    ap.add_argument("--multimodal", action="store_true"); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--duration", type=float, default=10800); ap.add_argument("--cycles-max", type=int, default=0)
    ap.add_argument("--max-input", type=int, default=262144); ap.add_argument("--max-images", type=int, default=64)
    ap.add_argument("--image-tokens", type=int, default=420, help="token budget reserved per image (mm-process-config cap)")
    ap.add_argument("--max-output", type=int, default=1024); ap.add_argument("--max-sessions", type=int, default=256)
    ap.add_argument("--p-return", type=float, default=0.30); ap.add_argument("--p-gsm8k", type=float, default=0.08)
    ap.add_argument("--p-image", type=float, default=0.35); ap.add_argument("--p-abort", type=float, default=0.05)
    ap.add_argument("--p-sticky", type=float, default=0.5, help="share of new sessions routed through a pinned router")
    ap.add_argument("--conc-start", type=int, default=2); ap.add_argument("--conc-max", type=int, default=256)
    ap.add_argument("--conc-factor", type=float, default=1.5); ap.add_argument("--step-seconds", type=float, default=300)
    ap.add_argument("--step-min-requests", type=int, default=20)
    ap.add_argument("--fail-error-rate", type=float, default=0.05); ap.add_argument("--hang-seconds", type=float, default=600)
    ap.add_argument("--ttft-sat-seconds", type=float, default=600); ap.add_argument("--request-timeout", type=float, default=2400)
    ap.add_argument("--ttft-timeout", type=float, default=900, help="a request with no first token after this fails (saturation)")
    ap.add_argument("--context-len", type=int, default=262144)
    ap.add_argument("--drain-seconds", type=float, default=1200)
    ap.add_argument("--verify-n", type=int, default=24); ap.add_argument("--verify-conc", type=int, default=8)
    ap.add_argument("--gsm8k-n", type=int, default=100); ap.add_argument("--gsm8k-conc", type=int, default=16)
    ap.add_argument("--gsm8k-tolerance", type=float, default=0.05); ap.add_argument("--leak-token-usage", type=float, default=0.02)
    ap.add_argument("--stop-on-fail", action="store_true")
    a = ap.parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1"); os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(a.tokenizer)
    pins = dict(p.split("=", 1) for p in a.pins.split(",") if "=" in p)
    engines = Engines(a.prefill_urls.split(), a.decode_urls.split(), a.lb, pins)
    corpus = Corpus(tok, a.prompts, a.max_input)
    gsm = gsm8k_eval.load(a.gsm8k, 1319, 0)
    Path(a.out).mkdir(parents=True, exist_ok=True)
    wl = Workload(a, tok, corpus, gsm, pins)
    return Driver(a, engines, wl).run()


if __name__ == "__main__":
    sys.exit(main())

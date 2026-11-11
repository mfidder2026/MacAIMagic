#!/usr/bin/env python3
"""Every model on the current engine (old) and the new one (2cbe0ec + patches), alternating old, new, old, new.
Usage: MACAIMAGIC_BENCH_DIR=<dir with args/<model>.json> MACAIMAGIC_ENGINE_NEW=<llama-server> allbench.py <model ids>
(args/<model>.json: {"args": [the app's engine arguments], "env": {...}}, see docs/RESEARCH.md section 16.)
Per run: 3 stories of 200 tokens, a prompt of ~1,900 tokens, and one fixed answer at temperature 0 (same text check)."""
import json, os, re, subprocess, sys, time, urllib.request, hashlib, shutil
S = os.environ.get("MACAIMAGIC_BENCH_DIR", os.path.dirname(os.path.abspath(__file__)))  # args/<model>.json and the results
ENGINES = {"old": "/Users/fremen/Development/MacAIMagic/engine/bin/llama-server",
           "new": os.environ.get("MACAIMAGIC_ENGINE_NEW", S + "/llama-up/build/bin/llama-server")}
URL = "http://127.0.0.1:8080"
models = sys.argv[1:]
out = open(S + "/allbench.jsonl", "a")

def ssd():
    o = subprocess.run(["ioreg", "-rc", "IOBlockStorageDriver", "-w0"], capture_output=True, text=True).stdout
    return sum(int(x) for x in re.findall(r'"Bytes \(Read\)"=(\d+)', o))

def chat(text, n):
    body = {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    r = json.load(urllib.request.urlopen(urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"}), timeout=7200))
    m = r["choices"][0]["message"]
    return r["timings"], (m.get("reasoning_content") or "") + "\n----\n" + (m.get("content") or "")

def wait_gone():
    for _ in range(120):
        if subprocess.run(["pgrep", "-f", "llama-server"], capture_output=True).returncode != 0: return
        time.sleep(1)

for mid in models:
    cfg = json.load(open(f"{S}/args/{mid}.json"))
    for i, eng in enumerate(["old", "new", "old", "new"]):
        env = dict(os.environ)
        for k, v in cfg["env"].items():
            if k != "cache_file": env[k] = v
        if cfg["env"].get("cache_file"):
            src = os.path.expanduser(f"~/Library/Application Support/MacAIMagic/models/{mid}/expert-cache.bin")
            dst = f"{S}/cache-{mid}-{eng}.bin"
            if not os.path.exists(dst) and os.path.exists(src): shutil.copy(src, dst)
            env["LLAMA_MOE_CACHE_FILE"] = dst
        wait_gone()
        log = open(f"{S}/logs-{mid}-{eng}-{i}.log", "w")
        t0 = time.time()
        p = subprocess.Popen([ENGINES[eng]] + cfg["args"], env=env, stdout=log, stderr=subprocess.STDOUT)
        ok = False
        while time.time() - t0 < 3600 and p.poll() is None:
            try:
                if urllib.request.urlopen(URL + "/health", timeout=2).status == 200: ok = True; break
            except Exception: pass
            time.sleep(2)
        rec = {"model": mid, "engine": eng, "run": i, "load_s": round(time.time() - t0)}
        if not ok:
            rec["error"] = "did not start"; print(json.dumps(rec), flush=True); out.write(json.dumps(rec) + "\n"); out.flush()
            p.terminate(); p.wait(); continue
        try:
            w = []
            for topic in ["een vuurtorenwachter", "de Afsluitdijk", "een robot die leert koken"]:
                b = ssd(); t, _ = chat(f"Schrijf een verhaal van 250 woorden over {topic}.", 200)
                w.append([round(t["predicted_per_second"], 2), round((ssd() - b) / 1e9 / max(t["predicted_n"] + t["prompt_n"], 1), 3)])
            b = ssd()
            t, _ = chat(f"[{time.time()}] Vat samen: " + " ".join(f"Zin {k} over techniek, natuur en geschiedenis in Nederland." for k in range(120)), 16)
            rec.update(write=w, prompt=round(t["prompt_per_second"], 1), prompt_gb=round((ssd() - b) / 1e9, 1))
            t, text = chat("Schrijf vier zinnen over de Afsluitdijk.", 120)
            rec["fixed_tps"] = round(t["predicted_per_second"], 2)
            rec["text_hash"] = hashlib.sha1(text.encode()).hexdigest()[:10]
            open(f"{S}/text-{mid}-{eng}-{i}.txt", "w").write(text)
        except Exception as e:
            rec["error"] = str(e)[:200]
        p.terminate(); p.wait()
        print(json.dumps(rec), flush=True); out.write(json.dumps(rec) + "\n"); out.flush()

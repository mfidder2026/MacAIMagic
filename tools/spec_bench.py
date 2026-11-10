#!/usr/bin/env python3
"""Speculative decoding on Qwen3.8-Flash-Next Q4: no drafting, MTP, MTP with ngram-mod (the app's setting), DFlash.
Starts the engine with the app's own arguments per configuration (quit the app first: two copies do not fit), writes
five kinds of text at temperature 0, and records the writing speed, the draft acceptance and the text (drafting is
lossless: the text should match the one without drafting, up to a near-tie token).
Usage: tools/spec_bench.py <out.json> [config names...]
MACAIMAGIC_DFLASH=<draft.gguf> adds the DFlash configurations (e.g. incoai/Qwen3.8-Flash-Next-DFlash2-GGUF Q4_K_M).
Results on the M3 Max 128 GB: docs/RESEARCH.md, "Guessing ahead"."""
import json, os, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = ROOT + "/engine/bin/llama-server"
M = os.path.expanduser("~/Library/Application Support/MacAIMagic/models")
MODEL = M + "/qwen3.8-flash-next-q4/qwen3.8-flash-next-q4-00001-of-00004.gguf"
MTP = M + "/qwen3.8-flash-next-q4/qwen3.8-flash-next-mtp.gguf"
VISION = M + "/vision/qwen3.8-vision.gguf"
DFLASH = os.environ.get("MACAIMAGIC_DFLASH")
PORT = 8093
URL = f"http://127.0.0.1:{PORT}"

# the app's arguments for this model (EngineController, MemoryPlan for a model that fits), without the slot saves
BASE = ["--model", MODEL, "--host", "127.0.0.1", "--port", str(PORT), "--ctx-size", "65536", "--n-gpu-layers", "999",
        "--flash-attn", "on", "--ubatch-size", "1024", "--batch-size", "2048", "--fit", "off", "--threads", "12",
        "--parallel", "1", "--jinja", "--reasoning-format", "deepseek", "--metrics", "--alias", "q", "--n-cpu-moe", "0",
        "--mmproj", VISION]

CONFIGS = {
    "none": [],
    "mtp2": ["--spec-type", "draft-mtp", "--model-draft", MTP, "--spec-draft-n-max", "2"],
    "mtp3": ["--spec-type", "draft-mtp", "--model-draft", MTP, "--spec-draft-n-max", "3"],
    "mtp2+ngram": ["--spec-type", "draft-mtp,ngram-mod", "--model-draft", MTP, "--spec-draft-n-max", "2"],
    "mtp3+ngram": ["--spec-type", "draft-mtp,ngram-mod", "--model-draft", MTP, "--spec-draft-n-max", "3"],
}
if DFLASH:
    CONFIGS["dflash4"] = ["--spec-type", "draft-dflash", "--model-draft", DFLASH, "--spec-draft-n-max", "4"]
    CONFIGS["dflash8"] = ["--spec-type", "draft-dflash", "--model-draft", DFLASH, "--spec-draft-n-max", "8"]

# a piece of real code to give back with one change (the lines of 2026-11-10; any 40 lines with domains(in:) will do)
source = open(ROOT + "/App/Sources/MacAIMagic/Chat/SystemTools.swift").read().split("\n")[289:330]
readme = open(ROOT + "/README.md").read()[2000:5000]
TASKS = [
    ("verhaal", "Schrijf een verhaal van 300 woorden over een vuurtorenwachter.", False, 400),
    ("code", "Schrijf in Swift een functie die een lijst met datums groepeert per week (maandag als eerste dag), met korte commentaarregels.", False, 450),
    ("aanpassen", "Geef deze Swift-code terug met als enige wijziging dat domains(in:) de domeinen alfabetisch gesorteerd teruggeeft. Geef de hele code, zonder uitleg.\n\n```swift\n" + "\n".join(source) + "\n```", False, 1100),
    ("uitleg", "Leg in vijf zinnen uit wat hier staat:\n\n" + readme, False, 300),
    ("denken", "Een trein vertrekt om 9:12 en rijdt 137 km met gemiddeld 88 km/u, met onderweg 2 stops van 3 minuten. Hoe laat komt hij aan? Reken het na.", True, 900),
]


def call(body, timeout=900):
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def run(name):
    log = open(f"{os.path.dirname(os.path.abspath(sys.argv[1]))}/spec_{name}.log", "w")
    p = subprocess.Popen([ENGINE] + BASE + CONFIGS[name], stdout=log, stderr=subprocess.STDOUT,
                         env=dict(os.environ, LLAMA_ARG_LAZY_MODE="auto"))
    t0 = time.time()
    try:
        while True:
            if p.poll() is not None:
                return {"error": f"engine exited {p.returncode}, see spec_{name}.log next to the results"}
            try:
                if urllib.request.urlopen(URL + "/health", timeout=2).status == 200:
                    break
            except Exception:
                pass
            if time.time() - t0 > 900:
                return {"error": "not ready after 15 min"}
            time.sleep(1)
        out = {"load_s": round(time.time() - t0, 1), "tasks": {}}
        call({"messages": [{"role": "user", "content": "Zeg hallo."}], "max_tokens": 16, "temperature": 0,
              "chat_template_kwargs": {"enable_thinking": False}})
        for key, prompt, think, n in TASKS:
            d = call({"messages": [{"role": "user", "content": prompt}], "max_tokens": n, "temperature": 0,
                      "chat_template_kwargs": {"enable_thinking": think}})
            t = d["timings"]
            msg = d["choices"][0]["message"]
            out["tasks"][key] = {
                "tok_s": round(t["predicted_per_second"], 2), "n": t["predicted_n"],
                "draft": {k: v for k, v in t.items() if "draft" in k},
                "text": (msg.get("reasoning_content") or "") + "\n---\n" + (msg.get("content") or ""),
            }
            print(name, key, out["tasks"][key]["tok_s"], "tok/s", t["predicted_n"], out["tasks"][key]["draft"], flush=True)
        return out
    finally:
        p.terminate()
        try:
            p.wait(60)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        time.sleep(3)


if __name__ == "__main__":
    path = sys.argv[1]
    results = json.load(open(path)) if os.path.exists(path) else {}
    for name in sys.argv[2:] or CONFIGS:
        results[name] = run(name)
        json.dump(results, open(path, "w"), ensure_ascii=False, indent=1)
        if "error" in results[name]:
            print(name, results[name]["error"], flush=True)

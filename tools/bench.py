#!/usr/bin/env python3
"""Wait for the engine, then measure prompt reading (~2.6K tokens) and writing (~400 tokens) speed."""
import json, os, time, urllib.request

URL = "http://127.0.0.1:8080"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def chat(body):
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=1800))


t0 = time.time()
while True:
    try:
        if urllib.request.urlopen(URL + "/health", timeout=2).status == 200:
            break
    except Exception:
        pass
    if time.time() - t0 > 1800:
        raise SystemExit("engine not ready after 30 min")
    time.sleep(2)
print(f"ready after {time.time() - t0:.0f} s")

text = open(os.path.join(ROOT, "third_party/llama.cpp/README.md")).read()[:16000]
# a different first line each run, so the prompt cache never hides the reading cost
d = chat({"messages": [{"role": "user", "content": f"[{time.time()}] Vat dit samen in 3 zinnen:\n\n" + text}],
          "max_tokens": 64, "chat_template_kwargs": {"thinking_mode": "chat"}})
t = d["timings"]
print(f"prompt: {t['prompt_per_second']:.1f} tok/s ({t['prompt_n']} tok in {t['prompt_ms'] / 1000:.1f} s)")

d = chat({"messages": [{"role": "user", "content": "Schrijf een verhaal van 300 woorden over een vuurtorenwachter."}],
          "max_tokens": 400, "chat_template_kwargs": {"thinking_mode": "chat"}})
t = d["timings"]
print(f"decode: {t['predicted_per_second']:.1f} tok/s ({t['predicted_n']} tok)")

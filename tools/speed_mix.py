#!/usr/bin/env python3
"""Writing speed on three kinds of text (code, explanation, creative), with draft statistics when MTP is on."""
import json, sys, time, urllib.request
URL = "http://127.0.0.1:8080"
t0 = time.time()
while True:
    try:
        if urllib.request.urlopen(URL + "/health", timeout=2).status == 200: break
    except Exception: pass
    if time.time() - t0 > 2700: sys.exit("engine not ready")
    time.sleep(2)
print(f"ready after {time.time() - t0:.0f} s")
def chat(text, n, temp):
    body = {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": temp,
            "chat_template_kwargs": {"enable_thinking": False}}
    r = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=3600))["timings"]
chat("Zeg hallo.", 8, 0.0)   # warm-up
for label, text, temp in [
    ("code t=0", "Schrijf een Python-klasse voor een binaire zoekboom met insert, delete, search en inorder traversal, met docstrings.", 0.0),
    ("uitleg t=1.0", "Leg in 200 woorden uit waarom de lucht blauw is.", 1.0),
    ("verhaal t=0.7", "Schrijf een verhaal van 300 woorden over een vuurtorenwachter.", 0.7)]:
    t = chat(text, 400, temp)
    extra = f", accepted {t['draft_n_accepted']}/{t['draft_n']}" if t.get("draft_n") else ""
    print(f"{label}: {t['predicted_per_second']:.1f} tok/s{extra}")

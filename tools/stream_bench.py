#!/usr/bin/env python3
"""Measure a running engine for a model larger than memory: writing speed over several rounds (the expert cache warms up
as the conversation goes on), with the SSD bytes read per token, and prompt reading.

Usage: stream_bench.py [label] [rounds] [tokens per round]     temperature 0, so every run writes the same text
"""
import json, re, subprocess, sys, time, urllib.request

URL = "http://127.0.0.1:8080"
label = sys.argv[1] if len(sys.argv) > 1 else ""
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
ntok = int(sys.argv[3]) if len(sys.argv) > 3 else 200


def ssd_bytes_read():
    out = subprocess.run(["ioreg", "-rc", "IOBlockStorageDriver", "-w0"], capture_output=True, text=True).stdout
    return sum(int(x) for x in re.findall(r'"Bytes \(Read\)"=(\d+)', out))


def chat(text, n):
    body = {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=7200))["timings"]


t0 = time.time()
while True:
    try:
        if urllib.request.urlopen(URL + "/health", timeout=2).status == 200:
            break
    except Exception:
        pass
    if time.time() - t0 > 3600:
        sys.exit("engine not ready after an hour")
    time.sleep(2)

line = f"{label}: load {time.time() - t0:.0f} s"
topics = ["een vuurtorenwachter", "de Afsluitdijk", "een robot die leert koken", "een reis naar Mars",
          "een oude bibliotheek", "de eerste sneeuw"]
for i in range(rounds):
    before = ssd_bytes_read()
    t = chat(f"Schrijf een verhaal van 250 woorden over {topics[i % len(topics)]}.", ntok)
    gb = (ssd_bytes_read() - before) / 1e9
    line += f" | w{i + 1} {t['predicted_per_second']:.2f} tok/s ({gb / max(t['predicted_n'] + t['prompt_n'], 1):.2f} GB/tok)"
    print(line, flush=True)

# a different first line each run, so the prompt cache never hides the reading cost
before = ssd_bytes_read()
t = chat(f"[{time.time()}] Vat samen: " + " ".join(f"Zin {i} over techniek, natuur en geschiedenis in Nederland." for i in range(120)), 16)
gb = (ssd_bytes_read() - before) / 1e9
line += f" | prompt {t['prompt_per_second']:.1f} tok/s ({t['prompt_n']} tok, {gb:.0f} GB read)"
print(line, flush=True)

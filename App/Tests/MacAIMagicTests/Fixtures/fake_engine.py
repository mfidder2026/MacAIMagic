"""A stand-in for llama-server's chat API, for the tests of the chat client.

The last user message decides: "SCHRIJF" asks for write_file (and after the result says KLAAR), "PLAN" sets a
task list, anything else gets "Antwoord op: <text>". GET /stats says how many requests ran at once at most.
Usage: fake_engine.py <port>
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
now = 0
most = 0
requests = []


def chunk(delta, finish=None):
    return "data: " + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({"most": most, "requests": len(requests)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global now, most
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock:
            now += 1
            most = max(most, now)
            requests.append(req)
        try:
            self.answer(req)
        finally:
            with lock:
                now -= 1

    def answer(self, req):
        msgs = req["messages"]
        last_user = next((m for m in reversed(msgs) if m["role"] == "user"), {"content": ""})
        text = last_user["content"] if isinstance(last_user["content"], str) else ""
        after_tool = msgs[-1]["role"] == "tool"
        time.sleep(0.4)          # long enough for another request to come in meanwhile
        if not req.get("stream"):
            body = json.dumps({"choices": [{"message": {"role": "assistant", "content": "GEEN"}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        out = []
        if "SCHRIJF" in text and not after_tool:
            args = json.dumps({"path": "x.txt", "content": "hoi"})
            out.append(chunk({"tool_calls": [{"index": 0, "id": "call1", "type": "function",
                                              "function": {"name": "write_file", "arguments": args}}]}))
            out.append(chunk({}, "tool_calls"))
        elif "APPACTIE" in text and not after_tool:
            args = json.dumps({"action": "stop_engine"})
            out.append(chunk({"tool_calls": [{"index": 0, "id": "call3", "type": "function",
                                              "function": {"name": "app_action", "arguments": args}}]}))
            out.append(chunk({}, "tool_calls"))
        elif "PLAN" in text and not after_tool:
            args = json.dumps({"steps": [{"title": "Eerst kijken", "status": "done"},
                                         {"title": "Dan bouwen", "status": "doing"},
                                         {"title": "Testen", "status": "todo"}]})
            out.append(chunk({"tool_calls": [{"index": 0, "id": "call2", "type": "function",
                                              "function": {"name": "task_list", "arguments": args}}]}))
            out.append(chunk({}, "tool_calls"))
        else:
            reply = "KLAAR: geschreven." if after_tool else "Antwoord op: " + text
            out.append(chunk({"role": "assistant", "content": reply}))
            out.append(chunk({}, "stop"))
        for part in out:
            self.wfile.write(part.encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    print("READY", flush=True)
    server.serve_forever()

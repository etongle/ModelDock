import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("command", nargs="?")
parser.add_argument("-m", default="fixture")
parser.add_argument("--port", type=int)
args, _ = parser.parse_known_args()
port = args.port or int(os.environ.get("OLLAMA_HOST", "127.0.0.1:29200").rsplit(":", 1)[1])
loaded = {}

class Handler(BaseHTTPRequestHandler):
    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/tags":
            self.reply({"models": [{"name": "alpha:latest"}, {"name": "beta:latest"}]})
        elif self.path == "/api/ps":
            self.reply({"models": list(loaded.values())})
        elif self.path == "/fixture/state":
            self.reply({"loaded": loaded, "context": os.environ.get("OLLAMA_CONTEXT_LENGTH"),
                        "maximumLoadedModels": os.environ.get("OLLAMA_MAX_LOADED_MODELS")})
        else:
            self.reply({"data": [{"id": os.path.basename(args.m)}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body.get("keep_alive") == 0:
            loaded.pop(body["model"], None)
        else:
            loaded[body["model"]] = {"name": body["model"], "size": 1024,
                                     "context_length": body["options"]["num_ctx"]}
        self.reply({"done": True})

    def log_message(self, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

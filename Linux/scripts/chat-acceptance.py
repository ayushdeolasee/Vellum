"""Normal reader against isolated Secret Service, Weston and a loopback TLS provider."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
import time

import gi
gi.require_version("Secret", "1")
from gi.repository import GLib, Secret
import pyatspi

home = Path(os.environ["VELLUM_TEST_KEYRING"])
assert Path.home() == home and os.environ["DBUS_SESSION_BUS_ADDRESS"] == f"unix:path={home}/run/bus"
os.environ.update(WAYLAND_DISPLAY="chat", GDK_BACKEND="wayland", GSK_RENDERER="cairo", GTK_A11Y="atspi")
runtime = Path(os.environ["XDG_RUNTIME_DIR"])
desktop = pyatspi.Registry.getDesktop(0)
schema = Secret.Schema.new("com.vellum.Credential", Secret.SchemaFlags.NONE,
                           {"service": Secret.SchemaAttributeType.STRING, "account": Secret.SchemaAttributeType.STRING})
provider = "gemini"
finished = threading.Event()
release = threading.Event()
errors = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        question = None
        try:
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert self.headers["Accept"] == "text/event-stream"
            if provider == "gemini":
                assert self.path == "/v1beta/models/gemini-3.1-flash-lite-preview:streamGenerateContent?alt=sse"
                assert self.headers["x-goog-api-key"] == "fixture-gemini"
                prompt = body["contents"][0]["parts"][0]["text"]
                chunk = {"candidates": [{"content": {"parts": [{"text": "First café"}]}}]}
                end = {"candidates": [{"content": {"parts": [{"text": " done"}]}, "finishReason": "STOP"}]}
            else:
                account = "opencode-go" if provider == "opencodeGo" else provider
                assert self.headers["Authorization"] == "Bearer fixture-" + account
                if provider == "openai":
                    assert self.path == "/v1/responses" and body["model"] == "gpt-5.5" and body["store"] is False
                    prompt = body["input"][0]["content"][0]["text"]
                    chunk = {"type": "response.output_text.delta", "delta": "First café"}
                    end = {"type": "response.completed"}
                else:
                    path, model = {"openrouter": ("/api/v1/chat/completions", "openrouter/auto"),
                                   "opencode": ("/zen/v1/chat/completions", "claude-opus-4-8"),
                                   "opencodeGo": ("/zen/go/v1/chat/completions", "glm-5.2")}[provider]
                    assert self.path == path and body["model"] == model
                    prompt = body["messages"][-1]["content"]
                    chunk = {"choices": [{"delta": {"content": "First café"}}]}
                    end = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
            question = prompt.split("Question:\n")[-1]
            if question == "Article?":
                assert "Harbor café 東京" in prompt and "Apple history" in prompt and "Left column" not in prompt
            else:
                assert "Left column" in prompt and "First line of evidence" in prompt and "Apple history" not in prompt
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            def emit(event):
                frame = ("data: " + json.dumps(event, ensure_ascii=False) + "\r\n\r\n").encode()
                cut = frame.find("é".encode()) + 1
                for part in (frame[:cut], frame[cut:]):
                    if part:
                        self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
                self.wfile.flush()
            emit(chunk)
            if question in ("Switch?", "Stop?", "Reopen?", "Close?"):
                self.connection.settimeout(12)
                # A socket close is the evidence of transport cancellation.
                assert self.rfile.read(1) == b""
            else:
                assert release.wait(12)
                emit(end)
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            if question not in ("Switch?", "Stop?", "Reopen?", "Close?"):
                errors.append("Unexpected disconnect")
        except Exception as e:
            errors.append(repr(e))
        finally:
            finished.set()


def wait(check, description):
    deadline = time.monotonic() + 18
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        if errors:
            raise RuntimeError(errors)
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise RuntimeError("Timed out: " + description)


def find(name, role=None, root=None):
    if root is None:
        root = desktop
    if root.name == name and (not role or root.getRoleName() == role):
        return root
    for child in root:
        if child is not None:
            result = find(name, role, child)
            if result is not None:
                return result


def get(name):
    return wait(lambda: find(name), name)


def click(name):
    widget = get(name)
    assert widget.getState().contains(pyatspi.STATE_SENSITIVE), name
    assert widget.queryAction().doAction(0), name


def has_status(fragment, root=None):
    if root is None:
        root = desktop
    if root.getRoleName() == "label" and fragment in root.name:
        return True
    return any(has_status(fragment, c) for c in root if c is not None)


def transcript():
    text = get("Conversation").queryText()
    return text.getText(0, text.characterCount)


def send(question):
    finished.clear()
    release.clear()
    assert get("Question").queryEditableText().setTextContents(question)
    click("Send")


def reply(question):
    send(question)
    wait(lambda: transcript().endswith("First café"), "live first delta")
    release.set()
    title = {"gemini": "Gemini", "openai": "OpenAI", "openrouter": "OpenRouter",
             "opencode": "OpenCode Zen", "opencodeGo": "OpenCode Go"}[provider]
    get(f"Send shares document text and recent chat with {title}. New messages stay in this session.")
    assert finished.is_set()


def select(label):
    elem = get(label)
    while elem.getRoleName() != "list item":
        elem = elem.parent
    assert elem.parent.querySelection().selectChild(elem.getIndexInParent())


def save_key(account):
    assert Secret.password_store_sync(schema, {"service": "com.vellum.ai", "account": account},
                                      Secret.COLLECTION_DEFAULT, "Disposable", "fixture-" + account, None)


def capture(name):
    subprocess.run(["weston-screenshooter"], cwd=home, check=True, timeout=5)
    shot, = home.glob("*.png")
    shot.rename(Path("/tmp") / name)


def exercise():
    global provider
    for provider in ("gemini", "openai", "openrouter", "opencode", "opencodeGo"):
        config = Path(os.environ["XDG_CONFIG_HOME"]) / "vellum"
        config.mkdir(parents=True, exist_ok=True)
        (config / "ai-provider").write_text(provider)
        app = subprocess.Popen(["/runtime/vellum-linux", "--library", "/library"])
        try:
            wait(lambda: has_status("PDF open"), "initial PDF")
            if provider == "gemini":
                capture("reader-before.png")
            click("Chat")
            wait(lambda: has_status("New messages stay"), "ready to send")
            if provider == "gemini":
                send("PDF?")
                wait(lambda: has_status("No Gemini key is saved"), "missing credential")
                draft = get("Question").queryText()
                assert draft.getText(0, draft.characterCount) == "PDF?", repr(draft.getText(0, draft.characterCount))
            if provider == "openai":
                select("harbor.vellumweb")
                wait(lambda: "Apple history" in transcript(), "saved history after relaunch")
                assert "Article?" not in transcript()
                select("classic-two-column.pdf")
                wait(lambda: get("Send").getState().contains(pyatspi.STATE_SENSITIVE) and not transcript(),
                     "fresh PDF session")
            save_key("opencode-go" if provider == "opencodeGo" else provider)
            reply("PDF?")
            if provider == "gemini":
                capture("reader-chat.png")
                send("Switch?")
                wait(lambda: transcript().endswith("First café"), "midstream before selection")
                select("harbor.vellumweb")
                wait(lambda: finished.is_set() and "Apple history" in transcript(), "switch cancels transport and loads archive")
                assert "PDF?" not in transcript()
                reply("Article?")
                select("classic-two-column.pdf")
                wait(lambda: "Switch?" in transcript(), "document-specific session")
                assert "Apple history" not in transcript()
                send("Stop?")
                wait(lambda: transcript().endswith("First café"), "midstream before stop")
                click("Stop")
                wait(lambda: finished.is_set() and has_status("Stopped."), "explicit stop")
                send("Reopen?")
                wait(lambda: transcript().endswith("First café"), "midstream before reopening library")
                click("Settings")
                click("Reopen")
                wait(finished.is_set, "library reopen cancels transport")
                click("Done")
                wait(lambda: get("Send").getState().contains(pyatspi.STATE_SENSITIVE), "reopened PDF")
                assert "Reopen?" in transcript()
                select("harbor.vellumweb")
                wait(lambda: "Apple history" in transcript(), "reopened saved conversation")
                assert "Article?" in transcript()
                select("classic-two-column.pdf")
                wait(lambda: get("Send").getState().contains(pyatspi.STATE_SENSITIVE) and "Reopen?" in transcript(),
                     "returned to PDF")
                send("Close?")
                wait(lambda: transcript().endswith("First café"), "midstream before close")
            if provider == "opencodeGo":
                subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.secrets",
                                "--object-path", "/org/freedesktop/secrets", "--method",
                                "org.freedesktop.Secret.Service.Lock", "['/org/freedesktop/secrets/collection/login']"],
                               check=True)
                send("Locked?")
                wait(lambda: has_status("keyring is locked or unavailable"), "locked credential")
            click("Close")
            assert app.wait(timeout=8) == 0
            if provider == "gemini":
                wait(finished.is_set, "window close cancels transport")
            print(provider, "passed", flush=True)
        finally:
            if app.poll() is None:
                app.kill()
                app.wait()


server = ThreadingHTTPServer(("127.0.0.1", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/runtime/fixture.crt", "/runtime/fixture.key")
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
weston = subprocess.Popen(["weston", "--no-config", "--backend=headless", "--renderer=pixman",
                           "--socket=chat", "--width=1100", "--height=760", "--idle-time=0", "--debug"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    wait(lambda: (runtime / "chat").exists(), "Wayland display")
    exercise()
finally:
    weston.terminate()
    weston.wait(timeout=5)
    server.shutdown()

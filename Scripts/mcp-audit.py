"""Audit of Ámbar's MCP integration (ambar-mcp) against the installed Ámbar
(docs/initiatives/mac-apps-mcp/DESIGN.md). Run only when the owner asks and is NOT using the
Mac: Ámbar polls the pasteboard every 0.5 s, so a copy the owner makes during the clipboard
test hides the agent's copy from the history (seen on 2026-10-15, first run 32/33; the same
check passed when repeated on a quiet Mac).

    python3 Scripts/mcp-audit.py

Every tool goes through ambar-mcp over stdio, as Claude Code does; every answer is checked
against Ámbar's own database, opened read-only (the oracle). The owner agreed to: one test
word in the dictionary (removed again with Ámbar closed), and one copy to the clipboard
(what it held is restored afterwards). Agent access is left ON.
"""
import base64, io, json, os, select, sqlite3, struct, subprocess, time

HOME = os.path.expanduser("~")
SERVER = "/Applications/Ambar.app/Contents/MacOS/ambar-mcp"
DATA = os.path.join(HOME, "Library/Application Support/Ambar")
ACCESS = os.path.join(DATA, "agent-access.json")
LOG = os.path.join(DATA, "agent-access.log")
DICTIONARY = os.path.join(DATA, "dictionary.json")
TEST_WORD = "Zzqxpalabraprueba"
TEST_COPY = "Prueba de Ámbar desde un agente (puedes borrarla del historial)."
OUT = os.environ.get("TMPDIR", "/tmp")
results = []


def check(test, ok, detail):
    results.append({"test": test, "ok": bool(ok), "detail": detail})
    print(("ok    " if ok else "FAIL  ") + f"[{test}] {detail}", flush=True)
    return ok


class MCP:
    def __init__(self, client="audit-ambar"):
        self.process = subprocess.Popen([SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0
        self.info = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                "clientInfo": {"name": client, "version": "1"}})

    def request(self, method, params=None, timeout=60):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], 0.5)
            if ready:
                reply = json.loads(self.process.stdout.readline())
                if reply.get("id") == self.next_id:
                    return reply
        raise TimeoutError(method)

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        return result.get("isError", True), result.get("content", []), result.get("structuredContent")

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)


def text_of(content):
    return "".join(c.get("text", "") for c in content if c.get("type") == "text")


def db():
    return sqlite3.connect(f"file:{os.path.join(DATA, 'ambar.db')}?mode=ro", uri=True)


def full_text(connection, item_id):
    row = connection.execute("SELECT inline, blob_hash FROM representation WHERE item_id = ? AND uti = 'public.utf8-plain-text'",
                             (item_id,)).fetchone()
    if not row:
        return None
    if row[0] is not None:
        return row[0].decode("utf-8", "replace")
    path = os.path.join(DATA, "blobs", row[1][:2], row[1])
    return open(path, "rb").read().decode("utf-8", "replace")


def jpeg_size(data):
    """Width and height from a JPEG's SOF marker."""
    i = 2
    while i < len(data):
        marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    return None


def running():
    return subprocess.run(["pgrep", "-x", "Ambar"], capture_output=True).returncode == 0


def quit_ambar():
    subprocess.run(["osascript", "-e", 'tell application id "dev.rrios.ambar" to quit'], capture_output=True)
    for _ in range(40):
        if not running():
            return True
        time.sleep(0.25)
    return False


def open_ambar():
    subprocess.run(["open", "-a", "/Applications/Ambar.app"])
    for _ in range(40):
        if running() and os.path.exists(os.path.join(DATA, "agent.sock")):
            return True
        time.sleep(0.25)
    return running()


def clipboard_is_text():
    info = subprocess.run(["osascript", "-e", "clipboard info"], capture_output=True, text=True).stdout
    return "utf8" in info or "string" in info.lower(), info.strip()


def main():
    session = MCP()
    info = session.info["result"]
    check("A1", info["serverInfo"]["name"] == "ambar", f"server {info['serverInfo']} protocol {info['protocolVersion']}")
    tools = session.request("tools/list")["result"]["tools"]
    names = [t["name"] for t in tools]
    check("A1", len(names) == 6, f"6 tools: {', '.join(names)}")
    actions = [t["name"] for t in tools if not t["annotations"]["readOnlyHint"]]
    check("A1", actions == ["add_dictionary_word", "copy_to_clipboard"], f"actions: {actions}; nothing deletes")

    # ------------------------------------------------------------------ A2 switch
    json.dump({"enabled": False}, open(ACCESS, "w"))
    error, content, _ = session.call("recent_clipboard")
    check("A2", error and "agent access is off" in text_of(content), f"off → refused: {text_of(content)[:70]}")
    json.dump({"enabled": True}, open(ACCESS, "w"))
    os.chmod(ACCESS, 0o600)
    error, content, _ = session.call("recent_clipboard")
    check("A2", not error, "on → works, read on every call")

    # ------------------------------------------------------------------ B reading
    connection = db()
    oracle = [r[0] for r in connection.execute("SELECT id FROM item WHERE concealed = 0 ORDER BY created_at DESC LIMIT 10")]
    error, content, structured = session.call("recent_clipboard", limit=10)
    listed = [i["id"] for i in structured["items"]]
    check("B1", listed == oracle, f"recent_clipboard: the same 10 items as the database, newest first")

    kinds = dict(connection.execute("SELECT kind, MAX(id) FROM item WHERE concealed = 0 GROUP BY kind").fetchall())
    print(f"kinds in the history: {kinds}", flush=True)
    text_id = kinds.get("text")
    if text_id:
        body = full_text(connection, text_id) or ""
        word = next((w.strip(".,;:()«»\"'") for w in body.split() if len(w.strip(".,;:()«»\"'")) > 5 and w.isalpha()), None)
        if word:
            error, content, structured = session.call("search_clipboard", query=word.upper(), limit=50)
            check("B2", not error and text_id in [i["id"] for i in structured["items"]],
                  f"search “{word.upper()}” finds the text item {text_id} (case ignored)")
        error, content, structured = session.call("get_clipboard_item", id=text_id, max_characters=200000)
        returned = structured["text"] if structured else ""
        check("B3", not error and returned == body[:200000], f"get_clipboard_item {text_id}: the whole text, byte for byte ({len(body)} characters)")
    error, content, structured = session.call("search_clipboard", query="zzqxnadaquebuscar")
    check("B2", not error and structured["items"] == [], "search with no match → none")
    error, content, structured = session.call("search_clipboard", query="a", kind="image", limit=50)
    check("B2", not error and all(i["kind"] == "image" for i in structured["items"]), "kind filter returns only that kind")

    image_id = kinds.get("image")
    if image_id:
        ocr = connection.execute("SELECT ocr_text, width, height FROM image_meta WHERE item_id = ?", (image_id,)).fetchone()
        error, content, _ = session.call("get_clipboard_item", id=image_id)
        images = [c for c in content if c.get("type") == "image"]
        if images:
            data = base64.b64decode(images[0]["data"])
            size = jpeg_size(data)
            check("B3", images[0]["mimeType"] == "image/jpeg" and len(data) <= 1_500_000 and size and max(size) <= 1568,
                  f"image {image_id} ({ocr[1]}×{ocr[2]}) → JPEG {size[0]}×{size[1]}, {len(data) // 1024} KB")
        else:
            check("B3", False, f"image {image_id}: no image content: {text_of(content)[:120]}")
        if ocr and ocr[0]:
            check("B3", ocr[0][:200] in text_of(content), "with the text Ámbar read from it")
    for kind in ("url", "file"):
        item_id = kinds.get(kind)
        if item_id:
            error, content, _ = session.call("get_clipboard_item", id=item_id)
            check("B3", not error and len(text_of(content).split("\n\n", 1)[-1]) > 0, f"{kind} item {item_id} → {text_of(content).split(chr(10))[-1][:80]}")

    entries = json.load(open(DICTIONARY)) if os.path.exists(DICTIONARY) else []
    error, content, structured = session.call("list_dictionary")
    check("B4", not error and len(structured["entries"]) == len(entries), f"list_dictionary: {len(entries)} words, as in the file")

    # ------------------------------------------------------------------ A5 bad arguments
    for name, arguments, needle in [
        ("search_clipboard", {"query": "   "}, "is empty"),
        ("search_clipboard", {"query": "a", "kind": "video"}, "must be one of"),
        ("recent_clipboard", {"limit": 500}, "between 1 and 20"),
        ("get_clipboard_item", {"id": 999999999}, "No item 999999999"),
        ("add_dictionary_word", {"word": "  "}, "1 to 100 characters"),
        ("copy_to_clipboard", {"text": ""}, "is empty"),
    ]:
        error, content, _ = session.call(name, **arguments)
        check("A5", error and needle in text_of(content), f"{name} {arguments} → {text_of(content)[:80]}")

    # ------------------------------------------------------------------ C actions
    error, content, _ = session.call("add_dictionary_word", word=TEST_WORD, heard_as="zz prueba")
    time.sleep(0.8)
    saved = [e for e in json.load(open(DICTIONARY)) if e["written"] == TEST_WORD]
    check("C1", not error and saved and "zz prueba" in saved[0]["heard"], f"add_dictionary_word → {text_of(content)}; saved by Ámbar")
    error, content, _ = session.call("add_dictionary_word", word=TEST_WORD.upper(), heard_as="zz otra")
    time.sleep(0.8)
    saved = [e for e in json.load(open(DICTIONARY)) if e["written"].lower() == TEST_WORD.lower()]
    check("C1", not error and len(saved) == 1 and "zz otra" in saved[0]["heard"], f"the same word again grows one entry: {text_of(content)[:90]}")

    is_text, clip_info = clipboard_is_text()
    if is_text:
        original = subprocess.run(["pbpaste"], capture_output=True).stdout
        try:
            error, content, _ = session.call("copy_to_clipboard", text=TEST_COPY)
            pasted = subprocess.run(["pbpaste"], capture_output=True).stdout.decode()
            check("C2", not error and pasted == TEST_COPY, f"copy_to_clipboard → {text_of(content)}; the clipboard holds it")
            time.sleep(2.0)
            latest = connection.execute("SELECT preview FROM item ORDER BY created_at DESC LIMIT 1").fetchone()
            check("C2", latest and latest[0].startswith(TEST_COPY[:40]), "and Ámbar keeps it in the history")
        finally:
            subprocess.run(["pbcopy"], input=original)
            check("C2", subprocess.run(["pbpaste"], capture_output=True).stdout == original, "the clipboard was restored")
    else:
        check("C2", True, f"skipped: the clipboard does not hold plain text ({clip_info[:60]}), so it could not be restored")

    # ------------------------------------------------------------------ A4 Ámbar closed
    if check("A4", quit_ambar(), "Ámbar closed"):
        error, content, _ = session.call("recent_clipboard", limit=3)
        check("A4", not error, "with Ámbar closed, reading still works")
        error, content, _ = session.call("add_dictionary_word", word="Otra")
        check("A4", error and "Ámbar is not open" in text_of(content), f"with Ámbar closed, teaching a word → {text_of(content)}")
        check("A4", not running(), "and Ámbar was not opened behind the user's back")
        # Remove the test word while Ámbar is closed (it loads the file at launch).
        entries = [e for e in json.load(open(DICTIONARY)) if e["written"].lower() != TEST_WORD.lower()]
        json.dump(entries, open(DICTIONARY, "w"), ensure_ascii=False, indent=2, sort_keys=True)
        check("C1", not any(e["written"].lower() == TEST_WORD.lower() for e in json.load(open(DICTIONARY))), "test word removed again")
    check("A4", open_ambar(), "Ámbar opened again")

    session.close()
    lines = [json.loads(l) for l in open(LOG).read().strip().split("\n") if "audit-ambar" in l]
    mode = oct(os.stat(LOG).st_mode & 0o777)
    check("A3", mode == "0o600", f"access log mode {mode}")
    check("A3", lines and all(set(e) == {"client", "date", "succeeded", "tool"} for e in lines), f"{len(lines)} entries, no arguments")
    check("A3", TEST_COPY not in open(LOG).read() and TEST_WORD not in open(LOG).read(), "the log holds no text that was copied or taught")
    json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=2, ensure_ascii=False)
    print(f"\n{len(results)} checks, {len([r for r in results if not r['ok']])} failed")


if __name__ == "__main__":
    main()

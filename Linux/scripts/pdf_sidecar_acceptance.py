"""Exercise open PDF sidecar saves while a peer changes the disposable library."""
import hashlib
import json
import re
import subprocess
import zipfile


def revision(pdf, objects, size, info):
    """Append a classic xref revision to the fixed PDF fixture."""
    previous = int(pdf.rsplit(b"startxref", 1)[1].split()[0])
    result = bytearray(pdf)
    xref = bytearray(b"xref\n")
    for number, value in objects:
        xref.extend(f"{number} 1\n{len(result):010} 00000 n \n".encode())
        result.extend(f"{number} 0 obj\n".encode() + value + b"\nendobj\n")
    offset = len(result)
    result.extend(xref + f"trailer\n<< /Size {size} /Root 1 0 R /Info {info} 0 R /Prev {previous} >>\n"
                  f"startxref\n{offset}\n%%EOF\n".encode())
    return bytes(result)


def exercise(ui):
    root = ui.root
    file = root / "PDFs/classic-two-column.pdf"
    key = "4850abcd"
    directory = root / ".vellum/documents" / key
    directory.mkdir(parents=True)
    note = directory / "scratchpad.md"
    conversation = directory / "conversations.json"
    note.write_bytes(b"Existing note\n")
    conversation.write_bytes(b'[{"id":"peer","content":"Existing turn","role":"user","createdAt":"peer","x":1.200}]')
    original = revision(file.read_bytes(), [(2, b"<< /Type /Pages /Count 2 /Kids [4 0 R 7 0 R] >>"),
        (7, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /Helv 3 0 R >> >> /Contents 5 0 R >>")], 8, 6)
    file.write_bytes(original)
    with zipfile.ZipFile(root / "Web Pages/harbor.vellumweb") as archive:
        image = archive.read(next(name for name in archive.namelist() if name.endswith(".png")))
    (root / "fixture.png").write_bytes(image)
    ui.save_key("gemini")
    position_key = "pdf:" + hashlib.sha256(key.encode()).hexdigest()

    def position():
        for path in (root / ".vellum/positions").glob("*.json"):
            entry = json.loads(path.read_bytes())["documents"].get(position_key, {})
            if "reading_position" in entry:
                return entry["reading_position"]["value"]["page"]

    def text():
        value = ui.get("Scratchpad Markdown").queryText()
        return value.getText(0, value.characterCount)

    def attach():
        ui.click("Attach Image")
        ui.select("fixture.png", role="table row")
        ui.click("Open")

    def snapshot():
        return ui.manifest(root / ".vellum")

    for case in ("replaced", "deleted", "claimed"):
        app = subprocess.Popen(["/runtime/vellum-linux", "--library", str(root)])
        try:
            ui.wait(lambda: ui.has_status("PDF open"), "PDF opens")
            if case == "replaced":
                ui.click("Settings")
                ui.click("Enable Shared Editing")
                ui.wait(lambda: ui.has_status("Shared editing enabled for this folder."), "shared editing enabled")
                ui.click("Done")
            if ui.has_status("Page 2 of 2"):
                ui.click("Previous page")
            ui.wait(lambda: position() == 1, "position writes to selected stamp")
            ui.click("Chat")
            ui.click("Scratchpad")
            ui.wait(lambda: ui.has_status("Shared scratchpad"), "note opened")
            current_note = note.read_bytes()
            current_chat = conversation.read_bytes()
            assert ui.get("Scratchpad Markdown").queryEditableText().setTextContents(current_note.decode() + "\n" + case)
            attach()
            ui.wait(lambda: "attachments/" in text()[len(current_note.decode()):], "attachment staged in draft")
            markdown = text()
            name = re.findall(r'attachments/([a-z0-9-]+\.png)', markdown)[-1]
            question = case + "?"
            ui.send(question)
            ui.first_delta(question)
            claim = root / ".vellum/documents" / hashlib.sha256(original).hexdigest() / "meta.json"
            if case == "replaced":
                file.write_bytes(original.replace(key.encode(), b"bbaa1234"))
            elif case == "deleted":
                file.unlink()
            else:
                claim.parent.mkdir()
                claim.write_text(json.dumps({"kind": "pdf", "last_known_path": "PDFs/classic-two-column.pdf"}))
            before = snapshot()
            ui.click("Next page")
            ui.click("Save")
            ui.release.set()
            ui.wait(lambda: ui.has_status("Save failed.") or ui.has_status("Scratchpad saved."), "scratchpad result")
            ui.wait(lambda: ui.has_status("Chat has unsaved messages") or conversation.read_bytes() != current_chat,
                    "chat result")
            ui.wait(lambda: ui.has_status("Could not save the reading position") or position() == 2, "position result")
            after = snapshot()
            changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k) or (k in before) != (k in after))
            assert not changed, (case, "stale PDF changed shared paths", changed)
            assert ui.has_status("Save failed.") and ui.has_status("Chat has unsaved messages")
            # Even importing a second image into the open draft checks the current identity.
            attach()
            ui.get("PDF identity changed or could not be verified. Restore the original document before retrying.")
            assert text() == markdown
            if case == "deleted":
                ui.select("harbor.vellumweb")
                ui.wait(lambda: "Apple history" in ui.transcript(), "leave while both PDF sidecars are dirty")
                ui.wait(lambda: ui.has_status("Shared scratchpad") and case not in text(), "archive scratchpad is independent")
                assert ui.get("Scratchpad Markdown").queryEditableText().setTextContents("Archive note")
                ui.click("Save")
                ui.wait(lambda: ui.has_status("Scratchpad saved."), "archive note published")
                assert (ui.saved_file.parent / "scratchpad.md").read_bytes() == b"Archive note"
                ui.click("Close")
                ui.click("Leave With Local Copy")
                assert app.wait(timeout=8) == 0
                assert note.read_bytes() == current_note and conversation.read_bytes() == current_chat
            if case == "claimed":
                claim.unlink()
            # A legal incremental update has different bytes but the original storage identity.
            original = revision(original, [(6, b"<< /VellumDocId (4850abcd) /Title (Updated) >>")], 8, 6)
            file.write_bytes(original)
            if case == "deleted":
                app = subprocess.Popen(["/runtime/vellum-linux", "--library", str(root)])
                ui.wait(lambda: ui.has_status("PDF open"), "reopen original PDF")
                ui.click("Chat")
                ui.click("Scratchpad")
                ui.wait(lambda: ui.has_status("Recovered local draft") and question in ui.transcript(), "both drafts restored")
            ui.click("Save")
            ui.click("Retry Save")
            ui.wait(lambda: note.read_bytes() == markdown.encode() and question.encode() in conversation.read_bytes(),
                    "same-key retry saved both sidecars")
            assert (directory / "attachments" / name).read_bytes() == image
            assert conversation.read_bytes().startswith(current_chat[:-1] + b",")
            assert [m["content"] for m in json.loads(conversation.read_bytes())].count(question) == 1
            ui.click("Close")
            assert app.wait(timeout=8) == 0
            print(case, "blocked scratchpad, attachment, chat and position; restored ID accepted", flush=True)
        finally:
            if app.poll() is None:
                app.kill()
                app.wait()

    # A valid hash claim takes precedence even on a stamped PDF. Until the
    # reader can check the claim, neither candidate may own this tab.
    hash_directory = directory.parent / hashlib.sha256(original).hexdigest()
    hash_directory.mkdir()
    metadata = hash_directory / "meta.json"
    metadata.write_text(json.dumps({"kind": "pdf", "last_known_path": "PDFs/classic-two-column.pdf"}))
    hash_note = hash_directory / "scratchpad.md"
    hash_note.write_bytes(b"Hash note")
    hash_chat = hash_directory / "conversations.json"
    hash_chat.write_bytes(b'[{"id":"h","content":"Hash history","role":"user","createdAt":"peer","x":1.200}]')
    stamp_before = ui.manifest(directory)
    for blocked in (root / ".vellum/positions", metadata):
        mode = blocked.stat().st_mode & 0o777
        before = snapshot()
        blocked.chmod(0)
        app = subprocess.Popen(["/runtime/vellum-linux", "--library", str(root)])
        try:
            ui.wait(lambda: ui.has_status("Restore access, then reopen the folder in Settings"), "metadata failure explained")
            ui.click("Next page")
            ui.wait(lambda: ui.has_status("Page 2 of 2") and ui.has_status("Restore access"), "PDF remains readable")
            ui.click("Scratchpad")
            ui.click("Chat")
            ui.wait(lambda: ui.has_status("no shared scratchpad identity"), "no Scratchpad bound")
            assert not text() and not ui.transcript()
            assert not ui.get("Send").getState().contains(ui.pyatspi.STATE_SENSITIVE)
            assert not ui.get("Scratchpad Markdown").getState().contains(ui.pyatspi.STATE_EDITABLE)
            if blocked == metadata:
                ui.capture("reader-identity-unavailable.png")
            if blocked != metadata:
                ui.click("Close")
                assert app.wait(timeout=8) == 0
            blocked.chmod(mode)
            assert snapshot() == before
            if blocked == metadata:
                ui.click("Settings")
                ui.click("Reopen")
                ui.click("Done")
                ui.wait(lambda: text() == "Hash note" and "Hash history" in ui.transcript(), "retry selects legacy hash")
                assert "Existing turn" not in ui.transcript()
                assert ui.get("Scratchpad Markdown").queryEditableText().setTextContents("Edited hash note")
                ui.click("Save")
                ui.reply("Hash chat?")
                ui.wait(lambda: b"Hash chat?" in hash_chat.read_bytes() and hash_note.read_bytes() == b"Edited hash note",
                        "verified hash receives both shared saves")
                ui.click("Close")
                assert app.wait(timeout=8) == 0
                assert ui.manifest(directory) == stamp_before
            print(blocked.name, "unreadable: PDF pages available, shared sidecars withheld", flush=True)
        finally:
            blocked.chmod(mode)
            if app.poll() is None:
                app.kill()
                app.wait()

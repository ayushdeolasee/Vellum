"""In the offline Colima dev image: python3 Linux/Tests/GTKReader/annotation-reopen.py /build/linux/debug/vellum-linux"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def wait(check, description):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        result = check()
        if result is not None and result is not False:
            return result
        time.sleep(.04)
    raise RuntimeError(f"Timed out waiting for {description}")


def revision(data, number, body, trailer):
    previous = int(re.findall(rb"startxref\s+(\d+)", data)[-1])
    offset = len(data)
    data += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(data)
    return (data + b"xref\n%d 1\n%010d 00000 n \ntrailer\n<< " % (number, offset) +
            trailer + b" /Prev %d >>\nstartxref\n%d\n%%%%EOF\n" % (previous, xref))


def run(binary, tmp):
    import pyatspi as at
    desktop = at.Registry.getDesktop(0)

    def find(role, name, node=desktop):
        if node.getRoleName() == role and node.name == name:
            return node
        for child in node:
            if child is not None:
                match = find(role, name, child)
                if match is not None:
                    return match

    def widget(role, name):
        return wait(lambda: find(role, name), f"{role} {name}")

    def activate(name, role="push button"):
        w = widget(role, name)
        wait(lambda: w.getState().contains(at.STATE_SENSITIVE), name)
        assert w.queryAction().doAction(0), name

    def text(name):
        t = widget("text", name).queryText()
        return t.getText(0, t.characterCount)

    def select(name):
        row = widget("list item", name)
        assert row.parent.querySelection().selectChild(row.getIndexInParent())

    fixture = Path(__file__).resolve().parents[3] / "Packages/VellumCore/Tests/VellumCoreTests/Fixtures/Pdf/rotated-all-angles.pdf"
    source = fixture.read_bytes()
    page = re.search(rb"(?m)^4 0 obj\s*(.*?)\s*endobj", source, re.S)[1]
    original = source
    for _ in range(62):
        original = revision(original, 4, page, b"/Size 12 /Root 1 0 R")
    ambiguous = revision(source, 12, b"<< /VellumDocId /NotAString >>", b"/Size 13 /Root 1 0 R /Info 12 0 R")
    library = tmp / "library"
    pdfs = library / "PDFs"
    pdfs.mkdir(parents=True)
    for filename, title, data in [("A.pdf", "My shared book", original), ("B.pdf", "Ambiguous ID", ambiguous)]:
        (pdfs / filename).write_bytes(data)
        key = hashlib.sha256(data).hexdigest()
        sidecar = library / ".vellum/documents" / key
        sidecar.mkdir(parents=True)
        (sidecar / "meta.json").write_text(json.dumps(dict(kind="pdf", title=title, last_known_path="PDFs/" + filename)))
        (sidecar / "scratchpad.md").write_text("My existing notes")

    comment = "Final endobj comment"
    restriction = "Read only · Vellum reached its PDF inspection limit. You can keep reading this document, but further edits cannot be saved safely."
    for first in [True, False]:
        process = subprocess.Popen([binary, "--library", library])
        try:
            widget("frame", "My shared book")
            if first:
                activate("Settings")
                activate("Enable Shared Editing")
                widget("push button", "Use Read Only")
                activate("Done")
                activate("Next page")
            widget("label", "Page 2 of 4")
            activate("Annotations")
            if first:
                widget("text", "Annotation comment").queryEditableText().setTextContents(comment)
                activate("Add note")
                widget("label", restriction)
                saved = (pdfs / "A.pdf").read_bytes()
                assert saved.startswith(original) and saved.count(b"startxref") == 64
                assert hashlib.sha256(original).hexdigest().encode() in saved[len(original):]
            else:
                widget("label", restriction)
                assert not widget("push button", "Add note").getState().contains(at.STATE_SENSITIVE)
                activate("Page annotations", "toggle button")
                widget("label", "1. Note " + comment)
                activate("Page annotations", "toggle button")
                activate("Scratchpad", "toggle button")
                wait(lambda: text("Scratchpad Markdown") == "My existing notes", "original scratchpad")
                activate("Scratchpad", "toggle button")
                select("B.pdf")
                widget("frame", "Ambiguous ID")
                widget("text", "Annotation comment").queryEditableText().setTextContents("Leave original intact")
                activate("Add note")
                widget("label", "Could not save the annotation. PDF already has /VellumDocId")
                assert (pdfs / "B.pdf").read_bytes() == ambiguous
                assert text("Annotation comment") == "Leave original intact"
                activate("Close")
                activate("Discard comment changes")
            activate("Close")
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    assert (pdfs / "A.pdf").read_bytes() == saved
    print("Reopened page 2 with the original title, scratchpad and last readable comment. Ambiguous identity refused.")


if __name__ == "__main__":
    if len(sys.argv) == 2:
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory, WAYLAND_DISPLAY="annotation-test",
                       GDK_BACKEND="wayland", GTK_A11Y="atspi", GSK_RENDERER="cairo", GSETTINGS_BACKEND="memory")
            for suffix in ["CONFIG", "DATA", "CACHE", "STATE"]:
                env[f"XDG_{suffix}_HOME"] = f"{directory}/{suffix.lower()}"
            subprocess.run(["dbus-run-session", "--", sys.executable, __file__, sys.argv[1], directory], env=env, check=True)
    else:
        tmp = Path(sys.argv[2])
        weston = subprocess.Popen(["weston", "--no-config", "--backend=headless", "--renderer=pixman",
                                   "--shell=desktop-shell.so", "--width=1100", "--height=760",
                                   "--socket=annotation-test", "--idle-time=0"],
                                  stderr=subprocess.DEVNULL)
        try:
            wait(lambda: (tmp / "annotation-test").is_socket(), "private Weston socket")
            run(sys.argv[1], tmp)
        finally:
            weston.terminate()
            weston.wait(timeout=5)

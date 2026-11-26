"""Drive the normal GTK window over AT-SPI and inspect compositor pixels."""
import os
from pathlib import Path
import subprocess
import sys
import time

from gi.repository import GLib
from PIL import Image, ImageChops
import pyatspi

desktop = pyatspi.Registry.getDesktop(0)
pictures = Path(os.environ["XDG_PICTURES_DIR"])
rotated = "rotated-all-angles.pdf"


def find(role, name=None, root=desktop):
    if root.getRoleName() == role and (name is None or root.name == name):
        return root
    for child in root:
        if child is not None:
            match = find(role, name, child)
            if match is not None:
                return match


def wait_for(check, description):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise RuntimeError(f"Timed out waiting for {description}")


def button(name):
    widget = wait_for(lambda: find("push button", name), name)
    assert widget.getState().contains(pyatspi.STATE_SENSITIVE), f"{name} is disabled"
    action = widget.queryAction()
    assert action.doAction(0), f"{name} action failed"


def select(name):
    rows = find("list")
    for i, row in enumerate(rows):
        if find("label", name, row) is not None:
            assert rows.querySelection().selectChild(i), f"Could not select {name}"
            return
    raise RuntimeError(f"Library row {name!r} is missing from the mounted fixture")


def page(number):
    def ready():
        return (find("frame", rotated) is not None and
                find("label", f"Page {number} of 4") is not None and
                find("label", "PDF open · Read only") is not None)
    wait_for(ready, f"{rotated}, page {number} of 4")


def capture(number):
    # P7 crop is 552 x 708 pt. Coordinates below are landmark centers in
    # top-down display space. GTK scales and positions the page to fit its pane.
    points = [(15, 691), (530, 685), (22, 21), (523, 28)]
    if number == 2:
        points = [(707 - y, x) for x, y in points]

    def painted():
        for path in pictures.glob("*.png"):
            path.unlink()
        subprocess.run(["weston-screenshooter"], cwd=pictures, check=True, timeout=4)
        path, = pictures.glob("*.png")
        with Image.open(path) as source:
            frame = source.convert("RGB")
        # Pure landmark colors in the reader pane. Require their geometry to
        # agree with one translation and uniform scale (including the rotation).
        centers = []
        for color in [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 0, 255)]:
            channels = ImageChops.difference(frame, Image.new("RGB", frame.size, color)).split()
            distance = ImageChops.lighter(ImageChops.lighter(*channels[:2]), channels[2])
            mask = distance.point(lambda d: 255 if d < 12 else 0)
            box = mask.getbbox()
            if box is None or mask.histogram()[255] < 4:
                return None
            x0, y0, x1, y1 = box
            centers.append(((x0 + x1) / 2, (y0 + y1) / 2))
        # Red to magenta spans both axes on both pages.
        scale = (centers[3][0] - centers[0][0]) / (points[3][0] - points[0][0])
        if scale < .35:
            return None
        for (x, y), (px, py) in zip(centers, points):
            if (abs(x - centers[0][0] - scale * (px - points[0][0])) > 4 or
                    abs(y - centers[0][1] - scale * (py - points[0][1])) > 4):
                return None
        print(f"Page {number} of 4: red, green, blue, magenta at {centers}", flush=True)
        return frame

    return wait_for(painted, f"painted P7 landmarks on page {number}")


def archive_ready(filename, title, position, ink):
    select(filename)
    wait_for(lambda: find("frame", title) and find("label", position) and
             find("label", "Offline archive · Read only") and
             (find("label", "Has handwriting: view on iPad/Mac") is not None) == ink,
             f"{title}, {position}, handwriting={ink}")
    for name in ("Previous page", "Next page"):
        assert not find("push button", name).getState().contains(pyatspi.STATE_SENSITIVE)


def harbor():
    archive_ready("harbor.vellumweb", "Exchange 東京", "Saved page 1 of 1", True)

    def painted():
        for path in pictures.glob("*.png"):
            path.unlink()
        subprocess.run(["weston-screenshooter"], cwd=pictures, check=True, timeout=4)
        path, = pictures.glob("*.png")
        with Image.open(path) as source:
            frame = source.convert("RGB")
        # sample.png is a solid 17 x 11 rectangle of this exact color.
        diff = ImageChops.difference(frame, Image.new("RGB", frame.size, (34, 112, 94))).split()
        distance = ImageChops.lighter(ImageChops.lighter(*diff[:2]), diff[2])
        box = distance.point(lambda d: 255 if d == 0 else 0).getbbox()
        if box and (box[2] - box[0], box[3] - box[1]) == (17, 11):
            print(f"Painted Harbor image at {box}", flush=True)
            return frame
    return wait_for(painted, "painted Harbor offline image")


def verify_webkit_sandbox():
    def status(pid):
        fields = Path(f"/proc/{pid}/status").read_text().splitlines()
        return dict(line.split(":", 1) for line in fields)
    processes = []
    for process in Path("/proc").glob("[0-9]*"):
        try:
            processes.append(status(process.name))
        except (FileNotFoundError, ProcessLookupError):
            continue
    owner = next(p for p in processes if p["Name"].strip() == "vellum-linux")
    for child in processes:
        if not child["Name"].strip().startswith("WebKitWebProces"):
            continue
        if (len(child["NSpid"].split()) > len(owner["NSpid"].split()) and
            int(child["Seccomp_filters"]) > int(owner["Seccomp_filters"]) and
            int(child["NoNewPrivs"]) == 1 and int(child["CapEff"], 16) == 0):
            print(f"WebKitWebProcess NSpid={child['NSpid'].split()}, "
                  f"seccomp filters {int(owner['Seccomp_filters'])} -> {int(child['Seccomp_filters'])}, "
                  "NoNewPrivs=1 CapEff=0", flush=True)
            return
    raise RuntimeError("No WebKit web process with nested PID namespace and additional seccomp filter")


wait_for(lambda: find("list item"), "library rows")
if sys.argv[2:3] == ["web"]:
    select(rotated)
    page(1)
    harbor()
    verify_webkit_sandbox()
    select(rotated)
    page(1)
    assert find("label", "Has handwriting: view on iPad/Mac") is None
    if sys.argv[3:] == ["normal"] and find("label", "sidecar-only.vellumweb") is not None:
        archive_ready("sidecar-only.vellumweb", "Sidecar article", "Saved page 3 of 5", True)
        archive_ready("plain.vellumweb", "Plain article", "Saved page 1 of 1", False)
        print("Record title + peer position + sidecar-only badge verified; plain archive has no badge", flush=True)
    harbor().save(sys.argv[1])
    button("Close")
    print("Closed the window with the web row selected", flush=True)
    sys.exit(0)
# Exercise a superseded selection through the real sidebar.
if find("label", "damaged.pdf") is not None:
    select("damaged.pdf")
    wait_for(lambda: find("label", "This file could not be read as a PDF."), "unreadable PDF message")
select(rotated)
select("classic-two-column.pdf")
select(rotated)
page(1)
assert not find("push button", "Previous page").getState().contains(pyatspi.STATE_SENSITIVE)
first = capture(1)
next_button = find("push button", "Next page")
button("Next page")
page(2)
second = capture(2)
previous = find("push button", "Previous page")
assert previous.getState().contains(pyatspi.STATE_SENSITIVE), "Previous is disabled on page 2"
button("Previous page")
page(1)
capture(1)
assert not previous.getState().contains(pyatspi.STATE_SENSITIVE), "Previous is enabled on page 1"
assert next_button.getState().contains(pyatspi.STATE_SENSITIVE), "Next is disabled on page 1"
if find("label", "harbor.vellumweb") is not None:
    harbor()
button("Close")
print("Activated the GTK window’s Close button", flush=True)
pair = Image.new("RGB", (first.width + second.width, first.height))
pair.paste(first)
pair.paste(second, (first.width, 0))
pair.save(sys.argv[1])

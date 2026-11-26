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
    index = next(i for i, row in enumerate(rows) if find("label", name, row) is not None)
    assert rows.querySelection().selectChild(index), f"Could not select {name}"


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


wait_for(lambda: find("list item"), "library rows")
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
button("Next page")
page(2)
second = capture(2)
button("Previous page")
page(1)
button("Close")
print("Activated the GTK window’s Close button", flush=True)
pair = Image.new("RGB", (first.width + second.width, first.height))
pair.paste(first)
pair.paste(second, (first.width, 0))
pair.save(sys.argv[1])

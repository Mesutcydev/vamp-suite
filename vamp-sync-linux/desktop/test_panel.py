"""Exercise the GTK companion state transitions on a disposable X11 display."""

from argparse import Namespace
import os
from pathlib import Path
import traceback

from vamp_sync import Gdk, GLib, Gtk, SyncPanel


def children(widget, kind):
    if isinstance(widget, kind):
        yield widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            yield from children(child, kind)


def take_screenshot(panel, name):
    output = os.environ.get("VAMP_TEST_PANEL_OUTPUT")
    if not output:
        return
    display = panel.window.get_window()
    width, height = panel.window.get_size()
    pixbuf = Gdk.pixbuf_get_from_window(display, 0, 0, width, height)
    pixbuf.savev(str(Path(output) / (name + ".png")), "png", [], [])


def main():
    panel = SyncPanel(Namespace(
        host=Path("/unused"), bind="192.168.77.12", name="Vamp Sync (Linux)", start=False,
        control=True, clipboard=False, app=[], state_dir=None, no_discovery=True, appearance="light",
    ))
    host_fingerprint = "e1" * 32
    peer_fingerprint = "34" * 32
    status = {
        "type": "status", "address": "192.168.77.12:9471", "hostName": "Vamp Sync (Linux)",
        "fingerprint": host_fingerprint, "desktopReady": True, "control": True,
        "devices": [], "discovery": True,
    }
    commands = []
    errors = []

    def exercise(callback):
        def step():
            try:
                callback()
            except BaseException:
                errors.append(traceback.format_exc())
                panel.quit()
            return GLib.SOURCE_REMOVE
        return step

    def show_ready():
        assert panel.status_label.get_text() == "Offline"
        assert not panel.pair_card.get_visible()
        panel.backend.process = object()
        panel.backend.send = commands.append
        panel.receive(status)
        assert panel.status_label.get_text() == "Ready"
        assert panel.pair_card.get_visible()
        assert panel.qr_image.get_pixbuf().get_width() == 110
        assert "fp=" + host_fingerprint in panel.pairing_link
        GLib.timeout_add(250, exercise(show_approval))

    def show_approval():
        take_screenshot(panel, "ready")
        panel.receive({**status, "pending": {"name": "Studio iPad", "fingerprint": peer_fingerprint}})
        entry = next(children(panel.approval, Gtk.Entry))
        approve = next(button for button in children(panel.approval, Gtk.Button)
                       if button.get_label() == "Codes match — approve")
        assert not approve.get_sensitive()
        entry.set_text("e1" * 32)
        assert not approve.get_sensitive()
        entry.set_text(" ".join(["34343434"] * 8))
        assert approve.get_sensitive()
        approve.clicked()
        assert commands == ["approve " + peer_fingerprint]
        entry.set_text("")
        GLib.timeout_add(250, exercise(show_stream))

    def show_stream():
        take_screenshot(panel, "approval")
        panel.root.get_style_context().add_class("dark")
        panel.receive({
            **status, "client": "Studio iPad", "stream": "Text Editor", "frames": 60,
            "devices": [{"name": "Studio iPad", "fingerprint": peer_fingerprint}],
        })
        assert panel.status_label.get_text() == "Live"
        assert panel.device_count.get_text() == "1"
        assert not panel.approval.get_visible()
        GLib.timeout_add(250, exercise(finish))

    def finish():
        take_screenshot(panel, "live-dark")
        panel.quit()

    GLib.timeout_add(300, exercise(show_ready))

    def deadline():
        errors.append("Panel smoke test timed out")
        panel.quit()
        return GLib.SOURCE_REMOVE

    GLib.timeout_add_seconds(6, deadline)
    result = panel.run([])
    for error in errors:
        print(error)
    return 1 if errors else result


if __name__ == "__main__":
    raise SystemExit(main())

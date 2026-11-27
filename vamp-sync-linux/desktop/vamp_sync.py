#!/usr/bin/env python3
"""Native GTK companion for the Vamp Sync Linux host."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote, urlencode

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango

PANEL = Path(__file__).resolve().parent
HOST_DIR = PANEL.parent
ASSETS = Path(os.environ.get("VAMP_SYNC_ARTWORK", HOST_DIR.parent / "Sources/HostApp/Assets.xcassets"))
DEFAULT_HOST = Path(os.environ.get("VAMP_SYNC_HOST", HOST_DIR / "build/vamp-sync-linux"))
FINGERPRINT = re.compile(r"[0-9a-f]{64}\Z")
TAILNET = ipaddress.ip_network("100.64.0.0/10")
LAN_RANGES = tuple(map(ipaddress.ip_network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def classes(widget, *names):
    context = widget.get_style_context()
    for name in names:
        context.add_class(name)
    return widget


def row(spacing=8):
    return Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)


def column(spacing=8):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)


def label(text="", *styles, wrap=False):
    widget = Gtk.Label(label=text, xalign=0)
    widget.set_valign(Gtk.Align.CENTER)
    if wrap:
        widget.set_line_wrap(True)
        widget.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        widget.set_max_width_chars(45)
    return classes(widget, *styles)


def icon(name, size=16):
    widget = Gtk.Image.new_from_icon_name(name, Gtk.IconSize.MENU)
    widget.set_pixel_size(size)
    return widget


def button(text, action, *styles):
    widget = Gtk.Button(label=text)
    widget.connect("clicked", lambda *_: action())
    return classes(widget, *styles)


def icon_button(name, title, action):
    widget = Gtk.Button()
    widget.add(icon(name))
    widget.get_accessible().set_name(title)
    widget.set_tooltip_text(title)
    widget.connect("clicked", lambda *_: action())
    return classes(widget, "flat")


def card(*styles):
    return classes(column(10), "card", *styles)


def add(container, widget, expand=False, end=False):
    pack = container.pack_end if end else container.pack_start
    pack(widget, expand, expand, 0)
    return widget


def margins(widget, horizontal, vertical):
    widget.set_margin_start(horizontal)
    widget.set_margin_end(horizontal)
    widget.set_margin_top(vertical)
    widget.set_margin_bottom(vertical)
    return widget


def label_and_value(parent, text, value):
    line = add(parent, row())
    add(line, label(text, "small"), True)
    return add(line, label(value, "small", "secondary"))


def fingerprint_display(value):
    chunks = [value[start:start + 8] for start in range(0, len(value), 8)]
    return "\n".join(" ".join(chunks[start:start + 4]) for start in range(0, len(chunks), 4))


def network_addresses():
    addresses = {"lan": None, "tailnet": None}
    try:
        routes = json.loads(subprocess.check_output(["ip", "-j", "-4", "route", "show", "default"], timeout=2))
        interfaces = json.loads(subprocess.check_output(["ip", "-j", "-4", "address", "show", "up", "scope", "global"], timeout=2))
    except (OSError, ValueError, subprocess.SubprocessError):
        return addresses
    preferred = {route.get("dev") for route in routes}
    interfaces.sort(key=lambda nic: nic.get("ifname") not in preferred)
    for nic in interfaces:
        name = nic.get("ifname", "")
        for candidate in nic["addr_info"]:
            address = ipaddress.IPv4Address(candidate["local"])
            if name == "tailscale0" and address in TAILNET:
                addresses["tailnet"] = str(address)
            elif (not addresses["lan"] and not name.startswith(("docker", "br-", "veth", "virbr", "podman", "tailscale"))
                  and any(address in prefix for prefix in LAN_RANGES)):
                addresses["lan"] = str(address)
    return addresses


class HostProcess:
    def __init__(self, receive, stopped):
        self.receive = receive
        self.stopped = stopped
        self.process = None

    def start(self, args):
        self.process = process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8",
        )
        threading.Thread(target=self.read, args=(process,), daemon=True).start()

    def read(self, process):
        try:
            for line in process.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                GLib.idle_add(self.deliver, process, event)
        finally:
            process.stdout.close()
            process.stdin.close()
            result = process.wait()
            GLib.idle_add(self.exited, process, result)

    def deliver(self, process, event):
        if process is self.process:
            self.receive(event)
        return GLib.SOURCE_REMOVE

    def exited(self, process, result):
        if process is self.process:
            self.process = None
            self.stopped(result)
        return GLib.SOURCE_REMOVE

    def send(self, command):
        if self.process is None:
            return
        try:
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def stop(self):
        if self.process is None:
            return
        process = self.process
        self.send("quit")

        def ensure_exit():
            if process.poll() is None:
                process.terminate()
            return GLib.SOURCE_REMOVE

        GLib.timeout_add_seconds(4, ensure_exit)


class SyncPanel(Gtk.Application):
    def __init__(self, options):
        super().__init__(application_id="app.thevamp.SyncLinux", flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.options = options
        self.backend = HostProcess(self.receive, self.host_stopped)
        self.snapshot = {}
        self.problem = ""
        self.phase = "Offline"
        self.preferences_path = Path(GLib.get_user_config_dir()) / "vamp-sync-linux-panel" / "preferences.json"
        preferences = self.load_preferences()
        self.network = preferences.get("network") if preferences.get("network") in ("lan", "tailnet") else "lan"
        if options.bind:
            self.network = "tailnet" if ipaddress.IPv4Address(options.bind) in TAILNET else "lan"
        self.addresses = {}
        self.control = options.control if options.control is not None else preferences.get("control") is True
        self.appearance = options.appearance or preferences.get("appearance", "system")
        self.restart_pending = False
        self.closing = False
        self.refreshing_segments = False
        self.previous_frames = None
        self.approval_key = None
        self.pairing_key = None
        self.devices_key = None
        self.tray = None

    def load_preferences(self):
        try:
            value = json.loads(self.preferences_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_preferences(self):
        file = None
        try:
            self.preferences_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.preferences_path.parent, delete=False) as file:
                json.dump({"network": self.network, "control": self.control, "appearance": self.appearance}, file)
            os.replace(file.name, self.preferences_path)
        except OSError as error:
            self.message("Could not save settings", str(error))
        finally:
            if file:
                Path(file.name).unlink(missing_ok=True)

    def do_activate(self):
        if self.get_active_window():
            self.get_active_window().present()
            return
        self.window = Gtk.ApplicationWindow(application=self, title="Vamp Sync")
        self.window.set_default_size(420, 675)
        self.window.set_size_request(420, 410)
        self.window.set_decorated(False)
        self.window.set_position(Gtk.WindowPosition.CENTER)
        self.window.connect("delete-event", self.on_delete)
        visual = self.window.get_screen().get_rgba_visual()
        if visual:
            self.window.set_visual(visual)
        skin = Gtk.CssProvider()
        backdrop = (ASSETS / "SyncBackdrop.imageset/sync-corridor.png").as_uri()
        logo = (ASSETS / "VampSyncLogo.imageset/VampSyncLogo.png").as_uri()
        css = (PANEL / "panel.css").read_text(encoding="utf-8").replace("@BACKDROP@", backdrop).replace("@LOGO@", logo)
        skin.load_from_data(css.encode())
        Gtk.StyleContext.add_provider_for_screen(self.window.get_screen(), skin, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        classes(self.window, "vamp-window")
        self.root = column(0)
        self.root.set_name("vamp-panel")
        self.window.add(self.root)
        self.build_header()

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_overlay_scrolling(True)
        add(self.root, scroll, True)
        self.content = margins(column(13), 19, 0)
        self.content.set_margin_bottom(18)
        scroll.add(self.content)
        self.approval = add(self.content, card("raised", "approval"))
        self.status_card = add(self.content, card("raised"))
        self.build_status()
        self.build_pairing()
        self.build_mode()
        self.build_access()
        self.build_devices()
        self.build_footer()
        self.apply_appearance(self.appearance)
        self.refresh_addresses()
        self.window.show_all()
        self.window.set_focus(None)
        self.render()
        if self.options.start and self.addresses.get(self.network):
            self.start_host()

    def build_header(self):
        header = Gtk.EventBox()
        header.set_visible_window(False)
        header.connect("button-press-event", self.move_window)
        add(self.root, header)
        contents = margins(row(12), 19, 18)
        header.add(contents)
        try:
            mark = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                str(ASSETS / "VampSyncLogo.imageset/VampSyncLogo.png"), 40, 40, True,
            )
            mark_tile = add(contents, classes(Gtk.Box(), "mark"))
            mark_tile.set_size_request(40, 40)
            mark_tile.get_accessible().set_name("Vamp Sync")
            self.window.set_icon(mark)
            self.tray = Gtk.StatusIcon.new_from_pixbuf(mark)
            self.tray.set_tooltip_text("Vamp Sync")
            self.tray.connect("activate", self.toggle_panel)
        except GLib.Error:
            add(contents, icon("video-display-symbolic", 36))
        titles = add(contents, column(2), True)
        add(titles, label("Vamp Sync", "title"))
        add(titles, label("For Control and Stream", "small", "secondary"))
        self.status_dot = label("●", "state-dot")
        self.status_dot.set_size_request(8, 8)
        self.status_dot.set_valign(Gtk.Align.CENTER)
        add(contents, self.status_dot)
        self.status_label = add(contents, label("Offline", "small", "secondary"))
        add(contents, icon_button("window-close-symbolic", "Close Vamp Sync panel", self.hide_panel))

    def build_status(self):
        line = add(self.status_card, row(11))
        self.status_icon = add(line, classes(icon("system-shutdown-symbolic", 21), "tile"))
        self.status_icon.set_size_request(42, 42)
        texts = add(line, column(4), True)
        self.status_title = add(texts, label("", "heading", wrap=True))
        self.status_detail = add(texts, label("", "small", "secondary", wrap=True))
        self.status_action = add(line, button("Start", self.toggle_host))
        self.status_action.set_valign(Gtk.Align.START)
        self.metrics = add(self.status_card, row(18))
        for text, attribute in (("FRAME", "fps"), ("STREAM", "stream_type"), ("LINK", "link_type")):
            field = add(self.metrics, column(3), True)
            add(field, label(text, "metric", "secondary"))
            setattr(self, attribute, add(field, label("—", "small")))

    def build_pairing(self):
        self.pair_card = add(self.content, card("raised"))
        top = add(self.pair_card, row(8))
        add(top, label("Pair over", "small"))
        segment = add(top, classes(row(1), "segments"))
        self.lan_radio = Gtk.RadioButton(label="Local Wi-Fi")
        self.tailscale_radio = Gtk.RadioButton.new_with_label_from_widget(self.lan_radio, "Tailscale")
        for radio, selected in ((self.lan_radio, "lan"), (self.tailscale_radio, "tailnet")):
            radio.set_mode(False)
            radio.connect("toggled", self.change_network, selected)
            add(segment, radio)
        self.instructions = add(self.pair_card, label("", "small", "secondary", wrap=True))
        middle = add(self.pair_card, row(16))
        qr_box = classes(Gtk.EventBox(), "qr")
        qr_box.set_visible_window(True)
        qr_box.set_size_request(116, 116)
        qr_box.set_valign(Gtk.Align.CENTER)
        add(middle, qr_box)
        self.qr_image = Gtk.Image.new_from_icon_name("view-grid-symbolic", Gtk.IconSize.DIALOG)
        self.qr_image.get_accessible().set_name("QR code for Vamp pairing")
        qr_box.add(self.qr_image)
        copy = add(middle, column(6), True)
        add(copy, label("Make the connection", "pair-title", wrap=True))
        self.pair_detail = add(copy, label("", "small", "secondary", wrap=True))
        self.copy_link = add(copy, button("Copy pairing link", self.copy_pairing))
        self.copy_link.set_halign(Gtk.Align.START)
        self.address_line = add(self.pair_card, classes(row(8), "address"))
        add(self.address_line, icon("network-workgroup-symbolic"))
        self.address_label = add(self.address_line, label("", "mono"), True)
        self.address_label.set_selectable(True)
        add(self.address_line, label("Private", "tiny", "secondary"))
        fp_row = add(self.pair_card, row())
        add(fp_row, label("Host fingerprint", "tiny", "secondary"), True)
        self.copy_fingerprint = add(fp_row, icon_button(
            "edit-copy-symbolic", "Copy host fingerprint", lambda: self.copy_text(self.snapshot.get("fingerprint", "")),
        ))
        self.host_fp = add(self.pair_card, label("", "mono", "secondary", wrap=True))
        self.host_fp.set_selectable(True)
        add(self.pair_card, label("Every new device needs your approval.", "small", "secondary"))

    def build_mode(self):
        section = add(self.content, card())
        line = add(section, row())
        self.mode_icon = add(line, icon("input-mouse-symbolic"))
        self.mode_title = add(line, label("Remote control", "heading"), True)
        self.control_switch = Gtk.Switch()
        self.control_switch.set_valign(Gtk.Align.CENTER)
        self.control_switch.set_active(self.control)
        self.control_switch.get_accessible().set_name("Allow remote control")
        self.control_switch.connect("state-set", self.switch_control)
        add(line, self.control_switch)
        self.mode_detail = add(section, label("", "small", "secondary", wrap=True))

    def build_access(self):
        section = add(self.content, card())
        title = add(section, row())
        add(title, label("Linux access", "heading"), True)
        add(title, icon_button("view-refresh-symbolic", "Refresh permission status", self.refresh))
        self.screen_access = label_and_value(section, "Screen capture", "Waiting")
        self.input_access = label_and_value(section, "Keyboard and pointer", "Waiting")

    def build_devices(self):
        section = add(self.content, card())
        title = add(section, row())
        add(title, label("Trusted devices", "heading"), True)
        self.device_count = add(title, label("0", "small", "secondary"))
        self.device_list = add(section, column(8))

    def build_footer(self):
        footer = add(self.root, classes(row(8), "footer"))
        items = add(footer, margins(row(7), 18, 8), True)
        add(items, icon("changes-prevent-symbolic", 12))
        add(items, label("Private connection", "tiny", "secondary"), True)
        self.host_toggle = add(items, button("Start host", self.toggle_host, "flat"))
        menu_button = Gtk.MenuButton()
        menu_button.add(icon("emblem-system-symbolic", 16))
        menu_button.get_accessible().set_name("Vamp Sync settings")
        add(items, classes(menu_button, "flat"))
        menu = Gtk.Menu()
        for title, action in (
            ("Refresh status", self.refresh), ("Restart host", self.restart_host),
            ("Export diagnostics…", lambda: self.backend.send("diagnose")), (None, None),
            ("Appearance · System", lambda: self.apply_appearance("system")),
            ("Appearance · Light", lambda: self.apply_appearance("light")),
            ("Appearance · Dark", lambda: self.apply_appearance("dark")), (None, None),
            ("Quit Vamp Sync", self.quit_panel),
        ):
            item = Gtk.MenuItem(label=title) if title else Gtk.SeparatorMenuItem()
            if action:
                item.connect("activate", lambda _, func=action: func())
            menu.append(item)
            if title == "Export diagnostics…":
                self.export_item = item
        menu.show_all()
        menu_button.set_popup(menu)

    def render(self):
        active = self.backend.process is not None
        ready = self.snapshot.get("desktopReady", False)
        client = self.snapshot.get("client")
        stream = self.snapshot.get("stream")
        phase = self.phase
        if phase == "Ready":
            phase = "Setup needed" if not ready else "Live" if stream else "Connected" if client else "Ready"
        self.status_label.set_text(phase)
        dot = self.status_dot.get_style_context()
        dot.remove_class("good")
        dot.remove_class("attention")
        if phase in ("Ready", "Connected", "Live"):
            dot.add_class("good")
        if phase == "Setup needed":
            dot.add_class("attention")
        status = {
            "Offline": ("Host is off", "Pairing and private transport are offline.", "system-shutdown-symbolic", "Start"),
            "Starting": ("Starting secure host…", "Preparing signed discovery and authenticated transport.", "view-refresh-symbolic", "Stop"),
            "Stopping": ("Stopping host…", "Closing the private connection.", "system-shutdown-symbolic", "Stop"),
            "Connected": (f"{client} is connected", "Choose an app window or the desktop to begin.", "phone-symbolic", "Stop"),
            "Live": (f"Streaming {stream}", f"{client} can view this stream.", "video-display-symbolic", "Stop"),
            "Setup needed": ("Vamp Sync needs attention", self.problem or "Unlock your local X11 desktop, then re-check.",
                             "dialog-warning-symbolic", "Stop" if active else "Retry"),
        }
        self.status_card.set_visible(phase != "Ready")
        if phase in status:
            title, detail, glyph, action = status[phase]
            self.status_title.set_text(title)
            self.status_detail.set_text(detail)
            self.status_icon.set_from_icon_name(glyph, Gtk.IconSize.LARGE_TOOLBAR)
            self.status_action.set_label(action)
            style = self.status_action.get_style_context()
            style.remove_class("suggested-action")
            if not active:
                style.add_class("suggested-action")
        tile = self.status_icon.get_style_context()
        tile.remove_class("good")
        tile.remove_class("attention")
        if phase in ("Live", "Connected"):
            tile.add_class("good")
        elif phase == "Setup needed":
            tile.add_class("attention")
        self.metrics.set_visible(phase == "Live")
        self.status_action.set_sensitive(phase != "Stopping")
        self.host_toggle.set_label("Stop host" if active else "Start host")
        self.host_toggle.set_sensitive(phase != "Stopping")
        self.export_item.set_sensitive(active)
        self.screen_access.set_text("Allowed" if ready else "Unavailable" if active else "Host off")
        self.input_access.set_text("Allowed" if ready and self.snapshot.get("control") else "View Only" if ready else "Unavailable" if active else "Host off")
        self.mode_title.set_text("Remote control" if self.control else "View Only")
        self.mode_icon.set_from_icon_name("input-mouse-symbolic" if self.control else "view-reveal-symbolic", Gtk.IconSize.MENU)
        self.mode_detail.set_text("Paired devices can use the pointer, keyboard, and window controls."
                                  if self.control else "Paired devices can view your desktop or an open app window.")
        pending = self.snapshot.get("pending")
        self.window.set_urgency_hint(bool(pending))
        if self.tray:
            self.tray.set_tooltip_text("Vamp Sync · " + ("Verify device" if pending else phase))
        self.show_approval(pending)
        self.show_pairing()
        self.show_devices(self.snapshot.get("devices", []))

    def show_approval(self, pending):
        key = pending and pending.get("fingerprint")
        if key == self.approval_key:
            self.approval.set_visible(bool(key))
            return
        self.approval_key = key
        for child in self.approval.get_children():
            self.approval.remove(child)
        if not key or not FINGERPRINT.fullmatch(key):
            self.approval.hide()
            return
        title = add(self.approval, classes(row(), "attention"))
        add(title, icon("dialog-password-symbolic"))
        add(title, label("Verify " + (pending.get("name") or "device"), "heading", wrap=True), True)
        add(self.approval, label("Compare this complete fingerprint with the one shown on the device through a separate trusted channel.",
                                 "small", "secondary", wrap=True))
        code = add(self.approval, label(fingerprint_display(key), "mono", wrap=True))
        code.set_selectable(True)
        entry = add(self.approval, Gtk.Entry())
        entry.set_placeholder_text("Enter the fingerprint from your device")
        entry.get_accessible().set_name("Fingerprint from your device")
        entry.set_max_length(96)
        actions = add(self.approval, row())
        add(actions, button("Reject", lambda: self.backend.send("deny " + key)))
        approve = add(actions, button("Codes match — approve", lambda: self.backend.send("approve " + key), "suggested-action"), end=True)
        approve.set_sensitive(False)
        entry.connect("changed", lambda field: approve.set_sensitive("".join(field.get_text().split()).lower() == key))
        entry.connect("activate", lambda _: approve.clicked() if approve.get_sensitive() else None)
        self.approval.show_all()
        self.present_panel()

    def show_pairing(self):
        active = self.backend.process and self.phase == "Ready"
        address = self.snapshot.get("address", "") if active else ""
        fp = self.snapshot.get("fingerprint", "") if active else ""
        host_name = self.snapshot.get("hostName", "Vamp Sync")
        discovered = self.snapshot.get("discovery", False)
        key = (self.network, address, fp, host_name, discovered)
        self.pair_card.set_visible(bool(active))
        if not active or key == self.pairing_key:
            return
        self.pairing_key = key
        tailnet = self.network == "tailnet"
        self.instructions.set_text("Connect both devices to the same private Tailscale network, then scan this code."
                                   if tailnet else "Keep both devices on the same trusted Wi-Fi network, then scan this code.")
        self.pair_detail.set_text("Scan with Stream, or discover this computer in Control."
                                  if discovered else "Scan with Stream, or enter the address in Control.")
        self.address_label.set_text(address)
        self.address_line.set_visible(bool(address))
        self.host_fp.set_text(fingerprint_display(fp))
        self.copy_fingerprint.set_sensitive(bool(fp))
        self.pairing_link = ""
        if address and fp and not address.startswith("127."):
            self.pairing_link = "vampstream://pair?" + urlencode({"address": address, "name": host_name, "fp": fp}, quote_via=quote)
        self.copy_link.set_sensitive(bool(self.pairing_link))
        self.copy_link.set_label("Copy pairing link")
        if self.pairing_link:
            try:
                image = subprocess.check_output(["qrencode", "-o", "-", "-m", "4", "-s", "4"],
                                                input=self.pairing_link.encode(), timeout=2)
                loader = GdkPixbuf.PixbufLoader.new_with_type("png")
                loader.write(image)
                loader.close()
                pixbuf = loader.get_pixbuf().scale_simple(110, 110, GdkPixbuf.InterpType.NEAREST)
                self.qr_image.set_from_pixbuf(pixbuf)
                return
            except (OSError, GLib.Error, subprocess.SubprocessError):
                pass
        self.qr_image.set_from_icon_name("view-grid-symbolic", Gtk.IconSize.DIALOG)

    def show_devices(self, devices):
        key = (tuple((d.get("name"), d.get("fingerprint")) for d in devices), self.backend.process is not None)
        if key == self.devices_key:
            return
        self.devices_key = key
        for child in self.device_list.get_children():
            self.device_list.remove(child)
        self.device_count.set_text(str(len(devices)))
        if not devices:
            add(self.device_list, label("Your devices will appear here after pairing.", "small", "secondary", wrap=True))
        for device in devices:
            line = add(self.device_list, row(8))
            add(line, classes(icon("phone-symbolic"), "tile")).set_size_request(28, 28)
            details = add(line, column(2), True)
            name = device.get("name") or "Paired device"
            title = add(details, label(name, "heading"))
            title.set_ellipsize(Pango.EllipsizeMode.END)
            fp = device["fingerprint"]
            add(details, label(fp[:12] + "…" + fp[-8:], "mono", "secondary"))
            action = add(line, button("Revoke", lambda n=name, f=fp: self.revoke(n, f)))
            action.set_sensitive(self.backend.process is not None)
        self.device_list.show_all()

    def receive(self, event):
        if event.get("type") == "status":
            if self.phase == "Stopping":
                return
            self.snapshot = event
            self.phase = "Ready"
            self.problem = ""
            self.update_metrics(event)
        elif event.get("type") == "error":
            self.problem = event.get("message", "The host could not complete the request.")
            if self.phase == "Starting":
                self.phase = "Setup needed"
            else:
                self.message("Vamp Sync", self.problem)
        elif event.get("type") == "report":
            self.save_report(event["path"])
        self.render()

    def update_metrics(self, state):
        stream = state.get("stream")
        frames = state.get("frames")
        if stream and isinstance(frames, int):
            now = time.monotonic()
            if self.previous_frames and self.previous_frames[0] == stream:
                _, last_time, previous = self.previous_frames
                if now - last_time >= 0.35:
                    self.fps.set_text(f"{max(0, round((frames - previous) / (now - last_time)))} fps")
                    self.previous_frames = (stream, now, frames)
            else:
                self.previous_frames = (stream, now, frames)
                self.fps.set_text("—")
            self.stream_type.set_text("Desktop" if stream == "Linux Desktop" else "App window")
            self.link_type.set_text("Tailscale" if self.network == "tailnet" else "Private LAN")
        else:
            self.previous_frames = None

    def refresh_addresses(self):
        self.addresses = network_addresses()
        if self.options.bind:
            bind = ipaddress.IPv4Address(self.options.bind)
            kind = "tailnet" if bind in TAILNET else "lan"
            self.addresses[kind] = str(bind)
        fallback = "tailnet" if self.network == "lan" else "lan"
        if not self.backend.process and not self.addresses.get(self.network) and self.addresses.get(fallback):
            self.network = fallback
        self.refreshing_segments = True
        (self.lan_radio if self.network == "lan" else self.tailscale_radio).set_active(True)
        self.refreshing_segments = False

    def refresh(self):
        self.refresh_addresses()
        self.backend.send("status")
        self.render()

    def start_host(self):
        if self.backend.process:
            return
        self.refresh_addresses()
        address = self.addresses.get(self.network)
        if not address:
            self.problem = "Join a private LAN or connect Tailscale to get a pairing address."
            self.phase = "Setup needed"
            self.render()
            return
        args = [str(self.options.host), "--panel-events", "--bind", address, "--name", self.options.name]
        if not self.options.no_discovery and self.network == "lan" and not address.startswith("127."):
            args.append("--discover")
        if self.control:
            args.append("--control")
            if self.options.clipboard:
                args.append("--clipboard")
            for app in self.options.app:
                args.extend(["--app", app])
        if self.options.state_dir:
            args.extend(["--state-dir", self.options.state_dir])
        self.snapshot = {"devices": self.snapshot.get("devices", [])}
        self.pairing_key = None
        self.previous_frames = None
        self.problem = ""
        try:
            self.backend.start(args)
            self.phase = "Starting"
        except OSError as error:
            self.phase = "Setup needed"
            self.problem = str(error)
        self.render()

    def toggle_host(self):
        if not self.backend.process:
            self.start_host()
        elif self.confirm_disconnect("Stop hosting?"):
            self.stop_host()

    def restart_host(self):
        if not self.backend.process:
            self.start_host()
        elif self.confirm_disconnect("Restart Vamp Sync?"):
            self.restart_pending = True
            self.stop_host()

    def stop_host(self):
        self.phase = "Stopping"
        self.backend.stop()
        self.render()

    def host_stopped(self, result):
        if self.closing:
            self.quit()
            return
        self.snapshot = {"devices": self.snapshot.get("devices", [])}
        if self.restart_pending:
            self.restart_pending = False
            self.start_host()
            return
        if result and self.phase != "Stopping":
            self.problem = self.problem or "The host stopped unexpectedly."
            self.phase = "Setup needed"
        else:
            self.phase = "Offline"
        self.render()

    def change_network(self, widget, network):
        if self.refreshing_segments or not widget.get_active() or network == self.network:
            return
        self.refresh_addresses()
        if not self.addresses.get(network):
            self.message("Pair over Tailscale" if network == "tailnet" else "Pair over Local Wi-Fi",
                         "Connect Tailscale on this computer first." if network == "tailnet" else "Connect to a private LAN first.")
            return
        if self.backend.process and not self.confirm_disconnect("Change pairing network?"):
            return
        self.network = network
        self.save_preferences()
        self.refreshing_segments = True
        widget.set_active(True)
        self.refreshing_segments = False
        if self.backend.process:
            self.restart_pending = True
            self.stop_host()
        else:
            self.start_host()

    def switch_control(self, widget, value):
        if value == self.control:
            return False
        if self.backend.process and not self.confirm_disconnect("Change remote access?"):
            return True
        self.control = value
        self.save_preferences()
        widget.set_state(value)
        if self.backend.process:
            self.restart_pending = True
            self.stop_host()
        else:
            self.render()
        return False

    def copy_text(self, text):
        if text:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)

    def copy_pairing(self):
        self.copy_text(self.pairing_link)
        self.copy_link.set_label("Copied")

    def apply_appearance(self, appearance):
        if appearance not in ("system", "light", "dark"):
            appearance = "system"
        changed = appearance != self.appearance
        self.appearance = appearance
        settings = Gtk.Settings.get_default()
        if appearance == "system":
            settings.reset_property("gtk-application-prefer-dark-theme")
            system_theme = settings.get_property("gtk-theme-name").lower()
            dark = settings.get_property("gtk-application-prefer-dark-theme") or "dark" in system_theme
        else:
            dark = appearance == "dark"
            settings.set_property("gtk-application-prefer-dark-theme", dark)
        style = self.root.get_style_context()
        if dark:
            style.add_class("dark")
        else:
            style.remove_class("dark")
        if changed:
            self.save_preferences()

    def revoke(self, name, fingerprint):
        if FINGERPRINT.fullmatch(fingerprint) and self.confirm(f"Revoke {name}?", "The device must be approved before it can reconnect.", "Revoke"):
            self.backend.send("revoke " + fingerprint)

    def confirm_disconnect(self, title):
        return not self.snapshot.get("client") or self.confirm(title, "The connected device will be disconnected.", "Continue")

    def confirm(self, title, detail, action):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text=title)
        dialog.format_secondary_text(detail)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button(action, Gtk.ResponseType.ACCEPT)
        result = dialog.run()
        dialog.destroy()
        return result == Gtk.ResponseType.ACCEPT

    def message(self, title, detail):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.CLOSE, text=title)
        dialog.format_secondary_text(detail)
        dialog.run()
        dialog.destroy()

    def save_report(self, path):
        chooser = Gtk.FileChooserNative.new("Export Vamp Sync Diagnostics", self.window,
                                            Gtk.FileChooserAction.SAVE, "Save", "Cancel")
        chooser.set_do_overwrite_confirmation(True)
        chooser.set_current_name(Path(path).name)
        try:
            if chooser.run() == Gtk.ResponseType.ACCEPT:
                destination = Path(chooser.get_filename())
                if destination.resolve() != Path(path).resolve():
                    with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as file:
                        with open(path, "rb") as report:
                            shutil.copyfileobj(report, file)
        except OSError as error:
            self.message("Could not export diagnostics", str(error))
        finally:
            chooser.destroy()

    def move_window(self, _widget, event):
        if event.button == 1:
            self.window.begin_move_drag(event.button, int(event.x_root), int(event.y_root), event.time)
        return False

    def hide_panel(self):
        if self.tray and self.tray.is_embedded():
            self.hold_if_hidden()
            self.window.hide()
        else:
            self.window.iconify()

    def hold_if_hidden(self):
        if not getattr(self, "holding_tray", False):
            self.hold()
            self.holding_tray = True

    def toggle_panel(self, _tray):
        if self.window.get_visible():
            self.hide_panel()
        else:
            self.present_panel()

    def present_panel(self):
        if self.tray and self.tray.is_embedded():
            found, screen, anchor, _ = self.tray.get_geometry()
            if found:
                monitor = screen.get_monitor_at_point(anchor.x, anchor.y)
                usable = screen.get_monitor_workarea(monitor)
                width, height = self.window.get_size()
                x = max(usable.x, min(anchor.x + (anchor.width - width) // 2, usable.x + usable.width - width))
                below = anchor.y < usable.y + usable.height / 2
                y = min(usable.y + usable.height - height, anchor.y + anchor.height + 6) if below else anchor.y - height - 6
                self.window.move(x, max(usable.y, y))
        self.window.present()

    def on_delete(self, *_):
        self.hide_panel()
        return True

    def quit_panel(self):
        if not self.confirm_disconnect("Quit Vamp Sync?"):
            return
        self.closing = True
        if self.backend.process:
            self.stop_host()
        else:
            self.quit()


def main():
    parser = argparse.ArgumentParser(description="Vamp Sync Linux companion")
    parser.add_argument("--host", type=Path, default=DEFAULT_HOST)
    parser.add_argument("--bind", type=ipaddress.IPv4Address)
    parser.add_argument("--name", default="Vamp Sync (Linux)")
    parser.add_argument("--start", action="store_true", help="start hosting as soon as the panel opens")
    parser.add_argument("--control", action=argparse.BooleanOptionalAction)
    parser.add_argument("--clipboard", action="store_true")
    parser.add_argument("--app", action="append", default=[])
    parser.add_argument("--state-dir")
    parser.add_argument("--no-discovery", action="store_true")
    parser.add_argument("--appearance", choices=["system", "light", "dark"])
    application = SyncPanel(parser.parse_args())
    return application.run([])


if __name__ == "__main__":
    raise SystemExit(main())

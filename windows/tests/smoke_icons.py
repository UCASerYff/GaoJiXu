"""Inspect real Windows icons without using the input desktop or installed app."""

from __future__ import annotations

import argparse
import ctypes as ct
from ctypes import wintypes as win
import os
from pathlib import Path
import tempfile
import time
import uuid

from PIL import Image, ImageDraw

from smoke_tray import bind, cleanup, hide_icon, launch_private, run_private, until
from gaojixu import native_tray
from gaojixu.resources import windows_icon_path

DPI_VALUES = (96, 120, 144, 168, 192)
APP_ID = "GaoSeries.GaoJiXu"


class IconInfo(ct.Structure):
    _fields_ = [("icon", win.BOOL), ("x", win.DWORD), ("y", win.DWORD),
                ("mask", win.HBITMAP), ("color", win.HBITMAP)]


class Bitmap(ct.Structure):
    _fields_ = [("type", win.LONG), ("width", win.LONG), ("height", win.LONG),
                ("width_bytes", win.LONG), ("planes", win.WORD), ("bits", win.WORD), ("pixels", ct.c_void_p)]


class BitmapInfo(ct.Structure):
    _fields_ = [("size", win.DWORD), ("width", win.LONG), ("height", win.LONG),
                ("planes", win.WORD), ("depth", win.WORD), ("compression", win.DWORD),
                ("image_size", win.DWORD), ("x_pixels", win.LONG), ("y_pixels", win.LONG),
                ("colors", win.DWORD), ("important", win.DWORD), ("palette", win.DWORD)]


class PropertyKey(ct.Structure):
    _fields_ = [("format", ct.c_ubyte * 16), ("id", win.DWORD)]


class PropertyVariant(ct.Structure):
    _fields_ = [("type", win.WORD), ("reserved", win.WORD * 3), ("text", ct.c_wchar_p),
                ("padding", ct.c_void_p)]


def guid(value):
    return (ct.c_ubyte * 16).from_buffer_copy(uuid.UUID(value).bytes_le)


class WindowsIcons:
    def __init__(self):
        user = ct.WinDLL("user32", use_last_error=True)
        gdi = ct.WinDLL("gdi32", use_last_error=True)
        self.get_icon = bind(user, "GetIconInfo", win.BOOL, win.HICON, ct.POINTER(IconInfo))
        self.get_object = bind(gdi, "GetObjectW", ct.c_int, win.HANDLE, ct.c_int, ct.c_void_p)
        self.get_bits = bind(gdi, "GetDIBits", ct.c_int, win.HDC, win.HBITMAP, win.UINT, win.UINT,
                             ct.c_void_p, ct.POINTER(BitmapInfo), win.UINT)
        self.create_dc = bind(gdi, "CreateCompatibleDC", win.HDC, win.HDC)
        self.delete_dc = bind(gdi, "DeleteDC", win.BOOL, win.HDC)
        self.delete_object = bind(gdi, "DeleteObject", win.BOOL, win.HANDLE)
        self.dpi_for_window = bind(user, "GetDpiForWindow", win.UINT, win.HWND)
        self.metric = bind(user, "GetSystemMetricsForDpi", ct.c_int, ct.c_int, win.UINT)
        self.load_image = bind(user, "LoadImageW", win.HANDLE, win.HINSTANCE, win.LPCWSTR,
                               win.UINT, ct.c_int, ct.c_int, win.UINT)
        self.destroy_icon = bind(user, "DestroyIcon", win.BOOL, win.HICON)
        self.get_message = bind(user, "SendMessageTimeoutW", win.LPARAM, win.HWND, win.UINT,
                                win.WPARAM, win.LPARAM, win.UINT, win.UINT, ct.POINTER(ct.c_size_t))
        self.extract = bind(user, "PrivateExtractIconsW", win.UINT, win.LPCWSTR, ct.c_int,
                            ct.c_int, ct.c_int, ct.POINTER(win.HICON), ct.c_void_p, win.UINT, win.UINT)

    def bitmap(self, handle):
        info = IconInfo()
        assert handle and self.get_icon(handle, ct.byref(info)), "No native HICON bitmap"
        dc = self.create_dc(None)
        try:
            bitmap = Bitmap()
            assert info.color and dc
            assert self.get_object(info.color, ct.sizeof(bitmap), ct.byref(bitmap))
            width, height = bitmap.width, bitmap.height
            pixels = (ct.c_ubyte * (width * height * 4))()
            request = BitmapInfo(size=40, width=width, height=-height, planes=1, depth=32)
            assert self.get_bits(dc, info.color, 0, height, pixels, ct.byref(request), 0) == height
            return Image.frombytes("RGBA", (width, height), bytes(pixels), "raw", "BGRA")
        finally:
            if dc:
                self.delete_dc(dc)
            for owned in (info.mask, info.color):
                if owned:
                    self.delete_object(owned)

    def from_file(self, icon, width, height):
        handle = self.load_image(None, os.fspath(icon), 1, width, height, 0x0010)
        try:
            return self.bitmap(handle)
        finally:
            if handle:
                self.destroy_icon(handle)

    def from_executable(self, executable, width, height):
        handle = win.HICON()
        try:
            assert self.extract(os.fspath(executable), 0, width, height, ct.byref(handle), None, 1, 0) == 1
            return self.bitmap(handle.value)
        finally:
            if handle.value:
                self.destroy_icon(handle.value)

    def from_window(self, window, kind, dpi):
        handle = ct.c_size_t()
        if self.get_message(window, 0x007F, kind, dpi, 2, 1500, ct.byref(handle)) and handle.value:
            return self.bitmap(handle.value)
        return None


def app_id(window):
    shell = ct.WinDLL("shell32")
    ole = ct.WinDLL("ole32")
    open_store = bind(shell, "SHGetPropertyStoreForWindow", win.LONG, win.HWND, ct.c_void_p,
                      ct.POINTER(ct.c_void_p))
    clear = bind(ole, "PropVariantClear", win.LONG, ct.POINTER(PropertyVariant))
    pointer = ct.c_void_p()
    iid = guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")
    assert open_store(window, iid, ct.byref(pointer)) == 0 and pointer.value
    methods = ct.cast(pointer, ct.POINTER(ct.POINTER(ct.c_void_p))).contents
    release = ct.WINFUNCTYPE(win.ULONG, ct.c_void_p)(methods[2])
    get = ct.WINFUNCTYPE(win.LONG, ct.c_void_p, ct.POINTER(PropertyKey),
                         ct.POINTER(PropertyVariant))(methods[5])
    value = PropertyVariant()
    try:
        key = PropertyKey(guid("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), 5)
        status = get(pointer, ct.byref(key), ct.byref(value))
        return value.text if status >= 0 and value.type == 31 else None
    finally:
        clear(ct.byref(value))
        release(pointer)


def verify_resources(icon, executable=None, evidence=None):
    api = WindowsIcons()
    variants = {}
    with Image.open(icon) as icon_file:
        available = icon_file.ico.sizes()
        for dpi in DPI_VALUES:
            metrics = [(api.metric(x, dpi), api.metric(y, dpi)) for x, y in ((49, 50), (11, 12))]
            expected = [(dpi // 6,) * 2, (dpi // 3,) * 2]
            assert metrics == expected, (dpi, metrics)
            variants[dpi] = []
            for width, height in metrics:
                size = (width, height)
                assert size in available, (dpi, size, sorted(available))
                native = api.from_file(icon, *size)
                image = icon_file.ico.getimage(size).convert("RGBA")
                assert native.size == size
                assert image.getchannel("A").getextrema()[1] == 255 and image.getpixel((0, 0))[3] < 32
                if executable:
                    embedded = api.from_executable(executable, *size)
                    assert embedded.size == size and embedded.tobytes() == native.tobytes(), (dpi, size, "PE icon")
                variants[dpi].append(native)
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
        board = Image.new("RGB", (650, 282), "#f1f4f4")
        draw = ImageDraw.Draw(board)
        draw.text((18, 12), "GaoJiXu - native HICON pixels at 100% physical size", fill="#132e27")
        for index, (dpi, images) in enumerate(variants.items()):
            x = 10 + index * 128
            draw.text((x + 12, 39), f"{dpi * 100 // 96}% ({dpi} dpi)", fill="#132e27")
            for row, (image, label) in enumerate(zip(images, ("small / tray", "large"), strict=True)):
                y = 65 + 102 * row
                draw.text((x + 12, y), f"{image.width}px {label}", fill="#132e27")
                for col, color in enumerate(("#e4ebea", "#182221")):
                    left = x + col * 63
                    draw.rectangle((left, y + 18, left + 63, y + 83), fill=color)
                    # Large icons at 200% are 64 px, so paste on the one-pixel cell boundary.
                    board.paste(image, (left + (64 - image.width) // 2, y + 18 + (66 - image.height) // 2), image)
        board.save(evidence / "native-icon-pixel-grid.png")
    print("Native resource pixels passed: 96/120/144/168/192 DPI; small 16/20/24/28/32; large 32/40/48/56/64.", flush=True)


def verify_tray(icon):
    api = WindowsIcons()
    calls = []
    tray = native_tray.TrayIcon(lambda: None, lambda: None, None, None, None, None, None, icon_path=icon)
    native_notify = tray._windows.notify

    def hidden_notify(command, address):
        data = ct.cast(address, ct.POINTER(native_tray._NotifyIconData)).contents
        if command == native_tray._NIM_ADD:
            hide_icon(data)
        if command in (native_tray._NIM_ADD, native_tray._NIM_MODIFY) and data.icon:
            image = api.bitmap(data.icon)
            assert image.tobytes() == api.from_file(icon, *image.size).tobytes()
            size = image.size
        else:
            size = None
        accepted = native_notify(command, address)
        calls.append((command, bool(accepted), size))
        return accepted

    tray._windows.notify = hidden_notify
    tray._thread.start()
    try:
        assert tray._ready.wait(5) and tray._registered and tray._modern_events
        first_size = tray._windows.tray_icon_size(tray._window)
        assert (native_tray._NIM_ADD, True, first_size) in calls
        for dpi in DPI_VALUES:
            tray._windows.dpi_for_window = lambda _window, dpi=dpi: dpi
            tray._windows.find_window = lambda *_: tray._window
            rect = win.RECT()
            result = ct.c_size_t()
            assert api.get_message(tray._window, native_tray._WM_DPICHANGED, dpi | (dpi << 16),
                                   ct.addressof(rect), 2, 1500, ct.byref(result))
            size = (dpi // 6,) * 2
            until(lambda: tray._icon_size == size, f"tray image at {dpi} dpi")
            assert api.bitmap(tray._icon).size == size
        assert native_notify(native_tray._NIM_DELETE, ct.byref(tray._icon_data(tray._window)))
        before = len(calls)
        assert tray._windows.post_message(tray._window, tray._taskbar_created, 0, 0)
        until(lambda: (native_tray._NIM_SETVERSION, True, None) in calls[before:], "hidden TaskbarCreated recovery")
        assert (native_tray._NIM_ADD, True, (32, 32)) in calls[before:]
    finally:
        tray.close()
    assert (native_tray._NIM_DELETE, True, None) in calls and not tray._thread.is_alive()
    print(f"Hidden Explorer icon accepted at host size {first_size}; DPI notifications exercised with five injected values; TaskbarCreated restored 32 px.", flush=True)


def verify_window(window, _base):
    api = WindowsIcons()
    dpi = api.dpi_for_window(window)
    assert dpi > 0
    sizes = [(api.metric(x, dpi), api.metric(y, dpi)) for x, y in ((49, 50), (11, 12))]
    expected = [api.from_file(windows_icon_path(), *size).tobytes() for size in sizes]

    observed = {}

    def icon_matches():
        identity = app_id(window)
        actual = [api.from_window(window, kind, dpi) for kind in (0, 1)]
        pixels_match = [bool(image and image.size == size and image.tobytes() == canonical)
                        for image, size, canonical in zip(actual, sizes, expected, strict=True)]
        observed.update(identity=identity, icons=[image.size if image else None for image in actual],
                        pixels_match=pixels_match, dpi=dpi)
        return identity == APP_ID and all(pixels_match)

    # Chromium may load its favicon after the HWND first appears. Check that
    # the canonical icons settle and survive a complete steady-state check.
    deadline = time.monotonic() + 12
    stable_since = None
    while time.monotonic() < deadline:
        now = time.monotonic()
        if icon_matches():
            stable_since = stable_since or now
            if now - stable_since >= 3.25:
                break
        else:
            stable_since = None
        time.sleep(.125)
    else:
        raise AssertionError(f"Chromium HWND icons did not settle: {observed}")
    print(f"Private Chromium workbench WM_GETICON at {dpi} DPI passed ({sizes}); AUMID {APP_ID}.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ico", type=Path, default=windows_icon_path())
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--evidence", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--private-child", type=Path, help=argparse.SUPPRESS)
    mode.add_argument("--resources-only", action="store_true")
    mode.add_argument("--shell-only", action="store_true")
    args = parser.parse_args()
    if args.executable:
        args.executable = args.executable.resolve(strict=True)
    if args.private_child:
        run_private(args.private_child, args.evidence, args.executable, inspect_main_window=verify_window)
    elif args.shell_only:
        verify_tray(args.ico.resolve(strict=True))
    else:
        verify_resources(args.ico.resolve(strict=True), args.executable, args.evidence)
        if not args.resources_only:
            work = Path(tempfile.mkdtemp(prefix="gaojixu-tray-smoke-icons-")).resolve()
            try:
                launch_private(work, args.evidence, args.executable, script=Path(__file__).resolve())
            finally:
                cleanup(work)


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Run this smoke with Python assertions enabled.")
    main()

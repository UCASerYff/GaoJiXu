import ctypes
import threading
from types import SimpleNamespace
from unittest.mock import Mock

from gaojixu import native_tray as native


def test_tray_reattaches_the_same_icon_after_taskbar_broadcast(monkeypatch):
    win = Mock()
    win.register_message.return_value = 0xC123
    commands = []

    def notify(command, address):
        data = ctypes.cast(address, ctypes.POINTER(native._NotifyIconData)).contents
        commands.append((command, data.window, data.identifier, data.version))
        # Explorer has kept the icon (for example, after a DPI-change broadcast).
        return command != native._NIM_ADD

    win.notify.side_effect = notify
    monkeypatch.setattr(native, "_Windows", lambda: win)
    tray = native.TrayIcon(Mock(), Mock(), None, None, None, None, None)
    tray._window_message(24, tray._taskbar_created, 0, 0)

    assert commands == [
        (native._NIM_ADD, 24, 1, 0),
        (native._NIM_MODIFY, 24, 1, 0),
        (native._NIM_SETVERSION, 24, 1, 4),
    ]
    assert tray._registered and tray._modern_events


def test_tray_left_mouse_and_keyboard_activation_dispatch(monkeypatch):
    monkeypatch.setattr(native, "_Windows", Mock())
    clock = iter((1.0, 1.01, 2.0))
    monkeypatch.setattr(native, "time", SimpleNamespace(monotonic=lambda: next(clock)))
    open_window = Mock()
    tray = native.TrayIcon(open_window, Mock(), None, None, None, None, None)
    tray._window_message(24, native._WM_TRAY, 0, native._WM_LBUTTONUP)
    tray._window_message(24, native._WM_TRAY, 0, 0x10000 | native._NIN_SELECT)
    assert open_window.call_count == 1
    tray._window_message(24, native._WM_TRAY, 0, 0x10000 | native._NIN_KEYSELECT)
    assert open_window.call_count == 2


def test_tray_right_click_uses_only_one_popup_even_with_both_shell_events(monkeypatch):
    win = Mock()
    win.track_menu.return_value = 0
    monkeypatch.setattr(native, "_Windows", lambda: win)
    clock = iter((1.0, 1.5, 1.51))
    monkeypatch.setattr(native, "time", SimpleNamespace(monotonic=lambda: next(clock)))
    tray = native.TrayIcon(Mock(), Mock(), None, None, None, None, None)
    tray._modern_events = True
    tray._window_message(24, native._WM_TRAY, 0, 0x10000 | native._WM_RBUTTONUP)
    tray._window_message(24, native._WM_TRAY, 0, 0x10000 | native._WM_CONTEXTMENU)
    win.track_menu.assert_called_once()


def test_tray_closes_its_menu_and_clears_icon_from_own_thread(monkeypatch):
    win = Mock()
    monkeypatch.setattr(native, "_Windows", lambda: win)
    exit_app = Mock()
    tray = native.TrayIcon(Mock(), exit_app, None, None, None, None, None, language=lambda: "en")
    tray._thread = threading.current_thread()
    tray._window = 24
    tray._registered = True

    def select_during_close(*_):
        tray.close()
        win.post_message.assert_called_once_with(24, native._WM_CLOSE, 0, 0)
        tray._window_message(24, native._WM_CLOSE, 0, 0)
        win.end_menu.assert_called_once()
        win.destroy_window.assert_not_called()
        return 2

    win.track_menu.side_effect = select_during_close
    tray._show_menu(24)

    assert [call.args[-1] for call in win.add_menu_item.call_args_list] == ["Open Gao Savings", "Exit"]
    win.destroy_window.assert_called_once_with(24)
    exit_app.assert_not_called()
    tray._window_message(24, native._WM_DESTROY, 0, 0)
    assert win.notify.call_args.args[0] == native._NIM_DELETE
    assert not tray._registered and tray._window is None

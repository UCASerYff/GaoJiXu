import ctypes
import threading
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from gaojixu import native_tray as native


def test_tray_reattaches_the_same_icon_after_taskbar_broadcast(monkeypatch):
    win = Mock()
    win.tray_icon_size.return_value = (16, 16)
    win.load_icon.return_value = 90
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


@pytest.mark.parametrize(("dpi", "pixels"), [(96, 16), (120, 20), (144, 24), (168, 28), (192, 32)])
def test_tray_uses_taskbar_dpi_for_both_small_icon_metrics(dpi, pixels):
    win = SimpleNamespace(
        metrics_for_dpi=Mock(return_value=pixels), dpi_for_window=Mock(return_value=dpi),
        find_window=Mock(return_value=42), system_dpi=Mock(return_value=96),
    )
    assert native._Windows.tray_icon_size(win, 24, 96) == (pixels, pixels)
    win.find_window.assert_called_once_with("Shell_TrayWnd", None)
    win.dpi_for_window.assert_called_once_with(42)
    assert [call.args for call in win.metrics_for_dpi.call_args_list] == [
        (native._SM_CXSMICON, dpi), (native._SM_CYSMICON, dpi),
    ]


def test_tray_uses_dpi_message_when_explorer_window_is_unavailable():
    win = SimpleNamespace(
        metrics_for_dpi=Mock(return_value=28), dpi_for_window=Mock(return_value=96),
        find_window=Mock(return_value=None), system_dpi=Mock(return_value=96),
    )
    assert native._Windows.tray_icon_size(win, 24, 168) == (28, 28)
    win.dpi_for_window.assert_not_called()
    assert all(call.args[1] == 168 for call in win.metrics_for_dpi.call_args_list)


def test_tray_refreshes_native_icon_without_replacing_identity(monkeypatch, tmp_path):
    win = Mock()
    win.register_message.return_value = 0xC123
    win.register_class.return_value = 1
    win.module_handle.return_value = 84
    win.create_window.return_value = 24
    win.tray_icon_size.side_effect = [(16, 16), (24, 24), (24, 24), (32, 32)]
    win.load_image.side_effect = [100, 101, 102]
    events = []

    def notify(command, address):
        data = ctypes.cast(address, ctypes.POINTER(native._NotifyIconData)).contents
        events.append((command, data.window, data.identifier, data.icon))
        return True

    win.notify.side_effect = notify
    win.destroy_icon.side_effect = lambda handle: events.append(("destroy", handle))
    monkeypatch.setattr(native, "_Windows", lambda: win)
    icon = tmp_path / "GaoJiXu.ico"
    tray = native.TrayIcon(Mock(), Mock(), None, None, None, None, None, icon_path=icon)
    win.destroy_window.side_effect = lambda window: tray._window_message(window, native._WM_DESTROY, 0, 0)

    def dispatch_dpi_and_taskbar_events(*_):
        tray._window_message(24, native._WM_DPICHANGED, (144 << 16) | 144, 0)
        tray._window_message(24, native._WM_DISPLAYCHANGE, 0, 0)
        tray._window_message(24, tray._taskbar_created, 0, 0)
        return 0

    win.get_message.side_effect = dispatch_dpi_and_taskbar_events
    tray._run()

    assert [call.args[3:5] for call in win.load_image.call_args_list] == [(16, 16), (24, 24), (32, 32)]
    win.set_thread_dpi_context.assert_called_once_with(native._PER_MONITOR_AWARE_V2)
    assert win.tray_icon_size.call_args_list[1].args == (24, 144)
    assert events == [
        (native._NIM_ADD, 24, 1, 100), (native._NIM_SETVERSION, 24, 1, None),
        (native._NIM_MODIFY, 24, 1, 101), ("destroy", 100),
        (native._NIM_ADD, 24, 1, 102), (native._NIM_SETVERSION, 24, 1, None), ("destroy", 101),
        (native._NIM_DELETE, 24, 1, None), ("destroy", 102),
    ]


def test_tray_retries_icon_registration_after_shell_failure(monkeypatch, tmp_path):
    win = Mock()
    win.tray_icon_size.side_effect = [(16, 16), (20, 20), (20, 20)]
    win.load_image.side_effect = [100, 101, 102]
    win.notify.side_effect = [True, True, False, False, False, True, True]
    monkeypatch.setattr(native, "_Windows", lambda: win)
    tray = native.TrayIcon(Mock(), Mock(), None, None, None, None, None, icon_path=tmp_path / "GaoJiXu.ico")

    tray._attach(24)
    tray._window_message(24, native._WM_DPICHANGED, 120, 0)
    assert tray._icon == 100 and not tray._registered
    win.destroy_icon.assert_called_once_with(101)

    tray._window_message(24, native._WM_TIMER, native._TRAY_TIMER, 0)
    assert tray._icon == 102 and tray._registered
    assert [call.args[0] for call in win.destroy_icon.call_args_list] == [101, 100]


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

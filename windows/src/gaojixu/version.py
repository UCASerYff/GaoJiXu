"""营销版本与当前 Mac 版 Info.plist 的 CFBundleShortVersionString 对齐。

Windows 构建号独立递增。
"""

MARKETING_VERSION = "4.06"
WINDOWS_BUILD = "2"
VERSION_LABEL = f"{MARKETING_VERSION}+{WINDOWS_BUILD}"
SCHEMA_VERSION = 24
WIDGET_SCHEMA_VERSION = 2
APP_NAME = "搞积蓄"
BUNDLE_ID = "com.gaojixu.savings"
EXECUTABLE = "GaoJiXu"

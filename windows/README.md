# 搞积蓄 Windows 版

面向 Windows 10/11 x64 的独立应用版本 **4.06**。Windows 构建号为 **2**，命令行显示 `4.06+2`。

主窗口与五个小组件优先使用本机 Microsoft Edge 或 Chromium 的应用模式。找不到可用的应用模式入口时，在系统默认浏览器中打开。服务只监听 `127.0.0.1`。

## 安装

双击 `GaoJiXu-Windows-4.06-x64.msi`，完成后从开始菜单打开「搞积蓄」。开始菜单还提供每日收支与积蓄、净资产、固定支出、权益打卡和勇者冒险小组件的独立入口。安装程序同时为当前 Windows 用户注册 `gaojixu://`。升级或卸载前可在应用中选择「退出」。

安装程序将应用装在 `%LOCALAPPDATA%\GaoJiXu\`。通过 Windows「设置 → 应用」卸载，资料保留在原目录。此前的便携版与安装版使用相同的资料目录。

下载后可以将计算结果与随包提供的 `.msi.sha256` 文件比对。

```powershell
Get-FileHash -Algorithm SHA256 .\GaoJiXu-Windows-4.06-x64.msi
```

当前安装包无 Authenticode 签名。隔离安装已在 Windows 11 x64 上验证。Windows 10 x64 未使用独立虚拟机验证。

## 构建

在 Windows x64 上使用 CPython 3.11 或 3.12 x64。

```powershell
cd windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

构建脚本将开发依赖下载到 `windows/build/`，运行回归测试，通过 PyInstaller 打包程序和应用资源，再用 WiX 生成 MSI。可交付的文件位于 `windows/dist/`。

- `GaoJiXu-Windows-4.06-x64.msi`
- `GaoJiXu-Windows-4.06-x64.msi.sha256`

GitHub Actions 在 Windows 运行器上构建并静默安装 MSI，验证两个 x64 程序、应用资源、适用的已有 Windows 资料、流水、月供数据库、财务快照及卸载保留资料。安装包和校验文件作为 `GaoJiXu-Windows-4.06-x64` 构建产物上传。

只跑源码测试可使用以下命令。

```powershell
cd windows
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

在 Linux 或 macOS 上也可以跑同一套测试。开发时启动界面：

```sh
cd windows
PYTHONPATH=src python3 launch.py --data-dir /tmp/gaojixu-dev --no-browser --port 8765
```

然后用浏览器打开 `http://127.0.0.1:8765/`。

## 资料和命令行

命令行程序 `GaoJiXu-cli.exe` 随 MSI 安装，可用于读取资料状态和写出小组件快照。关闭界面后冒险仍可继续结算。应用中的「退出」会停止服务。

资料目录：

`%APPDATA%\GaoSeries\Savings\`

也可以用环境变量 `GAOJIXU_DATA_DIR` 或参数 `--data-dir` 改到别的目录。第一次打开空目录时需要本人确认「创建我的资料库」。程序不会在资料缺失、损坏、目录里已有其他文件，或版本高于 schema 24 时用空库覆盖原文件，也不会写自动备份。

| 参数 | 作用 |
| --- | --- |
| `--data-dir` | 资料目录。不设时使用 `%APPDATA%\GaoSeries\Savings\` |
| `--serve` | 启动只监听 `127.0.0.1` 的本地服务。无其他命令时也会启动服务 |
| `--no-browser` | 不调用系统浏览器 |
| `--port` | 服务端口。`0` 表示由系统分配 |
| `--create-empty` | 在空目录明确新建资料后退出；与 `--serve` 同时使用时新建后继续服务 |
| `--inspect` | 只读打印账户、流水、目标和等级条数，不打印备注 |
| `--widget-snapshot` | 写出 schema 2 的 `gaojixu-widget.json` |
| `--version` | 打印 `4.06+2` |
| `--widget TYPE` | 打开每日收支与积蓄 `calendar`、净资产 `net-worth`、固定支出 `expenses`、权益打卡 `benefits` 或勇者冒险 `adventure` 窗口 |

## 数据

| 位置 | 内容 |
| --- | --- |
| `library.json` | schema 24：账户、流水、预算、周期规则、攒钱目标、积蓄记录、固定收入、冒险进度。日期是 Mac 的 Cocoa 秒（自 2001-01-01 UTC 起）。未知字段保留 |
| `settings.json` | 外观、语言、背景色、默认币种、预算结转 |
| `gaojixu-widget.json` | schema 2 财务快照，另有一份在 `IsolatedWidgetGroup/`。高于 schema 2 的已有快照不覆盖 |
| `monthly-account-bindings.json` | 固定支出订阅与流水账户的绑定 |
| `IntegratedFinance/Monthly/monthly.sqlite` | 固定支出与权益。表 `state` 只有一行 id=1 的 JSON，和 Mac 相同 |
| `IntegratedFinance/Monthly/authority.json` | 模式 `new` 或已核验的 `migrated` 才允许写入 |

Mac 上账本位于 `~/Library/Application Support/GaoSeries/Savings/`，小组件和月供位于 App Group `5G96498KGJ.com.gaojixu.savings`。Windows 不会读取那两个 macOS 路径，也不会注册 App Group。可以把 `library.json` 放到 Windows 资料目录；月供库放到 `IntegratedFinance/Monthly/`。两边不要同时写入同一份文件。

打开已经是 schema 24、且没有到期周期记账的库时，不改写 `library.json`。低于 24 的库会按 Mac 的迁移链补字段、补迁移事件并升到 24，原文件先读成功才写。

财务修订号是本程序自己的 SHA-256，算法与 Mac `JSONEncoder` 的字节不完全相同。只有本程序认定的财务内容变化时才推进 `financialUpdatedAt`。游戏结算不推进它。Mac 下次打开会按自己的算法重算修订号。

本仓库的账本金额在 `library.json` 里。Mac 源码把凭据放在钥匙串，不写进这个文件。Windows 版不另造凭据库，也不读取 macOS 钥匙串。

## Windows 功能

| 工作台 | 功能 |
| --- | --- |
| 总览 | 净资产、本月收支和预算、最近流水、当前目标和可展开的月历 |
| 收支 | 流水编辑、搜索和筛选、账户、信用账户和余额调整、同币种和跨币种转账、预算、周期记账、CSV、报表 |
| 固定收支 | 固定收入确认到账、订阅、待核实账期、支付历史和账户绑定、权益领取、到期事项、复盘及对账 |
| 攒钱 | 目标管理、积蓄明细、存取对应流水、统计和冒险奖励 |
| 冒险 | 像素战斗与营地、自动结算、装备、技能、宠物、祈愿、图鉴和成就 |
| 设置 | 模块设置、外观与数据页。可在文件资源管理器打开现用资料和小组件快照目录 |
| Windows 集成 | 系统托盘、固定支出提醒、`gaojixu://` 跳转、可单独打开的每日收支与积蓄、净资产、固定支出、权益打卡和勇者冒险小组件 |

## 已知限制

- Windows 界面由浏览器引擎绘制。冒险使用项目像素素材、网页战斗与营地场景，并以 2.5D 观察场景对应 macOS 的 SceneKit 3D。SpriteKit 的动画、SceneKit 的视角交互及部分界面细节仍有差异。冒险和部分固定收支文案仍为中文。
- 小组件通过独立窗口打开，支持开始菜单入口。Windows 版没有 WidgetKit、Windows 小组件面板集成、macOS 菜单栏或 Dock。
- 固定支出提醒按业务时区结算，应用运行时通过 Windows 托盘的 `Shell_NotifyIconW` 提交通知。已验证托盘注册和定时回调，未触发桌面横幅验证。实际呈现取决于 Windows 通知设置。
- macOS 的月供跨应用通知、离线迁移工具和钥匙串属于 Mac 环境。Windows 可读取相应格式的资料文件。已有月供库缺少写入授权或核验标记时会以只读状态打开。
- 同一资料目录应只由一个应用实例写入。
- 财务修订号的字节算法与 Mac 不同。两边先后打开时，Mac 会按自己的算法写回修订号；`financialUpdatedAt` 只在财务内容变化时前进。

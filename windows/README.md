# 搞积蓄 Windows 版

面向 Windows 10/11 x64 的独立版本。营销版本与当前 Mac 版同为 **4.06**（`Info.plist` 的短版本），Windows 构建号为 **1**。打印 `4.06+1`。Mac 版的 Swift 源码、签名、Bundle ID 和 `Info.plist` 版本号都不改。

界面在本机浏览器中打开。服务只监听 `127.0.0.1`。

## 选型

使用 **Python 3.12 标准库** 实现业务，界面是随程序打包的本地网页，安装包用 **PyInstaller** 在 `windows-latest` 上打成单个 exe。这与搞研究、搞节奏 Windows 版的做法相同。

这样选，是因为业务和测试可以在 Linux 上完成，GitHub Actions 的 Windows runner 能直接构建并产出可执行文件。没有做成 WinUI 或 Electron。勇者冒险的贴图场景依赖 SpriteKit，浏览器界面先把已经对齐的账本和数值战斗跑起来。

## 构建

在 Windows 10/11 x64 上安装 Python 3.12，然后：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会安装开发依赖、运行单元测试，并在 `windows/dist/` 生成：

- `GaoJiXu.exe`：打开界面的窗口程序
- `GaoJiXu-cli.exe`：命令行，用于检查条数和写出小组件快照

GitHub Actions 工作流 `.github/workflows/windows.yml` 在 `windows-latest` 上执行同一套步骤。打包之后会用临时目录后台启动 `GaoJiXu.exe`（`--serve --no-browser --port --data-dir`，不打开浏览器），轮询到本机 HTTP 200，再通过该服务新建资料库、写入一笔流水并读回 `library.json`，然后结束进程。两个 exe 作为 artifact `GaoJiXu-Windows-4.06` 上传。这个工作流不会创建 GitHub Release，也不会安装到运行器之外的电脑。

只跑测试：

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

## 运行

不需要安装程序。把 `GaoJiXu.exe` 放到任意文件夹，双击运行。程序会打开系统浏览器。关闭浏览器标签不会结束进程；冒险仍按每秒结算。页面右上角的「退出」会停止结算并退出。

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
| `--version` | 打印 `4.06+1` |

## 数据

| 位置 | 内容 |
| --- | --- |
| `library.json` | schema 24：账户、流水、预算、周期规则、攒钱目标、积蓄记录、固定收入、冒险进度。日期是 Mac 的 Cocoa 秒（自 2001-01-01 UTC 起）。未知字段保留 |
| `settings.json` | 外观、语言标记、默认币种。Mac 上这些值在 UserDefaults，不在 `library.json` |
| `gaojixu-widget.json` | schema 2 财务快照，另有一份在 `IsolatedWidgetGroup/`。高于 schema 2 的已有快照不覆盖 |
| `monthly-account-bindings.json` | 预留给月供账户绑定；本版确认支付时直接选择账户 |
| `IntegratedFinance/Monthly/monthly.sqlite` | 固定支出与权益。表 `state` 只有一行 id=1 的 JSON，和 Mac 相同 |
| `IntegratedFinance/Monthly/authority.json` | 模式 `new` 或已核验的 `migrated` 才允许写入 |

Mac 上账本位于 `~/Library/Application Support/GaoSeries/Savings/`，小组件和月供位于 App Group `5G96498KGJ.com.gaojixu.savings`。Windows 不会读取那两个 macOS 路径，也不会注册 App Group。可以把 `library.json` 放到 Windows 资料目录；月供库放到 `IntegratedFinance/Monthly/`。两边不要同时写入同一份文件。

打开已经是 schema 24、且没有到期周期记账的库时，不改写 `library.json`。低于 24 的库会按 Mac 的迁移链补字段、补迁移事件并升到 24，原文件先读成功才写。

财务修订号是本程序自己的 SHA-256，算法与 Mac `JSONEncoder` 的字节不完全相同。只有本程序认定的财务内容变化时才推进 `financialUpdatedAt`。游戏结算不推进它。Mac 下次打开会按自己的算法重算修订号。

本仓库的账本金额在 `library.json` 里。Mac 源码把凭据放在钥匙串，不写进这个文件。Windows 版不另造凭据库，也不读取 macOS 钥匙串。

## 功能对齐

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 总览、收支、攒钱、冒险 | 已实现 | 浏览器四个工作台。收支里包含账户、流水、预算、周期记账、固定收入、固定支出和权益 |
| schema 24 `library.json` | 已实现 | 未知字段保留。损坏、高于 24、目录非空却没有主库时只读，不覆盖 |
| 金额 2 位小数、半进远离零 | 已实现 | 与 `MoneyValue` 一致。日元、韩元的固定收入仍按 0 位小数校验 |
| 账户余额、信用账户、转账、余额调整 | 已实现 | 有流水的账户改为归档。余额调整不进月度收支。跨币种转账要填写转入金额 |
| 预算、月历、净资产 | 已实现 | 总览按默认币种汇总。信用账户以负债计入净资产 |
| 周期记账 | 已实现 | 日、周、月、年。月和年保持锚定日，小月夹到月末后下一期恢复。单次最多 366 期，重复执行不双记 |
| 攒钱目标与积蓄记录 | 已实现 | 存入和取出都写成同币种转账。每 1 个货币单位 1 张星券，完成目标再加 100。删除记录不收回已发星券 |
| 固定收入 | 已实现 | 计划只生成预测。确认到账才写收入，同一计划同一月份只确认一次。流水号 `fixed-income\|计划\|月份` |
| 固定支出、支付、权益打卡 | 已实现 | 沿用 `monthly.sqlite`。确认支付可写入 `auto-monthly\|订阅\|日期` 支出。每日、每周打卡只记一次。没有库时必须本人确认才创建 |
| 流水 CSV | 已实现 | UTF-8 BOM、CRLF，列与 Mac 导出一致。导入会跳过同一分钟、类型、账户、金额和备注都相同的行 |
| 冒险属性、伤害、过关奖励 | 已实现 | 等级、装备强化、技能效果、宠物星级和词条都进入同一套公式。击杀掉落、金币、经验和悟性沿用 Mac 数值 |
| 祈愿保底、强化、参悟、宠物蛋 | 已实现 | 10/30/150/500/2000 抽保底。装备池和技能池分开计。500 金币换 1 星券。宠物蛋 10000 金币 |
| 关窗口后继续战斗 | 已实现 | 关掉浏览器标签时进程仍每秒结算。「退出」停止。Windows 没有菜单栏和 Dock |
| 不制作备份、不提供恢复 | 已实现 | 临时文件原子替换，不留副本 |
| 外观 | 部分 | 可切换浅色和深色。页面正文以中文为主，设置里的语言标记不会换成 Mac 的全量英文文案 |
| WidgetKit | 部分 | 写 schema 2 的 `gaojixu-widget.json`。不能注册 Mac 小组件，也不读 App Group |
| 订阅提醒 | 部分 | 提醒天数可以留在月供偏好里。没有 Windows 通知横幅 |
| 成就墙 | 部分 | 成就由进度推导，不另存档。Windows 不单列成就页，进度仍在 `adventure` 里 |
| `gaojixu://` | 不支持 | 没有注册 Windows URL 协议 |
| 菜单栏、⌘,、⌘Q | 不支持 | 没有对应的 macOS 生命周期 |
| SpriteKit 冒险场景和贴图 | 不支持 | `GameWorld/` 与像素图没有打包。战斗是数值和按钮 |
| 与正在运行的 macOS 搞月供即时同步 | 不支持 | 没有 DistributedNotificationCenter |
| 离线迁移 CLI `IntegrateFinance` | 不支持 | 那是 Mac 上的一次性迁移工具。已有的 `monthly.sqlite` 可以直接读 |
| 钥匙串 | 不适用 | 凭据不在 `library.json`。Windows 不虚构凭据库 |
| 已迁移月供的 App Group 凭据 | 限制 | `authority.json` 为 `migrated` 且提交标记仍指向 `app-group:` 时，找不到本机标记就只读，避免改坏原库 |

## 已知限制

- 窗口程序没有自己的原生窗口。关闭浏览器标签不会退出进程，需要点「退出」。
- 冒险没有地图、精灵和三维场景。数值公式与 Mac 当前源码对齐，随机掉落的序列不会与某一次 Mac 运行相同。
- 同一份资料不要同时被 Mac 版和 Windows 版打开写入。
- 财务修订号的字节算法与 Mac 不同。两边先后打开时，Mac 会按自己的算法写回修订号；`financialUpdatedAt` 只在财务内容变化时前进。
- 没有 `authority.json` 或迁移标记对不上时，不会为了“能写”而替换已有的 `monthly.sqlite`。

# 灵梦值守 Reimu Watch

灵梦值守是以《东方 Project》博丽灵梦为形象、只提醒 Claude CLI 的 Windows 桌宠。它通过 Claude Code 官方 Hooks 接收事件，不读取其他应用通知，也不需要 Windows 全局通知访问权限；提醒使用接近 Codex 的深色气泡显示在桌宠旁边。

桌宠形象来源：[Reimu - codexpet.top](https://codexpet.top/pets/reimu--lingxiaotian)

## 提醒类型

- Claude 完成命令：显示“Claude 已完成命令”。
- Claude 请求权限：显示“Claude 需要权限”，提醒用户回到终端确认。
- Claude 返回 429、rate limit 或 Too Many Requests：显示“Claude 发生 429 错误”，展示 Claude 记录的错误信息，并持续保留到切回 Claude 或双击桌宠。
- Claude 返回其他 API/网络/权限错误：显示“Claude 发生错误”，展示实际错误信息，并持续保留到切回 Claude 或双击桌宠。

只有 Claude/Windows Terminal 不在桌面最前台时才弹出气泡；Claude 正在最前台时不打扰你。桌宠本身不会抢焦点，但提醒气泡会保持在其他窗口上方。

## 运行

双击 `run.cmd`，或在 PowerShell 中运行：

```powershell
.\build.ps1
.\build\ReimuWatch.exe
```

首次运行会自动在 `%USERPROFILE%\.claude\settings.json` 中安装 `UserPromptSubmit`、`Stop`、`PermissionRequest` 和 `Notification` Hooks，并先备份为 `settings.json.notify-pet.bak`。托盘菜单提供 Claude 通知测试、重新安装 Hooks、开机启动和退出。Hook 事件通过 `%LOCALAPPDATA%\NotifyPet\events` 中的短期队列文件交给灵梦值守，读取后立即删除，不发送到网络。

空闲时不显示气泡；双击桌宠头部会临时显示“等待 Claude 命令”10 秒，没有新状态时自动隐藏。Claude 开始处理命令时，气泡会重新出现，第二行“正在思考”从左到右循环发亮，同时桌宠播放向左奔跑动画。权限提醒使用下跪动作，并一直保留到用户继续操作 Claude 或双击桌宠。所有错误使用思考动作；错误和完成提醒都会一直保留到切回 Claude CLI 或双击桌宠。只有头部可以拖动，桌宠身体、气泡和窗口中的其他透明区域都会让鼠标穿透到后方应用。拖动松开后会自动保存位置。

## 自定义形象

程序优先加载 `assets/custom-spritesheet.png`。图集要求为 `1536x1872` PNG、8 列 x 9 行、每格 `192x208`；缺少或尺寸不符时会回退到内置矢量角色。

## 构建与验证

```powershell
.\build.ps1
.\test.ps1
```

项目只使用 Windows PowerShell、.NET Framework/WPF 和 WinRT，不需要 npm、NuGet 或额外 SDK。

## 文件说明

- `src/NotifyPet.cs`：桌宠窗口、Claude 事件分类、前台窗口判断和托盘菜单
- `src/ClaudeHook.ps1`：接收 Claude Hooks，识别完成、权限和 Claude/API 错误
- `src/InstallClaudeHooks.ps1`：合并安装 Claude Hooks，保留用户现有设置
- `src/NotificationBridge.ps1`：把本地 Hook 事件队列交给桌宠
- `build.ps1`：使用系统 C# 编译器构建
- `test.ps1`：构建、Hook 安装和 Claude 错误实时监控冒烟测试

Hooks 在新启动的 Claude 会话中生效；已经运行中的 Claude CLI 需要退出后重新打开。使用 `--safe-mode` 或 `--bare` 启动 Claude 会禁用 Hooks，此时灵梦值守不会收到提醒。

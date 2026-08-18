using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;
using IOPath = System.IO.Path;

[assembly: AssemblyTitle("灵梦值守")]
[assembly: AssemblyProduct("Reimu Watch")]
[assembly: AssemblyDescription("以博丽灵梦为形象的 Claude CLI 状态提醒桌宠")]
[assembly: AssemblyCompany("Reimu Watch")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace NotifyPet
{
    internal static class Program
    {
        private static Mutex instanceMutex;
        private static Forms.NotifyIcon trayIcon;
        private static PetWindow petWindow;
        private static ClaudeNotificationService notificationService;
        private static SettingsStore settingsStore;
        private static AppSettings settings;
        private static string logPath;

        [STAThread]
        public static void Main()
        {
            logPath = IOPath.Combine(
                IOPath.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
                "ReimuWatch.log");
            Log("process started");
            AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs args)
            {
                Log("fatal: " + args.ExceptionObject);
            };

            bool isFirstInstance;
            instanceMutex = new Mutex(true, "Local\\NotifyPet.SingleInstance", out isFirstInstance);
            if (!isFirstInstance)
            {
                Log("another instance is already running");
                return;
            }

            Log("loading settings");
            settingsStore = new SettingsStore();
            settings = settingsStore.Load();
            settingsStore.Save(settings);
            AutoStartManager.MigrateLegacyEntry();
            Log("settings ready");

            var app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            app.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs args)
            {
                if (petWindow != null)
                {
                    petWindow.ShowSystemMessage("灵梦值守遇到问题", FriendlyError(args.Exception));
                }
                args.Handled = true;
            };

            petWindow = new PetWindow(settings, SaveSettings);
            Log("window constructed");
            notificationService = new ClaudeNotificationService(
                settings,
                delegate(PetNotification notification)
                {
                    Log("Claude notification received: " + notification.Kind);
                    petWindow.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        if (ClaudeWindowMonitor.IsClaudeForeground())
                        {
                            Log("Claude notification suppressed because Claude is foreground: " + notification.Kind);
                            petWindow.SetTaskRunning(false);
                            return;
                        }
                        petWindow.EnqueueNotification(notification);
                    }));
                },
                delegate(string status)
                {
                    Log("listener status: " + status);
                    petWindow.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        petWindow.SetListenerStatus(status);
                        UpdateTrayText(status);
                    }));
                },
                delegate(bool working)
                {
                    Log("Claude activity: " + (working ? "working" : "idle"));
                    petWindow.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        petWindow.SetTaskRunning(working);
                    }));
                });
            BuildTrayIcon(app);
            Log("tray icon ready");
            petWindow.Closed += delegate { ExitApplication(app); };
            petWindow.Loaded += async delegate
            {
                await notificationService.StartAsync(true);
            };

            petWindow.Show();
            Log("window shown; entering message loop");
            app.Run();
            Log("message loop exited");
        }

        private static void BuildTrayIcon(Application app)
        {
            trayIcon = new Forms.NotifyIcon();
            trayIcon.Icon = CreateTrayIcon();
            trayIcon.Text = "灵梦值守 - 正在启动";
            trayIcon.Visible = true;

            var menu = new Forms.ContextMenuStrip();

            var statusItem = new Forms.ToolStripMenuItem("Claude 状态：正在检查");
            statusItem.Enabled = false;
            statusItem.Name = "status";
            menu.Items.Add(statusItem);
            menu.Items.Add(new Forms.ToolStripSeparator());

            var testItem = new Forms.ToolStripMenuItem("显示 Claude 测试通知");
            testItem.Click += delegate
            {
                petWindow.Dispatcher.BeginInvoke(new Action(delegate
                {
                    petWindow.EnqueueNotification(new PetNotification
                    {
                        Source = "Claude Code",
                        Title = "Claude 已完成命令",
                        Body = "这是一条测试提醒。真实 Claude CLI 通知会显示在这里。",
                        Kind = ClaudeNotificationKind.Completed,
                        CreatedAt = DateTime.Now
                    });
                }));
            };
            menu.Items.Add(testItem);

            var hooksItem = new Forms.ToolStripMenuItem("重新安装 Claude Hooks");
            hooksItem.Click += async delegate
            {
                if (!hooksItem.Enabled)
                {
                    return;
                }

                hooksItem.Enabled = false;
                hooksItem.Text = "正在安装 Claude Hooks...";
                var installed = await notificationService.ReinstallHooksAsync();
                hooksItem.Text = installed
                    ? "Claude Hooks 已安装"
                    : "Claude Hooks 安装失败";
                petWindow.Dispatcher.Invoke(new Action(delegate
                {
                    petWindow.SetTaskRunning(false);
                    petWindow.ShowSystemMessage(
                        installed ? "Claude Hooks 安装完成" : "Claude Hooks 安装失败",
                        installed
                            ? "新任务已经可以监听；已打开的 Claude CLI 建议退出后重新打开。"
                            : "请查看状态气泡中的错误信息后再次安装。");
                }));
                await Task.Delay(2500);
                hooksItem.Text = "重新安装 Claude Hooks";
                hooksItem.Enabled = true;
            };
            menu.Items.Add(hooksItem);

            var startupItem = new Forms.ToolStripMenuItem("开机启动");
            startupItem.Checked = AutoStartManager.IsEnabled();
            startupItem.CheckOnClick = true;
            startupItem.CheckedChanged += delegate
            {
                try
                {
                    AutoStartManager.SetEnabled(startupItem.Checked);
                    settings.StartWithWindows = startupItem.Checked;
                    SaveSettings();
                }
                catch (Exception ex)
                {
                    startupItem.Checked = AutoStartManager.IsEnabled();
                    petWindow.Dispatcher.BeginInvoke(new Action(delegate
                    {
                        petWindow.ShowSystemMessage("开机启动设置失败", FriendlyError(ex));
                    }));
                }
            };
            menu.Items.Add(startupItem);

            menu.Items.Add(new Forms.ToolStripSeparator());
            var exitItem = new Forms.ToolStripMenuItem("退出灵梦值守");
            exitItem.Click += delegate { ExitApplication(app); };
            menu.Items.Add(exitItem);

            trayIcon.ContextMenuStrip = menu;
            trayIcon.DoubleClick += delegate
            {
                petWindow.Dispatcher.BeginInvoke(new Action(delegate
                {
                    petWindow.ShowSystemMessage("灵梦值守在这里", petWindow.ListenerStatus);
                    petWindow.Activate();
                }));
            };
        }

        private static Drawing.Icon CreateTrayIcon()
        {
            try
            {
                using (var associated = Drawing.Icon.ExtractAssociatedIcon(
                    System.Reflection.Assembly.GetExecutingAssembly().Location))
                {
                    if (associated != null)
                    {
                        return new Drawing.Icon(associated, new Drawing.Size(32, 32));
                    }
                }
            }
            catch
            {
            }

            var bitmap = new Drawing.Bitmap(32, 32);
            using (var graphics = Drawing.Graphics.FromImage(bitmap))
            using (var red = new Drawing.SolidBrush(Drawing.Color.FromArgb(215, 48, 39)))
            using (var dark = new Drawing.SolidBrush(Drawing.Color.FromArgb(45, 38, 40)))
            using (var white = new Drawing.SolidBrush(Drawing.Color.White))
            {
                graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
                graphics.FillEllipse(dark, 5, 7, 22, 22);
                graphics.FillPolygon(red, new[]
                {
                    new Drawing.Point(2, 3),
                    new Drawing.Point(14, 7),
                    new Drawing.Point(8, 16)
                });
                graphics.FillPolygon(red, new[]
                {
                    new Drawing.Point(30, 3),
                    new Drawing.Point(18, 7),
                    new Drawing.Point(24, 16)
                });
                graphics.FillRectangle(white, 8, 9, 16, 5);
            }
            var iconHandle = bitmap.GetHicon();
            return Drawing.Icon.FromHandle(iconHandle);
        }

        private static void UpdateTrayText(string status)
        {
            if (trayIcon == null)
            {
                return;
            }

            var menu = trayIcon.ContextMenuStrip;
            var statusItem = menu == null ? null : menu.Items["status"] as Forms.ToolStripMenuItem;
            if (statusItem != null)
            {
                statusItem.Text = "Claude 状态：" + status;
            }

            var text = "灵梦值守 - " + status;
            trayIcon.Text = text.Length > 63 ? text.Substring(0, 63) : text;
        }

        private static void SaveSettings()
        {
            settingsStore.Save(settings);
        }

        private static string FriendlyError(Exception ex)
        {
            var current = ex;
            while (current.InnerException != null)
            {
                current = current.InnerException;
            }
            return current.Message;
        }

        internal static void Log(string message)
        {
            try
            {
                File.AppendAllText(
                    logPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch
            {
            }
        }

        private static void ExitApplication(Application app)
        {
            if (notificationService != null)
            {
                notificationService.Dispose();
            }
            if (trayIcon != null)
            {
                trayIcon.Visible = false;
                trayIcon.Dispose();
                trayIcon = null;
            }
            if (petWindow != null && petWindow.IsVisible)
            {
                petWindow.Close();
            }
            app.Shutdown();
        }
    }

    [DataContract]
    internal sealed class AppSettings
    {
        public AppSettings()
        {
            BubbleSeconds = 8;
            WindowLeft = double.NaN;
            WindowTop = double.NaN;
        }

        [DataMember] public bool StartWithWindows { get; set; }
        [DataMember] public int BubbleSeconds { get; set; }
        [DataMember] public double WindowLeft { get; set; }
        [DataMember] public double WindowTop { get; set; }
        [DataMember] public bool HasShownWelcome { get; set; }
    }

    internal sealed class SettingsStore
    {
        private readonly string settingsPath;

        public SettingsStore()
        {
            var folder = IOPath.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "NotifyPet");
            Directory.CreateDirectory(folder);
            settingsPath = IOPath.Combine(folder, "settings.json");
        }

        public AppSettings Load()
        {
            if (!File.Exists(settingsPath))
            {
                return new AppSettings();
            }

            try
            {
                using (var stream = File.OpenRead(settingsPath))
                {
                    var serializer = new DataContractJsonSerializer(typeof(AppSettings));
                    return (AppSettings)serializer.ReadObject(stream);
                }
            }
            catch
            {
                return new AppSettings();
            }
        }

        public void Save(AppSettings value)
        {
            var tempPath = settingsPath + ".tmp";
            using (var stream = File.Create(tempPath))
            {
                var serializer = new DataContractJsonSerializer(typeof(AppSettings));
                serializer.WriteObject(stream, value);
            }

            if (File.Exists(settingsPath))
            {
                File.Replace(tempPath, settingsPath, null);
            }
            else
            {
                File.Move(tempPath, settingsPath);
            }

        }
    }

    internal enum ClaudeNotificationKind
    {
        Unknown,
        Completed,
        PermissionRequired,
        RateLimited,
        Error
    }

    internal sealed class PetNotification
    {
        public uint Id { get; set; }
        public string Source { get; set; }
        public string Title { get; set; }
        public string Body { get; set; }
        public DateTime CreatedAt { get; set; }
        public ClaudeNotificationKind Kind { get; set; }
        public string EventId { get; set; }
        public string TranscriptPath { get; set; }
    }

    internal sealed class ClaudeEventDeduplicator
    {
        private readonly HashSet<string> seenEventIds = new HashSet<string>();

        public bool IsDuplicate(string eventId)
        {
            if (string.IsNullOrWhiteSpace(eventId))
            {
                return false;
            }
            if (!seenEventIds.Add(eventId))
            {
                return true;
            }
            while (seenEventIds.Count > 256)
            {
                seenEventIds.Remove(seenEventIds.First());
            }
            return false;
        }
    }

    internal sealed class ClaudeNotificationService : IDisposable
    {
        private readonly AppSettings settings;
        private readonly Action<PetNotification> onNotification;
        private readonly Action<string> onStatus;
        private readonly Action<bool> onActivity;
        private Process bridgeProcess;
        private bool disposed;
        private readonly ClaudeEventDeduplicator eventDeduplicator = new ClaudeEventDeduplicator();

        public ClaudeNotificationService(
            AppSettings settings,
            Action<PetNotification> onNotification,
            Action<string> onStatus,
            Action<bool> onActivity)
        {
            this.settings = settings;
            this.onNotification = onNotification;
            this.onStatus = onStatus;
            this.onActivity = onActivity;
        }

        public async Task StartAsync(bool installHooks)
        {
            if (installHooks && !await Task.Run((Func<bool>)InstallHooks))
            {
                return;
            }
            StartBridge();
            await Task.Delay(50);
        }

        public async Task<bool> ReinstallHooksAsync()
        {
            if (disposed)
            {
                return false;
            }

            if (onActivity != null)
            {
                onActivity(false);
            }
            StopBridge();
            if (!await Task.Run((Func<bool>)InstallHooks))
            {
                return false;
            }
            StartBridge();
            await Task.Delay(50);
            return true;
        }

        private bool InstallHooks()
        {
            try
            {
                var appFolder = IOPath.GetDirectoryName(
                    System.Reflection.Assembly.GetExecutingAssembly().Location);
                var installerPath = IOPath.Combine(appFolder, "InstallClaudeHooks.ps1");
                var hookPath = IOPath.Combine(appFolder, "ClaudeHook.ps1");
                if (!File.Exists(installerPath) || !File.Exists(hookPath))
                {
                    onStatus("缺少 Claude Hooks 安装脚本");
                    return false;
                }

                var arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
                    installerPath + "\" -HookScriptPath \"" + hookPath + "\"";
                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                using (var process = Process.Start(startInfo))
                {
                    var output = process.StandardOutput.ReadToEnd();
                    var error = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        var detail = string.IsNullOrWhiteSpace(error) ? output : error;
                        onStatus("Claude Hooks 安装失败：" + ShortText(detail));
                        return false;
                    }
                }
                Program.Log("Claude hooks installed");
                return true;
            }
            catch (Exception ex)
            {
                onStatus("Claude Hooks 安装失败：" + ShortMessage(ex));
                return false;
            }
        }

        private void StartBridge()
        {
            try
            {
                var appFolder = IOPath.GetDirectoryName(
                    System.Reflection.Assembly.GetExecutingAssembly().Location);
                var bridgePath = IOPath.Combine(appFolder, "NotificationBridge.ps1");
                if (!File.Exists(bridgePath))
                {
                    onStatus("缺少通知桥接脚本");
                    return;
                }

                var arguments = new StringBuilder();
                arguments.Append("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"");
                arguments.Append(bridgePath);
                arguments.Append("\" -ParentProcessId ");
                arguments.Append(Process.GetCurrentProcess().Id.ToString());

                var startInfo = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = arguments.ToString(),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
                process.OutputDataReceived += OnBridgeOutput;
                process.ErrorDataReceived += OnBridgeError;
                process.Exited += delegate
                {
                    if (!disposed && object.ReferenceEquals(bridgeProcess, process))
                    {
                        try
                        {
                            if (process.ExitCode == 0)
                            {
                                onStatus("Claude Hook 桥接已停止");
                            }
                        }
                        catch
                        {
                        }
                    }
                };
                bridgeProcess = process;
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                onStatus("启动失败：" + ShortMessage(ex));
            }
        }

        private void OnBridgeOutput(object sender, DataReceivedEventArgs args)
        {
            if (string.IsNullOrWhiteSpace(args.Data))
            {
                return;
            }
            try
            {
                BridgeMessage message;
                var bytes = Encoding.UTF8.GetBytes(args.Data);
                using (var stream = new MemoryStream(bytes))
                {
                    var serializer = new DataContractJsonSerializer(typeof(BridgeMessage));
                    message = (BridgeMessage)serializer.ReadObject(stream);
                }

                if (message.Type == "status")
                {
                    onStatus(MapStatus(message.Status, message.Message));
                }
                else if (message.Type == "activity")
                {
                    if (onActivity != null)
                    {
                        onActivity(string.Equals(message.Activity, "working", StringComparison.OrdinalIgnoreCase));
                    }
                }
                else if (message.Type == "notification")
                {
                    if (eventDeduplicator.IsDuplicate(message.EventId))
                    {
                        return;
                    }

                    DateTime createdAt;
                    if (!DateTime.TryParse(message.CreatedAt, out createdAt))
                    {
                        createdAt = DateTime.Now;
                    }
                    var notification = ClaudeNotificationParser.Parse(
                        message.Id,
                        message.Source,
                        message.Title,
                        message.Body,
                        createdAt);
                    if (notification == null)
                    {
                        return;
                    }

                    notification.EventId = message.EventId;
                    notification.TranscriptPath = message.TranscriptPath;
                    onNotification(notification);
                }
            }
            catch (Exception ex)
            {
                onStatus("桥接消息异常：" + ShortMessage(ex));
            }
        }

        private void OnBridgeError(object sender, DataReceivedEventArgs args)
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                onStatus("监听错误：" + args.Data);
            }
        }

        private static string MapStatus(string status, string message)
        {
            switch (status)
            {
                case "ready": return "正在监听 Claude CLI";
                case "error": return "监听不可用：" + (message ?? "未知错误");
                default: return message ?? "通知状态未知";
            }
        }

        private void StopBridge()
        {
            var process = bridgeProcess;
            bridgeProcess = null;
            if (process == null)
            {
                return;
            }
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(1000);
                }
            }
            catch
            {
            }
            process.Dispose();
        }

        private static string ShortMessage(Exception ex)
        {
            var current = ex;
            while (current.InnerException != null)
            {
                current = current.InnerException;
            }
            var message = current.Message ?? current.GetType().Name;
            return message.Length > 48 ? message.Substring(0, 48) + "…" : message;
        }

        private static string ShortText(string value)
        {
            value = (value ?? "").Trim();
            return value.Length > 96 ? value.Substring(0, 96) + "…" : value;
        }

        public void Dispose()
        {
            disposed = true;
            StopBridge();
        }
    }

    [DataContract]
    internal sealed class BridgeMessage
    {
        [DataMember(Name = "type")] public string Type { get; set; }
        [DataMember(Name = "activity")] public string Activity { get; set; }
        [DataMember(Name = "status")] public string Status { get; set; }
        [DataMember(Name = "message")] public string Message { get; set; }
        [DataMember(Name = "id")] public uint Id { get; set; }
        [DataMember(Name = "source")] public string Source { get; set; }
        [DataMember(Name = "title")] public string Title { get; set; }
        [DataMember(Name = "body")] public string Body { get; set; }
        [DataMember(Name = "eventId")] public string EventId { get; set; }
        [DataMember(Name = "transcriptPath")] public string TranscriptPath { get; set; }
        [DataMember(Name = "createdAt")] public string CreatedAt { get; set; }
    }

    internal static class ClaudeNotificationParser
    {
        private static readonly Regex RateLimitPattern = new Regex(
            @"\b429\b|too[\s\-_]?many[\s\-_]?requests|rate[\s\-_]?limit|限流|请求过于频繁",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex PermissionPattern = new Regex(
            @"permission|approval|approve|allow|需要权限|权限请求|需要授权|批准|确认权限",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex CompletedPattern = new Regex(
            @"completed?|finished|done|succeeded|success|任务完成|已完成|执行完毕|完成命令|已结束",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex ErrorPattern = new Regex(
            @"api[\s\-_]?error|\berror\b|failed|failure|exception|unauthorized|forbidden|overloaded|timed?[\s\-_]?out|network[\s\-_]?error|connection[\s\-_]?(?:error|failed|refused)|econn\w*|enotfound|报错|错误|失败|异常|超时|网络错误|连接失败",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static PetNotification Parse(
            uint id,
            string source,
            string title,
            string body,
            DateTime createdAt)
        {
            source = string.IsNullOrWhiteSpace(source) ? "Claude Code" : source.Trim();
            title = string.IsNullOrWhiteSpace(title) ? "Claude CLI 通知" : title.Trim();
            body = body ?? "";
            if (!IsClaudeNotification(source, title, body))
            {
                return null;
            }

            var text = source + "\n" + title + "\n" + body;
            ClaudeNotificationKind kind;
            string displayTitle;
            if (RateLimitPattern.IsMatch(text))
            {
                kind = ClaudeNotificationKind.RateLimited;
                displayTitle = "Claude 发生 429 错误";
                body = string.IsNullOrWhiteSpace(body) ? "API Error 429: Too Many Requests" : body.Trim();
            }
            else if (ErrorPattern.IsMatch(text))
            {
                kind = ClaudeNotificationKind.Error;
                displayTitle = "Claude 发生错误";
                body = string.IsNullOrWhiteSpace(body) ? title : body.Trim();
            }
            else if (PermissionPattern.IsMatch(text))
            {
                kind = ClaudeNotificationKind.PermissionRequired;
                displayTitle = "Claude 需要权限";
            }
            else if (CompletedPattern.IsMatch(text))
            {
                kind = ClaudeNotificationKind.Completed;
                displayTitle = "Claude 已完成命令";
            }
            else
            {
                // Only completion, permission and actual error events are actionable.
                return null;
            }

            return new PetNotification
            {
                Id = id,
                Source = "Claude Code",
                Title = displayTitle,
                Body = body.Trim(),
                CreatedAt = createdAt,
                Kind = kind
            };
        }

        public static bool IsClaudeNotification(string source, string title, string body)
        {
            var sourceText = source ?? "";
            if (Regex.IsMatch(sourceText, @"claude|anthropic", RegexOptions.IgnoreCase))
            {
                return true;
            }

            var text = (title ?? "") + "\n" + (body ?? "");
            return Regex.IsMatch(text, @"\bclaude(?:\s+code|\s+cli)?\b|anthropic", RegexOptions.IgnoreCase);
        }

    }

    internal static class ClaudeWindowMonitor
    {
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder text, int capacity);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        public static bool IsClaudeForeground(bool writeLog = true)
        {
            try
            {
                var window = GetForegroundWindow();
                if (window == IntPtr.Zero)
                {
                    return false;
                }

                uint processId;
                GetWindowThreadProcessId(window, out processId);
                var processName = "";
                try
                {
                    processName = Process.GetProcessById((int)processId).ProcessName;
                }
                catch
                {
                }

                var title = ReadWindowText(window);
                var className = ReadWindowClass(window);
                var claudeRunning = Process.GetProcessesByName("claude").Length > 0;
                var result = IsForegroundClaude(processName, className, title, claudeRunning);
                if (writeLog)
                {
                    Program.Log(string.Format(
                        "foreground check: process={0}; class={1}; title={2}; claude-running={3}; is-claude={4}",
                        processName,
                        className,
                        title,
                        claudeRunning,
                        result));
                }
                return result;
            }
            catch (Exception ex)
            {
                Program.Log("foreground check failed: " + ex.Message);
                return false;
            }
        }

        internal static bool IsForegroundClaude(
            string processName,
            string className,
            string title,
            bool claudeRunning)
        {
            processName = processName ?? "";
            className = className ?? "";
            title = title ?? "";

            if (processName.IndexOf("claude", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }

            var isWindowsTerminal =
                processName.IndexOf("WindowsTerminal", StringComparison.OrdinalIgnoreCase) >= 0 ||
                processName.IndexOf("OpenConsole", StringComparison.OrdinalIgnoreCase) >= 0 ||
                className.IndexOf("CASCADIA", StringComparison.OrdinalIgnoreCase) >= 0;
            return isWindowsTerminal &&
                (claudeRunning || title.IndexOf("claude", StringComparison.OrdinalIgnoreCase) >= 0);
        }

        private static string ReadWindowText(IntPtr window)
        {
            var text = new StringBuilder(512);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }

        private static string ReadWindowClass(IntPtr window)
        {
            var text = new StringBuilder(256);
            GetClassName(window, text, text.Capacity);
            return text.ToString();
        }
    }

    internal sealed class PetWindow : Window
    {
        private readonly AppSettings settings;
        private readonly Action saveSettings;
        private readonly Queue<PetNotification> queue = new Queue<PetNotification>();
        private readonly Border bubble;
        private readonly TextBlock titleText;
        private readonly TextBlock bodyText;
        private readonly SolidColorBrush bodyDefaultBrush;
        private readonly LinearGradientBrush runningShimmerBrush;
        private readonly TranslateTransform runningShimmerTransform;
        private readonly TextBlock statusDot;
        private readonly Grid petHost;
        private readonly Border headHitTarget;
        private readonly Canvas petCanvas;
        private readonly TranslateTransform petFloat = new TranslateTransform();
        private readonly DispatcherTimer bubbleTimer;
        private readonly DispatcherTimer idlePreviewTimer;
        private readonly DispatcherTimer motionTimer;
        private Image spriteImage;
        private BitmapSource spriteSheet;
        private bool customSpriteLoaded;
        private int spriteRow = -1;
        private int spriteFrame;
        private double spriteFrameElapsed;
        private static readonly int[] SpriteFrameCounts = { 6, 8, 8, 4, 5, 8, 6, 6, 6 };
        private static readonly int[][] SpriteFrameDurations =
        {
            new[] { 280, 110, 110, 140, 140, 320 },
            new[] { 140, 140, 140, 140, 140, 140, 140, 140 },
            new[] { 120, 120, 120, 120, 120, 120, 120, 120 },
            new[] { 140, 140, 140, 280 },
            new[] { 120, 120, 120, 120, 120 },
            new[] { 140, 140, 140, 140, 140, 140, 140, 240 },
            new[] { 150, 150, 150, 150, 150, 260 },
            new[] { 120, 120, 120, 120, 120, 120 },
            new[] { 150, 150, 150, 150, 150, 280 }
        };
        // Map Claude states to complete animation rows in the Reimu sheet.
        private const int DragSpriteRow = 4;
        private const int WorkingSpriteRow = 2;
        private const int NotificationSpriteRow = 3;
        private const int PermissionSpriteRow = 5;
        private const int ErrorSpriteRow = 8;
        private const int IdleSpriteRow = 0;
        private bool dragging;
        private bool dragMoved;
        private bool taskRunning;
        private bool transientBubbleVisible;
        private bool bubbleHiddenByUser = true;
        private PetNotification currentNotification;
        private int dragStartCursorX;
        private int dragStartCursorY;
        private double dragStartLeft;
        private double dragStartTop;
        private double dragScaleX = 1;
        private double dragScaleY = 1;
        private bool bubbleVisible;
        private double motionPhase;
        private readonly Stopwatch motionClock = Stopwatch.StartNew();
        private readonly Stopwatch foregroundDismissClock = Stopwatch.StartNew();
        private HwndSource windowSource;
        private IntPtr windowHandle;
        private bool clickThroughEnabled;

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(
            IntPtr window,
            IntPtr insertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

        private static readonly IntPtr HwndTopmost = new IntPtr(-1);
        private const uint SwpNoSize = 0x0001;
        private const uint SwpNoMove = 0x0002;
        private const uint SwpNoActivate = 0x0010;
        private const uint SwpShowWindow = 0x0040;
        private const int WmNcHitTest = 0x0084;
        private const int GwlExtendedStyle = -20;
        private const long WsExTransparent = 0x00000020L;
        private const long WsExNoActivate = 0x08000000L;
        private static readonly IntPtr HtTransparent = new IntPtr(-1);
        private const double HeadHitLeft = 26;
        private const double HeadHitTop = 0;
        private const double HeadHitWidth = 96;
        private const double HeadHitHeight = 82;

        public string ListenerStatus { get; private set; }

        public PetWindow(AppSettings settings, Action saveSettings)
        {
            this.settings = settings;
            this.saveSettings = saveSettings;
            ListenerStatus = "正在配置 Claude Hooks";

            Width = 398;
            Height = 326;
            Title = "灵梦值守";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowActivated = false;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            Focusable = false;

            var root = new Grid();
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(145) });
            Content = root;

            bubble = new Border
            {
                Width = 318,
                Height = 54,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 14, 4),
                Padding = new Thickness(16, 6, 16, 6),
                CornerRadius = new CornerRadius(27),
                Background = new SolidColorBrush(Color.FromArgb(222, 31, 34, 38)),
                BorderBrush = new SolidColorBrush(Color.FromRgb(62, 66, 72)),
                BorderThickness = new Thickness(1),
                Opacity = 0,
                Visibility = Visibility.Hidden,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    Color = Colors.Black,
                    BlurRadius = 12,
                    ShadowDepth = 2,
                    Opacity = 0.24
                }
            };
            Grid.SetRow(bubble, 0);
            root.Children.Add(bubble);

            var stack = new StackPanel();
            bubble.Child = stack;

            titleText = MakeText(13.5, Color.FromRgb(247, 248, 249), FontWeights.SemiBold);
            titleText.TextWrapping = TextWrapping.NoWrap;
            titleText.TextTrimming = TextTrimming.CharacterEllipsis;
            titleText.Height = 20;
            stack.Children.Add(titleText);

            bodyDefaultBrush = new SolidColorBrush(Color.FromRgb(174, 179, 186));
            runningShimmerTransform = new TranslateTransform(-0.7, 0);
            runningShimmerBrush = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0.5),
                EndPoint = new Point(1, 0.5),
                MappingMode = BrushMappingMode.RelativeToBoundingBox,
                SpreadMethod = GradientSpreadMethod.Pad,
                RelativeTransform = runningShimmerTransform
            };
            runningShimmerBrush.GradientStops.Add(new GradientStop(Color.FromRgb(151, 156, 164), 0));
            runningShimmerBrush.GradientStops.Add(new GradientStop(Color.FromRgb(151, 156, 164), 0.34));
            runningShimmerBrush.GradientStops.Add(new GradientStop(Color.FromRgb(250, 251, 252), 0.5));
            runningShimmerBrush.GradientStops.Add(new GradientStop(Color.FromRgb(151, 156, 164), 0.66));
            runningShimmerBrush.GradientStops.Add(new GradientStop(Color.FromRgb(151, 156, 164), 1));

            bodyText = MakeText(12, Color.FromRgb(174, 179, 186), FontWeights.Normal);
            bodyText.Foreground = bodyDefaultBrush;
            bodyText.Margin = new Thickness(0, 0, 0, 0);
            bodyText.TextWrapping = TextWrapping.NoWrap;
            bodyText.Height = 17;
            bodyText.TextTrimming = TextTrimming.CharacterEllipsis;
            stack.Children.Add(bodyText);

            petHost = new Grid
            {
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Width = 148,
                Height = 145,
                Margin = new Thickness(0, 0, 6, 0),
                Background = null
            };
            Grid.SetRow(petHost, 1);
            root.Children.Add(petHost);

            petCanvas = BuildPet();
            petCanvas.RenderTransform = petFloat;
            petCanvas.RenderTransformOrigin = new Point(0.5, 0.5);
            petCanvas.IsHitTestVisible = false;
            petHost.Children.Add(petCanvas);

            spriteImage = new Image
            {
                Width = 124,
                Height = 135,
                Stretch = Stretch.Uniform,
                Visibility = Visibility.Hidden,
                IsHitTestVisible = false
            };
            Canvas.SetLeft(spriteImage, 2);
            Canvas.SetTop(spriteImage, 2);
            petCanvas.Children.Add(spriteImage);
            SetVectorVisibility(Visibility.Hidden);
            LoadCustomSprite();

            statusDot = new TextBlock
            {
                Text = "●",
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(250, 204, 21)),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 14, 14, 0),
                ToolTip = ListenerStatus,
                IsHitTestVisible = false
            };
            petHost.Children.Add(statusDot);

            headHitTarget = new Border
            {
                Width = HeadHitWidth,
                Height = HeadHitHeight,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(HeadHitLeft, HeadHitTop, 0, 0),
                Background = Brushes.Transparent,
                Cursor = Cursors.SizeAll,
                ToolTip = "拖动头部；双击显示或隐藏状态"
            };
            Panel.SetZIndex(headHitTarget, 10);
            petHost.Children.Add(headHitTarget);

            headHitTarget.PreviewMouseLeftButtonDown += OnPetMouseDown;
            headHitTarget.PreviewMouseMove += OnPetMouseMove;
            headHitTarget.PreviewMouseLeftButtonUp += OnPetMouseUp;
            headHitTarget.LostMouseCapture += OnPetLostMouseCapture;

            bubbleTimer = new DispatcherTimer();
            bubbleTimer.Tick += delegate { HideBubble(true); };

            idlePreviewTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
            idlePreviewTimer.Tick += delegate
            {
                idlePreviewTimer.Stop();
                if (!taskRunning && !transientBubbleVisible)
                {
                    bubbleHiddenByUser = true;
                    HideBubble(false);
                }
            };

            motionTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
            motionTimer.Tick += OnMotionTick;
            motionTimer.Start();

            Loaded += OnLoaded;
            SourceInitialized += OnSourceInitialized;
            Closed += delegate
            {
                if (windowSource != null)
                {
                    windowSource.RemoveHook(WindowMessageHook);
                    windowSource = null;
                }
            };
            LocationChanged += delegate
            {
                if (!dragging)
                {
                    return;
                }
                settings.WindowLeft = Left;
                settings.WindowTop = Top;
            };
        }

        private void OnLoaded(object sender, RoutedEventArgs args)
        {
            if (!double.IsNaN(settings.WindowLeft) && !double.IsNaN(settings.WindowTop))
            {
                Left = Clamp(settings.WindowLeft, SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
                Top = Clamp(settings.WindowTop, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
            }
            else
            {
                var area = SystemParameters.WorkArea;
                Left = area.Right - Width - 18;
                Top = area.Bottom - Height - 8;
            }

            var source = PresentationSource.FromVisual(this);
            var scaleX = 1.0;
            var scaleY = 1.0;
            if (source != null && source.CompositionTarget != null)
            {
                scaleX = source.CompositionTarget.TransformToDevice.M11;
                scaleY = source.CompositionTarget.TransformToDevice.M22;
            }
            Program.Log(string.Format(
                "window bounds dip={0:0.##},{1:0.##},{2:0.##},{3:0.##}; dpi-scale={4:0.###},{5:0.###}; work-area={6}",
                Left,
                Top,
                Width,
                Height,
                scaleX,
                scaleY,
                SystemParameters.WorkArea));
            EnsureTopmostWithoutActivation();
        }

        private void OnSourceInitialized(object sender, EventArgs args)
        {
            windowHandle = new WindowInteropHelper(this).Handle;
            windowSource = HwndSource.FromHwnd(windowHandle);
            if (windowSource != null)
            {
                windowSource.AddHook(WindowMessageHook);
            }
            Program.Log("window handle initialized: " + windowHandle);
        }

        private IntPtr WindowMessageHook(
            IntPtr window,
            int message,
            IntPtr wordParameter,
            IntPtr longParameter,
            ref bool handled)
        {
            if (message != WmNcHitTest || dragging || !IsLoaded)
            {
                return IntPtr.Zero;
            }

            try
            {
                var packedPoint = longParameter.ToInt64();
                var screenX = unchecked((short)(packedPoint & 0xffff));
                var screenY = unchecked((short)((packedPoint >> 16) & 0xffff));
                var windowPoint = PointFromScreen(new Point(screenX, screenY));
                var hostOrigin = petHost.TranslatePoint(new Point(0, 0), this);
                if (!IsHeadHitPoint(windowPoint.X - hostOrigin.X, windowPoint.Y - hostOrigin.Y))
                {
                    handled = true;
                    return HtTransparent;
                }
            }
            catch
            {
            }
            return IntPtr.Zero;
        }

        internal static bool IsHeadHitPoint(double x, double y)
        {
            return x >= HeadHitLeft && x <= HeadHitLeft + HeadHitWidth &&
                y >= HeadHitTop && y <= HeadHitTop + HeadHitHeight;
        }

        private static TextBlock MakeText(double size, Color color, FontWeight weight)
        {
            return new TextBlock
            {
                FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"),
                FontSize = size,
                FontWeight = weight,
                Foreground = new SolidColorBrush(color)
            };
        }

        private void LoadCustomSprite()
        {
            var spritePath = IOPath.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "assets",
                "custom-spritesheet.png");
            if (!File.Exists(spritePath))
            {
                SetVectorVisibility(Visibility.Visible);
                return;
            }

            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.UriSource = new Uri(spritePath, UriKind.Absolute);
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.EndInit();
                bitmap.Freeze();
                if (bitmap.PixelWidth < 1536 || bitmap.PixelHeight < 1872)
                {
                    throw new InvalidDataException("custom spritesheet must be at least 1536x1872");
                }

                spriteSheet = bitmap;
                customSpriteLoaded = true;
                spriteImage.Visibility = Visibility.Visible;
                UpdateSpriteFrame(0, 0);
                Program.Log("custom pet loaded: " + spritePath);
            }
            catch (Exception ex)
            {
                customSpriteLoaded = false;
                spriteImage.Visibility = Visibility.Hidden;
                SetVectorVisibility(Visibility.Visible);
                Program.Log("custom pet load failed: " + ex.Message);
            }
        }

        private void SetVectorVisibility(Visibility visibility)
        {
            foreach (UIElement child in petCanvas.Children)
            {
                if (!object.ReferenceEquals(child, spriteImage))
                {
                    child.Visibility = visibility;
                }
            }
        }

        private void UpdateSpriteAnimation(int elapsedMilliseconds)
        {
            if (!customSpriteLoaded)
            {
                return;
            }

            var notificationKind = currentNotification == null
                ? ClaudeNotificationKind.Unknown
                : currentNotification.Kind;
            var desiredRow = SelectSpriteRow(
                dragging,
                taskRunning,
                transientBubbleVisible,
                notificationKind);
            if (desiredRow != spriteRow)
            {
                spriteRow = desiredRow;
                spriteFrame = 0;
                spriteFrameElapsed = 0;
                UpdateSpriteFrame(spriteRow, spriteFrame);
                return;
            }

            spriteFrameElapsed += elapsedMilliseconds;
            var durations = SpriteFrameDurations[spriteRow];
            while (spriteFrameElapsed >= durations[spriteFrame])
            {
                spriteFrameElapsed -= durations[spriteFrame];
                spriteFrame = (spriteFrame + 1) % SpriteFrameCounts[spriteRow];
                UpdateSpriteFrame(spriteRow, spriteFrame);
            }
        }

        internal static int SelectSpriteRow(
            bool isDragging,
            bool isRunning,
            bool notificationVisible,
            ClaudeNotificationKind notificationKind)
        {
            if (isDragging)
            {
                return DragSpriteRow;
            }
            if (isRunning)
            {
                return WorkingSpriteRow;
            }
            if (!notificationVisible)
            {
                return IdleSpriteRow;
            }
            if (notificationKind == ClaudeNotificationKind.PermissionRequired)
            {
                return PermissionSpriteRow;
            }
            if (notificationKind == ClaudeNotificationKind.RateLimited ||
                notificationKind == ClaudeNotificationKind.Error)
            {
                return ErrorSpriteRow;
            }
            return NotificationSpriteRow;
        }

        private void UpdateSpriteFrame(int row, int column)
        {
            if (!customSpriteLoaded || spriteSheet == null)
            {
                return;
            }
            var frame = new CroppedBitmap(
                spriteSheet,
                new Int32Rect(column * 192, row * 208, 192, 208));
            frame.Freeze();
            spriteImage.Source = frame;
        }

        private Canvas BuildPet()
        {
            var canvas = new Canvas { Width = 128, Height = 140 };

            var antenna = new Line
            {
                X1 = 64,
                Y1 = 25,
                X2 = 64,
                Y2 = 11,
                Stroke = new SolidColorBrush(Color.FromRgb(65, 76, 88)),
                StrokeThickness = 5,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round
            };
            canvas.Children.Add(antenna);

            var antennaTip = new Ellipse
            {
                Width = 13,
                Height = 13,
                Fill = new SolidColorBrush(Color.FromRgb(74, 222, 128))
            };
            Canvas.SetLeft(antennaTip, 57.5);
            Canvas.SetTop(antennaTip, 2);
            canvas.Children.Add(antennaTip);

            var leftEar = RoundedRect(28, 35, 12, Color.FromRgb(47, 57, 68), 5);
            Canvas.SetLeft(leftEar, 8);
            Canvas.SetTop(leftEar, 42);
            canvas.Children.Add(leftEar);

            var rightEar = RoundedRect(28, 35, 12, Color.FromRgb(47, 57, 68), 5);
            Canvas.SetLeft(rightEar, 92);
            Canvas.SetTop(rightEar, 42);
            canvas.Children.Add(rightEar);

            var head = RoundedRect(100, 76, 26, Color.FromRgb(34, 41, 49), 0);
            head.BorderBrush = new SolidColorBrush(Color.FromRgb(82, 94, 108));
            head.BorderThickness = new Thickness(2);
            Canvas.SetLeft(head, 14);
            Canvas.SetTop(head, 25);
            canvas.Children.Add(head);

            var face = RoundedRect(76, 46, 18, Color.FromRgb(18, 24, 30), 0);
            Canvas.SetLeft(face, 26);
            Canvas.SetTop(face, 39);
            canvas.Children.Add(face);

            var leftEye = new Ellipse { Width = 9, Height = 13, Fill = Brushes.White };
            Canvas.SetLeft(leftEye, 43);
            Canvas.SetTop(leftEye, 54);
            canvas.Children.Add(leftEye);

            var rightEye = new Ellipse { Width = 9, Height = 13, Fill = Brushes.White };
            Canvas.SetLeft(rightEye, 76);
            Canvas.SetTop(rightEye, 54);
            canvas.Children.Add(rightEye);

            var mouth = new Line
            {
                X1 = 58,
                Y1 = 74,
                X2 = 70,
                Y2 = 74,
                Stroke = new SolidColorBrush(Color.FromRgb(74, 222, 128)),
                StrokeThickness = 3,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round
            };
            canvas.Children.Add(mouth);

            var body = RoundedRect(72, 37, 17, Color.FromRgb(45, 54, 64), 0);
            body.BorderBrush = new SolidColorBrush(Color.FromRgb(82, 94, 108));
            body.BorderThickness = new Thickness(2);
            Canvas.SetLeft(body, 28);
            Canvas.SetTop(body, 96);
            canvas.Children.Add(body);

            var badge = new Ellipse
            {
                Width = 13,
                Height = 13,
                Fill = new SolidColorBrush(Color.FromRgb(74, 222, 128))
            };
            Canvas.SetLeft(badge, 57.5);
            Canvas.SetTop(badge, 106);
            canvas.Children.Add(badge);

            var leftFoot = RoundedRect(26, 11, 5, Color.FromRgb(28, 34, 41), 0);
            Canvas.SetLeft(leftFoot, 26);
            Canvas.SetTop(leftFoot, 128);
            canvas.Children.Add(leftFoot);

            var rightFoot = RoundedRect(26, 11, 5, Color.FromRgb(28, 34, 41), 0);
            Canvas.SetLeft(rightFoot, 76);
            Canvas.SetTop(rightFoot, 128);
            canvas.Children.Add(rightFoot);

            return canvas;
        }

        private static Border RoundedRect(double width, double height, double radius, Color color, double opacity)
        {
            return new Border
            {
                Width = width,
                Height = height,
                CornerRadius = new CornerRadius(radius),
                Background = new SolidColorBrush(color),
                Opacity = opacity <= 0 ? 1 : opacity
            };
        }

        private void OnPetMouseDown(object sender, MouseButtonEventArgs args)
        {
            if (args.ClickCount > 1)
            {
                FinishPetDrag(false);
                ToggleBubbleVisibility();
                args.Handled = true;
                return;
            }

            if (args.ChangedButton != MouseButton.Left)
            {
                return;
            }

            dragging = true;
            dragMoved = false;
            var cursor = Forms.Cursor.Position;
            dragStartCursorX = cursor.X;
            dragStartCursorY = cursor.Y;
            dragStartLeft = Left;
            dragStartTop = Top;
            var source = PresentationSource.FromVisual(this);
            if (source != null && source.CompositionTarget != null)
            {
                dragScaleX = Math.Max(0.1, source.CompositionTarget.TransformToDevice.M11);
                dragScaleY = Math.Max(0.1, source.CompositionTarget.TransformToDevice.M22);
            }
            else
            {
                dragScaleX = 1;
                dragScaleY = 1;
            }
            headHitTarget.CaptureMouse();
            args.Handled = true;
        }

        private void OnPetMouseMove(object sender, MouseEventArgs args)
        {
            if (!dragging)
            {
                return;
            }
            if (args.LeftButton != MouseButtonState.Pressed)
            {
                FinishPetDrag(true);
                return;
            }

            var cursor = Forms.Cursor.Position;
            var deltaX = (cursor.X - dragStartCursorX) / dragScaleX;
            var deltaY = (cursor.Y - dragStartCursorY) / dragScaleY;
            if (Math.Abs(deltaX) >= 2 || Math.Abs(deltaY) >= 2)
            {
                dragMoved = true;
            }

            Left = Clamp(
                dragStartLeft + deltaX,
                SystemParameters.VirtualScreenLeft,
                SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
            Top = Clamp(
                dragStartTop + deltaY,
                SystemParameters.VirtualScreenTop,
                SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
            args.Handled = true;
        }

        private void OnPetMouseUp(object sender, MouseButtonEventArgs args)
        {
            if (args.ChangedButton != MouseButton.Left)
            {
                return;
            }
            FinishPetDrag(true);
            args.Handled = true;
        }

        private void OnPetLostMouseCapture(object sender, MouseEventArgs args)
        {
            FinishPetDrag(true);
        }

        private void FinishPetDrag(bool savePosition)
        {
            var wasDragging = dragging;
            dragging = false;
            if (headHitTarget.IsMouseCaptured)
            {
                headHitTarget.ReleaseMouseCapture();
            }
            if (!wasDragging || !savePosition)
            {
                return;
            }

            settings.WindowLeft = Left;
            settings.WindowTop = Top;
            saveSettings();
            if (dragMoved)
            {
                Program.Log(string.Format("pet moved to {0:0.##},{1:0.##}", Left, Top));
            }
        }

        private void OnMotionTick(object sender, EventArgs args)
        {
            var elapsed = motionClock.Elapsed.TotalMilliseconds;
            motionClock.Restart();
            if (elapsed < 1 || elapsed > 250)
            {
                elapsed = 16;
            }
            motionPhase += elapsed * 0.0024;
            petFloat.Y = Math.Sin(motionPhase) * 2.2;
            petFloat.X = Math.Sin(motionPhase * 0.45) * 0.6;
            UpdateSpriteAnimation((int)Math.Round(elapsed));
            UpdateClickThroughState();
            if (currentNotification != null &&
                ShouldDismissNotificationWhenClaudeForeground(currentNotification.Kind) &&
                foregroundDismissClock.ElapsedMilliseconds >= 350)
            {
                foregroundDismissClock.Restart();
                if (ClaudeWindowMonitor.IsClaudeForeground(false))
                {
                    bubbleHiddenByUser = true;
                    HideBubble(true);
                }
            }
        }

        private void UpdateClickThroughState()
        {
            if (windowHandle == IntPtr.Zero || !IsLoaded)
            {
                return;
            }

            var cursor = Forms.Cursor.Position;
            var windowPoint = PointFromScreen(new Point(cursor.X, cursor.Y));
            var hostOrigin = petHost.TranslatePoint(new Point(0, 0), this);
            var overHead = IsHeadHitPoint(
                windowPoint.X - hostOrigin.X,
                windowPoint.Y - hostOrigin.Y);
            SetClickThrough(!dragging && !overHead);
        }

        private void SetClickThrough(bool enabled)
        {
            if (clickThroughEnabled == enabled || windowHandle == IntPtr.Zero)
            {
                return;
            }

            var style = GetWindowLongPtr(windowHandle, GwlExtendedStyle).ToInt64();
            var updatedStyle = ApplyClickThroughStyle(style, enabled);
            SetWindowLongPtr(windowHandle, GwlExtendedStyle, new IntPtr(updatedStyle));
            clickThroughEnabled = enabled;
        }

        internal static long ApplyClickThroughStyle(long style, bool enabled)
        {
            return enabled
                ? style | WsExTransparent | WsExNoActivate
                : (style & ~WsExTransparent) | WsExNoActivate;
        }

        public void SetTaskRunning(bool running)
        {
            taskRunning = running;
            if (running)
            {
                idlePreviewTimer.Stop();
                bubbleHiddenByUser = true;
                if (currentNotification != null &&
                    ShouldDismissNotificationOnActivity(running, currentNotification.Kind))
                {
                    bubbleTimer.Stop();
                    queue.Clear();
                    currentNotification = null;
                    transientBubbleVisible = false;
                }
            }
            if (customSpriteLoaded)
            {
                UpdateSpriteAnimation(0);
            }
            if (ShouldShowPersistentStatus(running, bubbleHiddenByUser, transientBubbleVisible))
            {
                ShowPersistentStatus(false);
            }
            else if (!running && !transientBubbleVisible && bubbleVisible)
            {
                bubbleTimer.Stop();
                bubbleTimer.Interval = TimeSpan.FromMilliseconds(250);
                bubbleTimer.Start();
            }
        }

        internal static bool ShouldShowPersistentStatus(
            bool running,
            bool hiddenByUser,
            bool transientVisible)
        {
            return !transientVisible && (running || !hiddenByUser);
        }

        internal static bool ShouldAutoDismissNotification(ClaudeNotificationKind kind)
        {
            return kind != ClaudeNotificationKind.Completed &&
                kind != ClaudeNotificationKind.PermissionRequired &&
                kind != ClaudeNotificationKind.RateLimited &&
                kind != ClaudeNotificationKind.Error;
        }

        internal static bool ShouldDismissNotificationWhenClaudeForeground(
            ClaudeNotificationKind kind)
        {
            return kind == ClaudeNotificationKind.Completed ||
                kind == ClaudeNotificationKind.RateLimited ||
                kind == ClaudeNotificationKind.Error;
        }

        internal static bool ShouldDismissNotificationOnActivity(
            bool running,
            ClaudeNotificationKind kind)
        {
            return running && kind == ClaudeNotificationKind.PermissionRequired;
        }

        public void SetListenerStatus(string status)
        {
            ListenerStatus = status;
            statusDot.ToolTip = status;
            if (status.IndexOf("正在监听 Claude", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                statusDot.Foreground = new SolidColorBrush(Color.FromRgb(74, 222, 128));
                if (!settings.HasShownWelcome)
                {
                    settings.HasShownWelcome = true;
                    saveSettings();
                }
                if (!transientBubbleVisible && !bubbleHiddenByUser)
                {
                    ShowPersistentStatus(false);
                }
            }
            else if (status.IndexOf("Hooks", StringComparison.OrdinalIgnoreCase) >= 0 ||
                     status.IndexOf("Hook", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                statusDot.Foreground = new SolidColorBrush(Color.FromRgb(250, 204, 21));
                ShowSystemMessage("Claude Hooks 未就绪", status);
            }
            else
            {
                statusDot.Foreground = new SolidColorBrush(Color.FromRgb(248, 113, 113));
                ShowSystemMessage("Claude 通知监听不可用", status);
            }
        }

        public void EnqueueNotification(PetNotification notification)
        {
            if (notification == null)
            {
                return;
            }
            idlePreviewTimer.Stop();
            bubbleHiddenByUser = true;
            if (notification.Kind == ClaudeNotificationKind.Completed ||
                 notification.Kind == ClaudeNotificationKind.PermissionRequired ||
                 notification.Kind == ClaudeNotificationKind.RateLimited ||
                 notification.Kind == ClaudeNotificationKind.Error)
            {
                SetTaskRunning(false);
            }
            while (queue.Count >= 20)
            {
                queue.Dequeue();
            }
            queue.Enqueue(notification);
            if (!transientBubbleVisible)
            {
                ShowNext();
            }
        }

        public void ShowSystemMessage(string title, string body)
        {
            EnqueueNotification(new PetNotification
            {
                Source = "灵梦值守",
                Title = title,
                Body = body,
                CreatedAt = DateTime.Now
            });
        }

        private void ShowNext()
        {
            if (queue.Count == 0)
            {
                transientBubbleVisible = false;
                currentNotification = null;
                if (taskRunning || !bubbleHiddenByUser)
                {
                    ShowPersistentStatus(true);
                }
                return;
            }

            var notification = queue.Dequeue();
            idlePreviewTimer.Stop();
            currentNotification = notification;
            transientBubbleVisible = true;
            StopRunningShimmer();
            titleText.Text = CompactLine(notification.Title);
            bodyText.Text = CompactLine(notification.Body);
            bodyText.Visibility = string.IsNullOrWhiteSpace(notification.Body)
                ? Visibility.Collapsed
                : Visibility.Visible;
            bubble.Visibility = Visibility.Visible;
            bubbleVisible = true;
            EnsureTopmostWithoutActivation();
            var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160));
            bubble.BeginAnimation(OpacityProperty, fade);

            bubbleTimer.Stop();
            if (!ShouldAutoDismissNotification(notification.Kind))
            {
                foregroundDismissClock.Restart();
            }
            else
            {
                var seconds = Math.Max(3, Math.Min(30, settings.BubbleSeconds));
                bubbleTimer.Interval = TimeSpan.FromSeconds(seconds);
                bubbleTimer.Start();
            }
        }

        private void HideBubble(bool advanceQueue)
        {
            bubbleTimer.Stop();
            idlePreviewTimer.Stop();
            StopRunningShimmer();
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(140));
            fade.Completed += delegate
            {
                bubble.Visibility = Visibility.Hidden;
                bubbleVisible = false;
                transientBubbleVisible = false;
                currentNotification = null;
                if (advanceQueue)
                {
                    if (queue.Count > 0)
                    {
                        ShowNext();
                    }
                    else if (taskRunning || !bubbleHiddenByUser)
                    {
                        ShowPersistentStatus(true);
                    }
                }
            };
            bubble.BeginAnimation(OpacityProperty, fade);
        }

        private void ToggleBubbleVisibility()
        {
            if (bubbleVisible)
            {
                idlePreviewTimer.Stop();
                bubbleHiddenByUser = true;
                queue.Clear();
                HideBubble(false);
                return;
            }

            bubbleHiddenByUser = false;
            ShowPersistentStatus(true);
            if (!taskRunning)
            {
                idlePreviewTimer.Stop();
                idlePreviewTimer.Start();
            }
        }

        private void ShowPersistentStatus(bool animate)
        {
            transientBubbleVisible = false;
            currentNotification = null;
            bubbleTimer.Stop();
            titleText.Text = taskRunning
                ? "灵梦值守 · Claude 正在执行"
                : "灵梦值守 · Claude 已连接";
            bodyText.Text = taskRunning
                ? "正在思考"
                : ListenerStatus.IndexOf("正在监听 Claude", StringComparison.OrdinalIgnoreCase) >= 0
                    ? "等待 Claude 命令"
                    : CompactLine(ListenerStatus);
            if (taskRunning)
            {
                StartRunningShimmer();
            }
            else
            {
                StopRunningShimmer();
            }
            bodyText.Visibility = Visibility.Visible;
            bubble.Visibility = Visibility.Visible;
            bubbleVisible = true;
            EnsureTopmostWithoutActivation();
            bubble.BeginAnimation(OpacityProperty, null);
            if (animate)
            {
                bubble.BeginAnimation(
                    OpacityProperty,
                    new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
            }
            else
            {
                bubble.Opacity = 1;
            }
        }

        private static string CompactLine(string value)
        {
            return Regex.Replace(value ?? "", @"\s+", " ").Trim();
        }

        private void StartRunningShimmer()
        {
            bodyText.Foreground = runningShimmerBrush;
            var shimmer = new DoubleAnimation(-0.7, 0.7, TimeSpan.FromMilliseconds(1500))
            {
                RepeatBehavior = RepeatBehavior.Forever
            };
            runningShimmerTransform.BeginAnimation(TranslateTransform.XProperty, shimmer);
        }

        private void StopRunningShimmer()
        {
            runningShimmerTransform.BeginAnimation(TranslateTransform.XProperty, null);
            runningShimmerTransform.X = -0.7;
            bodyText.Foreground = bodyDefaultBrush;
        }

        private void EnsureTopmostWithoutActivation()
        {
            var handle = new WindowInteropHelper(this).Handle;
            if (handle == IntPtr.Zero)
            {
                return;
            }
            SetWindowPos(
                handle,
                HwndTopmost,
                0,
                0,
                0,
                0,
                SwpNoMove | SwpNoSize | SwpNoActivate | SwpShowWindow);
        }

        private static double Clamp(double value, double min, double max)
        {
            return Math.Max(min, Math.Min(max, value));
        }
    }

    internal static class AutoStartManager
    {
        private const string RegistryPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string ValueName = "ReimuWatch";
        private const string LegacyValueName = "NotifyPet";

        public static void MigrateLegacyEntry()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(RegistryPath, true))
            {
                if (key == null)
                {
                    return;
                }
                if (key.GetValue(ValueName) != null || key.GetValue(LegacyValueName) != null)
                {
                    var executable = System.Reflection.Assembly.GetExecutingAssembly().Location;
                    key.SetValue(ValueName, "\"" + executable + "\"");
                    key.DeleteValue(LegacyValueName, false);
                }
            }
        }

        public static bool IsEnabled()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(RegistryPath, false))
            {
                return key != null &&
                    (key.GetValue(ValueName) != null || key.GetValue(LegacyValueName) != null);
            }
        }

        public static void SetEnabled(bool enabled)
        {
            using (var key = Registry.CurrentUser.OpenSubKey(RegistryPath, true))
            {
                if (key == null)
                {
                    throw new InvalidOperationException("无法打开开机启动注册表项。");
                }
                if (enabled)
                {
                    var executable = System.Reflection.Assembly.GetExecutingAssembly().Location;
                    key.SetValue(ValueName, "\"" + executable + "\"");
                    key.DeleteValue(LegacyValueName, false);
                }
                else
                {
                    key.DeleteValue(ValueName, false);
                    key.DeleteValue(LegacyValueName, false);
                }
            }
        }
    }
}

using System.Diagnostics;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace Feipan.Receiver;

internal static class Program
{
    private const string HtmlResourceName = "Feipan.Receiver.receiver.html";

    [STAThread]
    private static async Task<int> Main(string[] args)
    {
        // 1. 启动本地 HTTP 服务，占用一个空闲端口
        using var listener = new HttpListener();
        int port = FindFreePort();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();

        var appDir = AppContext.BaseDirectory;
        var localHtml = Path.Combine(appDir, "receiver.html");

        var serverTask = Task.Run(async () =>
        {
            while (listener.IsListening)
            {
                try
                {
                    var ctx = await listener.GetContextAsync();
                    _ = HandleRequest(ctx, localHtml);
                }
                catch (ObjectDisposedException) { break; }
                catch (Exception) { /* ignore */ }
            }
        });

        // 2. 启动 Edge / Chrome 应用模式
        var url = $"http://127.0.0.1:{port}/receiver.html";
        var browser = FindBrowser();
        if (browser is null)
        {
            listener.Stop();
            MessageBox("未找到 Microsoft Edge 或 Google Chrome。\n请安装 Edge 后重试。", "启动失败");
            return 1;
        }

        // 用独立 user-data-dir，确保进程生命周期与窗口绑定（Edge 多进程下否则会立即退出）
        var userDataDir = Path.Combine(Path.GetTempPath(), "FeipanReceiver_" + Guid.NewGuid().ToString("N"));

        var psi = new ProcessStartInfo
        {
            FileName = browser,
            // 后台保活三件套：禁定时器节流 / 禁遮挡降级 / 禁渲染进程降优先级。
            // 另外必须禁用 CalculateNativeWinOcclusion（Windows 遮挡计算会把最小化窗口判为
            // hidden，触发 IntensiveWakeUpThrottling 把定时器压到每分钟 1 次，导致 CSV 冻结）
            Arguments = $"--app=\"{url}\" --user-data-dir=\"{userDataDir}\" --window-size=1280,800 --no-first-run " +
                        "--disable-background-timer-throttling --disable-backgrounding-occluded-windows " +
                        "--disable-renderer-backgrounding " +
                        "--disable-features=TranslateUI,CalculateNativeWinOcclusion,IntensiveWakeUpThrottling",
            UseShellExecute = false,
        };
        var browserProcess = Process.Start(psi);

        if (browserProcess is null)
        {
            listener.Stop();
            try { Directory.Delete(userDataDir, true); } catch { }
            return 1;
        }

        // 3. 等待浏览器窗口关闭。若启动进程提前退出（多进程委托），则轮询窗口标题兜底
        bool exited = false;
        try
        {
            exited = browserProcess.WaitForExit(3000);
        }
        catch { }

        if (exited)
        {
            // 进程快速退出但窗口可能已交给其他进程托管，按标题找窗口轮询
            await WaitForAppWindowCloseAsync();
        }
        else
        {
            browserProcess.WaitForExit();
        }

        listener.Stop();
        try { Directory.Delete(userDataDir, true); } catch { }
        return 0;
    }

    private static async Task WaitForAppWindowCloseAsync()
    {
        // 查找标题含"比分接收端"或指向本地地址的 Edge/Chrome 窗口，等它消失
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "msedge", "chrome" };
        for (int i = 0; i < 60; i++)
        {
            bool found = false;
            foreach (var p in Process.GetProcesses())
            {
                if (!names.Contains(p.ProcessName)) continue;
                var t = p.MainWindowTitle;
                if (string.IsNullOrEmpty(t)) continue;
                if (t.Contains("比分接收端") || t.StartsWith("127.0.0.1") || t.StartsWith("localhost"))
                { found = true; break; }
            }
            if (!found) return;
            await Task.Delay(1000);
        }
    }

    private static int FindFreePort()
    {
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static async Task HandleRequest(HttpListenerContext ctx, string localHtml)
    {
        try
        {
            var req = ctx.Request;
            var resp = ctx.Response;
            var path = req.Url?.AbsolutePath.Trim('/') ?? "";

            if (path == "" || path == "receiver.html")
            {
                string html;
                if (File.Exists(localHtml))
                {
                    html = File.ReadAllText(localHtml);
                }
                else
                {
                    using var stream = Assembly.GetExecutingAssembly()
                        .GetManifestResourceStream(HtmlResourceName);
                    if (stream is null)
                    {
                        resp.StatusCode = 404;
                        resp.Close();
                        return;
                    }
                    using var sr = new StreamReader(stream, Encoding.UTF8);
                    html = sr.ReadToEnd();
                }

                var bytes = Encoding.UTF8.GetBytes(html);
                resp.ContentType = "text/html; charset=utf-8";
                resp.ContentLength64 = bytes.Length;
                resp.Headers.Set("Cache-Control", "no-store");
                await resp.OutputStream.WriteAsync(bytes);
                resp.Close();
                return;
            }

            resp.StatusCode = 404;
            resp.Close();
        }
        catch
        {
            // ignore - 客户端可能已断开
            try { ctx.Response.Close(); } catch { }
        }
    }

    private static string? FindBrowser()
    {
        string[] candidates =
        {
            @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
            @"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        };
        foreach (var c in candidates)
            if (File.Exists(c)) return c;

        // 回退：从注册表找 Edge
        try
        {
            var reg = Microsoft.Win32.Registry.LocalMachine
                .OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe");
            var v = reg?.GetValue("") as string;
            if (!string.IsNullOrEmpty(v) && File.Exists(v)) return v;
        }
        catch { }
        return null;
    }

    private static void MessageBox(string text, string caption)
    {
        // 不依赖 System.Windows.Forms，用原生 MessageBox
        MessageBoxW(IntPtr.Zero, text, caption, 0x00000010 | 0x00001000); // MB_ICONERROR | MB_SYSTEMMODAL
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}

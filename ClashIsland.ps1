# ClashIsland - Clash Verge 桌面悬浮岛
# 通过 Clash 核心 (mihomo) 的命名管道 API 实时显示节点 / 速度 / 连接数
# 悬停 2 秒弹出线路切换菜单; 断网时红色呼吸警告
# 运行: powershell -NoProfile -ExecutionPolicy Bypass -STA -File ClashIsland.ps1
# 诊断: 加 -Diag 参数只测试 API 连接, 不显示界面

param([switch]$Diag)

$ErrorActionPreference = 'Stop'
$script:Dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile   = Join-Path $script:Dir 'ClashIsland.log'
$script:StateFile = Join-Path $script:Dir 'state.json'

function Log($msg) {
    try {
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 524288) {
            Remove-Item $script:LogFile -Force
        }
        Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

# ---------- 从 Clash Verge 运行时配置读取管道名和密钥 ----------
$pipeName = 'verge-mihomo'
$secret   = 'set-your-secret'
$runtimeCfg = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
if (Test-Path $runtimeCfg) {
    $m = Select-String -Path $runtimeCfg -Pattern '^secret:\s*(.+)$' | Select-Object -First 1
    if ($m) { $secret = $m.Matches[0].Groups[1].Value.Trim().Trim("'").Trim('"') }
    $m = Select-String -Path $runtimeCfg -Pattern '^external-controller-pipe:\s*\\\\\.\\pipe\\(\S+)' | Select-Object -First 1
    if ($m) { $pipeName = $m.Matches[0].Groups[1].Value.Trim() }
}

# ---------- C# 辅助类: 通过命名管道发 HTTP 请求 (含 chunked 解码) ----------
Add-Type -ReferencedAssemblies 'System.dll','System.Core.dll' -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ClashPipe
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WaitNamedPipe(string name, int timeout);

    // 快速探测管道是否存在, 避免 .NET Connect 在管道消失时忙等烧 CPU
    public static void EnsurePipe(string pipeName)
    {
        if (!WaitNamedPipe("\\\\.\\pipe\\" + pipeName, 1))
            throw new IOException("named pipe not available: " + pipeName);
    }

    public static string Get(string pipeName, string path, string secret, int timeoutMs)
    {
        return Request(pipeName, "GET", path, secret, null, timeoutMs);
    }

    public static string Request(string pipeName, string method, string path, string secret, string body, int timeoutMs)
    {
        EnsurePipe(pipeName);
        byte[] bodyBytes = body == null ? new byte[0] : Encoding.UTF8.GetBytes(body);
        byte[] data;
        using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
        {
            pipe.Connect(timeoutMs);
            StringBuilder sb = new StringBuilder();
            sb.Append(method).Append(' ').Append(path).Append(" HTTP/1.1\r\n");
            sb.Append("Host: localhost\r\n");
            sb.Append("Authorization: Bearer ").Append(secret).Append("\r\n");
            if (bodyBytes.Length > 0)
            {
                sb.Append("Content-Type: application/json\r\n");
                sb.Append("Content-Length: ").Append(bodyBytes.Length).Append("\r\n");
            }
            sb.Append("Connection: close\r\n\r\n");
            byte[] head = Encoding.ASCII.GetBytes(sb.ToString());
            pipe.Write(head, 0, head.Length);
            if (bodyBytes.Length > 0) pipe.Write(bodyBytes, 0, bodyBytes.Length);
            pipe.Flush();
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[65536];
                int n;
                while ((n = pipe.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                data = ms.ToArray();
            }
        }
        int sep = FindHeaderEnd(data);
        if (sep < 0) throw new InvalidDataException("Malformed HTTP response");
        string headers = Encoding.ASCII.GetString(data, 0, sep);
        int eol = headers.IndexOf("\r\n");
        string status = eol > 0 ? headers.Substring(0, eol) : headers;
        string[] parts = status.Split(' ');
        if (parts.Length < 2 || !parts[1].StartsWith("2"))
            throw new InvalidDataException("HTTP error: " + status);
        int bodyStart = sep + 4;
        byte[] respBody;
        if (headers.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
            respBody = Dechunk(data, bodyStart);
        else
        {
            respBody = new byte[data.Length - bodyStart];
            Array.Copy(data, bodyStart, respBody, 0, respBody.Length);
        }
        return Encoding.UTF8.GetString(respBody);
    }

    private static int FindHeaderEnd(byte[] d)
    {
        for (int i = 0; i + 3 < d.Length; i++)
            if (d[i] == 13 && d[i+1] == 10 && d[i+2] == 13 && d[i+3] == 10) return i;
        return -1;
    }

    private static byte[] Dechunk(byte[] d, int pos)
    {
        using (MemoryStream outMs = new MemoryStream())
        {
            int i = pos;
            while (i < d.Length)
            {
                int j = i;
                while (j + 1 < d.Length && !(d[j] == 13 && d[j+1] == 10)) j++;
                if (j + 1 >= d.Length) break;
                string hex = Encoding.ASCII.GetString(d, i, j - i).Split(';')[0].Trim();
                if (hex.Length == 0) break;
                int size = Convert.ToInt32(hex, 16);
                if (size == 0) break;
                if (j + 2 + size > d.Length) size = d.Length - j - 2;
                outMs.Write(d, j + 2, size);
                i = j + 2 + size + 2;
            }
            return outMs.ToArray();
        }
    }
}

// 后台监控: 编译型线程替代 PowerShell runspace, 大幅降低内存与 GC 压力
public static class ClashMonitor
{
    private static string _pipe, _secret, _testPath, _groupPath;
    private static volatile bool _run;
    private static volatile bool _netTestNow, _groupTestNow;
    private static byte[] _connBuf = new byte[262144];

    public static volatile bool Ok;
    public static volatile bool NetOk = true;
    public static volatile int Up;
    public static volatile int Down;
    public static volatile int Count;
    public static volatile string Node = "";
    public static volatile string Mode = "";
    public static volatile string Err = "";
    public static volatile bool GroupTesting;
    public static volatile string DelaysJson = "";
    public static volatile int DelaysVer;

    public static void Start(string pipeName, string secret, string testPath, string groupPath)
    {
        _pipe = pipeName; _secret = secret; _testPath = testPath; _groupPath = groupPath;
        _run = true;
        Thread t1 = new Thread(DataLoop); t1.IsBackground = true; t1.Start();
        Thread t2 = new Thread(NetLoop);  t2.IsBackground = true; t2.Start();
    }

    public static void Stop() { _run = false; }
    public static void RequestNetTest() { _netTestNow = true; }
    public static void RequestGroupTest() { _groupTestNow = true; }

    // ---- 线程1: /traffic 流式推送 (每秒约 30 字节) + 每 5 秒辅助信息 ----
    private static void DataLoop()
    {
        while (_run)
        {
            try { StreamTraffic(); }
            catch (Exception ex) { Err = ex.Message; }
            Ok = false;
            if (!_run) break;
            Thread.Sleep(2500);
        }
    }

    private static void StreamTraffic()
    {
        ClashPipe.EnsurePipe(_pipe);
        using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", _pipe, PipeDirection.InOut))
        {
            pipe.Connect(1500);
            byte[] req = Encoding.ASCII.GetBytes("GET /traffic HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + _secret + "\r\n\r\n");
            pipe.Write(req, 0, req.Length);
            pipe.Flush();
            BufferedStream bs = new BufferedStream(pipe, 8192);
            byte[] line = new byte[1024];
            int len = ReadLine(bs, line);
            if (len < 12 || FindSub(line, len, " 200") < 0) throw new IOException("HTTP error on /traffic");
            while (true) { len = ReadLine(bs, line); if (len < 0) throw new IOException("EOF in headers"); if (len <= 1) break; }
            int tick = 0;
            while (_run)
            {
                len = ReadLine(bs, line);
                if (len < 0) throw new IOException("traffic stream closed");
                if (len == 0 || line[0] != (byte)'{') continue;
                long up = ScanLong(line, len, "\"up\":");
                long down = ScanLong(line, len, "\"down\":");
                if (up >= 0) Up = up > int.MaxValue ? int.MaxValue : (int)up;
                if (down >= 0) Down = down > int.MaxValue ? int.MaxValue : (int)down;
                Ok = true;
                Err = "";
                if (tick % 5 == 0) SideFetch();
                tick++;
            }
        }
    }

    // 连接数(字节级扫描, 复用缓冲区) + 模式/节点
    private static void SideFetch()
    {
        try
        {
            int n = FetchInto("/connections");
            Count = CountSub(_connBuf, n, "\"id\":\"");
            string cfg = ClashPipe.Get(_pipe, "/configs", _secret, 1500);
            string mode = ExtractString(cfg, "\"mode\":\"");
            if (mode != null) Mode = mode.ToLowerInvariant();
            if (Mode == "global")
            {
                string g = ClashPipe.Get(_pipe, "/proxies/GLOBAL", _secret, 1500);
                string now = ExtractString(g, "\"now\":\"");
                if (now != null) Node = now;
            }
        }
        catch { }
    }

    // ---- 线程2: 连通性测试 + 全组测速 ----
    private static void NetLoop()
    {
        int failCount = 0;
        int wait = 0;
        while (_run)
        {
            if (_groupTestNow)
            {
                _groupTestNow = false;
                GroupTesting = true;
                try { DelaysJson = ClashPipe.Get(_pipe, _groupPath, _secret, 25000); DelaysVer++; }
                catch { }
                GroupTesting = false;
            }
            if (wait <= 0 || _netTestNow)
            {
                _netTestNow = false;
                try
                {
                    ClashPipe.Get(_pipe, _testPath, _secret, 7000);
                    failCount = 0;
                    NetOk = true;
                    wait = 10;
                }
                catch
                {
                    failCount++;
                    if (failCount >= 2) NetOk = false;
                    wait = 5;
                }
            }
            Thread.Sleep(1000);
            wait--;
        }
    }

    // ---- 内存修剪: GC + 大对象堆压缩 + 归还工作集 ----
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool SetProcessWorkingSetSize(IntPtr h, IntPtr min, IntPtr max);

    // 轻量修剪: 只归还工作集, 不触发 GC (适合高频调用)
    public static void TrimWorkingSet()
    {
        SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1L), (IntPtr)(-1L));
    }

    public static void TrimMemory()
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1L), (IntPtr)(-1L));
    }

    // ---- 工具函数 (零字符串分配的字节级解析) ----
    private static int ReadLine(Stream s, byte[] buf)
    {
        int i = 0;
        while (true)
        {
            int b = s.ReadByte();
            if (b < 0) return i > 0 ? i : -1;
            if (b == 10) return i;
            if (i < buf.Length) buf[i++] = (byte)b;
        }
    }

    private static int FetchInto(string path)
    {
        ClashPipe.EnsurePipe(_pipe);
        using (NamedPipeClientStream p = new NamedPipeClientStream(".", _pipe, PipeDirection.InOut))
        {
            p.Connect(1500);
            byte[] rb = Encoding.ASCII.GetBytes("GET " + path + " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + _secret + "\r\nConnection: close\r\n\r\n");
            p.Write(rb, 0, rb.Length);
            p.Flush();
            int total = 0;
            int n;
            while ((n = p.Read(_connBuf, total, _connBuf.Length - total)) > 0)
            {
                total += n;
                if (total == _connBuf.Length)
                {
                    byte[] nb = new byte[_connBuf.Length * 2];
                    Array.Copy(_connBuf, nb, total);
                    _connBuf = nb;
                }
            }
            return total;
        }
    }

    private static int FindSub(byte[] b, int len, string pat)
    {
        int m = pat.Length;
        for (int i = 0; i + m <= len; i++)
        {
            bool hit = true;
            for (int j = 0; j < m; j++) if (b[i + j] != (byte)pat[j]) { hit = false; break; }
            if (hit) return i;
        }
        return -1;
    }

    private static int CountSub(byte[] b, int len, string pat)
    {
        int cnt = 0;
        int m = pat.Length;
        for (int i = 0; i + m <= len; i++)
        {
            bool hit = true;
            for (int j = 0; j < m; j++) if (b[i + j] != (byte)pat[j]) { hit = false; break; }
            if (hit) { cnt++; i += m - 1; }
        }
        return cnt;
    }

    private static long ScanLong(byte[] b, int len, string key)
    {
        int i = FindSub(b, len, key);
        if (i < 0) return -1;
        i += key.Length;
        long v = 0;
        bool any = false;
        while (i < len && b[i] >= (byte)'0' && b[i] <= (byte)'9') { v = v * 10 + (b[i] - (byte)'0'); i++; any = true; }
        return any ? v : -1;
    }

    private static string ExtractString(string s, string key)
    {
        int i = s.IndexOf(key);
        if (i < 0) return null;
        i += key.Length;
        int j = s.IndexOf('"', i);
        if (j < 0) return null;
        return s.Substring(i, j - i);
    }
}
'@

$TestUrlPath = '/proxies/GLOBAL/delay?timeout=4000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'
$GroupTestPath = '/group/GLOBAL/delay?timeout=3000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204'

# ---------- 诊断模式 ----------
if ($Diag) {
    Write-Output "管道: $pipeName  密钥: $secret"
    $v = [ClashPipe]::Get($pipeName, '/version', $secret, 2000)
    Write-Output "版本: $v"
    $c = [ClashPipe]::Get($pipeName, '/connections', $secret, 2000)
    $down = [regex]::Match($c, '"downloadTotal":(\d+)').Groups[1].Value
    $up   = [regex]::Match($c, '"uploadTotal":(\d+)').Groups[1].Value
    $cnt  = ([regex]::Matches($c, '"id":"')).Count
    Write-Output "总下载: $down  总上传: $up  连接数: $cnt"
    $cfg = [ClashPipe]::Get($pipeName, '/configs', $secret, 2000) | ConvertFrom-Json
    Write-Output "模式: $($cfg.mode)"
    $g = [ClashPipe]::Get($pipeName, '/proxies/GLOBAL', $secret, 2000) | ConvertFrom-Json
    Write-Output "当前节点: $($g.now)"
    try {
        $d = [ClashPipe]::Get($pipeName, $TestUrlPath, $secret, 6000)
        Write-Output "连通性测试: $d"
    } catch {
        Write-Output "连通性测试失败: $($_.Exception.Message)"
    }
    Write-Output "启动后台监控线程测试 (7秒)..."
    [ClashMonitor]::Start($pipeName, $secret, $TestUrlPath, $GroupTestPath)
    Start-Sleep -Seconds 7
    Write-Output ("Monitor: ok=" + [ClashMonitor]::Ok + " net=" + [ClashMonitor]::NetOk + " up=" + [ClashMonitor]::Up + " down=" + [ClashMonitor]::Down + " cnt=" + [ClashMonitor]::Count + " mode=" + [ClashMonitor]::Mode + " node=" + [ClashMonitor]::Node + " err=" + [ClashMonitor]::Err)
    [ClashMonitor]::Stop()
    exit 0
}

# ---------- 单实例 ----------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ClashIslandWidget')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0, $false) } catch { $owned = $true }
if (-not $owned) { Log '已有实例在运行, 退出'; exit 0 }

Log "启动. 管道=$pipeName"

try {

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Web.Extensions
$script:Json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Json.MaxJsonLength = 33554432

# ---------- 启动 C# 后台监控线程 (无 PowerShell runspace, 低内存) ----------
$script:cfg = @{ pipe = $pipeName; secret = $secret }
[ClashMonitor]::Start($pipeName, $secret, $TestUrlPath, $GroupTestPath)

# ---------- 界面 ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ClashIsland" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        ShowActivated="False">
  <Border x:Name="Pill" CornerRadius="17" Background="#E61B2030" BorderBrush="#2EFFFFFF"
          BorderThickness="1" Padding="14,7,14,8" Margin="12" Cursor="Hand">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45"/>
    </Border.Effect>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Ellipse x:Name="Dot" Width="9" Height="9" Fill="#666666" VerticalAlignment="Center" Margin="0,1,9,0"/>
      <TextBlock x:Name="NodeText" Text="连接中…" Foreground="#EAF0F8" FontSize="13"
                 FontFamily="Microsoft YaHei UI" VerticalAlignment="Center"
                 MaxWidth="150" TextTrimming="CharacterEllipsis"/>
      <Rectangle Width="1" Height="14" Fill="#26FFFFFF" Margin="11,0,11,0" VerticalAlignment="Center"/>
      <TextBlock Text="&#8595;" Foreground="#4ADE80" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,3,0"/>
      <TextBlock x:Name="DownText" Text="--" Foreground="#EAF0F8" FontSize="13"
                 FontFamily="Microsoft YaHei UI" VerticalAlignment="Center" MinWidth="66"/>
      <TextBlock Text="&#8593;" Foreground="#FBBF24" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" Margin="4,0,3,0"/>
      <TextBlock x:Name="UpText" Text="--" Foreground="#EAF0F8" FontSize="13"
                 FontFamily="Microsoft YaHei UI" VerticalAlignment="Center" MinWidth="60"/>
      <TextBlock x:Name="CntText" Text="" Foreground="#8B98AC" FontSize="12"
                 FontFamily="Microsoft YaHei UI" VerticalAlignment="Center" Margin="4,0,0,0" MinWidth="30"/>
    </StackPanel>
  </Border>
</Window>
'@

$script:window   = [System.Windows.Markup.XamlReader]::Parse($xaml)
$script:Pill     = $script:window.FindName('Pill')
$script:Dot      = $script:window.FindName('Dot')
$script:NodeText = $script:window.FindName('NodeText')
$script:DownText = $script:window.FindName('DownText')
$script:UpText   = $script:window.FindName('UpText')
$script:CntText  = $script:window.FindName('CntText')
$script:Shadow   = $script:Pill.Effect

function New-Brush($hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object System.Windows.Media.SolidColorBrush($c)
    $b.Freeze()
    return $b
}
$script:GreenBrush  = New-Brush '#4ADE80'
$script:RedBrush    = New-Brush '#F87171'
$script:TextBrush   = New-Brush '#EAF0F8'
$script:GrayBrush   = New-Brush '#8B98AC'
$script:HoverBrush  = New-Brush '#2BFFFFFF'
$script:AmberBrush  = New-Brush '#FBBF24'
$script:AccentBrush = New-Brush '#7DD3FC'
$script:PillBgNorm  = New-Brush '#E61B2030'
$script:RedTextBrush = New-Brush '#FECACA'
$script:BorderNorm  = New-Brush '#2EFFFFFF'
$script:BorderWarn  = New-Brush '#90F87171'

function Format-Speed([double]$b) {
    if ($b -ge 1073741824) { return ('{0:N2} GB/s' -f ($b / 1073741824)) }
    if ($b -ge 1048576)    { return ('{0:N1} MB/s' -f ($b / 1048576)) }
    if ($b -ge 1024)       { return ('{0:N0} KB/s' -f ($b / 1024)) }
    return ('{0:N0} B/s' -f $b)
}

function Format-Delay([int]$d) {
    if ($d -le 0) { return '--' }
    return "${d}ms"
}

function Get-DelayBrush([int]$d) {
    if ($d -le 0) { return $script:GrayBrush }
    if ($d -lt 200) { return $script:GreenBrush }
    if ($d -lt 500) { return $script:AmberBrush }
    return $script:RedBrush
}

function Save-State {
    try {
        @{ left = $script:window.Left; top = $script:restTop } |
            ConvertTo-Json -Compress | Set-Content -Path $script:StateFile -Encoding ASCII
    } catch {}
}

function Open-ClashVerge {
    try {
        $exe = $null
        $cim = Get-CimInstance Win32_Process -Filter "Name='clash-verge.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cim -and $cim.ExecutablePath) { $exe = $cim.ExecutablePath }
        if (-not $exe) {
            $candidates = @(
                (Join-Path $env:ProgramFiles 'Clash Verge\clash-verge.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge\clash-verge.exe'),
                (Join-Path $env:LOCALAPPDATA 'Clash Verge\clash-verge.exe')
            )
            $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if ($exe) { Start-Process -FilePath $exe } else { Log '未找到 clash-verge.exe' }
    } catch { Log "打开 Clash Verge 失败: $_" }
}

# ---------- 红色呼吸警告 ----------
$script:warnState = $false
$script:WarnBg = $null

function New-PulseAnim([double]$from, [double]$to) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(900))))
    $a.AutoReverse = $true
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $a.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    return $a
}

function Set-Warn([bool]$on) {
    if ($on -eq $script:warnState) { return }
    $script:warnState = $on
    if ($on) {
        $script:Pill.BorderBrush = $script:BorderWarn
        # 红色光晕: 阴影变红, 亮度和扩散半径同步呼吸
        $script:Shadow.Color = [System.Windows.Media.Color]::FromRgb(0xF8, 0x71, 0x71)
        $script:Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-PulseAnim 1.0 0.25))
        $script:Shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, (New-PulseAnim 0.45 0.95))
        $script:Shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, (New-PulseAnim 12.0 26.0))
        # 整岛背景在深色与暗红之间弥散渐变
        $cFrom = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#E61B2030')
        $cTo   = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#F05F1F2D')
        $script:WarnBg = New-Object System.Windows.Media.SolidColorBrush($cFrom)
        $script:Pill.Background = $script:WarnBg
        $ca = New-Object System.Windows.Media.Animation.ColorAnimation($cFrom, $cTo, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(900))))
        $ca.AutoReverse = $true
        $ca.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $ca.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
        $script:WarnBg.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        $script:idleTimer.Stop()
        Expand-Island
    } else {
        $script:Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $script:Shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)
        $script:Shadow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $null)
        if ($script:WarnBg) {
            $script:WarnBg.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
            $script:WarnBg = $null
        }
        $script:Pill.Background = $script:PillBgNorm
        $script:Dot.Opacity = 1.0
        $script:Shadow.Opacity = 0.45
        $script:Shadow.BlurRadius = 14
        $script:Shadow.Color = [System.Windows.Media.Colors]::Black
        $script:Pill.BorderBrush = $script:BorderNorm
        $script:idleTimer.Stop()
        $script:idleTimer.Start()
    }
}

# ---------- 边缘躲藏: 平时缩进屏幕顶部只露一条边, 鼠标碰到弹出 ----------
$script:rowDelayMap   = @{}
$script:delaysShown   = 0
$script:lastGroupTest = [DateTime]::MinValue
$script:coreDownSince = $null
$script:hiddenByCore  = $false
$script:lastNodeRaw      = ''
$script:lastNodeStripped = ''
$script:memTick          = 280
$script:restTop   = 8.0
$script:peekMode  = $true
$script:collapsed = $false

$script:animTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:animTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$script:animStart = 0.0; $script:animTarget = 0.0; $script:animT0 = [DateTime]::Now
$script:animTimer.Add_Tick({
    $p = ([DateTime]::Now - $script:animT0).TotalSeconds / 0.25
    if ($p -ge 1) {
        $script:window.Top = $script:animTarget
        $script:animTimer.Stop()
        return
    }
    $ease = 1 - [Math]::Pow(1 - $p, 3)
    $script:window.Top = $script:animStart + ($script:animTarget - $script:animStart) * $ease
})

function Start-TopAnim([double]$target) {
    $script:animStart  = $script:window.Top
    $script:animTarget = $target
    $script:animT0     = [DateTime]::Now
    $script:animTimer.Start()
}

function Update-PeekMode {
    # 只有小岛靠近屏幕顶部时才启用躲藏效果
    $script:peekMode = ($script:restTop -ge -40 -and $script:restTop -le 60)
}

function Expand-Island {
    if (-not $script:collapsed) { return }
    $script:collapsed = $false
    Start-TopAnim $script:restTop
}

function Collapse-Island {
    if ($script:collapsed) { return }
    if (-not $script:peekMode) { return }
    if ($script:warnState) { return }
    if ($script:Pill.IsMouseOver) { return }
    if ($script:NodePopup.IsOpen) { $script:idleTimer.Stop(); $script:idleTimer.Start(); return }
    $script:collapsed = $true
    # 窗口内容边距 12px, 收起后让药丸露出约 7px
    Start-TopAnim (7.0 - 12.0 - $script:Pill.ActualHeight)
}

# 鼠标离开后立即收起 (留 0.4 秒缓冲防抖; 启动时首次展示 3 秒)
$script:idleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:idleTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:idleTimer.Add_Tick({
    $script:idleTimer.Stop()
    $script:idleTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    Collapse-Island
})

# ---------- 线路切换弹出菜单 ----------
$script:NodePopup = New-Object System.Windows.Controls.Primitives.Popup
$script:NodePopup.AllowsTransparency = $true
$script:NodePopup.StaysOpen = $true
$script:NodePopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
$script:NodePopup.PlacementTarget = $script:Pill
$script:NodePopup.VerticalOffset = 0
$script:NodePopup.PopupAnimation = [System.Windows.Controls.Primitives.PopupAnimation]::Fade

$popupBorder = New-Object System.Windows.Controls.Border
$popupBorder.CornerRadius = New-Object System.Windows.CornerRadius(12)
$popupBorder.Background = New-Brush '#F2161B28'
$popupBorder.BorderBrush = $script:BorderNorm
$popupBorder.BorderThickness = New-Object System.Windows.Thickness(1)
$popupBorder.Padding = New-Object System.Windows.Thickness(6)
$popupBorder.Margin = New-Object System.Windows.Thickness(10)
$popupBorder.Width = 272
$popupShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$popupShadow.BlurRadius = 14; $popupShadow.ShadowDepth = 2; $popupShadow.Opacity = 0.5
$popupBorder.Effect = $popupShadow
$script:PopupBorder = $popupBorder

$popupStack = New-Object System.Windows.Controls.StackPanel
$popupHeader = New-Object System.Windows.Controls.DockPanel
$popupHeader.Margin = New-Object System.Windows.Thickness(10, 4, 10, 5)
$popupTitle = New-Object System.Windows.Controls.TextBlock
$popupTitle.Text = '切换线路'
$popupTitle.Foreground = $script:GrayBrush
$popupTitle.FontSize = 11
$popupTitle.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$script:SpeedBtn = New-Object System.Windows.Controls.TextBlock
$script:SpeedBtn.Text = '测速'
$script:SpeedBtn.Foreground = $script:AccentBrush
$script:SpeedBtn.FontSize = 11
$script:SpeedBtn.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$script:SpeedBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($script:SpeedBtn, [System.Windows.Controls.Dock]::Right)
$script:SpeedBtn.Add_MouseLeftButtonUp({
    if (-not [ClashMonitor]::GroupTesting) {
        $script:lastGroupTest = Get-Date
        [ClashMonitor]::RequestGroupTest()
    }
})
[void]$popupHeader.Children.Add($script:SpeedBtn)
[void]$popupHeader.Children.Add($popupTitle)
[void]$popupStack.Children.Add($popupHeader)

$script:NodeScroll = New-Object System.Windows.Controls.ScrollViewer
$script:NodeScroll.MaxHeight = 320
$script:NodeScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
$script:NodeList = New-Object System.Windows.Controls.StackPanel
$script:NodeList.Margin = New-Object System.Windows.Thickness(0, 0, 3, 0)
$script:NodeScroll.Content = $script:NodeList

# 极简滚动条: 6px 半透明圆角细条, 悬停/拖动时变亮
$sbStyle = [System.Windows.Markup.XamlReader]::Parse(@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
       xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
       TargetType="{x:Type ScrollBar}">
  <Setter Property="Width" Value="6"/>
  <Setter Property="MinWidth" Value="6"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="{x:Type ScrollBar}">
        <Grid Background="Transparent" Width="6">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="{x:Type Thumb}">
                    <Border x:Name="ThumbBar" Background="#26FFFFFF" CornerRadius="3" Margin="1,0,1,0"/>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="ThumbBar" Property="Background" Value="#55FFFFFF"/>
                      </Trigger>
                      <Trigger Property="IsDragging" Value="True">
                        <Setter TargetName="ThumbBar" Property="Background" Value="#77FFFFFF"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@)
$script:NodeScroll.Resources.Add([System.Windows.Controls.Primitives.ScrollBar], $sbStyle)
[void]$popupStack.Children.Add($script:NodeScroll)

$popupBorder.Child = $popupStack
$script:NodePopup.Child = $popupBorder

# 行点击 -> 切换节点
$script:onRowClick = {
    param($s, $e)
    $name = [string]$s.Tag
    try {
        $body = '{"name":' + (ConvertTo-Json $name) + '}'
        [void][ClashPipe]::Request($script:cfg.pipe, 'PUT', '/proxies/GLOBAL', $script:cfg.secret, $body, 2500)
        [ClashMonitor]::Node = $name
        [ClashMonitor]::RequestNetTest()
        $script:NodeText.Text = ($name -replace '[\uD83C][\uDDE6-\uDDFF]', '').Trim()
        Log "切换节点: $name"
    } catch {
        Log "切换节点失败: $($_.Exception.Message)"
    }
    $script:NodePopup.IsOpen = $false
}
$script:onRowEnter = { param($s, $e) $s.Background = $script:HoverBrush }
$script:onRowLeave = { param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent }

function Open-NodeMenu {
    if ($script:NodePopup.IsOpen) { return }
    if (-not [ClashMonitor]::Ok) { return }
    $groupTypes = @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Direct', 'Reject', 'RejectDrop', 'Pass', 'Compatible', 'DNS')
    try {
        $g = $script:Json.DeserializeObject([ClashPipe]::Get($script:cfg.pipe, '/proxies/GLOBAL', $script:cfg.secret, 2500))
        $all = @($g['all'])
        $now = [string]$g['now']
        $p = $script:Json.DeserializeObject([ClashPipe]::Get($script:cfg.pipe, '/proxies', $script:cfg.secret, 4000))
        $proxies = $p['proxies']
    } catch {
        Log "节点菜单加载失败: $($_.Exception.Message)"
        return
    }
    $script:NodeList.Children.Clear()
    $script:curRow = $null
    $script:rowDelayMap = @{}
    foreach ($n in $all) {
        $t = ''
        $delay = -1
        if ($proxies.ContainsKey($n)) {
            $pd = $proxies[$n]
            $t = [string]$pd['type']
            if ($pd.ContainsKey('history')) {
                $hist = @($pd['history'])
                if ($hist.Count -gt 0) {
                    $last = $hist[$hist.Count - 1]
                    if ($last -and $last.ContainsKey('delay')) { $delay = [int]$last['delay'] }
                }
            }
        }
        if ($groupTypes -contains $t) { continue }
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $row.Padding = New-Object System.Windows.Thickness(10, 5, 10, 5)
        $row.Background = [System.Windows.Media.Brushes]::Transparent
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Tag = $n
        $grid = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($c1)
        [void]$grid.ColumnDefinitions.Add($c2)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = ($n -replace '[\uD83C][\uDDE6-\uDDFF]', '').Trim()
        $tb.FontSize = 12.5
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
        $tb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $tb.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        if ($n -eq $now) {
            $tb.Text = [char]0x25CF + ' ' + $tb.Text
            $tb.Foreground = $script:GreenBrush
            $tb.FontWeight = [System.Windows.FontWeights]::Bold
            $script:curRow = $row
        } else {
            $tb.Foreground = $script:TextBrush
        }
        $dl = New-Object System.Windows.Controls.TextBlock
        $dl.Text = Format-Delay $delay
        $dl.Foreground = Get-DelayBrush $delay
        $dl.FontSize = 11.5
        $dl.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $dl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.Grid]::SetColumn($tb, 0)
        [System.Windows.Controls.Grid]::SetColumn($dl, 1)
        [void]$grid.Children.Add($tb)
        [void]$grid.Children.Add($dl)
        $script:rowDelayMap[$n] = $dl
        $row.Child = $grid
        $row.Add_MouseEnter($script:onRowEnter)
        $row.Add_MouseLeave($script:onRowLeave)
        $row.Add_MouseLeftButtonUp($script:onRowClick)
        [void]$script:NodeList.Children.Add($row)
    }
    if ($script:NodeList.Children.Count -eq 0) { return }
    $script:NodePopup.IsOpen = $true
    $script:closeTimer.Start()
    if (((Get-Date) - $script:lastGroupTest).TotalSeconds -gt 120) {
        $script:lastGroupTest = Get-Date
        [ClashMonitor]::RequestGroupTest()
    }
    $script:window.Dispatcher.BeginInvoke(
        [action] { if ($script:curRow) { $script:curRow.BringIntoView() } },
        [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# 悬停 2 秒打开菜单
$script:hoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:hoverTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:hoverTimer.Add_Tick({
    $script:hoverTimer.Stop()
    if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
    if ($script:Pill.IsMouseOver) { Open-NodeMenu }
})

# 鼠标同时离开小岛和菜单 -> 自动关闭
$script:closeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:closeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:closeTimer.Add_Tick({
    if (-not $script:NodePopup.IsOpen) { $script:closeTimer.Stop(); return }
    if (-not $script:Pill.IsMouseOver -and -not $script:PopupBorder.IsMouseOver) {
        $script:NodePopup.IsOpen = $false
        $script:closeTimer.Stop()
    }
})

$script:Pill.Add_MouseEnter({
    $script:idleTimer.Stop()
    Expand-Island
    if (-not $script:NodePopup.IsOpen) { $script:hoverTimer.Start() }
})
$script:Pill.Add_MouseLeave({
    $script:hoverTimer.Stop()
    $script:idleTimer.Stop()
    $script:idleTimer.Start()
})

# 恢复上次位置 (并确保仍在屏幕范围内)
$script:havePos = $false
if (Test-Path $script:StateFile) {
    try {
        $st = Get-Content $script:StateFile -Raw | ConvertFrom-Json
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
        $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($st.left -ge ($vl - 50) -and $st.left -le ($vl + $vw - 80) -and
            $st.top  -ge ($vt - 10) -and $st.top  -le ($vt + $vh - 40)) {
            $script:window.Left = [double]$st.left
            $script:window.Top  = [double]$st.top
            $script:restTop = [double]$st.top
            $script:havePos = $true
        }
    } catch {}
}

$script:window.Add_ContentRendered({
    if (-not $script:havePos) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:window.Left = $wa.Left + ($wa.Width - $script:window.ActualWidth) / 2
        $script:window.Top  = $wa.Top + 8
    }
    $script:restTop = $script:window.Top
    Update-PeekMode
    $script:idleTimer.Start()
})

# 拖动 + 双击打开 Clash Verge
$script:Pill.Add_MouseLeftButtonDown({
    param($s, $e)
    $script:hoverTimer.Stop()
    if ($script:animTimer.IsEnabled) { $script:animTimer.Stop(); $script:window.Top = $script:animTarget }
    if ($script:collapsed) { $script:collapsed = $false; $script:window.Top = $script:restTop; return }
    if ($e.ClickCount -ge 2) { Open-ClashVerge; return }
    $script:NodePopup.IsOpen = $false
    try {
        $script:window.DragMove()
        $script:restTop = $script:window.Top
        Update-PeekMode
        Save-State
        $script:idleTimer.Stop()
        $script:idleTimer.Start()
    } catch {}
})

# 右键菜单
$menu = New-Object System.Windows.Controls.ContextMenu
$miOpen  = New-Object System.Windows.Controls.MenuItem; $miOpen.Header  = '打开 Clash Verge'
$miNodes = New-Object System.Windows.Controls.MenuItem; $miNodes.Header = '切换线路'
$miReset = New-Object System.Windows.Controls.MenuItem; $miReset.Header = '重置位置'
$miExit  = New-Object System.Windows.Controls.MenuItem; $miExit.Header  = '退出悬浮岛'
[void]$menu.Items.Add($miOpen)
[void]$menu.Items.Add($miNodes)
[void]$menu.Items.Add($miReset)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($miExit)
$script:Pill.ContextMenu = $menu

$miOpen.Add_Click({ Open-ClashVerge })
$miNodes.Add_Click({ Open-NodeMenu })
$miReset.Add_Click({
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:window.Left = $wa.Left + ($wa.Width - $script:window.ActualWidth) / 2
    $script:window.Top  = $wa.Top + 8
    $script:restTop = $wa.Top + 8
    $script:collapsed = $false
    Update-PeekMode
    Save-State
})
$miExit.Add_Click({
    # 手动退出标记: 看门狗在本次 Clash 会话内不再拉起悬浮岛
    try { Set-Content -Path (Join-Path $script:Dir '.manual-exit') -Value 'user exited' -Encoding ASCII } catch {}
    Log '用户手动退出'
    $script:window.Close()
})

# ---------- 每秒刷新界面 ----------
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$script:timer.Add_Tick({
    $ok = [ClashMonitor]::Ok
    $net = [ClashMonitor]::NetOk
    # 跟随 Clash 客户端: 关闭超过 8 秒自动隐身, 重新打开自动现身
    if ($ok) {
        $script:coreDownSince = $null
        if ($script:hiddenByCore) {
            $script:hiddenByCore = $false
            $script:collapsed = $false
            $script:window.Top = $script:restTop
            $script:window.Show()
            $script:idleTimer.Stop()
            $script:idleTimer.Interval = [TimeSpan]::FromSeconds(3)
            $script:idleTimer.Start()
            Log 'Clash 已回来, 悬浮岛现身'
        }
    } else {
        if (-not $script:coreDownSince) { $script:coreDownSince = Get-Date }
        if (-not $script:hiddenByCore -and ((Get-Date) - $script:coreDownSince).TotalSeconds -gt 8) {
            $script:hiddenByCore = $true
            $script:NodePopup.IsOpen = $false
            Set-Warn $false
            $script:idleTimer.Stop()
            $script:animTimer.Stop()
            $script:window.Hide()
            Log 'Clash 已关闭, 悬浮岛隐身等待'
            [ClashMonitor]::TrimMemory()
        }
        if ($script:hiddenByCore) { return }
    }
    $warn = (-not $ok) -or (-not $net)
    Set-Warn $warn
    # 收起状态下界面不可见: 跳过全部刷新, 每分钟轻量归还工作集, 保持内存冷却
    if ($script:collapsed -and -not $warn -and -not $script:Pill.IsMouseOver) {
        $script:memTick++
        if ($script:memTick -ge 300) { $script:memTick = 0; [ClashMonitor]::TrimMemory() }
        elseif ($script:memTick % 60 -eq 0) { [ClashMonitor]::TrimWorkingSet() }
        return
    }
    # 可见时才构建完整状态快照并刷新界面
    $s = @{
        ok = $ok; net = $net
        down = [double][ClashMonitor]::Down; up = [double][ClashMonitor]::Up
        cnt = [ClashMonitor]::Count; err = [ClashMonitor]::Err
        mode = [ClashMonitor]::Mode; groupTesting = [ClashMonitor]::GroupTesting
        delaysVer = [ClashMonitor]::DelaysVer
    }
    if ([ClashMonitor]::Node -cne $script:lastNodeRaw) {
        $script:lastNodeRaw = [ClashMonitor]::Node
        $script:lastNodeStripped = ($script:lastNodeRaw -replace '[\uD83C][\uDDE6-\uDDFF]', '').Trim()
    }
    $s.node = $script:lastNodeStripped
    if ($s.ok) {
        if ($warn) {
            $script:Dot.Fill = $script:RedBrush
            $script:NodeText.Foreground = $script:RedTextBrush
            $script:NodeText.Text = '网络断联'
            $script:Pill.ToolTip = "代理连通性测试失败, 当前线路可能不可用`n(悬停2秒可弹出菜单切换线路)"
        } else {
            $script:Dot.Fill = $script:GreenBrush
            $script:NodeText.Foreground = $script:TextBrush
            $name = ''
            switch ($s.mode) {
                'global' { $name = $s.node; if (-not $name) { $name = '全局模式' } }
                'rule'   { $name = '规则模式' }
                'direct' { $name = '直连模式' }
                default  { $name = $s.node; if (-not $name) { $name = 'Clash' } }
            }
            $script:NodeText.Text = $name
            $script:Pill.ToolTip = "节点: $($s.node)`n模式: $($s.mode)`n活动连接: $($s.cnt)`n(悬停2秒切换线路 / 拖动移动 / 双击打开主界面)"
        }
        $script:DownText.Text = Format-Speed $s.down
        $script:UpText.Text   = Format-Speed $s.up
        $script:CntText.Text  = "$($s.cnt)连"
    } else {
        $script:Dot.Fill = $script:RedBrush
        $script:NodeText.Foreground = $script:RedTextBrush
        $script:NodeText.Text = 'Clash 未运行'
        $script:DownText.Text = '--'
        $script:UpText.Text   = '--'
        $script:CntText.Text  = ''
        $script:Pill.ToolTip  = "无法连接 Clash 核心: $($s.err)"
    }
    if ($s.groupTesting) {
        if ($script:SpeedBtn.Text -ne '测速中…') {
            $script:SpeedBtn.Text = '测速中…'
            $script:SpeedBtn.Foreground = $script:GrayBrush
        }
    } elseif ($script:SpeedBtn.Text -ne '测速') {
        $script:SpeedBtn.Text = '测速'
        $script:SpeedBtn.Foreground = $script:AccentBrush
    }
    if ($script:NodePopup.IsOpen -and $s.delaysVer -ne $script:delaysShown) {
        $script:delaysShown = $s.delaysVer
        $d = $null
        try { $d = $script:Json.DeserializeObject([ClashMonitor]::DelaysJson) } catch {}
        if ($d) {
            foreach ($name in @($script:rowDelayMap.Keys)) {
                $tb = $script:rowDelayMap[$name]
                if ($d.ContainsKey($name)) {
                    $val = [int]$d[$name]
                    $tb.Text = Format-Delay $val
                    $tb.Foreground = Get-DelayBrush $val
                } else {
                    $tb.Text = '超时'
                    $tb.Foreground = $script:RedBrush
                }
            }
        }
    }
    # 每 5 分钟 GC + 大对象堆压缩 + 工作集修剪, 长期驻留不吃内存
    $script:memTick++
    if ($script:memTick -ge 300) {
        $script:memTick = 0
        [ClashMonitor]::TrimMemory()
    }
})
$script:timer.Start()

$script:window.Add_Closed({
    $script:timer.Stop()
    $script:hoverTimer.Stop()
    $script:closeTimer.Stop()
    $script:idleTimer.Stop()
    $script:animTimer.Stop()
    $script:NodePopup.IsOpen = $false
    [ClashMonitor]::Stop()
    Save-State
    Log '窗口关闭'
    if ($script:app) { $script:app.Shutdown() }
})

Log 'UI 显示'
# OnExplicitShutdown: 隐身(Hide)绝不会结束消息循环, 只有窗口 Closed 事件里的
# Shutdown() 才能退出程序
$script:app = New-Object System.Windows.Application
$script:app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
[void]$script:app.Run($script:window)

} catch {
    Log "FATAL: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
} finally {
    try { [ClashMonitor]::Stop() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
    Log '退出'
}

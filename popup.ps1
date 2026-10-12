# 일정 알림창: 화면 오른쪽 아래, 항상 위, 0.5초마다 깜빡임, X를 눌러야만 닫힘
# v0.50: 크기(scale, 설정 > 알림 창 크기) · [n분 뒤 다시 알림] 버튼(snooze) — 앱이 /notify JSON에 같이 보냄 (없으면 1 · 10)
param([string]$DataFile)
$errLog = Join-Path ([System.IO.Path]::GetTempPath()) 'upmu_popup_error.log'
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $raw = [System.IO.File]::ReadAllText($DataFile, [System.Text.Encoding]::UTF8)
    Remove-Item -LiteralPath $DataFile -ErrorAction SilentlyContinue
    $d = $raw | ConvertFrom-Json
    $scale = 1.0; $snooze = 10
    try { if ($d.PSObject.Properties['scale'] -and [double]$d.scale -gt 0) { $scale = [Math]::Max(0.8, [Math]::Min(2.5, [double]$d.scale)) } } catch { }
    try { if ($d.PSObject.Properties['snooze'] -and [int]$d.snooze -gt 0) { $snooze = [Math]::Min(120, [int]$d.snooze) } } catch { }

    # 알림이 여러 개면 위로 쌓이도록 자리 잡기
    $slot = 0; $mutex = $null
    for ($i = 0; $i -lt 6; $i++) {
        $m = New-Object System.Threading.Mutex($false, "Local\UpmuPopupSlot$i")
        if ($m.WaitOne(0)) { $slot = $i; $mutex = $m; break } else { $m.Dispose() }
    }

    if (-not ('UpmuAlert2' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class UpmuAlert2 : Form
{
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    readonly Label lblHead, lblTitle, lblBody;
    readonly Button btnSnooze;
    readonly Timer blink, snoozeTimer;
    readonly string head;
    readonly double k;
    readonly int slot, snoozeMin;
    bool on;
    static readonly Color Accent = Color.FromArgb(214, 72, 38);
    static readonly Color Dark = Color.FromArgb(31, 30, 29);
    static readonly Color Muted = Color.FromArgb(90, 88, 82);

    // 다른 창에서 일하던 포커스를 빼앗지 않고 맨 위에 표시
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x00000008; return cp; }   // WS_EX_TOPMOST
    }

    int S(double v) { return (int)Math.Round(v * k); }

    public UpmuAlert2(string head, string title, string body, int slot, double scale, int snoozeMin)
    {
        this.head = head; this.slot = slot; this.snoozeMin = snoozeMin; k = scale;
        Text = "일정 알림";
        FormBorderStyle = FormBorderStyle.FixedToolWindow;   // 제목줄에 X만 있음
        MaximizeBox = false; MinimizeBox = false;
        TopMost = true; ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(S(410), S(196));
        BackColor = Color.White;
        DoubleBuffered = true;

        lblHead  = MakeLabel(12, 24, 10f, true,  "[일정 알림]  " + head);
        lblTitle = MakeLabel(40, 34, 15f, true,  title);
        lblBody  = MakeLabel(80, 72, 10f, false, body);
        Controls.Add(lblHead); Controls.Add(lblTitle); Controls.Add(lblBody);

        btnSnooze = new Button();
        btnSnooze.Text = snoozeMin + "분 뒤 다시 알림";
        btnSnooze.Font = new Font("Malgun Gothic", (float)(9.5 * k), FontStyle.Regular);
        btnSnooze.Size = new Size(S(150), S(28));
        btnSnooze.Location = new Point(ClientSize.Width - btnSnooze.Width - S(18), S(158));
        btnSnooze.FlatStyle = FlatStyle.Flat;
        btnSnooze.BackColor = Color.White; btnSnooze.ForeColor = Dark;
        btnSnooze.Click += delegate { Snooze(); };
        Controls.Add(btnSnooze);

        Place();

        blink = new Timer();
        blink.Interval = 500;                                  // 0.5초마다 깜빡임
        blink.Tick += delegate { on = !on; ApplyLook(); };
        snoozeTimer = new Timer();
        snoozeTimer.Interval = Math.Max(1, snoozeMin) * 60000;
        snoozeTimer.Tick += delegate { snoozeTimer.Stop(); Wake(); };
        Shown += delegate { Ring(); };
        FormClosed += delegate { blink.Stop(); snoozeTimer.Stop(); };
    }

    void Place()
    {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.Right - Width - 12, wa.Bottom - (Height + 10) * (slot + 1));
    }

    Label MakeLabel(int y, int h, float size, bool bold, string text)
    {
        Label l = new Label();
        l.Location = new Point(S(18), S(y));
        l.Size = new Size(S(376), S(h));
        l.Font = new Font("Malgun Gothic", (float)(size * k), bold ? FontStyle.Bold : FontStyle.Regular);
        l.Text = text;
        l.AutoEllipsis = true;
        l.BackColor = Color.Transparent;
        return l;
    }

    void Ring()
    {
        ApplyLook();
        blink.Start();
        System.Media.SystemSounds.Exclamation.Play();
        FlashTaskbar();
    }

    // [n분 뒤 다시 알림]: 창을 숨겼다가 시간이 되면 같은 자리에 다시 띄움
    void Snooze()
    {
        blink.Stop(); on = false; ApplyLook();
        Hide();
        snoozeTimer.Start();
    }

    void Wake()
    {
        lblHead.Text = "[다시 알림]  " + head;
        Place();
        Show();
        Ring();
    }

    void ApplyLook()
    {
        BackColor = on ? Accent : Color.White;
        lblHead.ForeColor = on ? Color.White : Accent;
        lblTitle.ForeColor = on ? Color.White : Dark;
        lblBody.ForeColor = on ? Color.White : Muted;
        btnSnooze.BackColor = on ? Accent : Color.White;
        btnSnooze.ForeColor = on ? Color.White : Dark;
        btnSnooze.FlatAppearance.BorderColor = on ? Color.White : Color.FromArgb(200, 196, 186);
        Invalidate(true);
    }

    void FlashTaskbar()
    {
        try
        {
            FLASHWINFO f = new FLASHWINFO();
            f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            f.hwnd = Handle; f.dwFlags = 3 | 4; f.uCount = uint.MaxValue; f.dwTimeout = 0;   // 작업표시줄 아이콘도 계속 깜빡임
            FlashWindowEx(ref f);
        }
        catch { }
    }
}

"@
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object UpmuAlert2([string]$d.head, [string]$d.title, [string]$d.body, $slot, [double]$scale, [int]$snooze)
    [System.Windows.Forms.Application]::Run($form)
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
catch {
    # 문제가 생기면 기록을 남기고 간단한 메시지 창으로라도 알림
    ("[{0}] {1}`r`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace) | Out-File -LiteralPath $errLog -Append -Encoding UTF8
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(([string]$d.title + "`r`n" + [string]$d.body), '일정 알림', 'OK', 'Warning', 'Button1', 'ServiceNotification') | Out-Null
    } catch { }
}

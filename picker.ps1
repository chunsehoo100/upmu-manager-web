# 메모 첨부용 파일/폴더 선택 창: 고른 전체 경로를 OutFile에 UTF-8로 기록 (취소하면 빈 파일)
param([ValidateSet('file', 'folder')][string]$Kind = 'file', [string]$OutFile)
$errLog = Join-Path ([System.IO.Path]::GetTempPath()) 'upmu_picker_error.log'
$result = ''
$title = if ($Kind -eq 'folder') { '메모에 첨부할 폴더 선택' } else { '메모에 첨부할 파일 선택' }
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 다른 창 뒤에 숨지 않도록 보이지 않는 '항상 위' 창을 주인으로 삼아 선택 창을 띄움
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.FormBorderStyle = 'None'
    $owner.StartPosition = 'CenterScreen'; $owner.Size = New-Object System.Drawing.Size(1, 1); $owner.Opacity = 0
    $owner.Show(); $owner.Activate()

    try {
        # Windows 탐색기와 같은 최신 선택 창 (주소창에 경로 붙여넣기 가능)
        if (-not ('UpmuPicker' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class UpmuPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogCo { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    // 취소하면 null
    public static string Pick(IntPtr owner, bool folder, string title)
    {
        IFileDialog d = (IFileDialog)new FileOpenDialogCo();
        uint opts; d.GetOptions(out opts);
        opts |= 0x40 | 0x800 | 0x1000;          // FORCEFILESYSTEM | PATHMUSTEXIST | FILEMUSTEXIST
        if (folder) opts |= 0x20;               // PICKFOLDERS
        d.SetOptions(opts);
        d.SetTitle(title);
        if (d.Show(owner) != 0) return null;    // 취소
        IShellItem item; d.GetResult(out item);
        IntPtr p; item.GetDisplayName(0x80058000, out p);   // SIGDN_FILESYSPATH
        try { return Marshal.PtrToStringUni(p); } finally { Marshal.FreeCoTaskMem(p); }
    }
}
"@
        }
        $r = [UpmuPicker]::Pick($owner.Handle, $Kind -eq 'folder', $title)
        if ($r) { $result = $r }
    }
    catch {
        # 최신 선택 창을 못 쓰면 기본 선택 창으로
        ("[{0}] modern dialog: {1}" -f (Get-Date), $_.Exception.Message) | Out-File -LiteralPath $errLog -Append -Encoding UTF8
        if ($Kind -eq 'folder') {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $title
            if ($dlg.ShowDialog($owner) -eq 'OK') { $result = $dlg.SelectedPath }
        } else {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = $title
            if ($dlg.ShowDialog($owner) -eq 'OK') { $result = $dlg.FileName }
        }
    }
    $owner.Close()
}
catch {
    ("[{0}] {1}`r`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace) | Out-File -LiteralPath $errLog -Append -Encoding UTF8
}
[System.IO.File]::WriteAllText($OutFile, $result, (New-Object System.Text.UTF8Encoding $false))

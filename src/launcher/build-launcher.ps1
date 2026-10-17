#Requires -Version 5.1
# 编译三个入口：open-gui.exe、silent-check.exe、uninstall.exe
# 使用 Windows 系统自带的 .NET Framework C# 编译器（csc.exe），不引入第三方依赖。
# 运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File src\launcher\build-launcher.ps1

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# 定位 csc.exe（优先 64 位框架，回退 32 位）
$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw '未找到系统自带的 C# 编译器 csc.exe（.NET Framework v4.0.30319）' }

$targets = @(
    @{ Cs = 'open-gui.cs';    Exe = 'open-gui.exe' },
    @{ Cs = 'silent-check.cs'; Exe = 'silent-check.exe' },
    @{ Cs = 'uninstall.cs'; Exe = 'uninstall.exe' }
)

foreach ($t in $targets) {
    $csPath  = Join-Path $PSScriptRoot $t.Cs
    $exePath = Join-Path $repoRoot $t.Exe
    if (-not (Test-Path $csPath)) { throw "未找到源码：$csPath" }

    # /target:winexe —— Windows 图形子系统，无控制台（黑框从根源消失）
    & $csc /nologo /target:winexe /platform:anycpu `
        /r:System.dll /r:System.Windows.Forms.dll `
        /out:"$exePath" "$csPath"
    if ($LASTEXITCODE -ne 0) { throw "编译 $($t.Cs) 失败，退出码 $LASTEXITCODE" }
    if (-not (Test-Path $exePath)) { throw "编译后未找到产物：$exePath" }

    # 静态验证：PE 头子系统应为 2（GUI，无控制台）
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $isMz = ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 0x5C)

    $sizeKB = [math]::Round((Get-Item $exePath).Length / 1KB, 1)
    Write-Output "编译完成：$exePath（$sizeKB KB）"
    Write-Output "PE 校验：MZ头=$isMz 子系统=$subsystem（2=图形程序，无控制台）"
    if (-not $isMz) { throw '产物不是有效的 PE 文件' }
    if ($subsystem -ne 2) { throw "子系统异常：期望 2（GUI），实际 $subsystem" }
}
Write-Output 'OK'

#Requires -Version 5.1
# 微软拼音词库备份 GUI —— 设置与状态面板
#
# 用法：
#   双击 open-gui.exe（正常入口；启动器会准备应用专属临时目录）
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File gui-app.ps1
#   powershell.exe … -File gui-app.ps1 -DataDir <临时目录>
#   （-DataDir 为测试模式：配置/日志/存档/词库目录全部指向该目录下的虚构数据，
#     与真实词库完全隔离；不传则使用真实位置）
#
# 行为约定：
#   - 本窗口只是设置与状态面板：备份/恢复/清理实际由 engine.psm1 执行；
#     正常操作在面板内显示进度与结果；引擎不弹窗。
#   - 关闭主窗口即真正退出：不驻留托盘、不常驻后台。
#   - 恢复必须用户明确确认；取消、关闭提示都不执行恢复。
#   - 登录自动检查由计划任务 + silent-check.exe + auto-check.ps1 承担，与本窗口无关。
#
# 边界（界面同步说明）：
#   - 词组数量是估算值（连续汉字串匹配数），不是精确解析。
#   - 恢复产物（recovery 存档）不作为恢复来源，也不参与普通清理。

param([string]$DataDir = '')

$ErrorActionPreference = 'Stop'

function Write-GuiCrashLog {
    <# 尽力写崩溃日志；返回是否写入成功。 #>
    param([string]$Message)
    try {
        Add-Content -Path (Join-Path $env:TEMP 'pinyin-gui-crash.log') -Value "[$(Get-Date -Format s)] $Message" -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

try {
    # ============ 环境与路径 ============
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms

    # ---- 临时目录自检 ----
    # WPF 会把文本渲染缓存写到 <TEMP>\WPF 下的临时文件（.qmp/.abw 等）。
    # 这些文件写不进去时，窗口构造过程只会抛出「对某临时文件的访问被拒绝」这类
    # 难以理解的内部异常。这里在创建任何窗口之前先做一次真实写入探测。
    # 说明：正常启动时由 open-gui.exe 把 TEMP/TMP 指向本应用专属目录；
    # 直接运行本脚本时用的是当前 TEMP，这里同样会先检查它是否可写。
    $script:TempRoot = $env:TEMP
    $script:TempProblem = $null
    try {
        if ([string]::IsNullOrWhiteSpace($script:TempRoot)) {
            throw '环境变量 TEMP 为空'
        }
        if (-not [System.IO.Directory]::Exists($script:TempRoot)) {
            $null = [System.IO.Directory]::CreateDirectory($script:TempRoot)
        }
        $wpfCacheDir = Join-Path $script:TempRoot 'WPF'
        if (-not [System.IO.Directory]::Exists($wpfCacheDir)) {
            $null = [System.IO.Directory]::CreateDirectory($wpfCacheDir)
        }
        $probeFile = Join-Path $wpfCacheDir ('pinyin-gui-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $probeBytes = [System.Text.Encoding]::UTF8.GetBytes('probe')
        $fs = [System.IO.File]::Open($probeFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($probeBytes, 0, $probeBytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
        try { [System.IO.File]::Delete($probeFile) } catch { }
    } catch {
        $script:TempProblem = $_.Exception.Message
    }
    if ($script:TempProblem) {
        throw ("临时目录不可写，窗口无法安全启动。`n`n目录：$($script:TempRoot)`n" +
               "原因：$($script:TempProblem)`n`n" +
               "请先用 open-gui.exe 启动（它会把临时目录指向本程序自己的可写目录）；`n" +
               "如果仍然失败，请检查磁盘剩余空间，以及该目录是否被安全软件锁定。")
    }

    $script:AppDir     = $PSScriptRoot
    $script:BaseDir    = if ($DataDir) { $DataDir } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $script:ConfigPath = Join-Path $script:BaseDir 'config.json'
    $script:LogPath    = Join-Path $script:BaseDir 'pinyin-backup.log'
    $script:SnapDir    = Join-Path $script:BaseDir 'snapshots'

    Import-Module (Join-Path $AppDir 'gui-config.psm1') -DisableNameChecking
    Import-Module (Join-Path $AppDir 'gui-status.psm1') -DisableNameChecking
    Import-Module (Join-Path $AppDir 'engine.psm1')      -DisableNameChecking
    Import-Module (Join-Path $AppDir 'shell-actions.psm1') -DisableNameChecking

    # GUI 上下文：测试模式（-DataDir）下词库目录也隔离到 DataDir；生产用真实位置
    $script:ImeDirArg = ''
    if ($DataDir) { $script:ImeDirArg = Join-Path $DataDir 'ime-data' }

    function New-GuiEngineContext {
        <# 组装 GUI 用的引擎上下文。配置无效时弹窗说明并返回 $null（绝不按另一套参数运行）。 #>
        $cargs = @{ BaseDir = $script:BaseDir }
        if ($script:ImeDirArg) { $cargs.ImeDir = $script:ImeDirArg }
        $ctx = New-EngineContext @cargs
        if (-not $ctx.Ok) {
            [System.Windows.MessageBox]::Show(
                ($ctx.Errors -join "`n") + "`n`n为避免按错误参数运行，操作未执行。请在『设置』中修正。",
                '微软拼音词库备份', 'OK', 'Error') | Out-Null
            return $null
        }
        return $ctx
    }

    # ============ 单实例 ============
    $script:MutexName = 'Local\PinyinLexiconGuiMutex'
    $script:EventName = 'Local\PinyinLexiconGuiShowEvent'

    $createdNew = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) {
        # 已有实例在运行：通知它显示主窗口，然后本进程退出。
        $notified = $false
        try {
            $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)
            $notified = $ev.Set()
            if ($notified) {
                $ack = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "$EventName.Ack")
                $acked = $ack.WaitOne(3000)
                $ack.Dispose()
                if ($acked) {
                    $ev.Dispose()
                    Write-GuiCrashLog '重复启动：已唤起现有实例，本进程退出'
                    exit 0
                }
            }
            $ev.Dispose()
        } catch { }
        # 通知失败或旧实例无响应：只定位本程序自己的进程，不引导用户结束所有 PowerShell
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            $staleIds = @()
            try {
                $staleIds = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like '*gui-app.ps1*' } |
                    ForEach-Object { [int]$_.ProcessId })
            } catch { }
            if ($staleIds.Count -gt 0) {
                $idList = ($staleIds | Sort-Object) -join '、'
                $choice = [System.Windows.MessageBox]::Show(
                    ("本程序还有一个进程在运行，但无法唤起它的窗口（可能是上次异常退出留下的残留进程）。`n`n" +
                     "找到的本程序进程：PID $idList`n`n" +
                     "是否现在结束这些进程？只会结束上面列出的这几个（命令行含 gui-app.ps1），`n" +
                     "不会影响你正在使用的其他 PowerShell 窗口。"),
                    '微软拼音词库备份 GUI', 'YesNo', 'Warning',
                    [System.Windows.MessageBoxResult]::No)
                if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
                    $failedIds = @()
                    foreach ($staleId in $staleIds) {
                        try { Stop-Process -Id $staleId -Force -ErrorAction Stop }
                        catch { $failedIds += $staleId }
                    }
                    if ($failedIds.Count -eq 0) {
                        [System.Windows.MessageBox]::Show(
                            "已结束残留进程。请重新双击 open-gui.exe 打开窗口。",
                            '微软拼音词库备份 GUI', 'OK', 'Information') | Out-Null
                    } else {
                        [System.Windows.MessageBox]::Show(
                            ("有进程未能结束（PID " + (($failedIds | Sort-Object) -join '、') + "）。`n`n" +
                             "请打开任务管理器 →『详细信息』，手动结束这几个 PID。"),
                            '微软拼音词库备份 GUI', 'OK', 'Warning') | Out-Null
                    }
                }
            } else {
                [System.Windows.MessageBox]::Show(
                    ("本程序还有一个进程在运行，但无法唤起它的窗口。`n`n" +
                     "请打开任务管理器 →『详细信息』，右键列标题勾选『命令行』，`n" +
                     "只结束命令行里包含 gui-app.ps1 的那个 powershell.exe。`n`n" +
                     "请不要结束其他 PowerShell 进程：它们可能是你正在使用的终端或其他脚本。"),
                    '微软拼音词库备份 GUI', 'OK', 'Warning') | Out-Null
            }
        } catch { }
        exit 0
    }

    # ============ 应用 ============
    $app = New-Object System.Windows.Application
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnLastWindowClose

    # ============ 主窗口 XAML ============
    [xml]$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="微软拼音词库备份" Height="700" Width="880"
        MinHeight="560" MinWidth="760"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="True">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" x:Name="bdLexicon" Background="#FFE8F5E9" BorderBrush="#FFA5D6A7"
            BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,0,0,10">
      <StackPanel>
        <TextBlock FontWeight="Bold" x:Name="txtLexiconState" Text="词库状态：读取中…"/>
        <TextBlock TextWrapping="Wrap" Margin="0,3,0,0" x:Name="txtLexiconDetail" Foreground="#FF4E6E4F"
                   Text="词组数量为估算值，仅供参考。"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="1" Background="#FFF2F5F8" BorderBrush="#FFD0D7DE" BorderThickness="1"
            CornerRadius="4" Padding="10,8" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Grid.Column="0" Text="最近一次备份：" FontWeight="Bold"/>
        <TextBlock Grid.Row="0" Grid.Column="1" x:Name="txtLatestBackup" Text="读取中…"/>
        <TextBlock Grid.Row="1" Grid.Column="0" Text="最近一次恢复：" FontWeight="Bold"/>
        <TextBlock Grid.Row="1" Grid.Column="1" x:Name="txtLatestRestore" Text="暂无记录"/>
        <TextBlock Grid.Row="2" Grid.Column="0" Text="备份位置：" FontWeight="Bold"/>
        <TextBlock Grid.Row="2" Grid.Column="1" x:Name="txtBackupDir" Text="读取中…" TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Row="3" Grid.Column="0" Text="生效配置：" FontWeight="Bold"/>
        <TextBlock Grid.Row="3" Grid.Column="1" x:Name="txtConfigSummary" Text="读取中…"/>
        <TextBlock Grid.Row="4" Grid.Column="0" Text="登录自动检查：" FontWeight="Bold"/>
        <TextBlock Grid.Row="4" Grid.Column="1" x:Name="txtTaskState" Text="读取中…"/>
      </Grid>
    </Border>

    <TabControl Grid.Row="2" Margin="0,0,0,10">
      <TabItem Header="存档记录（最近 10 份，普通备份优先；恢复前先选中一份）">
        <ListView x:Name="lvSnapshots" SelectionMode="Single">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="存档名" Width="170" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="来源" Width="80" DisplayMemberBinding="{Binding Source}"/>
              <GridViewColumn Header="参考词数（估算）" Width="110" DisplayMemberBinding="{Binding Words}"/>
              <GridViewColumn Header="时间" Width="160" DisplayMemberBinding="{Binding Time}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </TabItem>
      <TabItem Header="运行日志（最近 20 条）">
        <ListView x:Name="lvLogs">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="时间" Width="150" DisplayMemberBinding="{Binding Time}"/>
              <GridViewColumn Header="动作" Width="80" DisplayMemberBinding="{Binding Action}"/>
              <GridViewColumn Header="结果" Width="110" DisplayMemberBinding="{Binding Result}"/>
              <GridViewColumn Header="详情" Width="380" DisplayMemberBinding="{Binding Detail}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </TabItem>
    </TabControl>

    <TextBlock Grid.Row="3" x:Name="txtOpState" TextWrapping="Wrap" Margin="0,0,0,8" Foreground="#FF37474F"
               Text="操作结果会显示在这里。恢复前会先完整保全当前数据，确认后才执行。"/>

    <Grid Grid.Row="4">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button Grid.Column="0" x:Name="btnBackup" Content="立即备份" MinWidth="110" Margin="0,0,8,0"
              ToolTip="把当前词库完整备份一份（手动备份不受间隔限制，也不做去重跳过）"/>
      <Button Grid.Column="1" x:Name="btnRestore" Content="恢复选中存档…" MinWidth="120" Margin="0,0,8,0"
              ToolTip="恢复前先保全当前数据并需要你确认；恢复产物不会成为推荐来源"/>
      <Button Grid.Column="2" x:Name="btnSuspend" Content="挂起值守" MinWidth="95" Margin="0,0,8,0"
              ToolTip="主动清空词库前挂起自动检查，避免误报；清空完恢复值守"/>
      <StackPanel Grid.Column="4" Orientation="Horizontal">
        <Button x:Name="btnOpenFolder" Content="打开备份文件夹" MinWidth="115" Margin="0,0,8,0"/>
        <Button x:Name="btnRefresh" Content="刷新" MinWidth="65" Margin="0,0,8,0"/>
        <Button x:Name="btnSettings" Content="设置…" MinWidth="75" Margin="0,0,8,0"/>
        <Button x:Name="btnUninstall" Content="卸载…" MinWidth="65"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
"@

    $mainWindow = [System.Windows.Markup.XamlReader]::Parse($mainXaml.OuterXml)

    # ============ 设置窗口 XAML ============
    $script:SettingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="设置" Height="560" Width="580"
        MinHeight="500" MinWidth="540"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <GroupBox Header="常用设置" Padding="8">
          <Grid Margin="0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="170"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Text="备份间隔（天）"/>
            <TextBox Grid.Row="0" Grid.Column="1" x:Name="txtInterval" Width="80" HorizontalAlignment="Left"/>
            <TextBlock Grid.Row="0" Grid.Column="2" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#FF808080" Text="1–365；登录检查时距上次备份超过该天数才备份"/>

            <TextBlock Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Margin="0,10,0,0" Text="保留份数"/>
            <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtKeep" Width="80" HorizontalAlignment="Left" Margin="0,10,0,0"/>
            <TextBlock Grid.Row="1" Grid.Column="2" VerticalAlignment="Center" Margin="8,10,0,0" Foreground="#FF808080" Text="1–200；只统计普通备份（自动+手动）"/>

            <TextBlock Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Margin="0,10,0,0" Text="备份位置"/>
            <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtBackupDir" Margin="0,10,0,0"/>
            <Button Grid.Row="2" Grid.Column="2" x:Name="btnBrowse" Content="浏览…" Margin="8,10,0,0"/>
            <TextBlock Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,4,0,0" Foreground="#FF808080" TextWrapping="Wrap"
                       Text="支持绝对或相对路径（相对本程序目录）。修改备份位置不会搬迁或删除旧备份，旧备份保留在原位置，可自行移入新位置。"/>

            <CheckBox Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="3" x:Name="chkLoginStart" Content="登录 Windows 后自动检查并按需备份" Margin="0,10,0,0"/>
            <TextBlock Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="3" Margin="0,6,0,0" Foreground="#FF808080" TextWrapping="Wrap"
                       Text="启用时注册本版本的登录任务（延迟见高级设置）；关闭时只移除本版本的任务，不影响旧脚本的任务。正常检查完全静默，出错才提示。"/>
          </Grid>
        </GroupBox>

        <Expander Header="高级设置（默认即可，改前请确认含义）" Margin="0,10,0,0" IsExpanded="False">
          <Grid Margin="8,4,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="170"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Text="登录后检查延迟（秒）"/>
            <TextBox Grid.Row="0" Grid.Column="1" x:Name="txtDelay" Width="80" HorizontalAlignment="Left"/>
            <TextBlock Grid.Row="0" Grid.Column="2" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#FF808080" Text="5–300；等输入法初始化，等待由任务调度承担"/>

            <CheckBox Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" x:Name="chkDedup" Content="自动备份内容相同时跳过（手动备份不受影响）" Margin="0,10,0,0"/>

            <TextBlock Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Margin="0,10,0,0" Text="日志上限（MB）"/>
            <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtLogMb" Width="80" HorizontalAlignment="Left" Margin="0,10,0,0"/>
            <TextBlock Grid.Row="2" Grid.Column="2" VerticalAlignment="Center" Margin="8,10,0,0" Foreground="#FF808080" Text="1–50；超过后截断重建"/>
          </Grid>
        </Expander>

        <Border Background="#FFF8F5E6" BorderBrush="#FFE0C87A" BorderThickness="1"
                CornerRadius="4" Padding="10,8" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#FF7A5C00"
                       Text="错误与异常提醒是程序的内置保证（例如词库疑似丢失、备份失败），没有开关可以整体关闭；正常检查与正常备份保持静默。"/>
            <TextBlock TextWrapping="Wrap" Margin="0,6,0,0" Foreground="#FF7A5C00"
                       Text="恢复前的确认与数据保全、失败回退同样是内置保证，不提供关闭开关。"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <Grid Grid.Row="1" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" x:Name="txtConfigPath" VerticalAlignment="Center" Foreground="#FF9A9A9A"
                 TextTrimming="CharacterEllipsis" FontSize="11"/>
      <Button Grid.Column="1" x:Name="btnSave" Content="保存并应用" MinWidth="100" Margin="0,0,8,0" IsDefault="True"/>
      <Button Grid.Column="2" x:Name="btnCancel" Content="取消" MinWidth="70"/>
    </Grid>
  </Grid>
</Window>
"@

    # ============ 通用工具 ============
    function Set-OpState {
        <# 更新操作状态行，并让界面先把这次更新画出来再继续（配合按钮禁用实现可感知进度）。 #>
        param([string]$Text)
        $mainWindow.FindName('txtOpState').Text = $Text
        $mainWindow.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }

    function Set-ButtonsEnabled {
        param([bool]$Enabled)
        foreach ($n in @('btnBackup','btnRestore','btnSuspend','btnOpenFolder','btnRefresh','btnSettings')) {
            $mainWindow.FindName($n).IsEnabled = $Enabled
        }
        $mainWindow.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }

    function Convert-ToUiRow {
        param($Item)
        [pscustomobject]@{
            Time   = $Item.Time;   Action = $Item.Action
            Result = $Item.Result; Detail = $Item.Detail
        }
    }

    # ============ 主窗口刷新 ============
    function Update-MainStatus {
        $cfgResult = Read-GuiConfig -Path $script:ConfigPath -BaseDir $script:BaseDir
        $cfg = $cfgResult.Config

        # ---- 词库状态横幅 + 任务实际状态（读系统，不读配置，避免显示与事实不符） ----
        $ctx = $null
        try { $ctx = New-GuiEngineContext } catch { }
        if ($ctx) {
            $lex = Get-EngineLexiconStatus -Ctx $ctx
            $st = $mainWindow.FindName('txtLexiconState')
            $dt = $mainWindow.FindName('txtLexiconDetail')
            $bd = $mainWindow.FindName('bdLexicon')
            switch ($lex.State) {
                'ok' {
                    $bd.Background = '#FFE8F5E9' -as [System.Windows.Media.Brush]
                    $bd.BorderBrush = '#FFA5D6A7' -as [System.Windows.Media.Brush]
                    $dt.Foreground = '#FF4E6E4F' -as [System.Windows.Media.Brush]
                    $st.Text = "词库状态：可读取（估算 $($lex.Words) 个词组）"
                    $dt.Text = $lex.Note
                }
                'locked' {
                    $bd.Background = '#FFFFF8E1' -as [System.Windows.Media.Brush]
                    $bd.BorderBrush = '#FFE0C87A' -as [System.Windows.Media.Brush]
                    $st.Text = '词库状态：暂时被占用（通常是输入法正在写入）'
                    $dt.Text = $lex.Note + ' 稍后点『刷新』即可。'
                }
                'missing' {
                    $bd.Background = '#FFFDECEA' -as [System.Windows.Media.Brush]
                    $bd.BorderBrush = '#FFEF9A9A' -as [System.Windows.Media.Brush]
                    $st.Text = '词库状态：文件不存在'
                    $dt.Text = $lex.Note + ' 如果是你主动清空词库所致，请用下方『挂起值守』；否则可从存档恢复。'
                }
                'malformed' {
                    $bd.Background = '#FFFDECEA' -as [System.Windows.Media.Brush]
                    $bd.BorderBrush = '#FFEF9A9A' -as [System.Windows.Media.Brush]
                    $st.Text = '词库状态：内容无法解析（可能损坏）'
                    $dt.Text = $lex.Note + ' 不会自动覆盖数据；可从存档恢复。'
                }
            }
            if (Test-EngineSuspended -Ctx $ctx) {
                $st.Text = $st.Text + '（值守已挂起：自动检查暂停）'
            }
            $mainWindow.FindName('btnSuspend').Content = if (Test-EngineSuspended -Ctx $ctx) { '恢复值守' } else { '挂起值守' }

            $ts = Get-EngineTaskStatus -Ctx $ctx
            $tTxt = $mainWindow.FindName('txtTaskState')
            if ($ts.Registered) {
                $delayTxt = if ($null -ne $ts.DelaySeconds) { "，登录后延迟 $($ts.DelaySeconds) 秒" } else { '' }
                $tTxt.Text = "已启用（计划任务已注册$delayTxt）"
            } elseif ($ts.Error) {
                $tTxt.Text = "查询失败：$($ts.Error)"
            } else {
                $tTxt.Text = '未启用（无登录计划任务）'
            }
        } else {
            $mainWindow.FindName('txtLexiconState').Text = '词库状态：无法检查（配置无效）'
        }

        # ---- 摘要区 ----
        $dir = Resolve-GuiBackupDir -BackupDir $cfg.BackupDir -BaseDir $script:BaseDir
        $mainWindow.FindName('txtBackupDir').Text = $dir
        $mainWindow.FindName('txtConfigSummary').Text =
            "间隔 $($cfg.BackupIntervalDays) 天；保留 $($cfg.KeepCount) 份；自动去重 $(if ($cfg.DeduplicateBackup) { '开' } else { '关' })；日志上限 $($cfg.MaxLogMB) MB"

        $latest = Get-GuiLatestBackupFromLog -LogPath $script:LogPath
        if ($latest) { $mainWindow.FindName('txtLatestBackup').Text = "$($latest.Time)   $($latest.Detail)" }
        else         { $mainWindow.FindName('txtLatestBackup').Text = '暂无记录' }

        $logAll = Get-GuiLogEntries -LogPath $script:LogPath -MaxCount 0
        $lastRestore = $null
        for ($i = $logAll.Entries.Count - 1; $i -ge 0; $i--) {
            if ($logAll.Entries[$i].Action -eq 'recovery') { $lastRestore = $logAll.Entries[$i]; break }
        }
        if ($lastRestore) { $mainWindow.FindName('txtLatestRestore').Text = "$($lastRestore.Time)   $($lastRestore.Result)" }
        else              { $mainWindow.FindName('txtLatestRestore').Text = '暂无记录' }

        # ---- 存档列表 ----
        $lv = $mainWindow.FindName('lvSnapshots')
        $snaps = @()
        if ($ctx) { $snaps = @(Get-EngineSnapshots -Ctx $ctx | Select-Object -First 10) }
        if ($snaps.Count -gt 0) {
            $lv.ItemsSource = @($snaps | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Source = switch ($_.Source) { 'auto' {'自动'} 'manual' {'手动'} 'recovery' {'恢复产物（不可恢复）'} default { $_.Source } }
                    Words = $_.Words
                    Time  = $_.Time
                }
            })
        } else {
            $lv.ItemsSource = @( [pscustomobject]@{ Name='暂无记录'; Source=''; Words=''; Time='' } )
        }

        # ---- 日志列表 ----
        $lv2 = $mainWindow.FindName('lvLogs')
        $log = Get-GuiLogEntries -LogPath $script:LogPath -MaxCount 20
        if (-not $log.FileExists) {
            $lv2.ItemsSource = @( [pscustomobject]@{ Time='暂无记录'; Action=''; Result=''; Detail='尚未生成日志' } )
        } elseif ($log.Entries.Count -eq 0) {
            $lv2.ItemsSource = @( [pscustomobject]@{ Time='暂无记录'; Action=''; Result=''; Detail='' } )
        } else {
            $rows = @($log.Entries | ForEach-Object { Convert-ToUiRow -Item $_ })
            [array]::Reverse($rows)
            if ($log.SkippedLines -gt 0) {
                $rows += [pscustomobject]@{ Time='—'; Action=''; Result="另有 $($log.SkippedLines) 行无法解析"; Detail='' }
            }
            $lv2.ItemsSource = $rows
        }
    }

    function Show-MainWindow {
        $mainWindow.Show()
        if ($mainWindow.WindowState -eq [System.Windows.WindowState]::Minimized) {
            $mainWindow.WindowState = [System.Windows.WindowState]::Normal
        }
        $null = $mainWindow.Activate()
        Update-MainStatus
    }

    # ============ 操作：立即备份 ============
    function Invoke-GuiBackup {
        $ctx = New-GuiEngineContext
        if (-not $ctx) { return }
        if (Test-EngineOpBusy) {
            [System.Windows.MessageBox]::Show(
                '另一个备份/恢复/清理操作正在进行（可能是登录自动检查）。请稍后点『刷新』再试。',
                '操作进行中', 'OK', 'Information') | Out-Null
            return
        }
        Set-ButtonsEnabled $false
        Set-OpState '正在备份：检查词库 → 复制到临时目录 → 完整性校验 → 转正 …'
        try {
            $r = Invoke-EngineBackup -Ctx $ctx -Manual
            switch ($r.Outcome) {
                'success' {
                    if (@($r.RotationErrors).Count -gt 0) {
                        Set-OpState ("备份成功：$($r.SnapshotName)（$($r.Words) 个词组，估算）。超额旧备份清理失败，不影响新备份，下次会再试。")
                        [System.Windows.MessageBox]::Show(
                            ("备份成功，但清理失败。`n`n新备份：$($r.SnapshotName)（$($r.Words) 个词组，估算值）`n`n清理失败的项目：`n· " + (@($r.RotationErrors) -join "`n· ") + "`n`n新备份不受影响；可在『设置』里再保存一次以重试清理。"),
                            '备份成功、清理失败', 'OK', 'Warning') | Out-Null
                    } else {
                        Set-OpState "备份成功：$($r.SnapshotName)（$($r.Words) 个词组，估算）。"
                    }
                }
                'failed' {
                    Set-OpState '备份失败（详情见弹窗）。'
                    [System.Windows.MessageBox]::Show((@($r.Errors) -join "`n"), '备份失败', 'OK', 'Error') | Out-Null
                }
                default {
                    Set-OpState "备份未执行：$($r.Outcome)"
                }
            }
        } finally {
            Set-ButtonsEnabled $true
            Update-MainStatus
        }
    }

    # ============ 操作：恢复选中存档 ============
    function Invoke-GuiRestore {
        $ctx = New-GuiEngineContext
        if (-not $ctx) { return }
        $sel = $mainWindow.FindName('lvSnapshots').SelectedItem
        if (-not $sel -or -not $sel.Name -or $sel.Name -eq '暂无记录') {
            [System.Windows.MessageBox]::Show(
                '请先在『存档记录』列表中选中一份存档，再点『恢复选中存档…』。',
                '未选择存档', 'OK', 'Information') | Out-Null
            return
        }
        $snaps = @(Get-EngineSnapshots -Ctx $ctx | Where-Object { $_.Name -eq $sel.Name })
        if ($snaps.Count -eq 0) {
            [System.Windows.MessageBox]::Show("列表中的存档已不可用（$($sel.Name)），请点『刷新』。", '存档不可用', 'OK', 'Warning') | Out-Null
            return
        }
        $snap = $snaps[0]
        if ($snap.Source -notin @('auto','manual')) {
            [System.Windows.MessageBox]::Show(
                '恢复产物（recovery 存档）不能作为恢复来源，防止坏结果污染基准。请选择自动或手动备份。',
                '不能恢复这份存档', 'OK', 'Warning') | Out-Null
            return
        }
        if (Test-EngineOpBusy) {
            [System.Windows.MessageBox]::Show('另一个操作正在进行，请稍后再试。', '操作进行中', 'OK', 'Information') | Out-Null
            return
        }

        $srcName = switch ($snap.Source) { 'auto' {'自动备份'} 'manual' {'手动备份'} default {$snap.Source} }
        $choice = [System.Windows.MessageBox]::Show(
            ("即将把词库恢复到选中的备份。`n`n" +
             "备份：$($snap.Name)`n" +
             "来源：$srcName（$($snap.Words) 个词组，估算值）`n" +
             "备份时间：$($snap.Time)`n" +
             "恢复到：$($ctx.Paths.ImeDir)`n`n" +
             "执行说明：`n" +
             "· 恢复前会把当前数据完整保全到 quarantine 目录（校验通过才继续）`n" +
             "· 期间会短暂停止输入法相关进程，恢复后尝试重启；输入法可能短暂中断`n" +
             "· 恢复后逐个文件与备份内容核对（不只看词数）`n`n" +
             "是 = 开始恢复　否 = 取消（当前词库不会有任何改动）"),
            '确认恢复', 'YesNo', 'Warning', [System.Windows.MessageBoxResult]::No)
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Set-ButtonsEnabled $false
        Set-OpState '正在恢复：校验存档 → 保全当前数据 → 覆盖 → 逐文件核对 …'
        try {
            $r = Invoke-EngineRestore -Ctx $ctx -SnapshotName $snap.Name
            switch ($r.Outcome) {
                'success' {
                    Set-OpState "恢复成功：已从 $($snap.Name) 恢复；恢复前数据保全在 $($r.QuarantineName)。"
                    [System.Windows.MessageBox]::Show(
                        ("恢复完成。`n`n已从 $($snap.Name) 恢复词库；恢复前的数据保全在：`nquarantine\$($r.QuarantineName)`n`n输入法进程已按原运行状态尝试重启。$(@($r.RestartErrors) -join "`n")`n如果输入法没有恢复工作，请注销后重新登录。"),
                        '恢复成功', 'OK', 'Information') | Out-Null
                }
                'busy' {
                    Set-OpState '恢复未执行：另一个操作正在进行。'
                    [System.Windows.MessageBox]::Show((@($r.Errors) -join "`n"), '恢复未执行', 'OK', 'Warning') | Out-Null
                }
                default {
                    Set-OpState '恢复失败或未完成（详情见弹窗）。'
                    [System.Windows.MessageBox]::Show((@($r.Errors + $r.RestartErrors) -join "`n"), '恢复失败', 'OK', 'Error') | Out-Null
                }
            }
        } finally {
            Set-ButtonsEnabled $true
            Update-MainStatus
        }
    }

    # ============ 操作：挂起/恢复值守 ============
    function Invoke-GuiSuspendToggle {
        $ctx = New-GuiEngineContext
        if (-not $ctx) { return }
        if (Test-EngineSuspended -Ctx $ctx) {
            Clear-EngineSuspend -Ctx $ctx
            Set-OpState '已恢复值守：下次登录检查会正常执行。'
        } else {
            $choice = [System.Windows.MessageBox]::Show(
                ("挂起值守后，登录自动检查会跳过（不再备份、不再弹词库异常提醒）。`n`n" +
                 "适用场景：你准备主动清空词库重新开始，避免被误报。`n`n" +
                 "清空完成后请回到这里点『恢复值守』。`n`n是 = 挂起值守　否 = 取消"),
                '挂起值守', 'YesNo', 'Question', [System.Windows.MessageBoxResult]::No)
            if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
            Set-EngineSuspend -Ctx $ctx
            Set-OpState '值守已挂起：自动检查暂停。清空词库完成后请点『恢复值守』。'
        }
        Update-MainStatus
    }

    # ============ 设置窗口逻辑 ============
    function Get-SettingsDraft {
        $w = $script:SettingsWindow
        @{
            BackupIntervalDays = $w.FindName('txtInterval').Text.Trim()
            KeepCount          = $w.FindName('txtKeep').Text.Trim()
            BackupDir          = $w.FindName('txtBackupDir').Text.Trim()
            LoginStart         = [bool]$w.FindName('chkLoginStart').IsChecked
            LoginDelaySeconds  = $w.FindName('txtDelay').Text.Trim()
            DeduplicateBackup  = [bool]$w.FindName('chkDedup').IsChecked
            MaxLogMB           = $w.FindName('txtLogMb').Text.Trim()
        }
    }

    function Save-SettingsFromWindow {
        <# 返回 $true 表示保存成功。失败时保留设置窗口让用户修改。 #>
        $draft = Get-SettingsDraft
        $contextArgs = @{ BaseDir = $script:BaseDir }
        if ($script:ImeDirArg) { $contextArgs.ImeDir = $script:ImeDirArg }
        $result = Set-EngineSettings -ContextArgs $contextArgs -Draft $draft -ConfirmCleanup {
                param($plan)
                $list = ($plan.Remove | ForEach-Object { "· $($_.Name)（$($_.Time)，来源 $($_.Source)）" }) -join "`n"
                $choice = [System.Windows.MessageBox]::Show(
                    ("新位置中现有 $($plan.Total) 份普通备份，将按新的保留份数清理。`n" +
                     "保存后将清理以下 $($($plan.Remove).Count) 份最旧的备份：`n`n$list`n`n" +
                     "恢复产物与无法确认归属的目录不会被清理。`n" +
                     "是 = 保存设置并立即清理　否 = 取消（本次不保存任何修改）"),
                    '确认清理旧备份', 'YesNo', 'Warning', [System.Windows.MessageBoxResult]::No)
                return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
        }
        if ($result.Cancelled) { return $false }
        if (-not $result.Success) {
            [System.Windows.MessageBox]::Show(
                ("设置未保存，原配置未改动：`n`n· " + (@($result.Errors) -join "`n· ")),
                '设置未保存', 'OK', 'Error') | Out-Null
            return $false
        }
        $partial = @($result.Errors)
        if ($partial.Count -gt 0) {
            [System.Windows.MessageBox]::Show(
                ("设置已保存，但有部分操作未完成：`n`n· " + ($partial -join "`n· ") + "`n`n" +
                 "主窗口会显示各项的真实状态；失败的项可再点一次『保存并应用』重试。"),
                '已保存（部分失败）', 'OK', 'Warning') | Out-Null
        } else {
            $taskTxt = if ([bool]$draft.LoginStart) { '登录自动检查已启用' } else { '登录自动检查已关闭' }
            $rotTxt = if (@($result.Cleaned).Count -gt 0) { '；超额旧备份已按确认清理' } else { '' }
            [System.Windows.MessageBox]::Show(
                "设置已保存并应用。$taskTxt$rotTxt。`n`n正在进行的操作（若有）仍使用开始时读取的配置；新配置从下一次操作起生效。",
                '已保存', 'OK', 'Information') | Out-Null
        }
        return $true
    }

    function Confirm-CloseSettings {
        if (-not $script:SettingsDirty) { return $true }
        $choice = [System.Windows.MessageBox]::Show(
            "有未保存的修改。要保存并应用吗？`n`n是 = 保存并应用   否 = 放弃修改并关闭   取消 = 继续编辑",
            '未保存的修改', 'YesNoCancel', 'Question')
        switch ($choice) {
            'Yes'    { $ok = Save-SettingsFromWindow; if ($ok) { $script:SettingsDirty = $false }; return $ok }
            'No'     { $script:SettingsDirty = $false; return $true }
            default  { return $false }
        }
    }

    function New-SettingsWindow {
        $w = [System.Windows.Markup.XamlReader]::Parse($script:SettingsXaml)

        $cfgResult = Read-GuiConfig -Path $script:ConfigPath -BaseDir $script:BaseDir
        $cfg = $cfgResult.Config
        $w.FindName('txtInterval').Text  = [string]$cfg.BackupIntervalDays
        $w.FindName('txtKeep').Text      = [string]$cfg.KeepCount
        $w.FindName('txtBackupDir').Text = $cfg.BackupDir
        $w.FindName('chkLoginStart').IsChecked  = [bool]$cfg.LoginStart
        $w.FindName('txtDelay').Text     = [string]$cfg.LoginDelaySeconds
        $w.FindName('chkDedup').IsChecked       = [bool]$cfg.DeduplicateBackup
        $w.FindName('txtLogMb').Text     = [string]$cfg.MaxLogMB
        $w.FindName('txtConfigPath').Text = "配置文件：$script:ConfigPath"

        $w.FindName('btnBrowse').add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = '选择备份位置（不搬迁旧存档）'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:SettingsWindow.FindName('txtBackupDir').Text = $dlg.SelectedPath
            }
        })
        $w.FindName('btnSave').add_Click({
            if (Save-SettingsFromWindow) {
                $script:SettingsDirty = $false
                $script:SettingsWindow.DialogResult = $true
                $script:SettingsWindow.Close()
            }
        })
        $w.FindName('btnCancel').add_Click({
            if (Confirm-CloseSettings) {
                $script:SettingsDirty = $false
                $script:SettingsWindow.Close()
            }
        })
        $w.add_Closing({
            param($s, $e)
            if ($script:SettingsWindow.DialogResult -eq $true) { return }
            if (-not (Confirm-CloseSettings)) { $e.Cancel = $true }
        })
        foreach ($name in @('txtInterval','txtKeep','txtBackupDir','txtDelay','txtLogMb')) {
            $w.FindName($name).add_TextChanged({ $script:SettingsDirty = $true })
        }
        foreach ($name in @('chkLoginStart','chkDedup')) {
            $cb = $w.FindName($name)
            $cb.add_Checked({ $script:SettingsDirty = $true })
            $cb.add_Unchecked({ $script:SettingsDirty = $true })
        }
        return $w
    }

    function Show-SettingsWindow {
        if ($script:SettingsWindow -and $script:SettingsWindow.IsLoaded -and $script:SettingsWindow.IsVisible) {
            $null = $script:SettingsWindow.Activate()
            return
        }
        $script:SettingsDirty = $false
        $script:SettingsWindow = New-SettingsWindow
        $script:SettingsWindow.Owner = $mainWindow
        $null = $script:SettingsWindow.ShowDialog()
        Update-MainStatus
    }

    # ============ 主窗口事件 ============
    $mainWindow.FindName('btnBackup').add_Click({ Invoke-GuiBackup })
    $mainWindow.FindName('btnRestore').add_Click({ Invoke-GuiRestore })
    $mainWindow.FindName('btnSuspend').add_Click({ Invoke-GuiSuspendToggle })
    $mainWindow.FindName('btnSettings').add_Click({ Show-SettingsWindow })
    $mainWindow.FindName('btnUninstall').add_Click({
        try {
            $exe = Join-Path (Split-Path -Parent (Split-Path -Parent $script:AppDir)) 'uninstall.exe'
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw '未找到 uninstall.exe，请重新解压完整发行文件。' }
            $null = Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetTempPath()) -ErrorAction Stop
            $mainWindow.Close()
        } catch { [System.Windows.MessageBox]::Show($_.Exception.Message,'无法启动卸载','OK','Error') | Out-Null }
    })
    $mainWindow.FindName('btnRefresh').add_Click({ Update-MainStatus })
    $mainWindow.FindName('btnOpenFolder').add_Click({
        $dir = $mainWindow.FindName('txtBackupDir').Text
        if ([string]::IsNullOrWhiteSpace($dir)) {
            [System.Windows.MessageBox]::Show(
                '备份位置为空，请先在设置中指定备份位置。',
                '备份文件夹还不存在', 'OK', 'Information') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            # 首次使用（新装/克隆）时备份目录还没创建，这是预期状态，不是错误。
            [System.Windows.MessageBox]::Show(
                ("备份文件夹还不存在：`n$dir`n`n" +
                 "第一次备份后会自动创建；现在可点『立即备份』，也可在设置中确认备份位置是否正确。"),
                '备份文件夹还不存在', 'OK', 'Information') | Out-Null
            return
        }
        $opened = Open-BackupFolder -Path $dir
        if (-not $opened.Ok) {
            [System.Windows.MessageBox]::Show(
                $opened.Message, '无法打开备份文件夹', 'OK', 'Error') | Out-Null
        }
    })

    # 关闭主窗口 = 退出程序（不隐藏、不驻留托盘）
    $mainWindow.add_Closed({
        try {
            if ($script:ShowTimer) { $script:ShowTimer.Stop() }
            if ($script:ShowEvent) { $script:ShowEvent.Dispose() }
            if ($script:AckEvent)  { $script:AckEvent.Dispose() }
            if ($script:InstanceMutex) {
                try { $script:InstanceMutex.ReleaseMutex() } catch { }
                $script:InstanceMutex.Dispose()
            }
        } catch { }
    })

    # ============ 单实例唤醒（第二个实例通知本实例显示窗口） ============
    # DispatcherTimer 在界面线程上轮询信号。不能用 RegisterWaitForSingleObject：
    # 它的回调在线程池线程上执行，而 PowerShell 脚本块只能在拥有 Runspace 的
    # 线程上运行（界面线程有、后台线程没有）——旧方案的回调一执行就抛错，
    # 导致第二个实例等不到应答而误报「残留进程」。
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $EventName)
    $script:AckEvent  = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "$EventName.Ack")

    $script:ShowTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ShowTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:ShowTimer.Add_Tick({
        if ($script:ShowEvent.WaitOne(0)) {
            try { $null = $script:AckEvent.Set() } catch { }
            Show-MainWindow
        }
    })
    $script:ShowTimer.Start()

    # ============ 启动 ============
    Update-MainStatus
    $mainWindow.Show()
    $null = $mainWindow.Activate()

    $null = $app.Run()
    exit 0
}
catch {
    $crashWritten = Write-GuiCrashLog "启动失败：$($_.Exception.GetType().FullName)：$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $tempRootShown = if ($script:TempRoot) { $script:TempRoot } else { $env:TEMP }
    $logHint = if ($crashWritten) { "`n`n技术信息已同时写入临时目录下的 pinyin-gui-crash.log：`n$tempRootShown（若该文件不存在则以本弹窗内容为准）。" } else { '' }
    $tempHint = "`n`n本次使用的临时目录：`n$tempRootShown"
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "程序启动失败：`n$($_.Exception.Message)`n`n异常类型：$($_.Exception.GetType().FullName)$tempHint$logHint",
            '微软拼音词库备份 GUI', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

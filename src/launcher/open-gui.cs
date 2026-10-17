// 迷你图形启动器 —— 微软拼音词库备份 GUI
// 作用：双击后静默启动 PowerShell 主程序（src\pinyin-gui\gui-app.ps1），不显示控制台窗口。
//
// 为什么要在这里设置临时目录：
//   WPF 把字体与文本整形的临时缓存写到 <TEMP>\WPF\ 下的临时文件（常见后缀 .qmp/.abw 等），
//   路径取自进程的 TEMP/TMP 环境变量。
//   当 %TEMP%\WPF 由管理员身份的进程创建（属主变成 BUILTIN\Administrators）后，普通用户
//   启动时可能写入被拒绝，表现为「调用 Show 时发生异常，对 ...\Temp\WPF\xxx 的访问被拒绝」。
//   本启动器因此不再依赖用户级 %TEMP%\WPF：它为这个应用单独建一个当前用户可写的临时目录，
//   在启动子进程之前设置 TEMP/TMP，只影响本应用进程树，不改系统环境变量、不改 TEMP 权限。
//   目录不可写时明确报错退出，不做提权、不静默重试、不假装启动成功。
//
// 说明：编译为 WinExe 子系统（无控制台），这是消除启动黑框的根源性方案。
// 编译：运行 build-launcher.ps1（使用 Windows 自带的 .NET Framework C# 编译器）。
using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

static class OpenGui
{
    const string AppDisplayName = "微软拼音词库备份";

    /// <summary>
    /// 启动日志：记录本次选用的临时目录与失败原因，便于事后排查。
    /// 写在临时目录自身里；日志写不进去也绝不影响启动。
    /// </summary>
    static void LogLine(string tempDir, string message)
    {
        try
        {
            if (string.IsNullOrEmpty(tempDir) || !Directory.Exists(tempDir)) return;
            File.AppendAllText(
                Path.Combine(tempDir, "launcher.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }

    [STAThread]
    static int Main()
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(baseDir, "src", "pinyin-gui", "gui-app.ps1");
            if (!File.Exists(ps1))
            {
                Fail("找不到主程序：\n" + ps1 + "\n\n请确认 open-gui.exe 与 src 文件夹在同一目录下。");
                return 1;
            }

            // 1) 选定并准备「本应用专属」的临时目录
            string tempDir;
            string tempProblem;
            if (!TryPrepareAppTemp(out tempDir, out tempProblem))
            {
                Fail("无法为本程序准备可写的临时目录，因此没有启动窗口。\n\n" +
                     tempProblem + "\n\n" +
                     "说明：窗口程序需要在自己的临时目录里保存文本渲染缓存。\n" +
                     "本次没有改用管理员权限，也没有修改系统 TEMP 设置。\n\n" +
                     "可以尝试：关闭后重新双击；或检查磁盘是否已满、该位置是否被安全软件占用。");
                return 1;
            }

            // 2) 用干净的环境变量启动主程序：TEMP/TMP 指向上面这个目录
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + ps1 + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,           // 不为 PowerShell 创建控制台窗口（无黑框）
                WorkingDirectory = baseDir
            };
            psi.EnvironmentVariables["TEMP"] = tempDir;
            psi.EnvironmentVariables["TMP"] = tempDir;

            Process child = Process.Start(psi);
            if (child == null)
            {
                Fail("启动主程序失败：系统没有返回进程对象。\n\n目标：" + ps1);
                return 1;
            }
            LogLine(tempDir, "启动：主程序进程 pid=" + child.Id);

            // 3) 只等待「刚启动就崩溃」这一种情况；窗口正常打开后就退出启动器进程。
            //    这里不做自动重启，也不吞掉失败。
            if (child.WaitForExit(2500))
            {
                int code = child.ExitCode;
                if (code != 0)
                {
                    Fail("主程序启动后立即退出（退出码 " + code + "）。\n\n" +
                         "窗口程序本身会在失败时弹出更详细的说明；如果没看到弹窗，\n" +
                         "可以查看临时目录里的崩溃日志：\n" + Path.Combine(tempDir, "pinyin-gui-crash.log"));
                    return code;
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Fail("启动失败：\n" + ex.GetType().Name + ": " + ex.Message);
            return 1;
        }
    }

    /// <summary>
    /// 准备本应用专属临时目录。按顺序尝试：
    ///   1. %LOCALAPPDATA%\PinyinLexiconBackup\temp —— 正常情况下当前用户必然可写，位置干净
    ///   2. 程序目录\.pinyin-gui-temp —— 前两者所在盘受限时（便携/受限环境）的后备
    ///   3. %TEMP%\PinyinLexiconBackup —— 最后兜底
    /// 三者都不可写才返回 false。目录里预先建好 WPF 子目录，让 WPF 直接复用。
    /// </summary>
    // 每份安装使用自己的缓存，完整卸载时不会删到另一份安装正在使用的数据。
    static string InstanceKey()
    {
        using (var sha = System.Security.Cryptography.SHA256.Create())
        {
            string path = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant();
            return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(path))).Replace("-", "").Substring(0, 16);
        }
    }
    static bool TryPrepareAppTemp(out string tempDir, out string problem)
    {
        tempDir = null;
        problem = null;
        var tried = new StringBuilder();

        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates = new string[]
        {
            (localAppData == null || localAppData.Length == 0)
                ? null
                : Path.Combine(localAppData, "PinyinLexiconBackup", "instances", InstanceKey(), "temp"),
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".pinyin-gui-temp"),
            Path.Combine(Path.GetTempPath(), "PinyinLexiconBackup", InstanceKey())
        };

        foreach (string candidate in candidates)
        {
            if (string.IsNullOrEmpty(candidate)) continue;
            string reason;
            if (TryEnsureWritableDir(candidate, out reason))
            {
                tempDir = candidate;
                LogLine(tempDir, "启动：临时目录选定为 " + tempDir);
                return true;
            }
            tried.Append("· ").Append(candidate).Append("：").Append(reason).Append('\n');
        }

        problem = "已尝试的位置都不满足写入条件：\n" + tried.ToString().TrimEnd('\n');
        return false;
    }

    /// <summary>创建（若不存在）并验证目录确实可写；顺带建好 WPF 子目录。</summary>
    static bool TryEnsureWritableDir(string dir, out string reason)
    {
        reason = null;
        try
        {
            if (!Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
                TryGrantCurrentUserFullControl(dir);   // 仅在新建时调整，保证后续复用可写
            }

            string wpfDir = Path.Combine(dir, "WPF");
            if (!Directory.Exists(wpfDir))
            {
                Directory.CreateDirectory(wpfDir);
            }

            // 真写一次，确认目录可创建文件（不做只读判断，避免误判）
            string probe = Path.Combine(wpfDir, "write-probe-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var fs = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                byte[] payload = new byte[] { 0x70, 0x72, 0x6F, 0x62, 0x65 };  // "probe"
                fs.Write(payload, 0, payload.Length);
                fs.Flush();
            }
            try { File.Delete(probe); } catch { /* 探针文件删不掉不影响可用性 */ }
            return true;
        }
        catch (Exception ex)
        {
            reason = ex.GetType().Name + ": " + ex.Message;
            return false;
        }
    }

    /// <summary>给当前用户对该目录补一条完全控制权限。只用于本应用新建的目录。</summary>
    static void TryGrantCurrentUserFullControl(string dir)
    {
        try
        {
            var identity = WindowsIdentity.GetCurrent();
            if (identity == null || identity.User == null) return;

            var info = new DirectoryInfo(dir);
            DirectorySecurity security = info.GetAccessControl();
            var rule = new FileSystemAccessRule(
                identity.User,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow);
            security.AddAccessRule(rule);
            info.SetAccessControl(security);
        }
        catch
        {
            // 拿不到权限修改权时不必失败：稍后的真实写入探测才是判定依据。
        }
    }

    static void Fail(string message)
    {
        MessageBox.Show(message, AppDisplayName, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}

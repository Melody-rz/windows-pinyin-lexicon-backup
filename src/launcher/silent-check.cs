// 登录静默检查启动器 —— 微软拼音词库备份
// 与 open-gui.exe 同款的启动方式：无控制台黑框、应用专属临时目录（避开被污染的
// %TEMP%\WPF）、不提权。区别：本程序运行 auto-check.ps1（登录检查），并透传其
// 退出码；脚本负责操作异常，启动器负责启动失败。退出码 2 表示脚本已提示，避免重复弹窗。
//
// 编译：运行 build-launcher.ps1（同时编译 open-gui.exe 与 silent-check.exe）。
using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

static class SilentCheck
{
    [STAThread]
    static int Main()
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(baseDir, "src", "pinyin-gui", "auto-check.ps1");
            if (!File.Exists(ps1))
            {
                return Fail("登录自动检查未启动：找不到必要的程序文件。\n\n" + ps1 +
                            "\n\n本次没有执行词库检查。请恢复完整程序文件后重试；仅复制 exe 不足以运行。");
            }

            string tempDir;
            string tempProblem;
            if (!TryPrepareAppTemp(out tempDir, out tempProblem))
            {
                return Fail("登录自动检查未启动：无法准备可写的应用临时目录。\n\n" + tempProblem +
                            "\n\n本次没有执行词库检查。请检查磁盘空间和目录访问权限后重试。");
            }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + ps1 + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = baseDir
            };
            psi.EnvironmentVariables["TEMP"] = tempDir;
            psi.EnvironmentVariables["TMP"] = tempDir;

            using (Process child = Process.Start(psi))
            {
                if (child == null) return Fail("登录自动检查未启动：系统没有返回执行进程。请打开主程序检查程序文件。");
                // 登录检查最长大约几十秒；给足上限防止进程悬挂占用任务槽位。
                if (!child.WaitForExit(15 * 60 * 1000))
                {
                    try { child.Kill(); } catch { }
                    return Fail("登录自动检查超过等待时限，已尝试停止本次执行。\n\n" +
                                "操作可能尚未完成，请打开主程序检查日志，并保留备份和恢复前的数据。");
                }
                if (child.ExitCode != 0 && child.ExitCode != 2)
                    return Fail("登录自动检查异常结束（退出码 " + child.ExitCode + "）。\n\n" +
                                "没有收到已显示错误说明的确认。请检查程序文件，打开主程序查看日志及数据状态。");
                return child.ExitCode;
            }
        }
        catch (Exception ex)
        {
            return Fail("登录自动检查启动失败：\n\n" + ex.Message +
                        "\n\n请打开主程序检查文件是否完整，并查看最近的操作记录。");
        }
    }

    static int Fail(string message)
    {
        MessageBox.Show(message, "微软拼音词库备份：自动检查失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return 1;
    }

    // 与 open-gui.cs 相同的候选顺序与真实写入探测；代码重复是有意的：
    // 两个启动器彼此独立启动，不共享状态，避免相互依赖。
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
                return true;
            }
            tried.Append(candidate).Append(": ").Append(reason).Append("; ");
        }

        problem = tried.ToString();
        return false;
    }

    static bool TryEnsureWritableDir(string dir, out string reason)
    {
        reason = null;
        try
        {
            if (!Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
                TryGrantCurrentUserFullControl(dir);
            }
            string wpfDir = Path.Combine(dir, "WPF");
            if (!Directory.Exists(wpfDir)) Directory.CreateDirectory(wpfDir);

            string probe = Path.Combine(wpfDir, "write-probe-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var fs = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                fs.WriteByte(0x70);
            }
            try { File.Delete(probe); } catch { }
            return true;
        }
        catch (Exception ex)
        {
            reason = ex.GetType().Name + ": " + ex.Message;
            return false;
        }
    }

    static void TryGrantCurrentUserFullControl(string dir)
    {
        try
        {
            var identity = WindowsIdentity.GetCurrent();
            if (identity == null || identity.User == null) return;
            var info = new DirectoryInfo(dir);
            DirectorySecurity security = info.GetAccessControl();
            security.AddAccessRule(new FileSystemAccessRule(
                identity.User,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow));
            info.SetAccessControl(security);
        }
        catch { }
    }
}

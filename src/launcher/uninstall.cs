// 独立卸载入口：不驻留、不提权、不依赖已经移除的 GUI。
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
static class Uninstall {
    [STAThread] static int Main() {
        try {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string script = Path.Combine(root, "src", "pinyin-gui", "uninstall-app.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("卸载组件不完整，请重新解压完整发行文件后重试。", script);
            var psi = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\" -BaseDir \"" + root + "\" -LauncherPid " + Process.GetCurrentProcess().Id,
                WorkingDirectory = Path.GetTempPath(), UseShellExecute = false, CreateNoWindow = true
            };
            using (Process child = Process.Start(psi)) {
                if (child == null) throw new Exception("无法启动卸载界面。");
            }
            // 立即退出，让卸载脚本可以删除本 exe；脚本会等待本 PID 退出再执行。
            return 0;
        } catch (Exception ex) {
            MessageBox.Show(ex.Message,"卸载程序无法启动",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
}

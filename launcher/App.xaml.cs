using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Markup;
using Moon.Core;
using Moon.ViewModels;

namespace Moon;

public partial class App : Application
{
    Mutex? single;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Italian everywhere, whatever the language of Windows: dates, numbers, the folder dialog's texts
        var it = CultureInfo.GetCultureInfo("it-IT");
        CultureInfo.DefaultThreadCurrentCulture = it;
        CultureInfo.DefaultThreadCurrentUICulture = it;
        Thread.CurrentThread.CurrentCulture = it;
        Thread.CurrentThread.CurrentUICulture = it;
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(it.IetfLanguageTag)));

        var options = Options.Parse(e.Args);

        // one launcher at a time: two of them could copy the same files together. After an update or a restart as
        // administrator the old one is still closing, so the new one waits for it a little.
        var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(options.DataFolder.ToLowerInvariant())))[..16];
        single = new Mutex(false, @"Local\Moon.Launcher." + key);
        bool mine;
        try
        {
            mine = single.WaitOne(options.JustUpdated || e.Args.Contains("--riavvio") ? TimeSpan.FromSeconds(10) : TimeSpan.Zero);
        }
        catch (AbandonedMutexException)
        {
            mine = true;
        }
        if (!mine)
        {
            BringOtherToFront();
            Shutdown();
            return;
        }

        // whatever slipped through: written in errori.log, shown, and the launcher goes on
        DispatcherUnhandledException += (_, a) =>
        {
            a.Handled = true;
            try
            {
                Directory.CreateDirectory(options.DataFolder);
                File.AppendAllText(Path.Combine(options.DataFolder, "errori.log"),
                    $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {SelfUpdate.CurrentText}{Environment.NewLine}{a.Exception}{Environment.NewLine}{Environment.NewLine}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
            MessageBox.Show(a.Exception.Message, "Moon: qualcosa è andato storto", MessageBoxButton.OK, MessageBoxImage.Warning);
        };

        base.OnStartup(e);
        var window = new MainWindow(new MainViewModel(options));
        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { single?.ReleaseMutex(); }
        catch (ApplicationException) { }
        single?.Dispose();
        base.OnExit(e);
    }

    static void BringOtherToFront()
    {
        using var me = Process.GetCurrentProcess();
        foreach (var p in Process.GetProcessesByName(me.ProcessName))
        {
            using (p)
            {
                if (p.Id == me.Id || p.MainWindowHandle == IntPtr.Zero) continue;
                ShowWindow(p.MainWindowHandle, 9);          // SW_RESTORE
                SetForegroundWindow(p.MainWindowHandle);
            }
        }
    }

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);
}

using System.Diagnostics;

namespace Moon.Core;

/// <summary>
/// The launcher updates itself: it downloads the new MoonLauncher.exe next to itself, steps aside (Windows lets a running exe
/// be renamed, not overwritten), puts the new one in its place and starts it. The old one is deleted at the next start.
/// </summary>
public static class SelfUpdate
{
    public const string AssetName = "MoonLauncher.exe";

    public static Version Current { get; } = Normalize(typeof(SelfUpdate).Assembly.GetName().Version);

    public static string CurrentText => Current.ToString(3);

    public static bool IsNewer(string? version) =>
        Version.TryParse(version, out var v) && Normalize(v) > Current;

    static Version Normalize(Version? v) =>
        v is null ? new Version(0, 0, 0, 0) : new Version(v.Major, v.Minor, Math.Max(0, v.Build), Math.Max(0, v.Revision));

    static string Exe => Environment.ProcessPath ?? throw new InvalidOperationException("Non so dove si trova il launcher.");

    /// <summary>Deletes what the previous update left behind.</summary>
    public static void CleanUp()
    {
        Task.Run(async () =>
        {
            foreach (var leftover in new[] { Exe + ".vecchio", Exe + ".nuovo" })
            {
                for (var i = 0; i < 10 && File.Exists(leftover); i++)
                {
                    try { File.Delete(leftover); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { await Task.Delay(500); }
                }
            }
        });
    }

    /// <summary>Downloads and swaps the exe. The caller then starts the new one and closes this one.</summary>
    public static async Task ApplyAsync(GitHub github, ReleaseAsset asset, IProgress<double> progress, CancellationToken ct)
    {
        var exe = Exe;
        var next = exe + ".nuovo";
        var old = exe + ".vecchio";
        try
        {
            await github.DownloadAsync(asset.Url, next, progress, ct, asset.Size, asset.Digest);
            File.Move(exe, old, overwrite: true);
        }
        catch (UnauthorizedAccessException e)
        {
            throw new InstallerException("Non posso aggiornare il launcher nella cartella dove si trova.",
                $"Scarica il nuovo MoonLauncher.exe dalla pagina delle release: {GitHub.ReleasesPage}", false, e);
        }
        try
        {
            File.Move(next, exe);
        }
        catch
        {
            File.Move(old, exe, overwrite: true);
            throw;
        }
    }

    public static void Restart(IEnumerable<string> args, bool asAdmin = false)
    {
        var info = new ProcessStartInfo(Exe) { UseShellExecute = asAdmin };
        if (asAdmin) info.Verb = "runas";
        foreach (var a in args) info.ArgumentList.Add(a);
        Process.Start(info)?.Dispose();
    }
}

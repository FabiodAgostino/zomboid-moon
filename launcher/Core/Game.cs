using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Moon.Core;

/// <summary>Finds Project Zomboid, tells whether it is running and starts it through Steam.</summary>
public static partial class Game
{
    public const string SteamAppId = "108600";
    const string Exe = "ProjectZomboid64.exe";

    /// <summary>A folder is the game when it has the game's Lua folder and its launcher, as for the bat.</summary>
    public static bool IsGame(string? folder) =>
        !string.IsNullOrWhiteSpace(folder)
        && Directory.Exists(Path.Combine(folder, "media", "lua", "client"))
        && File.Exists(Path.Combine(folder, Exe));

    /// <summary>The folder given to the launcher, the one chosen last time, Steam's own folder, every Steam library.</summary>
    public static string? Find(params string?[] preferred)
    {
        foreach (var p in preferred)
            if (IsGame(p)) return p;
        foreach (var p in SteamCandidates())
            if (IsGame(p)) return p;
        return null;
    }

    static IEnumerable<string> SteamCandidates()
    {
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        yield return Path.Combine(pf86, "Steam", "steamapps", "common", "ProjectZomboid");

        string? steam = null;
        try
        {
            steam = (Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam")?.GetValue("SteamPath") as string)
                ?.Replace('/', '\\');
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
        }
        if (steam is not null) yield return Path.Combine(steam, "steamapps", "common", "ProjectZomboid");
        steam ??= Path.Combine(pf86, "Steam");

        // libraryfolders.vdf lists every library, with doubled backslashes: "path"  "D:\\SteamLibrary"
        var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
        string text;
        try
        {
            text = File.Exists(vdf) ? File.ReadAllText(vdf) : "";
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            text = "";
        }
        foreach (Match m in LibraryPath().Matches(text))
            yield return Path.Combine(m.Groups[1].Value.Replace(@"\\", @"\"), "steamapps", "common", "ProjectZomboid");
    }

    [GeneratedRegex("\"path\"\\s+\"([^\"]+)\"", RegexOptions.IgnoreCase)]
    private static partial Regex LibraryPath();

    public static bool IsRunning()
    {
        var running = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(Exe));
        foreach (var p in running) p.Dispose();
        return running.Length > 0;
    }

    /// <summary>Starts the game through Steam; without Steam's link, the game's own exe. Returns what it did.</summary>
    public static string Launch(string? gameFolder, bool dryRun, bool dryRunFails = false)
    {
        if (dryRunFails) throw new Win32Exception("Prova: Steam non risponde e la cartella del gioco non c'è.");
        if (dryRun) return $"prova: avvierei steam://rungameid/{SteamAppId}";
        try
        {
            Process.Start(new ProcessStartInfo($"steam://rungameid/{SteamAppId}") { UseShellExecute = true })?.Dispose();
            return "steam";
        }
        catch (Win32Exception) when (IsGame(gameFolder))
        {
            Process.Start(new ProcessStartInfo(Path.Combine(gameFolder!, Exe))
            {
                UseShellExecute = true,
                WorkingDirectory = gameFolder!,
            })?.Dispose();
            return "exe";
        }
    }
}

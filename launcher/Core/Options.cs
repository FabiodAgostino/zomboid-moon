namespace Moon.Core;

/// <summary>
/// What the command line says. A folder dropped onto MoonLauncher.exe arrives as the first argument and is taken as the
/// game's folder, like with the old mod-moon-server.bat. The other switches are for trying the launcher on fake
/// folders without touching the real game:
///   --gioco &lt;cartella&gt;     the game's folder (ProjectZomboid)
///   --zomboid &lt;cartella&gt;   the user's Zomboid folder (normally %UserProfile%\Zomboid)
///   --dati &lt;cartella&gt;      where the launcher keeps its state and its downloads (normally %LocalAppData%\Moon)
///   --sorgente &lt;cartella&gt;  take the mods from a local copy of the repo instead of GitHub
///   --api &lt;url&gt;           GitHub's API address (a fake server, for the tests)
///   --prova                does everything but start the game
///   --prova-errore         like --prova, and starting the game fails
/// </summary>
public sealed class Options
{
    public string? GameFolder { get; private set; }
    public string ZomboidFolder { get; private set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Zomboid");
    public string DataFolder { get; private set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Moon");
    public string? SourceFolder { get; private set; }
    public string ApiBase { get; private set; } = "https://api.github.com";
    public bool DryRun { get; private set; }
    public bool DryRunFails { get; private set; }
    public bool JustUpdated { get; private set; }

    /// <summary>The arguments as they were, to start the launcher again after an update or as administrator.</summary>
    public IReadOnlyList<string> Raw { get; private set; } = [];

    public static Options Parse(IReadOnlyList<string> args)
    {
        var o = new Options { Raw = args.Where(a => a is not ("--aggiornato" or "--riavvio")).ToList() };
        for (var i = 0; i < args.Count; i++)
        {
            var a = args[i];
            string Next() => i + 1 < args.Count ? args[++i] : "";
            switch (a.ToLowerInvariant())
            {
                case "--gioco": o.GameFolder = Full(Next()); break;
                case "--zomboid": o.ZomboidFolder = Full(Next()); break;
                case "--dati": o.DataFolder = Full(Next()); break;
                case "--sorgente": o.SourceFolder = Full(Next()); break;
                case "--api": o.ApiBase = Next().TrimEnd('/'); break;
                case "--prova": o.DryRun = true; break;
                case "--prova-errore": o.DryRun = o.DryRunFails = true; break;
                case "--aggiornato": o.JustUpdated = true; break;
                default:
                    if (!a.StartsWith("--", StringComparison.Ordinal) && o.GameFolder is null) o.GameFolder = Full(a);
                    break;
            }
        }
        return o;
    }

    static string Full(string path) => string.IsNullOrWhiteSpace(path) ? "" : Path.GetFullPath(path.Trim().Trim('"'));
}

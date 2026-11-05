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
///   --pacchetto &lt;cartella&gt; the package of Jukebox (Moon) from a folder made by tools/jukebox, not from GitHub
///   --riscatta &lt;url&gt;      where the music's codes are redeemed instead of mods.json's (a fake ZomBOT, for the tests):
///                          only with --prova, and http only on this computer (127.0.0.1, localhost)
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
    public string? PackFolder { get; private set; }
    public string ApiBase { get; private set; } = "https://api.github.com";
    /// <summary>--riscatta, accepted only with --prova: the real codes never go anywhere but to mods.json's address.</summary>
    public Uri? RedeemUrl { get; private set; }
    public bool DryRun { get; private set; }
    public bool DryRunFails { get; private set; }
    public bool JustUpdated { get; private set; }

    /// <summary>The arguments as they were, to start the launcher again after an update or as administrator.</summary>
    public IReadOnlyList<string> Raw { get; private set; } = [];

    public static Options Parse(IReadOnlyList<string> args)
    {
        var o = new Options { Raw = args.Where(a => a is not ("--aggiornato" or "--riavvio")).ToList() };
        string? redeem = null;
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
                case "--pacchetto": o.PackFolder = Full(Next()); break;
                case "--api": o.ApiBase = Next().TrimEnd('/'); break;
                case "--riscatta": redeem = Next(); break;
                case "--prova": o.DryRun = true; break;
                case "--prova-errore": o.DryRun = o.DryRunFails = true; break;
                case "--aggiornato": o.JustUpdated = true; break;
                default:
                    if (!a.StartsWith("--", StringComparison.Ordinal) && o.GameFolder is null) o.GameFolder = Full(a);
                    break;
            }
        }
        if (o.DryRun && Uri.TryCreate(redeem, UriKind.Absolute, out var url)
                     && (url.Scheme == Uri.UriSchemeHttps || (url.Scheme == Uri.UriSchemeHttp && url.IsLoopback)))
            o.RedeemUrl = url;
        return o;
    }

    static string Full(string path) => string.IsNullOrWhiteSpace(path) ? "" : Path.GetFullPath(path.Trim().Trim('"'));
}

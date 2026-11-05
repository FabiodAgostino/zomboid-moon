using System.Security.Cryptography;
using System.Text.Json;

namespace Moon.Core;

/// <summary>
/// mods.json, at the top of the repo: the mods the launcher offers and where their files go. A new mod is a new
/// entry there, the launcher does not change. Destinations start with {zomboid} (the user's Zomboid folder) or {game}
/// (the game's folder); "from" is a file or a folder of the repo, and a folder brings all its files.
/// "mirror" makes the destination folder an exact copy (like robocopy /MIR): what is not in the mod is deleted.
/// A mod's version can be written there or read from a file of the mod (its VERSION file, the modversion of mod.info);
/// its "state" says whether it can be installed ("installabile", the default) or not ("disattivata").
/// </summary>
public sealed class Manifest
{
    public string Launcher { get; set; } = "0.0.0";
    public List<ModDef> Mods { get; set; } = [];

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static Manifest Load(string path)
    {
        var m = Parse(File.ReadAllText(path));
        var root = Path.GetDirectoryName(Path.GetFullPath(path))!;
        foreach (var mod in m.Mods)
        {
            if (!string.IsNullOrWhiteSpace(mod.VersionFile))
                mod.Version = VersionFile.Read(Path.Combine(root, mod.VersionFile), mod.VersionKey)
                              ?? throw new InvalidDataException($"mods.json: la versione di «{mod.Name}» dovrebbe essere in {mod.VersionFile}, che non la contiene.");
            if (string.IsNullOrWhiteSpace(mod.Version))
                throw new InvalidDataException($"mods.json: «{mod.Name}» non ha una versione.");
        }
        return m;
    }

    /// <summary>mods.json without its files: a release's, to know which versions it had, or the main branch's state.</summary>
    public static Manifest Parse(string json)
    {
        var m = JsonSerializer.Deserialize<Manifest>(json, Json) ?? throw new InvalidDataException("mods.json è vuoto.");
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var mod in m.Mods)
        {
            if (string.IsNullOrWhiteSpace(mod.Id) || !ids.Add(mod.Id))
                throw new InvalidDataException($"mods.json: la mod «{mod.Name}» non ha un id, o ce l'ha uguale a un'altra.");
            if (string.IsNullOrWhiteSpace(mod.Name)) mod.Name = mod.Id;
            if (mod.Install.Count == 0)
                throw new InvalidDataException($"mods.json: la mod «{mod.Name}» non dice cosa installare.");
            if (mod.State is not null && !ModDef.States.Contains(mod.State, StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException($"mods.json: lo stato di «{mod.Name}» è «{mod.State}»: può essere «installabile» o «disattivata».");
            foreach (var e in mod.Install)
            {
                e.To = Target.Normalize(e.To, mod.Name);
                if (e.Mirror && (Target.IsGame(e.To) || Target.Depth(e.To) < 2))
                    throw new InvalidDataException(
                        $"mods.json: «{mod.Name}» chiede di rendere identica la cartella {e.To}: si può solo per una cartella sua dentro {{zomboid}}, come {{zomboid}}/mods/{mod.Name}.");
            }
        }
        foreach (var mod in m.Mods.Where(x => x.Pack is not null))
        {
            var pack = mod.Pack!;
            if (string.IsNullOrWhiteSpace(pack.Release) || pack.Release.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not '-' and not '_' and not '.'))
                throw new InvalidDataException($"mods.json: il pacchetto di «{mod.Name}» deve dire la sua release, come \"jukebox\".");
            pack.To = Target.Normalize(pack.To, mod.Name);
            pack.KeyFile = Target.Normalize(pack.KeyFile, mod.Name);
            if (Target.IsGame(pack.To) || Target.Depth(pack.To) < 2 || Target.IsGame(pack.KeyFile))
                throw new InvalidDataException($"mods.json: il pacchetto di «{mod.Name}» va in una cartella sua dentro {{zomboid}}.");
            if (!mod.Install.Any(e => e.Mirror && e.To.Equals(pack.To, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException($"mods.json: il pacchetto di «{mod.Name}» va nella cartella della mod ({pack.To}), installata con mirror.");
        }
        foreach (var mod in m.Mods.Where(x => x.Replaces is not null))
        {
            var files = mod.Replaces!.Files;
            for (var i = 0; i < files.Count; i++)
            {
                files[i] = Target.Normalize(files[i], mod.Name);
                if (Target.Depth(files[i]) < 2)
                    throw new InvalidDataException($"mods.json: «{mod.Name}» vuole togliere {files[i]}: si tolgono solo file, non cartelle intere.");
            }
        }
        return m;
    }
}

/// <summary>
/// The mods that a mod takes the place of, and their old files to remove wherever they still are. ZomBOT (Moon) holds
/// ZomBOT and Admin-Scorte, which used to be copied into the game's folder: the game loads those files on every
/// server, and a server that checks the Lua files kicks whoever has them. A launcher older than 1.0.2 does not know
/// this field and skips it, so mods.json stays readable for it.
/// </summary>
public sealed class ReplacesDef
{
    /// <summary>The ids of mods.json's mods it replaces: their cards are not shown any more.</summary>
    public List<string> Mods { get; set; } = [];
    /// <summary>What they were, for the messages: «ZomBOT e Admin-Scorte».</summary>
    public string What { get; set; } = "";
    /// <summary>The old files to delete when they are there: exactly these, and nothing else.</summary>
    public List<string> Files { get; set; } = [];
}

public sealed class ModDef
{
    public static readonly string[] States = ["installabile", "disattivata"];

    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    /// <summary>A file of the mod with its version: the whole first line, or the value of VersionKey.</summary>
    public string? VersionFile { get; set; }
    public string? VersionKey { get; set; }
    /// <summary>"installabile" or "disattivata": a disabled mod is not installed nor updated.</summary>
    public string? State { get; set; }
    public string? StateNote { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool Disabled => string.Equals(State, "disattivata", StringComparison.OrdinalIgnoreCase);
    /// <summary>Needed to join the server: GIOCA offers to install it first.</summary>
    public bool Required { get; set; }
    public string? Audience { get; set; }
    public string? Summary { get; set; }
    public string? Note { get; set; }
    public string? AfterInstall { get; set; }
    /// <summary>A picture in the repo for the mod's card.</summary>
    public string? Image { get; set; }
    /// <summary>
    /// Where to read the installed version. With a key it is a line of a file of the mod (modversion= of mod.info);
    /// without, it is a marker of one line that the launcher writes next to the mod and deletes with it, like the bat.
    /// </summary>
    public VersionProbe? InstalledVersion { get; set; }
    public List<InstallEntry> Install { get; set; } = [];
    /// <summary>The mods this one replaces and their old files to remove (ZomBOT (Moon): ZomBOT and Admin-Scorte).</summary>
    public ReplacesDef? Replaces { get; set; }
    /// <summary>Files of the mod that are not in the repo: Jukebox (Moon)'s catalogue and music (Core/Pack.cs).</summary>
    public PackDef? Pack { get; set; }
}

/// <summary>
/// A package published as the assets of a pre-release of the repo (the launcher never takes a pre-release for its own):
/// manifest.json, a public zip and encrypted .jbm files, made by tools/jukebox. Its files are installed in the mod's own
/// folder with the repo's (To, the folder of the mod's mirror entry). The key that opens the .jbm files is written by
/// the game, when the player enters the server, in KeyFile. A launcher older than 1.0.3 does not know this field.
/// </summary>
public sealed class PackDef
{
    /// <summary>The tag of the pre-release, «jukebox».</summary>
    public string Release { get; set; } = "";
    /// <summary>Where the files go: the mod's folder, «{zomboid}/mods/JukeboxMoon».</summary>
    public string To { get; set; } = "";
    /// <summary>Where the game writes the key: «{zomboid}/Lua/JukeboxMoon_key.txt».</summary>
    public string KeyFile { get; set; } = "";
}

public sealed class VersionProbe
{
    public string File { get; set; } = "";
    public string? Key { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsMarker => string.IsNullOrWhiteSpace(Key);
}

public static class VersionFile
{
    /// <summary>The first line of the file, or the value of key=value; null when the file or the key is not there.</summary>
    public static string? Read(string path, string? key)
    {
        if (!File.Exists(path)) return null;
        foreach (var raw in File.ReadLines(path))
        {
            var line = raw.Trim();
            if (string.IsNullOrWhiteSpace(key))
            {
                if (line.Length > 0) return line;
                continue;
            }
            var i = line.IndexOf('=');
            if (i > 0 && line[..i].Trim().Equals(key, StringComparison.OrdinalIgnoreCase)) return line[(i + 1)..].Trim();
        }
        return null;
    }
}

public sealed class InstallEntry
{
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public bool Mirror { get; set; }
}

/// <summary>Destinations as written in mods.json: "{zomboid}/mods/Silenziatori/42/mod.info".</summary>
public static class Target
{
    public const string Zomboid = "{zomboid}";
    public const string Game = "{game}";

    public static string Normalize(string target, string mod)
    {
        var t = target.Trim().Replace('\\', '/');
        while (t.Contains("//", StringComparison.Ordinal)) t = t.Replace("//", "/", StringComparison.Ordinal);
        t = t.TrimEnd('/');
        var ok = t.StartsWith(Zomboid + "/", StringComparison.OrdinalIgnoreCase)
                 || t.StartsWith(Game + "/", StringComparison.OrdinalIgnoreCase);
        var parts = t.Split('/');
        if (!ok || parts.Skip(1).Any(p => p is "" or "." or ".." || p.Contains(':')))
            throw new InvalidDataException(
                $"mods.json: «{mod}» installa in «{target}»: la destinazione deve cominciare con {{zomboid}}/ o {{game}}/ e restare lì dentro.");
        return (parts[0].Equals(Game, StringComparison.OrdinalIgnoreCase) ? Game : Zomboid) + t[parts[0].Length..];
    }

    public static bool IsGame(string target) => target.StartsWith(Game + "/", StringComparison.OrdinalIgnoreCase);

    public static int Depth(string target) => target.Split('/').Length - 1;

    public static string Combine(string folder, string relative) => folder + "/" + relative.Replace('\\', '/');

    public static readonly StringComparer Comparer = StringComparer.OrdinalIgnoreCase;
}

/// <summary>The folders behind {zomboid} and {game}. The game's folder can be unknown.</summary>
public sealed record Roots(string Zomboid, string? Game)
{
    public string? Resolve(string target)
    {
        var root = Target.IsGame(target) ? Game : Zomboid;
        if (root is null) return null;
        var rest = target[(target.IndexOf('/') + 1)..].Replace('/', Path.DirectorySeparatorChar);
        return Path.Combine(root, rest);
    }
}

public sealed record PlannedFile(string Source, string Target, long Size, string Hash);

/// <summary>A mod with every file it installs, read from the folder where mods.json is.</summary>
public sealed class ModPlan
{
    public required ModDef Def { get; init; }
    public required IReadOnlyList<PlannedFile> Files { get; init; }
    public required IReadOnlyList<string> Mirrors { get; init; }
    public string? ImagePath { get; init; }
    /// <summary>Downloads what the plan needs before installing (a package's files): null when it has everything.</summary>
    public Func<IProgress<Step>, CancellationToken, Task>? Fetch { get; init; }
    /// <summary>After a good install: what can go (the package's downloads).</summary>
    public Action? Cleanup { get; init; }
    /// <summary>A word for the mod's card (the music that will come).</summary>
    public string? Notice { get; init; }

    HashSet<string>? targets;
    public HashSet<string> Targets => targets ??= new HashSet<string>(Files.Select(f => f.Target), Target.Comparer);
    public bool NeedsGame => Files.Any(f => Target.IsGame(f.Target)) || Mirrors.Any(Target.IsGame);
    public long TotalBytes => Files.Sum(f => f.Size);

    public static List<ModPlan> Build(Manifest manifest, string root) => manifest.Mods.Select(d => Build(d, root)).ToList();

    public static ModPlan Build(ModDef def, string root)
    {
        var files = new List<PlannedFile>();
        var mirrors = new List<string>();
        foreach (var e in def.Install)
        {
            var from = Path.GetFullPath(Path.Combine(root, e.From.Replace('/', Path.DirectorySeparatorChar)));
            if (!from.StartsWith(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException($"mods.json: «{def.Name}» prende i file da fuori dal pacchetto: {e.From}");
            if (Directory.Exists(from))
            {
                foreach (var f in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories)
                             .Order(StringComparer.OrdinalIgnoreCase))
                    files.Add(Plan(f, Target.Combine(e.To, Path.GetRelativePath(from, f))));
                if (e.Mirror) mirrors.Add(e.To);
            }
            else if (File.Exists(from))
            {
                files.Add(Plan(from, e.To));
            }
            else
            {
                throw new InvalidDataException($"Nel pacchetto delle mod manca «{e.From}», che serve a {def.Name}.");
            }
        }
        string? image = null;
        if (!string.IsNullOrWhiteSpace(def.Image))
        {
            var p = Path.GetFullPath(Path.Combine(root, def.Image));
            if (File.Exists(p)) image = p;
        }
        return new ModPlan { Def = def, Files = files, Mirrors = mirrors, ImagePath = image };
    }

    static PlannedFile Plan(string source, string target)
    {
        var info = new FileInfo(source);
        return new PlannedFile(source, target, info.Length, Hash(source));
    }

    public static string Hash(string path) => HashCache.Of(path);
}

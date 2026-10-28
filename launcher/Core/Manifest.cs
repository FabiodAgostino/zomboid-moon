using System.Security.Cryptography;
using System.Text.Json;

namespace Moon.Core;

/// <summary>
/// mods.json, at the top of the repo: the mods the launcher offers and where their files go. A new mod is a new
/// entry there, the launcher does not change. Destinations start with {zomboid} (the user's Zomboid folder) or {game}
/// (the game's folder); "from" is a file or a folder of the repo, and a folder brings all its files.
/// "mirror" makes the destination folder an exact copy (like robocopy /MIR): what is not in the mod is deleted.
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
        var m = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(path), Json)
                ?? throw new InvalidDataException("mods.json è vuoto.");
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var mod in m.Mods)
        {
            if (string.IsNullOrWhiteSpace(mod.Id) || !ids.Add(mod.Id))
                throw new InvalidDataException($"mods.json: la mod «{mod.Name}» non ha un id, o ce l'ha uguale a un'altra.");
            if (string.IsNullOrWhiteSpace(mod.Name)) mod.Name = mod.Id;
            if (mod.Install.Count == 0)
                throw new InvalidDataException($"mods.json: la mod «{mod.Name}» non dice cosa installare.");
            foreach (var e in mod.Install)
            {
                e.To = Target.Normalize(e.To, mod.Name);
                if (e.Mirror && (Target.IsGame(e.To) || Target.Depth(e.To) < 2))
                    throw new InvalidDataException(
                        $"mods.json: «{mod.Name}» chiede di rendere identica la cartella {e.To}: si può solo per una cartella sua dentro {{zomboid}}, come {{zomboid}}/mods/{mod.Name}.");
            }
        }
        return m;
    }
}

public sealed class ModDef
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    /// <summary>Needed to join the server: GIOCA offers to install it first.</summary>
    public bool Required { get; set; }
    public string? Audience { get; set; }
    public string? Summary { get; set; }
    public string? Note { get; set; }
    public string? AfterInstall { get; set; }
    /// <summary>A picture in the repo for the mod's card.</summary>
    public string? Image { get; set; }
    /// <summary>Where to read the installed version, when it was not the launcher that installed it.</summary>
    public VersionProbe? InstalledVersion { get; set; }
    public List<InstallEntry> Install { get; set; } = [];
}

public sealed class VersionProbe
{
    public string File { get; set; } = "";
    public string Key { get; set; } = "";
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

    HashSet<string>? targets;
    public HashSet<string> Targets => targets ??= new HashSet<string>(Files.Select(f => f.Target), Target.Comparer);
    public bool NeedsGame => Files.Any(f => Target.IsGame(f.Target)) || Mirrors.Any(Target.IsGame);
    public long TotalBytes => Files.Sum(f => f.Size);

    public static List<ModPlan> Build(Manifest manifest, string root)
    {
        var plans = new List<ModPlan>();
        foreach (var def in manifest.Mods)
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
            plans.Add(new ModPlan { Def = def, Files = files, Mirrors = mirrors, ImagePath = image });
        }
        return plans;
    }

    static PlannedFile Plan(string source, string target)
    {
        var info = new FileInfo(source);
        return new PlannedFile(source, target, info.Length, Hash(source));
    }

    public static string Hash(string path)
    {
        using var s = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(s));
    }
}

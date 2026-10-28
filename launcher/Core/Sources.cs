using System.IO.Compression;

namespace Moon.Core;

/// <summary>The folder with mods.json and the mods' files, and where it came from.</summary>
public sealed class ModSource
{
    public required string Root { get; init; }
    public required Manifest Manifest { get; init; }
    public required string Label { get; init; }
    public Release? Release { get; init; }
    public bool Offline { get; init; }
}

/// <summary>
/// Where the mods come from: the latest release on GitHub (its moon-mods.zip, or GitHub's own zip of the code),
/// the main branch while there is no release yet, the copy downloaded last time when offline. A release is
/// downloaded once and kept in the cache folder until the next one comes out.
/// </summary>
public sealed class Sources(GitHub github, string cacheFolder, string? localFolder)
{
    public const string PackageAsset = "moon-mods.zip";

    string Folder => Path.Combine(cacheFolder, "mod");

    public async Task<ModSource> ResolveAsync(IReadOnlyList<Release>? releases, bool offline, IProgress<Step> progress,
        CancellationToken ct)
    {
        if (localFolder is not null)
        {
            return new ModSource
            {
                Root = localFolder,
                Manifest = Manifest.Load(Path.Combine(localFolder, "mods.json")),
                Label = $"Cartella locale {localFolder}",
            };
        }

        var latest = releases?.FirstOrDefault(r => !r.Draft && !r.Prerelease);
        if (latest is not null)
        {
            var key = Safe(latest.Tag);
            var label = $"Release {latest.Tag} del {latest.Published.ToLocalTime():d MMMM yyyy}";
            if (Open(key) is { } root) return Make(root, label, latest, offline);
            if (!offline)
            {
                var asset = latest.Asset(PackageAsset);
                await DownloadAsync(asset?.Url ?? latest.ZipballUrl, key, asset?.Size, asset?.Digest,
                    $"Scarico le mod di {latest.Tag}", progress, ct);
                return Make(Open(key)!, label, latest, false);
            }
        }
        else if (!offline && releases is not null)
        {
            // no release yet: the latest files of the main branch
            var sha = await github.BranchShaAsync("main", ct);
            var key = "main-" + Safe(sha[..Math.Min(12, sha.Length)]);
            const string label = "Ultime modifiche su GitHub (non c'è ancora una release)";
            if (Open(key) is { } root) return Make(root, label, null, false);
            await DownloadAsync(github.BranchZipUrl("main"), key, null, null, "Scarico le mod da GitHub", progress, ct);
            return Make(Open(key)!, label, null, false);
        }

        // offline: the newest copy downloaded before
        var cached = Directory.Exists(Folder)
            ? new DirectoryInfo(Folder).EnumerateDirectories().Where(d => !d.Name.EndsWith(".tmp", StringComparison.Ordinal))
                .OrderByDescending(d => d.LastWriteTimeUtc).FirstOrDefault(d => Open(d.Name) is not null)
            : null;
        if (cached is not null)
            return Make(Open(cached.Name)!, $"Non in linea: uso le mod scaricate il {cached.LastWriteTime:d MMMM yyyy}",
                null, true);
        throw new InvalidOperationException(
            "Non riesco a scaricare le mod da GitHub e non ne ho una copia: controlla la connessione e riprova.");
    }

    static ModSource Make(string root, string label, Release? release, bool offline) => new()
    {
        Root = root,
        Manifest = Manifest.Load(Path.Combine(root, "mods.json")),
        Label = label,
        Release = release,
        Offline = offline,
    };

    /// <summary>The folder with mods.json inside a downloaded copy: at its top, or one level down in GitHub's zip.</summary>
    string? Open(string key)
    {
        var dir = Path.Combine(Folder, key);
        if (!Directory.Exists(dir)) return null;
        if (File.Exists(Path.Combine(dir, "mods.json"))) return dir;
        return Directory.EnumerateDirectories(dir).FirstOrDefault(d => File.Exists(Path.Combine(d, "mods.json")));
    }

    async Task DownloadAsync(string url, string key, long? size, string? digest, string title, IProgress<Step> progress,
        CancellationToken ct)
    {
        Directory.CreateDirectory(Folder);
        var zip = Path.Combine(Folder, key + ".zip");
        var tmp = Path.Combine(Folder, key + ".tmp");
        var dir = Path.Combine(Folder, key);
        progress.Report(new(0, title, url));
        await github.DownloadAsync(url, zip, new Progress<double>(f => progress.Report(new(f * 0.9, title, url))), ct,
            size, digest);
        progress.Report(new(0.92, title, "estraggo i file"));
        await Task.Run(() =>
        {
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            ZipFile.ExtractToDirectory(zip, tmp);
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            Directory.Move(tmp, dir);
            File.Delete(zip);
        }, ct);
        if (Open(key) is null)
            throw new InvalidDataException("Nel pacchetto scaricato da GitHub non c'è mods.json.");
        // the older copies are not needed any more
        foreach (var old in Directory.EnumerateDirectories(Folder))
        {
            if (Path.GetFileName(old).Equals(key, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.Delete(old, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    static string Safe(string s) => string.Concat(s.Select(c => char.IsLetterOrDigit(c) || c is '.' or '-' or '_' ? c : '_'));
}

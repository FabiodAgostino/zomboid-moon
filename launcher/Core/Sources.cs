using System.Collections.Concurrent;
using System.IO.Compression;
using System.Text.Json;

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

/// <summary>A version of a mod and the release it is installed from (null: the copy in use).</summary>
public sealed record ModVersion(string Version, Release? Release, bool Latest);

/// <summary>
/// Where the mods come from: the latest release on GitHub (its moon-mods.zip, or GitHub's own zip of the code),
/// the main branch while there is no release yet, the copy downloaded last time when offline. A release is
/// downloaded once and kept in the cache folder. The older releases give the older versions of every mod, and the
/// main branch says, at every start, which mods are disabled.
/// </summary>
public sealed class Sources(GitHub github, string cacheFolder, string? localFolder)
{
    public const string PackageAsset = "moon-mods.zip";
    public const string ManifestAsset = "mods.json";

    readonly HashSet<string> keep = new(StringComparer.OrdinalIgnoreCase);

    string Folder => Path.Combine(cacheFolder, "mod");

    public static Release? Latest(IReadOnlyList<Release>? releases) =>
        releases?.FirstOrDefault(r => !r.Draft && !r.Prerelease);

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

        var latest = Latest(releases);
        if (latest is not null)
        {
            keep.Add(Safe(latest.Tag));
            var label = $"Release {latest.Tag} del {latest.Published.ToLocalTime():d MMMM yyyy}";
            if (await RootAsync(latest, offline, progress, ct) is { } root) return Make(root, label, latest, offline);
        }
        else if (!offline && releases is not null)
        {
            // no release yet: the latest files of the main branch
            var sha = await github.BranchShaAsync("main", ct);
            var key = "main-" + Safe(sha[..Math.Min(12, sha.Length)]);
            keep.Add(key);
            const string label = "Ultime modifiche su GitHub (non c'è ancora una release)";
            if (Open(key) is null)
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

    /// <summary>The folder with a release's mods, downloaded the first time; null when offline and never downloaded.</summary>
    public async Task<string?> RootAsync(Release release, bool offline, IProgress<Step> progress, CancellationToken ct)
    {
        var key = Safe(release.Tag);
        if (Open(key) is { } root) return root;
        if (offline) return null;
        var asset = release.Asset(PackageAsset);
        await DownloadAsync(asset?.Url ?? release.ZipballUrl, key, asset?.Size, asset?.Digest,
            $"Scarico le mod di {release.Tag}", progress, ct);
        return Open(key) ?? throw new InvalidDataException("Nel pacchetto scaricato da GitHub non c'è mods.json.");
    }

    /// <summary>
    /// Every version of every mod that a release published, newest first. Each release brings its mods.json, which is
    /// small and never changes: it is downloaded once and kept. A version is installed from the newest release that has it.
    /// </summary>
    public async Task<Dictionary<string, List<ModVersion>>> HistoryAsync(ModSource current, IReadOnlyList<Release> releases,
        bool offline, CancellationToken ct)
    {
        var history = new Dictionary<string, List<ModVersion>>(StringComparer.OrdinalIgnoreCase);
        void Add(ModDef def, Release? release, bool latest)
        {
            if (string.IsNullOrWhiteSpace(def.Version)) return;
            if (!history.TryGetValue(def.Id, out var list)) history[def.Id] = list = [];
            if (list.All(v => v.Version != def.Version)) list.Add(new ModVersion(def.Version, release, latest));
        }

        foreach (var def in current.Manifest.Mods) Add(def, current.Release, true);
        if (localFolder is not null) return history;

        var folder = Path.Combine(cacheFolder, "manifesti");
        Directory.CreateDirectory(folder);
        var older = releases.Where(r => !r.Draft && !r.Prerelease && r.Tag != current.Release?.Tag && r.Asset(ManifestAsset) is not null)
            .ToList();
        var manifests = new ConcurrentDictionary<string, Manifest>();
        await Parallel.ForEachAsync(older, new ParallelOptions { MaxDegreeOfParallelism = 6, CancellationToken = ct }, async (r, token) =>
        {
            var file = Path.Combine(folder, Safe(r.Tag) + ".json");
            try
            {
                if (!File.Exists(file))
                {
                    if (offline) return;
                    var asset = r.Asset(ManifestAsset)!;
                    await github.DownloadAsync(asset.Url, file, null, token, asset.Size, asset.Digest);
                }
                manifests[r.Tag] = Manifest.Parse(await File.ReadAllTextAsync(file, token));
            }
            catch (Exception e) when (e is HttpRequestException or IOException or JsonException or InvalidDataException
                                          or TaskCanceledException)
            {
                // a release without a good mods.json simply adds no versions
            }
        });
        foreach (var r in older)
            if (manifests.TryGetValue(r.Tag, out var m))
                foreach (var def in m.Mods) Add(def, r, false);
        return history;
    }

    /// <summary>
    /// The mods as the main branch has them now, for their state: disabling a mod is one line of mods.json and a
    /// commit, without a release. Kept for when GitHub cannot be reached; null when it was never read.
    /// </summary>
    public async Task<Dictionary<string, ModDef>?> LiveAsync(bool offline, CancellationToken ct)
    {
        if (localFolder is not null) return null;
        var file = Path.Combine(cacheFolder, "mods-main.json");
        string? json = null;
        if (!offline)
        {
            try
            {
                json = await github.RawAsync("main", "mods.json", ct);
                Manifest.Parse(json);
                Directory.CreateDirectory(cacheFolder);
                await File.WriteAllTextAsync(file, json, ct);
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException or JsonException
                                          or InvalidDataException)
            {
                json = null;
            }
        }
        if (json is null && File.Exists(file)) json = await File.ReadAllTextAsync(file, ct);
        if (json is null) return null;
        try
        {
            return Manifest.Parse(json).Mods.ToDictionary(m => m.Id, StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is JsonException or InvalidDataException)
        {
            return null;
        }
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
        // the copies of other releases are not needed any more, except the latest one
        foreach (var old in Directory.EnumerateDirectories(Folder))
        {
            var name = Path.GetFileName(old);
            if (name.Equals(key, StringComparison.OrdinalIgnoreCase) || keep.Contains(name)) continue;
            try { Directory.Delete(old, true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    static string Safe(string s) => string.Concat(s.Select(c => char.IsLetterOrDigit(c) || c is '.' or '-' or '_' ? c : '_'));
}

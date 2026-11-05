using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Moon.Core;

public sealed record PackFile(string Path, long Size, string Sha256);

public sealed record PackAsset(string Asset, long Size, string Sha256, IReadOnlyList<PackFile> Files);

public sealed record PackManifest(string CatalogVersion, string PackageVersion, string KeyId, PackAsset Catalog,
    IReadOnlyList<PackAsset> Albums);

/// <summary>
/// The package of a mod that is not in the repo (mods.json, "pack"): Jukebox (Moon)'s catalogue and music, made by
/// tools/jukebox and published as the assets of the pre-release "jukebox" (docs/jukebox/TECHNICAL_DESIGN.md).
///   - manifest.json says every file, with its size and SHA-256;
///   - the public catalogue (a zip) goes to everyone: with it a player enters Moon even without the music;
///   - the music is one .jbm per album, a zip encrypted with AES-256-GCM. The key is written by the game in
///     Zomboid/Lua/JukeboxMoon_key.txt when the player enters the server: before the first time there is no music.
/// The files become part of the mod's plan, like the repo's: the same byte-by-byte check, and the mirror keeps them.
/// Only what is missing or different is downloaded, checked, opened and checked again before it is installed.
/// </summary>
public static partial class Packs
{
    static readonly byte[] Magic = "JBM1"u8.ToArray();
    static readonly byte[] Aad = "JukeboxMoon"u8.ToArray();

    [GeneratedRegex("^(42|common)(/[A-Za-z0-9_.-]+)+$")]
    private static partial Regex SafePath();

    [GeneratedRegex("^[A-Za-z0-9_.-]{1,120}$")]
    private static partial Regex SafeName();

    [GeneratedRegex("^[0-9a-f]{64}$")]
    private static partial Regex Sha();

    public static async Task<List<ModPlan>> AttachAsync(IEnumerable<ModPlan> plans, GitHub github, string cache, Roots roots,
        string? localFolder, bool offline, CancellationToken ct)
    {
        var result = new List<ModPlan>();
        foreach (var plan in plans)
            result.Add(plan.Def.Pack is null ? plan : await AttachAsync(plan, github, cache, roots, localFolder, offline, ct));
        return result;
    }

    /// <summary>The plan with its package's files. Never throws for the package: when it cannot be read the plan has
    /// only the repo's files, a notice, and keeps what is already installed (ModPlan.KeepExtras).</summary>
    public static async Task<ModPlan> AttachAsync(ModPlan plan, GitHub github, string cache, Roots roots, string? localFolder,
        bool offline, CancellationToken ct)
    {
        var repo = plan.Base ?? plan;
        try
        {
            return await AttachCoreAsync(repo, github, cache, roots, localFolder, offline, ct);
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            // a folder that cannot be written, an antivirus holding a file: the other mods go on, this one waits
            return Unresolved(repo, "Non riesco a preparare la musica: riprova più tardi.");
        }
    }

    static async Task<ModPlan> AttachCoreAsync(ModPlan plan, GitHub github, string cache, Roots roots, string? localFolder,
        bool offline, CancellationToken ct)
    {
        var def = plan.Def.Pack!;
        var folder = Path.Combine(cache, "pack", plan.Def.Id);
        Directory.CreateDirectory(folder);
        var manifestPath = Path.Combine(folder, "manifest.json");
        string? trouble = null;
        try
        {
            if (localFolder is not null)
            {
                File.Copy(Path.Combine(localFolder, "manifest.json"), manifestPath, overwrite: true);
            }
            else if (!offline)
            {
                // a GitHub that connects and then says nothing must not keep the launcher on «Controllo le mod»
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));
                await github.DownloadAsync(github.ReleaseFileUrl(def.Release, "manifest.json"), manifestPath, null, timeout.Token);
            }
        }
        catch (HttpRequestException e) when (e.StatusCode == HttpStatusCode.NotFound)
        {
            trouble = "La musica non è ancora pubblicata.";
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
        {
            trouble = "Non riesco a scaricare l'elenco dei CD: uso quello dell'ultima volta.";
        }
        if (!File.Exists(manifestPath)) return Unresolved(plan, trouble ?? "La musica non è ancora pubblicata.");

        PackManifest m;
        try
        {
            m = Parse(await File.ReadAllTextAsync(manifestPath, ct));
        }
        catch (Exception e) when (e is JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException
                                       or FormatException)
        {
            return Unresolved(plan, "L'elenco dei CD non si legge: riprova più tardi.");
        }

        var keyPath = roots.Resolve(def.KeyFile);
        var key = keyPath is null ? null : ReadKey(keyPath);
        var keyOk = key is not null && KeyId(key) == m.KeyId;
        var blobs = Path.Combine(folder, "blobs");
        var files = new List<PlannedFile>(plan.Files);
        var taken = new HashSet<string>(plan.Targets, Target.Comparer);
        var needCatalog = false;
        var needAlbums = new List<PackAsset>();
        var missingAudio = 0;

        PlannedFile? Place(PackFile f, bool canFetch, out bool ready)
        {
            var target = Target.Combine(def.To, f.Path);
            if (!taken.Add(target)) throw new InvalidDataException($"{f.Path} è sia nel repo sia nel pacchetto.");
            var hash = f.Sha256.ToUpperInvariant();
            var installed = roots.Resolve(target);
            if (installed is not null && File.Exists(installed) && new FileInfo(installed).Length == f.Size
                && HashCache.Of(installed) == hash)
            {
                ready = true;
                return new PlannedFile(installed, target, f.Size, hash);
            }
            var blob = Path.Combine(blobs, f.Sha256);
            ready = File.Exists(blob);
            if (!canFetch && !ready)
            {
                taken.Remove(target);
                return null;
            }
            return new PlannedFile(blob, target, f.Size, hash);
        }

        try
        {
            foreach (var f in m.Catalog.Files)
            {
                files.Add(Place(f, true, out var ready)!);
                if (!ready) needCatalog = true;
            }
            foreach (var album in m.Albums)
            {
                var needs = false;
                foreach (var f in album.Files)
                {
                    var p = Place(f, keyOk, out var ready);
                    if (p is null)
                    {
                        missingAudio++;
                        continue;
                    }
                    files.Add(p);
                    if (!ready) needs = true;
                }
                if (needs) needAlbums.Add(album);
            }
        }
        catch (InvalidDataException e)
        {
            return Unresolved(plan, e.Message);
        }

        var notice = missingAudio == 0
            ? trouble
            : key is null
                ? "La musica arriva dopo la tua prima volta su Moon: il gioco mi dà la chiave e la scarico io."
                : "La chiave della musica è cambiata: entra su Moon per avere quella nuova, poi riapri il launcher.";

        async Task Fetch(IProgress<Step> progress, CancellationToken token)
        {
            var assets = new List<(PackAsset Asset, bool Encrypted)>();
            if (needCatalog) assets.Add((m.Catalog, false));
            assets.AddRange(needAlbums.Select(a => (a, true)));
            for (var i = 0; i < assets.Count; i++)
            {
                var (asset, encrypted) = assets[i];
                var share = 0.9 / assets.Count;
                var title = encrypted ? "Scarico la musica" : "Scarico l'elenco dei CD";
                progress.Report(new(i * share, title, $"{i + 1} di {assets.Count} · {asset.Size / 1_000_000.0:0.0} MB"));
                var dest = Path.Combine(folder, "assets", asset.Asset);
                if (!(File.Exists(dest) && new FileInfo(dest).Length == asset.Size && FileSha(dest) == asset.Sha256))
                {
                    if (localFolder is not null)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                        File.Copy(Path.Combine(localFolder, asset.Asset), dest, overwrite: true);
                        if (new FileInfo(dest).Length != asset.Size || FileSha(dest) != asset.Sha256)
                            throw new InvalidDataException($"{asset.Asset} non è quello dell'elenco: riprova.");
                    }
                    else
                    {
                        // DownloadAsync checks size and SHA-256 before the file takes its name
                        var start = i * share;
                        await github.DownloadAsync(github.ReleaseFileUrl(def.Release, asset.Asset), dest,
                            new Progress<double>(f => progress.Report(new(start + f * share, title, $"{i + 1} di {assets.Count}"))),
                            token, asset.Size, "sha256:" + asset.Sha256, stall: TimeSpan.FromSeconds(30));
                    }
                }
                var data = await File.ReadAllBytesAsync(dest, token);
                if (encrypted) data = Decrypt(key!, data);
                Extract(data, asset, blobs);
                File.Delete(dest);
            }
            foreach (var f in files.Where(f => !File.Exists(f.Source)))
                throw new InvalidDataException($"Manca {f.Target} anche dopo lo scaricamento: riprova.");
        }

        void Cleanup()
        {
            try
            {
                if (Directory.Exists(blobs)) Directory.Delete(blobs, recursive: true);
                var assetsDir = Path.Combine(folder, "assets");
                if (Directory.Exists(assetsDir)) Directory.Delete(assetsDir, recursive: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }

        var fetch = needCatalog || needAlbums.Count > 0 ? (Func<IProgress<Step>, CancellationToken, Task>)Fetch : null;
        return With(plan, files, fetch, Cleanup, notice);
    }

    static ModPlan With(ModPlan plan, IReadOnlyList<PlannedFile> files, Func<IProgress<Step>, CancellationToken, Task>? fetch,
        Action? cleanup, string? notice) =>
        new()
        {
            Def = plan.Def, Files = files, Mirrors = plan.Mirrors, ImagePath = plan.ImagePath, Fetch = fetch, Cleanup = cleanup,
            Notice = notice, Base = plan,
        };

    /// <summary>The package could not be read: only the repo's files, and the package's files already installed stay
    /// (without this the mirror would delete the catalogue and the music as files it does not know).</summary>
    static ModPlan Unresolved(ModPlan plan, string notice) =>
        new()
        {
            Def = plan.Def, Files = plan.Files, Mirrors = plan.Mirrors, ImagePath = plan.ImagePath, Notice = notice, Base = plan,
            KeepExtras = true,
        };

    // -----------------------------------------------------------------------------------------------------------------

    public static PackManifest Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var r = doc.RootElement;
        if (r.GetProperty("format").GetInt32() != 1) throw new InvalidDataException("formato sconosciuto");
        var keyId = r.GetProperty("keyId").GetString() ?? "";
        if (!Regex.IsMatch(keyId, "^[0-9a-f]{16}$")) throw new InvalidDataException("keyId");
        return new PackManifest(r.GetProperty("catalogVersion").GetString() ?? "", r.GetProperty("packageVersion").GetString() ?? "",
            keyId, Asset(r.GetProperty("catalog")), r.GetProperty("albums").EnumerateArray().Select(Asset).ToList());
    }

    static PackAsset Asset(JsonElement e)
    {
        var name = e.GetProperty("asset").GetString() ?? "";
        var sha = e.GetProperty("sha256").GetString() ?? "";
        if (!SafeName().IsMatch(name) || !Sha().IsMatch(sha)) throw new InvalidDataException(name);
        var files = e.GetProperty("files").EnumerateArray().Select(f =>
        {
            var path = f.GetProperty("path").GetString() ?? "";
            var hash = f.GetProperty("sha256").GetString() ?? "";
            if (!SafePath().IsMatch(path) || path.Split('/').Any(p => p is "." or "..") || !Sha().IsMatch(hash))
                throw new InvalidDataException(path);
            return new PackFile(path, f.GetProperty("size").GetInt64(), hash);
        }).ToList();
        return new PackAsset(name, e.GetProperty("size").GetInt64(), sha, files);
    }

    /// <summary>The key the game wrote: 64 hex characters on the first line, or null.</summary>
    public static byte[]? ReadKey(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var line = File.ReadLines(path).FirstOrDefault()?.Trim().ToLowerInvariant() ?? "";
            return Regex.IsMatch(line, "^[0-9a-f]{64}$") ? Convert.FromHexString(line) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static string KeyId(byte[] key) => Convert.ToHexString(SHA256.HashData(key))[..16].ToLowerInvariant();

    static string FileSha(string path)
    {
        using var s = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant();
    }

    /// <summary>A .jbm: "JBM1", 12 bytes of nonce, the ciphertext, the 16-byte tag; associated data "JukeboxMoon".</summary>
    public static byte[] Decrypt(byte[] key, byte[] blob)
    {
        if (blob.Length < 4 + 12 + 16 || !blob.AsSpan(0, 4).SequenceEqual(Magic))
            throw new InvalidDataException("Il file della musica non è nel formato giusto.");
        var nonce = blob.AsSpan(4, 12);
        var cipher = blob.AsSpan(16, blob.Length - 16 - 16);
        var tag = blob.AsSpan(blob.Length - 16);
        var plain = new byte[cipher.Length];
        try
        {
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(nonce, cipher, tag, plain, Aad);
        }
        catch (CryptographicException e)
        {
            throw new InvalidDataException("La chiave non apre la musica: entra su Moon per avere quella giusta.", e);
        }
        return plain;
    }

    /// <summary>Every file of the zip into blobs/&lt;sha256&gt;, each checked against the manifest; nothing else.</summary>
    static void Extract(byte[] zip, PackAsset asset, string blobs)
    {
        Directory.CreateDirectory(blobs);
        var expected = asset.Files.ToDictionary(f => f.Path, StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        using var archive = new ZipArchive(new MemoryStream(zip), ZipArchiveMode.Read);
        foreach (var entry in archive.Entries)
        {
            if (!expected.TryGetValue(entry.FullName, out var f) || !seen.Add(entry.FullName) || entry.Length != f.Size)
                throw new InvalidDataException($"{asset.Asset}: {entry.FullName} non è nell'elenco.");
            using var input = entry.Open();
            using var buffer = new MemoryStream((int)f.Size);
            input.CopyTo(buffer);
            var bytes = buffer.ToArray();
            if (Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != f.Sha256)
                throw new InvalidDataException($"{asset.Asset}: {entry.FullName} è diverso dall'elenco.");
            var dest = Path.Combine(blobs, f.Sha256);
            File.WriteAllBytes(dest + ".tmp", bytes);
            File.Move(dest + ".tmp", dest, overwrite: true);
        }
        if (seen.Count != expected.Count) throw new InvalidDataException($"{asset.Asset}: mancano dei file.");
    }
}

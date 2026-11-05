using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace Moon.Core;

public sealed record ReleaseAsset(string Name, string Url, long Size, string? Digest);

public sealed record Release(
    string Tag, string Name, string Body, DateTimeOffset Published, string HtmlUrl, string ZipballUrl,
    bool Draft, bool Prerelease, IReadOnlyList<ReleaseAsset> Assets)
{
    public ReleaseAsset? Asset(string name) =>
        Assets.FirstOrDefault(a => a.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// The releases of the public repo, without an account: GitHub allows 60 questions an hour to every address, and
/// the answer is kept with its ETag, so asking again when nothing changed costs nothing.
/// </summary>
public sealed class GitHub : IDisposable
{
    public const string Repo = "FabiodAgostino/zomboid-moon";
    public static string ReleasesPage => $"https://github.com/{Repo}/releases";

    readonly HttpClient http;
    readonly string api;
    readonly string cache;

    public GitHub(string apiBase, string cacheFolder)
    {
        api = apiBase.TrimEnd('/');
        cache = cacheFolder;
        http = new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        })
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Moon-Launcher", SelfUpdate.Current.ToString(3)));
    }

    /// <summary>The releases, newest first. Throws when GitHub cannot be reached and nothing was kept from before.</summary>
    public async Task<(IReadOnlyList<Release> Releases, bool Offline)> ReleasesAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(cache);
        var body = Path.Combine(cache, "releases.json");
        var etag = Path.Combine(cache, "releases.etag");
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{api}/repos/{Repo}/releases?per_page=50");
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            req.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
            if (File.Exists(body) && File.Exists(etag) && EntityTagHeaderValue.TryParse(File.ReadAllText(etag), out var tag))
                req.Headers.IfNoneMatch.Add(tag);
            using var res = await http.SendAsync(req, timeout.Token);
            if (res.StatusCode == HttpStatusCode.NotModified) return (Parse(await File.ReadAllTextAsync(body, ct)), false);
            res.EnsureSuccessStatusCode();
            var json = await res.Content.ReadAsStringAsync(timeout.Token);
            var list = Parse(json);
            await File.WriteAllTextAsync(body, json, ct);
            if (res.Headers.ETag is { } e) await File.WriteAllTextAsync(etag, e.ToString(), ct);
            else File.Delete(etag);
            return (list, false);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException && !ct.IsCancellationRequested)
        {
            if (File.Exists(body)) return (Parse(await File.ReadAllTextAsync(body, ct)), true);
            throw;
        }
    }

    /// <summary>The commit at the tip of a branch, to know whether the copy downloaded before is still the latest.</summary>
    public async Task<string> BranchShaAsync(string branch, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{api}/repos/{Repo}/commits/{branch}");
        req.Headers.Accept.ParseAdd("application/vnd.github.sha");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        using var res = await http.SendAsync(req, timeout.Token);
        res.EnsureSuccessStatusCode();
        var sha = (await res.Content.ReadAsStringAsync(timeout.Token)).Trim();
        return sha.StartsWith('{') ? JsonDocument.Parse(sha).RootElement.GetProperty("sha").GetString() ?? "" : sha;
    }

    public string BranchZipUrl(string branch) => $"{api}/repos/{Repo}/zipball/{branch}";

    /// <summary>
    /// A file of a branch as it is now, from raw.githubusercontent.com: no account, and no limit of questions an hour.
    /// GitHub keeps it in its cache for up to 5 minutes.
    /// </summary>
    public async Task<string> RawAsync(string branch, string path, CancellationToken ct)
    {
        var url = api == "https://api.github.com"
            ? $"https://raw.githubusercontent.com/{Repo}/{branch}/{path}"
            : $"{api}/raw/{Repo}/{branch}/{path}";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        return await http.GetStringAsync(url, timeout.Token);
    }

    /// <summary>An asset of a release by its tag and name, without the API: github.com serves it from its CDN.</summary>
    public string ReleaseFileUrl(string tag, string name) => api == "https://api.github.com"
        ? $"https://github.com/{Repo}/releases/download/{Uri.EscapeDataString(tag)}/{Uri.EscapeDataString(name)}"
        : $"{api}/releases/download/{Uri.EscapeDataString(tag)}/{Uri.EscapeDataString(name)}";

    /// <summary>Downloads into a .part file and renames it at the end; checks size and SHA-256 when GitHub gives them.</summary>
    /// <param name="stall">When set, a server that sends nothing for this long ends the download with an IOException,
    /// instead of keeping the launcher waiting for ever.</param>
    public async Task DownloadAsync(string url, string dest, IProgress<double>? progress, CancellationToken ct,
        long? expectedSize = null, string? digest = null, TimeSpan? stall = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        var part = dest + ".part";
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct);
        void Wait()
        {
            if (stall is { } s) idle.CancelAfter(s);
        }
        try
        {
            Wait();
            using var res = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, idle.Token);
            res.EnsureSuccessStatusCode();
            var total = res.Content.Headers.ContentLength ?? expectedSize ?? 0;
            await using var input = await res.Content.ReadAsStreamAsync(idle.Token);
            await using var output = File.Create(part);
            var buffer = new byte[81920];
            long done = 0;
            int n;
            Wait();
            while ((n = await input.ReadAsync(buffer, idle.Token)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, n), ct);
                done += n;
                if (total > 0) progress?.Report(Math.Min(1, done / (double)total));
                Wait();
            }
        }
        catch (OperationCanceledException e) when (idle.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            throw new IOException("GitHub ha smesso di rispondere: riprova.", e);
        }
        if (expectedSize is > 0 && new FileInfo(part).Length != expectedSize)
            throw new IOException("Il file scaricato è incompleto: riprova.");
        if (digest is not null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            await using var s = File.OpenRead(part);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(s, ct));
            if (!hash.Equals(digest[7..], StringComparison.OrdinalIgnoreCase))
                throw new IOException("Il file scaricato non corrisponde a quello della release: riprova.");
        }
        File.Move(part, dest, overwrite: true);
    }

    static IReadOnlyList<Release> Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<Release>();
        foreach (var r in doc.RootElement.EnumerateArray())
        {
            var assets = new List<ReleaseAsset>();
            if (r.TryGetProperty("assets", out var a))
                foreach (var x in a.EnumerateArray())
                    assets.Add(new ReleaseAsset(Str(x, "name"), Str(x, "browser_download_url"),
                        x.TryGetProperty("size", out var s) ? s.GetInt64() : 0, NullableStr(x, "digest")));
            var published = r.TryGetProperty("published_at", out var p) && p.ValueKind == JsonValueKind.String
                ? p.GetDateTimeOffset()
                : DateTimeOffset.MinValue;
            list.Add(new Release(Str(r, "tag_name"), NullableStr(r, "name") ?? Str(r, "tag_name"), Str(r, "body"),
                published, Str(r, "html_url"), Str(r, "zipball_url"),
                r.TryGetProperty("draft", out var d) && d.GetBoolean(),
                r.TryGetProperty("prerelease", out var pr) && pr.GetBoolean(), assets));
        }
        return list.OrderByDescending(r => r.Published).ToList();
    }

    static string Str(JsonElement e, string name) => NullableStr(e, name) ?? "";

    static string? NullableStr(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s
            ? s
            : null;

    public void Dispose() => http.Dispose();
}

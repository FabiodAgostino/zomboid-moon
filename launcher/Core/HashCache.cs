using System.Security.Cryptography;
using System.Text.Json;

namespace Moon.Core;

/// <summary>
/// SHA-256 of files, kept by path, size and date: a file that did not change is not read again. With Jukebox (Moon)
/// the music is hundreds of MB, and every start compares every file of every mod (Installer.Status). The cache lives
/// in the launcher's cache folder (hashes.json); without it everything still works, only slower.
/// </summary>
public static class HashCache
{
    sealed record Entry(long Size, long Ticks, string Hash);

    static readonly object Gate = new();
    static Dictionary<string, Entry> entries = new(StringComparer.OrdinalIgnoreCase);
    static string? file;
    static bool dirty;

    public static void Use(string folder)
    {
        lock (Gate)
        {
            file = Path.Combine(folder, "hashes.json");
            try
            {
                if (File.Exists(file))
                    entries = JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(file)) is { } read
                        ? new Dictionary<string, Entry>(read, StringComparer.OrdinalIgnoreCase)
                        : entries;
            }
            catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
            {
                entries = new(StringComparer.OrdinalIgnoreCase);
            }
        }
    }

    public static string Of(string path)
    {
        var info = new FileInfo(path);
        var full = info.FullName;
        lock (Gate)
        {
            if (entries.TryGetValue(full, out var e) && e.Size == info.Length && e.Ticks == info.LastWriteTimeUtc.Ticks)
                return e.Hash;
        }
        string hash;
        using (var s = File.OpenRead(full))
            hash = Convert.ToHexString(SHA256.HashData(s));
        lock (Gate)
        {
            entries[full] = new Entry(info.Length, info.LastWriteTimeUtc.Ticks, hash);
            dirty = true;
        }
        return hash;
    }

    public static void Save()
    {
        lock (Gate)
        {
            if (!dirty || file is null) return;
            try
            {
                // only the files that are still there
                var kept = entries.Where(kv => File.Exists(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(kept));
                File.Move(file + ".tmp", file, overwrite: true);
                dirty = false;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }
}

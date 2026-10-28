using System.Text.Json;

namespace Moon.Core;

/// <summary>What the launcher installed, and which version: installate.json in the data folder.</summary>
public sealed class InstalledState
{
    public Dictionary<string, InstalledMod> Mods { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class InstalledMod
{
    public string Version { get; set; } = "";
    public List<string> Files { get; set; } = [];
    public List<string> Mirrors { get; set; } = [];
    /// <summary>The user chose this version, older than the latest: the launcher leaves it as it is.</summary>
    public bool Pinned { get; set; }
    public DateTimeOffset At { get; set; }
}

/// <summary>The user's choices: impostazioni.json in the data folder.</summary>
public sealed class Settings
{
    public string? GameFolder { get; set; }
}

public sealed class Store
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    readonly string folder;

    public Store(string folder)
    {
        this.folder = folder;
        State = Read<InstalledState>("installate.json") ?? new InstalledState();
        State.Mods = new Dictionary<string, InstalledMod>(State.Mods, StringComparer.OrdinalIgnoreCase);
        Settings = Read<Settings>("impostazioni.json") ?? new Settings();
    }

    public InstalledState State { get; }
    public Settings Settings { get; }
    public string CacheFolder => Path.Combine(folder, "cache");

    public void SaveState() => Write("installate.json", State);
    public void SaveSettings() => Write("impostazioni.json", Settings);

    T? Read<T>(string name) where T : class
    {
        try
        {
            var path = Path.Combine(folder, name);
            return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json) : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    void Write<T>(string name, T value)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, name);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, Json));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}

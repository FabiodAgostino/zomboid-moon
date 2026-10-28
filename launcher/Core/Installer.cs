namespace Moon.Core;

public enum ModState { NotInstalled, Installed, Outdated, NeedsGame }

public sealed record ModStatus(ModState State, string? InstalledVersion, string? Why);

/// <summary>How far an operation is (0..1), what it is doing and on which file.</summary>
public readonly record struct Step(double Fraction, string Title, string Detail);

public sealed class InstallerException(string message, string advice, bool needsAdmin, Exception? inner = null)
    : Exception(message, inner)
{
    public string Advice { get; } = advice;
    public bool NeedsAdmin { get; } = needsAdmin;
}

/// <summary>
/// Installs, checks and removes the mods of mods.json, like mod-moon-server.bat did: a mod is installed when every
/// file is in place and identical, byte by byte; a mirrored folder must also have nothing more. A file that two mods
/// share (ZomBotMenu.lua, in Admin-Scorte and in ZomBOT) stays until the last of them is removed.
/// </summary>
public sealed class Installer(IReadOnlyList<ModPlan> plans, Roots roots, Store store)
{
    public Roots Roots { get; } = roots;
    public IReadOnlyList<ModPlan> Plans { get; } = plans;

    public ModStatus Status(ModPlan plan)
    {
        if (plan.NeedsGame && Roots.Game is null) return new(ModState.NeedsGame, null, null);
        if (!IsPresent(plan)) return new(ModState.NotInstalled, null, null);
        var why = Difference(plan);
        return why is null
            ? new(ModState.Installed, plan.Def.Version, null)
            : new(ModState.Outdated, InstalledVersion(plan), why);
    }

    /// <summary>The mod is on this computer, in some version: one of the files that are only its own is there.</summary>
    public bool IsPresent(ModPlan plan)
    {
        if (plan.Mirrors.Any(m => Roots.Resolve(m) is { } dir && Directory.Exists(dir))) return true;
        var own = plan.Files.Select(f => f.Target).Where(t => !InOtherPlans(t, plan)).ToList();
        if (own.Any(Exists)) return true;
        if (!store.State.Mods.TryGetValue(plan.Def.Id, out var old)) return false;
        // installed by the launcher: an older version may have had other files, or only files shared with others
        return old.Files.Where(t => !InOtherPlans(t, plan)).Any(Exists)
               || (own.Count == 0 && plan.Files.Any(f => Exists(f.Target)));
    }

    public string? InstalledVersion(ModPlan plan)
    {
        var probe = plan.Def.InstalledVersion;
        if (probe is not null)
        {
            try
            {
                var path = Roots.Resolve(Target.Normalize(probe.File, plan.Def.Name));
                if (path is not null && File.Exists(path))
                {
                    foreach (var line in File.ReadLines(path))
                    {
                        var i = line.IndexOf('=');
                        if (i > 0 && line[..i].Trim().Equals(probe.Key, StringComparison.OrdinalIgnoreCase))
                            return line[(i + 1)..].Trim();
                    }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
            {
            }
        }
        return store.State.Mods.TryGetValue(plan.Def.Id, out var m) && m.Version.Length > 0 ? m.Version : null;
    }

    /// <summary>Where the mod goes, for the messages: its own folder or the folder its files have in common.</summary>
    public string Where(ModPlan plan)
    {
        if (plan.Mirrors.Count > 0) return Roots.Resolve(plan.Mirrors[0]) ?? "";
        var folders = plan.Files.Select(f => Roots.Resolve(f.Target)).OfType<string>()
            .Select(p => Path.GetDirectoryName(p)!).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (folders.Count == 0) return "";
        var common = folders[0];
        foreach (var f in folders.Skip(1))
            while (!(f + Path.DirectorySeparatorChar).StartsWith(common + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                common = Path.GetDirectoryName(common) ?? common;
        return common;
    }

    // -----------------------------------------------------------------------------------------------------------------

    public Task InstallAsync(ModPlan plan, IProgress<Step> progress, CancellationToken ct) =>
        Task.Run(() => Install(plan, progress, ct), ct);

    public Task UninstallAsync(ModPlan plan, IProgress<Step> progress, CancellationToken ct) =>
        Task.Run(() => Uninstall(plan, progress, ct), ct);

    void Install(ModPlan plan, IProgress<Step> progress, CancellationToken ct)
    {
        var name = plan.Def.Name;
        if (plan.NeedsGame && Roots.Game is null)
            throw new InstallerException($"Non trovo Project Zomboid: {name} non è installata.",
                "Scegli la cartella del gioco (o trascinala sul launcher) e riprova.", false);

        var title = $"Installo {name}";
        var where = Where(plan);
        var previous = IsPresent(plan) ? InstalledVersion(plan) : null;
        progress.Report(new(0, title, previous is not null && previous != plan.Def.Version
            ? $"sostituisco la versione {previous} che hai già"
            : $"copio {plan.Files.Count} file in {where}"));

        long total = Math.Max(1, plan.TotalBytes), done = 0;
        var copied = 0;
        foreach (var f in plan.Files)
        {
            ct.ThrowIfCancellationRequested();
            var dest = Roots.Resolve(f.Target)!;
            if (!(File.Exists(dest) && Same(dest, f)))
            {
                Guard(f.Target, () =>
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    CopyFile(f.Source, dest);
                });
                copied++;
            }
            done += f.Size;
            progress.Report(new(done / (double)total * 0.96, title, $"» {dest}"));
        }

        // what the new version does not have any more
        var targets = plan.Targets;
        foreach (var mirror in plan.Mirrors)
        {
            foreach (var extra in Extras(mirror, targets).ToList())
                Guard(mirror, () => DeleteFile(extra));
            Guard(mirror, () => RemoveEmptyFolders(Roots.Resolve(mirror)!));
        }
        if (store.State.Mods.TryGetValue(plan.Def.Id, out var old))
        {
            foreach (var t in old.Files.Where(t => !targets.Contains(t) && !UnderMirror(t, plan.Mirrors)))
                if (ClaimedByOthers(t, plan) is null && Roots.Resolve(t) is { } path && File.Exists(path))
                    Guard(t, () => DeleteFile(path));
        }

        store.State.Mods[plan.Def.Id] = new InstalledMod
        {
            Version = plan.Def.Version,
            Files = plan.Files.Select(f => f.Target).ToList(),
            Mirrors = plan.Mirrors.ToList(),
            At = DateTimeOffset.Now,
        };
        store.SaveState();
        progress.Report(new(1, $"{name} installata",
            copied == 0 ? "era già tutto a posto" : $"{copied} file copiati in {where}"));
    }

    void Uninstall(ModPlan plan, IProgress<Step> progress, CancellationToken ct)
    {
        var name = plan.Def.Name;
        var title = $"Tolgo {name}";
        store.State.Mods.TryGetValue(plan.Def.Id, out var old);
        var mirrors = plan.Mirrors.Concat(old?.Mirrors ?? []).Distinct(Target.Comparer)
            .Where(m => !Target.IsGame(m) && Target.Depth(m) >= 2).ToList();
        var files = plan.Files.Select(f => f.Target).Concat(old?.Files ?? []).Distinct(Target.Comparer)
            .Where(t => !UnderMirror(t, mirrors)).ToList();

        var steps = Math.Max(1, mirrors.Count + files.Count);
        var step = 0;
        var kept = new List<string>();
        foreach (var m in mirrors)
        {
            ct.ThrowIfCancellationRequested();
            var dir = Roots.Resolve(m);
            progress.Report(new(step++ / (double)steps, title, $"» {dir}"));
            if (dir is not null && Directory.Exists(dir)) Guard(m, () => DeleteFolder(dir));
        }
        if (files.Any(Target.IsGame) && Roots.Game is null)
            kept.Add("non trovo Project Zomboid: nella sua cartella non c'è niente da togliere");
        foreach (var t in files)
        {
            ct.ThrowIfCancellationRequested();
            var path = Roots.Resolve(t);
            if (path is null) continue;
            if (ClaimedByOthers(t, plan) is { } by)
            {
                kept.Add($"lascio {Path.GetFileName(path)}: serve anche a {by}");
                continue;
            }
            progress.Report(new(step++ / (double)steps, title, $"» {path}"));
            if (File.Exists(path)) Guard(t, () => DeleteFile(path));
        }

        store.State.Mods.Remove(plan.Def.Id);
        store.SaveState();
        progress.Report(new(1, $"{name} tolta", kept.Count > 0 ? string.Join(" · ", kept) : "fatto"));
    }

    // -----------------------------------------------------------------------------------------------------------------

    string? Difference(ModPlan plan)
    {
        int missing = 0, changed = 0, extra = 0;
        foreach (var f in plan.Files)
        {
            var path = Roots.Resolve(f.Target);
            if (path is null || !File.Exists(path)) missing++;
            else if (!Same(path, f)) changed++;
        }
        var targets = plan.Targets;
        foreach (var mirror in plan.Mirrors) extra += Extras(mirror, targets).Count();
        if (store.State.Mods.TryGetValue(plan.Def.Id, out var old))
            extra += old.Files.Count(t => !targets.Contains(t) && !UnderMirror(t, plan.Mirrors)
                                          && ClaimedByOthers(t, plan) is null && Exists(t));
        if (missing + changed + extra == 0) return null;
        var parts = new List<string>();
        if (changed > 0) parts.Add(changed == 1 ? "1 file diverso" : $"{changed} file diversi");
        if (missing > 0) parts.Add(missing == 1 ? "1 file mancante" : $"{missing} file mancanti");
        if (extra > 0) parts.Add(extra == 1 ? "1 file vecchio da togliere" : $"{extra} file vecchi da togliere");
        return string.Join(", ", parts);
    }

    IEnumerable<string> Extras(string mirror, HashSet<string> targets)
    {
        var dir = Roots.Resolve(mirror);
        if (dir is null || !Directory.Exists(dir)) yield break;
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            if (!targets.Contains(Target.Combine(mirror, Path.GetRelativePath(dir, f))))
                yield return f;
    }

    bool InOtherPlans(string target, ModPlan plan) => Plans.Any(o => o != plan && o.Targets.Contains(target));

    /// <summary>The name of another installed mod that needs this file too, if any.</summary>
    string? ClaimedByOthers(string target, ModPlan plan)
    {
        foreach (var o in Plans)
        {
            if (o == plan) continue;
            var listed = o.Targets.Contains(target)
                         || (store.State.Mods.TryGetValue(o.Def.Id, out var s) && s.Files.Contains(target, Target.Comparer));
            if (listed && IsPresent(o)) return o.Def.Name;
        }
        // a mod that is not in mods.json any more, but that the launcher installed
        foreach (var (id, s) in store.State.Mods)
            if (!id.Equals(plan.Def.Id, StringComparison.OrdinalIgnoreCase) && Plans.All(p => !p.Def.Id.Equals(id, StringComparison.OrdinalIgnoreCase))
                && s.Files.Contains(target, Target.Comparer))
                return id;
        return null;
    }

    static bool UnderMirror(string target, IEnumerable<string> mirrors) =>
        mirrors.Any(m => target.StartsWith(m + "/", StringComparison.OrdinalIgnoreCase));

    bool Exists(string target) => Roots.Resolve(target) is { } p && File.Exists(p);

    static bool Same(string path, PlannedFile f) =>
        new FileInfo(path).Length == f.Size && ModPlan.Hash(path) == f.Hash;

    void Guard(string target, Action action)
    {
        try
        {
            action();
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException)
        {
            if (Target.IsGame(target))
                throw new InstallerException(
                    $"Non riesco a scrivere nella cartella del gioco: \"{Path.Combine(Roots.Game!, "media", "lua")}\".",
                    "Chiudi il gioco e riprova, oppure riavvia il launcher come amministratore.", true, e);
            var first = string.Join('/', target.Split('/').Take(2));
            throw new InstallerException($"Non riesco a scrivere in \"{Roots.Resolve(first)}\".",
                "Chiudi il gioco e riprova.", false, e);
        }
    }

    static void CopyFile(string source, string dest)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                if (File.Exists(dest)) File.SetAttributes(dest, FileAttributes.Normal);
                File.Copy(source, dest, overwrite: true);
                return;
            }
            catch (IOException) when (attempt == 0)
            {
                Thread.Sleep(1000);          // like robocopy /R:1 /W:1: one more try, a second later
            }
        }
    }

    static void DeleteFile(string path)
    {
        File.SetAttributes(path, FileAttributes.Normal);
        File.Delete(path);
    }

    static void DeleteFolder(string dir)
    {
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            File.SetAttributes(f, FileAttributes.Normal);
        Directory.Delete(dir, recursive: true);
    }

    static void RemoveEmptyFolders(string dir)
    {
        if (!Directory.Exists(dir)) return;
        foreach (var sub in Directory.EnumerateDirectories(dir, "*", SearchOption.AllDirectories)
                     .OrderByDescending(d => d.Length).ToList())
            if (!Directory.EnumerateFileSystemEntries(sub).Any())
                Directory.Delete(sub);
    }
}

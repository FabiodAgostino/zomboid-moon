using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Moon.Core;

namespace Moon.ViewModels;

public enum ToastKind { Ok, Info, Warning, Error }

/// <summary>Who asks for the music's code: the launcher by itself at the start, GIOCA, or the card's «CODICE MUSICA».</summary>
public enum MusicAsk { Startup, Play, Card }

/// <summary>The packages read again on GIOCA: ready, unreadable but the player plays without music, or stop.</summary>
public enum PackCheck { Ready, WithoutMusic, Cancel }

/// <summary>A question in the middle of the window. The view shows it and closes it with the button pressed.</summary>
public sealed class DialogRequest
{
    readonly TaskCompletionSource<int> result = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public required string Title { get; init; }
    public required string Message { get; init; }
    public string? Advice { get; init; }
    public IReadOnlyList<string> Buttons { get; init; } = ["OK"];
    /// <summary>The first button does something that cannot be undone.</summary>
    public bool Danger { get; init; }
    /// <summary>The launcher is waiting for something: a spinner instead of the icon.</summary>
    public bool Waiting { get; init; }
    public string Icon { get; init; } = "";
    public bool HasAdvice => !string.IsNullOrEmpty(Advice);

    public Task<int> Result => result.Task;
    public void Close(int button) => result.TrySetResult(button);
}

/// <summary>
/// The window that asks for the music's code (Core/MusicCode.cs). The view says at once whether the pasted text is a
/// whole code (Check); «Conferma» sends it to ZomBOT (Redeem) and closes the window with the key when ZomBOT gives the
/// one of the music of now, otherwise it stays open and says why. «Più tardi» closes it with null.
/// </summary>
public sealed class MusicCodeRequest
{
    readonly TaskCompletionSource<byte[]?> result = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public required string Title { get; init; }
    public required string Message { get; init; }
    /// <summary>A whole code (MusicCodeCheck.Code) to ZomBOT: the key already checked against the manifest's keyId.</summary>
    public required Func<string, Task<MusicRedeem>> Redeem { get; init; }

    public MusicCodeCheck Check(string? text) => MusicCode.Check(text);

    public Task<byte[]?> Result => result.Task;
    public void Close(byte[]? key) => result.TrySetResult(key);
}

/// <summary>Everything the window shows and does: the mods, the news, the GIOCA button and the progress bar.</summary>
public sealed class MainViewModel : Observable, IDisposable
{
    readonly Options options;
    readonly Store store;
    readonly GitHub github;
    readonly MusicRedeemer redeemer = new();
    readonly Sources sources;
    readonly DispatcherTimer watch;
    IReadOnlyList<Release> releases = [];
    /// <summary>The main branch's mods.json as read at the start (null offline or with --sorgente).</summary>
    Manifest? liveManifest;
    IReadOnlyList<ModDef> replacing = [];
    bool cleanupWaiting;
    ModSource? source;
    Installer? installer;
    List<ModPlan> plans = [];
    string? gameFolder;
    bool gameRunning;
    bool launching;
    bool confirming;
    /// <summary>The window of the music's code is open.</summary>
    bool askingCode;
    /// <summary>«Più tardi» to the music's code: the launcher does not ask again by itself (at the start, when the game
    /// closes) until it is opened again. GIOCA always asks (from 1.0.5).</summary>
    bool musicCodeLater;
    ReleaseAsset? launcherAsset;

    public MainViewModel(Options options)
    {
        this.options = options;
        store = new Store(options.DataFolder);
        HashCache.Use(store.CacheFolder);
        github = new GitHub(options.ApiBase, store.CacheFolder);
        sources = new Sources(github, store.CacheFolder, options.SourceFolder);
        PlayCommand = new Command(PlayAsync, () => PlayEnabled);
        PlayAnywayCommand = new Command(LaunchGameAsync, () => !IsBusy && !gameRunning);
        ChooseGameCommand = new Command(ChooseGameAsync, () => !IsBusy);
        OpenModsFolderCommand = new Command(OpenModsFolder);
        UpdateAllCommand = new Command(() => InstallAsync(Mods.Where(m => m.HasUpdate).ToList(), latest: true), () => !IsBusy);
        UpdateLauncherCommand = new Command(UpdateLauncherAsync, () => !IsBusy);
        RetryCommand = new Command(InitializeAsync, () => !IsBusy);
        OpenUrlCommand = new Command(p => { OpenUrl(p as string); return Task.CompletedTask; });
        watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        watch.Tick += async (_, _) => await WatchGameAsync();
    }

    public Func<DialogRequest, Task<int>> Dialog { get; set; } = _ => Task.FromResult(-1);
    public Func<MusicCodeRequest, Task<byte[]?>> AskCode { get; set; } = _ => Task.FromResult<byte[]?>(null);
    public Action<string, string, ToastKind> Toast { get; set; } = (_, _, _) => { };
    public Action Minimize { get; set; } = () => { };
    public Action CloseLauncher { get; set; } = () => { };

    public ObservableCollection<ModCard> Mods { get; } = [];
    public ObservableCollection<NewsItem> News { get; } = [];
    public ObservableCollection<NewsItem> LatestNews { get; } = [];

    public ICommand PlayCommand { get; }
    public ICommand PlayAnywayCommand { get; }
    public ICommand ChooseGameCommand { get; }
    public ICommand OpenModsFolderCommand { get; }
    public ICommand UpdateAllCommand { get; }
    public ICommand UpdateLauncherCommand { get; }
    public ICommand RetryCommand { get; }
    public ICommand OpenUrlCommand { get; }

    public string VersionText => "v" + SelfUpdate.CurrentText;
    public bool IsDryRun => options.DryRun;

    // ---- the GIOCA button and the bar under it -----------------------------------------------------------------------

    string playLabel = "GIOCA";
    public string PlayLabel { get => playLabel; private set => Set(ref playLabel, value); }

    bool playEnabled;
    public bool PlayEnabled
    {
        get => playEnabled;
        private set
        {
            // the button asks the command again now, not at the next click or key
            if (Set(ref playEnabled, value)) CommandManager.InvalidateRequerySuggested();
        }
    }

    bool showPlayAnyway;
    public bool ShowPlayAnyway { get => showPlayAnyway; private set => Set(ref showPlayAnyway, value); }

    string statusTitle = "Un attimo…";
    public string StatusTitle { get => statusTitle; private set => Set(ref statusTitle, value); }

    string statusDetail = "Preparo il launcher di Moon.";
    public string StatusDetail { get => statusDetail; private set => Set(ref statusDetail, value); }

    bool isBusy;
    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (Set(ref isBusy, value)) CommandManager.InvalidateRequerySuggested();
        }
    }

    bool showProgress;
    public bool ShowProgress { get => showProgress; private set => Set(ref showProgress, value); }

    string progressTitle = "";
    public string ProgressTitle { get => progressTitle; private set => Set(ref progressTitle, value); }

    string progressDetail = "";
    public string ProgressDetail { get => progressDetail; private set => Set(ref progressDetail, value); }

    double progress;
    public double Progress { get => progress; private set => Set(ref progress, value); }

    bool indeterminate;
    public bool Indeterminate { get => indeterminate; private set => Set(ref indeterminate, value); }

    string percentText = "";
    public string PercentText { get => percentText; private set => Set(ref percentText, value); }

    // ---- folders, sources, banners -----------------------------------------------------------------------------------

    string gameText = "";
    public string GameText { get => gameText; private set => Set(ref gameText, value); }

    bool gameFound;
    public bool GameFound { get => gameFound; private set => Set(ref gameFound, value); }

    public string ModsFolderText => Path.Combine(options.ZomboidFolder, "mods");

    string sourceText = "";
    public string SourceText { get => sourceText; private set => Set(ref sourceText, value); }

    bool launcherUpdateAvailable;
    public bool LauncherUpdateAvailable { get => launcherUpdateAvailable; private set => Set(ref launcherUpdateAvailable, value); }

    string launcherUpdateText = "";
    public string LauncherUpdateText { get => launcherUpdateText; private set => Set(ref launcherUpdateText, value); }

    bool offline;
    public bool Offline { get => offline; private set => Set(ref offline, value); }

    string? loadError;
    public string? LoadError
    {
        get => loadError;
        private set
        {
            if (Set(ref loadError, value)) Raise(nameof(HasLoadError));
        }
    }

    public bool HasLoadError => loadError is not null;

    string modsSummary = "Controllo le mod…";
    public string ModsSummary { get => modsSummary; private set => Set(ref modsSummary, value); }

    bool anyUpdates;
    public bool AnyUpdates { get => anyUpdates; private set => Set(ref anyUpdates, value); }

    // ---- start ------------------------------------------------------------------------------------------------------

    public async Task InitializeAsync()
    {
        if (IsBusy) return;
        IsBusy = true;
        LoadError = null;
        UpdatePlayState();
        try
        {
            SelfUpdate.CleanUp();
            LocateGame(options.GameFolder);
            BeginProgress("Controllo le novità di Moon", "mi collego a GitHub", true);
            bool isOffline;
            try
            {
                (releases, isOffline) = await github.ReleasesAsync(CancellationToken.None);
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException or JsonException)
            {
                (releases, isOffline) = ([], true);
            }
            Offline = isOffline && options.SourceFolder is null;
            FillNews();

            source = await sources.ResolveAsync(releases, isOffline, Reporter(null), CancellationToken.None);
            SourceText = source.Label;
            BeginProgress("Controllo le mod sul tuo computer", "confronto i file, uno per uno", true);
            // the main branch says now which mods are disabled and which old files go; the release said it when it
            // came out. The mods that another one replaces (ZomBOT and Admin-Scorte, inside ZomBOT (Moon)) have no card.
            var live = await sources.LiveAsync(isOffline, CancellationToken.None);
            liveManifest = live;
            replacing = (live ?? source.Manifest).Mods.Where(m => m.Replaces is not null).ToList();
            var replaced = new HashSet<string>(source.Manifest.Mods.Concat(replacing).SelectMany(m => m.Replaces?.Mods ?? []),
                StringComparer.OrdinalIgnoreCase);
            var root = source;
            plans = await Task.Run(() => ModPlan.Build(root.Manifest, root.Root).Where(p => !replaced.Contains(p.Def.Id)).ToList());
            // the files of a mod that are not in the repo (Jukebox (Moon)'s catalogue and music)
            plans = await Task.Run(() => Packs.AttachAsync(plans, github, store.CacheFolder,
                new Roots(options.ZomboidFolder, gameFolder), options.PackFolder, Offline, CancellationToken.None));
            Mods.Clear();
            // the mods that Moon needs first
            foreach (var plan in plans.OrderByDescending(p => p.Def.Required))
                Mods.Add(new ModCard(plan, Mods.Count, ToggleAsync, c => InstallAsync([c], latest: true), UninstallAsync,
                    ChooseVersionAsync, ChooseGameAsync, EnterMusicCodeAsync));
            foreach (var card in Mods)
            {
                var def = live?.Mods.FirstOrDefault(m => m.Id.Equals(card.Def.Id, StringComparison.OrdinalIgnoreCase)) ?? card.Def;
                card.Disabled = def.Disabled;
                card.DisabledNote = def.StateNote;
            }
            await CleanOldFilesAsync();
            await RefreshAsync();
            CheckLauncherUpdate();
            // a disabled mod still installed says it on its card (TOGLI), and the new version is in the corner: no toast
            _ = LoadVersionsAsync(isOffline);
        }
        catch (Exception e)
        {
            LoadError = e.Message;
            ModsSummary = "Mod non disponibili";
        }
        finally
        {
            IsBusy = false;
            EndProgress();
            UpdatePlayState();
            watch.Start();
        }
        if (!HasLoadError) await InstallMissingRequiredAsync();
    }

    /// <summary>
    /// The mods that Moon needs (ZomBOT (Moon)), installed without asking as soon as the launcher opens when they are
    /// missing. With the game open, GIOCA does it later. The music's code first, when it is needed: then the music
    /// comes in the same install.
    /// </summary>
    async Task InstallMissingRequiredAsync()
    {
        if (askingCode) return;
        var missing = Mods.Where(m => m.Required && !m.Disabled && m.State == ModState.NotInstalled).ToList();
        if (missing.Count == 0 || await Task.Run(Game.IsRunning)) return;
        var unlocked = await MusicCodeAsync(MusicAsk.Startup);
        if (unlocked is null) return;
        if (unlocked.Count > 0)
            missing = Mods.Where(m => (m.Required && !m.Disabled && m.State == ModState.NotInstalled)
                                      || (unlocked.Contains(m) && m.HasUpdate)).ToList();
        if (missing.Count > 0) await InstallAsync(missing, latest: true);
    }

    /// <summary>The older versions of every mod, from the older releases: the menus fill in while the launcher is ready.</summary>
    async Task LoadVersionsAsync(bool isOffline)
    {
        if (source is null) return;
        try
        {
            var history = await sources.HistoryAsync(source, releases, isOffline, CancellationToken.None);
            foreach (var card in Mods)
                if (history.TryGetValue(card.Def.Id, out var versions))
                    card.SetVersions(versions);
            foreach (var card in Mods.Where(m => m.IsOn)) card.Status = card.Status;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException or InvalidDataException)
        {
            // only the latest version, then
        }
    }

    void FillNews()
    {
        News.Clear();
        LatestNews.Clear();
        // not the pre-releases: «jukebox» holds Jukebox (Moon)'s music, it is not news
        foreach (var r in releases.Where(r => !r.Draft && !r.Prerelease)) News.Add(NewsItem.From(r));
        if (News.Count == 0)
            News.Add(new NewsItem
            {
                Title = "Benvenuto nel launcher di Moon",
                Tag = "",
                Date = DateTimeOffset.MinValue,
                Url = GitHub.ReleasesPage,
                Body = "Da qui installi e aggiorni le mod per giocare sul server **Moon** e avvii Project Zomboid.\n\n"
                       + "- **GIOCA** avvia il gioco da Steam; se manca una mod che serve, prima la installa.\n"
                       + "- Nella pagina **MOD** accendi o spegni ogni mod con il suo interruttore.\n"
                       + "- Le novità del server compaiono qui ogni volta che esce una versione nuova.",
            });
        foreach (var n in News.Take(3)) LatestNews.Add(n);
    }

    void CheckLauncherUpdate()
    {
        var asset = source?.Release?.Asset(SelfUpdate.AssetName);
        launcherAsset = asset is not null && SelfUpdate.IsNewer(source!.Manifest.Launcher) ? asset : null;
        LauncherUpdateAvailable = launcherAsset is not null;
        LauncherUpdateText = launcherAsset is null
            ? ""
            : $"È uscita la versione {source!.Manifest.Launcher} del launcher (tu hai la {SelfUpdate.CurrentText}).";
    }

    // ---- the game ---------------------------------------------------------------------------------------------------

    void LocateGame(string? preferred)
    {
        // trying the launcher (--prova) never looks in Steam: it must not find and touch the real game
        gameFolder = options.DryRun
            ? new[] { preferred, store.Settings.GameFolder }.FirstOrDefault(Game.IsGame)
            : Game.Find(preferred, store.Settings.GameFolder);
        if (!string.IsNullOrEmpty(preferred) && !Game.IsGame(preferred))
            Toast("Qui non c'è Project Zomboid", "La cartella che hai trascinato non contiene il gioco.", ToastKind.Warning);
        GameFound = gameFolder is not null;
        GameText = gameFolder ?? "Non trovato: trascina qui la cartella ProjectZomboid, o premi Cambia";
    }

    public async Task ChooseGameAsync()
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "Scegli la cartella di Project Zomboid",
            InitialDirectory = gameFolder ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        };
        if (dlg.ShowDialog() == true) await SetGameFolderAsync(dlg.FolderName);
        else foreach (var m in Mods) m.Sync();
    }

    /// <summary>A folder chosen or dropped on the window: the game, or a Steam folder with the game inside.</summary>
    public async Task SetGameFolderAsync(string folder)
    {
        if (IsBusy) return;
        var found = new[]
        {
            folder,
            Path.Combine(folder, "ProjectZomboid"),
            Path.Combine(folder, "common", "ProjectZomboid"),
            Path.Combine(folder, "steamapps", "common", "ProjectZomboid"),
        }.FirstOrDefault(Game.IsGame);
        if (found is null)
        {
            await Dialog(new DialogRequest
            {
                Title = "Qui non c'è Project Zomboid",
                Message = $"La cartella che hai scelto non contiene il gioco:\n{folder}",
                Advice = "Di solito è in …\\Steam\\steamapps\\common\\ProjectZomboid. Da Steam: tasto destro sul gioco, «Gestisci», «Sfoglia i file locali».",
                Icon = "",
            });
            return;
        }
        store.Settings.GameFolder = found;
        store.SaveSettings();
        gameFolder = found;
        GameFound = true;
        GameText = found;
        await CleanOldFilesAsync();
        if (Mods.Count > 0) await RefreshAsync();
    }

    async Task WatchGameAsync()
    {
        var running = await Task.Run(Game.IsRunning);
        if (running == gameRunning) return;
        gameRunning = running;
        if (running && !options.DryRun) Minimize();
        UpdatePlayState();
        if (running || IsBusy || HasLoadError) return;
        if (cleanupWaiting) await CleanOldFilesAsync();
        // the game was open when the launcher started: the mod that Moon needs goes in now
        await InstallMissingRequiredAsync();
    }

    /// <summary>
    /// What is left of the mods that another one replaces: the old copies of ZomBOT and Admin-Scorte in the game's
    /// folder (now inside ZomBOT (Moon)), which the game loads on every server, so that the servers that check the Lua
    /// files kick whoever has them; and, from 1.0.4, the folder of Silenziatori, replaced by SilencerMoon (the two do
    /// not get along). Exactly the files and the folders that mods.json lists, nothing else; with the game open, as soon
    /// as it closes; the files in the game's folder only when the launcher knows where it is.
    /// </summary>
    async Task CleanOldFilesAsync()
    {
        if (replacing.Count == 0) return;
        var roots = new Roots(options.ZomboidFolder, gameFolder);
        var found = replacing.SelectMany(m => m.Replaces!.Files.Select(t => (Mod: m, Path: roots.Resolve(t), Folder: false))
                .Concat(m.Replaces.Folders.Select(t => (Mod: m, Path: roots.Resolve(t), Folder: true))))
            .Where(x => x.Path is not null && (x.Folder ? Directory.Exists(x.Path) : File.Exists(x.Path)))
            .Select(x => (x.Mod, Path: x.Path!, x.Folder)).ToList();
        if (found.Count == 0)
        {
            cleanupWaiting = false;
            return;
        }
        var mods = found.Select(f => f.Mod).Distinct().ToList();
        var names = string.Join(" e ", mods.Select(m => m.Replaces!.What).Where(w => w.Length > 0).Distinct());
        if (names.Length == 0) names = "mod che non si usano più";
        if (await Task.Run(Game.IsRunning))
        {
            // something the player must do: close the game
            if (!cleanupWaiting)
                Toast($"Vecchi file di {names} da togliere", $"Chiudi Project Zomboid e li tolgo io: {string.Join("; ", mods.Select(Why).Distinct())}.",
                    ToastKind.Warning);
            cleanupWaiting = true;
            return;
        }
        cleanupWaiting = false;
        var failed = await Task.Run(() =>
        {
            var left = new List<string>();
            foreach (var (_, path, folder) in found)
            {
                try
                {
                    if (folder)
                    {
                        DeleteOldFolder(path);
                    }
                    else
                    {
                        File.SetAttributes(path, FileAttributes.Normal);
                        File.Delete(path);
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    left.Add(path);
                }
            }
            return left;
        });
        // the launcher's own record of those mods goes too: they are not on this computer any more
        foreach (var id in replacing.SelectMany(m => m.Replaces!.Mods)) store.State.Mods.Remove(id);
        store.SaveState();
        if (failed.Count > 0)
        {
            var inGame = gameFolder is not null && failed.Any(p => p.StartsWith(gameFolder, StringComparison.OrdinalIgnoreCase));
            await ShowErrorAsync(new InstallerException(
                $"Non riesco a togliere i vecchi file di {names}: \"{failed[0]}\"" + (failed.Count > 1 ? $" e altri {failed.Count - 1}." : "."),
                inGame ? "Chiudi il gioco e riprova, oppure riavvia il launcher come amministratore." : "Chiudi il gioco e riprova.", inGame),
                "Vecchi file da togliere");
            return;
        }
        // said, without stopping the launcher until OK: the launcher deleted something from this computer
        _ = Dialog(new DialogRequest
        {
            Title = $"Ho tolto i vecchi file di {names}",
            Message = string.Join(" ", mods.Select(m => $"Al posto di {m.Replaces!.What} ora c'è {m.Name}, che installo e aggiorno io. "
                                                         + $"I vecchi file {Why(m)}: li ho tolti.")),
            Advice = string.Join(", ", found.Select(f => f.Folder ? f.Path : Path.GetFileName(f.Path))),
            Icon = "\uE73E",
        });
    }

    /// <summary>Why what is left of a replaced mod must go: mods.json says it, or the reason of ZomBOT and Admin-Scorte.</summary>
    static string Why(ModDef mod) => mod.Replaces?.Why is { Length: > 0 } why ? why : "sugli altri server fanno espellere chi li ha";

    /// <summary>
    /// A replaced mod's own folder, all of it; a link inside is removed, never followed. A few more tries: Windows may
    /// still hold a file just deleted (the indexer, an antivirus) and refuse the empty folder for a moment, and .NET
    /// removes a junction inside but then says «access denied» (it also tries to unmount it as a volume) and leaves
    /// the folder that is empty by then.
    /// </summary>
    static void DeleteOldFolder(string dir)
    {
        var all = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint };
        foreach (var f in Directory.EnumerateFiles(dir, "*", all)) File.SetAttributes(f, FileAttributes.Normal);
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                Directory.Delete(dir, recursive: true);
                return;
            }
            catch (Exception e) when ((e is IOException or UnauthorizedAccessException) && !Directory.Exists(dir))
            {
                return;
            }
            catch (Exception e) when ((e is IOException or UnauthorizedAccessException) && attempt < 4)
            {
                Thread.Sleep(400);
            }
        }
    }

    /// <summary>
    /// GIOCA: the packages read again, the music's code when it is needed, then the mods that need it (INSTALLA,
    /// AGGIORNA) with the music, then the game. When the game starts the launcher closes; when something goes wrong it
    /// stays open and says why.
    /// </summary>
    async Task PlayAsync()
    {
        if (IsBusy || askingCode) return;
        // the mod that Moon needs must be exactly the release's: looked at again now, since its files may have changed
        // while the launcher was open. Missing or different, it is installed before the game starts, without asking.
        if (installer is not null && !HasLoadError)
        {
            await RefreshAsync();
            // the code before anything is installed: with it the music comes now, before the game, not after the first
            // time on Moon. «Più tardi» and the game starts as before, without the music. Never skipped without a word:
            // 1.0.4 did, when GitHub did not answer at the start (Zaskor, 05/11/2026).
            var packs = await CheckPacksForPlayAsync();
            if (packs == PackCheck.Cancel) return;
            if (packs == PackCheck.Ready && await MusicCodeAsync(MusicAsk.Play) is null) return;
        }
        if (PlayLabel is "INSTALLA" or "AGGIORNA")
        {
            var todo = Mods.Where(m => (m.Required && m.State == ModState.NotInstalled && !m.Disabled) || m.HasUpdate).ToList();
            if (!await InstallAsync(todo, latest: true) || PlayLabel != "GIOCA") return;
        }
        await LaunchGameAsync();
    }

    async Task LaunchGameAsync()
    {
        try
        {
            Game.Launch(gameFolder, options.DryRun, options.DryRunFails);
            launching = true;
            UpdatePlayState();
            // the game is starting («AVVIO…» under the button): the launcher is not needed any more
            await Task.Delay(TimeSpan.FromSeconds(1.5));
            CloseLauncher();
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            _ = Dialog(new DialogRequest
            {
                Title = "Non riesco ad avviare Project Zomboid",
                Message = e.Message,
                Advice = "Avvialo da Steam come sempre: le mod sono già al loro posto.",
                Icon = "",
            });
        }
    }

    void UpdatePlayState()
    {
        var missing = Mods.Where(m => m.Required && m.State == ModState.NotInstalled && !m.Disabled).ToList();
        var outdated = Mods.Where(m => m.HasUpdate).ToList();
        ShowPlayAnyway = false;
        if (IsBusy)
        {
            PlayLabel = "ATTENDI";
            PlayEnabled = false;
            return;
        }
        if (gameRunning)
        {
            PlayLabel = "IN GIOCO";
            PlayEnabled = false;
            StatusTitle = "Project Zomboid è aperto";
            StatusDetail = "Le mod si cambiano solo a gioco chiuso. Buona fortuna là fuori.";
            return;
        }
        if (launching)
        {
            PlayLabel = "AVVIO…";
            PlayEnabled = false;
            StatusTitle = "Avvio Project Zomboid";
            StatusDetail = "Entra sul server Moon come sempre: le mod le attiva il server.";
            return;
        }
        PlayEnabled = true;
        if (HasLoadError)
        {
            PlayLabel = "GIOCA";
            StatusTitle = "Non riesco a preparare le mod";
            StatusDetail = LoadError!;
        }
        else if (missing.Count > 0)
        {
            PlayLabel = "INSTALLA";
            StatusTitle = missing.Count == 1
                ? $"{missing[0].Name} non è installata"
                : $"{string.Join(" e ", missing.Select(m => m.Name))} non sono installate";
            StatusDetail = "Senza non entri sul server Moon: premi INSTALLA, ci vuole un attimo.";
            ShowPlayAnyway = true;
        }
        else if (outdated.Count > 0)
        {
            PlayLabel = "AGGIORNA";
            StatusTitle = outdated.Count == 1 ? $"{outdated[0].Name} è da aggiornare" : $"{outdated.Count} mod da aggiornare";
            StatusDetail = string.Join(" · ", outdated.Select(m => $"{m.Name}: {m.VersionText}"));
            ShowPlayAnyway = true;
        }
        else
        {
            PlayLabel = "GIOCA";
            StatusTitle = "Tutto pronto";
            var music = Mods.FirstOrDefault(m => m.NeedsMusicCode && RedeemUrl(m) is not null);
            var unread = Mods.FirstOrDefault(PackUnread);
            if (unread is not null) StatusTitle = $"Gli asset di {unread.Name} non sono pronti";
            StatusDetail = unread is not null
                ? $"{unread.Plan.Notice} Premi GIOCA e riprovo."
                : music is null
                    ? "Entra sul server Moon come sempre: le mod le attiva il server, non devi attivare niente tu."
                    : $"Per la musica di {music.Name} premi GIOCA: ti chiedo il tuo codice, una volta sola.";
        }
    }

    /// <summary>The music comes from GitHub, or from --pacchetto: when the launcher started offline it does not ask by
    /// itself (Startup). GIOCA and the card try anyway: GitHub's list of releases may be down while the rest answers.</summary>
    bool CanFetchMusic => !Offline || options.PackFolder is not null;

    /// <summary>A mod that Moon needs (or that is installed) whose package could not be read: no list of its files.</summary>
    static bool PackUnread(ModCard m) =>
        m.Def.Pack is not null && m.Plan.MusicKeyId is null && !m.Disabled && (m.Def.Required || m.IsOn);

    /// <summary>
    /// GIOCA (from 1.0.5): the packages of the mods that Moon needs, or that are installed, read again now, from GitHub
    /// even when the launcher started offline (its list of releases did not come: an hourly limit, a timeout): a list of
    /// files that did not come at the start, a key that the game wrote meanwhile. 1.0.4 used what it had read at the
    /// start and, offline or without the list, started the game without asking for the code and without the music.
    /// A package that still cannot be read is said: try again, play without music, or stop.
    /// </summary>
    async Task<PackCheck> CheckPacksForPlayAsync()
    {
        var cards = Mods.Where(m => m.Def.Pack is not null && m.Plan.Base is not null && !m.Disabled && (m.Def.Required || m.IsOn)).ToList();
        if (cards.Count == 0) return PackCheck.Ready;
        var roots = new Roots(options.ZomboidFolder, gameFolder);
        while (true)
        {
            IsBusy = true;
            BeginProgress("Preparo gli asset del Jukebox", "leggo l'elenco", true);
            try
            {
                foreach (var c in cards)
                    Replace(c, await Task.Run(() => Packs.AttachAsync(c.Plan.Base!, github, store.CacheFolder, roots, options.PackFolder,
                        offline: false, CancellationToken.None)));
                await RefreshAsync();
            }
            finally
            {
                IsBusy = false;
                EndProgress();
                UpdatePlayState();
            }
            var unread = cards.FirstOrDefault(PackUnread);
            if (unread is null) return PackCheck.Ready;
            var choice = await Dialog(new DialogRequest
            {
                Title = $"Gli asset di {unread.Name} non sono pronti",
                Message = unread.Plan.Notice ?? "Non riesco a leggere l'elenco degli asset del Jukebox.",
                Advice = "Senza l'elenco non posso chiederti il codice né scaricare la musica. Controlla la connessione e premi Riprova; "
                         + "con «Gioca senza musica» il gioco parte lo stesso, questa volta senza.",
                Buttons = ["Riprova", "Gioca senza musica", "Annulla"],
                Icon = "",
            });
            if (choice == 0) continue;
            return choice == 1 ? PackCheck.WithoutMusic : PackCheck.Cancel;
        }
    }

    /// <summary>
    /// Where ZomBOT redeems the codes («pack.redeem»): the main branch's mods.json first, so the address changes with a
    /// commit and without a new launcher, then the release's; https only. With --prova, --riscatta (a fake ZomBOT).
    /// </summary>
    Uri? RedeemUrl(ModCard card) =>
        options.RedeemUrl
        ?? liveManifest?.Mods.FirstOrDefault(m => m.Id.Equals(card.Def.Id, StringComparison.OrdinalIgnoreCase))?.Pack?.RedeemUri
        ?? card.Def.Pack?.RedeemUri;

    // ---- the mods ---------------------------------------------------------------------------------------------------

    async Task RefreshAsync()
    {
        var current = new Installer(plans, new Roots(options.ZomboidFolder, gameFolder), store);
        installer = current;
        var states = await Task.Run(() =>
        {
            var read = current.Plans.ToDictionary(p => p.Def.Id, p => (Status: current.Status(p), Where: current.Where(p)),
                StringComparer.OrdinalIgnoreCase);
            HashCache.Save();       // the files just read are not read again at the next start
            return read;
        });
        foreach (var card in Mods)
        {
            if (!states.TryGetValue(card.Def.Id, out var state)) continue;
            card.Status = state.Status;
            card.Where = state.Where.Length == 0
                ? "nella cartella del gioco, che non ho trovato"
                : $"{card.Plan.Files.Count} file in {state.Where}";
        }
        var installable = Mods.Count(m => !m.Disabled);
        var installed = Mods.Count(m => m.IsOn && !m.Disabled);
        var updates = Mods.Count(m => m.HasUpdate);
        var off = Mods.Count - installable;
        AnyUpdates = updates > 0;
        ModsSummary = $"{installed} mod su {installable} installate" + (updates > 0 ? $" · {updates} da aggiornare" : "")
                      + (off == 1 ? " · 1 disattivata" : off > 1 ? $" · {off} disattivate" : "");
        UpdatePlayState();
    }

    async Task ToggleAsync(ModCard card)
    {
        if (IsBusy)
        {
            card.Sync();
            return;
        }
        if (card.NeedsGame)
        {
            card.Sync();
            await ChooseGameAsync();
            return;
        }
        if (card.IsOn) await UninstallAsync(card);
        else await InstallAsync([card], latest: false);
    }

    /// <summary>A version chosen in a card's menu: for a mod not installed it is the one the switch will install.</summary>
    async Task ChooseVersionAsync(ModCard card, string version)
    {
        card.IsVersionMenuOpen = false;
        if (IsBusy || confirming || card.Disabled) return;
        if (!card.IsOn)
        {
            card.SelectedVersion = version;
            return;
        }
        var installed = card.Status.InstalledVersion ?? card.Def.Version;
        if (version == installed && card.State == ModState.Installed) return;
        var latest = version == card.Def.Version;
        confirming = true;
        int choice;
        try
        {
            choice = await Dialog(new DialogRequest
            {
                Title = $"{card.Name} {version}",
                Message = latest
                    ? $"Passo {card.Name} alla versione {version}, l'ultima. Da qui in avanti il launcher la tiene aggiornata."
                    : $"Passo {card.Name} alla versione {version}. È una versione precedente: finché non scegli di nuovo l'ultima, il launcher non te la aggiorna.",
                Buttons = [$"Installa la {version}", "Annulla"],
                Icon = "\uE81C",
            });
        }
        finally
        {
            confirming = false;
        }
        if (choice != 0) return;
        card.SelectedVersion = version;
        await InstallAsync([card], latest: latest);
    }

    /// <summary>The plan of an older version of a mod, from the release that published it (downloaded if needed).</summary>
    async Task<ModPlan> PlanForAsync(ModCard card, string version, Reporter reporter)
    {
        // a package is read again: what was installed or downloaded when the launcher opened may be gone
        if (version == card.Def.Version) return card.Plan.Base is { } repo ? await AttachPackAsync(repo) : card.Plan;
        var release = card.FindVersion(version)?.Release
                      ?? throw new InvalidOperationException($"Non so da quale release prendere {card.Name} {version}.");
        var root = await sources.RootAsync(release, Offline, reporter, CancellationToken.None)
                   ?? throw new InvalidOperationException($"Non riesco a scaricare {card.Name} {version}: GitHub non risponde.");
        var plan = await Task.Run(() =>
        {
            var def = Manifest.Load(Path.Combine(root, "mods.json")).Mods
                          .FirstOrDefault(m => m.Id.Equals(card.Def.Id, StringComparison.OrdinalIgnoreCase))
                      ?? throw new InvalidDataException($"Nella release {release.Tag} non c'è {card.Name}.");
            return ModPlan.Build(def, root);
        });
        return plan.Def.Pack is null ? plan : await AttachPackAsync(plan);
    }

    /// <summary>A mod's package on top of its repo files, away from the UI thread: it hashes the installed files.</summary>
    Task<ModPlan> AttachPackAsync(ModPlan plan) => Task.Run(() => Packs.AttachAsync(plan, github, store.CacheFolder,
        new Roots(options.ZomboidFolder, gameFolder), options.PackFolder, Offline, CancellationToken.None));

    /// <summary>The plan read at install time takes the place of the one from when the launcher opened.</summary>
    void Replace(ModCard card, ModPlan plan)
    {
        card.Plan = plan;
        plans = plans.Select(p => p.Def.Id.Equals(plan.Def.Id, StringComparison.OrdinalIgnoreCase) ? plan : p).ToList();
    }

    /// <summary>Installs the cards: their latest version, or the one chosen in their menu.</summary>
    /// <returns>true when every card was installed.</returns>
    async Task<bool> InstallAsync(IReadOnlyList<ModCard> cards, bool latest)
    {
        if (IsBusy || installer is null || cards.Count == 0)
        {
            foreach (var c in cards) c.Sync();
            return false;
        }
        IsBusy = true;
        UpdatePlayState();
        var done = false;
        try
        {
            if (!await WaitForGameClosedAsync()) return false;
            for (var i = 0; i < cards.Count; i++)
            {
                var card = cards[i];
                card.IsWorking = true;
                try
                {
                    var reporter = Reporter(card, i / (double)cards.Count, 1.0 / cards.Count);
                    var version = latest ? card.Def.Version : card.SelectedVersion;
                    var plan = await PlanForAsync(card, version, reporter);
                    await installer.InstallAsync(plan, pinned: version != card.Def.Version, reporter, CancellationToken.None);
                    if (version == card.Def.Version && plan.Base is not null) Replace(card, plan);
                    card.SelectedVersion = version;
                }
                finally
                {
                    card.IsWorking = false;
                }
            }
            await RefreshAsync();
            // the bar says it, and the cards: no toast (from 1.0.4 «afterInstall» is not shown)
            ProgressTitle = "Tutto pronto";
            await Task.Delay(700);
            done = true;
        }
        catch (Exception e)
        {
            await ShowErrorAsync(e, "Installazione non riuscita");
            await RefreshAsync();
        }
        finally
        {
            IsBusy = false;
            EndProgress();
            foreach (var c in cards) c.Sync();
            UpdatePlayState();
        }
        return done;
    }

    async Task UninstallAsync(ModCard card)
    {
        // one question at a time: a second click while the first one waits does nothing
        if (IsBusy || confirming || !card.IsOn)
        {
            card.Sync();
            return;
        }
        confirming = true;
        int choice;
        try
        {
            choice = await Dialog(new DialogRequest
            {
                Title = $"Togliere {card.Name}?",
                Message = (card.Required ? $"Senza {card.Name} non puoi entrare sul server Moon.\n\n" : "")
                          + $"Tolgo i suoi file ({card.Where}). I salvataggi, le impostazioni e le altre mod restano come sono.",
                Buttons = ["Togli", "Annulla"],
                Danger = true,
                Icon = "",
            });
        }
        finally
        {
            confirming = false;
        }
        if (choice != 0 || IsBusy || installer is null)
        {
            card.Sync();
            return;
        }
        IsBusy = true;
        UpdatePlayState();
        try
        {
            if (!await WaitForGameClosedAsync()) return;
            card.IsWorking = true;
            var reporter = Reporter(card);
            try
            {
                await installer.UninstallAsync(card.Plan, reporter, CancellationToken.None);
            }
            finally
            {
                card.IsWorking = false;
            }
            // the bar and the card say it: no toast
            await RefreshAsync();
            await Task.Delay(500);
        }
        catch (Exception e)
        {
            await ShowErrorAsync(e, "Non sono riuscito a togliere la mod");
            await RefreshAsync();
        }
        finally
        {
            IsBusy = false;
            EndProgress();
            card.Sync();
            UpdatePlayState();
        }
    }

    async Task<bool> WaitForGameClosedAsync()
    {
        BeginProgress("Controllo che Project Zomboid sia chiuso",
            "i file di una mod non si possono cambiare mentre il gioco li sta usando", true);
        if (!await Task.Run(Game.IsRunning)) return true;
        var request = new DialogRequest
        {
            Title = "Project Zomboid è aperto",
            Message = "Chiudilo e continuo da solo: i file di una mod non si possono cambiare mentre il gioco li sta usando.",
            Buttons = ["Annulla"],
            Waiting = true,
        };
        var shown = Dialog(request);
        while (await Task.Run(Game.IsRunning))
            if (await Task.WhenAny(shown, Task.Delay(1000)) == shown) return false;
        request.Close(-1);
        await shown;
        return true;
    }

    // ---- the music's code -------------------------------------------------------------------------------------------

    /// <summary>
    /// The music's code (Core/MusicCode.cs), asked when a mod that Moon needs, or that is installed, has music that this
    /// computer cannot open: no key, or the key of before. Once: ZomBOT spends the code and gives the key (from 1.0.5 a
    /// code is good once), which goes in the file where the game writes it too (pack.keyFile), and from then on the
    /// launcher finds it there. By itself (Startup) the launcher asks only with GitHub there and not again after «Più
    /// tardi»; GIOCA (Play) and the card's «CODICE MUSICA» (Card) ask whenever the music cannot be opened.
    /// </summary>
    /// <returns>The cards whose plans now have the music (empty: nothing to do, «Più tardi», «Gioca senza musica»);
    /// null when the key could not be written: the player has been told, and the game does not start.</returns>
    async Task<List<ModCard>?> MusicCodeAsync(MusicAsk reason)
    {
        var needing = Mods.Where(m => m.NeedsMusicCode).ToList();
        if (needing.Count == 0 || askingCode) return [];
        // by itself the launcher asks once, and only with GitHub there; GIOCA and the card always
        if (reason == MusicAsk.Startup && (musicCodeLater || !CanFetchMusic)) return [];
        var card = needing[0];
        var keyPath = new Roots(options.ZomboidFolder, gameFolder).Resolve(card.Def.Pack!.KeyFile)!;
        var keyId = card.Plan.MusicKeyId!;
        var old = await Task.Run(() => Packs.ReadKey(keyPath));
        // the game may have written it while the launcher was open: then there is nothing to ask
        if (old is null || Packs.KeyId(old) != keyId)
        {
            // a mods.json without ZomBOT's address: no code, the key comes from the game as with 1.0.3
            if (RedeemUrl(card) is not { } redeem)
            {
                if (reason != MusicAsk.Startup)
                    Toast("Il codice della musica non si può usare", "La chiave della musica arriva dal gioco, quando entri su Moon.", ToastKind.Warning);
                return [];
            }
            // a code is good once: before ZomBOT spends it, the key must have a place to go
            while (true)
            {
                try
                {
                    await Task.Run(() => Packs.CheckKeyWritable(keyPath));
                    break;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    musicCodeLater = true;
                    var choice = await Dialog(new DialogRequest
                    {
                        Title = "Non posso salvare la chiave della musica",
                        Message = $"Non riesco a scrivere in \"{keyPath}\". Il codice non l'ho usato: vale ancora.",
                        Advice = "Chiudi Project Zomboid e premi Riprova."
                                 + (reason == MusicAsk.Play ? " Con «Gioca senza musica» il gioco parte lo stesso, questa volta senza." : ""),
                        Buttons = reason == MusicAsk.Play ? ["Riprova", "Gioca senza musica", "Annulla"] : ["Riprova", "Chiudi"],
                        Icon = "",
                    });
                    if (choice == 0) continue;
                    UpdatePlayState();
                    return reason == MusicAsk.Play && choice == 1 ? [] : null;
                }
            }
            byte[]? key;
            askingCode = true;
            try
            {
                key = await AskCode(new MusicCodeRequest
                {
                    Title = old is null ? "Il codice della musica" : "Serve un codice nuovo della musica",
                    Message = old is null
                        ? $"Per scaricare la musica di {card.Name} prima di avviare il gioco mi serve il tuo codice. "
                          + "Il codice vale una volta sola: il launcher se lo ricorda su questo PC. Per un altro PC chiedi un codice nuovo a un admin."
                        : $"La chiave della musica di {card.Name} è cambiata e quella di prima non apre i CD. "
                          + "Il codice vale una volta sola: se il tuo l'hai già usato, chiedine uno nuovo a un admin, "
                          + "oppure premi «Più tardi» e la chiave nuova arriva dal gioco quando entri su Moon.",
                    Redeem = code => redeemer.RedeemAsync(redeem, code, keyId, CancellationToken.None),
                });
            }
            finally
            {
                askingCode = false;
            }
            if (key is null)
            {
                musicCodeLater = true;
                UpdatePlayState();
                return [];
            }
            // ZomBOT has spent the code: the key is only here now, so a file that will not take it gets another try
            while (true)
            {
                try
                {
                    await Task.Run(() => Packs.WriteKey(keyPath, key));
                    break;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    var choice = await Dialog(new DialogRequest
                    {
                        Title = "Chiave non salvata",
                        Message = $"ZomBOT ha accettato il codice, ma non riesco a salvare la chiave della musica in \"{keyPath}\".",
                        Advice = "Chiudi Project Zomboid e premi Riprova: il codice vale una volta sola, e finché il launcher è aperto la chiave ce l'ho io.",
                        Buttons = ["Riprova", "Chiudi"],
                        Icon = "",
                    });
                    if (choice != 0) return null;
                }
            }
            musicCodeLater = false;
        }
        // read again with the key: now the music is in their plans, and the cards say what is missing
        IsBusy = true;
        BeginProgress("Preparo gli asset del Jukebox", "leggo l'elenco", true);
        try
        {
            foreach (var c in needing)
                if (c.Plan.Base is { } repo) Replace(c, await AttachPackAsync(repo));
            await RefreshAsync();
        }
        finally
        {
            IsBusy = false;
            EndProgress();
            UpdatePlayState();
        }
        return needing;
    }

    /// <summary>«CODICE MUSICA» on a card: the code now, also after «Più tardi», then the music.</summary>
    async Task EnterMusicCodeAsync(ModCard card)
    {
        if (IsBusy || askingCode || confirming || installer is null) return;
        var unlocked = await MusicCodeAsync(MusicAsk.Card);
        if (unlocked is not { Count: > 0 }) return;
        var todo = unlocked.Where(c => c.HasUpdate || (c.Required && !c.Disabled && c.State == ModState.NotInstalled)).ToList();
        if (todo.Count > 0) await InstallAsync(todo, latest: true);
    }

    // ---- the launcher -----------------------------------------------------------------------------------------------

    async Task UpdateLauncherAsync()
    {
        if (launcherAsset is null || IsBusy) return;
        IsBusy = true;
        UpdatePlayState();
        try
        {
            var title = $"Scarico Moon {source?.Manifest.Launcher}";
            BeginProgress(title, launcherAsset.Url, false);
            await SelfUpdate.ApplyAsync(github, launcherAsset, new Progress<double>(f =>
            {
                Progress = f * 100;
                PercentText = $"{Progress:0}%";
            }), CancellationToken.None);
            ProgressTitle = "Riavvio il launcher";
            await Task.Delay(400);
            SelfUpdate.Restart(options.Raw.Append("--aggiornato"));
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            await ShowErrorAsync(e, "Non riesco ad aggiornare il launcher");
        }
        finally
        {
            IsBusy = false;
            EndProgress();
            UpdatePlayState();
        }
    }

    async Task ShowErrorAsync(Exception e, string title)
    {
        var ie = e as InstallerException;
        var admin = ie?.NeedsAdmin == true;
        var choice = await Dialog(new DialogRequest
        {
            Title = title,
            Message = e.Message,
            Advice = ie?.Advice,
            Buttons = admin ? ["Riavvia come amministratore", "Chiudi"] : ["Chiudi"],
            Icon = "",
        });
        if (admin && choice == 0)
        {
            try
            {
                SelfUpdate.Restart(options.Raw.Append("--riavvio"), asAdmin: true);
                Application.Current.Shutdown();
            }
            catch (Win32Exception)
            {
                // the user said no to Windows' question
            }
        }
    }

    void OpenModsFolder()
    {
        var folder = Directory.Exists(ModsFolderText) ? ModsFolderText : options.ZomboidFolder;
        if (Directory.Exists(folder)) OpenUrl(folder);
        else Toast("La cartella non c'è ancora", "Si crea quando installi la prima mod.", ToastKind.Info);
    }

    public static void OpenUrl(string? target)
    {
        if (string.IsNullOrWhiteSpace(target)) return;
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose();
        }
        catch (Win32Exception)
        {
        }
    }

    // ---- progress ---------------------------------------------------------------------------------------------------

    void BeginProgress(string title, string detail, bool isIndeterminate)
    {
        ShowProgress = true;
        ProgressTitle = title;
        ProgressDetail = detail;
        Indeterminate = isIndeterminate;
        Progress = 0;
        PercentText = "";
    }

    void EndProgress() => ShowProgress = false;

    /// <summary>Shows the steps of an operation in the bar (between from and from + span) and on the card.</summary>
    Reporter Reporter(ModCard? card, double from = 0, double span = 1) => new(Application.Current.Dispatcher, s =>
    {
        ShowProgress = true;
        Indeterminate = false;
        ProgressTitle = s.Title;
        ProgressDetail = s.Detail;
        Progress = (from + s.Fraction * span) * 100;
        PercentText = $"{Progress:0}%";
        if (card is not null)
        {
            card.Progress = s.Fraction * 100;
            card.WorkText = s.Title;
        }
    });

    public void Dispose()
    {
        watch.Stop();
        github.Dispose();
        redeemer.Dispose();
    }
}

/// <summary>Reports from the worker thread to the window; remembers the last step for the final message.</summary>
public sealed class Reporter(Dispatcher dispatcher, Action<Step> show) : IProgress<Step>
{
    volatile StepBox last = new(default);

    public Step Last => last.Step;

    public void Report(Step value)
    {
        last = new StepBox(value);
        dispatcher.BeginInvoke(show, value);
    }

    sealed record StepBox(Step Step);
}

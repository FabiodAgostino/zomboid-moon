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

/// <summary>Everything the window shows and does: the mods, the news, the GIOCA button and the progress bar.</summary>
public sealed class MainViewModel : Observable, IDisposable
{
    readonly Options options;
    readonly Store store;
    readonly GitHub github;
    readonly Sources sources;
    readonly DispatcherTimer watch;
    IReadOnlyList<Release> releases = [];
    ModSource? source;
    Installer? installer;
    List<ModPlan> plans = [];
    string? gameFolder;
    bool gameRunning;
    bool launching;
    ReleaseAsset? launcherAsset;

    public MainViewModel(Options options)
    {
        this.options = options;
        store = new Store(options.DataFolder);
        github = new GitHub(options.ApiBase, store.CacheFolder);
        sources = new Sources(github, store.CacheFolder, options.SourceFolder);
        PlayCommand = new Command(PlayAsync, () => PlayEnabled);
        PlayAnywayCommand = new Command(LaunchGame, () => !IsBusy && !gameRunning);
        ChooseGameCommand = new Command(ChooseGameAsync, () => !IsBusy);
        OpenModsFolderCommand = new Command(OpenModsFolder);
        UpdateAllCommand = new Command(() => InstallAsync(Mods.Where(m => m.HasUpdate).ToList()), () => !IsBusy);
        UpdateLauncherCommand = new Command(UpdateLauncherAsync, () => !IsBusy);
        RetryCommand = new Command(InitializeAsync, () => !IsBusy);
        OpenUrlCommand = new Command(p => { OpenUrl(p as string); return Task.CompletedTask; });
        watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        watch.Tick += async (_, _) => await WatchGameAsync();
    }

    public Func<DialogRequest, Task<int>> Dialog { get; set; } = _ => Task.FromResult(-1);
    public Action<string, string, ToastKind> Toast { get; set; } = (_, _, _) => { };
    public Action Minimize { get; set; } = () => { };

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
    public bool PlayEnabled { get => playEnabled; private set => Set(ref playEnabled, value); }

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
            var root = source;
            plans = await Task.Run(() => ModPlan.Build(root.Manifest, root.Root));
            Mods.Clear();
            for (var i = 0; i < plans.Count; i++)
                Mods.Add(new ModCard(plans[i], i, ToggleAsync, c => InstallAsync([c]), ChooseGameAsync));
            await RefreshAsync();
            CheckLauncherUpdate();
            if (options.JustUpdated) Toast("Launcher aggiornato", $"Ora hai Moon {VersionText}.", ToastKind.Ok);
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
    }

    void FillNews()
    {
        News.Clear();
        LatestNews.Clear();
        foreach (var r in releases.Where(r => !r.Draft)) News.Add(NewsItem.From(r));
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
        if (Mods.Count > 0) await RefreshAsync();
        Toast("Project Zomboid trovato", found, ToastKind.Ok);
    }

    async Task WatchGameAsync()
    {
        var running = await Task.Run(Game.IsRunning);
        if (running == gameRunning) return;
        gameRunning = running;
        if (running && !options.DryRun) Minimize();
        UpdatePlayState();
    }

    async Task PlayAsync()
    {
        if (PlayLabel is "INSTALLA" or "AGGIORNA")
        {
            await InstallAsync(Mods.Where(m => (m.Required && m.State == ModState.NotInstalled) || m.HasUpdate).ToList());
            return;
        }
        LaunchGame();
    }

    void LaunchGame()
    {
        try
        {
            var how = Game.Launch(gameFolder, options.DryRun);
            launching = true;
            UpdatePlayState();
            Toast("Buona fortuna là fuori", how == "steam" ? "Steam sta aprendo Project Zomboid." : how, ToastKind.Info);
            _ = Task.Delay(TimeSpan.FromSeconds(8)).ContinueWith(_ =>
            {
                launching = false;
                UpdatePlayState();
            }, TaskScheduler.FromCurrentSynchronizationContext());
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
        var missing = Mods.Where(m => m.Required && m.State == ModState.NotInstalled).ToList();
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
            StatusDetail = "Entra sul server Moon come sempre: le mod le attiva il server, non devi attivare niente tu.";
        }
    }

    // ---- the mods ---------------------------------------------------------------------------------------------------

    async Task RefreshAsync()
    {
        var current = new Installer(plans, new Roots(options.ZomboidFolder, gameFolder), store);
        installer = current;
        var states = await Task.Run(() => current.Plans.Select(p => (Status: current.Status(p), Where: current.Where(p))).ToList());
        for (var i = 0; i < Mods.Count && i < states.Count; i++)
        {
            var (status, where) = states[i];
            Mods[i].Status = status;
            Mods[i].Where = where.Length == 0
                ? "nella cartella del gioco, che non ho trovato"
                : $"{Mods[i].Plan.Files.Count} file in {where}";
        }
        var installed = Mods.Count(m => m.IsOn);
        var updates = Mods.Count(m => m.HasUpdate);
        AnyUpdates = updates > 0;
        ModsSummary = $"{installed} mod su {Mods.Count} installate" + (updates > 0 ? $" · {updates} da aggiornare" : "");
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
        else await InstallAsync([card]);
    }

    async Task InstallAsync(IReadOnlyList<ModCard> cards)
    {
        if (IsBusy || installer is null || cards.Count == 0)
        {
            foreach (var c in cards) c.Sync();
            return;
        }
        IsBusy = true;
        UpdatePlayState();
        var hints = new List<string>();
        try
        {
            if (!await WaitForGameClosedAsync()) return;
            for (var i = 0; i < cards.Count; i++)
            {
                var card = cards[i];
                card.IsWorking = true;
                try
                {
                    await installer.InstallAsync(card.Plan, Reporter(card, i / (double)cards.Count, 1.0 / cards.Count),
                        CancellationToken.None);
                }
                finally
                {
                    card.IsWorking = false;
                }
                if (card.Def.AfterInstall is { Length: > 0 } hint) hints.Add(hint);
            }
            await RefreshAsync();
            ProgressTitle = "Tutto pronto";
            await Task.Delay(700);
            Toast(cards.Count == 1 ? $"{cards[0].Name} installata" : "Tutto pronto",
                hints.Count > 0 ? string.Join(" ", hints) : "Avvia Project Zomboid ed entra sul server Moon come sempre.",
                ToastKind.Ok);
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
    }

    async Task UninstallAsync(ModCard card)
    {
        var choice = await Dialog(new DialogRequest
        {
            Title = $"Togliere {card.Name}?",
            Message = (card.Required ? $"Senza {card.Name} non puoi entrare sul server Moon.\n\n" : "")
                      + $"Tolgo i suoi file ({card.Where}). I salvataggi, le impostazioni e le altre mod restano come sono.",
            Buttons = ["Togli", "Annulla"],
            Danger = true,
            Icon = "",
        });
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
            await RefreshAsync();
            await Task.Delay(500);
            var last = reporter.Last.Detail;
            Toast($"{card.Name} tolta", last is { Length: > 0 } and not "fatto" ? last : "Per rimetterla, accendi di nuovo il suo interruttore.",
                ToastKind.Info);
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

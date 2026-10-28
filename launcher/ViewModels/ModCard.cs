using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Moon.Core;

namespace Moon.ViewModels;

/// <summary>A version in a card's menu.</summary>
public sealed class VersionOption : Observable
{
    public required string Version { get; init; }
    public required ModVersion Source { get; init; }
    public required ICommand Choose { get; init; }
    public bool IsLatest => Source.Latest;

    string hint = "";
    public string Hint { get => hint; set => Set(ref hint, value); }

    bool isSelected;
    public bool IsSelected { get => isSelected; set => Set(ref isSelected, value); }
}

/// <summary>One mod as a card: its switch, its state, its versions and, while it works, its progress.</summary>
public sealed class ModCard : Observable
{
    readonly Func<ModCard, Task> toggle;
    readonly Func<ModCard, string, Task> chooseVersion;

    public ModCard(ModPlan plan, int index, Func<ModCard, Task> toggle, Func<ModCard, Task> update, Func<ModCard, Task> remove,
        Func<ModCard, string, Task> chooseVersion, Func<Task> chooseGame)
    {
        Plan = plan;
        Index = index;
        this.toggle = toggle;
        this.chooseVersion = chooseVersion;
        UpdateCommand = new Command(() => update(this));
        RemoveCommand = new Command(() => remove(this));
        ChooseGameCommand = new Command(chooseGame);
        ToggleVersionsCommand = new Command(() => IsVersionMenuOpen = !IsVersionMenuOpen, () => CanChooseVersion);
        selectedVersion = plan.Def.Version;
        disabled = plan.Def.Disabled;
        disabledNote = plan.Def.StateNote;
        SetVersions([new ModVersion(plan.Def.Version, null, true)]);
        if (plan.ImagePath is not null)
        {
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.DecodePixelWidth = 480;
                bmp.UriSource = new Uri(plan.ImagePath);
                bmp.EndInit();
                bmp.Freeze();
                Image = bmp;
            }
            catch (Exception e) when (e is IOException or NotSupportedException or UriFormatException)
            {
            }
        }
    }

    public ModPlan Plan { get; }
    public ModDef Def => Plan.Def;
    public int Index { get; }
    public string Name => Def.Name;
    public string Initial => Def.Name.Length > 0 ? Def.Name[..1].ToUpperInvariant() : "?";
    public string Summary => Def.Summary ?? "";
    public string Note => Def.Note ?? "";
    public string Audience => (Def.Audience ?? (Def.Required ? "Per tutti" : "Facoltativa")).ToUpperInvariant();
    public bool Required => Def.Required;
    public ImageSource? Image { get; }
    public bool HasImage => Image is not null;
    public ICommand UpdateCommand { get; }
    public ICommand RemoveCommand { get; }
    public ICommand ChooseGameCommand { get; }
    public ICommand ToggleVersionsCommand { get; }

    // ---- state ------------------------------------------------------------------------------------------------------

    ModStatus status = new(ModState.NotInstalled, null, null);
    public ModStatus Status
    {
        get => status;
        set
        {
            status = value;
            // the version menu shows what is on the computer
            if (IsOn && Versions.Any(o => o.Version == (status.InstalledVersion ?? Def.Version)))
                SelectedVersion = status.InstalledVersion ?? Def.Version;
            RaiseState();
        }
    }

    bool disabled;
    /// <summary>The repo says this mod is not to be installed now: «Disattivata».</summary>
    public bool Disabled
    {
        get => disabled;
        set
        {
            if (Set(ref disabled, value)) RaiseState();
        }
    }

    string? disabledNote;
    public string? DisabledNote
    {
        get => disabledNote;
        set
        {
            if (Set(ref disabledNote, value)) RaiseState();
        }
    }

    void RaiseState()
    {
        foreach (var p in new[] { nameof(State), nameof(IsOn), nameof(Switch), nameof(StatusText), nameof(StatusKind), nameof(VersionText),
                     nameof(HasUpdate), nameof(NeedsGame), nameof(CanToggle), nameof(CanRemove), nameof(CanChooseVersion), nameof(StateLabel) })
            Raise(p);
    }

    public ModState State => Status.State;

    /// <summary>The switch: on when the mod is on this computer, in any version.</summary>
    public bool IsOn => State is ModState.Installed or ModState.Outdated;

    /// <summary>
    /// The switch as the user moves it, with the mouse, the keyboard or a screen reader: moving it starts installing or
    /// removing, and the switch ends where the mod ends (back where it was if the user says no).
    /// </summary>
    public bool Switch
    {
        get => IsOn;
        set
        {
            if (value != IsOn) _ = toggle(this);
        }
    }

    public bool HasUpdate => State == ModState.Outdated && !Disabled;
    public bool NeedsGame => State == ModState.NeedsGame && !Disabled;
    public bool CanToggle => !IsWorking && State != ModState.NeedsGame && !Disabled;
    /// <summary>A disabled mod that is still installed: the card offers to remove it, it never does it by itself.</summary>
    public bool CanRemove => Disabled && IsOn && !IsWorking;
    public string StateLabel => Disabled ? "DISATTIVATA" : "INSTALLABILE";

    /// <summary>ok, update, off, game, disabled: the colour of the state's dot.</summary>
    public string StatusKind => Disabled ? (IsOn ? "update" : "disabled") : State switch
    {
        ModState.Installed => "ok",
        ModState.Outdated => "update",
        ModState.NeedsGame => "game",
        _ => "off",
    };

    public string StatusText => Disabled
        ? (IsOn ? "Disattivata, ma ce l'hai installata" : "Disattivata")
        : State switch
        {
            ModState.Installed when Status.Pinned => "Installata, versione scelta da te",
            ModState.Installed => "Aggiornata",
            ModState.Outdated => "Da aggiornare",
            ModState.NeedsGame => "Serve la cartella del gioco",
            _ => Def.Required ? "Non installata: senza non entri su Moon" : "Non installata",
        };

    public string VersionText
    {
        get
        {
            var installed = Status.InstalledVersion;
            if (Disabled)
                return IsOn
                    ? $"{(installed is null ? "" : $"hai la {installed} · ")}puoi toglierla: per ora non serve"
                    : DisabledNote ?? "per ora non si installa";
            return State switch
            {
                ModState.Installed when Status.Pinned => $"hai la {installed}, l'ultima è la {Def.Version}",
                ModState.Installed => $"versione {Def.Version}",
                ModState.Outdated when installed is not null && installed != Def.Version => $"hai la {installed}, c'è la {Def.Version}",
                ModState.Outdated => $"{Status.Why} · versione {Def.Version}",
                _ when SelectedVersion != Def.Version => $"installerò la {SelectedVersion}, l'ultima è la {Def.Version}",
                _ => $"versione {Def.Version}",
            };
        }
    }

    // ---- versions ---------------------------------------------------------------------------------------------------

    public ObservableCollection<VersionOption> Versions { get; } = [];

    /// <summary>The versions the releases published, newest first; the first is the latest.</summary>
    public void SetVersions(IEnumerable<ModVersion> versions)
    {
        Versions.Clear();
        foreach (var v in versions)
        {
            var date = v.Release is { } r && r.Published != DateTimeOffset.MinValue ? r.Published.ToLocalTime().ToString("d MMMM yyyy") : "";
            Versions.Add(new VersionOption
            {
                Version = v.Version,
                Source = v,
                Choose = new Command(() => chooseVersion(this, v.Version)),
                Hint = v.Latest ? (date.Length > 0 ? $"ultima · {date}" : "ultima") : date,
            });
        }
        if (Versions.All(o => o.Version != selectedVersion)) selectedVersion = Def.Version;
        MarkSelected();
        Raise(nameof(SelectedVersion));
        Raise(nameof(HasVersions));
        Raise(nameof(CanChooseVersion));
        Raise(nameof(VersionsCountText));
    }

    public ModVersion? FindVersion(string version) => Versions.FirstOrDefault(o => o.Version == version)?.Source;

    public bool HasVersions => Versions.Count > 1;
    public bool CanChooseVersion => HasVersions && !IsWorking && !Disabled;
    public string VersionsCountText => Versions.Count == 1 ? "1 versione" : $"{Versions.Count} versioni";

    string selectedVersion;
    /// <summary>The version that is installed, or that the switch will install.</summary>
    public string SelectedVersion
    {
        get => selectedVersion;
        set
        {
            if (!Set(ref selectedVersion, value)) return;
            MarkSelected();
            Raise(nameof(VersionText));
        }
    }

    void MarkSelected()
    {
        foreach (var o in Versions) o.IsSelected = o.Version == selectedVersion;
    }

    bool isVersionMenuOpen;
    public bool IsVersionMenuOpen { get => isVersionMenuOpen; set => Set(ref isVersionMenuOpen, value); }

    // ---- work -------------------------------------------------------------------------------------------------------

    string where = "";
    public string Where { get => where; set => Set(ref where, value); }

    bool isWorking;
    public bool IsWorking
    {
        get => isWorking;
        set
        {
            if (!Set(ref isWorking, value)) return;
            Raise(nameof(CanToggle));
            Raise(nameof(CanRemove));
            Raise(nameof(CanChooseVersion));
        }
    }

    double progress;
    public double Progress { get => progress; set => Set(ref progress, value); }

    string workText = "";
    public string WorkText { get => workText; set => Set(ref workText, value); }

    /// <summary>Puts the switch back where the state says, after a click that did not change anything.</summary>
    public void Sync() => Application.Current.Dispatcher.BeginInvoke(() =>
    {
        Raise(nameof(IsOn));
        Raise(nameof(Switch));
    });
}

using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Moon.Core;

namespace Moon.ViewModels;

/// <summary>One mod as a card: its switch, its state, its version and, while it works, its progress.</summary>
public sealed class ModCard : Observable
{
    readonly Func<ModCard, Task> toggle;

    public ModCard(ModPlan plan, int index, Func<ModCard, Task> toggle, Func<ModCard, Task> update, Func<Task> chooseGame)
    {
        Plan = plan;
        Index = index;
        this.toggle = toggle;
        UpdateCommand = new Command(() => update(this));
        ChooseGameCommand = new Command(chooseGame);
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

    public ModPlan Plan { get; private set; }
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
    public ICommand ChooseGameCommand { get; }

    ModStatus status = new(ModState.NotInstalled, null, null);
    public ModStatus Status
    {
        get => status;
        set
        {
            status = value;
            foreach (var p in new[] { nameof(State), nameof(IsOn), nameof(Switch), nameof(StatusText), nameof(StatusKind), nameof(VersionText),
                         nameof(HasUpdate), nameof(NeedsGame), nameof(CanToggle) })
                Raise(p);
        }
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

    public bool HasUpdate => State == ModState.Outdated;
    public bool NeedsGame => State == ModState.NeedsGame;
    public bool CanToggle => !IsWorking && State != ModState.NeedsGame;

    /// <summary>ok, update, off, game: the colour of the state's dot.</summary>
    public string StatusKind => State switch
    {
        ModState.Installed => "ok",
        ModState.Outdated => "update",
        ModState.NeedsGame => "game",
        _ => "off",
    };

    public string StatusText => State switch
    {
        ModState.Installed => "Installata",
        ModState.Outdated => "Da aggiornare",
        ModState.NeedsGame => "Serve la cartella del gioco",
        _ => Def.Required ? "Non installata: senza non entri su Moon" : "Non installata",
    };

    public string VersionText => State switch
    {
        ModState.Installed => $"versione {Def.Version}",
        ModState.Outdated when Status.InstalledVersion is { } v && v != Def.Version => $"hai la {v}, c'è la {Def.Version}",
        ModState.Outdated => $"{Status.Why} · versione {Def.Version}",
        _ => $"versione {Def.Version}",
    };

    string where = "";
    public string Where { get => where; set => Set(ref where, value); }

    bool isWorking;
    public bool IsWorking
    {
        get => isWorking;
        set
        {
            if (Set(ref isWorking, value)) Raise(nameof(CanToggle));
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

    public void Replan(ModPlan plan) => Plan = plan;
}

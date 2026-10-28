using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Moon.Core;
using Moon.ViewModels;

namespace Moon;

/// <summary>
/// The window: what the XAML cannot do alone. The night moving with the mouse, the pages sliding in, the cards
/// coming in one after the other, the messages in the corner and the questions in the middle.
/// </summary>
public partial class MainWindow : Window
{
    readonly MainViewModel vm;
    readonly List<FrameworkElement> cards = [];
    readonly SemaphoreSlim dialogs = new(1, 1);
    Point parallaxTarget, parallax;
    FrameworkElement? page;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        vm = viewModel;
        DataContext = vm;
        vm.Dialog = ShowDialogAsync;
        vm.Toast = ShowToast;
        vm.Minimize = () => WindowState = WindowState.Minimized;
        page = PageHome;
        SourceInitialized += (_, _) => RoundCorners();
        Loaded += async (_, _) =>
        {
            ((Storyboard)FindResource("Night")).Begin(this, true);
            CompositionTarget.Rendering += MoveNight;
            Intro();
            await vm.InitializeAsync();
        };
        Closed += (_, _) =>
        {
            CompositionTarget.Rendering -= MoveNight;
            vm.Dispose();
        };
        MouseMove += (_, e) =>
        {
            var p = e.GetPosition(this);
            parallaxTarget = new Point(p.X / Math.Max(1, ActualWidth) - 0.5, p.Y / Math.Max(1, ActualHeight) - 0.5);
        };
        MouseLeave += (_, _) => parallaxTarget = new Point(0, 0);
        DragEnter += (_, e) => DropHint.Visibility = DroppedFolder(e) is null ? Visibility.Collapsed : Visibility.Visible;
        DragLeave += (_, _) => DropHint.Visibility = Visibility.Collapsed;
        Drop += async (_, e) =>
        {
            DropHint.Visibility = Visibility.Collapsed;
            if (DroppedFolder(e) is { } folder) await vm.SetGameFolderAsync(folder);
        };
    }

    // ---- the night --------------------------------------------------------------------------------------------------

    /// <summary>Every frame: the layers follow the mouse a little, the far ones less than the near ones.</summary>
    void MoveNight(object? sender, EventArgs e)
    {
        if (WindowState == WindowState.Minimized) return;
        parallax.X += (parallaxTarget.X - parallax.X) * 0.05;
        parallax.Y += (parallaxTarget.Y - parallax.Y) * 0.05;
        Shift(SkyShift, 8);
        Shift(MoonShift, 10);
        Shift(CloudShift, 14);
        Shift(HillsShift, 18);
        Shift(FogBackShift, 22);
        Shift(GroundShift, 30);
        Shift(LampShift, 30);
        Shift(FogFrontShift, 38);
        Shift(FliesShift, 34);
    }

    void Shift(TranslateTransform t, double depth)
    {
        t.X = -parallax.X * depth;
        t.Y = -parallax.Y * depth * 0.5;
    }

    void Intro()
    {
        Curtain.BeginAnimation(OpacityProperty, Fade(1, 0, 1100, 0));
        var i = 0;
        foreach (UIElement child in Hero.Children) Rise(child, 26, 180 + i++ * 90, 700);
        Rise(NewsColumn, 0, 520, 700, fromX: 40);
        Rise(ActionBar, 40, 380, 650);
        Rise(TitleBar, -16, 120, 500);
    }

    static DoubleAnimation Fade(double from, double to, int ms, int delay) => new(from, to, TimeSpan.FromMilliseconds(ms))
    {
        BeginTime = TimeSpan.FromMilliseconds(delay),
        EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
    };

    static void Rise(UIElement e, double fromY, int delay, int ms, double fromX = 0)
    {
        var t = e.RenderTransform is TranslateTransform { IsFrozen: false } own ? own : new TranslateTransform();
        e.RenderTransform = t;
        e.Opacity = 0;
        e.BeginAnimation(OpacityProperty, Fade(0, 1, ms, delay));
        t.BeginAnimation(TranslateTransform.YProperty, Fade(fromY, 0, ms, delay));
        t.BeginAnimation(TranslateTransform.XProperty, Fade(fromX, 0, ms, delay));
    }

    // ---- pages ------------------------------------------------------------------------------------------------------

    void Nav_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        ShowPage(sender == NavMods ? PageMods : sender == NavNews ? PageNews : PageHome);
    }

    void ShowPage(FrameworkElement next)
    {
        if (next == page) return;
        var old = page;
        page = next;
        if (old is not null)
        {
            var fade = Fade(1, 0, 160, 0);
            fade.Completed += (_, _) =>
            {
                if (page != old) old.Visibility = Visibility.Collapsed;
            };
            old.BeginAnimation(OpacityProperty, fade);
        }
        next.Visibility = Visibility.Visible;
        Rise(next, 18, 120, 420);
        // the night steps back behind the lists, so they read well
        PageShade.BeginAnimation(OpacityProperty, Fade(PageShade.Opacity, next == PageHome ? 0 : 1, 400, 0));
        if (next == PageMods)
        {
            var i = 0;
            foreach (var c in cards.OrderBy(c => (c.DataContext as ModCard)?.Index ?? 0)) CardIn(c, i++);
        }
    }

    void GoNews(object sender, RoutedEventArgs e) => NavNews.IsChecked = true;

    void GoMods(object sender, MouseButtonEventArgs e) => NavMods.IsChecked = true;

    void NewsSmall_Click(object sender, MouseButtonEventArgs e) => NavNews.IsChecked = true;

    void OpenReleases(object sender, RoutedEventArgs e) => MainViewModel.OpenUrl(GitHub.ReleasesPage);

    void Card_Loaded(object sender, RoutedEventArgs e)
    {
        var card = (FrameworkElement)sender;
        if (!cards.Contains(card)) cards.Add(card);
        CardIn(card, (card.DataContext as ModCard)?.Index ?? 0);
    }

    void Card_Unloaded(object sender, RoutedEventArgs e) => cards.Remove((FrameworkElement)sender);

    static void CardIn(FrameworkElement card, int index)
    {
        // what a DataTemplate builds comes frozen and shared by every card: each card needs its own to move it
        if (card.RenderTransform.IsFrozen) card.RenderTransform = card.RenderTransform.Clone();
        if (card.RenderTransform is not TransformGroup { Children: [TranslateTransform intro, ..] }) return;
        var delay = 140 + index * 90;
        card.Opacity = 0;
        card.BeginAnimation(OpacityProperty, Fade(0, 1, 520, delay));
        intro.BeginAnimation(TranslateTransform.YProperty, Fade(28, 0, 620, delay));
    }

    // ---- title bar --------------------------------------------------------------------------------------------------

    void Minimize_Click(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);

    void Close_Click(object sender, RoutedEventArgs e) => Close();

    static string? DroppedFolder(DragEventArgs e) =>
        e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } paths && Directory.Exists(paths[0]) ? paths[0] : null;

    // ---- messages in the corner -------------------------------------------------------------------------------------

    void ShowToast(string title, string message, ToastKind kind)
    {
        Dispatcher.InvokeAsync(() =>
        {
            var (glyph, color) = kind switch
            {
                ToastKind.Ok => ("", (Brush)FindResource("Ok")),
                ToastKind.Warning => ("", (Brush)FindResource("Warn")),
                ToastKind.Error => ("", (Brush)FindResource("Danger")),
                _ => ("", (Brush)FindResource("Moonlight")),
            };
            var text = new StackPanel();
            text.Children.Add(new TextBlock
            {
                Text = title,
                FontFamily = (FontFamily)FindResource("Display"),
                FontWeight = FontWeights.SemiBold,
                FontSize = 15,
                TextWrapping = TextWrapping.Wrap,
            });
            if (message.Length > 0)
                text.Children.Add(new TextBlock
                {
                    Text = message,
                    Foreground = (Brush)FindResource("TextDim"),
                    FontSize = 12.5,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 3, 0, 0),
                });
            var icon = new TextBlock
            {
                Text = glyph,
                Style = (Style)FindResource("Icon"),
                Foreground = color,
                FontSize = 16,
                Margin = new Thickness(0, 2, 12, 0),
                VerticalAlignment = VerticalAlignment.Top,
            };
            var row = new DockPanel();
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            row.Children.Add(text);
            var toast = new Border
            {
                Child = row,
                Background = new SolidColorBrush(Color.FromArgb(0xF5, 0x10, 0x16, 0x24)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1, 1, 1, 1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(16, 12, 16, 13),
                Margin = new Thickness(0, 0, 0, 10),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 24, ShadowDepth = 6, Direction = 270, Opacity = 0.5 },
                RenderTransform = new TranslateTransform(),
                Cursor = Cursors.Hand,
            };
            var accent = new Border
            {
                Width = 3,
                CornerRadius = new CornerRadius(2),
                Background = color,
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(-16, -4, 0, -5),
            };
            DockPanel.SetDock(accent, Dock.Left);
            row.Children.Insert(0, accent);
            Toasts.Children.Insert(0, toast);
            var t = (TranslateTransform)toast.RenderTransform;
            toast.BeginAnimation(OpacityProperty, Fade(0, 1, 300, 0));
            t.BeginAnimation(TranslateTransform.XProperty, Fade(60, 0, 420, 0));

            void Dismiss()
            {
                if (!Toasts.Children.Contains(toast)) return;
                var fade = Fade(toast.Opacity, 0, 260, 0);
                fade.Completed += (_, _) => Toasts.Children.Remove(toast);
                toast.BeginAnimation(OpacityProperty, fade);
                t.BeginAnimation(TranslateTransform.XProperty, Fade(0, 40, 260, 0));
            }

            toast.MouseLeftButtonUp += (_, _) => Dismiss();
            _ = Task.Delay(TimeSpan.FromSeconds(kind == ToastKind.Error ? 9 : 6)).ContinueWith(_ => Dismiss(),
                TaskScheduler.FromCurrentSynchronizationContext());
            while (Toasts.Children.Count > 4) Toasts.Children.RemoveAt(Toasts.Children.Count - 1);
        });
    }

    // ---- questions in the middle ------------------------------------------------------------------------------------

    async Task<int> ShowDialogAsync(DialogRequest request)
    {
        await dialogs.WaitAsync();
        try
        {
            DialogTitle.Text = request.Title;
            DialogMessage.Text = request.Message;
            DialogAdvice.Visibility = request.HasAdvice ? Visibility.Visible : Visibility.Collapsed;
            DialogAdviceText.Text = request.Advice ?? "";
            DialogIcon.Text = request.Icon;
            DialogIcon.Visibility = request.Waiting ? Visibility.Collapsed : Visibility.Visible;
            DialogSpinner.Visibility = request.Waiting ? Visibility.Visible : Visibility.Collapsed;
            if (request.Waiting)
                SpinnerAngle.BeginAnimation(RotateTransform.AngleProperty,
                    new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever });
            DialogButtons.Children.Clear();
            for (var i = 0; i < request.Buttons.Count; i++)
            {
                var index = i;
                var style = i > 0 ? "GhostButton" : request.Danger ? "DangerButton" : request.Buttons.Count > 1 ? "AccentButton" : "GhostButton";
                var b = new Button
                {
                    Content = request.Buttons[i].ToUpperInvariant(),
                    Style = (Style)FindResource(style),
                    Margin = new Thickness(10, 0, 0, 0),
                    MinWidth = 96,
                    Padding = new Thickness(16, 8, 16, 8),
                    IsCancel = i == request.Buttons.Count - 1,
                };
                b.Click += (_, _) => request.Close(index);
                DialogButtons.Children.Add(b);
            }

            DialogLayer.Visibility = Visibility.Visible;
            DialogLayer.BeginAnimation(OpacityProperty, Fade(0, 1, 200, 0));
            DialogScale.BeginAnimation(ScaleTransform.ScaleXProperty, Fade(0.94, 1, 260, 0));
            DialogScale.BeginAnimation(ScaleTransform.ScaleYProperty, Fade(0.94, 1, 260, 0));
            if (DialogButtons.Children.Count > 0) ((Button)DialogButtons.Children[0]).Focus();

            var result = await request.Result;

            var fade = Fade(1, 0, 160, 0);
            var done = new TaskCompletionSource();
            fade.Completed += (_, _) => done.TrySetResult();
            DialogLayer.BeginAnimation(OpacityProperty, fade);
            await done.Task;
            DialogLayer.Visibility = Visibility.Collapsed;
            SpinnerAngle.BeginAnimation(RotateTransform.AngleProperty, null);
            return result;
        }
        finally
        {
            dialogs.Release();
        }
    }

    // ---- Windows 11: rounded corners and a dark frame ---------------------------------------------------------------

    void RoundCorners()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var round = 2;          // DWMWCP_ROUND
        var dark = 1;
        var border = 0x00241A14; // COLORREF, 0x00BBGGRR
        _ = DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, 34, ref border, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}

using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Moon.ViewModels;

namespace Moon.Controls;

/// <summary>
/// The little markdown of the release notes, written into a TextBlock: titles, lists, **bold**, `code` and links.
/// Use: &lt;TextBlock c:Markdown.Text="{Binding Body}" /&gt;
/// </summary>
public static partial class Markdown
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.RegisterAttached(
        "Text", typeof(string), typeof(Markdown), new PropertyMetadata(null, (d, e) => Fill((TextBlock)d, e.NewValue as string)));

    public static string? GetText(DependencyObject d) => (string?)d.GetValue(TextProperty);
    public static void SetText(DependencyObject d, string? value) => d.SetValue(TextProperty, value);

    [GeneratedRegex(@"(\*\*[^*]+\*\*|__[^_]+__|`[^`]+`|\[[^\]]+\]\([^)\s]+\))")]
    private static partial Regex Token();

    static void Fill(TextBlock tb, string? text)
    {
        tb.Inlines.Clear();
        if (string.IsNullOrEmpty(text)) return;
        var first = true;
        var blank = false;
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (line.Trim().Length == 0)
            {
                blank = true;
                continue;
            }
            if (!first)
            {
                tb.Inlines.Add(new LineBreak());
                if (blank) tb.Inlines.Add(new Run("\n") { FontSize = 6 });
            }
            first = false;
            blank = false;

            var trimmed = line.TrimStart();
            if (trimmed.StartsWith('#'))
            {
                var level = trimmed.TakeWhile(c => c == '#').Count();
                var title = new Run(trimmed[level..].Trim())
                {
                    FontWeight = FontWeights.SemiBold,
                    FontSize = level <= 2 ? tb.FontSize + 3 : tb.FontSize + 1,
                    Foreground = (Brush)Application.Current.FindResource("Text"),
                    FontFamily = (FontFamily)Application.Current.FindResource("Display"),
                };
                tb.Inlines.Add(title);
                continue;
            }
            if (trimmed.StartsWith("- ", StringComparison.Ordinal) || trimmed.StartsWith("* ", StringComparison.Ordinal))
            {
                var indent = line.Length - trimmed.Length >= 2 ? "      " : "  ";
                tb.Inlines.Add(new Run(indent + "•  ") { Foreground = (Brush)Application.Current.FindResource("Accent") });
                trimmed = trimmed[2..];
            }
            AddSpans(tb, trimmed);
        }
    }

    static void AddSpans(TextBlock tb, string text)
    {
        var pos = 0;
        foreach (Match m in Token().Matches(text))
        {
            if (m.Index > pos) tb.Inlines.Add(new Run(text[pos..m.Index]));
            var t = m.Value;
            if (t.StartsWith("**", StringComparison.Ordinal) || t.StartsWith("__", StringComparison.Ordinal))
                tb.Inlines.Add(new Run(t[2..^2]) { FontWeight = FontWeights.SemiBold, Foreground = (Brush)Application.Current.FindResource("Text") });
            else if (t.StartsWith('`'))
                tb.Inlines.Add(new Run(t[1..^1]) { FontFamily = new FontFamily("Cascadia Mono, Consolas"), Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)) });
            else
            {
                var close = t.IndexOf("](", StringComparison.Ordinal);
                var url = t[(close + 2)..^1];
                var link = new Hyperlink(new Run(t[1..close])) { Foreground = (Brush)Application.Current.FindResource("Accent"), Cursor = System.Windows.Input.Cursors.Hand };
                link.Click += (_, _) => MainViewModel.OpenUrl(url);
                tb.Inlines.Add(link);
            }
            pos = m.Index + m.Length;
        }
        if (pos < text.Length) tb.Inlines.Add(new Run(text[pos..]));
    }
}

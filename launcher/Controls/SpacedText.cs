using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Moon.Controls;

/// <summary>A line of text with space between the letters, which WPF's TextBlock cannot do: the big MOON.</summary>
public sealed class SpacedText : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = Register(nameof(Text), "");
    public static readonly DependencyProperty SpacingProperty = Register(nameof(Spacing), 0.0);
    public static readonly DependencyProperty FontSizeProperty = Register(nameof(FontSize), 14.0);
    public static readonly DependencyProperty FontFamilyProperty = Register(nameof(FontFamily), new FontFamily("Segoe UI"));
    public static readonly DependencyProperty FontWeightProperty = Register(nameof(FontWeight), FontWeights.Normal);
    public static readonly DependencyProperty ForegroundProperty = Register<Brush>(nameof(Foreground), Brushes.White);

    static DependencyProperty Register<T>(string name, T value) =>
        DependencyProperty.Register(name, typeof(T), typeof(SpacedText),
            new FrameworkPropertyMetadata(value, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public double Spacing { get => (double)GetValue(SpacingProperty); set => SetValue(SpacingProperty, value); }
    public double FontSize { get => (double)GetValue(FontSizeProperty); set => SetValue(FontSizeProperty, value); }
    public FontFamily FontFamily { get => (FontFamily)GetValue(FontFamilyProperty); set => SetValue(FontFamilyProperty, value); }
    public FontWeight FontWeight { get => (FontWeight)GetValue(FontWeightProperty); set => SetValue(FontWeightProperty, value); }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }

    IEnumerable<FormattedText> Letters()
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var face = new Typeface(FontFamily, FontStyles.Normal, FontWeight, FontStretches.Normal);
        return Text.Select(c => new FormattedText(c.ToString(), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            face, FontSize, Foreground, dpi));
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var letters = Letters().ToList();
        if (letters.Count == 0) return new Size(0, 0);
        return new Size(letters.Sum(l => l.WidthIncludingTrailingWhitespace) + Spacing * (letters.Count - 1),
            letters.Max(l => l.Height));
    }

    protected override void OnRender(DrawingContext dc)
    {
        var x = 0.0;
        foreach (var l in Letters())
        {
            dc.DrawText(l, new Point(x, 0));
            x += l.WidthIncludingTrailingWhitespace + Spacing;
        }
    }
}

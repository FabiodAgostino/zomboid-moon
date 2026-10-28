using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Media.Animation;

namespace Moon.Controls;

/// <summary>A progress bar that glides to its new value instead of jumping: &lt;ProgressBar c:Smooth.Value="{Binding Progress}" /&gt;</summary>
public static class Smooth
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.RegisterAttached(
        "Value", typeof(double), typeof(Smooth), new PropertyMetadata(0.0, Changed));

    public static double GetValue(DependencyObject d) => (double)d.GetValue(ValueProperty);
    public static void SetValue(DependencyObject d, double value) => d.SetValue(ValueProperty, value);

    static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not RangeBase bar) return;
        var to = (double)e.NewValue;
        // going back (a new operation) is immediate, going forward glides
        var duration = to < bar.Value ? TimeSpan.Zero : TimeSpan.FromMilliseconds(380);
        bar.BeginAnimation(RangeBase.ValueProperty,
            new DoubleAnimation(to, duration) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }
}

using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Moon.Controls;

/// <summary>true is Visible, false is Collapsed; with Invert, the other way round.</summary>
public sealed class Visible : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value is true) ^ Invert ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

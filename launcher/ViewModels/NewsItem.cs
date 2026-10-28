using System.Text.RegularExpressions;
using Moon.Core;

namespace Moon.ViewModels;

/// <summary>A piece of news: the notes of a GitHub release.</summary>
public sealed partial class NewsItem
{
    public required string Title { get; init; }
    public required string Tag { get; init; }
    public required DateTimeOffset Date { get; init; }
    public required string Body { get; init; }
    public required string Url { get; init; }

    public string DateText => Date == DateTimeOffset.MinValue ? "" : Date.ToLocalTime().ToString("d MMMM yyyy");
    public bool IsNew => DateTimeOffset.Now - Date < TimeSpan.FromDays(10);
    public bool HasTag => Tag.Length > 0;

    /// <summary>The first lines without the markdown, for the small cards of the home.</summary>
    public string Excerpt
    {
        get
        {
            var text = string.Join(" ", Body.Replace("\r", "").Split('\n')
                .Select(l => l.Trim())
                .Where(l => !l.StartsWith('#'))
                .Select(l => l.TrimStart('-', '*', '>', ' '))
                .Where(l => l.Length > 0));
            text = Link().Replace(text, "$1").Replace("**", "").Replace("__", "").Replace("`", "");
            return text.Length > 170 ? text[..170].TrimEnd() + "…" : text;
        }
    }

    [GeneratedRegex(@"\[([^\]]+)\]\([^)]+\)")]
    private static partial Regex Link();

    public static NewsItem From(Release r) => new()
    {
        Title = r.Name,
        Tag = r.Tag == r.Name ? "" : r.Tag,
        Date = r.Published,
        Body = string.IsNullOrWhiteSpace(r.Body) ? "Nessuna nota per questa versione." : r.Body,
        Url = r.HtmlUrl,
    };
}

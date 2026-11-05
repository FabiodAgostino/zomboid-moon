using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Moon.Core;

/// <summary>What a pasted text looks like, before it goes to ZomBOT.</summary>
public enum MusicCodeProblem
{
    /// <summary>A whole code: it can go to ZomBOT, the only one that knows whether it is good.</summary>
    None,
    Empty,
    /// <summary>Letters of a code and nothing else, but not all of them: a paste that lost a piece, or a code typed so far.</summary>
    Incomplete,
    /// <summary>Not a code: a character outside the alphabet, or too long (a code of 1.0.4, too).</summary>
    NotACode,
}

/// <summary>A pasted text, read: the code written as ZomBOT wants it, or why it is not one, in words for the player.</summary>
public sealed record MusicCodeCheck(string? Code, MusicCodeProblem Problem)
{
    public bool Ok => Problem == MusicCodeProblem.None && Code is not null;

    public string Message => Problem switch
    {
        MusicCodeProblem.None => "Codice intero: premi Conferma.",
        MusicCodeProblem.Empty => "Incolla qui il codice: comincia con MOON-.",
        MusicCodeProblem.Incomplete => "Il codice non è intero: copialo di nuovo dalla tua scheda, con «Copia».",
        _ => "Questo non è un codice della musica: copialo di nuovo dalla tua scheda, con «Copia».",
    };
}

/// <summary>
/// The code of the music, from 1.0.5 (05/11/2026, evening): a random token that ZomBOT keeps, good once. ZomBOT gives
/// one to every Discord account (live page, «Musica»), an admin makes more with /codicemusica; the launcher sends it to
/// ZomBOT (MusicRedeemer), which spends it and answers with the key of the music. «MOON-» and 4 groups of 5 characters
/// of A-Z2-7: MOON-ABCDE-FGH23-JK4LM-NOP56. The code of 1.0.4 (the key itself, 63 characters) is not read any more.
/// Logic only.
/// </summary>
public static class MusicCode
{
    public const string Prefix = "MOON";
    const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    /// <summary>The characters of a code without «MOON» and the dashes.</summary>
    public const int BodyLength = 20;
    const int GroupLength = 5;

    /// <summary>
    /// The text as it may be pasted (lowercase, spaces, line breaks, without the dashes or without «MOON-»), written as
    /// ZomBOT wants it: MOON-XXXXX-XXXXX-XXXXX-XXXXX. Only what clearly is not a code is refused here: the wrong
    /// length or a character outside the alphabet. Whether it is good, and not used yet, only ZomBOT knows.
    /// </summary>
    public static MusicCodeCheck Check(string? text)
    {
        var body = Clean(text);
        if (body.Length == 0) return new(null, MusicCodeProblem.Empty);
        if (body.Any(c => Alphabet.IndexOf(c) < 0)) return new(null, MusicCodeProblem.NotACode);
        if (body.Length < BodyLength) return new(null, MusicCodeProblem.Incomplete);
        if (body.Length > BodyLength) return new(null, MusicCodeProblem.NotACode);
        return new(Prefix + "-" + string.Join("-", body.Chunk(GroupLength).Select(g => new string(g))), MusicCodeProblem.None);
    }

    /// <summary>
    /// Uppercase, without whitespace and dashes (any dash: a chat may turn «-» into «–»), without the «MOON» in front.
    /// A code pasted without «MOON-» whose own letters start with MOON (one in a million) keeps them: its length says so.
    /// </summary>
    static string Clean(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
            if (!char.IsWhiteSpace(c) && char.GetUnicodeCategory(c) != UnicodeCategory.DashPunctuation)
                sb.Append(char.ToUpperInvariant(c));
        var body = sb.ToString();
        return body.StartsWith(Prefix, StringComparison.Ordinal) && body.Length != BodyLength ? body[Prefix.Length..] : body;
    }
}

/// <summary>How ZomBOT answered a code.</summary>
public enum MusicRedeemOutcome
{
    /// <summary>The key of the music of now: the code is spent.</summary>
    Ok,
    /// <summary>409: the code was used already, on this PC or another.</summary>
    Used,
    /// <summary>404: ZomBOT does not know this code.</summary>
    Invalid,
    /// <summary>429: too many tries from this address.</summary>
    Slow,
    /// <summary>503: the server has no key of the music yet.</summary>
    NoKey,
    /// <summary>No answer: no network, a timeout, ZomBOT or its address down.</summary>
    Unreachable,
    /// <summary>A key, but not the one of the package's manifest: it is not written.</summary>
    OtherKey,
    /// <summary>An answer that is none of the above (a body that does not read, a key that does not match its id).</summary>
    BadAnswer,
}

/// <summary>ZomBOT's answer to a code: the key when it is the music of now, otherwise why not, in words for the player.</summary>
public sealed record MusicRedeem(MusicRedeemOutcome Outcome, byte[]? Key = null, DateTimeOffset? UsedAt = null)
{
    static readonly CultureInfo Italian = CultureInfo.GetCultureInfo("it-IT");

    public bool Ok => Outcome == MusicRedeemOutcome.Ok && Key is not null;

    public string Message => Outcome switch
    {
        MusicRedeemOutcome.Ok => "Codice accettato.",
        MusicRedeemOutcome.Used => "Questo codice è già stato usato"
                                   + (UsedAt is { } at ? $" (il {at.ToLocalTime().ToString("d MMMM yyyy 'alle' HH:mm", Italian)})" : "")
                                   + ". Per questo PC chiedi un codice nuovo a un admin.",
        MusicRedeemOutcome.Invalid => "Codice non valido: controlla di averlo copiato tutto.",
        MusicRedeemOutcome.Slow => "Troppi tentativi: riprova tra qualche minuto.",
        MusicRedeemOutcome.NoKey => "La musica non è ancora pronta sul server: riprova più tardi.",
        MusicRedeemOutcome.Unreachable => "Non riesco a raggiungere ZomBOT: controlla la connessione e riprova.",
        MusicRedeemOutcome.OtherKey => "Il codice è giusto ma la musica è cambiata: aggiorna il launcher o riprova più tardi.",
        _ => "ZomBOT ha risposto in un modo che non capisco: riprova più tardi.",
    };
}

/// <summary>
/// Sends a code to ZomBOT (mods.json, the jukebox's «pack.redeem»): POST {"code": "MOON-…"} as application/json,
/// 15 seconds at most. 200 {"key": 64 hex, "keyId": 16 hex} is the key when SHA-256(key)[:16] is its keyId and the
/// manifest's; 409 {"error": "used", "at": ISO time}, 404 {"error": "invalid"}, 429 {"error": "slow"},
/// 503 {"error": "nokey"}. The code is a secret like the key it opens: it is never logged nor kept, and it never
/// follows a redirect to another address.
/// </summary>
public sealed partial class MusicRedeemer : IDisposable
{
    readonly HttpClient http;
    readonly TimeSpan timeout;

    [GeneratedRegex("^[0-9a-fA-F]{64}$")]
    private static partial Regex KeyHex();

    [GeneratedRegex("^[0-9a-fA-F]{16}$")]
    private static partial Regex IdHex();

    public MusicRedeemer(TimeSpan? timeout = null)
    {
        this.timeout = timeout ?? TimeSpan.FromSeconds(15);
        http = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        })
        {
            Timeout = Timeout.InfiniteTimeSpan,
            MaxResponseContentBufferSize = 64 * 1024,
        };
        // the same name as the GitHub client's (Core/GitHub.cs)
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Moon-Launcher", SelfUpdate.Current.ToString(3)));
    }

    /// <summary>The address of mods.json: https only. Null for anything else.</summary>
    public static Uri? Address(string? url) =>
        Uri.TryCreate(url?.Trim(), UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps && u.Host.Length > 0 ? u : null;

    /// <summary>A whole code (MusicCode.Check) to ZomBOT; keyId is the package manifest's. Never throws for the network.</summary>
    public async Task<MusicRedeem> RedeemAsync(Uri url, string code, string keyId, CancellationToken ct)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            using var content = new StringContent(JsonSerializer.Serialize(new { code }), Encoding.UTF8);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            using var res = await http.PostAsync(url, content, limit.Token);
            var body = await res.Content.ReadAsStringAsync(limit.Token);
            return Read((int)res.StatusCode, body, keyId);
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException && !ct.IsCancellationRequested)
        {
            return new(MusicRedeemOutcome.Unreachable);
        }
    }

    /// <summary>ZomBOT's answer, read: the status first, then the body.</summary>
    public static MusicRedeem Read(int status, string body, string keyId)
    {
        string? error = null, key = null, id = null, at = null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                string? Text(string name) => doc.RootElement.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String
                    ? p.GetString()
                    : null;
                error = Text("error");
                key = Text("key");
                id = Text("keyId");
                at = Text("at");
            }
        }
        catch (JsonException)
        {
            // a page of a proxy, not ZomBOT's: the status says what it can
        }
        switch (status)
        {
            case 200:
                if (key is null || id is null || !KeyHex().IsMatch(key) || !IdHex().IsMatch(id))
                    return new(MusicRedeemOutcome.BadAnswer);
                var bytes = Convert.FromHexString(key);
                var real = Packs.KeyId(bytes);
                if (real != id.ToLowerInvariant()) return new(MusicRedeemOutcome.BadAnswer);
                return real == keyId ? new(MusicRedeemOutcome.Ok, bytes) : new(MusicRedeemOutcome.OtherKey);
            case 409:
                return new(MusicRedeemOutcome.Used, UsedAt: DateTimeOffset.TryParse(at, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal, out var when) ? when : null);
            case 404 when error == "invalid":
                return new(MusicRedeemOutcome.Invalid);
            case 429:
                return new(MusicRedeemOutcome.Slow);
            case 503 when error == "nokey":
                return new(MusicRedeemOutcome.NoKey);
            // the proxies in front of ZomBOT, when it is down: Cloudflare (52x, 530) and the gateway
            case 502 or 503 or 504 or (>= 520 and <= 527) or 530:
                return new(MusicRedeemOutcome.Unreachable);
            default:
                return new(MusicRedeemOutcome.BadAnswer);
        }
    }

    public void Dispose() => http.Dispose();
}

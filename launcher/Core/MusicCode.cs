using System.Security.Cryptography;
using System.Text;

namespace Moon.Core;

/// <summary>What a pasted text turned out to be.</summary>
public enum MusicCodeProblem
{
    /// <summary>A code that opens the music of now.</summary>
    None,
    Empty,
    /// <summary>Letters of the code and nothing else, but not all of them: a paste that lost a piece, or a code typed so far.</summary>
    Incomplete,
    /// <summary>Not a code: a wrong letter, too long, another version, the check that does not match.</summary>
    NotACode,
    /// <summary>A good code, for another key: the key of before (a new one was made), or a code from somewhere else.</summary>
    OtherKey,
}

/// <summary>A pasted text, read: the music's key when it is the code of now, otherwise why not, in words for the player.</summary>
public sealed record MusicCodeCheck(byte[]? Key, MusicCodeProblem Problem)
{
    public bool Ok => Problem == MusicCodeProblem.None && Key is not null;

    public string Message => Problem switch
    {
        MusicCodeProblem.None => "Codice giusto: premi Conferma.",
        MusicCodeProblem.Empty => "Incolla qui il codice: comincia con MOON-.",
        MusicCodeProblem.Incomplete => "Il codice non è intero: copialo di nuovo dalla tua scheda, con «Copia».",
        MusicCodeProblem.NotACode => "Questo non è il codice della musica: copialo di nuovo dalla tua scheda, con «Copia».",
        _ => "Questo codice è vecchio: la chiave della musica è cambiata. Riapri la tua scheda, vai su «Musica» e copia quello nuovo.",
    };
}

/// <summary>
/// The personal code of the music (05/11/2026): ZomBOT's live page shows it to each player, in «Musica», and the launcher
/// asks for it once, so the music is there before the first time on Moon. «moon-music-code v1», the same byte for byte
/// as the page's (zomboid-discord, src/zombot/musiccode.py), not to change on one side only:
///   code = "MOON-" + base32 (RFC 4648, uppercase, no "=") of payload + check, 39 bytes, in groups of five;
///   payload = [0x01] + salt (4 bytes) + (K XOR mask), mask = SHA-256(ASCII "moon-music-code|v1|" + salt);
///   check = SHA-256(payload)[0:2]. K is the 32-byte key of the music.
/// Every player has another salt, so another code for the same key; the code is the key, a secret like it. A code
/// is good when its K has the id of the package's manifest (Packs.KeyId == keyId). Logic only.
/// </summary>
public static class MusicCode
{
    public const string Prefix = "MOON";
    const byte Version = 1;
    const int SaltBytes = 4;
    const int KeyBytes = 32;
    const int CheckBytes = 2;
    const int PayloadBytes = 1 + SaltBytes + KeyBytes;      // 37
    const int CodeBytes = PayloadBytes + CheckBytes;         // 39
    /// <summary>Base32 characters of the 39 bytes, without the padding.</summary>
    public const int BodyLength = 63;
    const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    static readonly byte[] MaskLabel = "moon-music-code|v1|"u8.ToArray();

    /// <summary>The text read and checked against the key of the package (its manifest's keyId).</summary>
    public static MusicCodeCheck Check(string? text, string keyId)
    {
        var (key, problem) = Decode(text);
        if (key is null) return new(null, problem);
        return Packs.KeyId(key) == keyId ? new(key, MusicCodeProblem.None) : new(null, MusicCodeProblem.OtherKey);
    }

    /// <summary>
    /// K from a code, as the page reads it back: spaces, line breaks, dashes, lowercase and the «MOON» in front do not
    /// matter; the alphabet, the length, the version and the check do. Like the page, the 3 bits after the last byte
    /// are not looked at.
    /// </summary>
    public static (byte[]? Key, MusicCodeProblem Problem) Decode(string? text)
    {
        var body = Clean(text);
        if (body.Length == 0) return (null, MusicCodeProblem.Empty);
        if (body.Any(c => Alphabet.IndexOf(c) < 0)) return (null, MusicCodeProblem.NotACode);
        if (body.Length < BodyLength) return (null, MusicCodeProblem.Incomplete);
        if (body.Length > BodyLength) return (null, MusicCodeProblem.NotACode);

        var raw = Base32(body);
        var payload = raw.AsSpan(0, PayloadBytes);
        if (payload[0] != Version) return (null, MusicCodeProblem.NotACode);
        if (!SHA256.HashData(payload)[..CheckBytes].AsSpan().SequenceEqual(raw.AsSpan(PayloadBytes, CheckBytes)))
            return (null, MusicCodeProblem.NotACode);
        var salt = payload.Slice(1, SaltBytes).ToArray();
        var mask = SHA256.HashData([.. MaskLabel, .. salt]);
        var key = new byte[KeyBytes];
        for (var i = 0; i < KeyBytes; i++) key[i] = (byte)(payload[1 + SaltBytes + i] ^ mask[i]);
        return (key, MusicCodeProblem.None);
    }

    /// <summary>Uppercase, without whitespace and dashes, without the «MOON» in front (a v1 body starts with «A»).</summary>
    static string Clean(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
            if (!char.IsWhiteSpace(c) && c != '-')
                sb.Append(char.ToUpperInvariant(c));
        var body = sb.ToString();
        return body.StartsWith(Prefix, StringComparison.Ordinal) ? body[Prefix.Length..] : body;
    }

    /// <summary>RFC 4648 base32 of exactly BodyLength valid characters: CodeBytes bytes, the bits left over dropped.</summary>
    static byte[] Base32(string body)
    {
        var bytes = new byte[CodeBytes];
        int buffer = 0, bits = 0, n = 0;
        foreach (var c in body)
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(c);
            bits += 5;
            if (bits < 8) continue;
            bits -= 8;
            if (n < CodeBytes) bytes[n++] = (byte)(buffer >> bits);
            buffer &= (1 << bits) - 1;
        }
        return bytes;
    }
}

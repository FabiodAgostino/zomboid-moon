using System.Windows;
using System.Windows.Media;

namespace Moon.Controls;

/// <summary>
/// Kentucky in July: fireflies over the field and some dust in the moonlight. Drawn in the background's own
/// 1920x1140 space, so they stay on the field whatever the size of the window.
/// </summary>
public sealed class Fireflies : FrameworkElement
{
    sealed class Mote
    {
        public double X, Y, Vx, Vy, Phase, Speed, Size, Glow;
        public bool Firefly;
    }

    readonly List<Mote> motes = [];
    readonly Random rng = new(1993);
    readonly Brush fly;
    readonly Brush dust;
    TimeSpan last;
    double clock;

    public Fireflies()
    {
        IsHitTestVisible = false;
        fly = Glow(Color.FromRgb(0xD8, 0xFF, 0x8A));
        dust = Glow(Color.FromRgb(0xC8, 0xD8, 0xF0));
        for (var i = 0; i < 34; i++) motes.Add(NewMote(firefly: true));
        for (var i = 0; i < 26; i++) motes.Add(NewMote(firefly: false));
        Loaded += (_, _) => CompositionTarget.Rendering += Tick;
        Unloaded += (_, _) => CompositionTarget.Rendering -= Tick;
    }

    static Brush Glow(Color c)
    {
        var b = new RadialGradientBrush(
            [new GradientStop(c, 0), new GradientStop(Color.FromArgb(0x55, c.R, c.G, c.B), 0.35), new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1)]);
        b.Freeze();
        return b;
    }

    Mote NewMote(bool firefly) => new()
    {
        Firefly = firefly,
        X = rng.NextDouble() * 1920,
        Y = firefly ? 820 + rng.NextDouble() * 300 : rng.NextDouble() * 760,
        Vx = (rng.NextDouble() - 0.5) * (firefly ? 18 : 10),
        Vy = firefly ? (rng.NextDouble() - 0.6) * 10 : 4 + rng.NextDouble() * 6,
        Phase = rng.NextDouble() * Math.Tau,
        Speed = 0.4 + rng.NextDouble() * 0.9,
        Size = firefly ? 7 + rng.NextDouble() * 9 : 3 + rng.NextDouble() * 4,
        Glow = firefly ? 0.9 : 0.25 + rng.NextDouble() * 0.25,
    };

    void Tick(object? sender, EventArgs e)
    {
        if (e is not RenderingEventArgs r || r.RenderingTime == last) return;
        var dt = last == TimeSpan.Zero ? 0 : Math.Min(0.1, (r.RenderingTime - last).TotalSeconds);
        last = r.RenderingTime;
        if (!IsVisible) return;
        clock += dt;
        foreach (var m in motes)
        {
            m.Vx += (rng.NextDouble() - 0.5) * dt * (m.Firefly ? 30 : 6);
            m.Vy += (rng.NextDouble() - 0.5) * dt * (m.Firefly ? 22 : 2);
            m.Vx = Math.Clamp(m.Vx, -22, 22);
            m.Vy = m.Firefly ? Math.Clamp(m.Vy, -14, 10) : Math.Clamp(m.Vy, 2, 12);
            m.X += m.Vx * dt;
            m.Y += m.Vy * dt;
            if (m.X < -20) m.X = 1940;
            if (m.X > 1940) m.X = -20;
            if (m.Firefly && (m.Y < 800 || m.Y > 1140)) m.Vy = -m.Vy;
            if (!m.Firefly && m.Y > 800) { m.Y = -10; m.X = rng.NextDouble() * 1920; }
        }
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        foreach (var m in motes)
        {
            // fireflies light up and go dark, each at its own pace
            var o = m.Firefly
                ? Math.Pow(Math.Max(0, Math.Sin(clock * m.Speed * 1.6 + m.Phase)), 3) * m.Glow
                : m.Glow * (0.7 + 0.3 * Math.Sin(clock * m.Speed + m.Phase));
            if (o < 0.02) continue;
            dc.PushOpacity(o);
            dc.DrawEllipse(m.Firefly ? fly : dust, null, new Point(m.X, m.Y), m.Size, m.Size);
            dc.Pop();
        }
    }
}

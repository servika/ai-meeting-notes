using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using MeetingNotes.Audio;
// The App also pulls in System.Drawing / WinForms (tray icon), so pin the drawing
// primitives to their WPF (Media) equivalents.
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using Pen = System.Windows.Media.Pen;
using Point = System.Windows.Point;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;

namespace MeetingNotes.App;

/// <summary>
/// Loudness strip for the Trim window with two draggable handles: a green start
/// marker and a red end marker. Bars outside the kept range are tinted red, quiet
/// stretches are dimmed so the spot where the meeting ended stands out, and a
/// playhead follows playback. Clicking (away from a handle) seeks; dragging a
/// handle moves that edge of the kept range.
/// </summary>
public sealed class WaveformTrimControl : FrameworkElement
{
    // Half-width (px) of the grab zone around each handle.
    private const double HandleGrab = 10;
    // Handles may not cross closer than this (seconds).
    private const double MinGap = 0.5;

    private float[] _levels = [];
    private double _duration;
    private double _startTime;
    private double _endTime;
    private double _currentTime;
    private DragMode _drag = DragMode.None;

    private enum DragMode { None, Start, End, Seek }

    /// <summary>Seconds to seek playback to, raised on a click/scrub away from a handle.</summary>
    public event Action<double>? SeekRequested;
    /// <summary>Raised whenever a handle drag changes <see cref="StartTime"/>/<see cref="EndTime"/>.</summary>
    public event Action? RangeChanged;

    public float[] Levels
    {
        get => _levels;
        set { _levels = value ?? []; InvalidateVisual(); }
    }

    public double Duration
    {
        get => _duration;
        set { _duration = value; InvalidateVisual(); }
    }

    public double StartTime
    {
        get => _startTime;
        set { _startTime = value; InvalidateVisual(); }
    }

    public double EndTime
    {
        get => _endTime;
        set { _endTime = value; InvalidateVisual(); }
    }

    public double CurrentTime
    {
        get => _currentTime;
        set { _currentTime = value; InvalidateVisual(); }
    }

    // Frozen brushes/pens - cheap to reuse across renders.
    private static readonly Brush KeptLoud = Frozen(Color.FromRgb(0x0A, 0x84, 0xFF));
    private static readonly Brush KeptQuiet = Frozen(Color.FromArgb(0x66, 0x88, 0x88, 0x88));
    private static readonly Brush RemovedLoud = Frozen(Color.FromArgb(0x73, 0xFF, 0x3B, 0x30));
    private static readonly Brush RemovedQuiet = Frozen(Color.FromArgb(0x33, 0xFF, 0x3B, 0x30));
    private static readonly Brush RemovedShade = Frozen(Color.FromArgb(0x22, 0x80, 0x80, 0x80));
    private static readonly Pen PlayheadPen = FrozenPen(Color.FromArgb(0xC0, 0x88, 0x88, 0x88), 1.5);
    private static readonly Brush StartHandle = Frozen(Color.FromRgb(0x34, 0xC7, 0x59));
    private static readonly Brush EndHandle = Frozen(Color.FromRgb(0xFF, 0x3B, 0x30));
    private static readonly Pen StartPen = FrozenPen(Color.FromRgb(0x34, 0xC7, 0x59), 2);
    private static readonly Pen EndPen = FrozenPen(Color.FromRgb(0xFF, 0x3B, 0x30), 2);

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        // Transparent hit-test backing so the whole strip receives mouse events.
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));
        if (_levels.Length == 0 || _duration <= 0) return;

        var barWidth = w / _levels.Length;
        var startX = w * (_startTime / _duration);
        var endX = w * (_endTime / _duration);

        // Dim the removed head/tail regions.
        if (startX > 0) dc.DrawRectangle(RemovedShade, null, new Rect(0, 0, startX, h));
        if (endX < w) dc.DrawRectangle(RemovedShade, null, new Rect(endX, 0, w - endX, h));

        for (var i = 0; i < _levels.Length; i++)
        {
            var level = _levels[i];
            var x = i * barWidth;
            var center = x + barWidth / 2;
            var barH = Math.Max(2, level * h);
            var rect = new Rect(x, (h - barH) / 2, Math.Max(barWidth - 1, 0.5), barH);
            var removed = center < startX || center > endX;
            var quiet = level < Waveform.QuietLevel;
            var brush = removed
                ? (quiet ? RemovedQuiet : RemovedLoud)
                : (quiet ? KeptQuiet : KeptLoud);
            var r = barWidth / 3;
            dc.DrawRoundedRectangle(brush, null, rect, r, r);
        }

        // Playhead under the handles so the cut edges always stay visible.
        var playX = w * Math.Clamp(_currentTime / _duration, 0, 1);
        dc.DrawLine(PlayheadPen, new Point(playX, 0), new Point(playX, h));

        DrawHandle(dc, startX, h, StartPen, StartHandle);
        DrawHandle(dc, endX, h, EndPen, EndHandle);
    }

    // A full-height line with a small grip tab at the top so the handle is easy to
    // spot and grab.
    private static void DrawHandle(DrawingContext dc, double x, double h, Pen pen, Brush fill)
    {
        dc.DrawLine(pen, new Point(x, 0), new Point(x, h));
        dc.DrawRoundedRectangle(fill, null, new Rect(x - 4, 0, 8, 8), 2, 2);
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (_duration <= 0 || ActualWidth <= 0) return;

        var x = e.GetPosition(this).X;
        var startX = ActualWidth * (_startTime / _duration);
        var endX = ActualWidth * (_endTime / _duration);

        // Grab whichever handle is nearer if within the grab zone; otherwise seek.
        if (Math.Abs(x - startX) <= HandleGrab && Math.Abs(x - startX) <= Math.Abs(x - endX))
            _drag = DragMode.Start;
        else if (Math.Abs(x - endX) <= HandleGrab)
            _drag = DragMode.End;
        else
            _drag = DragMode.Seek;

        CaptureMouse();
        Apply(x);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_drag != DragMode.None) Apply(e.GetPosition(this).X);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        _drag = DragMode.None;
        ReleaseMouseCapture();
    }

    private void Apply(double x)
    {
        var t = Math.Clamp(x / ActualWidth, 0, 1) * _duration;
        switch (_drag)
        {
            case DragMode.Start:
                StartTime = Math.Clamp(t, 0, _endTime - MinGap);
                RangeChanged?.Invoke();
                break;
            case DragMode.End:
                EndTime = Math.Clamp(t, _startTime + MinGap, _duration);
                RangeChanged?.Invoke();
                break;
            case DragMode.Seek:
                SeekRequested?.Invoke(t);
                break;
        }
    }

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    private static Pen FrozenPen(Color c, double thickness)
    {
        var p = new Pen(Frozen(c), thickness);
        p.Freeze();
        return p;
    }
}
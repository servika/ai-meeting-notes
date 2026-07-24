using System.IO;
using System.Windows;
using MeetingNotes.Audio;

namespace MeetingNotes.App;

/// <summary>
/// Modal window for trimming a recording to just the meeting: a loudness waveform
/// with draggable start and end handles, a transport to preview, and "set to
/// playhead" shortcuts. On confirm, <see cref="StartSeconds"/>/<see cref="EndSeconds"/>
/// carry the chosen range back to the caller (DialogResult == true).
/// </summary>
public partial class TrimWindow
{
    private readonly string[] _tracks;
    private readonly double _duration;
    private AudioPlayer? _player;

    /// <summary>Start of the kept range, in seconds (valid when DialogResult == true).</summary>
    public double StartSeconds => Waveform.StartTime;
    /// <summary>End of the kept range, in seconds (valid when DialogResult == true).</summary>
    public double EndSeconds => Waveform.EndTime;

    public TrimWindow(IEnumerable<string> tracks, double duration)
    {
        InitializeComponent();
        _tracks = tracks.Where(File.Exists).ToArray();
        _duration = duration;

        Waveform.Duration = duration;
        Waveform.StartTime = 0;
        Waveform.EndTime = duration;
        Waveform.SeekRequested += OnWaveformSeek;
        Waveform.RangeChanged += OnRangeChanged;

        UpdateRangeLabels();
        Loaded += OnLoaded;
        Closed += (_, _) => _player?.Dispose();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Waveform decode is CPU-bound - compute off the UI thread, then paint.
        var buckets = Math.Max(80, (int)Waveform.ActualWidth / 3);
        var levels = await Task.Run(() => MeetingNotes.Audio.Waveform.Compute(_tracks, buckets));
        Waveform.Levels = levels;

        _player = new AudioPlayer();
        _player.PositionChanged += () => Dispatcher.Invoke(OnPlayerPosition);
        _player.PlaybackStopped += () => Dispatcher.Invoke(() => PlayPause.Content = "▶");
        _player.Load(_tracks);
    }

    private void OnPlayerPosition()
    {
        if (_player is null) return;
        Waveform.CurrentTime = _player.CurrentTime;
        PositionText.Text = FormatTime(_player.CurrentTime);
        // Preview stays within the kept range: pause at the end handle.
        if (_player.IsPlaying && _player.CurrentTime >= Waveform.EndTime)
        {
            _player.Pause();
            PlayPause.Content = "▶";
        }
    }

    private void OnWaveformSeek(double seconds)
    {
        _player?.Seek(seconds);
        Waveform.CurrentTime = seconds;
        PositionText.Text = FormatTime(seconds);
    }

    private void OnRangeChanged() => UpdateRangeLabels();

    private void UpdateRangeLabels()
    {
        RangeText.Text = $"Keep {FormatTime(Waveform.StartTime)} - {FormatTime(Waveform.EndTime)}";
        var removed = Math.Max(0, _duration - (Waveform.EndTime - Waveform.StartTime));
        var head = Waveform.StartTime;
        var tail = Math.Max(0, _duration - Waveform.EndTime);
        RemovedText.Text = removed < 0.5
            ? "Nothing will be removed - drag a handle inward to cut."
            : $"Removes {FormatTime(head)} from the start and {FormatTime(tail)} from the end "
              + $"({FormatTime(Waveform.EndTime - Waveform.StartTime)} kept).";
        // Guard against a no-op / inverted range.
        TrimButton.IsEnabled = removed >= 0.5 && Waveform.EndTime > Waveform.StartTime;
    }

    // ---- transport ----

    private void OnPlayPause(object sender, RoutedEventArgs e)
    {
        if (_player is null || !_player.IsReady) return;
        // Start preview from the kept-range start if we're before or past it.
        if (!_player.IsPlaying &&
            (_player.CurrentTime < Waveform.StartTime || _player.CurrentTime >= Waveform.EndTime))
            _player.Seek(Waveform.StartTime);
        _player.TogglePlay();
        PlayPause.Content = _player.IsPlaying ? "⏸" : "▶";
    }

    private void OnRestart(object sender, RoutedEventArgs e) => _player?.Seek(Waveform.StartTime);
    private void OnBack(object sender, RoutedEventArgs e) => _player?.Skip(-15);
    private void OnForward(object sender, RoutedEventArgs e) => _player?.Skip(15);

    private void OnSetStart(object sender, RoutedEventArgs e)
    {
        if (_player is null) return;
        Waveform.StartTime = Math.Clamp(_player.CurrentTime, 0, Waveform.EndTime - 0.5);
        UpdateRangeLabels();
    }

    private void OnSetEnd(object sender, RoutedEventArgs e)
    {
        if (_player is null) return;
        Waveform.EndTime = Math.Clamp(_player.CurrentTime, Waveform.StartTime + 0.5, _duration);
        UpdateRangeLabels();
    }

    // ---- actions ----

    private void OnConfirm(object sender, RoutedEventArgs e)
    {
        _player?.Pause();
        DialogResult = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private static string FormatTime(double seconds)
    {
        var s = Math.Max(0, (int)seconds);
        return s >= 3600 ? $"{s / 3600}:{(s % 3600) / 60:D2}:{s % 60:D2}"
            : $"{s / 60}:{s % 60:D2}";
    }
}
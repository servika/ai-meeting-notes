using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace MeetingNotes.Audio;

/// <summary>
/// Plays back a meeting's mic + system tracks mixed together with transport
/// controls (play/pause, seek, speed). Port of macOS MeetingAudioPlayer.
/// Uses NAudio's WaveOutEvent for playback.
/// </summary>
public sealed class AudioPlayer : IDisposable
{
    private WaveOutEvent? _output;
    private MixingSampleProvider? _mixer;
    private SpeedControlSampleProvider? _speedControl;
    private AudioFileReader? _reader1;
    private AudioFileReader? _reader2;
    private readonly System.Timers.Timer _posTimer = new(100);

    public bool IsReady { get; private set; }
    public bool IsPlaying => _output?.PlaybackState == PlaybackState.Playing;
    public double Duration { get; private set; }
    public double CurrentTime => _reader1?.CurrentTime.TotalSeconds ?? 0;
    public float Speed { get; private set; } = 1f;

    public static readonly float[] Speeds = [0.5f, 1f, 1.5f, 2f, 3f];

    public event Action? PositionChanged;
    public event Action? PlaybackStopped;

    public AudioPlayer()
    {
        _posTimer.Elapsed += (_, _) => PositionChanged?.Invoke();
    }

    /// <summary>Load one or two audio tracks for mixed playback.</summary>
    public void Load(params string[] paths)
    {
        Unload();
        var validPaths = paths.Where(File.Exists).ToArray();
        if (validPaths.Length == 0) return;

        try
        {
            _reader1 = new AudioFileReader(validPaths[0]);
            var maxDur = _reader1.TotalTime.TotalSeconds;

            _mixer = new MixingSampleProvider(_reader1.WaveFormat) { ReadFully = false };
            _mixer.AddMixerInput((ISampleProvider)_reader1);

            if (validPaths.Length > 1)
            {
                _reader2 = new AudioFileReader(validPaths[1]);
                if (_reader2.WaveFormat.SampleRate == _reader1.WaveFormat.SampleRate
                    && _reader2.WaveFormat.Channels == _reader1.WaveFormat.Channels)
                {
                    _mixer.AddMixerInput((ISampleProvider)_reader2);
                    maxDur = Math.Max(maxDur, _reader2.TotalTime.TotalSeconds);
                }
            }

            _speedControl = new SpeedControlSampleProvider(_mixer, Speed);
            _output = new WaveOutEvent();
            _output.Init(_speedControl);
            _output.PlaybackStopped += (_, _) =>
            {
                _posTimer.Stop();
                PlaybackStopped?.Invoke();
            };

            Duration = maxDur;
            IsReady = true;
        }
        catch
        {
            Unload();
        }
    }

    public void Play()
    {
        if (_output is null) return;
        if (CurrentTime >= Duration - 0.05) Seek(0);
        _output.Play();
        _posTimer.Start();
    }

    public void Pause()
    {
        _output?.Pause();
        _posTimer.Stop();
    }

    public void TogglePlay() { if (IsPlaying) Pause(); else Play(); }

    public void Seek(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Clamp(seconds, 0, Duration));
        if (_reader1 is not null) _reader1.CurrentTime = t;
        if (_reader2 is not null) _reader2.CurrentTime = t;
        PositionChanged?.Invoke();
    }

    public void Skip(double seconds) => Seek(CurrentTime + seconds);

    public void SetSpeed(float speed)
    {
        Speed = speed;
        if (_speedControl is not null) _speedControl.Speed = speed;
    }

    public void Unload()
    {
        _posTimer.Stop();
        _output?.Stop();
        _output?.Dispose(); _output = null;
        _speedControl = null;
        _mixer = null;
        _reader1?.Dispose(); _reader1 = null;
        _reader2?.Dispose(); _reader2 = null;
        IsReady = false;
        Duration = 0;
    }

    public void Dispose() => Unload();
}

/// <summary>
/// Wraps an ISampleProvider and changes playback speed by skipping or
/// duplicating samples. Pitch shifts at extreme speeds but preserves
/// intelligibility for speech at 0.5x-3x.
/// </summary>
internal sealed class SpeedControlSampleProvider(ISampleProvider source, float speed) : ISampleProvider
{
    private float _speed = speed;
    private float[] _buf = [];
    private int _bufFrames;   // valid frames currently buffered in _buf
    private double _pos;      // fractional read cursor within _buf, in frames

    public float Speed { get => _speed; set => _speed = Math.Clamp(value, 0.25f, 5f); }
    public WaveFormat WaveFormat => source.WaveFormat;

    public int Read(float[] buffer, int offset, int count)
    {
        if (Math.Abs(_speed - 1f) < 0.01f)
            return source.Read(buffer, offset, count);

        var channels = WaveFormat.Channels;
        var outFrames = count / channels;
        var written = 0;

        for (var i = 0; i < outFrames; i++)
        {
            var frame = (int)_pos;
            // Pull more source audio when the cursor reaches the buffer's end; stop
            // cleanly when the source is exhausted so WaveOut raises PlaybackStopped.
            while (frame >= _bufFrames)
            {
                var want = Math.Max(outFrames, 1);
                EnsureCapacity((_bufFrames + want) * channels);
                var got = source.Read(_buf, _bufFrames * channels, want * channels);
                if (got == 0) { Compact(channels); return written; }
                _bufFrames += got / channels;
            }
            for (var ch = 0; ch < channels; ch++)
                buffer[offset + written++] = _buf[frame * channels + ch];
            _pos += _speed;
        }

        Compact(channels);
        return written;
    }

    // Drop fully-consumed frames, keeping the tail (and the sub-frame phase in
    // _pos) so the next Read continues seamlessly instead of discarding samples.
    private void Compact(int channels)
    {
        var consumed = (int)_pos;
        if (consumed <= 0) return;
        var keep = _bufFrames - consumed;
        if (keep > 0) Array.Copy(_buf, consumed * channels, _buf, 0, keep * channels);
        _bufFrames = Math.Max(0, keep);
        _pos -= consumed;
    }

    private void EnsureCapacity(int samples)
    {
        if (_buf.Length < samples) Array.Resize(ref _buf, samples);
    }
}

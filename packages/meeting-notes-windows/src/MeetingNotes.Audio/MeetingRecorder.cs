using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace MeetingNotes.Audio;

/// <summary>An input (microphone) device the user can choose.</summary>
public readonly record struct InputDevice(string Id, string Name);

/// <summary>
/// Paths + frame counts for a finished recording's two tracks. <see cref="MicWarning"/>
/// is non-null when the microphone couldn't be captured (failed to start, or stayed
/// silent) - the system-audio track is still saved regardless.
/// </summary>
public readonly record struct CaptureResult(
    string SystemPath, string MicPath, long SystemFrames, long MicFrames, string? MicWarning);

/// <summary>
/// Captures the meeting as two separate WAV tracks with zero setup:
/// system audio via WASAPI loopback on the default render endpoint, and the mic
/// via WASAPI capture (default or a chosen input device). The mic is best-effort:
/// if it can't start or stays silent, the system track is still recorded and a
/// warning is surfaced. Tracks are resampled to whisper's 16 kHz mono on Stop().
/// </summary>
public sealed class MeetingRecorder : IDisposable
{
    // whisper.cpp wants 16 kHz mono 16-bit PCM.
    private static readonly WaveFormat WhisperFormat = new(16000, 16, 1);
    // Peak below this over the whole recording == effectively silent (no mic input).
    private const float SilenceThreshold = 0.001f;

    private WasapiLoopbackCapture? _system;
    private WasapiCapture? _mic;
    private WaveFileWriter? _systemWriter;
    private WaveFileWriter? _micWriter;
    private string _systemTemp = "";
    private string _micTemp = "";
    private string _outBase = "";
    private float _systemLevel;
    private float _micLevel;
    private float _micPeak;     // loudest mic sample seen this session
    private string? _micError;  // set when the mic failed to start

    /// <summary>Fired per buffer with the latest peak levels (0…1) for (system, mic).</summary>
    public event Action<float, float>? OnLevel;

    /// <summary>Active input (microphone) devices, for a settings picker.</summary>
    public static IReadOnlyList<InputDevice> InputDevices()
    {
        var en = new MMDeviceEnumerator();
        var list = new List<InputDevice>();
        foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            list.Add(new InputDevice(d.ID, d.FriendlyName));
        return list;
    }

    /// <summary>
    /// Begin capturing to temp files. <paramref name="micDeviceId"/> selects a specific
    /// input device; null/empty uses the system default. A mic that can't start does
    /// not abort the recording - system audio is captured either way.
    /// </summary>
    public void Start(string outBase, string? micDeviceId = null)
    {
        _outBase = outBase;
        _systemTemp = Path.GetTempFileName();
        _micTemp = Path.GetTempFileName();
        _micPeak = 0;
        _micError = null;

        // System audio (loopback) - the critical track. Throws if there's no default
        // render device; that's a genuine error and propagates.
        _system = new WasapiLoopbackCapture();
        _systemWriter = new WaveFileWriter(_systemTemp, _system.WaveFormat);
        _system.DataAvailable += (_, e) =>
        {
            _systemWriter!.Write(e.Buffer, 0, e.BytesRecorded);
            _systemLevel = PeakLevel(e.Buffer, e.BytesRecorded, _system!.WaveFormat);
            OnLevel?.Invoke(_systemLevel, _micLevel);
        };
        _system.StartRecording();

        // Microphone - best-effort. If it throws (no device, in use, blocked), keep
        // recording system audio and remember the error for the warning on Stop.
        try
        {
            _mic = string.IsNullOrEmpty(micDeviceId)
                ? new WasapiCapture()
                : new WasapiCapture(new MMDeviceEnumerator().GetDevice(micDeviceId));
            _micWriter = new WaveFileWriter(_micTemp, _mic.WaveFormat);
            _mic.DataAvailable += (_, e) =>
            {
                _micWriter!.Write(e.Buffer, 0, e.BytesRecorded);
                _micLevel = PeakLevel(e.Buffer, e.BytesRecorded, _mic!.WaveFormat);
                if (_micLevel > _micPeak) _micPeak = _micLevel;
                OnLevel?.Invoke(_systemLevel, _micLevel);
            };
            _mic.StartRecording();
        }
        catch (Exception ex)
        {
            _micError = ex.Message;
            _micWriter?.Dispose(); _micWriter = null;
            _mic?.Dispose(); _mic = null;
        }
    }

    /// <summary>Stop both captures and write the resampled 16 kHz mono tracks.</summary>
    public async Task<CaptureResult> StopAsync()
    {
        await StopAndFlushAsync(_system, () => { _systemWriter?.Dispose(); _systemWriter = null; });
        await StopAndFlushAsync(_mic, () => { _micWriter?.Dispose(); _micWriter = null; });

        var systemOut = _outBase + ".system.wav";
        var micOut = _outBase + ".mic.wav";
        var systemFrames = Resample(_systemTemp, systemOut);
        var micFrames = Resample(_micTemp, micOut);

        TryDelete(_systemTemp);
        TryDelete(_micTemp);

        // Decide whether the mic actually captured anything useful.
        string? micWarning = null;
        if (_micError is not null)
            micWarning = $"Microphone unavailable ({_micError}). Recorded system audio only.";
        else if (micFrames == 0 || _micPeak < SilenceThreshold)
            micWarning = "No microphone audio captured - check Windows mic permissions "
                + "(Settings → Privacy & security → Microphone → \"Let desktop apps access your microphone\"), "
                + "or pick your mic in Settings.";

        return new CaptureResult(systemOut, micOut, systemFrames, micFrames, micWarning);
    }

    private static async Task StopAndFlushAsync(IWaveIn? capture, Action disposeWriter)
    {
        if (capture is null) return;
        var tcs = new TaskCompletionSource();
        void Stopped(object? s, StoppedEventArgs e) => tcs.TrySetResult();
        capture.RecordingStopped += Stopped;
        capture.StopRecording();
        await tcs.Task;
        capture.RecordingStopped -= Stopped;
        disposeWriter();
        capture.Dispose();
    }

    /// <summary>Resample a captured temp WAV to 16 kHz mono 16-bit; returns frame count.</summary>
    private static long Resample(string src, string dst)
    {
        if (!File.Exists(src) || new FileInfo(src).Length == 0) return 0;
        MediaFoundationApi.Startup();
        using var reader = new WaveFileReader(src);
        using var resampler = new MediaFoundationResampler(reader, WhisperFormat) { ResamplerQuality = 60 };
        WaveFileWriter.CreateWaveFile(dst, resampler);
        using var outReader = new WaveFileReader(dst);
        return outReader.SampleCount;
    }

    /// <summary>Peak amplitude (0…1) of a capture buffer, for VU metering.</summary>
    private static float PeakLevel(byte[] buffer, int bytes, WaveFormat format)
    {
        float peak = 0;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            for (var i = 0; i + 4 <= bytes; i += 4)
            {
                var sample = Math.Abs(BitConverter.ToSingle(buffer, i));
                if (sample > peak) peak = sample;
            }
        }
        else if (format.BitsPerSample == 16)
        {
            for (var i = 0; i + 2 <= bytes; i += 2)
            {
                var sample = Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f);
                if (sample > peak) peak = sample;
            }
        }
        return Math.Clamp(peak, 0f, 1f);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }

    public void Dispose()
    {
        _systemWriter?.Dispose();
        _micWriter?.Dispose();
        _system?.Dispose();
        _mic?.Dispose();
    }
}
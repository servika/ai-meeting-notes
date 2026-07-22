using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace MeetingNotes.Audio;

/// <summary>
/// Watches the default input (microphone) device and, when another app starts
/// using it (Zoom, Teams, Meet, etc.), suggests that the user start recording.
/// Port of macOS MeetingDetector.swift.
/// </summary>
public sealed class MeetingDetector : IDisposable
{
    private System.Timers.Timer? _timer;
    private bool _wasInUse;
    private bool _dismissedThisCall;

    public bool SuggestRecording { get; private set; }

    /// <summary>Set externally: true while the app is recording/processing.</summary>
    public Func<bool> IsBusy { get; set; } = () => false;

    /// <summary>Set externally: whether detection is enabled in settings.</summary>
    public Func<bool> IsEnabled { get; set; } = () => true;

    /// <summary>Fired on the rising edge when a meeting is first detected.</summary>
    public event Action? MeetingDetected;

    public void Start()
    {
        Stop();
        _timer = new System.Timers.Timer(4000);
        _timer.Elapsed += (_, _) => Tick();
        _timer.Start();
    }

    public void Stop()
    {
        _timer?.Stop();
        _timer?.Dispose();
        _timer = null;
    }

    public void Dismiss()
    {
        SuggestRecording = false;
        _dismissedThisCall = true;
    }

    public void Clear()
    {
        SuggestRecording = false;
    }

    private void Tick()
    {
        bool inUse;
        try { inUse = IsInputDeviceInUse(); }
        catch { return; }

        var prev = _wasInUse;

        if (!inUse)
        {
            _wasInUse = false;
            _dismissedThisCall = false;
            if (SuggestRecording) SuggestRecording = false;
            return;
        }

        // Don't consume the rising edge while the app can't act on it: leave
        // _wasInUse as-is so the meeting still fires once busy/disabled clears.
        if (IsBusy() || !IsEnabled()) return;

        _wasInUse = true;
        if (!prev && !_dismissedThisCall)
        {
            SuggestRecording = true;
            MeetingDetected?.Invoke();
        }
    }

    private static bool IsInputDeviceInUse()
    {
        using var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        try { device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications); }
        catch { return false; }

        using (device)
        {
            var sessions = device.AudioSessionManager.Sessions;
            // More than one session on the input device typically means another
            // app has activated the mic alongside the idle session.
            var activeCount = 0;
            for (var i = 0; i < sessions.Count; i++)
            {
                using var session = sessions[i];
                if (session.State == AudioSessionState.AudioSessionStateActive)
                    activeCount++;
            }
            return activeCount > 0;
        }
    }

    public void Dispose() => Stop();
}

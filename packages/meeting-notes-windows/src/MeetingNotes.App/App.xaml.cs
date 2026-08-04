using MeetingNotes.Core;

namespace MeetingNotes.App;

public partial class App : System.Windows.Application
{
    public App()
    {
        // Last-chance capture of a crash. Writes only when the user enabled the
        // diagnostic log in Settings; the exception is not swallowed, so behaviour
        // is unchanged for everyone else.
        DispatcherUnhandledException += (_, e) =>
            DiagnosticLog.Exception("unhandled (UI thread)", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex) DiagnosticLog.Exception("unhandled", ex);
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
            DiagnosticLog.Exception("unobserved task", e.Exception);
    }
}
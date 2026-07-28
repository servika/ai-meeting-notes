using System.Net;
using System.Text;

namespace MeetingNotes.Integration.Tests;

/// <summary>
/// A local stand-in for Ollama (and, with a rewritten base URL, the Claude API):
/// a real HTTP server on loopback, so the summary stage exercises its actual
/// request/response/timeout handling instead of a mocked client.
/// </summary>
public sealed class StubSummaryServer : IDisposable
{
    private readonly HttpListener _listener = new();
    private readonly Func<string, (int Status, string Body)> _respond;
    private readonly CancellationTokenSource _cts = new();
    private readonly List<string> _requests = [];

    public string Url { get; }

    /// <summary>Prompts the server has been asked to summarize, in order.</summary>
    public IReadOnlyList<string> Requests { get { lock (_requests) return _requests.ToList(); } }

    private StubSummaryServer(int port, Func<string, (int, string)> respond)
    {
        _respond = respond;
        Url = $"http://127.0.0.1:{port}";
        _listener.Prefixes.Add(Url + "/");
        _listener.Start();
        _ = Task.Run(LoopAsync);
    }

    /// <summary>A server that returns <paramref name="summary"/> as an Ollama response.</summary>
    public static StubSummaryServer Returning(string summary) =>
        Start(_ => (200, $$"""{"model":"stub","response":{{System.Text.Json.JsonSerializer.Serialize(summary)}},"done":true}"""));

    /// <summary>A server that reports a model error the way Ollama does.</summary>
    public static StubSummaryServer Failing(string error = "model not found") =>
        Start(_ => (200, $$"""{"error":{{System.Text.Json.JsonSerializer.Serialize(error)}}}"""));

    /// <summary>A server that returns an HTTP error status.</summary>
    public static StubSummaryServer Erroring(int status) => Start(_ => (status, "upstream is unhappy"));

    public static StubSummaryServer Start(Func<string, (int Status, string Body)> respond)
    {
        // Retry a few times: the port may be taken between probing and binding.
        for (var attempt = 0; ; attempt++)
        {
            try { return new StubSummaryServer(FreePort(), respond); }
            catch (HttpListenerException) when (attempt < 5) { }
        }
    }

    private static int FreePort()
    {
        var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    private async Task LoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch { return; }

            string body;
            using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                body = await reader.ReadToEndAsync();
            lock (_requests) _requests.Add(body);

            var (status, response) = _respond(body);
            var bytes = Encoding.UTF8.GetBytes(response);
            ctx.Response.StatusCode = status;
            ctx.Response.ContentType = "application/json";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _listener.Stop(); } catch { }
        _listener.Close();
        _cts.Dispose();
    }
}

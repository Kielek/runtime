using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

if (args.Length == 0 || !string.Equals(args[0], "server", StringComparison.OrdinalIgnoreCase))
{
    Console.WriteLine("Usage: dotnet run -- server [--port <port>]");
    return;
}

await RunServerAsync(args);

static async Task RunServerAsync(string[] args)
{
    int port = GetIntOption(args, "--port", 5000);
    string url = $"http://127.0.0.1:{port}/";

    var propagator = DistributedContextPropagator.CreateW3CPropagator();
    Console.WriteLine($"DiagnosticSource assembly: {typeof(DistributedContextPropagator).Assembly.Location}");
    Console.WriteLine($"Listening on {url}");

    using var httpClient = new HttpClient();
    var builder = WebApplication.CreateSlimBuilder();
    builder.WebHost.UseUrls(url);
    builder.Logging.ClearProviders();

    var app = builder.Build();
    app.MapPost("/", async (HttpRequest request) =>
    {
        propagator.ExtractTraceIdAndState(
            request,
            static (object? carrier, string fieldName, out string? fieldValue, out IEnumerable<string>? fieldValues) =>
            {
                var request = (HttpRequest)carrier!;
                fieldValue = request.Headers.TryGetValue(fieldName, out var values) ? values.ToString() : null;
                fieldValues = null;
            },
            out string? traceId,
            out string? traceState);

        using var serverActivity = new Activity("w3c.repro.server");
        if (traceId is not null)
        {
            serverActivity.SetParentId(traceId);
        }
        else
        {
            serverActivity.SetIdFormat(ActivityIdFormat.W3C);
        }

        serverActivity.TraceStateString = traceState;
        serverActivity.Start();

        Data[] data = await JsonSerializer.DeserializeAsync<Data[]>(request.Body) ?? [];
        foreach (Data item in data)
        {
            using var callbackActivity = new Activity("w3c.repro.callback");
            callbackActivity.Start();
            await SendCallbackAsync(httpClient, propagator, item);
        }
    });

    await app.RunAsync();
}

static async Task SendCallbackAsync(HttpClient httpClient, DistributedContextPropagator propagator, Data item)
{
    if (item.Url is null)
    {
        throw new InvalidOperationException("Callback URL is missing.");
    }

    using var callback = new HttpRequestMessage(HttpMethod.Post, item.Url);
    callback.Content = new StringContent(
        JsonSerializer.Serialize(item.Arguments ?? []),
        Encoding.UTF8,
        "application/json");

    propagator.Inject(
        Activity.Current,
        callback,
        static (object? carrier, string fieldName, string value) =>
        {
            var request = (HttpRequestMessage)carrier!;
            request.Headers.Remove(fieldName);
            request.Headers.TryAddWithoutValidation(fieldName, value);
        });

    using HttpResponseMessage response = await httpClient.SendAsync(callback);
    response.EnsureSuccessStatusCode();
}

static int GetIntOption(string[] args, string optionName, int defaultValue)
{
    for (int i = 0; i < args.Length; i++)
    {
        if (string.Equals(args[i], optionName, StringComparison.OrdinalIgnoreCase) &&
            i + 1 < args.Length &&
            int.TryParse(args[i + 1], out int value))
        {
            return value;
        }

        string prefix = optionName + "=";
        if (args[i].StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
            int.TryParse(args[i].AsSpan(prefix.Length), out value))
        {
            return value;
        }
    }

    return defaultValue;
}

internal sealed class Data
{
    [JsonPropertyName("url")]
    public string? Url { get; set; }

    [JsonPropertyName("arguments")]
    public Data[]? Arguments { get; set; }
}

using System.Text.Json;
using Confluent.Kafka;
using EventLogs.Data.Context;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

public record RequestKey(string Region, short Locality, Guid RequestId);

public class RequestProcessorService : BackgroundService
{
    private readonly ILogger<RequestProcessorService> _logger;
    private readonly ConsumerConfig _config;
    private readonly ProcessorSettings _settings;
    private readonly IServiceScopeFactory _scopeFactory;

    public RequestProcessorService(
        ILogger<RequestProcessorService> logger,
        ConsumerConfig config,
        ProcessorSettings settings,
        IServiceScopeFactory scopeFactory)
    {
        _logger       = logger;
        _config       = config;
        _settings     = settings;
        _scopeFactory = scopeFactory;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var consumer = new ConsumerBuilder<string, Ignore>(_config).Build();
        consumer.Subscribe(_settings.Topic);

        _logger.LogInformation("Starting processor for region {Region}", _settings.Region);

        while (!stoppingToken.IsCancellationRequested)
        {
            var cr = consumer.Consume(stoppingToken);
            if (cr?.Message?.Key == null)
                continue;

            if (!TryParseKey(cr.Message.Key, out var key))
                continue;

            if (!string.Equals(key.Region, _settings.Region, StringComparison.OrdinalIgnoreCase))
                continue; // selector: ignore foreign regions

            using var scope = _scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<OptimaEventLogsContext>();

            // Example: load full request and log an event
            var request = await db.RequestInfos
                .AsNoTracking()
                .FirstOrDefaultAsync(r => r.RequestId == key.RequestId, stoppingToken);

            if (request == null)
            {
                _logger.LogWarning("Request {RequestId} not found", key.RequestId);
                continue;
            }

            _logger.LogInformation("Processing request {RequestId} for region {Region}",
                key.RequestId, key.Region);

            // TODO: write to request_event_log, update status_head, etc.
        }
    }

    private static bool TryParseKey(string keyJson, out RequestKey key)
    {
        try
        {
            using var doc = JsonDocument.Parse(keyJson);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() < 3)
            {
                key = default!;
                return false;
            }

            var region    = root[0].GetString() ?? "";
            var locality  = (short)root[1].GetInt32();
            var requestId = root[2].GetGuid();

            key = new RequestKey(region, locality, requestId);
            return true;
        }
        catch
        {
            key = default!;
            return false;
        }
    }
}

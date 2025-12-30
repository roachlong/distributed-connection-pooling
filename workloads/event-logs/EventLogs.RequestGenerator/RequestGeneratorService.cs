using EventLogs.Data.Context;
using EventLogs.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

public class RequestGeneratorService : BackgroundService
{
    private readonly ILogger<RequestGeneratorService> _logger;
    private readonly IDbContextFactory<OptimaEventLogsContext> _dbFactory;
    private readonly Random _rng = new();

    public RequestGeneratorService(
        ILogger<RequestGeneratorService> logger,
        IDbContextFactory<OptimaEventLogsContext> dbFactory)
    {
        _logger = logger;
        _dbFactory = dbFactory;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            await using var db = await _dbFactory.CreateDbContextAsync(stoppingToken);

            var req = new RequestInfo
            {
                // Assuming scaffold gave you these props:
                RequestId      = Guid.NewGuid(),
                RequestTypeId  = (short)(_rng.Next(1, 10)),
                CreatedTs      = DateTime.UtcNow,
                RequestStatusId = 1, // PENDING
                // other fields...
            };

            db.RequestInfos.Add(req);
            await db.SaveChangesAsync(stoppingToken);

            _logger.LogInformation("Created request {RequestId}", req.RequestId);

            // throttle a bit for demo
            await Task.Delay(TimeSpan.FromMilliseconds(200), stoppingToken);
        }
    }
}

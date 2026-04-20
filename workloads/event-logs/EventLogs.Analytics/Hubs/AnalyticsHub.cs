using EventLogs.Analytics.Models;
using Microsoft.AspNetCore.SignalR;

namespace EventLogs.Analytics.Hubs;

public class AnalyticsHub : Hub
{
    public async Task SendAggregateUpdate(List<RequestStatusAggregate> aggregates)
    {
        await Clients.All.SendAsync("ReceiveAggregateUpdate", aggregates);
    }

    public async Task SendMetricsUpdate(GlobalMetrics metrics)
    {
        await Clients.All.SendAsync("ReceiveMetricsUpdate", metrics);
    }

    public async Task SendProgress(Dictionary<string, PaginationMetrics> progress)
    {
        await Clients.All.SendAsync("ReceiveProgress", progress);
    }
}

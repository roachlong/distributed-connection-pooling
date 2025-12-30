using EventLogs.Data.Context;
using EventLogs.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = Host.CreateDefaultBuilder(args)
    .ConfigureServices((context, services) =>
    {
        var cs = Environment.GetEnvironmentVariable("EVENTLOGS_DB")
                 ?? "Host=pgbouncer;Port=6543;Database=optima;Username=app_user;Password=secret";

        services.AddDbContext<OptimaEventLogsContext>(opt =>
            opt.UseNpgsql(cs, o => o.EnableRetryOnFailure()));
        
        services.AddHostedService<RequestGeneratorService>();
    });

await builder.RunConsoleAsync();

using Confluent.Kafka;
using EventLogs.Data.Context;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = Host.CreateDefaultBuilder(args)
    .ConfigureServices((context, services) =>
    {
        var region = Environment.GetEnvironmentVariable("REGION") ?? "us-east";

        var dbCs = Environment.GetEnvironmentVariable("EVENTLOGS_DB")
                  ?? "Host=pgbouncer;Port=6543;Database=optima;Username=app_user;Password=secret";

        var kafkaBootstrap = Environment.GetEnvironmentVariable("KAFKA_BOOTSTRAP")
                             ?? "kafka:9093";

        services.AddSingleton(new ConsumerConfig
        {
            BootstrapServers = kafkaBootstrap,
            GroupId          = $"eventlogs-processor-{region}",
            AutoOffsetReset  = AutoOffsetReset.Earliest,
        });

        services.AddDbContext<OptimaEventLogsContext>(opt =>
            opt.UseNpgsql(dbCs, o => o.EnableRetryOnFailure()));

        services.AddSingleton(new ProcessorSettings
        {
            Region = region,
            Topic  = "acct-mgmt.new-request-events"
        });

        services.AddHostedService<RequestProcessorService>();
    });

await builder.RunConsoleAsync();

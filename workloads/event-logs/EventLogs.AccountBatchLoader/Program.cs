using EventLogs.Common;
using EventLogs.Data;
using EventLogs.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using System.Text.Json;

var configuration = new ConfigurationBuilder()
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false)
    .AddEnvironmentVariables()  // This allows docker-compose env vars to override appsettings.json
    .Build();

var connectionString = configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("DefaultConnection not found");

var batchSize = configuration.GetValue<int>("BatchSize", 1000);
var totalAccounts = configuration.GetValue<int>("TotalAccounts", 10000);

using var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
var logger = loggerFactory.CreateLogger<Program>();

logger.LogInformation("=== Account Batch Loader ===");
logger.LogInformation("Connection: {Connection}", connectionString.Substring(0, Math.Min(50, connectionString.Length)));
logger.LogInformation("Total Accounts: {Total}, Batch Size: {BatchSize}", totalAccounts, batchSize);

var optionsBuilder = new DbContextOptionsBuilder<EventLogsContext>();
optionsBuilder.UseNpgsql(connectionString);

using var dbContext = new EventLogsContext(optionsBuilder.Options);

// Test connection with retry
try
{
    await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
    {
        await dbContext.Database.ExecuteSqlRawAsync("SELECT 1");
    }, logger, "connection test");

    logger.LogInformation("Database connection successful");
}
catch (Exception ex)
{
    logger.LogError(ex, "Database connection failed after retries");
    return 1;
}

// Check total account count with retry
var totalAccountCount = await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
{
    return await dbContext.AccountInfo.CountAsync();
}, logger, "count existing accounts");

logger.LogInformation("Total accounts in system: {Count}", totalAccountCount);

// Count "new" accounts (accounts without request_info records) with retry
var newCount = await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
{
    return await dbContext.AccountInfo
        .Where(a => !dbContext.RequestInfo.Any(r => r.PrimaryAccountNumber == a.AccountNumber))
        .CountAsync();
}, logger, "count new accounts");

logger.LogInformation("New accounts (without requests): {Count}", newCount);

if (newCount >= totalAccounts)
{
    logger.LogInformation("Sufficient new accounts already exist ({New}/{Target}). Exiting.", newCount, totalAccounts);
    return 0;
}

var accountsToLoad = totalAccounts - newCount;
logger.LogInformation("Loading {Count} new accounts to maintain target of {Target} new accounts...", accountsToLoad, totalAccounts);

var strategies = new[] { "Growth", "Value", "Income", "Balanced", "Aggressive", "Conservative" };
var currencies = new[] { "USD", "EUR", "GBP", "JPY", "CAD", "AUD" };
var random = new Random(42); // Deterministic seed for reproducibility

var loadedCount = 0;

// Batch by region to target correct gateway (even though locality is auto-calculated by DB)
var regionalBatches = new Dictionary<string, List<AccountInfo>>
{
    { "us-east", new List<AccountInfo>() },
    { "us-central", new List<AccountInfo>() },
    { "us-west", new List<AccountInfo>() }
};

for (int i = 0; i < accountsToLoad; i++)
{
    var accountNumber = $"ACCT-{totalAccountCount + i + 1:D8}";

    // Compute locality to determine target region/gateway (but don't set it - DB auto-calculates)
    var locality = LocalityHasher.ComputeLocality(accountNumber);
    var region = LocalityHasher.LocalityToRegion(locality);

    var account = new AccountInfo
    {
        AccountNumber = accountNumber,
        AccountName = $"Account {totalAccountCount + i + 1}",
        Strategy = strategies[random.Next(strategies.Length)],
        BaseCurrency = currencies[random.Next(currencies.Length)]
        // locality is NOT set here - it's auto-computed by database
    };

    regionalBatches[region].Add(account);

    // Check if any region batch is full
    foreach (var kvp in regionalBatches)
    {
        if (kvp.Value.Count >= batchSize)
        {
            var batchRegion = kvp.Key;
            var count = kvp.Value.Count;

            await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
            {
                await dbContext.AccountInfo.AddRangeAsync(kvp.Value);
                await dbContext.SaveChangesAsync();
            }, logger, $"save {count} accounts to {batchRegion}");

            loadedCount += count;
            logger.LogInformation("Loaded {Count} accounts to {Region} ({Loaded}/{Total} total, {Percent:F1}%)",
                count, batchRegion, loadedCount, accountsToLoad, (loadedCount * 100.0 / accountsToLoad));

            kvp.Value.Clear();
        }
    }
}

// Load remaining accounts for each region
foreach (var kvp in regionalBatches.Where(r => r.Value.Count > 0))
{
    var batchRegion = kvp.Key;
    var count = kvp.Value.Count;

    await DatabaseRetryHelper.ExecuteWithRetryAsync(async () =>
    {
        await dbContext.AccountInfo.AddRangeAsync(kvp.Value);
        await dbContext.SaveChangesAsync();
    }, logger, $"save remaining {count} accounts to {batchRegion}");

    loadedCount += count;
    logger.LogInformation("Loaded {Count} accounts to {Region} ({Loaded}/{Total} total)",
        count, batchRegion, loadedCount, accountsToLoad);
}

// Show distribution across regions
logger.LogInformation("=== Account Distribution by Region ===");
var distribution = await dbContext.AccountInfo
    .GroupBy(a => new
    {
        Region = a.Locality >= 0 && a.Locality <= 9 ? "us-east" :
                 a.Locality >= 10 && a.Locality <= 19 ? "us-central" : "us-west"
    })
    .Select(g => new { g.Key.Region, Count = g.Count() })
    .ToListAsync();

foreach (var item in distribution.OrderBy(d => d.Region))
{
    logger.LogInformation("{Region}: {Count} accounts", item.Region, item.Count);
}

logger.LogInformation("=== Account Batch Load Complete ===");
return 0;

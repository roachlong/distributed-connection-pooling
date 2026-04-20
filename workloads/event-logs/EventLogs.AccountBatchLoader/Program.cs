using EventLogs.Common;
using EventLogs.Data;
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

// Test connection
try
{
    await dbContext.Database.ExecuteSqlRawAsync("SELECT 1");
    logger.LogInformation("Database connection successful");
}
catch (Exception ex)
{
    logger.LogError(ex, "Database connection failed");
    return 1;
}

// Load locality configuration
var localitiesByRegion = new Dictionary<string, List<short>>();
foreach (var region in new[] { "us-east", "us-central", "us-west" })
{
    var configKey = $"Localities_{region.Replace("-", "_")}";
    var localitiesJson = configuration.GetValue<string>(configKey)
        ?? throw new InvalidOperationException($"{configKey} not configured");
    var localities = JsonSerializer.Deserialize<List<short>>(localitiesJson)
        ?? throw new InvalidOperationException($"Failed to parse {configKey}");
    localitiesByRegion[region] = localities;
    logger.LogInformation("Region {Region} localities: {Localities}", region, string.Join(",", localities));
}

// Check total account count
var totalAccountCount = await dbContext.AccountInfo.CountAsync();
logger.LogInformation("Total accounts in system: {Count}", totalAccountCount);

// Count "new" accounts per region (accounts without request_info records in their home region)
logger.LogInformation("=== Counting New Accounts by Region ===");
var newAccountsByRegion = new Dictionary<string, int>();

foreach (var kvp in localitiesByRegion)
{
    var region = kvp.Key;
    var localities = kvp.Value;

    // Count accounts in this region's locality range that don't have request_info
    var newCount = await dbContext.AccountInfo
        .Where(a => localities.Contains(a.Locality))
        .Where(a => !dbContext.RequestInfo.Any(r => r.PrimaryAccountId == a.AccountId))
        .CountAsync();

    newAccountsByRegion[region] = newCount;
    logger.LogInformation("{Region}: {Count} new accounts", region, newCount);
}

var totalNewAccounts = newAccountsByRegion.Values.Sum();
logger.LogInformation("Total new accounts across all regions: {Count}", totalNewAccounts);

if (totalNewAccounts >= totalAccounts)
{
    logger.LogInformation("Sufficient new accounts already exist ({New}/{Target}). Exiting.", totalNewAccounts, totalAccounts);
    return 0;
}

var accountsToLoad = totalAccounts - totalNewAccounts;
logger.LogInformation("Loading {Count} new accounts to maintain target of {Target} new accounts...", accountsToLoad, totalAccounts);

var strategies = new[] { "Growth", "Value", "Income", "Balanced", "Aggressive", "Conservative" };
var currencies = new[] { "USD", "EUR", "GBP", "JPY", "CAD", "AUD" };
var random = new Random(42); // Deterministic seed for reproducibility

var loadedCount = 0;

// Batch by region to avoid cross-region transactions
var regionalBatches = new Dictionary<string, List<AccountInfo>>
{
    { "us-east", new List<AccountInfo>() },
    { "us-central", new List<AccountInfo>() },
    { "us-west", new List<AccountInfo>() }
};

for (int i = 0; i < accountsToLoad; i++)
{
    var accountId = Guid.NewGuid();
    var locality = LocalityHasher.ComputeLocality(accountId);
    var region = LocalityHasher.LocalityToRegion(locality);

    var account = new AccountInfo
    {
        AccountId = accountId,
        AccountNumber = $"ACCT-{totalAccountCount + i + 1:D8}",
        AccountName = $"Account {totalAccountCount + i + 1}",
        Strategy = strategies[random.Next(strategies.Length)],
        BaseCurrency = currencies[random.Next(currencies.Length)]
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

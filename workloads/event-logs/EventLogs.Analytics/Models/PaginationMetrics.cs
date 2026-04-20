namespace EventLogs.Analytics.Models;

public class PaginationMetrics
{
    public string Region { get; set; } = "";
    public int TotalPages { get; set; }
    public int CompletedPages { get; set; }
    public int TotalQueries { get; set; }
    public double AverageResponseTimeMs { get; set; }
    public int ActiveConnections { get; set; }
    public int PeakConnections { get; set; }
    public long TotalRowsProcessed { get; set; }
    public DateTime? StartTime { get; set; }
    public DateTime? EndTime { get; set; }
    public bool IsComplete => CompletedPages >= TotalPages && TotalPages > 0;
    public double ProgressPercent => TotalPages > 0 ? (CompletedPages * 100.0 / TotalPages) : 0;
    public TimeSpan? ElapsedTime => StartTime.HasValue ?
        (EndTime ?? DateTime.UtcNow) - StartTime.Value : null;
}

public class GlobalMetrics
{
    public Dictionary<string, PaginationMetrics> RegionalMetrics { get; set; } = new();
    public int TotalQueries => RegionalMetrics.Values.Sum(m => m.TotalQueries);
    public double AverageResponseTimeMs => RegionalMetrics.Values.Any() ?
        RegionalMetrics.Values.Average(m => m.AverageResponseTimeMs) : 0;
    public int PeakConnections => RegionalMetrics.Values.Any() ?
        RegionalMetrics.Values.Max(m => m.PeakConnections) : 0;
    public long TotalRowsProcessed => RegionalMetrics.Values.Sum(m => m.TotalRowsProcessed);
    public bool AllComplete => RegionalMetrics.Values.All(m => m.IsComplete) && RegionalMetrics.Any();
    public double OverallProgress => RegionalMetrics.Values.Any() ?
        RegionalMetrics.Values.Average(m => m.ProgressPercent) : 0;
}

namespace EventLogs.Analytics.Models;

public class RequestStatusAggregate
{
    public string RequestType { get; set; } = "";
    public string Status { get; set; } = "";
    public int Count { get; set; }
    public string Region { get; set; } = "";
}

public class RequestTypeStatusGroup
{
    public string RequestType { get; set; } = "";
    public Dictionary<string, int> StatusCounts { get; set; } = new();
    public int TotalCount => StatusCounts.Values.Sum();
}

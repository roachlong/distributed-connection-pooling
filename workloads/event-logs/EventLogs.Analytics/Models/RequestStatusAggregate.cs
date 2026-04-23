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

public class RequestDetail
{
    public Guid RequestId { get; set; }
    public string RequestType { get; set; } = "";
    public string Status { get; set; } = "";
    public string Region { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
    public string RequestedBy { get; set; } = "";
    public Guid AccountId { get; set; }
}

public class EventLogEntry
{
    public long LogId { get; set; }
    public Guid RequestId { get; set; }
    public int SequenceNumber { get; set; }
    public string EventType { get; set; } = "";
    public string Status { get; set; } = "";
    public DateTime EventTimestamp { get; set; }
    public string? EventData { get; set; }
    public string? ErrorMessage { get; set; }
}

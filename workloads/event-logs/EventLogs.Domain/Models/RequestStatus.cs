using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Identifies the minimum selected value.
/// </summary>
public partial class RequestStatus
{
    public int StatusId { get; set; }

    public string StatusCode { get; set; } = null!;

    public string Description { get; set; } = null!;
}

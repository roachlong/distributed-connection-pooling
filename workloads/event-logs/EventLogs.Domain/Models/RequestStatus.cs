using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestStatus
{
    public int StatusId { get; set; }

    public string StatusCode { get; set; } = null!;

    public string Description { get; set; } = null!;
}

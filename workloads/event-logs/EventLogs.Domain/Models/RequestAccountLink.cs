using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Concatenates all selected values using the provided delimiter.
/// </summary>
public partial class RequestAccountLink
{
    public Guid RequestId { get; set; }

    public Guid AccountId { get; set; }

    public string? Role { get; set; }

    public decimal? AllocationPct { get; set; }
}

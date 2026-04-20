using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestEventLog
{
    public Guid RequestId { get; set; }

    public long SeqNum { get; set; }

    public long ActionStateLinkId { get; set; }

    public int StatusId { get; set; }

    public DateTime EventTs { get; set; }

    public string? Actor { get; set; }

    public string? Metadata { get; set; }

    public string IdempotencyKey { get; set; } = null!;

    public virtual RequestActionStateLink ActionStateLink { get; set; } = null!;

    public virtual RequestStatus Status { get; set; } = null!;
}

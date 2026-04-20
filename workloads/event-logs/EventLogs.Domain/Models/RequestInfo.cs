using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestInfo
{
    public Guid RequestId { get; set; }

    public int RequestTypeId { get; set; }

    public Guid PrimaryAccountId { get; set; }

    public DateTime CreatedTs { get; set; }

    public string RequestedBy { get; set; } = null!;

    public string? Description { get; set; }

    public DateTime? TargetEffectiveTs { get; set; }

    public int RequestStatusId { get; set; }

    public virtual RequestStatus RequestStatus { get; set; } = null!;

    public virtual RequestType RequestType { get; set; } = null!;
}

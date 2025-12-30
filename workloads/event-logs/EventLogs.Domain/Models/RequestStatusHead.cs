using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Calculates the sum of the selected values.
/// </summary>
public partial class RequestStatusHead
{
    public short Locality { get; set; }

    public Guid RequestId { get; set; }

    public long ActionStateLinkId { get; set; }

    public int StatusId { get; set; }

    public DateTime EventTs { get; set; }

    public long SeqNum { get; set; }

    public virtual RequestActionStateLink ActionStateLink { get; set; } = null!;

    public virtual RequestStatus Status { get; set; } = null!;
}

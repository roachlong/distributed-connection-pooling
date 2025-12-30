using System;
using System.Collections.Generic;

namespace EventLogs.Data;

/// <summary>
/// Identifies the minimum selected value.
/// </summary>
public partial class RequestActionType
{
    public int ActionTypeId { get; set; }

    public string ActionCode { get; set; } = null!;

    public string Description { get; set; } = null!;

    public virtual ICollection<RequestActionStateLink> RequestActionStateLink { get; set; } = new List<RequestActionStateLink>();
}

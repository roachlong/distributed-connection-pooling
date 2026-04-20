using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates slope of the least-squares-fit linear equation determined by the (X, Y) pairs.
/// </summary>
public partial class RequestState
{
    public int StateId { get; set; }

    public string StateCode { get; set; } = null!;

    public string Description { get; set; } = null!;

    public virtual ICollection<RequestActionStateLink> RequestActionStateLink { get; set; } = new List<RequestActionStateLink>();
}

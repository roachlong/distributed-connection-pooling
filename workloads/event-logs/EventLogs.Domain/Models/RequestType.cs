using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Calculates square of the correlation coefficient.
/// </summary>
public partial class RequestType
{
    public int RequestTypeId { get; set; }

    public string RequestTypeCode { get; set; } = null!;

    public string Description { get; set; } = null!;

    public virtual ICollection<RequestActionStateLink> RequestActionStateLink { get; set; } = new List<RequestActionStateLink>();
}

using System;
using System.Collections.Generic;

namespace EventLogs.Domain.Models;

/// <summary>
/// Shows all defined Spatial Reference Identifiers (SRIDs). Matches PostGIS&apos; spatial_ref_sys table.
/// </summary>
public partial class SpatialRefSys
{
    public long? Srid { get; set; }

    public string? AuthName { get; set; }

    public long? AuthSrid { get; set; }

    public string? Srtext { get; set; }

    public string? Proj4text { get; set; }
}

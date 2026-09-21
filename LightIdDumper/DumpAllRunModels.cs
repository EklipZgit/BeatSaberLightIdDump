using System;
using System.Collections.Generic;
using Newtonsoft.Json;

namespace LightIdDumper
{
    // The external runner trusts this manifest only when Complete is true and every environment result succeeded.
    internal sealed class DumpAllRunStatus
    {
        [JsonProperty(Order = 0)]
        public int StatusFormatVersion { get; set; } = 1;

        [JsonProperty(Order = 1)]
        public int DumpFormatVersion { get; set; } = 5;

        [JsonProperty(Order = 2)]
        public string GameVersion { get; set; } = string.Empty;

        [JsonProperty(Order = 3)]
        public DateTime StartedAtUtc { get; set; }

        [JsonProperty(Order = 4)]
        public DateTime? FinishedAtUtc { get; set; }

        [JsonProperty(Order = 5)]
        public bool Complete { get; set; }

        [JsonProperty(Order = 6)]
        public string? FatalError { get; set; }

        [JsonProperty(Order = 7)]
        public List<string> ExpectedEnvironmentNames { get; set; } = new();

        [JsonProperty(Order = 8)]
        public List<DumpAllEnvironmentResult> Environments { get; set; } = new();
    }

    // Per-environment classified paths and counts let PowerShell reject stale or partial paired writes without parsing prose logs.
    internal sealed class DumpAllEnvironmentResult
    {
        [JsonProperty(Order = 0)]
        public string EnvironmentName { get; set; } = string.Empty;

        [JsonProperty(Order = 1)]
        public bool Succeeded { get; set; }

        [JsonProperty(Order = 2)]
        public string? BehaviorLightsOutputPath { get; set; }

        [JsonProperty(Order = 3)]
        public string? OtherLightsOutputPath { get; set; }

        [JsonProperty(Order = 4)]
        public int BehaviorLightCount { get; set; }

        [JsonProperty(Order = 5)]
        public int OtherLightCount { get; set; }

        [JsonProperty(Order = 6)]
        public string? Error { get; set; }
    }
}

using System.Collections.Generic;
using Newtonsoft.Json;
using UnityEngine;

namespace LightIdDumper
{
    // Format 5 samples at Chroma's environment-enhancement boundary (end of frame after BeatmapObjectSpawnController.Start),
    // so every path and GameCore root index matches what Chroma resolves in gameplay; format 4 and earlier sampled
    // before level setup completed and carried transient GameCore root offsets in dynamically-spawned ring paths.
    // Paired filenames classify lights without repeating constant or inapplicable fields on every record.
    internal sealed class EnvironmentLightDump
    {
        [JsonProperty(Order = 0)]
        public int FormatVersion { get; set; } = 5;

        [JsonProperty(Order = 1)]
        public string EnvironmentName { get; set; } = string.Empty;

        [JsonProperty(Order = 2)]
        public string GameVersion { get; set; } = string.Empty;

        // Capture time is intentionally absent so identical runtime data remains byte-stable across reruns and produces no timestamp-only diff.
        [JsonProperty(Order = 3)]
        public string? LightManagerPath { get; set; }

        [JsonProperty(Order = 4)]
        public int InitialRegisteredLightCount { get; set; }

        [JsonProperty(Order = 5)]
        public int TotalRegisteredLightCount { get; set; }

        [JsonProperty(Order = 6)]
        public List<LightIdSlotDump> LightIdSlots { get; set; } = new();
    }

    // A slot is exactly LightWithIdManager._lights[beatSaberLightId], not a Chroma ID or a named fixture group.
    internal sealed class LightIdSlotDump
    {
        [JsonProperty(Order = 0)]
        public int BeatSaberLightId { get; set; }

        [JsonProperty(Order = 1)]
        public string? CommonGameObjectPath { get; set; }

        [JsonProperty(Order = 2)]
        public int RegisteredLightCount { get; set; }

        [JsonProperty(Order = 3)]
        public List<RegisteredLightDump> RegisteredLights { get; set; } = new();
    }

    // IndexWithinLightIdList is the Heck table value; the internal classification controls which file and field set receives each record.
    internal sealed class RegisteredLightDump
    {
        [JsonProperty(Order = 0)]
        public int IndexWithinLightIdList { get; set; }

        [JsonProperty(Order = 1)]
        public int? ComponentLightId { get; set; }

        [JsonProperty(Order = 2)]
        public int? Type { get; set; }

        [JsonProperty(Order = 3)]
        public string? TypeName { get; set; }

        // Regression: runtime positions and Unity instance IDs change between equivalent runs, so durable component identity uses hierarchy, type, scale, and scene data only.
        [JsonProperty(Order = 4)]
        public string? RelativeGameObjectPath { get; set; }

        [JsonProperty(Order = 5)]
        public string? GameObjectPath { get; set; }

        [JsonProperty(Order = 6)]
        public string? ComponentType { get; set; }

        [JsonProperty(Order = 7)]
        public VectorDump? LocalScale { get; set; }

        [JsonProperty(Order = 8)]
        public string? SceneName { get; set; }

        [JsonProperty(Order = 9)]
        public string? OwnerGameObjectPath { get; set; }

        [JsonProperty(Order = 10)]
        public string? OwnerComponentType { get; set; }

        [JsonProperty(Order = 11)]
        public int? IndexWithinOwner { get; set; }

        [JsonProperty(Order = 12)]
        public VectorDump? OwnerLocalScale { get; set; }

        [JsonProperty(Order = 13)]
        public string? OwnerSceneName { get; set; }

        [JsonProperty(Order = 14)]
        public float? Intensity { get; set; }

        [JsonProperty(Order = 15)]
        public int? BakeId { get; set; }

        [JsonProperty(Order = 16)]
        public float? Weight { get; set; }

        [JsonIgnore]
        internal bool IsNonMonoBehavior { get; set; }

        [JsonIgnore]
        internal string[]? PathSegments { get; set; }

        // Direct Unity identity exists only for BehaviorLights; run-local positions and instance IDs are omitted because they create false diffs.
        public bool ShouldSerializeGameObjectPath() => !IsNonMonoBehavior;

        public bool ShouldSerializeLocalScale() => !IsNonMonoBehavior;

        public bool ShouldSerializeSceneName() => !IsNonMonoBehavior;

        // Owner and wrapper-child identity exists only for OtherLights; explicit nulls remain available there when a particular wrapper lacks a value.
        public bool ShouldSerializeOwnerGameObjectPath() => IsNonMonoBehavior;

        public bool ShouldSerializeOwnerComponentType() => IsNonMonoBehavior;

        public bool ShouldSerializeIndexWithinOwner() => IsNonMonoBehavior;

        public bool ShouldSerializeOwnerLocalScale() => IsNonMonoBehavior;

        public bool ShouldSerializeOwnerSceneName() => IsNonMonoBehavior;

        public bool ShouldSerializeIntensity() => IsNonMonoBehavior;

        public bool ShouldSerializeBakeId() => IsNonMonoBehavior;

        public bool ShouldSerializeWeight() => IsNonMonoBehavior;
    }

    // Completion data lets the batch controller advance only after both classified files finish writing.
    internal sealed class LightDumpCompletion
    {
        internal LightDumpCompletion(
            string environmentName,
            string? behaviorLightsOutputPath,
            string? otherLightsOutputPath,
            int behaviorLightCount,
            int otherLightCount,
            string? error)
        {
            EnvironmentName = environmentName;
            BehaviorLightsOutputPath = behaviorLightsOutputPath;
            OtherLightsOutputPath = otherLightsOutputPath;
            BehaviorLightCount = behaviorLightCount;
            OtherLightCount = otherLightCount;
            Error = error;
        }

        internal string EnvironmentName { get; }

        internal string? BehaviorLightsOutputPath { get; }

        internal string? OtherLightsOutputPath { get; }

        internal int BehaviorLightCount { get; }

        internal int OtherLightCount { get; }

        internal string? Error { get; }

        internal bool Succeeded => Error == null;
    }

    // Numeric coordinates remain machine-comparable across game-version dumps.
    internal sealed class VectorDump
    {
        internal VectorDump(Vector3 vector)
        {
            X = vector.x;
            Y = vector.y;
            Z = vector.z;
        }

        [JsonProperty(Order = 0)]
        public float X { get; }

        [JsonProperty(Order = 1)]
        public float Y { get; }

        [JsonProperty(Order = 2)]
        public float Z { get; }
    }
}

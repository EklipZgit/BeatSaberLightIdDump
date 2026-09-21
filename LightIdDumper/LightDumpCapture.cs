using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using HarmonyLib;
using Newtonsoft.Json;
using Newtonsoft.Json.Serialization;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace LightIdDumper
{
    // Captures are lifecycle-scoped and disk work happens once, outside per-frame lighting paths.
    internal static class LightDumpCapture
    {
        private static readonly FieldInfo? SceneSetupDataField = AccessTools.Field(typeof(EnvironmentSceneSetup), "_sceneSetupData");
        private static readonly FieldInfo? LightSwitchEventTypeField = AccessTools.Field(typeof(LightSwitchEventEffect), "_event");
        private static readonly Dictionary<int, GameObject[]> RootObjectsBySceneHandle = new();
        private static int _environmentBeginFrame;
        private static int _captureToken;
        private static int _initialRegisteredLightCount;
        private static bool _capturePending;
        private static string _environmentName = "UnknownEnvironment";
        private static LightWithIdManager? _lightManager;

        // The dump-all controller observes completed writes without polling partially written JSON files.
        internal static event Action<LightDumpCompletion>? DumpCompleted;

        // Resetting the token creates a clean diagnostic lifetime across dynamic plugin enables.
        internal static void Initialize()
        {
            _captureToken++;
            _capturePending = false;
            _lightManager = null;
            RootObjectsBySceneHandle.Clear();
        }

        // Regression: frame-delayed capture observed startup-animated ring transforms, so the capture boundary must
        // be the single authoritative one instead of whichever lifecycle edge runs first.
        internal static void BeginEnvironment(EnvironmentSceneSetup environmentSceneSetup)
        {
            _captureToken++;
            _capturePending = true;
            _environmentBeginFrame = Time.frameCount;
            _environmentName = GetEnvironmentName(environmentSceneSetup);
            _lightManager = FindLightManager();

            // The current format records actual registered-list entries instead of calling them generic light entries.
            _initialRegisteredLightCount = _lightManager != null
                ? CountRegisteredLights(_lightManager._lights)
                : 0;
            RootObjectsBySceneHandle.Clear();

            if (_lightManager == null)
            {
                Plugin.Log.Warn($"Environment [{_environmentName}] began before LightManager could be resolved; registration observation will supply it before the Chroma-boundary snapshot.");
                return;
            }

            Plugin.Log.Info($"Environment [{_environmentName}] began at frame [{_environmentBeginFrame}] with {_initialRegisteredLightCount} registered lights already present; capture runs at Chroma's environment-enhancement boundary (end of frame after BeatmapObjectSpawnController.Start).");
        }

        // Regression: the manager can be undiscoverable during InstallBindings, so RegisterLight supplies it without delaying the pre-render snapshot into an animation frame.
        internal static void ObserveRegistration(LightWithIdManager lightManager)
        {
            if (!_capturePending)
            {
                return;
            }

            if (_lightManager == null)
            {
                _lightManager = lightManager;

                // The fallback manager uses the same unambiguous registered-light count as the normal setup path.
                _initialRegisteredLightCount = CountRegisteredLights(lightManager._lights);
            }
            else if (_lightManager != lightManager)
            {
                return;
            }
        }

        // Disable invalidates any scheduled pre-render callback without needing to discover or repair Unity components in a hot path.
        internal static void Dispose()
        {
            _captureToken++;
            _capturePending = false;
            _lightManager = null;
            RootObjectsBySceneHandle.Clear();
        }

        // Chroma resolves environment-enhancement IDs from a coroutine started in a BeatmapObjectSpawnController.Start
        // prefix and resumed at WaitForEndOfFrame (Heck Chroma EnvironmentEnhancementManager.Start/DelayedStart);
        // sampling at that identical boundary is the dumper's core parity requirement (see ChromaBoundaryCapturePatch).
        // The scheduled token keeps a prior environment's coroutine from capturing the next environment.
        internal static void ScheduleChromaBoundaryCapture(BeatmapObjectSpawnController spawnController)
        {
            if (!_capturePending)
            {
                return;
            }

            spawnController.StartCoroutine(CaptureAtChromaBoundary(_captureToken));
        }

        private static IEnumerator CaptureAtChromaBoundary(int captureToken)
        {
            yield return new WaitForEndOfFrame();
            CaptureAtInitializedBoundary(
                captureToken,
                "BeatmapObjectSpawnController.Start + WaitForEndOfFrame (Chroma environment-enhancement boundary)");
        }

        // A single guarded capture path makes the first valid post-initialization boundary win and records which lifecycle edge produced the snapshot.
        private static void CaptureAtInitializedBoundary(int captureToken, string trigger)
        {
            if (!_capturePending || captureToken != _captureToken)
            {
                return;
            }

            LightWithIdManager? lightManager = _lightManager ?? FindLightManager();
            _capturePending = false;
            if (lightManager == null)
            {
                string error = $"LightManager was unavailable at the pre-render capture boundary for environment [{_environmentName}].";
                Plugin.Log.Error(error);
                DumpCompleted?.Invoke(new LightDumpCompletion(_environmentName, null, null, 0, 0, error));
                return;
            }

            _lightManager = lightManager;
            Plugin.Log.Info($"Capturing environment [{_environmentName}] synchronously at frame [{Time.frameCount}] (armed at [{_environmentBeginFrame}]) from [{trigger}].");
            WriteDump(lightManager);
        }

        // The stable snapshot walks only populated ID slots and preserves null list entries used by Chroma.
        private static void WriteDump(LightWithIdManager lightManager)
        {
            string? behaviorLightsOutputPath = null;
            string? otherLightsOutputPath = null;
            int behaviorLightCount = 0;
            int otherLightCount = 0;
            try
            {
                EnvironmentLightDump completeDump = BuildDump(lightManager);

                // Separate files make the component/MonoBehaviour fixtures directly consumable while preserving non-MonoBehaviour wrapper reference data independently.
                EnvironmentLightDump behaviorLightsDump = FilterDump(completeDump, false);
                EnvironmentLightDump otherLightsDump = FilterDump(completeDump, true);
                ValidateDump(behaviorLightsDump, false);
                ValidateDump(otherLightsDump, true);
                behaviorLightCount = behaviorLightsDump.TotalRegisteredLightCount;
                otherLightCount = otherLightsDump.TotalRegisteredLightCount;
                string outputDirectory = Path.Combine(
                    Environment.CurrentDirectory,
                    "UserData",
                    "LightIdDumper",
                    SanitizeFileName(Application.version));
                Directory.CreateDirectory(outputDirectory);
                string environmentFileName = SanitizeFileName(_environmentName);
                behaviorLightsOutputPath = Path.Combine(outputDirectory, $"{environmentFileName}_BehaviorLights.json");
                otherLightsOutputPath = Path.Combine(outputDirectory, $"{environmentFileName}_OtherLights.json");
                WriteJson(behaviorLightsOutputPath, behaviorLightsDump);
                WriteJson(otherLightsOutputPath, otherLightsDump);

                // A successful paired capture removes the obsolete combined filename so consumers cannot select stale mixed data.
                string obsoleteCombinedOutputPath = Path.Combine(outputDirectory, $"{environmentFileName}.json");
                if (File.Exists(obsoleteCombinedOutputPath))
                {
                    File.Delete(obsoleteCombinedOutputPath);
                }

                // The completion line names both classifications so logs can prove that neither half of the snapshot was omitted.
                Plugin.Log.Info($"Dumped [{behaviorLightCount}] MonoBehaviour lights to [{behaviorLightsOutputPath}] and [{otherLightCount}] other lights to [{otherLightsOutputPath}] for [{_environmentName}].");
                DumpCompleted?.Invoke(new LightDumpCompletion(_environmentName, behaviorLightsOutputPath, otherLightsOutputPath, behaviorLightCount, otherLightCount, null));
            }
            catch (Exception exception)
            {
                Plugin.Log.Error($"Failed to dump environment [{_environmentName}]: {exception}");
                DumpCompleted?.Invoke(new LightDumpCompletion(_environmentName, behaviorLightsOutputPath, otherLightsOutputPath, behaviorLightCount, otherLightCount, exception.ToString()));
            }
            finally
            {
                RootObjectsBySceneHandle.Clear();
            }
        }

        // Both output files use the current schema; RegisteredLightDump controls classification-specific fields while preserving meaningful null wrapper values.
        private static void WriteJson(string outputPath, EnvironmentLightDump dump)
        {
            string json = JsonConvert.SerializeObject(
                dump,
                Formatting.Indented,
                new JsonSerializerSettings
                {
                    // Camel-case output matches the planned Chroma/ChroMapper table tooling and the requested sample shape.
                    ContractResolver = new CamelCasePropertyNamesContractResolver(),
                    NullValueHandling = NullValueHandling.Include,
                });
            File.WriteAllText(outputPath, json, new UTF8Encoding(false));
        }

        // Filtering retains each light's original manager-list index while recalculating file-local counts and hierarchy prefixes.
        private static EnvironmentLightDump FilterDump(EnvironmentLightDump source, bool includeNonMonoBehaviors)
        {
            // Classified copies retain only stable environment identity and light data so rerunning a capture cannot create a timestamp-only change.
            var filtered = new EnvironmentLightDump
            {
                EnvironmentName = source.EnvironmentName,
                GameVersion = source.GameVersion,
                LightManagerPath = source.LightManagerPath,
                InitialRegisteredLightCount = source.InitialRegisteredLightCount,
            };

            for (int slotIndex = 0; slotIndex < source.LightIdSlots.Count; slotIndex++)
            {
                LightIdSlotDump sourceSlot = source.LightIdSlots[slotIndex];

                // A direct bounded pass avoids adding a LINQ dependency to the capture path and retains original manager ordering.
                var selectedLights = new List<RegisteredLightDump>(sourceSlot.RegisteredLights.Count);
                for (int lightIndex = 0; lightIndex < sourceSlot.RegisteredLights.Count; lightIndex++)
                {
                    RegisteredLightDump light = sourceSlot.RegisteredLights[lightIndex];
                    if (light.IsNonMonoBehavior == includeNonMonoBehaviors)
                    {
                        selectedLights.Add(light);
                    }
                }

                if (selectedLights.Count == 0)
                {
                    continue;
                }

                var filteredSlot = new LightIdSlotDump
                {
                    BeatSaberLightId = sourceSlot.BeatSaberLightId,
                    RegisteredLightCount = selectedLights.Count,
                    RegisteredLights = selectedLights,
                };
                int commonSegmentCount = FindCommonSegmentCount(filteredSlot.RegisteredLights);
                filteredSlot.CommonGameObjectPath = GetCommonGameObjectPath(filteredSlot.RegisteredLights, commonSegmentCount);
                for (int lightIndex = 0; lightIndex < filteredSlot.RegisteredLights.Count; lightIndex++)
                {
                    RegisteredLightDump light = filteredSlot.RegisteredLights[lightIndex];
                    if (light.PathSegments != null)
                    {
                        light.RelativeGameObjectPath = string.Join(".", light.PathSegments, commonSegmentCount, light.PathSegments.Length - commonSegmentCount);
                    }
                }

                filtered.TotalRegisteredLightCount += filteredSlot.RegisteredLightCount;
                filtered.LightIdSlots.Add(filteredSlot);
            }

            return filtered;
        }

        // Building data separately from serialization keeps all Unity access on the main thread.
        private static EnvironmentLightDump BuildDump(LightWithIdManager lightManager)
        {
            // Runtime captures deliberately have no wall-clock metadata because repository diffs should reflect only actual environment-light changes.
            var dump = new EnvironmentLightDump
            {
                EnvironmentName = _environmentName,
                GameVersion = Application.version,
                LightManagerPath = BuildPath(lightManager.transform, out _),
                InitialRegisteredLightCount = _initialRegisteredLightCount,
            };

            // Chroma's environment-component type is a BasicBeatmapEventType whose LightSwitchEventEffect targets the manager slot.
            Dictionary<int, LightEventTypeBinding> eventTypesByLightId = BuildEventTypesByLightId();
            List<ILightWithId>[] lightsById = lightManager._lights;
            for (int lightId = 0; lightId < lightsById.Length; lightId++)
            {
                List<ILightWithId> lights = lightsById[lightId];
                if (lights == null || lights.Count == 0)
                {
                    continue;
                }

                // Each populated outer array slot stays separate from its inner Heck-addressable list indexes.
                eventTypesByLightId.TryGetValue(lightId, out LightEventTypeBinding? eventType);
                LightIdSlotDump slot = BuildSlot(lightId, lights, eventType);
                dump.TotalRegisteredLightCount += slot.RegisteredLightCount;
                dump.LightIdSlots.Add(slot);
            }

            return dump;
        }

        // Longest common hierarchy prefixes are path data, so the current format does not label them as semantic group names.
        private static LightIdSlotDump BuildSlot(int beatSaberLightId, List<ILightWithId> lights, LightEventTypeBinding? eventType)
        {
            var slot = new LightIdSlotDump
            {
                BeatSaberLightId = beatSaberLightId,
                RegisteredLightCount = lights.Count,
            };

            for (int indexWithinLightIdList = 0; indexWithinLightIdList < lights.Count; indexWithinLightIdList++)
            {
                slot.RegisteredLights.Add(BuildRegisteredLight(indexWithinLightIdList, lights[indexWithinLightIdList], eventType));
            }

            int commonSegmentCount = FindCommonSegmentCount(slot.RegisteredLights);
            slot.CommonGameObjectPath = GetCommonGameObjectPath(slot.RegisteredLights, commonSegmentCount);
            for (int i = 0; i < slot.RegisteredLights.Count; i++)
            {
                RegisteredLightDump light = slot.RegisteredLights[i];
                if (light.PathSegments != null)
                {
                    light.RelativeGameObjectPath = string.Join(".", light.PathSegments, commonSegmentCount, light.PathSegments.Length - commonSegmentCount);
                }
            }

            return slot;
        }

        // Internal classification sends each entry to its named output without serializing a redundant per-record discriminator.
        private static RegisteredLightDump BuildRegisteredLight(int indexWithinLightIdList, ILightWithId light, LightEventTypeBinding? eventType)
        {
            if (light == null)
            {
                return new RegisteredLightDump
                {
                    IndexWithinLightIdList = indexWithinLightIdList,
                    Type = eventType?.Type,
                    TypeName = eventType?.TypeName,
                    IsNonMonoBehavior = true,
                };
            }

            MonoBehaviour? behaviour = light as MonoBehaviour;
            var result = new RegisteredLightDump
            {
                IndexWithinLightIdList = indexWithinLightIdList,
                ComponentLightId = light.lightId,
                Type = eventType?.Type,
                TypeName = eventType?.TypeName,
                ComponentType = light.GetType().FullName ?? light.GetType().Name,
                IsNonMonoBehavior = behaviour == null,
            };
            if (behaviour == null)
            {
                Component? owner = FindOwningComponent(light);
                if (owner != null)
                {
                    PopulateOwnerIdentity(result, owner, light);
                }

                // Runtime and lightmap wrapper values help distinguish children sharing the same owner object.
                result.Intensity = ReadNullableFloat(light, "intensity", "_intensity");
                result.BakeId = ReadNullableInt(light, "bakeId", "_bakeId");
                result.Weight = ReadNullableFloat(light, "weight", "_weight");
                return result;
            }

            Transform transform = behaviour.transform;
            GameObject gameObject = behaviour.gameObject;
            result.GameObjectPath = BuildPath(transform, out string[] segments);
            result.PathSegments = segments;
            result.RelativeGameObjectPath = result.GameObjectPath;
            result.LocalScale = new VectorDump(transform.localScale);
            result.SceneName = gameObject.scene.name;
            return result;
        }

        // LightSwitchEventEffect is the authoritative bridge from Chroma's documented BasicBeatmapEventType "type" to a LightWithIdManager slot.
        private static Dictionary<int, LightEventTypeBinding> BuildEventTypesByLightId()
        {
            var result = new Dictionary<int, LightEventTypeBinding>();
            if (LightSwitchEventTypeField == null)
            {
                Plugin.Log.Warn("Could not resolve LightSwitchEventEffect._event; dump type/typeName values will be null.");
                return result;
            }

            LightSwitchEventEffect[] effects = Resources.FindObjectsOfTypeAll<LightSwitchEventEffect>();
            for (int i = 0; i < effects.Length; i++)
            {
                LightSwitchEventEffect effect = effects[i];
                if (effect == null || !effect.gameObject.scene.IsValid() || !effect.gameObject.scene.isLoaded)
                {
                    continue;
                }

                object? eventTypeValue = LightSwitchEventTypeField.GetValue(effect);
                if (eventTypeValue == null)
                {
                    continue;
                }

                int type = Convert.ToInt32(eventTypeValue);
                string? typeName = Enum.GetName(eventTypeValue.GetType(), eventTypeValue);
                var binding = new LightEventTypeBinding(type, typeName);
                if (result.TryGetValue(effect.lightsId, out LightEventTypeBinding? existing))
                {
                    if (existing.Type != binding.Type)
                    {
                        // A singular Chroma type is ambiguous if two different events control the same manager slot; retain the lower enum value deterministically and keep the diagnostic.
                        Plugin.Log.Warn($"Light ID slot [{effect.lightsId}] is controlled by both event types [{existing.TypeName ?? existing.Type.ToString()}] and [{binding.TypeName ?? binding.Type.ToString()}].");
                        if (binding.Type < existing.Type)
                        {
                            result[effect.lightsId] = binding;
                        }
                    }

                    continue;
                }

                result.Add(effect.lightsId, binding);
            }

            return result;
        }

        // LightWithIds.LightWithId stores its backing MonoBehaviour in a private base field across supported game versions.
        private static Component? FindOwningComponent(ILightWithId light)
        {
            FieldInfo? parentField = FindField(light.GetType(), "_parentLightWithIds");
            return parentField?.GetValue(light) as Component;
        }

        // Owner paths, transforms, and owner-array indexes make RuntimeLightWithIds and LightmapLightsWithIds entries comparable without unstable Unity instance IDs.
        private static void PopulateOwnerIdentity(RegisteredLightDump result, Component owner, ILightWithId light)
        {
            Transform transform = owner.transform;
            GameObject gameObject = owner.gameObject;
            result.OwnerGameObjectPath = BuildPath(transform, out string[] segments);
            result.PathSegments = segments;
            result.RelativeGameObjectPath = result.OwnerGameObjectPath;
            result.OwnerComponentType = owner.GetType().FullName ?? owner.GetType().Name;
            result.IndexWithinOwner = FindIndexWithinOwner(owner, light);
            result.OwnerLocalScale = new VectorDump(transform.localScale);
            result.OwnerSceneName = gameObject.scene.name;
        }

        // The owner enumeration is authoritative for ChroMapper's arrayId and runs only once per environment snapshot.
        private static int? FindIndexWithinOwner(Component owner, ILightWithId light)
        {
            PropertyInfo? lightsProperty = AccessTools.Property(owner.GetType(), "lightWithIds");
            FieldInfo? lightsField = FindField(owner.GetType(), "_lightWithIds");
            object? value = lightsProperty?.GetValue(owner, null) ?? lightsField?.GetValue(owner);
            if (!(value is IEnumerable ownerLights))
            {
                return null;
            }

            int index = 0;
            foreach (object ownerLight in ownerLights)
            {
                if (ReferenceEquals(ownerLight, light))
                {
                    return index;
                }

                index++;
            }

            return null;
        }

        // Private wrapper fields changed visibility over time, so walk the runtime inheritance chain by exact field name.
        private static FieldInfo? FindField(Type type, string fieldName)
        {
            Type? current = type;
            while (current != null)
            {
                FieldInfo? field = current.GetField(fieldName, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly);
                if (field != null)
                {
                    return field;
                }

                current = current.BaseType;
            }

            return null;
        }

        // Identifying scalar access accepts either a public property or serialized backing field without version branches.
        private static object? ReadMember(object instance, params string[] names)
        {
            for (int i = 0; i < names.Length; i++)
            {
                PropertyInfo? property = AccessTools.Property(instance.GetType(), names[i]);
                if (property != null)
                {
                    return property.GetValue(instance, null);
                }

                FieldInfo? field = FindField(instance.GetType(), names[i]);
                if (field != null)
                {
                    return field.GetValue(instance);
                }
            }

            return null;
        }

        // Numeric wrapper values are optional because not every ILightWithId implementation defines intensity.
        private static float? ReadNullableFloat(object instance, params string[] names)
        {
            object? value = ReadMember(instance, names);
            return value != null
                ? Convert.ToSingle(value)
                : (float?)null;
        }

        // Bake IDs exist only on lightmap-backed child lights and remain null for every other implementation.
        private static int? ReadNullableInt(object instance, params string[] names)
        {
            object? value = ReadMember(instance, names);
            return value != null
                ? Convert.ToInt32(value)
                : (int?)null;
        }

        // Integrity checks prevent the batch runner from treating a structurally incomplete snapshot as successful.
        private static void ValidateDump(EnvironmentLightDump dump, bool expectNonMonoBehaviors)
        {
            int total = 0;
            var slotIds = new HashSet<int>();
            for (int slotIndex = 0; slotIndex < dump.LightIdSlots.Count; slotIndex++)
            {
                LightIdSlotDump slot = dump.LightIdSlots[slotIndex];
                if (!slotIds.Add(slot.BeatSaberLightId))
                {
                    throw new InvalidDataException($"Duplicate Beat Saber light ID slot [{slot.BeatSaberLightId}].");
                }

                if (slot.RegisteredLightCount != slot.RegisteredLights.Count)
                {
                    throw new InvalidDataException($"Slot [{slot.BeatSaberLightId}] count [{slot.RegisteredLightCount}] does not match [{slot.RegisteredLights.Count}] entries.");
                }

                var managerIndexes = new HashSet<int>();
                int previousManagerIndex = -1;
                for (int lightIndex = 0; lightIndex < slot.RegisteredLights.Count; lightIndex++)
                {
                    RegisteredLightDump light = slot.RegisteredLights[lightIndex];
                    if (!managerIndexes.Add(light.IndexWithinLightIdList) || light.IndexWithinLightIdList <= previousManagerIndex)
                    {
                        throw new InvalidDataException($"Slot [{slot.BeatSaberLightId}] has duplicate or unordered manager-list index [{light.IndexWithinLightIdList}].");
                    }

                    if (light.IsNonMonoBehavior != expectNonMonoBehaviors)
                    {
                        throw new InvalidDataException($"Slot [{slot.BeatSaberLightId}] manager-list index [{light.IndexWithinLightIdList}] is in the wrong classified output.");
                    }

                    previousManagerIndex = light.IndexWithinLightIdList;
                }

                total += slot.RegisteredLightCount;
            }

            if (total != dump.TotalRegisteredLightCount)
            {
                throw new InvalidDataException($"Total registered-light count [{dump.TotalRegisteredLightCount}] does not match slot sum [{total}].");
            }
        }

        // This reproduces Chroma's scene.[sibling]name hierarchy identifiers used by environment lookups.
        private static string BuildPath(Transform transform, out string[] segments)
        {
            var reversedSegments = new List<string>(8);
            Transform current = transform;
            while (current.parent != null)
            {
                reversedSegments.Add($"[{current.GetSiblingIndex()}]{current.name}");
                current = current.parent;
            }

            reversedSegments.Add($"[{GetRootIndex(current.gameObject)}]{current.name}");
            reversedSegments.Add(current.gameObject.scene.name);
            reversedSegments.Reverse();
            segments = reversedSegments.ToArray();
            return string.Join(".", segments);
        }

        // Unity root sibling indices are version-sensitive, so use the scene's authoritative root array like Chroma does.
        private static int GetRootIndex(GameObject gameObject)
        {
            Scene scene = gameObject.scene;
            if (!RootObjectsBySceneHandle.TryGetValue(scene.handle, out GameObject[] rootObjects))
            {
                rootObjects = scene.GetRootGameObjects();
                RootObjectsBySceneHandle.Add(scene.handle, rootObjects);
            }

            return Array.IndexOf(rootObjects, gameObject);
        }

        // Common-prefix comparison skips null/non-component lights without shifting their runtime array indices.
        private static int FindCommonSegmentCount(List<RegisteredLightDump> lights)
        {
            string[]? common = null;
            int commonCount = 0;
            for (int lightIndex = 0; lightIndex < lights.Count; lightIndex++)
            {
                string[]? candidate = lights[lightIndex].PathSegments;
                if (candidate == null)
                {
                    continue;
                }

                if (common == null)
                {
                    common = candidate;
                    commonCount = candidate.Length;
                    continue;
                }

                commonCount = Math.Min(commonCount, candidate.Length);
                int segmentIndex = 0;
                while (segmentIndex < commonCount && string.Equals(common[segmentIndex], candidate[segmentIndex], StringComparison.Ordinal))
                {
                    segmentIndex++;
                }

                commonCount = segmentIndex;
            }

            return commonCount;
        }

        // The first component path supplies the already-validated shared prefix text.
        private static string? GetCommonGameObjectPath(List<RegisteredLightDump> lights, int commonSegmentCount)
        {
            if (commonSegmentCount == 0)
            {
                return null;
            }

            for (int i = 0; i < lights.Count; i++)
            {
                string[]? segments = lights[i].PathSegments;
                if (segments != null)
                {
                    return string.Join(".", segments, 0, commonSegmentCount);
                }
            }

            return null;
        }

        // Reflection avoids binding the capture to EnvironmentSceneSetupData field visibility across game versions.
        private static string GetEnvironmentName(EnvironmentSceneSetup environmentSceneSetup)
        {
            object? setupData = SceneSetupDataField?.GetValue(environmentSceneSetup);
            if (setupData == null)
            {
                return environmentSceneSetup.gameObject.scene.name;
            }

            // Beat Saber 1.44.2 stores the serialized environment name directly instead of retaining EnvironmentInfoSO.
            PropertyInfo? directNameProperty = AccessTools.Property(setupData.GetType(), "environmentSerializedName");
            FieldInfo? directNameField = FindField(setupData.GetType(), "environmentSerializedName")
                ?? FindField(setupData.GetType(), "_environmentSerializedName");
            string? directName = directNameProperty?.GetValue(setupData, null) as string
                ?? directNameField?.GetValue(setupData) as string;
            if (!string.IsNullOrEmpty(directName))
            {
                return directName!;
            }

            FieldInfo? environmentInfoField = AccessTools.Field(setupData.GetType(), "environmentInfo");
            object? environmentInfo = environmentInfoField?.GetValue(setupData);
            PropertyInfo? serializedNameProperty = environmentInfo != null
                ? AccessTools.Property(environmentInfo.GetType(), "serializedName")
                : null;
            FieldInfo? serializedNameField = environmentInfo != null
                ? AccessTools.Field(environmentInfo.GetType(), "serializedName")
                : null;
            string? serializedName = serializedNameProperty?.GetValue(environmentInfo, null) as string
                ?? serializedNameField?.GetValue(environmentInfo) as string;
            if (!string.IsNullOrEmpty(serializedName))
            {
                return serializedName!;
            }

            return environmentSceneSetup.gameObject.scene.name;
        }

        // Resolve once at the environment lifecycle boundary; the registration patch supplies a fallback manager if needed.
        private static LightWithIdManager? FindLightManager()
        {
            GameObject lightManagerObject = GameObject.Find("LightManager");
            if (lightManagerObject != null)
            {
                LightWithIdManager manager = lightManagerObject.GetComponent<LightWithIdManager>();
                if (manager != null)
                {
                    return manager;
                }
            }

            return null;
        }

        // Counting is restricted to populated slots and provides evidence about capture timing in the output.
        private static int CountRegisteredLights(List<ILightWithId>[] lightsById)
        {
            int count = 0;
            for (int i = 0; i < lightsById.Length; i++)
            {
                List<ILightWithId> lights = lightsById[i];
                if (lights != null)
                {
                    count += lights.Count;
                }
            }

            return count;
        }

        // Stable filenames make repeat captures directly comparable while rejecting filesystem-reserved characters.
        private static string SanitizeFileName(string value)
        {
            char[] invalidCharacters = Path.GetInvalidFileNameChars();
            var builder = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char character = value[i];
                builder.Append(Array.IndexOf(invalidCharacters, character) >= 0 ? '_' : character);
            }

            return builder.Length == 0 ? "Unknown" : builder.ToString();
        }

        // This immutable pair keeps the numeric Chroma component value adjacent to its BasicBeatmapEventType enum name.
        private sealed class LightEventTypeBinding
        {
            internal LightEventTypeBinding(int type, string? typeName)
            {
                Type = type;
                TypeName = typeName;
            }

            internal int Type { get; }

            internal string? TypeName { get; }
        }
    }
}

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Newtonsoft.Json.Serialization;
using UnityEngine;
using Object = UnityEngine.Object;

namespace LightIdDumper
{
    // This controller exists only for an explicit batch argument, leaving ordinary installed-mod behavior unchanged.
    internal sealed class DumpAllEnvironmentsController : MonoBehaviour
    {
        internal const string CommandLineArgument = "--dump-all-light-ids";
        internal const int DumpTimeoutSeconds = 90;
        private static DumpAllEnvironmentsController? _instance;
        private readonly DumpAllRunStatus _status = new();
        private LightDumpCompletion? _pendingCompletion;
        private string? _waitingForEnvironment;
        private string _statusPath = string.Empty;

        // Command-line detection is exact and opt-in because successful completion exits the game automatically.
        internal static void StartIfRequested()
        {
            bool requested = Environment.GetCommandLineArgs().Any(
                argument => string.Equals(argument, CommandLineArgument, StringComparison.OrdinalIgnoreCase));
            if (!requested || _instance != null)
            {
                return;
            }

            var controllerObject = new GameObject("LightIdDumper.DumpAllEnvironmentsController");
            DontDestroyOnLoad(controllerObject);
            _instance = controllerObject.AddComponent<DumpAllEnvironmentsController>();
        }

        // Awake starts the main-thread coroutine after the persistent object has a valid Unity lifetime.
        private void Awake()
        {
            _status.GameVersion = Application.version;
            _status.StartedAtUtc = DateTime.UtcNow;
            string outputDirectory = Path.Combine(
                Environment.CurrentDirectory,
                "UserData",
                "LightIdDumper",
                SanitizeFileName(Application.version));
            Directory.CreateDirectory(outputDirectory);
            _statusPath = Path.Combine(outputDirectory, "_dump-all-status.json");
            WriteStatus();
            LightDumpCapture.DumpCompleted += HandleDumpCompleted;
            StartCoroutine(Run());
        }

        // Removing the event subscription prevents a destroyed controller from observing later manual captures.
        private void OnDestroy()
        {
            LightDumpCapture.DumpCompleted -= HandleDumpCompleted;

            // A destroyed batch controller must not leave the donor environment substitution active during later ordinary gameplay.
            DumpAllEnvironmentSelection.Deactivate();
            if (_instance == this)
            {
                _instance = null;
            }
        }

        // Regression: EventsTest has no normal gameplay setup binding, so batch mode now runs ordinary custom levels and returns through the game's own controller after each capture.
        private IEnumerator Run()
        {
            yield return null;

            object? gameScenesManager = null;
            object? menuTransitionsHelper = null;
            float discoveryDeadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            while ((gameScenesManager == null || menuTransitionsHelper == null) && Time.realtimeSinceStartup < discoveryDeadline)
            {
                // Beat Saber 1.44.2 changed both managers from Unity components to injected plain objects reachable through MainFlowCoordinator.
                object? mainFlowCoordinator = FindLoadedSceneComponent(FindType("MainFlowCoordinator"));
                menuTransitionsHelper = FindLoadedSceneComponent(FindType("MenuTransitionsHelper")) ?? ReadMember(mainFlowCoordinator, "_menuTransitionsHelper");
                gameScenesManager = FindLoadedObject(FindType("GameScenesManager")) ?? ReadMember(menuTransitionsHelper, "_gameScenesManager") ?? ReadMember(mainFlowCoordinator, "_gameScenesManager");
                if (gameScenesManager == null || menuTransitionsHelper == null)
                {
                    yield return null;
                }
            }

            if (gameScenesManager == null || menuTransitionsHelper == null)
            {
                FinishWithFatalError("GameScenesManager or MenuTransitionsHelper was not available before the startup timeout.");
                yield break;
            }

            // Starting a standard level before AppCore reaches its settled menu state can race platform and custom-song initialization.
            Type? mainFlowCoordinatorType = FindType("MainFlowCoordinator");
            bool startupReady = false;
            float startupDeadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            Plugin.Log.Info("Dump-all mode waiting for normal game startup to reach the main menu.");
            while (!startupReady && Time.realtimeSinceStartup < startupDeadline)
            {
                object? mainFlowCoordinator = FindLoadedActiveSceneComponent(mainFlowCoordinatorType);
                bool isInTransition = ReadMember(gameScenesManager, "isInTransition") is bool transitionActive && transitionActive;
                startupReady = mainFlowCoordinator != null && !isInTransition;
                if (!startupReady)
                {
                    yield return null;
                }
            }

            if (!startupReady)
            {
                FinishWithFatalError("The normal main-menu startup transition did not finish before the startup timeout.");
                yield break;
            }

            Plugin.Log.Info("Dump-all mode detected completed main-menu startup; preparing one donor custom level for the complete environment catalog.");

            // The game catalog is authoritative; generated candidates no longer depend on users having one custom map per environment.
            List<EnvironmentCatalogEntry> environmentCatalog;
            try
            {
                environmentCatalog = GetStandardEnvironmentCatalog();
            }
            catch (Exception exception)
            {
                FinishWithFatalError($"Could not enumerate Beat Saber's standard environment catalog: {Unwrap(exception)}");
                yield break;
            }

            EnvironmentMapDonor? donor = null;
            string? donorDiscoveryError = null;

            // A stock-level fallback lets minimally modded game versions run after the outer script has independently proved that a non-Chroma custom map exists.
            object? donorMainFlowCoordinator = FindLoadedActiveSceneComponent(mainFlowCoordinatorType);
            yield return DiscoverDonorMap(environmentCatalog, donorMainFlowCoordinator, value => donor = value, error => donorDiscoveryError = error);
            if (donorDiscoveryError != null)
            {
                FinishWithFatalError(donorDiscoveryError);
                yield break;
            }

            if (donor == null)
            {
                FinishWithFatalError("SongCore supplied no usable non-Chroma/non-Vivify custom-map difficulty to use as the donor song.");
                yield break;
            }

            // One real donor difficulty supplies valid audio/beatmap loading while its native environment lookup is scoped to one stock catalog entry at a time.
            List<EnvironmentMapCandidate> candidates = environmentCatalog
                .Select(entry => new EnvironmentMapCandidate(
                    entry.EnvironmentName,
                    donor.MapDirectory,
                    donor.BeatmapLevel,
                    donor.DifficultyOrKey,
                    donor.IsLegacy,
                    entry.EnvironmentInfo))
                .ToList();
            _status.ExpectedEnvironmentNames = environmentCatalog.Select(entry => entry.EnvironmentName).ToList();
            WriteStatus();
            Plugin.Log.Info($"Dump-all mode generated [{candidates.Count}] environment launches from donor map [{donor.MapDirectory}] for Beat Saber [{Application.version}].");

            for (int environmentIndex = 0; environmentIndex < candidates.Count; environmentIndex++)
            {
                EnvironmentMapCandidate candidate = candidates[environmentIndex];
                _waitingForEnvironment = candidate.EnvironmentName;
                _pendingCompletion = null;

                try
                {
                    Plugin.Log.Info($"Dump-all mode loading [{candidate.EnvironmentName}] from [{candidate.MapDirectory}] ({environmentIndex + 1}/{candidates.Count}).");

                    // The active lookup makes this donor difficulty identify as the target without setting Beat Saber's override-environment flag or changing its scene setup path.
                    DumpAllEnvironmentSelection.Activate(candidate.EnvironmentName, candidate.TargetEnvironmentInfo);
                    StartStandardLevel(menuTransitionsHelper, candidate);
                }
                catch (Exception exception)
                {
                    // Failed setup cannot proceed to the normal return-to-menu cleanup boundary.
                    DumpAllEnvironmentSelection.Deactivate();
                    FinishWithFatalError($"Could not start standard level for [{candidate.EnvironmentName}]: {Unwrap(exception)}");
                    yield break;
                }

                float dumpDeadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
                while (_pendingCompletion == null && Time.realtimeSinceStartup < dumpDeadline)
                {
                    yield return null;
                }

                if (_pendingCompletion == null)
                {
                    FinishWithFatalError($"Timed out waiting for [{candidate.EnvironmentName}] to finish dumping after [{DumpTimeoutSeconds}] seconds.");
                    yield break;
                }

                LightDumpCompletion completion = _pendingCompletion;
                _status.Environments.Add(new DumpAllEnvironmentResult
                {
                    EnvironmentName = candidate.EnvironmentName,
                    Succeeded = completion.Succeeded,
                    BehaviorLightsOutputPath = completion.BehaviorLightsOutputPath,
                    OtherLightsOutputPath = completion.OtherLightsOutputPath,
                    BehaviorLightCount = completion.BehaviorLightCount,
                    OtherLightCount = completion.OtherLightCount,
                    Error = completion.Error,
                });
                WriteStatus();
                if (!completion.Succeeded)
                {
                    FinishWithFatalError($"Dump failed for [{candidate.EnvironmentName}]: {completion.Error}");
                    yield break;
                }

                string? returnError = null;
                yield return ReturnToMenuAndWait(gameScenesManager, error => returnError = error);
                if (returnError != null)
                {
                    FinishWithFatalError($"Could not return to the menu after [{candidate.EnvironmentName}]: {returnError}");
                    yield break;
                }

                // Deferred beatmap loading is complete once gameplay has returned, so the next candidate can safely install a different native environment identity.
                DumpAllEnvironmentSelection.Deactivate();
            }

            _status.Complete = true;
            _status.FinishedAtUtc = DateTime.UtcNow;
            WriteStatus();
            Plugin.Log.Info($"Dump-all mode completed [{_status.Environments.Count}] environments; exiting Beat Saber.");
            yield return null;
            Application.Quit();
        }

        // A completion belongs to the active standard level only when its serialized environment name is exact.
        private void HandleDumpCompleted(LightDumpCompletion completion)
        {
            if (string.Equals(completion.EnvironmentName, _waitingForEnvironment, StringComparison.Ordinal))
            {
                _pendingCompletion = completion;
                return;
            }

            Plugin.Log.Debug($"Dump-all mode ignored completion for [{completion.EnvironmentName}] while waiting for [{_waitingForEnvironment}].");
        }

        // Fatal batch errors are persisted before quitting so the outer script can fail with a precise reason.
        private void FinishWithFatalError(string error)
        {
            // Fatal exits can occur before the normal per-environment cleanup, so always remove the scoped lookup before requesting process shutdown.
            DumpAllEnvironmentSelection.Deactivate();
            _status.Complete = false;
            _status.FatalError = error;
            _status.FinishedAtUtc = DateTime.UtcNow;
            WriteStatus();
            Plugin.Log.Error($"Dump-all mode failed: {error}");
            Application.Quit();
        }

        // SongCore is read reflectively so normal one-environment dumping keeps BSIPA as its only hard dependency.
        private IEnumerator DiscoverDonorMap(List<EnvironmentCatalogEntry> environmentCatalog, object? mainFlowCoordinator, Action<EnvironmentMapDonor> reportDonor, Action<string> reportError)
        {
            Type? loaderType = FindType("SongCore.Loader");
            if (loaderType == null)
            {
                // Beat Saber 1.44.2 can be installed with BSIPA alone; its built-in OST repository supplies the same valid standard-level launch objects without adding a runtime SongCore dependency.
                EnvironmentMapDonor? builtInDonor = CreateBuiltInDonor(environmentCatalog, mainFlowCoordinator);
                if (builtInDonor == null)
                {
                    reportError("SongCore.Loader is unavailable and no playable built-in OST difficulty could be resolved as a fallback donor.");
                    yield break;
                }

                Plugin.Log.Warn($"Dump-all mode could not find SongCore; using built-in donor [{builtInDonor.MapDirectory}] after the runner validated the required non-Chroma custom-map input.");
                reportDonor(builtInDonor);
                yield break;
            }

            float songsDeadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            while (!(ReadStaticMember(loaderType, "AreSongsLoaded") is bool songsLoaded && songsLoaded) && Time.realtimeSinceStartup < songsDeadline)
            {
                yield return null;
            }

            if (!(ReadStaticMember(loaderType, "AreSongsLoaded") is bool loaded && loaded))
            {
                reportError($"SongCore did not finish loading custom maps within [{DumpTimeoutSeconds}] seconds.");
                yield break;
            }

            if (!(ReadStaticMember(loaderType, "CustomLevels") is IEnumerable customLevels))
            {
                reportError("SongCore.Loader.CustomLevels is unavailable or not enumerable.");
                yield break;
            }

            var entries = new List<object>();
            foreach (object entry in customLevels)
            {
                entries.Add(entry);
            }

            // ConcurrentDictionary enumeration order is unstable, so directory ordering makes the selected map for each environment reproducible.
            entries.Sort((left, right) => string.Compare(
                ReadMember(left, "Key") as string,
                ReadMember(right, "Key") as string,
                StringComparison.OrdinalIgnoreCase));

            // Legacy SongCore can set AreSongsLoaded before BeatmapLevelsModel has synchronized its preview-ID cache, so retain its injected loader for direct preview loading.
            object? beatmapLevelsModel = ReadStaticMember(loaderType, "BeatmapLevelsModelSO") ?? FindLoadedObject(FindType("BeatmapLevelsModel"));
            object? customLevelLoader = ReadMember(beatmapLevelsModel, "_customLevelLoader") ?? FindLoadedObject(FindType("CustomLevelLoader"));
            for (int entryIndex = 0; entryIndex < entries.Count; entryIndex++)
            {
                object entry = entries[entryIndex];
                string? mapDirectory = ReadMember(entry, "Key") as string;
                object? previewOrLevel = ReadMember(entry, "Value");
                if (string.IsNullOrWhiteSpace(mapDirectory) || previewOrLevel == null)
                {
                    continue;
                }

                // A modded donor could replace the environment before capture; skip it and choose the next deterministic map directory.
                if (IsChromaOrVivifyMap(mapDirectory!))
                {
                    Plugin.Log.Info($"Dump-all mode skipped Chroma/Vivify donor candidate [{mapDirectory}].");
                    continue;
                }

                MethodInfo? getKeysMethod = previewOrLevel.GetType().GetMethod("GetBeatmapKeys", BindingFlags.Public | BindingFlags.Instance, null, Type.EmptyTypes, null);
                if (getKeysMethod != null)
                {
                    EnvironmentMapDonor? modernDonor = CreateModernDonor(environmentCatalog, mapDirectory!, previewOrLevel, getKeysMethod);
                    if (modernDonor != null)
                    {
                        reportDonor(modernDonor);
                        yield break;
                    }

                    continue;
                }

                // The direct custom-level loader consumes SongCore's preview object without depending on BeatmapLevelsModel's asynchronously refreshed ID dictionary.
                if (customLevelLoader == null)
                {
                    reportError("CustomLevelLoader is unavailable for loading legacy SongCore preview levels.");
                    yield break;
                }

                object? loadedLevel = null;
                string? loadError = null;
                yield return LoadLegacyBeatmapLevel(customLevelLoader, previewOrLevel, level => loadedLevel = level, error => loadError = error);
                if (loadError != null)
                {
                    Plugin.Log.Warn($"Dump-all mode skipped custom map [{mapDirectory}] because its legacy level data failed to load: {loadError}");
                    continue;
                }

                if (loadedLevel != null)
                {
                    EnvironmentMapDonor? legacyDonor = CreateLegacyDonor(environmentCatalog, mapDirectory!, loadedLevel);
                    if (legacyDonor != null)
                    {
                        reportDonor(legacyDonor);
                        yield break;
                    }
                }
            }

            reportError("No non-Chroma/non-Vivify SongCore custom map contained a playable difficulty whose source environment exists in the current game catalog.");
        }

        // Minimally modded installs still expose owned OST levels through MainFlowCoordinator's injected BeatmapLevelsModel, which avoids copying foreign SongCore binaries between game versions.
        private EnvironmentMapDonor? CreateBuiltInDonor(List<EnvironmentCatalogEntry> environmentCatalog, object? mainFlowCoordinator)
        {
            object? beatmapLevelsModel = ReadMember(mainFlowCoordinator, "_beatmapLevelsModel") ??
                ReadMember(FindLoadedSceneComponent(FindType("SoloFreePlayFlowCoordinator")), "_beatmapLevelsModel");
            object? repository = ReadMember(beatmapLevelsModel, "ostAndExtrasBeatmapLevelsRepository");
            if (!(ReadMember(repository, "beatmapLevelPacks", "_beatmapLevelPacks") is IEnumerable packs))
            {
                return null;
            }

            foreach (object pack in packs)
            {
                MethodInfo? allLevelsMethod = pack.GetType().GetMethod("AllBeatmapLevels", BindingFlags.Public | BindingFlags.Instance, null, Type.EmptyTypes, null);
                if (!(allLevelsMethod?.Invoke(pack, null) is IEnumerable levels))
                {
                    continue;
                }

                foreach (object level in levels)
                {
                    MethodInfo? getKeysMethod = level.GetType().GetMethod("GetBeatmapKeys", BindingFlags.Public | BindingFlags.Instance, null, Type.EmptyTypes, null);
                    if (getKeysMethod == null)
                    {
                        continue;
                    }

                    string levelId = GetStringMember(level, "levelID", "_levelID") ?? "unknown";
                    EnvironmentMapDonor? donor = CreateModernDonor(environmentCatalog, $"built-in:{levelId}", level, getKeysMethod);
                    if (donor != null)
                    {
                        return donor;
                    }
                }
            }

            return null;
        }

        // Chroma/Vivify requirements or suggestions are rejected so automated captures always enter an unmodified stock environment with a vanilla lightshow path.
        private bool IsChromaOrVivifyMap(string mapDirectory)
        {
            try
            {
                string? infoPath = Directory.EnumerateFiles(mapDirectory)
                    .FirstOrDefault(path => string.Equals(Path.GetFileName(path), "Info.dat", StringComparison.OrdinalIgnoreCase));
                if (infoPath == null)
                {
                    return true;
                }

                // Restrict matching to the standard declaration arrays so a song title or author containing "Chroma" is not a false positive.
                JObject info = JObject.Parse(File.ReadAllText(infoPath));
                return info.DescendantsAndSelf()
                    .OfType<JProperty>()
                    .Where(property =>
                        string.Equals(property.Name.TrimStart('_'), "requirements", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(property.Name.TrimStart('_'), "suggestions", StringComparison.OrdinalIgnoreCase))
                    .SelectMany<JProperty, JToken>(property => property.Value.Type == JTokenType.Array ? property.Value.Children<JToken>() : new JToken[] { property.Value })
                    .Any(requirement =>
                        string.Equals((string?)requirement, "Chroma", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals((string?)requirement, "Vivify", StringComparison.OrdinalIgnoreCase));
            }
            catch (Exception exception)
            {
                Plugin.Log.Warn($"Dump-all mode skipped unreadable custom map [{mapDirectory}]: {exception.Message}");
                return true;
            }
        }

        // Modern SongCore levels expose exact BeatmapKeys and environment selection without loading beatmap data first.
        private EnvironmentMapDonor? CreateModernDonor(List<EnvironmentCatalogEntry> environmentCatalog, string mapDirectory, object beatmapLevel, MethodInfo getKeysMethod)
        {
            if (!(getKeysMethod.Invoke(beatmapLevel, null) is IEnumerable beatmapKeys))
            {
                return null;
            }

            MethodInfo? getEnvironmentNameMethod = beatmapLevel.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance)
                .FirstOrDefault(method => method.Name == "GetEnvironmentName" && method.GetParameters().Length == 2);
            if (getEnvironmentNameMethod == null)
            {
                return null;
            }

            foreach (object beatmapKey in beatmapKeys)
            {
                object? characteristic = ReadMember(beatmapKey, "beatmapCharacteristic", "characteristic");
                object? difficulty = ReadMember(beatmapKey, "difficulty");
                if (characteristic == null || difficulty == null)
                {
                    continue;
                }

                object? environmentNameValue = getEnvironmentNameMethod.Invoke(beatmapLevel, new[] { characteristic, difficulty });
                string? environmentName = GetSerializedName(environmentNameValue);
                EnvironmentCatalogEntry? sourceEnvironment = environmentCatalog.FirstOrDefault(entry => string.Equals(entry.EnvironmentName, environmentName, StringComparison.Ordinal));
                if (sourceEnvironment != null)
                {
                    return new EnvironmentMapDonor(mapDirectory, beatmapLevel, beatmapKey, false, sourceEnvironment.EnvironmentInfo);
                }
            }

            return null;
        }

        // Legacy SongCore exposes a valid CustomPreviewBeatmapLevel before BeatmapLevelsModel's ID cache is necessarily refreshed, so load that preview directly.
        private IEnumerator LoadLegacyBeatmapLevel(object customLevelLoader, object previewLevel, Action<object> reportLevel, Action<string> reportError)
        {
            string? levelId = GetStringMember(previewLevel, "levelID", "levelId");
            MethodInfo? loadMethod = customLevelLoader.GetType().GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .FirstOrDefault(method =>
                {
                    ParameterInfo[] parameters = method.GetParameters();
                    return method.Name == "LoadCustomBeatmapLevelAsync" &&
                        parameters.Length == 2 &&
                        parameters[0].ParameterType.IsInstanceOfType(previewLevel) &&
                        parameters[1].ParameterType == typeof(CancellationToken);
                });
            if (string.IsNullOrWhiteSpace(levelId) || loadMethod == null)
            {
                reportError("LoadCustomBeatmapLevelAsync or the custom level ID is unavailable.");
                yield break;
            }

            Task? task;
            try
            {
                // This diagnostic remains until old-version runtime verification confirms the cache-independent path receives the generated preview.
                Plugin.Log.Info($"Dump-all mode directly loading legacy donor [{levelId}] through [{customLevelLoader.GetType().FullName}.{loadMethod.Name}].");
                task = loadMethod.Invoke(customLevelLoader, new object[] { previewLevel, CancellationToken.None }) as Task;
            }
            catch (Exception exception)
            {
                reportError(Unwrap(exception).ToString());
                yield break;
            }

            if (task == null)
            {
                reportError("LoadCustomBeatmapLevelAsync did not return a Task.");
                yield break;
            }

            float deadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            while (!task.IsCompleted && Time.realtimeSinceStartup < deadline)
            {
                yield return null;
            }

            if (!task.IsCompleted)
            {
                reportError($"LoadCustomBeatmapLevelAsync timed out after [{DumpTimeoutSeconds}] seconds.");
                yield break;
            }

            if (task.IsFaulted)
            {
                reportError(task.Exception?.GetBaseException().ToString() ?? "LoadCustomBeatmapLevelAsync faulted.");
                yield break;
            }

            object? beatmapLevel = ReadMember(task, "Result");
            if (beatmapLevel == null)
            {
                reportError("LoadCustomBeatmapLevelAsync returned no beatmap level.");
                yield break;
            }

            // CustomLevelLoader can return a wrapper after beatmap-data or audio parsing fails, so reject it with a precise diagnostic before environment selection.
            if (ReadMember(beatmapLevel, "beatmapLevelData") == null)
            {
                reportError("LoadCustomBeatmapLevelAsync returned a level with no beatmapLevelData.");
                yield break;
            }

            reportLevel(beatmapLevel);
        }

        // Legacy environment selection mirrors BeatmapEnvironmentHelper, including 1.34's per-difficulty environmentNameIdx.
        private EnvironmentMapDonor? CreateLegacyDonor(List<EnvironmentCatalogEntry> environmentCatalog, string mapDirectory, object beatmapLevel)
        {
            // CustomBeatmapLevel exposes loaded difficulty sets through IBeatmapLevelData, not on the level wrapper as BeatmapLevelSO does.
            object? beatmapLevelData = ReadMember(beatmapLevel, "beatmapLevelData");
            if (!(ReadMember(beatmapLevelData, "difficultyBeatmapSets") is IEnumerable difficultySets))
            {
                Plugin.Log.Warn($"Dump-all mode rejected loaded legacy donor [{mapDirectory}] because [{beatmapLevelData?.GetType().FullName ?? "null"}] exposed no difficultyBeatmapSets.");
                return null;
            }

            foreach (object difficultySet in difficultySets)
            {
                if (!(ReadMember(difficultySet, "difficultyBeatmaps") is IEnumerable difficultyBeatmaps))
                {
                    continue;
                }

                foreach (object difficultyBeatmap in difficultyBeatmaps)
                {
                    object? environmentInfo = GetLegacyEnvironmentInfo(beatmapLevel, difficultySet, difficultyBeatmap);
                    string? environmentName = GetStringMember(environmentInfo, "serializedName", "_serializedName");
                    EnvironmentCatalogEntry? sourceEnvironment = environmentCatalog.FirstOrDefault(entry => string.Equals(entry.EnvironmentName, environmentName, StringComparison.Ordinal));
                    if (sourceEnvironment != null)
                    {
                        // Keep the resolved legacy object path visible until 1.29/1.34 complete an end-to-end dump-all run.
                        Plugin.Log.Info($"Dump-all mode selected legacy donor [{mapDirectory}] with source environment [{environmentName}] and difficulty [{difficultyBeatmap.GetType().FullName}].");
                        return new EnvironmentMapDonor(mapDirectory, beatmapLevel, difficultyBeatmap, true, sourceEnvironment.EnvironmentInfo);
                    }
                }
            }

            return null;
        }

        // Beat Saber 1.34 uses an indexed environment array; 1.29 falls back to normal versus rotational environment assets.
        private object? GetLegacyEnvironmentInfo(object beatmapLevel, object difficultySet, object difficultyBeatmap)
        {
            object? environmentNameIndexValue = ReadMember(difficultyBeatmap, "environmentNameIdx");
            object? environmentInfosValue = ReadMember(beatmapLevel, "environmentInfos");
            if (environmentNameIndexValue != null && environmentInfosValue is IList environmentInfos)
            {
                int environmentNameIndex = Convert.ToInt32(environmentNameIndexValue);
                if (environmentNameIndex >= 0 && environmentNameIndex < environmentInfos.Count)
                {
                    return environmentInfos[environmentNameIndex];
                }
            }

            object? characteristic = ReadMember(difficultySet, "beatmapCharacteristic");
            bool containsRotationEvents = ReadMember(characteristic, "containsRotationEvents") is bool rotational && rotational;
            return containsRotationEvents
                ? ReadMember(beatmapLevel, "allDirectionsEnvironmentInfo")
                : ReadMember(beatmapLevel, "environmentInfo");
        }

        // MenuTransitionsHelper builds the same gameplay setup used by the Solo play button, including every version-specific dependency.
        private void StartStandardLevel(object menuTransitionsHelper, EnvironmentMapCandidate candidate)
        {
            MethodInfo? method = menuTransitionsHelper.GetType().GetMethods(BindingFlags.Public | BindingFlags.Instance)
                .Where(item => item.Name == "StartStandardLevel")
                .Where(item => item.GetParameters().Any(parameter => parameter.Name == (candidate.IsLegacy ? "difficultyBeatmap" : "beatmapKey")))
                .Where(item => !item.GetParameters().Any(parameter => GetParameterType(parameter).Name == "IBeatmapLevelData" && !parameter.HasDefaultValue))
                .OrderByDescending(item => item.GetParameters().Length)
                .FirstOrDefault();
            if (method == null)
            {
                throw new MissingMethodException(menuTransitionsHelper.GetType().FullName, "StartStandardLevel");
            }

            // The menu setup can be absent in automated startup, and simple-name lookup can select PlayerSaveData's nested settings DTO instead of the runtime method parameter type.
            object? gameplaySetup = FindLoadedSceneComponent(FindType("GameplaySetupViewController"));
            object? gameplayModifiers = ReadMember(gameplaySetup, "gameplayModifiers");
            object? playerSpecificSettings = ReadMember(gameplaySetup, "playerSettings");
            object? environmentsListModel = ReadMember(FindLoadedSceneComponent(FindType("SoloFreePlayFlowCoordinator")), "_environmentsListModel") ?? CreateEnvironmentsListModel();

            ParameterInfo[] parameters = method.GetParameters();
            var arguments = new object?[parameters.Length];
            for (int i = 0; i < parameters.Length; i++)
            {
                string parameterName = parameters[i].Name ?? string.Empty;
                Type parameterType = GetParameterType(parameters[i]);
                if (parameterName == "gameMode")
                {
                    arguments[i] = "LightIdDumper";
                }
                else if (parameterName == "difficultyBeatmap" || parameterName == "beatmapKey")
                {
                    arguments[i] = candidate.DifficultyOrKey;
                }
                else if (parameterName == "previewBeatmapLevel" || parameterName == "beatmapLevel")
                {
                    arguments[i] = candidate.BeatmapLevel;
                }
                else if (parameterType.Name == "GameplayModifiers")
                {
                    // The selected overload's declared type is authoritative and prevents similarly named serialized save-data types from reaching MethodInfo.Invoke.
                    arguments[i] = GetCompatibleObjectOrDefault(gameplayModifiers, parameterType);
                }
                else if (parameterType.Name == "PlayerSpecificSettings")
                {
                    // Player settings also have versioned serialized representations, so validate the menu value against the exact runtime parameter type.
                    arguments[i] = GetCompatibleObjectOrDefault(playerSpecificSettings, parameterType);
                }
                else if (parameterType.Name == "OverrideEnvironmentSettings")
                {
                    // Null preserves Beat Saber's native usingOverrideEnvironment=false initialization path while the scoped difficulty lookup supplies the target environment.
                    arguments[i] = null;
                }
                else if (parameterType.Name == "EnvironmentsListModel")
                {
                    arguments[i] = environmentsListModel;
                }
                else if (parameterType.Name == "GameplayAdditionalInformation")
                {
                    arguments[i] = CreateGameplayAdditionalInformation(parameterType);
                }
                else if (parameterName == "backButtonText")
                {
                    arguments[i] = "Light ID Dumper";
                }
                else if (parameterType == typeof(bool))
                {
                    arguments[i] = false;
                }
                else if (parameters[i].HasDefaultValue)
                {
                    arguments[i] = parameters[i].DefaultValue;
                }
                else
                {
                    arguments[i] = null;
                }
            }

            // Keep the resolved runtime types and native-selection invariant visible until an end-to-end dump confirms the automated level-start path across supported versions.
            Plugin.Log.Info($"Dump-all mode invoking [{method}] with native environment [{candidate.EnvironmentName}], OverrideEnvironmentSettings [null], and argument types [{string.Join(", ", arguments.Select(argument => argument?.GetType().FullName ?? "null"))}].");
            method.Invoke(menuTransitionsHelper, arguments);
        }

        // The game-owned return controller supplies valid quit results and pops all standard gameplay scenes as one transition.
        private IEnumerator ReturnToMenuAndWait(object gameScenesManager, Action<string> reportError)
        {
            yield return null;

            // Unity 6000 can register and dump lights before PushScenes finishes shader warmup; wait for that transition so ReturnToMenu does not race and strand the gameplay scenes.
            float pushDeadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            while (ReadMember(gameScenesManager, "isInTransition") is bool pushTransitionActive && pushTransitionActive && Time.realtimeSinceStartup < pushDeadline)
            {
                yield return null;
            }

            if (ReadMember(gameScenesManager, "isInTransition") is bool unfinishedPushTransition && unfinishedPushTransition)
            {
                reportError($"The gameplay scene-push transition did not finish within [{DumpTimeoutSeconds}] seconds.");
                yield break;
            }

            Type? returnControllerType = FindType("StandardLevelReturnToMenuController");
            object? returnController = FindLoadedSceneComponent(returnControllerType);
            if (returnController == null)
            {
                reportError("StandardLevelReturnToMenuController was not present after the environment dump.");
                yield break;
            }

            try
            {
                MethodInfo? returnMethod = returnController.GetType().GetMethod("ReturnToMenu", BindingFlags.Public | BindingFlags.Instance);
                if (returnMethod == null)
                {
                    throw new MissingMethodException(returnController.GetType().FullName, "ReturnToMenu");
                }

                returnMethod.Invoke(returnController, null);
                Plugin.Log.Info($"Dump-all mode returning to menu after [{_waitingForEnvironment}].");
            }
            catch (Exception exception)
            {
                // A later didFinishEvent subscriber can throw after MenuTransitionsHelper has already started PopScenes; the active transition proves the requested return is still progressing.
                Exception returnException = Unwrap(exception);
                bool returnTransitionStarted = ReadMember(gameScenesManager, "isInTransition") is bool transitionActive && transitionActive;
                if (!returnTransitionStarted)
                {
                    reportError(returnException.ToString());
                    yield break;
                }

                // Keep this diagnostic until repeated multi-environment runs confirm subscriber failures no longer abort an otherwise valid scene pop.
                Plugin.Log.Warn($"Dump-all mode return subscriber threw after the scene-pop transition started for [{_waitingForEnvironment}]; continuing to wait for the menu: {returnException}");
            }

            float deadline = Time.realtimeSinceStartup + DumpTimeoutSeconds;
            while (Time.realtimeSinceStartup < deadline)
            {
                bool isInTransition = ReadMember(gameScenesManager, "isInTransition") is bool transitionActive && transitionActive;
                bool gameplayStillLoaded = FindLoadedSceneComponent(returnControllerType) != null;
                bool mainMenuReady = FindLoadedActiveSceneComponent(FindType("MainFlowCoordinator")) != null;
                if (!isInTransition && !gameplayStillLoaded && mainMenuReady)
                {
                    yield break;
                }

                yield return null;
            }

            reportError($"The normal return-to-menu transition did not finish within [{DumpTimeoutSeconds}] seconds.");
        }

        // Later versions construct their environment model from addressables; older StartStandardLevel signatures do not request it.
        private object? CreateEnvironmentsListModel()
        {
            Type? modelType = FindType("EnvironmentsListModel");
            MethodInfo? createMethod = modelType?.GetMethod("CreateFromAddressables", BindingFlags.Public | BindingFlags.Static);
            return createMethod?.Invoke(null, null);
        }

        // Beat Saber changed the catalog from EnvironmentsListSO to an injected EnvironmentsListModel, so reflection reads the common environmentInfos contract from either generation.
        private List<EnvironmentCatalogEntry> GetStandardEnvironmentCatalog()
        {
            object? mainFlowCoordinator = FindLoadedSceneComponent(FindType("MainFlowCoordinator"));
            object? soloFlowCoordinator = FindLoadedSceneComponent(FindType("SoloFreePlayFlowCoordinator"));
            object? catalog = ReadMember(mainFlowCoordinator, "_environmentsListModel", "_environmentListModel") ??
                ReadMember(soloFlowCoordinator, "_environmentsListModel", "_environmentListModel") ??
                FindLoadedObject(FindType("EnvironmentsListSO")) ??
                CreateEnvironmentsListModel();
            if (!(ReadMember(catalog, "environmentInfos", "_environmentInfos") is IEnumerable environmentInfos))
            {
                throw new InvalidOperationException("No environmentInfos collection was available from EnvironmentsListModel or EnvironmentsListSO.");
            }

            var entries = new Dictionary<string, EnvironmentCatalogEntry>(StringComparer.Ordinal);
            foreach (object environmentInfo in environmentInfos)
            {
                string? serializedName = GetStringMember(environmentInfo, "serializedName", "_serializedName");
                object? environmentType = ReadMember(environmentInfo, "environmentType", "_environmentType");
                string? environmentTypeName = GetStringMember(environmentType, "typeNameLocalizationKey", "_typeNameLocalizationKey") ?? environmentType?.ToString();

                // Entries without a serialized map identity cannot be covered, while special scene types are intentionally outside this batch.
                if (serializedName == null || string.IsNullOrWhiteSpace(serializedName) || IsExcludedEnvironment(serializedName, environmentTypeName))
                {
                    continue;
                }

                entries[serializedName] = new EnvironmentCatalogEntry(serializedName, environmentInfo);
            }

            if (entries.Count == 0)
            {
                throw new InvalidOperationException("The environment catalog contained no standard or circle environments.");
            }

            return entries.Values.OrderBy(entry => entry.EnvironmentName, StringComparer.Ordinal).ToList();
        }

        // Tutorial and Multiplayer are game modes rather than ordinary custom-map targets and are the only catalog exclusions requested for coverage.
        private bool IsExcludedEnvironment(string serializedName, string? environmentTypeName)
        {
            // Older assets expose localized type keys and newer builds expose enum names, so both are matched case-insensitively.
            bool isExcludedType = environmentTypeName != null &&
                (environmentTypeName.IndexOf("Tutorial", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    environmentTypeName.IndexOf("Multiplayer", StringComparison.OrdinalIgnoreCase) >= 0);
            return serializedName.IndexOf("Tutorial", StringComparison.OrdinalIgnoreCase) >= 0 ||
                serializedName.IndexOf("Multiplayer", StringComparison.OrdinalIgnoreCase) >= 0 ||
                isExcludedType;
        }

        // GameplayAdditionalInformation gained constructor parameters over time, so safe defaults and a diagnostic label are supplied reflectively.
        private object CreateGameplayAdditionalInformation(Type type)
        {
            ConstructorInfo? constructor = type.GetConstructors(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .OrderBy(candidate => candidate.GetParameters().Length)
                .FirstOrDefault();
            if (constructor == null)
            {
                return Activator.CreateInstance(type, true) ?? throw new MissingMethodException(type.FullName, ".ctor");
            }

            ParameterInfo[] parameters = constructor.GetParameters();
            var arguments = new object?[parameters.Length];
            for (int i = 0; i < parameters.Length; i++)
            {
                arguments[i] = parameters[i].ParameterType == typeof(string)
                    ? "Light ID Dumper"
                    : GetDefaultValue(parameters[i]);
            }

            return constructor.Invoke(arguments);
        }

        // Default gameplay objects are used only if the loaded menu UI does not expose its already-initialized settings.
        private object? CreateDefaultObject(Type? type)
        {
            if (type == null)
            {
                return null;
            }

            object? namedDefault = ReadStaticMember(type, "noModifiers", "NoModifiers", "defaultSettings", "DefaultSettings");
            return namedDefault ?? Activator.CreateInstance(type, true);
        }

        // A loaded menu value is reusable only when it matches the selected overload; otherwise construct the exact declared runtime type.
        private object? GetCompatibleObjectOrDefault(object? value, Type requiredType)
        {
            if (value != null && requiredType.IsInstanceOfType(value))
            {
                return value;
            }

            if (value != null)
            {
                Plugin.Log.Warn($"Dump-all mode ignored incompatible [{value.GetType().FullName}] while preparing [{requiredType.FullName}].");
            }

            return CreateDefaultObject(requiredType);
        }

        // Optional and value-type constructor parameters need their declared default rather than an invalid null reflection argument.
        private object? GetDefaultValue(ParameterInfo parameter)
        {
            if (parameter.HasDefaultValue)
            {
                return parameter.DefaultValue;
            }

            return parameter.ParameterType.IsValueType
                ? Activator.CreateInstance(parameter.ParameterType)
                : null;
        }

        // By-ref BeatmapKey parameters expose BeatmapKey& through reflection, so matching uses the element type.
        private Type GetParameterType(ParameterInfo parameter)
        {
            return parameter.ParameterType.IsByRef
                ? parameter.ParameterType.GetElementType() ?? parameter.ParameterType
                : parameter.ParameterType;
        }

        // EnvironmentName changed from a plain string to a value object; serializedName remains its stable external identity.
        private string? GetSerializedName(object? value)
        {
            if (value is string text)
            {
                return text;
            }

            return value == null
                ? null
                : GetStringMember(value, "serializedName", "_serializedName", "value", "_value") ?? value.ToString();
        }

        // Type lookup by full or simple name tolerates Beat Saber's assembly and namespace reorganizations.
        private Type? FindType(string typeName)
        {
            foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                Type? exact = assembly.GetType(typeName, false);
                if (exact != null)
                {
                    return exact;
                }

                try
                {
                    Type? match = assembly.GetTypes().FirstOrDefault(type => type.Name == typeName);
                    if (match != null)
                    {
                        return match;
                    }
                }
                catch (ReflectionTypeLoadException exception)
                {
                    Type? match = exception.Types.FirstOrDefault(type => type != null && type.Name == typeName);
                    if (match != null)
                    {
                        return match;
                    }
                }
            }

            return null;
        }

        // Unity's loaded-object inventory finds persistent managers without relying on scene hierarchy names.
        private object? FindLoadedObject(Type? type)
        {
            // Beat Saber 1.44.2 makes some injected managers plain objects, and Unity 6000 returns null instead of an empty array when a non-Unity type is searched.
            if (type == null || !typeof(Object).IsAssignableFrom(type))
            {
                return null;
            }

            Object[] objects = Resources.FindObjectsOfTypeAll(type);
            return objects.FirstOrDefault(item => item != null);
        }

        // Inactive menu components are valid dependencies, but prefab assets and unloaded-scene remnants are not.
        private object? FindLoadedSceneComponent(Type? type)
        {
            // Beat Saber 1.44.2 makes MenuTransitionsHelper a plain object, so reject it before Unity's component search and allow the caller's injected-field fallback.
            if (type == null || !typeof(Component).IsAssignableFrom(type))
            {
                return null;
            }

            Object[] objects = Resources.FindObjectsOfTypeAll(type);
            return objects.FirstOrDefault(item =>
                item is Component component &&
                component != null &&
                component.gameObject.scene.IsValid() &&
                component.gameObject.scene.isLoaded);
        }

        // Startup and return readiness require an active component in a genuinely loaded scene.
        private object? FindLoadedActiveSceneComponent(Type? type)
        {
            // Cross-version reflective candidates are not guaranteed to remain components, so only pass valid component types into Unity's object inventory.
            if (type == null || !typeof(Component).IsAssignableFrom(type))
            {
                return null;
            }

            Object[] objects = Resources.FindObjectsOfTypeAll(type);
            return objects.FirstOrDefault(item =>
                item is Component component &&
                component != null &&
                component.gameObject.scene.IsValid() &&
                component.gameObject.scene.isLoaded &&
                component.gameObject.activeInHierarchy);
        }

        // Quiet static-member lookup reads SongCore's cross-version public fields and properties without hard linking it.
        private object? ReadStaticMember(Type type, params string[] names)
        {
            for (int i = 0; i < names.Length; i++)
            {
                PropertyInfo? property = FindProperty(type, names[i], true);
                if (property != null)
                {
                    return property.GetValue(null, null);
                }

                FieldInfo? field = FindField(type, names[i], true);
                if (field != null)
                {
                    return field.GetValue(null);
                }
            }

            return null;
        }

        // Direct reflection avoids Harmony warnings for every absent cross-version fallback candidate.
        private object? ReadMember(object? instance, params string[] names)
        {
            if (instance == null)
            {
                return null;
            }

            for (int i = 0; i < names.Length; i++)
            {
                PropertyInfo? property = FindProperty(instance.GetType(), names[i], false);
                if (property != null)
                {
                    return property.GetValue(instance, null);
                }

                FieldInfo? field = FindField(instance.GetType(), names[i], false);
                if (field != null)
                {
                    return field.GetValue(instance);
                }
            }

            return null;
        }

        // Environment and level IDs share the same cross-version string-member resolver.
        private string? GetStringMember(object? instance, params string[] names)
        {
            return ReadMember(instance, names) as string;
        }

        // Cross-version properties can move to a base type, so lookup explicitly walks inheritance.
        private PropertyInfo? FindProperty(Type type, string name, bool isStatic)
        {
            Type? current = type;
            BindingFlags scope = isStatic ? BindingFlags.Static : BindingFlags.Instance;
            while (current != null)
            {
                PropertyInfo? property = current.GetProperty(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly | scope);
                if (property != null)
                {
                    return property;
                }

                current = current.BaseType;
            }

            return null;
        }

        // Base-private fields and SongCore static fields require the same explicit inheritance walk.
        private FieldInfo? FindField(Type type, string name, bool isStatic)
        {
            Type? current = type;
            BindingFlags scope = isStatic ? BindingFlags.Static : BindingFlags.Instance;
            while (current != null)
            {
                FieldInfo? field = current.GetField(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly | scope);
                if (field != null)
                {
                    return field;
                }

                current = current.BaseType;
            }

            return null;
        }

        // Reflection invocation errors are unwrapped so the status manifest contains the actionable game exception.
        private Exception Unwrap(Exception exception)
        {
            return exception is TargetInvocationException invocationException && invocationException.InnerException != null
                ? invocationException.InnerException
                : exception;
        }

        // Status rewrites are small and complete before process exit, making them safe for the waiting PowerShell runner.
        private void WriteStatus()
        {
            string json = JsonConvert.SerializeObject(
                _status,
                Formatting.Indented,
                new JsonSerializerSettings
                {
                    ContractResolver = new CamelCasePropertyNamesContractResolver(),
                    NullValueHandling = NullValueHandling.Include,
                });
            File.WriteAllText(_statusPath, json, new UTF8Encoding(false));
        }

        // Application versions can contain filesystem-reserved build separators on some Beat Saber distributions.
        private string SanitizeFileName(string value)
        {
            char[] invalidCharacters = Path.GetInvalidFileNameChars();
            var builder = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char character = value[i];
                builder.Append(Array.IndexOf(invalidCharacters, character) >= 0 ? '_' : character);
            }

            return builder.Length == 0
                ? "Unknown"
                : builder.ToString();
        }

        // One donor difficulty supplies valid song and beatmap objects while its original environment type keys every generated override.
        private sealed class EnvironmentMapDonor
        {
            internal EnvironmentMapDonor(string mapDirectory, object beatmapLevel, object difficultyOrKey, bool isLegacy, object sourceEnvironmentInfo)
            {
                MapDirectory = mapDirectory;
                BeatmapLevel = beatmapLevel;
                DifficultyOrKey = difficultyOrKey;
                IsLegacy = isLegacy;
                SourceEnvironmentInfo = sourceEnvironmentInfo;
            }

            internal string MapDirectory { get; }

            internal object BeatmapLevel { get; }

            internal object DifficultyOrKey { get; }

            internal bool IsLegacy { get; }

            internal object SourceEnvironmentInfo { get; }
        }

        // Catalog entries retain the real EnvironmentInfoSO needed by OverrideEnvironmentSettings rather than reconstructing serialized assets.
        private sealed class EnvironmentCatalogEntry
        {
            internal EnvironmentCatalogEntry(string environmentName, object environmentInfo)
            {
                EnvironmentName = environmentName;
                EnvironmentInfo = environmentInfo;
            }

            internal string EnvironmentName { get; }

            internal object EnvironmentInfo { get; }
        }

        // One generated launch candidate reuses the donor song/difficulty and swaps only its target environment.
        private sealed class EnvironmentMapCandidate
        {
            internal EnvironmentMapCandidate(
                string environmentName,
                string mapDirectory,
                object beatmapLevel,
                object difficultyOrKey,
                bool isLegacy,
                object targetEnvironmentInfo)
            {
                EnvironmentName = environmentName;
                MapDirectory = mapDirectory;
                BeatmapLevel = beatmapLevel;
                DifficultyOrKey = difficultyOrKey;
                IsLegacy = isLegacy;
                TargetEnvironmentInfo = targetEnvironmentInfo;
            }

            internal string EnvironmentName { get; }

            internal string MapDirectory { get; }

            internal object BeatmapLevel { get; }

            internal object DifficultyOrKey { get; }

            internal bool IsLegacy { get; }

            internal object TargetEnvironmentInfo { get; }
        }
    }
}

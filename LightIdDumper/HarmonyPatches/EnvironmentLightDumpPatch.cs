using HarmonyLib;

namespace LightIdDumper.HarmonyPatches
{
    // EnvironmentSceneSetup marks the earliest environment-specific lifecycle point where the shared manager can be captured.
    [HarmonyPatch(typeof(EnvironmentSceneSetup), nameof(EnvironmentSceneSetup.InstallBindings))]
    internal static class EnvironmentSetupPatch
    {
        [HarmonyPostfix]
        private static void Postfix(EnvironmentSceneSetup __instance)
        {
            LightDumpCapture.BeginEnvironment(__instance);
        }
    }

    // Regression: InstallBindings can run before the manager is discoverable, so registration supplies its reference without postponing capture beyond the first-frame Start boundary.
    [HarmonyPatch(typeof(LightWithIdManager), nameof(LightWithIdManager.RegisterLight))]
    internal static class LightRegistrationPatch
    {
        [HarmonyPostfix]
        private static void Postfix(LightWithIdManager __instance)
        {
            LightDumpCapture.ObserveRegistration(__instance);
        }
    }

    // Chroma resolves environment-enhancement IDs from a coroutine started in a BeatmapObjectSpawnController.Start
    // prefix and resumed at WaitForEndOfFrame (Heck Chroma EnvironmentEnhancementManager.Start/DelayedStart). The
    // previous pre-ring-movement boundary sampled while transient GameCore roots (gameplay pools) still existed,
    // inflating the root indices of dynamically-spawned ring clones: Timbaland's PairLaserTrackLaneRings dumped at
    // [513..522] while Chroma matches the same rings in real gameplay at [1..10]. Sampling at Chroma's exact
    // boundary keeps every dumped path and root index identical to what Chroma resolves, which is this dumper's
    // entire purpose; ring transforms therefore include their first movement update, exactly as Chroma sees them.
    [HarmonyPatch(typeof(BeatmapObjectSpawnController), nameof(BeatmapObjectSpawnController.Start))]
    internal static class ChromaBoundaryCapturePatch
    {
        [HarmonyPrefix]
        private static void Prefix(BeatmapObjectSpawnController __instance)
        {
            LightDumpCapture.ScheduleChromaBoundaryCapture(__instance);
        }
    }
}

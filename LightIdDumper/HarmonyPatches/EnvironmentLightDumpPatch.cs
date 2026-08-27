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

    // Regression: the environment setup object's late Start sometimes ran after GameCore lane-ring updates, so capture immediately before the manager's first FixedUpdate mutates ring state.
    [HarmonyPatch(typeof(TrackLaneRingsManager), "FixedUpdate")]
    internal static class TrackLaneRingsPreMovementCapturePatch
    {
        [HarmonyPrefix]
        private static void Prefix()
        {
            LightDumpCapture.CaptureBeforeRingMovement();
        }
    }
}

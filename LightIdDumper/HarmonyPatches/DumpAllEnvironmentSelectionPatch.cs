using HarmonyLib;

namespace LightIdDumper.HarmonyPatches
{
#if PRE_V1_37_1
    // Regression: generated legacy launches used OverrideEnvironmentSettings and produced a different shared-light registration order, so this prefix makes the target catalog environment the difficulty's native result.
    [HarmonyPatch(typeof(BeatmapEnvironmentHelper), nameof(BeatmapEnvironmentHelper.GetEnvironmentInfo))]
    internal static class LegacyDumpAllEnvironmentSelectionPatch
    {
        [HarmonyPrefix]
        private static bool Prefix(ref EnvironmentInfoSO? __result)
        {
            if (!DumpAllEnvironmentSelection.TryGetTarget(out EnvironmentInfoSO? targetEnvironmentInfo))
            {
                return true;
            }

            __result = targetEnvironmentInfo;
            return false;
        }
    }
#else
    // Regression: generated modern launches used OverrideEnvironmentSettings and produced a different shared-light registration order, so this postfix makes the target name the donor difficulty's normal environment identity.
    [HarmonyPatch(typeof(BeatmapLevel), nameof(BeatmapLevel.GetEnvironmentName))]
    internal static class ModernDumpAllEnvironmentSelectionPatch
    {
        [HarmonyPostfix]
        private static void Postfix(ref EnvironmentName __result)
        {
            if (DumpAllEnvironmentSelection.TryGetTarget(out EnvironmentName targetEnvironmentName))
            {
                __result = targetEnvironmentName;
            }
        }
    }
#endif
}

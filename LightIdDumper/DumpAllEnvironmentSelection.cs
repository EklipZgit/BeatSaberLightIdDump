namespace LightIdDumper
{
    // Regression: OverrideEnvironmentSettings changed the generated level's setup semantics and registration order, so dump-all now substitutes the donor difficulty's native environment lookup for exactly one active level.
    internal static class DumpAllEnvironmentSelection
    {
        private static bool _active;

#if PRE_V1_37_1
        private static EnvironmentInfoSO? _targetEnvironmentInfo;
#else
        private static EnvironmentName _targetEnvironmentName;
#endif

        // The selection remains active through asynchronous beatmap loading because modern GameplayCoreSceneSetupData queries the environment after StartStandardLevel returns.
        internal static void Activate(string environmentName, object targetEnvironmentInfo)
        {
#if PRE_V1_37_1
            _targetEnvironmentInfo = targetEnvironmentInfo as EnvironmentInfoSO ??
                throw new System.ArgumentException("The dump-all target was not an EnvironmentInfoSO.", nameof(targetEnvironmentInfo));
#else
            _targetEnvironmentName = environmentName;
#endif
            _active = true;
        }

        // Returning to the menu clears the substitution before the next generated difficulty is selected.
        internal static void Deactivate()
        {
            _active = false;
#if PRE_V1_37_1
            _targetEnvironmentInfo = null;
#else
            _targetEnvironmentName = EnvironmentName.Empty;
#endif
        }

#if PRE_V1_37_1
        // Legacy setup resolves an EnvironmentInfoSO directly from IDifficultyBeatmap, so the patch supplies the catalog asset without constructing an override.
        internal static bool TryGetTarget(out EnvironmentInfoSO? targetEnvironmentInfo)
        {
            targetEnvironmentInfo = _targetEnvironmentInfo;
            return _active && targetEnvironmentInfo != null;
        }
#else
        // Modern setup resolves an EnvironmentName from BeatmapLevel in both scene setup and deferred beatmap loading.
        internal static bool TryGetTarget(out EnvironmentName targetEnvironmentName)
        {
            targetEnvironmentName = _targetEnvironmentName;
            return _active;
        }
#endif
    }
}

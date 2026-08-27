using HarmonyLib;
using IPA;
using JetBrains.Annotations;
using Logger = IPA.Logging.Logger;

namespace LightIdDumper
{
    [Plugin(RuntimeOptions.DynamicInit)]
    internal class Plugin
    {
        // A unique Harmony owner lets disable remove only this diagnostic mod's patches.
        private readonly Harmony _harmonyInstance = new("com.eklipz.LightIdDumper");

#pragma warning disable CA1822

        // BSIPA supplies the logger before any environment-load patch can execute.
        [UsedImplicitly]
        [Init]
        public Plugin(Logger pluginLogger)
        {
            Log = pluginLogger;
        }

        internal static Logger Log { get; private set; } = null!;

        // Environment capture is always enabled, while full-game automation starts only with its explicit batch argument.
        [UsedImplicitly]
        [OnEnable]
        public void OnEnable()
        {
            LightDumpCapture.Initialize();
            _harmonyInstance.PatchAll(typeof(Plugin).Assembly);
            Log.Info("LightIdDumper enabled; environment snapshots will be written under UserData/LightIdDumper.");
            DumpAllEnvironmentsController.StartIfRequested();
        }

        // Invalidating the capture token prevents an already-running coroutine from writing after disable.
        [UsedImplicitly]
        [OnDisable]
        public void OnDisable()
        {
            LightDumpCapture.Dispose();
            _harmonyInstance.UnpatchSelf();
        }
#pragma warning restore CA1822
    }
}

using UnityEngine;

namespace LightIdDumper
{
    // Environments without lane rings still need a post-Start snapshot, so this late Start component is the no-ring fallback for the ring-aware lifecycle patch.
    [DefaultExecutionOrder(32000)]
    internal sealed class BeforeFirstFrameCapture : MonoBehaviour
    {
        private int _captureToken;

        // Scheduling during EnvironmentSceneSetup.InstallBindings places the fallback in the environment's first Start phase without changing any stock component's execution order.
        internal static void Schedule(GameObject environmentSetupObject, int captureToken)
        {
            BeforeFirstFrameCapture capture = environmentSetupObject.AddComponent<BeforeFirstFrameCapture>();
            capture._captureToken = captureToken;
        }

        // A synchronous write here captures no-ring environments after Start-created fixture initialization; ring environments normally win earlier at the manager's first movement boundary.
        private void Start()
        {
            LightDumpCapture.CaptureBeforeFirstFrame(_captureToken);
            Destroy(this);
        }
    }
}

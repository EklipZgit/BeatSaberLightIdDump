# Runtime light data

`DumpAllLightIds.ps1` creates one child directory per Beat Saber version and
copies the validated current-format `BehaviorLights`, `OtherLights`, and
`_dump-all-status.json` files into it.

Example:

```text
RuntimeLightData/
  1.44.1/
    KaleidoscopeEnvironment_BehaviorLights.json
    KaleidoscopeEnvironment_OtherLights.json
    _dump-all-status.json
```

Pass `-OutputPath` to `DumpAllLightIds.ps1` to use a different archive root.

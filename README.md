# LightIdDumper

LightIdDumper is a standalone BSIPA diagnostic mod for recording Beat Saber's
runtime light-ID registration tables. It uses the multi-version project, Luna
build tasks, configuration names, and deployment flow cloned from ChromaGLS, but
has its own `LightIdDumper` plugin identity and only declares the runtime
dependency it uses: BSIPA.

The purpose of the mod is to produce stable evidence for translating Chroma
light IDs when a game update changes an environment's serialized assets or the
order in which its lights register.

The complete developer reference for identifier spaces, asset/event grouping,
Chroma runtime behavior, ChroMapper reconstruction, Kaleidoscope findings, and
cross-version remapping is in
[`LightIdDumper/README.md`](LightIdDumper/README.md).

## Why runtime capture is required

Beat Saber stores environment lights in:

```csharp
List<ILightWithId>[] LightWithIdManager._lights
```

The outer array index is the in-game event light ID. The inner list index is the
runtime registration index for an individual light. Chroma's light-ID table maps
a stable authored Chroma ID to that inner runtime index:

```text
table[beatSaberLightId][chromaLightId] = indexWithinLightIdList
```

For example, a table entry such as `"1": { "4": 12 }` means authored Chroma
light ID 4 in Beat Saber light-ID slot 1 selects `_lights[1][12]`.

The runtime index cannot be recovered reliably from names or serialized IDs
alone. `LightWithIdMonoBehaviour` and `LightWithIds` register with the shared
manager during Unity/Zenject environment initialization, and asset changes can
shift the resulting list order between game versions. The runtime table is the
authoritative source.

## Capture lifecycle

The Harmony patches are in
[`LightIdDumper/HarmonyPatches/EnvironmentLightDumpPatch.cs`](LightIdDumper/HarmonyPatches/EnvironmentLightDumpPatch.cs).
The capture implementation is in
[`LightIdDumper/LightDumpCapture.cs`](LightIdDumper/LightDumpCapture.cs).

The capture sequence is:

1. A postfix on `EnvironmentSceneSetup.InstallBindings` identifies the new
   environment, immediately resolves the `LightWithIdManager` component from
   the `LightManager` game object, and schedules a last-ordered initialization
   callback.
2. A postfix on `LightWithIdManager.RegisterLight` observes environment light
   registration without modifying the manager or its lists and supplies the
   authoritative manager if it was not discoverable during setup.
3. A `DefaultExecutionOrder(32000)` component captures synchronously at the end
   of the environment's first `Start` phase. Stock `Start` initialization has
   therefore created and positioned dynamic fixtures, but Unity has not yet run
   the first `FixedUpdate`, `Update`, `LateUpdate`, or render. This prevents
   unconditional startup effects such as track-ring rotation from changing the
   captured world transforms.
4. That same main-thread callback walks only populated `_lights` slots, builds
   all Unity-derived data, and serializes separate MonoBehaviour and other-light
   JSON files before returning control to the player loop.

No component discovery, reflection, collection traversal, or file I/O is added
to a per-frame lighting path. The registration postfix only supplies the
pending capture's authoritative manager reference.

## Output location and lifetime

Each game installation writes to:

```text
<Beat Saber>/UserData/LightIdDumper/<game version>/<EnvironmentName>_BehaviorLights.json
<Beat Saber>/UserData/LightIdDumper/<game version>/<EnvironmentName>_OtherLights.json
```

`BehaviorLights` contains registered `ILightWithId` implementations that are
Unity `MonoBehaviour` components with their own GameObject. Ordinary
Heck/Chroma light-ID tables select their targets from this file, although not
every rendering companion needs its own table entry.
`OtherLights` contains nested plain-C# `ILightWithId` wrappers and null
manager-list tombstones. Loading the environment again replaces both files with
the newest complete snapshot and removes that environment's obsolete combined
`.json` file. Different versions have separate directories.

The automated runner validates those in-game files and copies the complete
current run into the repository-owned archive:

```text
RuntimeLightData/<Beat Saber version>/<EnvironmentName>_BehaviorLights.json
RuntimeLightData/<Beat Saber version>/<EnvironmentName>_OtherLights.json
```

`DumpAllLightIds.ps1 -OutputPath <directory>` overrides the archive root while
retaining the per-version directory. The transient `_dump-all-status.json`
remains in the game installation for validation and diagnostics but is not
copied into the repository archive.

The BSIPA log records when capture begins, its initial entry count, the final
entry/group counts, and both exact output paths. For current-run diagnostics use
that installation's live `_latest.log` or `Logs_latest.log`, never a timestamped
archive.

## BehaviorLights, OtherLights, and Chroma

The split describes how a registered light is attached to the loaded Unity
environment; it does not mean that `OtherLights` entries are absent from
`LightWithIdManager`. Both files preserve the entry's real outer manager slot
and original inner-list index.

| File | Runtime object | Ordinary Chroma light-ID table | Environment Enhancements |
| --- | --- | --- | --- |
| `BehaviorLights` | A GameObject-backed `LightWithIdMonoBehaviour` | Normal directly mapped fixtures are selected from this file. `heckTable[beatSaberLightId][chromaLightId]` selects one entry by `indexWithinLightIdList`; companion records need not each have a table key. | The component's `lightID` and event `type` can be reassigned. |
| `OtherLights` | A non-MonoBehaviour child inside a GameObject-backed `LightWithIds` owner, or a null tombstone | Not a normal table target and excluded from ordinary fixture/entity matching. A table index resolving here is reported as a verifier error. | Chroma can reach non-null children through the selected owner and assign their `lightID` and `type`, making them addressable by a map-authored light ID without turning the wrappers into MonoBehaviours. |

The official Heck documentation describes the Environment Enhancement
[`ILightWithId` component fields](https://heck.aeroluna.dev/environment/environment/#components):
`lightID` assigns the ID used by lighting events and `type` assigns the event
type. Its [standard-light event documentation](https://heck.aeroluna.dev/items/events/#standard-lights)
describes the map-side `lightID` selector. Chroma's implementation applies the
component command to both GameObject-backed light behaviours and the nested
`_lightWithIds` children of a matching `LightWithIds` owner. Therefore
`OtherLights` is diagnostic/reference data for stock Chroma tables, but it is
not intrinsically impossible for an Environment Enhancement to light-ID those
non-MonoBehaviour children.

In other words, a real `OtherLights` child can already expose a stock
`componentLightId` and occupy a manager slot, but it has no normal stable
authored Chroma ID table entry of its own. An Environment Enhancement can assign
one for that map through the owner-mediated component command.

Null tombstones are retained only to preserve list indexing and cannot be
configured. Assigning an ID to a real `OtherLights` child also does not make it
a stock table-mapped fixture; it remains an owner-backed wrapper and will still
be emitted in `OtherLights` on a subsequent capture.

## JSON schema

The current and only supported schema is format 5. The model is defined in
[`LightIdDumper/LightDumpModels.cs`](LightIdDumper/LightDumpModels.cs). Output is
camel-cased and includes meaningful class-specific null values deliberately,
while fields proven constant or inapplicable for an entire classified file are
omitted.

Capture timestamps are intentionally omitted so an unchanged environment produces
an unchanged JSON file on subsequent dump-all runs.

```json
{
  "formatVersion": 5,
  "environmentName": "KaleidoscopeEnvironment",
  "gameVersion": "1.44.1",
  "lightManagerPath": "MainMenu.[0]LightManager",
  "initialRegisteredLightCount": 0,
  "totalRegisteredLightCount": 200,
  "lightIdSlots": [
    {
      "beatSaberLightId": 1,
      "commonGameObjectPath": "GameCore.[509]ConeRing(Clone)",
      "registeredLightCount": 40,
      "registeredLights": [
        {
          "indexWithinLightIdList": 12,
          "componentLightId": 1,
          "type": 0,
          "typeName": "Event0",
          "relativeGameObjectPath": "[1]Cone (1).[5]NeonTubeDirectional (2)",
          "gameObjectPath": "GameCore.[509]ConeRing(Clone).[1]Cone (1).[5]NeonTubeDirectional (2)",
          "componentType": "TubeBloomPrePassLightWithId",
          "localScale": { "x": 1.0, "y": 1.0, "z": 1.0 },
          "sceneName": "GameCore"
        }
      ]
    }
  ]
}
```

The paired `OtherLights` file uses the same root, slot, and common record
fields. A non-MonoBehaviour wrapper record uses its owner for Unity identity,
as in this format-5 shape:

```json
{
  "indexWithinLightIdList": 80,
  "componentLightId": 1,
  "type": 0,
  "typeName": "Event0",
  "relativeGameObjectPath": "[12]CoreLighting.[0]DirectionalLight",
  "componentType": "RuntimeLightWithIds+LightIntensitiesWithId",
  "ownerGameObjectPath": "KaleidoscopeEnvironment.[0]Environment.[12]CoreLighting.[0]DirectionalLight",
  "ownerComponentType": "DirectionalLightWithIds",
  "indexWithinOwner": 0,
  "ownerLocalScale": { "x": 1.0, "y": 1.0, "z": 1.0 },
  "ownerSceneName": "KaleidoscopeEnvironment",
  "intensity": 0.0,
  "bakeId": null,
  "weight": null
}
```

Important fields:

- `beatSaberLightId`: outer `LightWithIdManager._lights` array index and basic
  event light ID. Every entry in the slot normally reports this same ID.
- `indexWithinLightIdList`: original inner `_lights[beatSaberLightId]` list
  index. This is the value stored on the right-hand side of Heck/Chroma's
  light-ID table. It can be sparse within either classified file because the
  opposite classification was moved to its paired file.
- `componentLightId`: the `ILightWithId.lightId` declared by the component. Its
  repetition is expected: it identifies the containing Beat Saber slot, not a
  unique fixture or Chroma ID. Retaining it exposes registration mismatches.
- `type`: the integer `BasicBeatmapEventType` accepted by Chroma's documented
  `ILightWithId` environment component. Beat Saber does not store it on the
  light; the dumper derives it from the loaded `LightSwitchEventEffect` whose
  `lightsId` targets the light's manager slot.
- `typeName`: the enum name for `type`, such as `Event0`, written immediately
  after the integer. Both values are `null` only when the loaded environment has
  no `LightSwitchEventEffect` for that slot.
- `commonGameObjectPath`: longest common Chroma hierarchy-path prefix shared by
  the classified records in one Beat Saber light-ID slot. `BehaviorLights` uses
  direct component paths; `OtherLights` uses owner paths. It is path data, not a
  semantic light-group name.
- `relativeGameObjectPath`: the remainder below `commonGameObjectPath`.
- `gameObjectPath`: exact `Scene.[siblingIndex]Name...` path generated using the same
  root-index strategy as Heck/Chroma environment lookup.
- `componentType`: full runtime component type name.
- The paired filename is the classification: `BehaviorLights` contains Unity
  `MonoBehaviour` entries and `OtherLights` contains plain wrapper entries and
  null tombstones. No per-record classification flag is repeated.
- `localScale` and `ownerLocalScale`: the remaining numeric transform evidence.
  Runtime world/local positions are intentionally omitted because animated
  environment initialization made them nondeterministic between equal runs.
- Unity instance IDs are intentionally omitted from new dumps and rejected by
  the runner because they can change between equivalent runs and have no value
  for durable light remapping.
- `ownerGameObjectPath`, `ownerComponentType`, and `indexWithinOwner`: identity
  for a nested non-MonoBehaviour child of `RuntimeLightWithIds` or
  `LightmapLightsWithIds`. The child has no GameObject of its own; these fields
  resolve its private `_parentLightWithIds` owner and its position in
  `owner.lightWithIds`.
- `intensity`, `bakeId`, and `weight`: optional identifying values exposed by
  nested runtime/lightmap children.
- `totalRegisteredLightCount` and `registeredLightCount`: count entries in that
  classified file. `initialRegisteredLightCount` remains the unsplit manager
  count observed at environment setup.

If an `ILightWithId` is not a `MonoBehaviour`, format 5 writes it only to
`OtherLights`, omits the inapplicable direct Unity fields, and resolves the
private owning `LightWithIds` MonoBehaviour's path, type, transform, and
child-array index. Runtime-only owner instance IDs and constant active-state
fields are omitted. A null list entry is retained at its original list index
with null OtherLights identity fields.
Their original `indexWithinLightIdList` values are preserved in `OtherLights`,
so separating them never renumbers a following behavior light.

## Logical groups versus rendering components

A populated `beatSaberLightId` slot is the logical lighting group controlled by
one `LightSwitchEventEffect`; it is not one physical light and is not expected to
contain only directly addressable Chroma fixtures. One logical fixture can
register a material light plus one or more tube/bloom components. Directional,
lightmap, sprite, and fake-glow support components can share the same slot too.

Kaleidoscope demonstrates the distinction clearly:

| Beat Saber light ID | ChroMapper event track | Direct Chroma fixtures | Other registered components |
| --- | --- | ---: | ---: |
| 1 | Spike Tip Lights | 40 `ConeLight0` | 40 render companions + 6 runtime support |
| 2 | Spike Mid Lights | 40 `ConeLight2` | 80 render companions + 6 runtime support |
| 3 | Spike Left Lights | 20 `ConeLight1` | 40 render companions + 6 runtime support |
| 4 | Spike Right Lights | 20 `ConeLight1` | 40 render companions + 6 runtime support |
| 5 | Distant Lasers and Spike Top Lights | 40 `ConeLight3` + 20 `BigCone0` + 20 `BigCone1` | 122 render companions + 6 runtime support |

The resulting 552 runtime entries therefore represent 200 directly addressable
Chroma fixtures, 322 GameObject-backed companion renderers, 25
`RuntimeLightWithIds` array entries, and 5 runtime-only
`LightmapLightsWithIds` entries. The large count is component registration, not
552 independently authored lights.

The dump deliberately records the raw authoritative slot and list index rather
than embedding environment-specific display names. The verifier derives semantic
group names from ChroMapper's event-track metadata and its serialized
`LightSwitchEventEffect` bindings, then checks those names against the same slots
used by the Heck table.

Chroma's environment-enhancement `type` field is the reverse direction of this
same relationship. Chroma casts the supplied integer to
`BasicBeatmapEventType`, finds that event's colorizer and
`LightSwitchEventEffect`, then assigns the selected `ILightWithId` to the
effect's `lightsId`. It is not serialized on the light or its owner. Therefore
every direct light and non-MonoBehaviour wrapper in one manager slot receives
the same derived `type` and `typeName` in the dump.

## Turning captures into remapping tables

The current Chroma reference table is, for example,
`../Heck/Chroma/LightIDTables/KaleidoscopeEnvironment.json`. The corresponding
ChroMapper table is
`../ChroMapper/Assets/Editor/Environments/LightIDTables/KaleidoscopeEnvironment.json`.
Both use the same nested mapping shape, but the values are in different index
spaces. Heck's value indexes Beat Saber's runtime
`_lights[beatSaberLightId]` list. ChroMapper's value indexes the reconstructed
`LightWithIdManager.lights[beatSaberLightId]` list in its checked-in
EnvironmentData JSON. The two numbers need not be equal even when they resolve
to the same fixture.

The intended remapping workflow is:

1. Load the existing source table and source-version LightIdDumper JSON.
2. For every `(beatSaberLightId, chromaLightId, indexWithinLightIdList)` Heck
   table entry, reverse the inner-list index into the source dump's exact light
   record.
3. Match that source record to the target-version dump using stable evidence:
   full path first, then component type, relative path, and neighboring
   registration order where asset hierarchy changes require it.
4. Read the matched target record's `indexWithinLightIdList`.
5. Write `table[beatSaberLightId][chromaLightId] = targetIndexWithinLightIdList`
   while keeping the authored Chroma ID unchanged.
6. Report missing, duplicate, or ambiguous matches instead of guessing.

This mod only produces the authoritative source data. It does not yet modify the
checked-in Chroma or ChroMapper tables.

## Verifying a dump against Heck and ChroMapper

[`Export-LightIdMappingVerificationCsvs.ps1`](Export-LightIdMappingVerificationCsvs.ps1)
performs the mapping comparison and writes the four CSV perspectives.
[`Verify-LightIdMappings.ps1`](Verify-LightIdMappings.ps1) calls that exporter,
reads the resulting CSV Boolean columns, and prints a warning/error synopsis.
Both accept an optional game version and serialized environment name, search the
repository `RuntimeLightData` archive, and fall back to the matching game's
`UserData/LightIdDumper` capture, then load ChroMapper EnvironmentData and any
available Heck/Chroma or ChroMapper light-ID tables. Omitting the environment
verifies every captured environment that has Chroma-addressable Basic Event
lights. Pure GLS environments remain excluded because their fixtures use OEM
group-lighting IDs instead of the legacy Chroma light-ID tables. Omitting the
version verifies every archived version.

<!-- The fixed environment allowlist hid hybrid environments such as The Second, so selection now follows the serialized event bindings and runtime fixtures. -->
Environment selection is evidence-based rather than name-based. An environment
is included when it has an authored Heck or ChroMapper light-ID table, or when
ChroMapper EnvironmentData binds a `LightSwitchEventEffect` slot containing a
real runtime `BehaviorLight`. The ubiquitous player-platform `Feet`
`SpriteLightWithId` and `RectangleFakeGlowLightWithId` do not qualify an
otherwise GLS-only environment by themselves. Mixed environments do qualify:
for example, `TheSecondEnvironment` is included because its buildings, logo,
and runway are Basic Event lights even though the environment also contains GLS
fixtures. Its CSVs contain Basic Event slots 1, 2, and 5 and omit its unrelated
GLS manager slots. An older game version naturally exports only qualifying
environments present in that version's runtime corpus.

The normal verifier invocation prints per-environment perspective counts plus
an aggregate category synopsis:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Verify-LightIdMappings.ps1 `
    -GameVersion 1.44.1 `
    -EnvironmentName KaleidoscopeEnvironment
```

Use `-SummaryOnly` to omit the per-environment perspective tables:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Verify-LightIdMappings.ps1 `
    -GameVersion 1.44.1 `
    -EnvironmentName KaleidoscopeEnvironment `
    -SummaryOnly
```

Verify every captured environment for one game version:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Verify-LightIdMappings.ps1 `
    -GameVersion 1.44.1 `
    -SummaryOnly
```

The exporter flags table keys present on only one side, table indexes that
resolve to no dump/editor light, component IDs inconsistent with their outer
Beat Saber slot, runtime `type`/`typeName` values inconsistent with ChroMapper's
`LightSwitchEventEffect`, genuine inventory components missing from either
runtime or ChroMapper, entity-name path mismatches, and component-type
mismatches in explicit CSV Boolean columns. Numeric sibling indexes are normalized only for the entity-name
comparison; repeated normalized paths are paired by exact path first and then
stable editor/list order.

Non-table-mapped MonoBehaviour rendering companions are matched from
`BehaviorLights` as inventory instead of being misreported as missing Chroma
fixtures. `OtherLights` never participates in normal mapping/entity matching;
it is checked independently against every Heck/Chroma runtime index and every
ChroMapper `arrayId` target. A mapped entry found there emits a red verification
error with its slot, Chroma ID, manager/editor index, component type, and owner
path. The output also includes semantic-group and directly addressable
fixture-family data.

Every successful exporter comparison writes four filterable CSV
perspectives beneath
`LightMappingValidation/<version>/<environmentName>/`:

- `<version>_<environmentName>_DumpBehaviorLights.csv` contains every exported
  MonoBehaviour light in the selected Basic Event slots.
- `<version>_<environmentName>_DumpOtherLights.csv` contains every exported non-MonoBehaviour wrapper in those Basic Event slots and
  makes any accidental Heck/ChroMapper mapping into this class an explicit
  error Boolean.
- `<version>_<environmentName>_ChroMapper.csv` contains every reconstructed
  ChroMapper entry in the selected Basic Event environment's manager slots,
  including environments whose authored ChroMapper mapping table is absent.
- `<version>_<environmentName>_Chroma.csv` contains every authored Chroma ID in
  Heck's Chroma table, or every raw BehaviorLight manager index when Heck uses
  its no-table identity fallback, and cross-links each source row to ChroMapper
  and the runtime dumps. ChroMapper-only IDs remain in the ChroMapper
  perspective as missing-from-Chroma warnings.

<!-- Heck and ChroMapper both fall back to raw list indexes when no remap table exists, so a tableless environment still has real Chroma light IDs. -->
If an entire mapping table is absent, the exporter models that implementation's
identity fallback instead of suppressing the environment. The Chroma perspective
uses each BehaviorLight's raw Beat Saber manager-list index as its Chroma ID;
the ChroMapper perspective uses each non-array-wrapper editor-list index. An
explicit environment-level source-coverage warning still distinguishes these
derived identity mappings from authored remap-table rows.

Each perspective has its own CSV schema. It contains only that perspective's
source identity, applicable validation flags, and explicitly named target
columns such as `mappedChroMapperGameObjectPaths` or
`mappedDumpBehaviorGameObjectPaths`; irrelevant always-empty columns are not
emitted. The schemas also separate authored table targets from full inventory pairings.
Source-membership columns are omitted when the perspective itself already proves membership; for example,
Chroma rows do not repeat `existsInChromaTable`, `warningMissingFromChromaTable`, or `notMappedByChroma`.
The Chroma schema also omits exact aliases: `mapsToDumpBehaviorLights` and its mapped target columns are the
authored Chroma-table target, `inventoryMapsToDumpBehaviorLights` is the reconstructed inventory counterpart,
and `warningMissingFromChroMapperTable` is the canonical missing-target flag.
Version, environment, and perspective identity live only in each filename, not
as repeated row columns. `beatSaberLightId` is immediately followed by
`beatSaberIndexInLightIdsList` near the source component identity columns.
For example, `tableChroMapperIndex` is the ChroMapper index selected through a
Chroma ID, while `inventoryChroMapperIndex` is the entity/path counterpart found
in the reconstructed manager inventory. `warningTableTargetDiffersFromInventory`
makes disagreement between those interpretations directly filterable. Every applicable error/warning category has its own
Boolean plus `anyValidationError`, `anyValidationWarning`, and
`validationCodes`. Pass `-LightMappingValidationPath` to redirect the CSV root.
The verifier preserves this parameter and reports counts of flagged CSV rows;
`-FailOnWarning` exits with code 2 when any error or warning row exists.

## Automatic all-environment capture

Normal launches retain manual behavior: every environment loaded by the user is
dumped, and the game stays open. Automation is enabled only by the explicit
`--dump-all-light-ids` game argument.

Before launching each game version, `DumpAllLightIds.ps1` selects the first
installed custom-map directory, creates a temporary map that hard-links (or
copies) its song and cover, and writes one empty vanilla V2 Easy difficulty.
The generated directory sorts first in SongCore and contains no notes, events,
requirements, or environment edits. In dump-all mode the mod waits for the
normal main-menu startup transition and SongCore scan, then selects this clean
donor difficulty. For every
standard/circle entry in Beat Saber's environment catalog, the mod creates a
synthetic launch candidate that reuses the donor difficulty and targets the
catalog's real `EnvironmentInfoSO` through the game's
`OverrideEnvironmentSettings` API. It then launches each candidate through the
same `MenuTransitionsHelper.StartStandardLevel` path as Solo play.

Beat Saber 1.29/1.34 expose SongCore entries as preview-only levels. The mod
loads those preview objects directly with the game's injected
`CustomLevelLoader`; it does not look them up again through
`BeatmapLevelsModel`, whose preview-ID cache can still be refreshing after
SongCore has set `AreSongsLoaded`. Newer versions expose usable `BeatmapKey`
values on the SongCore level itself.

The runner removes the generated directory after that game exits and repeats
for the next version; `finally` cleanup also removes it after failures. The mod
does not mutate Beat Saber's private difficulty collections. The supported
environment override seam produces the requested one-launch-per-environment
behavior without being limited to the five `BeatmapDifficulty` enum values.
After the JSON is written, the controller invokes the active
`StandardLevelReturnToMenuController` and waits for the normal scene pop before
starting the next environment. Tutorial and Multiplayer are excluded from the
catalog because they are special game modes. It writes `_dump-all-status.json`
beside the captures and calls
`Application.Quit()` only after every selected environment succeeds. A song
scan, level load, transition, or capture timeout writes a fatal status and also
exits.

The run terminates before any environment launch if the catalog cannot be read
or no usable donor difficulty exists. It no longer requires separate custom
maps for each environment.

The end-to-end runner is [`DumpAllLightIds.ps1`](DumpAllLightIds.ps1):

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\DumpAllLightIds.ps1
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\DumpAllLightIds.ps1 -Version 1.44.1,1.44.2
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\DumpAllLightIds.ps1 -OutputPath D:\BeatSaberLightData
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\DumpAllLightIds.ps1 -Version 1.44.1 -Verify
```

It builds Release plugins, generates and cleans the donor map, then prints and
launches each selected game sequentially
with BSManager's `--no-yeet -vrmode oculus fpfc` arguments plus
`--dump-all-light-ids`. It also mirrors BSManager's direct Steam launch
environment by setting `SteamAppId`, `SteamOverlayGameId`, and `SteamGameId` to
Beat Saber's app ID (`620980`); this prevents Steam from relaunching the copied
instance and showing its custom-arguments prompt. The runner tracks the real
executable until it exits, rejects either missing, stale, misclassified, or
structurally invalid format-5 file in every pair, copies every pair to
`RuntimeLightData/<version>` (or `-OutputPath`), optionally runs
mapping verification with `-Verify` where all repository inputs exist,
corroborates completion in the live log, and always calls the deploy script's `-Uninstall`
path in `finally`.

## Supported configurations

The solution contains Debug and Release configurations for:

| Beat Saber | Built by default when installed | Notes |
| --- | --- | --- |
| 1.29.1 | Yes | Uses the matching configured BSManager install. |
| 1.34.2 | Yes | Uses the matching configured BSManager install. |
| 1.37.1 | Yes | Uses the matching configured BSManager install. |
| 1.40.8 | Yes | Uses the matching configured BSManager install. |
| 1.42.1 | Yes | Uses the matching configured BSManager install. |
| 1.44.1 | Yes | Uses the matching configured BSManager install. |
| 1.44.2 | Yes | Uses managed Newtonsoft.Json and a compile-only HarmonyX fallback when the selected install has no `Libs` directory. |

The declared plugin dependency is only `BSIPA ^4.2.2`. Chroma, SongCore, and
CustomJSONData are not required for ordinary one-environment capture. The
explicit dump-all mode requires SongCore at runtime because it deliberately
uses installed custom levels to enter each selectable environment.
HarmonyX 2.16.0 is restored as a private compile-time package only when a selected
install does not expose `Libs/0Harmony.dll`; it is not bundled into the plugin or
added to the BSIPA manifest. The game installation still needs a complete BSIPA
runtime before it can load any BSIPA mod.

## Build and deployment

The scripts use a matching process environment variable when present and
otherwise use `C:\Users\tdrak\BSManager\BSInstances\<version>`:

```text
BEATSABER_1_29_1
BEATSABER_1_34_2
BEATSABER_1_37_1
BEATSABER_1_40_8
BEATSABER_1_42_1
BEATSABER_1_44_1
BEATSABER_1_44_2
```

Use [`build-all-versions.ps1`](build-all-versions.ps1) directly from this folder:

```powershell
.\build-all-versions.ps1
.\build-all-versions.ps1 -Release
.\build-all-versions.ps1 -Version 1.44.1 -Release
.\build-all-versions.ps1 -Version 1.44.1 -Release -PluginVersion 1.0.1
```

Each selected configuration compiles against its own game assemblies. Luna's
`BSMT_CopyToPlugins` target then copies `LightIdDumper.dll` and its PDB into that
same installation's `Plugins` directory. Release output and plugin-only zip files
are under:

```text
LightIdDumper/bin/Release-<game version>/net48/
```

For the normal deployment workflow, use the repository-local wrapper. Omitting
`-Version` selects every installed supported version:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Deploy-LightIdDumper.ps1
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Deploy-LightIdDumper.ps1 -Release
```

## Uninstall

Run:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Deploy-LightIdDumper.ps1 -Uninstall
```

Uninstall does not build and does not recurse through any directory. For every
configured game version it removes only:

```text
Plugins/LightIdDumper.dll
Plugins/LightIdDumper.pdb
```

Captured JSON under `UserData/LightIdDumper` is intentionally preserved.

## Validation checklist

After a code or configuration change:

1. Run the Release all-version build and require zero compiler/analyzer warnings.
2. Confirm the summary lists every deployable Release configuration.
3. Check each generated manifest has ID `LightIdDumper`, its matching game
   version, and only the BSIPA dependency.
4. Compare the built and installed DLL hashes and `LastWriteTimeUtc`.
5. Start the selected Beat Saber version and load an environment.
6. Check the authoritative live log for `LightIdDumper enabled` and the completed
   dump line; the log timestamp must be newer than the installed DLL timestamp.
7. Parse both generated JSON files and verify `indexWithinLightIdList` values
   are unique and ascending within each slot, every entry contains `type`,
   and `typeName`; confirm each classified file contains only its applicable
   direct or owner identity fields without renumbering original indexes.

The game-starting steps must not be run while the machine is in use without the
operator's explicit approval. PowerShell parsing and Release builds do not start
Beat Saber.

## Repository layout

```text
BeatSaberLightIdDumper/
  LightIdDumper.sln
  Directory.Build.targets
  NuGet.config
  build-all-versions.ps1
  package-release.ps1
  README.md
  LightIdDumper/
    LightIdDumper.csproj
    Plugin.cs
    DumpAllEnvironmentsController.cs
    DumpAllRunModels.cs
    LightDumpCapture.cs
    LightDumpModels.cs
    HarmonyPatches/
      EnvironmentLightDumpPatch.cs
```

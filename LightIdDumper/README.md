# Light ID model and remapping notes

This document records the runtime light-ID model established while building and
validating LightIdDumper. It focuses on how Beat Saber, Heck/Chroma, ChroMapper,
and serialized environment assets refer to the same logical lights using
different identifiers and list orderings.

For build, deployment, supported-game-version, and uninstall instructions, see
the [repository README](../README.md).

## The important distinction: fixtures versus components

Beat Saber does not expose one manager entry per visible or mapper-addressable
fixture. A logical fixture can register several independent `ILightWithId`
implementations, for example:

- `MaterialLightWithId` for an emissive mesh;
- one or more `TubeBloomPrePassLightWithId` components for bloom tubes;
- `RuntimeLightWithIds+LightIntensitiesWithId` wrappers for Unity lights;
- `LightmapLightsWithIds+LightIntensitiesWithId` for lightmap contribution;
- environment-specific sprite or fake-glow light components.

These components can all share one Beat Saber light-ID slot. Consequently, a
dump containing hundreds of registered entries does not imply that the
environment contains hundreds of independently authored fixtures.

The current Kaleidoscope capture contains 552 registered components but only 200
directly addressable Chroma fixtures. The other entries are companion renderers
or shared lighting support.

## Identifier and index spaces

Five different values must not be conflated.

### Basic beatmap event type

The beatmap event type selects a `LightSwitchEventEffect`. ChroMapper displays a
friendly track name for that event, such as `Spike Tip Lights` for `Event0` in
Kaleidoscope.

This is not automatically the same number as the manager's outer light ID.
Always read the serialized `LightSwitchEventEffect` binding instead of assuming
that event N controls slot N or N+1.

### Beat Saber light ID

`LightWithIdManager` stores:

```csharp
List<ILightWithId>[] _lights;
```

The outer array index is the Beat Saber light ID. LightIdDumper calls it
`beatSaberLightId`. A `LightSwitchEventEffect` has a `lightsId` that selects this
outer slot.

For Kaleidoscope, the serialized bindings are:

| Event type | ChroMapper track name | `lightsId` |
| --- | --- | ---: |
| `Event0` | Spike Tip Lights | 1 |
| `Event1` | Spike Mid Lights | 2 |
| `Event2` | Spike Left Lights | 3 |
| `Event3` | Spike Right Lights | 4 |
| `Event4` | Distant Lasers and Spike Top Lights | 5 |

### Component light ID

Every registered component exposes `ILightWithId.lightId`. LightIdDumper records
this as `componentLightId`.

It normally repeats the containing outer slot number. Seeing the same
`componentLightId` dozens of times is expected and is not evidence of duplicate
fixture IDs. Its diagnostic purpose is to catch a component registered in a slot
that disagrees with the component's declared light ID.

### Runtime inner-list index

Each component's position in `_lights[beatSaberLightId]` is its runtime inner-list
index. LightIdDumper calls it `indexWithinLightIdList`.

This index is implicit: it comes from registration order rather than a unique
field on the component. It can shift when an environment asset or game version
adds, removes, or reorders registrations. This is the right-hand value stored in
Heck/Chroma's runtime table.

### Authored Chroma light ID

The map's custom `lightID` is a stable authored identifier. It is the inner key
in a Chroma light-ID table and is not the same value as `componentLightId`. The
official Heck [standard-light event documentation](https://heck.aeroluna.dev/items/events/#standard-lights)
defines this `lightID` as the selector that restricts an event to the requested
ID or IDs.

Heck's mapping shape is:

```text
heckTable[beatSaberLightId][chromaLightId] = runtimeIndexWithinLightIdList
```

### Chroma environment-component type

The `ILightWithId` component field called `type` in Chroma environment
enhancements is the integer value of `BasicBeatmapEventType`, for example `0`
for `Event0`. It is not stored on `ILightWithId` or on a
`RuntimeLightWithIds` owner. Heck's official
[`ILightWithId` Environment Enhancement documentation](https://heck.aeroluna.dev/environment/environment/#components)
defines both configurable fields: `lightID` assigns the lighting-event ID and
`type` assigns the event type.

Chroma handles `type` by finding the `LightColorizer` for that event type,
reading its `LightSwitchEventEffect.LightsID`, and changing the selected
component's light ID to that manager slot. LightIdDumper reverses that lookup at
capture time: it inventories loaded `LightSwitchEventEffect` components, joins
their `lightsId` to each manager slot, and writes both `type` and `typeName` on
every registered entry. Thus a slot controlled by `Event4` records:

```json
"type": 4,
"typeName": "Event4"
```

Non-MonoBehaviour wrappers receive the same slot-derived values. If no loaded
effect targets a slot, both properties are explicitly `null`. If different
event types target the same slot, the mod logs the ambiguity and retains the
lower enum integer deterministically; checked-in ChroMapper environment data
currently has no such conflicting slots.

### ChroMapper editor-list index

ChroMapper reconstructs its own `LightWithIdManager.lights[beatSaberLightId]`
lists from checked-in EnvironmentData. A ChroMapper table value indexes that
editor list, not Beat Saber's runtime list.

Its mapping shape is:

```text
chroMapperTable[beatSaberLightId][chromaLightId] = editorListIndex
```

The Heck and ChroMapper keys should agree, but their right-hand values do not
need to be equal. For example, current Kaleidoscope data contains:

| Slot / Chroma ID | Heck runtime index | ChroMapper editor index | Resolved fixture |
| --- | ---: | ---: | --- |
| 1 / 1 | 6 | 0 | first `ConeLight0` spike-tip fixture |
| 5 / 1 | 8 | 0 | first `ConeLight3` spike-top fixture |
| 5 / 41 | 128 | 120 | first distant `BigCone0` fixture |

The differing numbers are correct because runtime support components register at
different positions than ChroMapper's reconstructed entries.

## How the asset-level group name is found

The runtime manager contains slots and components, but it does not store mapper
display names such as `Spike Mid Lights`. Those names are derived through two
serialized ChroMapper data sets:

1. `environmentData.lightTracks.eventTracks` maps an event type such as `Event1`
   to a display name such as `Spike Mid Lights`.
2. Each serialized `LightSwitchEventEffect` maps that event type to its
   `lightsId`, which is the outer `LightWithIdManager` slot.

The verifier performs this join rather than hard-coding Kaleidoscope's names.
The relevant sources are:

- [Kaleidoscope EnvironmentData](../../ChroMapper/Assets/__Scenes/Environments/Data/KaleidoscopeEnvironment.json)
- [Kaleidoscope track definition](../../ChroMapper/Assets/__Scripts/Environments/TracksDefinitions/KaleidoscopeEnvironmentTracksDefinition.asset)

The hierarchy names in the dump answer a different question. Names such as
`ConeRing(Clone)` and `ConeRingBig(Clone)` identify asset geometry and object
ownership; they are not the semantic event-track names.

## Kaleidoscope's five logical groups

Kaleidoscope reuses the small `ConeRing(Clone)` hierarchy for four independently
controlled portions of every spike. The fact that slots 1 through 4 share that
root family is therefore expected.

| Beat Saber slot | Semantic group | Direct Chroma representatives | Companion/support registration |
| ---: | --- | --- | --- |
| 1 | Spike Tip Lights | 40 `ConeLight0` | 40 tube renderers + 5 runtime-light wrappers + 1 lightmap wrapper |
| 2 | Spike Mid Lights | 40 `ConeLight2` | 80 tube renderers + 5 runtime-light wrappers + 1 lightmap wrapper |
| 3 | Spike Left Lights | 20 `ConeLight1` under the first cone | 40 tube renderers + 5 runtime-light wrappers + 1 lightmap wrapper |
| 4 | Spike Right Lights | 20 `ConeLight1` under the opposite cone | 40 tube renderers + 5 runtime-light wrappers + 1 lightmap wrapper |
| 5 | Distant Lasers and Spike Top Lights | 40 `ConeLight3`, 20 `BigCone0`, and 20 `BigCone1` | 120 tube renderers, one sprite, one rectangle glow, 5 runtime-light wrappers, and 1 lightmap wrapper |

Slot 5 intentionally combines two asset families:

- the 40 spike outer/top lights under the small `ConeRing(Clone)` objects;
- the 40 distant lasers under the `ConeRingBig(Clone)` objects.

The two 20-entry `BigCone0` and `BigCone1` populations together form the 40
distant lasers.

The total accounting is:

| Category | Count |
| --- | ---: |
| Direct Chroma representatives | 200 |
| GameObject-backed companion renderers | 322 |
| `RuntimeLightWithIds` wrappers | 25 |
| Runtime-only `LightmapLightsWithIds` wrappers | 5 |
| Total runtime manager entries | 552 |

ChroMapper reconstructs all 522 GameObject-backed entries and the 25 runtime
array entries, giving 547 entries. It does not reconstruct the five lightmap
wrappers in its manager list.

## How Chroma applies lighting events

Chroma replaces `LightSwitchEventEffect.Start()` with its own initialization and
creates a separate `ChromaIDColorTween` for each registered `ILightWithId`
component.

The relevant code paths are:

- [LightColorizerInitialize.cs](../../Heck/Chroma/HarmonyPatches/Colorizer/Initialize/LightColorizerInitialize.cs)
- [ChromaLightSwitchEventEffect.cs](../../Heck/Chroma/Lighting/ChromaLightSwitchEventEffect.cs)
- [LightColorizer.cs](../../Heck/Chroma/Colorizer/LightColorizer.cs)
- [ChromaIDColorTween.cs](../../Heck/Chroma/Lighting/ChromaIDColorTween.cs)

The behavior depends on whether the event has a custom Chroma `lightID`:

- Without a custom `lightID`, Chroma refreshes every component tween in the
  selected Beat Saber slot. Materials, tubes, runtime lights, lightmap lights,
  sprites, and fake glow all participate in the logical group event.
- With a custom `lightID`, `LightColorizer.GetLightWithIds()` resolves each
  authored ID through the active Heck table and selects one runtime inner-list
  entry per ID. `ChromaIDColorTween.SetColor()` calls that component's
  `ColorWasSet()` directly.

There is no automatic sibling expansion for modern `lightID` events. A mapped
`MaterialLightWithId` does not automatically select adjacent tube components on
the same cone. In the current Kaleidoscope table all 200 direct targets are
`MaterialLightWithId` components; the tube components remain whole-group
companions rather than individually mapped fixtures.

Other code that calls `LightWithIdManager.SetColorForId()` still fans the color
out to every registered component in the slot. Chroma patches that method to
retain the whole-slot behavior while allowing null tombstones in its lists.

The deprecated `propID` path is separate. It groups MonoBehaviour lights by
rounded Z position or track-ring position and can select multiple components.
Modern Chroma `lightID` lookup does not use that propagation grouping.

The current table shape is one authored ID to one inner-list index. Representing
one modern Chroma ID as several component targets would require either a table
schema change or explicit companion expansion in Chroma.

## What LightIdDumper captures

The current and only supported JSON schema is format version 5, defined in
[LightDumpModels.cs](LightDumpModels.cs). Older dump formats are intentionally
unsupported. Format 5 samples at Chroma's environment-enhancement boundary so
every dumped path and GameCore root index matches what Chroma resolves during
real gameplay; format 5 and earlier sampled before level setup completed and
carried transient GameCore root offsets in dynamically-spawned ring paths
(for example, Timbaland's `PairLaserTrackLaneRing(Clone)` roots captured at
`[513..522]` instead of Chroma's `[1..10]`).

The capture implementation is [LightDumpCapture.cs](LightDumpCapture.cs), and
the lifecycle patches are in
[EnvironmentLightDumpPatch.cs](HarmonyPatches/EnvironmentLightDumpPatch.cs).

The capture sequence is:

1. `EnvironmentSceneSetup.InstallBindings` identifies the environment and tries
   to resolve `LightWithIdManager` from the `LightManager` GameObject, then
   arms the capture.
2. A `LightWithIdManager.RegisterLight` observation supplies the authoritative
   manager if setup occurred before it was discoverable.
3. A prefix on `BeatmapObjectSpawnController.Start` starts a coroutine that
   resumes at `WaitForEndOfFrame` and captures there. This is the exact
   boundary at which Heck Chroma's `EnvironmentEnhancementManager` computes
   the IDs it matches environment-enhancement lookups against, so sampled
   paths are identical to Chroma's in-game view. Ring transforms include
   their first movement update, exactly as Chroma sees them.
4. The boundary traversal covers every populated manager slot and records
   every original inner-list index, including null tombstones.
5. The completed snapshot is split by actual MonoBehaviour identity, replaces
   the environment's prior paired files, and removes its obsolete combined file
   for that `Application.version`.

The log records the frame on which capture was armed and the boundary that
produced the snapshot. This is retained as diagnostic evidence until repeat
dumps prove that registration indexes and root paths are stable.

The output paths are:

```text
<Beat Saber>/UserData/LightIdDumper/<Application.version>/<EnvironmentName>_BehaviorLights.json
<Beat Saber>/UserData/LightIdDumper/<Application.version>/<EnvironmentName>_OtherLights.json
```

`Application.version` can include a game build suffix, such as
`1.44.1_20239`. The verifier searches both the plain-version and
version-with-build-suffix directories and selects the newest matching capture.

### Format 4 field layout

Both classified files have the same root fields:

- `formatVersion`, currently and exclusively `5`;
- `environmentName` and the exact `Application.version` in `gameVersion`;
- `lightManagerPath`;
- `initialRegisteredLightCount`, the unsplit count observed at setup;
- `totalRegisteredLightCount`, the count in this classified file;
- `lightIdSlots`.

Every slot contains `beatSaberLightId`, `commonGameObjectPath`,
`registeredLightCount`, and `registeredLights`. Every registered-light record
in either file contains:

- `indexWithinLightIdList`, preserving the original possibly sparse manager-list
  index;
- `componentLightId`;
- slot-derived `type` and `typeName`;
- `relativeGameObjectPath` and `componentType`.

`BehaviorLights` then adds direct `gameObjectPath`, `localScale`, and
`sceneName` fields. `OtherLights` instead adds
`ownerGameObjectPath`, `ownerComponentType`, `indexWithinOwner`, the owner's
local-scale/scene fields, and optional wrapper values
`intensity`, `bakeId`, and `weight`. Class-specific nulls remain explicit, but
fields that cannot apply to an entire classified file are omitted. The filename
is the classification; format 5 has no redundant per-record behaviour flag.

### Path identity

For MonoBehaviour light implementations, the dump records:

- exact scene/root/sibling hierarchy path;
- the path relative to the slot's longest common hierarchy prefix;
- concrete component type;
- local scale;
- scene name.

The full path uses Chroma's `Scene.[siblingIndex]Name...` convention. Root and
sibling indexes are version-sensitive. In the current runtime dump, the first
small ring can be `GameCore.[1]ConeRing(Clone)`, while ChroMapper's exported asset
uses `GameCore.[509]ConeRing(Clone)` for the corresponding entity.

The verifier therefore uses exact paths first, then removes only numeric sibling
indexes and requires matching component identity. Repeated normalized clone
paths are consumed in stable editor/list order because runtime position values
are intentionally unavailable.

Unity instance IDs, active state, and registration state were intentionally
removed from format 5 because they were either run-unstable or constant and did
not contribute durable mapping identity.

### BehaviorLights versus OtherLights

`BehaviorLights` is the GameObject-backed set used by ordinary Heck/Chroma
light-ID tables. The table's runtime value is an
`indexWithinLightIdList`, and normal verification expects that index to resolve
to a `LightWithIdMonoBehaviour` record in this file. Other MonoBehaviour render
companions may also appear in the file as inventory even when they have no
individual authored Chroma ID.

`OtherLights` contains registered `ILightWithId` implementations that are not
Unity components. They are not ordinary stable Chroma-table fixtures and do not
participate in normal entity matching. However, they are not necessarily beyond
Chroma control: the documented Environment Enhancement `ILightWithId`
[`lightID` and `type` fields](https://heck.aeroluna.dev/environment/environment/#components)
can be applied through the matching GameObject's `LightWithIds` owner. Chroma's
customizer enumerates that owner's nested `_lightWithIds` children, unregisters
and re-registers them as needed, and assigns the requested ID/event type. A
standard lighting event can then select the requested ID with its documented
[`lightID` property](https://heck.aeroluna.dev/items/events/#standard-lights).

That enhancement-time capability does not reclassify the child. It remains a
plain C# wrapper with owner-derived identity and will still be captured in
`OtherLights`. A null tombstone has no object to configure and exists only to
preserve the original list index.

### Nested non-MonoBehaviour schema

`RuntimeLightWithIds+LightIntensitiesWithId` and
`LightmapLightsWithIds+LightIntensitiesWithId` are not MonoBehaviours. They have
no component GameObject. Each wrapper child does, however, retain a private
`_parentLightWithIds` reference to its owning MonoBehaviour. Format 4 uses the
`OtherLights` filename as that classification and records:

- `ownerGameObjectPath` and the owner's transform fields;
- `ownerComponentType`;
- `indexWithinOwner`, found by reference identity in `owner.lightWithIds`;
- optional `intensity`, `bakeId`, and `weight` child values.

`BehaviorLights` and `OtherLights` retain original manager-list indexes, which
become sparse rather than shifting after the split. The filename is the sole
classification; the redundant per-record flag is omitted. The verifier uses BehaviorLights
for normal fixture comparison and uses OtherLights only to detect bad mapping
targets. Any Heck/Chroma index or ChroMapper `arrayId` mapping that resolves to
OtherLights emits a dedicated error with the mapping and owner identity.

## How the verifier compares runtime, Heck, and ChroMapper

The comparison exporter is
[Export-LightIdMappingVerificationCsvs.ps1](../Export-LightIdMappingVerificationCsvs.ps1).
It consumes up to five files:

1. the latest format-5 BehaviorLights runtime dump;
2. its paired OtherLights diagnostic dump;
3. Heck/Chroma's runtime light-ID table, when one is authored;
4. ChroMapper's editor light-ID table, when one is authored;
5. ChroMapper's EnvironmentData, which supplies reconstructed manager lists,
   object paths, transforms, event-track names, and event-to-slot bindings.

Run it with:

```powershell
& C:\src\BeatSaberStuff\BeatSaberLightIdDumper\Verify-LightIdMappings.ps1 `
    -GameVersion 1.44.1 `
    -EnvironmentName KaleidoscopeEnvironment `
    -SummaryOnly `
    -FailOnWarning
```

`Verify-LightIdMappings.ps1` calls the exporter, then reads the four resulting
CSV perspectives and prints per-perspective affected-row counts plus aggregated
error/warning categories. Invoke `Export-LightIdMappingVerificationCsvs.ps1`
directly when only refreshed CSVs are wanted.

<!-- A fixed 25-environment list omitted hybrid environments, so automatic coverage now comes from authored tables plus serialized Basic Event bindings. -->
Omit `-EnvironmentName` to verify every captured environment with
Chroma-addressable Basic Event lights. An authored Heck or ChroMapper light-ID
table is definitive coverage. Without one, the exporter uses ChroMapper
EnvironmentData's `LightSwitchEventEffect` bindings and requires at least one
real runtime `BehaviorLight` in a bound slot. The shared player-platform `Feet`
and `RectangleFakeGlow` components do not make a pure GLS environment qualify.
Mixed environments do qualify: `TheSecondEnvironment`, for example, exports its
Basic Event buildings, logo, and runway slots while its GLS-only slots are left
out of every perspective. An older game version exports only qualifying members
that exist in its runtime corpus. Omit `-GameVersion` as well to verify every
archived version. The exporter prefers `RuntimeLightData/<version>` beside the
script and falls back to the game installation's capture directory.

Each covered exporter comparison writes
`<version>_<environment>_DumpBehaviorLights.csv`,
`<version>_<environment>_DumpOtherLights.csv`,
`<version>_<environment>_ChroMapper.csv`, and
`<version>_<environment>_Chroma.csv` beneath
`LightMappingValidation/<version>/<environment>/`. Version, environment, and
perspective identity are encoded only in the filename. Each perspective has a
purpose-specific schema with one row per source entry. Target columns explicitly
name the perspective they resolve into, while irrelevant always-empty columns
are omitted. Applicable table targets, full inventory counterparts,
entity/component comparison results, per-category error/warning Booleans, and
aggregate validation flags remain available. `tableTargetMatchesInventory` and
`warningTableTargetDiffersFromInventory` specifically expose cases where the
authored Chroma mapping and the entity reconstructed from the current runtime
dump identify different list entries. `beatSaberLightId` sits immediately next
to the renamed `beatSaberIndexInLightIdsList` column. Use
`-LightMappingValidationPath` to
redirect this output.

The Chroma perspective contains only keys authored in Heck's Chroma table.
ChroMapper-only keys stay in the ChroMapper perspective and are marked as
missing from Chroma there. Because membership is proven by the source
perspective, Chroma CSVs omit the tautological `existsInChromaTable`,
`warningMissingFromChromaTable`, and `notMappedByChroma` columns. They also omit
duplicate aliases for the Chroma-table runtime target, Chroma/ChroMapper
membership agreement, and the inverse of `warningMissingFromChroMapperTable`.
<!-- Heck and ChroMapper use raw list-index identity when no remap table is authored, so tableless environments must not lose their usable Chroma IDs. -->
Gaga, Spoooky, The Second, and other tableless hybrid environments can still
have runtime and ChroMapper EnvironmentData inventories without an authored
Heck/Chroma or ChroMapper light-ID table. They are still exported: both dump
perspectives are populated, Chroma derives identity mappings from raw Beat
Saber BehaviorLight manager indexes, and ChroMapper derives identity mappings
from non-array-wrapper editor indexes. Source-coverage warnings keep both absent
authored tables explicit.

Verification occurs in two layers.

### Direct-address mapping verification

For every unioned `(beatSaberLightId, chromaLightId)` key, the verifier:

1. requires the key to exist in both Heck and ChroMapper tables;
2. resolves Heck's value into the captured runtime slot;
3. resolves ChroMapper's value into its reconstructed editor slot;
4. verifies that both resolve to the same entity by normalized hierarchy path,
   component identity, and stable list ordering;
5. reports duplicate target indices, missing slots, out-of-range indices, entity
   mismatches, and event-type mismatches.

### Full component-inventory verification

After the 200 directly mapped representatives are proven, the verifier also
matches all GameObject-backed MonoBehaviour companion components. This prevents
tube renderers or other visible support components from silently disappearing
while avoiding the old error of treating plain `LightIntensitiesWithId`
wrappers as fixtures. OtherLights wrappers never enter this inventory pass.
Instead, their original slot/index identities are checked against all
Heck/Chroma mappings, while ChroMapper `arrayId` targets are checked separately;
either mapping into OtherLights is an error. A path-backed MonoBehaviour
component missing from either runtime or ChroMapper remains a warning.

Counts and discrepancies are intentionally read from the generated CSVs rather
than documented as a fixed snapshot, because they change when either the game
assets or one of the checked-in mapping tables changes.

## Cross-version remapping workflow

The stable quantity is the authored Chroma ID and its resolved entity identity,
not either table's right-hand index.

To create a Heck table for a new game version:

1. Capture the source and target game versions at runtime.
2. For each source Heck table entry, resolve
   `(beatSaberLightId, chromaLightId)` to the source dump's
   `indexWithinLightIdList` record.
3. Match that source record to the target dump using exact path first, then
   normalized path, component type, and neighboring registration
   evidence.
4. Read the target record's `indexWithinLightIdList`.
5. Keep the same authored Chroma ID and write the target runtime index as the new
   Heck value.
6. Warn instead of guessing when a source entity is missing, duplicated, or
   ambiguous.

To update ChroMapper, independently find the same fixture in ChroMapper's
reconstructed manager list and write its editor-list index. Never copy Heck's
runtime value into the ChroMapper table merely because the keys match.

## Practical conclusions

- Repeated `componentLightId` values are expected; they identify an outer group,
  not a unique fixture.
- The runtime inner-list index is the Heck table value and is registration-order
  sensitive.
- The ChroMapper table value belongs to a separate editor reconstruction index
  space.
- Semantic light-group names come from event-track metadata joined through
  `LightSwitchEventEffect`, not from cone hierarchy names.
- `ConeRing(Clone)` can contribute to several logical groups because separate
  components on the same asset use different light IDs.
- A single logical group can span several asset families, as Kaleidoscope slot 5
  does with small-ring spike tops and distant `ConeRingBig` lasers.
- Chroma targets one table-selected component for a modern custom `lightID`, but
  whole-group events update every registered component in the slot.
- Companion renderers are real inventory and must be compared, but their lack of
  direct table entries is not by itself a mapping error.
- BehaviorLights are the stock Chroma light-ID table targets. OtherLights are
  excluded from those tables, but real owner-backed wrappers may still receive
  a map-specific `lightID` and `type` through Chroma Environment Enhancements.
- Null direct GameObject fields on non-MonoBehaviour wrappers are correct; their
  owner fields and manager-list positions must still be present.
- Format 4 omits globally constant registration/active-state fields, uses the
  filename instead of a per-record behavior flag, and emits only direct fields
  in BehaviorLights or owner/wrapper fields in OtherLights.
- `type`/`typeName` are derived from the slot's loaded
  `LightSwitchEventEffect`, and the verifier compares them with ChroMapper's
  serialized event-type binding.
- Version-sensitive sibling indexes require component identity and stable
  registration ordering before normalized paths can be paired.

## Automated environment traversal

`DumpAllEnvironmentsController` is created only when Beat Saber receives
`--dump-all-light-ids`. Before launch, `DumpAllLightIds.ps1` creates a temporary
map from the first installed custom map's audio and cover. It supplies a clean
V2 `Info.dat` and one empty Easy difficulty with no notes, events, requirements,
or custom data. Hard links avoid copying the media when supported. Its
`000_LightIdDumperGenerated-<version>` name sorts first, so after the normal menu
and SongCore scan the controller deterministically selects it as the donor.

The controller reads Beat Saber's complete standard/circle environment catalog
and creates one synthetic launch candidate per entry. Every candidate reuses
the donor difficulty, but a batch-only Harmony patch makes that difficulty's
normal environment lookup return the target catalog environment. Legacy games
receive the target `EnvironmentInfoSO` from
`BeatmapEnvironmentHelper.GetEnvironmentInfo`; modern games receive the target
`EnvironmentName` from `BeatmapLevel.GetEnvironmentName`, including deferred
beatmap-loading calls. `OverrideEnvironmentSettings` is passed as `null`, so
`usingOverrideEnvironment` remains false and Beat Saber follows its ordinary
per-difficulty scene initialization path. Tutorial and Multiplayer remain
excluded because they are special game modes.
It launches that difficulty through `MenuTransitionsHelper.StartStandardLevel`,
waits for `LightDumpCapture.DumpCompleted`, then calls the active
`StandardLevelReturnToMenuController.ReturnToMenu` and waits for the normal scene
pop before continuing. Tutorial and Multiplayer are special scenes rather than
selectable standard-map environments and are intentionally absent.

The controller reflects only at this startup/lifecycle boundary because Beat
Saber changed custom-level, `BeatmapKey`, transition-helper, and environment
model APIs across the supported versions. On 1.29/1.34 it passes SongCore's
`CustomPreviewBeatmapLevel` directly to Beat Saber's injected
`CustomLevelLoader.LoadCustomBeatmapLevelAsync`. Direct loading is necessary
because those SongCore versions can report `AreSongsLoaded` before
`BeatmapLevelsModel` has synchronized its preview-ID cache. The returned
`CustomBeatmapLevel` keeps its playable `IDifficultyBeatmap` objects under
`beatmapLevelData.difficultyBeatmapSets`; they are not properties of the level
wrapper itself. Newer SongCore levels expose `BeatmapKey` values directly. Beat Saber 1.44.2 also changed
`MenuTransitionsHelper` from a
MonoBehaviour into an injected plain object, so it is resolved through
`MainFlowCoordinator`. No discovery runs in a lighting hot path.

Each run writes `_dump-all-status.json` containing the exact game version,
start/finish UTC times, current dump format, every expected environment, both
classified output paths and counts, completion state, and any fatal error. The
controller exits the game after complete success or a terminal batch failure.

When returning from a captured level, `MenuTransitionsHelper` begins the normal
`GameScenesManager.PopScenes` transition before later `didFinishEvent`
subscribers run. If one of those unrelated subscribers throws after
`isInTransition` becomes true, the controller records a warning and continues
waiting for the already-started menu transition. An exception before the
transition starts remains a terminal error.

The repository-local [`DumpAllLightIds.ps1`](../DumpAllLightIds.ps1) owns the
outer multi-version sequence. With no `-Version`, it runs every installed
supported version. It
prints and uses BSManager's exact `--no-yeet -vrmode oculus fpfc` launch prefix,
injects BSManager's `SteamAppId`, `SteamOverlayGameId`, and `SteamGameId`
environment values (`620980`) so Steamworks accepts the direct instance launch,
waits for the matching game executable to exit before starting the next,
validates both files' current timestamps, classifications, sparse manager
indexes, and format-5 invariants,
invokes mapping verification only when `-Verify` is passed and corresponding
Heck and ChroMapper data exist,
checks the authoritative live log, copies only the paired light-data files to
`RuntimeLightData/<version>` (or a caller-supplied `-OutputPath`), removes any
legacy archived status manifest, removes the generated donor directory, and
uninstalls in `finally`. The transient `_dump-all-status.json` remains only in
the game installation for validation and diagnostics.

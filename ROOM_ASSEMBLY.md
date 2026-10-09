# Room Assembly

## Start here

In a Room3D's Scene Settings, enable **Room Assembly**, then choose **Edit Room Assembly**. A new definition is created if none is assigned. Definitions can be reused; editing a shared definition affects all rooms that reference it. Linked Room3Ds inherit their linked root's definition and enablement.

1. **Pick room** selects a container and adds its direct geometry children. While picking, **Tab** cycles through ancestors, allowing a Model or Folder to be selected. **Pick component** adds an individual part or container. Repeat to include multiple objects.
2. Review suggested roles in the left-hand tree. Classification is only a suggestion. Do not select both a container and its descendants as independent source components: that would assign the same part twice.
3. The **Generate** split button writes a role-based choreography. Use its arrow to choose **Generate**, a restrained saved **Randomize variation**, or **Repeat last variation**; the main button then becomes that selected action. These replace motions/timings after confirmation; they do not alter source geometry. Reordering components changes the stagger order used by the next Generate.
4. Adjust each component's recipe, timing, pivot, travel, rotation, overshoot, and settling. A source-free **Group** is a virtual animation parent (similar to an editor-only Folder): it has no map geometry of its own, but its children inherit its transform. Select the group and use **Pick child component**, or select a component and choose **Create parent group**. Use **Set direct children to Follow only** when children should use only the group's movement.
5. **Play / Pause**, **Replay**, or drag the scrub bar. **S / I / F** jump directly to a component's Start, Impact, or fully Settled marker. **Final room** ends preview and restores the authored room and camera. **Compare** swaps between the current construction pose and the real final room without rebuilding. **Back/Escape** returns to the prior editor screen. **Save** persists the definition and, when opened from Scene Settings, the scene's assignment.

The left panel is the **Room Definition** list. It deliberately stays compact: it shows the editable group/component name only. The selected item's exact source path and sibling ordinal live in the inspector, so repeated `Part` names stay distinguishable without making every row tall. Selecting a component there outlines its assembled preview geometry in gold; it does **not** change the scrub time or take over the fly camera. Clicking already-added geometry in the clear centre preview selects the matching Room Definition component and scrolls its row into view. Clicking unrelated geometry does not add it; use **Pick component** for that.

The workspace includes **Undo/Redo** for the current editing run, **Validate** for missing/ambiguous bindings and timing-graph problems, **Copy/Paste motion**, **Reset motion**, and **Duplicate** to branch a shared room definition into an independent choreography. Undo history is intentionally temporary; Save persists the definition itself.

Presets → **Room Assembly** also includes a disposable **pop-up room benchmark**. Its generated walls, floor, desk, chair, ceiling, and lamp exist only until the workspace is closed. Use it to tune motion; save its choreography as a reusable template, not as world bindings.

## Motion controls

- Directions and virtual-pivot offsets are in the source object's rest-pivot coordinate system. They never change its authored pivot.
- A virtual group without a source uses its parent's rest pivot (or the final camera for a root group).
- **Orientation** uses shortest-path CFrame interpolation. **Rotation axis/angle** is a separate unwrapped hinge channel, supporting turns greater than 180 degrees.
- **Impact fraction** divides travel from settling. **Anticipation fraction** adds a short preparatory motion. The default **Bounce** settle uses directional overshoot—the actual fold axis for walls/floors or travel direction for props—so rigid geometry rebounds naturally. **Wobble** is an opt-in angular treatment for lighter objects, with separate wobble, oscillation, and damping controls.
- Movement and rotation curves use cubic Bezier control points `x1,y1,x2,y2`. Time coordinates are clamped to 0–1; value coordinates may overshoot.
- **Synchronize** starts a component relative to another group's Start, Impact, or Settled marker, plus a signed offset. Circular dependencies, missing groups, and resulting negative start times are rejected.
- Parent transforms are applied before child transforms. Each leaf owns its geometry exactly once.
- **Ghost / pivot / path guides** shows final bounds, hinge-axis dots, and sampled paths. **Solo selected** filters the selected group and descendants during preview. Guides and solo are editor-only and are not saved.

## Panels and presets

Panel X/Z counts subdivide one rectangular Part in its local X/Z plane; 2×1 gives two halves, larger counts give strips/grids. Mirror folds pairs their rotation directions. Counts default to 1 (no subdivision). Individual panel hinges are generated at panel edges; the ordinary component pivot controls unsplit geometry. Prepare vertical walls with an appropriate local orientation if subdividing them.

Plain materials and repeating Textures are supported. Single-image Decals, embedded meshes, SurfaceAppearance, and attached fixtures need separately prepared geometry rather than runtime cutting. MeshParts can move as whole rigid components, but cannot be subdivided.

**Save motion as preset** stores one component's recipe. **Save choreography as preset** stores role-based motions and camera settings without source references. Applying choreography maps matching roles in order and remaps timing dependencies. If a timing role is absent, its resolved start time is used. It does not import another room's bindings or parent IDs. Existing room-specific hierarchy/pivots are retained.

## Runtime behavior

Destination preparation happens behind the transition. For Fade to Black and Enter, the assembly clock begins as soon as the destination is switched at full black, so construction runs underneath the fade-out rather than freezing on its first frame. Dialog still waits for both the transition and assembly to finish (or an empty Room3D enters AWAIT). Click/advance during Assembly finishes it immediately. Source collision geometry stays in place and player movement/interactions remain phase-locked.

Normal entries replay assembly. **Merge never does** and retains the existing Zoom/camera/character state. Fade to Black, Cut, and valid Enter transitions work directly. Other incoming transition kinds use Fade to Black with an Output warning. Authored transition selections are not rewritten.

Room assembly does not absorb placed characters into room geometry. The character layer is held hidden during construction, then restores its prior fade state. Characters removed earlier in the playthrough remain removed.

Runtime serialization includes assembly elapsed time. Restore rebuilds and seeks the assembly without replaying earlier sound cues. Await restores skip assembly.

## Safety and limitations

- Geometry must be anchored, Archivable, and free of embedded scripts. Characters and dynamic geometry are not supported as assembly components.
- Name/class paths are resolved strictly. Duplicate names can use unique saved positions; ambiguous geometry refuses to animate. A unique **VNAssemblyId** string authored into the original Studio place can provide a durable binding. The editor never assumes client-added attributes survive Studio restarts.
- Missing required geometry aborts assembly before hiding sources. Optional missing geometry produces a warning and is omitted.
- The renderer uses temporary, noncollidable, nonqueryable client copies. Sources' transforms are never moved. Visibility and light/effect state are restored on completion, cancellation, and errors.
- **Backdrop** adds a temporary dark enclosure; **additional objects to hide** explicitly excludes unwanted neighboring scenery. Other map objects are never automatically hidden.
- Source geometry must remain static while previewing/playing assembly. Streamed-out or deleted required objects must be restored/rebound before playback.
- Arbitrary mesh cutting, skinned mesh deformation, editable graph-curve handles, and automatic room-semantic recognition are not provided. Motion curves currently use numeric control points; pivots use numeric/edge/surface picking plus visual guides.

## Verification

`tests/assembly-schedule.luau` runs with the standalone Luau CLI. It checks schedule compilation, overlapping dependencies, panel-stagger duration, cycle rejection, exact scalar endpoints, and deterministic motion sampling at 30/60/144 samples per second.

For Roblox engine checks, require `VNSceneEditor.Runtime.AssemblyTests` on the **client** and call `.run()`. This opt-in module tests actual CFrames, visibility cleanup, clone alignment, ambiguity rejection, panel generation, and JSON persistence; its temporary test geometry is removed afterward.

Also playtest real rooms using Fade to Black, Enter, Cut, Merge, direct linked-room entry, and cancellation during both reveal and assembly. Inspect texture seams, shadows, camera clearance, performance, and final handoffs in Studio. Compilation and standalone tests do not substitute for this visual QA.

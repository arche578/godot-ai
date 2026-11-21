"""Headless Blender cleanup for asset_cleanup (top-down shooter tools).

Run by the Godot tool as:

    blender -b --factory-startup --python asset_cleanup.py -- <job.json>

The job file says what to load, how to fix it and where to write. The
script never touches the source file: it imports it into an empty scene,
then rotates the model so its front faces Godot's -Z, scales it to a real
size in meters, moves the origin (bottom center, or the grip for weapons),
cuts triangles down to a budget, shrinks oversized textures, adds a Muzzle
point to weapons and exports one .glb. Every number in the report is in
Godot axes (X right, Y up, -Z forward) and meters.

The report JSON is always written (ok: false with an error on failure), so
the caller can tell a crash before the script ran from a failed cleanup.
Works with Blender 3.6 to 5.x and with the `bpy` Python module.
"""

import json
import math
import os
import sys
import traceback

import bpy
from mathutils import Matrix, Vector

# Godot (glTF) axes -> Blender axes. The glTF importer maps glTF/Godot
# (x, y, z) to Blender (x, -z, y), and the exporter maps it back.
G2B = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
B2G = G2B.transposed()

AXES = {
    "+x": Vector((1, 0, 0)),
    "-x": Vector((-1, 0, 0)),
    "+y": Vector((0, 1, 0)),
    "-y": Vector((0, -1, 0)),
    "+z": Vector((0, 0, 1)),
    "-z": Vector((0, 0, -1)),
}

DEFAULTS = {
    # kind: (size_mode, size, max_triangles, max_texture, origin, forward)
    "weapon": ("length", 0.7, 5000, 512, "grip", "auto"),
    "item": ("max", 0.3, 2000, 512, "bottom_center", "+z"),
    "prop": ("keep", 0.0, 5000, 512, "bottom_center", "+z"),
    "character": ("height", 1.8, 15000, 1024, "bottom_center", "+z"),
}


# Weapon direction from the top-down principal axis (see _guess_weapon_forward).
PCA_SAMPLE = 60000
PCA_MIN_ELONGATION = 1.5
SNAP_DEGREES = 3.0


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        print("asset_cleanup.py: pass the job .json path after --", file=sys.stderr)
        sys.exit(2)
    with open(argv[0], "r", encoding="utf-8") as f:
        job = json.load(f)
    report = {"ok": False, "blender_version": bpy.app.version_string, "warnings": []}
    try:
        run(job, report)
        report["ok"] = True
    except CleanupError as e:
        report["error"] = str(e)
    except Exception as e:  # noqa: BLE001 - every failure goes to the report
        report["error"] = "%s: %s" % (type(e).__name__, e)
        report["traceback"] = traceback.format_exc()
    out = job.get("report_path") or (os.path.splitext(argv[0])[0] + "_report.json")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    print("asset_cleanup: %s -> %s" % ("ok" if report["ok"] else "failed", out))


class CleanupError(Exception):
    pass


def run(job, report):
    source = job["source"]
    output = job["output"]
    kind = job.get("kind", "prop")
    if kind not in DEFAULTS:
        raise CleanupError("unknown kind '%s'" % kind)
    d_mode, d_size, d_tris, d_tex, d_origin, d_forward = DEFAULTS[kind]
    size_mode = job.get("size_mode") or d_mode
    size = float(job.get("size") or d_size)
    max_tris = int(job.get("max_triangles") or d_tris)
    max_tex = int(job.get("max_texture") or d_tex)
    origin_mode = job.get("origin") or d_origin
    forward = (job.get("forward") or d_forward).lower()
    up = (job.get("up") or "+y").lower()
    yaw = float(job.get("yaw_degrees") or 0.0)
    add_muzzle = job.get("muzzle", kind == "weapon")
    warnings = report["warnings"]

    if not os.path.isfile(source):
        raise CleanupError("source file not found: %s" % source)

    _reset_scene()
    _import(source)
    _remove_unwanted()

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise CleanupError("the file has no mesh")
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    rigged = bool(armatures)
    report["source"] = {
        "file": source,
        "objects": len(bpy.data.objects),
        "meshes": len(meshes),
        "materials": sorted({m.name for o in meshes for m in o.data.materials if m}),
        "triangles": _triangles(meshes),
        "bones": sum(len(a.data.bones) for a in armatures),
        "animations": sorted(a.name for a in bpy.data.actions),
        "size": _g(_bounds(meshes)[2]),
    }

    # --- 1. orientation ------------------------------------------------------
    up_v = AXES.get(up)
    if up_v is None:
        raise CleanupError("'up' must be one of %s" % ", ".join(AXES))
    fwd_v = None
    if forward == "auto":
        if kind == "weapon":
            forward, how, fwd_v = _guess_weapon_forward(meshes, up_v)
            report["forward_detected"] = how
        else:
            forward = "+z"
    if fwd_v is None:
        fwd_v = AXES.get(forward)
    if fwd_v is None:
        raise CleanupError("'forward' must be auto or one of %s" % ", ".join(AXES))
    if abs(fwd_v.dot(up_v)) > 0.5:
        raise CleanupError("'forward' (%s) and 'up' (%s) must be different axes" % (forward, up))
    rot_g = _frame_rotation(fwd_v, up_v)
    if yaw:
        rot_g = Matrix.Rotation(math.radians(yaw), 3, "Y") @ rot_g
    rot_b = (G2B @ rot_g @ B2G).to_4x4()
    _transform_roots(rot_b)
    report["rotation"] = {"forward_was": forward, "up_was": up, "yaw_degrees": yaw}

    # --- 2. scale ------------------------------------------------------------
    lo, hi, dims = _bounds(meshes)
    g_dims = _g(dims)  # [width x, height y, length z]
    factor = 1.0
    if size_mode != "keep":
        axis = {"width": 0, "height": 1, "length": 2}.get(size_mode)
        measured = (
            max(g_dims) if size_mode == "max" else (g_dims[axis] if axis is not None else None)
        )
        if measured is None:
            raise CleanupError("'size_mode' must be height, length, width, max or keep")
        if size <= 0:
            raise CleanupError("'size' must be above 0")
        if measured <= 1e-6:
            raise CleanupError(
                "the model is flat along the %s axis; pick another size_mode" % size_mode
            )
        factor = size / measured
        _transform_roots(Matrix.Scale(factor, 4))
    report["scale"] = {
        "mode": size_mode,
        "target": size if size_mode != "keep" else None,
        "factor": round(factor, 6),
    }

    if not rigged:
        _bake_transforms()

    # --- 3. triangle budget --------------------------------------------------
    before = _triangles(meshes)
    if max_tris > 0 and before > max_tris:
        ratio = max(0.02, max_tris / float(before))
        for o in meshes:
            _decimate(o, ratio)
        after = _triangles(meshes)
        # Collapse can land above the target on small meshes; one more pass.
        if after > max_tris * 1.05:
            for o in meshes:
                _decimate(o, max(0.02, max_tris / float(after)))
            after = _triangles(meshes)
        report["decimated"] = {"from": before, "to": after, "budget": max_tris}
        if after > max_tris * 1.1:
            warnings.append("triangles %d are still above the budget %d" % (after, max_tris))

    # --- 4. origin -----------------------------------------------------------
    lo, hi, dims = _bounds(meshes)
    g_lo, g_hi = _g_box(lo, hi)
    g_center = [(g_lo[i] + g_hi[i]) / 2.0 for i in range(3)]
    if origin_mode == "bottom_center":
        origin_g = [g_center[0], g_lo[1], g_center[2]]
    elif origin_mode == "center":
        origin_g = g_center
    elif origin_mode == "grip":
        origin_g = _guess_grip(meshes, g_lo, g_hi)
    elif origin_mode == "keep":
        origin_g = [0.0, 0.0, 0.0]
    else:
        raise CleanupError("'origin' must be bottom_center, center, grip or keep")
    _transform_roots(Matrix.Translation(G2B @ Vector(origin_g)).inverted())
    if not rigged:
        _bake_transforms()
    report["origin"] = {"mode": origin_mode, "moved_by": _round(origin_g)}

    # --- 5. textures ---------------------------------------------------------
    report["textures"] = _shrink_textures(max_tex, warnings)

    # --- 6. muzzle -----------------------------------------------------------
    if add_muzzle:
        report["muzzle"] = _place_muzzle(meshes)

    # --- 7. export -----------------------------------------------------------
    lo, hi, dims = _bounds(meshes)
    g_lo, g_hi = _g_box(lo, hi)
    report["result"] = {
        "file": output,
        "size": _round(_g(dims)),
        "bounds_min": _round(g_lo),
        "bounds_max": _round(g_hi),
        "triangles": _triangles(meshes),
        "materials": len({m.name for o in meshes for m in o.data.materials if m}),
        "bones": sum(len(a.data.bones) for a in armatures),
        "animations": sorted(a.name for a in bpy.data.actions),
    }
    _check_size(kind, report["result"]["size"], warnings)
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    _export(output, bool(bpy.data.actions))
    if not os.path.isfile(output):
        raise CleanupError("Blender did not write %s" % output)
    report["result"]["bytes"] = os.path.getsize(output)


# --- scene ---------------------------------------------------------------------


def _reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for coll in (
        bpy.data.objects,
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.images,
        bpy.data.actions,
    ):
        for block in list(coll):
            coll.remove(block)


def _import(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext == ".obj":
        if hasattr(bpy.ops.wm, "obj_import"):
            bpy.ops.wm.obj_import(filepath=path)
        else:
            bpy.ops.import_scene.obj(filepath=path)
    elif ext == ".blend":
        with bpy.data.libraries.load(path) as (src, dst):
            dst.objects = list(src.objects)
        for o in dst.objects:
            if o is not None:
                bpy.context.scene.collection.objects.link(o)
    else:
        raise CleanupError("unsupported file type %s (use .glb, .gltf, .fbx, .obj or .blend)" % ext)


def _remove_unwanted():
    for o in list(bpy.data.objects):
        if o.type in ("CAMERA", "LIGHT", "SPEAKER", "LIGHT_PROBE"):
            bpy.data.objects.remove(o, do_unlink=True)


def _roots():
    return [o for o in bpy.context.scene.objects if o.parent is None]


def _transform_roots(m):
    for o in _roots():
        o.matrix_world = m @ o.matrix_world
    bpy.context.view_layer.update()


def _bake_transforms():
    """Applies every object's transform to its mesh data (static models)."""
    view = bpy.context.view_layer
    for o in bpy.context.scene.objects:
        o.hide_set(False)
        o.hide_select = False
    bpy.ops.object.select_all(action="SELECT")
    view.objects.active = next((o for o in bpy.context.scene.objects if o.type == "MESH"), None)
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    if meshes:
        view.objects.active = meshes[0]
        bpy.ops.object.make_single_user(object=True, obdata=True)
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # Empties left from the import hierarchy carry nothing once meshes are
    # baked; keep only named markers (Muzzle and friends).
    for o in list(bpy.context.scene.objects):
        if o.type == "EMPTY" and not o.children and "muzzle" not in o.name.lower():
            bpy.data.objects.remove(o, do_unlink=True)
    view.update()


# --- measuring -------------------------------------------------------------------


def _world_verts(meshes):
    for o in meshes:
        m = o.matrix_world
        for v in o.data.vertices:
            yield m @ v.co


def _bounds(meshes):
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for p in _world_verts(meshes):
        for i in range(3):
            lo[i] = min(lo[i], p[i])
            hi[i] = max(hi[i], p[i])
    if lo[0] == math.inf:
        raise CleanupError("the meshes have no vertices")
    return lo, hi, hi - lo


def _g(b):
    """Blender vector (or dims) -> Godot [x, y, z], unsigned for dims."""
    v = B2G @ Vector(b)
    return [abs(v[0]), abs(v[1]), abs(v[2])]


def _g_box(lo, hi):
    a = B2G @ lo
    b = B2G @ hi
    return [min(a[i], b[i]) for i in range(3)], [max(a[i], b[i]) for i in range(3)]


def _g_point(p):
    return list(B2G @ Vector(p))


def _round(v, n=4):
    return [round(float(x), n) for x in v]


def _triangles(meshes):
    total = 0
    for o in meshes:
        for poly in o.data.polygons:
            total += max(0, len(poly.vertices) - 2)
    return total


# --- weapon heuristics -----------------------------------------------------------


def _guess_weapon_forward(meshes, up_v):
    """The long horizontal direction is the barrel; its thinner end is the front.

    The direction is the principal axis of the vertices seen from above, so a
    model exported at an angle (not along X or Z) is still straightened; it
    snaps to the nearest axis when within SNAP_DEGREES. The thin end is the
    one whose last 12% of length has the smaller cross section (the stock and
    grip are bulky). Returns (label, explanation, forward vector in Godot
    axes)."""
    pts = [B2G @ p for p in _world_verts(meshes)]
    if len(pts) > PCA_SAMPLE:
        step = len(pts) / PCA_SAMPLE
        pts = [pts[int(i * step)] for i in range(PCA_SAMPLE)]
    up_axis = max(range(3), key=lambda i: abs(up_v[i]))
    h0, h1 = [i for i in range(3) if i != up_axis]
    n = float(len(pts))
    ma = sum(p[h0] for p in pts) / n
    mb = sum(p[h1] for p in pts) / n
    caa = sum((p[h0] - ma) ** 2 for p in pts) / n
    cbb = sum((p[h1] - mb) ** 2 for p in pts) / n
    cab = sum((p[h0] - ma) * (p[h1] - mb) for p in pts) / n
    theta = 0.5 * math.atan2(2.0 * cab, caa - cbb)
    # Eigenvalues: how elongated the top-down silhouette is.
    mid = (caa + cbb) / 2.0
    rad = math.sqrt(max(0.0, ((caa - cbb) / 2.0) ** 2 + cab * cab))
    l1, l2 = mid + rad, max(1e-12, mid - rad)
    if l1 / l2 < PCA_MIN_ELONGATION:
        # Nearly round from above: fall back to the longer bounding-box side.
        lo = [min(p[i] for p in pts) for i in (h0, h1)]
        hi = [max(p[i] for p in pts) for i in (h0, h1)]
        theta = 0.0 if hi[0] - lo[0] >= hi[1] - lo[1] else math.pi / 2.0
    # Snap to an axis when the tilt is small: keeps axis-aligned models exact.
    nearest = round(theta / (math.pi / 2.0)) * (math.pi / 2.0)
    tilt = math.degrees(theta - nearest)
    if abs(tilt) <= SNAP_DEGREES:
        theta = nearest
        tilt = 0.0
    u = (math.cos(theta), math.sin(theta))
    w = (-u[1], u[0])

    def coords(p):
        a, b = p[h0] - ma, p[h1] - mb
        return a * u[0] + b * u[1], a * w[0] + b * w[1], p[up_axis]

    proj = [coords(p) for p in pts]
    t_lo = min(c[0] for c in proj)
    t_hi = max(c[0] for c in proj)
    band = (t_hi - t_lo) * 0.12

    def section(at_low):
        sel = [c for c in proj if (c[0] <= t_lo + band if at_low else c[0] >= t_hi - band)]
        if not sel:
            return math.inf
        side = max(1e-6, max(c[1] for c in sel) - min(c[1] for c in sel))
        tall = max(1e-6, max(c[2] for c in sel) - min(c[2] for c in sel))
        return side * tall

    low_area = section(True)
    high_area = section(False)
    sign = -1.0 if low_area < high_area else 1.0
    vec = [0.0, 0.0, 0.0]
    vec[h0] = sign * u[0]
    vec[h1] = sign * u[1]
    fwd = Vector(vec).normalized()
    names = "xyz"
    if tilt == 0.0:
        k = max(range(3), key=lambda i: abs(fwd[i]))
        label = ("-" if fwd[k] < 0 else "+") + names[k]
        where = "barrel along %s" % label
    else:
        label = "auto"
        where = "barrel along (%.3f, %.3f, %.3f), %.1f degrees off the nearest axis" % (
            fwd[0],
            fwd[1],
            fwd[2],
            abs(tilt),
        )
    return (
        label,
        "%s (end cross sections %.4g vs %.4g m2)"
        % (
            where,
            min(low_area, high_area),
            max(low_area, high_area),
        ),
        fwd,
    )


def _guess_grip(meshes, g_lo, g_hi):
    """Origin for a weapon: above the lowest part (grip/magazine), at mid height."""
    pts = [B2G @ p for p in _world_verts(meshes)]
    height = g_hi[1] - g_lo[1]
    low = [p for p in pts if p[1] <= g_lo[1] + height * 0.3]
    # Ignore the front half: a long magazine or a bipod under the barrel
    # should not pull the grip forward.
    mid_z = (g_lo[2] + g_hi[2]) / 2.0
    rear = [p for p in low if p[2] >= mid_z] or low
    x = sum(p[0] for p in rear) / len(rear)
    z = sum(p[2] for p in rear) / len(rear)
    return [x, g_lo[1] + height * 0.5, z]


def _place_muzzle(meshes):
    existing = [
        o for o in bpy.context.scene.objects if o.type == "EMPTY" and "muzzle" in o.name.lower()
    ]
    if existing:
        o = existing[0]
        o.name = "Muzzle"
        return {"source": "model", "position": _round(_g_point(o.matrix_world.translation))}
    pts = [B2G @ p for p in _world_verts(meshes)]
    zmin = min(p[2] for p in pts)
    zmax = max(p[2] for p in pts)
    tip = [p for p in pts if p[2] <= zmin + (zmax - zmin) * 0.04]
    x = sum(p[0] for p in tip) / len(tip)
    y = sum(p[1] for p in tip) / len(tip)
    pos_g = Vector((x, y, zmin))
    empty = bpy.data.objects.new("Muzzle", None)
    empty.empty_display_type = "SINGLE_ARROW"
    empty.empty_display_size = 0.1
    empty.location = G2B @ pos_g
    bpy.context.scene.collection.objects.link(empty)
    return {
        "source": "estimated (front-most point, center of the barrel tip)",
        "position": _round(pos_g),
    }


# --- budgets -----------------------------------------------------------------------


def _decimate(o, ratio):
    if ratio >= 0.999:
        return
    view = bpy.context.view_layer
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    view.objects.active = o
    mod = o.modifiers.new("Budget", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=mod.name)


def _shrink_textures(max_size, warnings):
    out = []
    for img in bpy.data.images:
        if img.type != "IMAGE":
            continue
        if img.size[0] == 0:
            if img.filepath or img.packed_file is None:
                warnings.append(
                    "texture %s is missing (%s); copy it next to the source file"
                    % (img.name, img.filepath or "no data")
                )
            continue
        w, h = img.size[0], img.size[1]
        entry = {"name": img.name, "size": [w, h]}
        if max_size > 0 and max(w, h) > max_size:
            k = max_size / float(max(w, h))
            nw, nh = max(1, int(round(w * k))), max(1, int(round(h * k)))
            try:
                img.scale(nw, nh)
                entry["resized_to"] = [nw, nh]
            except RuntimeError as e:
                warnings.append("could not resize texture %s: %s" % (img.name, e))
        if img.file_format != "PNG":
            _to_png(img, entry, warnings)
        out.append(entry)
    return out


def _to_png(img, entry, warnings):
    """Re-encodes a texture as PNG in the exported .glb.

    Blender 5.3 writes sRGB JPEGs with a color profile Godot's glTF loader
    rejects ("Couldn't load image ... image/jpeg"), which leaves the model
    white. The exporter re-encodes from pixels when the image is no longer
    backed by its original file, so pack the pixels as PNG first.
    """
    was = img.file_format
    try:
        img.file_format = "PNG"
        img.filepath_raw = os.path.splitext(img.filepath_raw or img.name)[0] + ".png"
        img.pack()
        entry["format"] = "png (was %s)" % was.lower()
    except RuntimeError as e:
        warnings.append("could not convert texture %s from %s to PNG: %s" % (img.name, was, e))


def _check_size(kind, size, warnings):
    biggest = max(size)
    if kind == "prop" and (biggest > 20 or biggest < 0.05):
        warnings.append(
            "the prop is %.3g m across; pass size (meters) and size_mode if that is wrong" % biggest
        )
    if kind == "weapon" and size[2] < size[0]:
        warnings.append(
            "the weapon is wider than it is long; check forward (the barrel should point along -Z)"
        )


def _export(path, animations):
    kwargs = dict(
        filepath=path,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_cameras=False,
        export_lights=False,
        export_animations=animations,
        export_extras=False,
    )
    try:
        bpy.ops.export_scene.gltf(**kwargs)
    except TypeError:
        # Older exporters lack some keywords.
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_yup=True)


def _frame_rotation(fwd, up):
    """Rotation (Godot axes) taking a model facing `fwd` with `up` to -Z / +Y."""
    back = -fwd
    right = up.cross(back)
    s = Matrix((right, up, back)).transposed()  # columns: right, up, back
    return s.transposed()  # inverse of an orthonormal basis


if __name__ == "__main__":
    main()

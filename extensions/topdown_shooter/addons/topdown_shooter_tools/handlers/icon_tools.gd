@tool
extends RefCounted

## item_icon_render: inventory icons from item models.
##
## For each item with a 3D model (item.model, or the rule folder
## res://assets/items/<id>/<id>.glb), renders the model with a fixed
## orthographic camera, the shared studio light and a transparent
## background into res://assets/icons/items/<item_id>.png, sized to the
## item's grid cells (grid_width x grid_height x cell_px). The longest
## side of the model is turned to lie across the icon, and a thin dark
## outline keeps it readable on the rarity-colored cell. Then it sets
## item.icon, suggests grid cells from the model's shape (apply_grid=true
## writes them), and teaches the project's inventory_ui.gd and hideout.gd to
## draw icons when they are older copies that only draw colored boxes.
##
## Rendering needs a GUI editor (a headless one has no renderer). Writes are
## one editor undo step (PNG files, item .tres files and patched scripts).

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const SwapTools := preload("res://addons/topdown_shooter_tools/handlers/swap_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")

const DEFAULT_ICON_DIR := "res://assets/icons/items"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const MAX_ITEMS := 64
const MAX_GRID := 6
## Frames to wait for one icon; the editor may draw slowly when unfocused.
const RENDER_WAIT_MSEC := 6000
const REPLY_MARGIN_MSEC := 5000
const ICON_EXT_ID := "icon_tex"

## The block both UI templates carry between these markers; older copies of
## inventory_ui.gd / hideout.gd get it inserted after their border line.
const UI_MARKER_BEGIN := "# --- item icon (item_icon_render) ---"
const UI_MARKER_END := "# --- end item icon ---"
const UI_PATCHES := [
	{"file": "inventory_ui.gd", "template": "inventory_ui.gd.tmpl", "anchor": "\t\tdraw_rect(rect, border, false, 2.0)\n"},
	{"file": "hideout.gd", "template": "hideout.gd.tmpl", "anchor": "\t\tcanvas.draw_rect(rect, border, false, 2.0)\n"},
]


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func item_icon_render(params: Dictionary, ctx = null) -> Dictionary:
	var p: Variant = read_params(params)
	if Util.is_error(p):
		return p
	var plan: Variant = make_plan(p)
	if Util.is_error(plan):
		return plan
	if p.dry_run:
		return {"data": dry_report(p, plan)}
	if plan.items.is_empty():
		return {"data": dry_report(p, plan)}
	if DisplayServer.get_name() == "headless" or not Engine.is_editor_hint():
		return Util.error(Util.EDITOR_NOT_READY, "item_icon_render needs a GUI Godot editor (a headless editor has no renderer); dry_run=true works anywhere")
	if ctx == null or not ctx.has_method("send_deferred"):
		return Util.error(Util.INTERNAL_ERROR, "item_icon_render renders over several frames; call it through MCP (deferred)")
	_run_async(p, plan, ctx)
	return {"_deferred": true}


func _run_async(p: Dictionary, plan: Dictionary, ctx) -> void:
	## The dispatcher registers a deferred request only after the tool
	## returns; start on the next frame so the reply is never dropped.
	await (Engine.get_main_loop() as SceneTree).process_frame
	var deadline := 0
	if "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		deadline = int(ctx.deadline_msec) - REPLY_MARGIN_MSEC
	var images := {}
	var notes := {}
	for it in plan.items:
		var r: Variant = await render_icon(it.model, it.grid if not p.apply_grid else it.suggested_grid, p, deadline)
		if r is Image:
			images[it.item_id] = r
		else:
			notes[it.item_id] = str(r)
	var result := apply_icons(p, plan, images, notes)
	if Util.is_error(result):
		ctx.send_deferred(result)
		return
	## Let the editor import the new PNGs so item.icon loads right away.
	var pngs: Array = []
	for icon in result.data.icons:
		pngs.append(icon.icon)
	var imported := await _import_pngs(pngs, deadline)
	result.data["imported"] = imported
	if not imported:
		result.data["note"] = "the editor has not finished importing the PNGs yet; icons appear once it does (focus the Godot window)"
	for icon in result.data.icons:
		var item_path := String(icon.item_file)
		if ResourceLoader.has_cached(item_path):
			ResourceLoader.load(item_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	ctx.send_deferred(result)


# =============================================================================
# params and plan
# =============================================================================

static func read_params(params: Dictionary) -> Variant:
	var allowed := ["item_id", "item_ids", "all", "model", "database_path", "icon_dir", "script_dir", "cell_px",
		"pitch_degrees", "yaw_degrees", "auto_orient", "margin", "outline", "apply_grid", "patch_ui", "dry_run"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var p := {}
	for spec in [["item_id", ""], ["model", ""], ["database_path", DEFAULT_DATABASE], ["icon_dir", DEFAULT_ICON_DIR], ["script_dir", DEFAULT_SCRIPT_DIR]]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var ids: Array[String] = []
	var raw_ids: Variant = params.get("item_ids", [])
	if raw_ids == null:
		raw_ids = []
	if not raw_ids is Array:
		return Util.error(Util.INVALID_PARAMS, "'item_ids' must be a list of item ids")
	for id in raw_ids:
		if not id is String or String(id).strip_edges().is_empty():
			return Util.error(Util.INVALID_PARAMS, "'item_ids' must hold item id strings")
		if not String(id).strip_edges() in ids:
			ids.append(String(id).strip_edges())
	if not String(p.item_id).is_empty() and not String(p.item_id) in ids:
		ids.push_front(String(p.item_id))
	var all: Variant = Util.boolean(params, "all", false)
	var cell_px: Variant = Util.integer(params, "cell_px", 128, 32, 512)
	var pitch: Variant = Util.num(params, "pitch_degrees", 30.0, 0.0, 90.0)
	var yaw: Variant = Util.num(params, "yaw_degrees", 25.0, -180.0, 180.0)
	var auto_orient: Variant = Util.boolean(params, "auto_orient", true)
	var margin: Variant = Util.num(params, "margin", 0.08, 0.0, 0.4)
	var outline: Variant = Util.boolean(params, "outline", true)
	var apply_grid: Variant = Util.boolean(params, "apply_grid", false)
	var patch_ui: Variant = Util.boolean(params, "patch_ui", true)
	var dry: Variant = Util.boolean(params, "dry_run", false)
	for v in [all, cell_px, pitch, yaw, auto_orient, margin, outline, apply_grid, patch_ui, dry]:
		if Util.is_error(v):
			return v
	if ids.is_empty() and not all:
		return Util.error(Util.INVALID_PARAMS, "pass item_id, item_ids or all=true (every item with a model)")
	if not ids.is_empty() and all:
		return Util.error(Util.INVALID_PARAMS, "pass item ids or all=true, not both")
	if ids.size() > MAX_ITEMS:
		return Util.error(Util.INVALID_PARAMS, "at most %d items per call" % MAX_ITEMS)
	if not String(p.model).is_empty():
		if ids.size() != 1:
			return Util.error(Util.INVALID_PARAMS, "'model' needs exactly one item_id")
		if not String(p.model).begins_with("res://"):
			return Util.error(Util.INVALID_PARAMS, "'model' must be a res:// path (import it with asset_import first)")
	for key in ["icon_dir", "script_dir"]:
		if not String(p[key]).begins_with("res://"):
			return Util.error(Util.INVALID_PARAMS, "'%s' must be a res:// folder" % key)
		p[key] = Util.clean_dir(p[key])
	p.merge({"item_ids": ids, "all": all, "cell_px": cell_px, "pitch_degrees": pitch, "yaw_degrees": yaw,
		"auto_orient": auto_orient, "margin": margin, "outline": outline, "apply_grid": apply_grid,
		"patch_ui": patch_ui, "dry_run": dry}, true)
	return p


## {"items": [{item_id, item_file, model, icon, grid, suggested_grid, shape}],
##  "skipped": [{item_id, reason}], "ui": [{path, change}|{path, note}]}
func make_plan(p: Dictionary) -> Variant:
	var targets: Array = []   ## [item_id, item_file]
	var swap := SwapTools.new()
	if p.all:
		if not FileAccess.file_exists(p.database_path):
			return Util.error(Util.NODE_NOT_FOUND, "item database %s not found; import items with item_db_import" % p.database_path)
		var db := load(p.database_path)
		var items: Variant = db.get("items") if db != null else null
		if not items is Array:
			return Util.error(Util.INVALID_PARAMS, "%s has no items list" % p.database_path)
		for it in items:
			if it is Resource and not String(it.get("item_id")).is_empty() and not it.resource_path.is_empty():
				targets.append([String(it.get("item_id")), it.resource_path])
	else:
		for id in p.item_ids:
			var path: Variant = swap._find_item_file(id, p.database_path)
			if Util.is_error(path):
				return path
			targets.append([id, path])
	var plan := {"items": [], "skipped": [], "ui": []}
	for t in targets:
		var id: String = t[0]
		## Read the .tres text, not a loaded copy: the cached resource may
		## predate a swap_placeholder that just wrote item.model.
		var text := FileAccess.get_file_as_string(t[1])
		if text.is_empty():
			plan.skipped.append({"item_id": id, "reason": "cannot read %s" % t[1]})
			continue
		var model := String(p.model)
		if model.is_empty():
			model = tres_string(text, "model")
		if model.is_empty():
			var guess := AssetTools.default_model_path("item", id)
			if ResourceLoader.exists(guess):
				model = guess
		if model.is_empty() or not ResourceLoader.exists(model):
			if not p.all or not model.is_empty():
				plan.skipped.append({"item_id": id, "reason": ("model %s not found or not imported yet" % model) if not model.is_empty()
					else "no model: make one with asset_pipeline kind=item asset_id=%s (or asset_import) first" % id})
			continue
		var grid := Vector2i(maxi(1, tres_int(text, "grid_width", 1)), maxi(1, tres_int(text, "grid_height", 1)))
		var shape: Variant = model_shape(model, p.auto_orient)
		if shape is String:
			plan.skipped.append({"item_id": id, "reason": shape})
			continue
		plan.items.append({
			"item_id": id, "item_file": t[1], "model": model, "icon": "%s/%s.png" % [p.icon_dir, id],
			"grid": grid, "suggested_grid": suggest_grid(shape.across, shape.along, tres_string(text, "category")),
			"shape": shape,
		})
	if p.patch_ui:
		plan.ui = plan_ui_patches(p.script_dir)
	return plan


## The model's size and how long it is along the icon's width: "along" is
## the longest horizontal side (the icon's width once auto_orient turns it),
## "across" the other horizontal side, "size" the bounding box in meters.
static func model_shape(model_path: String, auto_orient: bool) -> Variant:
	var packed := load(model_path) as PackedScene
	if packed == null:
		return "%s is not a scene (import it with asset_import)" % model_path
	var root := packed.instantiate()
	if not root is Node3D:
		if root != null:
			root.free()
		return "%s: the scene root is not a Node3D" % model_path
	var stats := AssetTools.measure(root)
	root.free()
	if not stats.has_aabb or stats.meshes == 0:
		return "%s has no mesh" % model_path
	var size: Vector3 = stats.aabb.size
	var along := size.x
	var across := size.z
	var turn := false
	if auto_orient and size.z > size.x:
		along = size.z
		across = size.x
		turn = true
	return {"size": [snappedf(size.x, 0.001), snappedf(size.y, 0.001), snappedf(size.z, 0.001)], "along": along,
		"across": maxf(across, size.y), "turn": turn}


## Cells for an item that is `along` long and `across` wide (meters, but only
## the ratio counts: asset_cleanup scales every item to the same size).
## Weapons (category "weapon") may get 4 cells; other items at most 3.
static func suggest_grid(across: float, along: float, category := "") -> Vector2i:
	var ratio := along / maxf(0.0001, across) + 0.0001
	if ratio >= 4.5 and category == "weapon":
		return Vector2i(4, 1)
	if ratio >= 3.0:
		return Vector2i(3, 1)
	if ratio >= 1.8:
		return Vector2i(2, 1)
	return Vector2i(1, 1)


static func dry_report(p: Dictionary, plan: Dictionary) -> Dictionary:
	var items: Array = []
	for it in plan.items:
		var grid: Vector2i = it.suggested_grid if p.apply_grid else it.grid
		items.append({
			"item_id": it.item_id, "item_file": it.item_file, "model": it.model, "icon": it.icon,
			"grid": [it.grid.x, it.grid.y], "suggested_grid": [it.suggested_grid.x, it.suggested_grid.y],
			"icon_px": [grid.x * int(p.cell_px), grid.y * int(p.cell_px)], "model_size": it.shape.size,
		})
	var out := {"dry_run": p.dry_run, "items": items, "skipped": plan.skipped, "ui": plan.ui}
	if items.is_empty():
		out["note"] = "nothing to render: no item here has an imported model"
	return out


# =============================================================================
# render
# =============================================================================

## Renders one icon. Returns an Image (RGBA, grid.x*cell_px by
## grid.y*cell_px) or a String saying why not. Coroutine.
func render_icon(model_path: String, grid: Vector2i, p: Dictionary, deadline_msec := 0) -> Variant:
	var packed := load(model_path) as PackedScene
	if packed == null:
		return "model did not load"
	var model := packed.instantiate() as Node3D
	if model == null:
		return "the model's root is not a Node3D"
	## Render wide (w >= h) and turn the image when the slot is tall.
	var tall := grid.y > grid.x
	var cells := Vector2i(maxi(grid.x, grid.y), mini(grid.x, grid.y))
	var px := cells * int(p.cell_px)
	var stop := Time.get_ticks_msec() + RENDER_WAIT_MSEC
	if deadline_msec > 0:
		stop = mini(stop, deadline_msec)
	if stop - Time.get_ticks_msec() < 500:
		model.free()
		return "out of time; call item_icon_render again for the rest"

	var vp := SubViewport.new()
	vp.size = px
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_8X
	EditorInterface.get_base_control().add_child(vp)
	var pivot := Node3D.new()
	vp.add_child(pivot)
	pivot.add_child(model)
	var stats := AssetTools.measure(model)
	var aabb: AABB = stats.aabb
	## Lay the longest horizontal side across the icon.
	## -90 degrees turns the front (-Z, a muzzle) to the right of the icon.
	if p.auto_orient and aabb.size.z > aabb.size.x:
		pivot.rotation.y = -PI * 0.5
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	## A long icon turns less, so the item's length spans the width.
	var basis := camera_basis(float(p.pitch_degrees), float(p.yaw_degrees) * float(cells.y) / float(cells.x))
	var framing := frame_box(pivot.transform * model.transform * aabb, basis, float(px.x) / float(px.y), float(p.margin))
	cam.transform = Transform3D(basis, framing.center + basis.z * framing.depth)
	cam.size = framing.height
	cam.near = 0.01
	cam.far = framing.depth * 2.0 + 1.0
	AssetTools.add_studio(vp)
	## A fill light from the camera side so the front never goes flat black.
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.45
	fill.transform = Transform3D(basis.rotated(Vector3.UP, deg_to_rad(-40.0)), Vector3.ZERO)
	vp.add_child(fill)

	var frames := [0]
	var count := func() -> void: frames[0] += 1
	RenderingServer.frame_post_draw.connect(count)
	var tree := Engine.get_main_loop() as SceneTree
	var base := EditorInterface.get_base_control()
	while frames[0] < 3 and Time.get_ticks_msec() < stop:
		base.queue_redraw()
		await tree.create_timer(0.05).timeout
	RenderingServer.frame_post_draw.disconnect(count)
	if frames[0] < 3:
		vp.queue_free()
		return "the editor window is not drawing; bring Godot to the front and call again"
	var image := vp.get_texture().get_image()
	vp.queue_free()
	if image == null or image.is_empty():
		return "the renderer returned no image"
	image.convert(Image.FORMAT_RGBA8)
	if p.outline:
		image = add_outline(image)
	if tall:
		image.rotate_90(CLOCKWISE)
	return image


## Camera orientation looking down `pitch` degrees, from `yaw` degrees to
## the right of the front (+Z side of the model).
static func camera_basis(pitch_degrees: float, yaw_degrees: float) -> Basis:
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.RIGHT, -deg_to_rad(pitch_degrees))
	b = b.rotated(Vector3.UP, deg_to_rad(yaw_degrees))
	return b.orthonormalized()


## Where an orthographic camera with `basis` must sit to fit `box` with a
## `margin` share of empty border: {center, height (ortho size), depth}.
static func frame_box(box: AABB, basis: Basis, aspect: float, margin: float) -> Dictionary:
	var right := basis.x
	var up := basis.y
	var back := basis.z
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var c := box.get_endpoint(i)
		var v := Vector3(c.dot(right), c.dot(up), c.dot(back))
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	var w := maxf(0.001, hi.x - lo.x)
	var h := maxf(0.001, hi.y - lo.y)
	var fit_h := maxf(h, w / maxf(0.01, aspect)) / maxf(0.2, 1.0 - margin * 2.0)
	var mid := (lo + hi) * 0.5
	var center := right * mid.x + up * mid.y + back * mid.z
	return {"center": center, "height": fit_h, "depth": maxf(0.1, (hi.z - lo.z) * 0.5 + 1.0)}


## A 1-2 px dark edge around the opaque pixels, so a dark model still reads
## on a dark cell and a light one on a light cell.
static func add_outline(src: Image, color := Color(0.04, 0.04, 0.05, 0.85)) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := src.duplicate() as Image
	for y in h:
		for x in w:
			if src.get_pixel(x, y).a > 0.5:
				continue
			var near := 0.0
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx >= 0 and ny >= 0 and nx < w and ny < h:
					near = maxf(near, src.get_pixel(nx, ny).a * (1.0 if absi(d.x) + absi(d.y) == 1 else 0.6))
			if near <= 0.0:
				continue
			var under := src.get_pixel(x, y)
			var a := maxf(under.a, color.a * near)
			out.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return out


# =============================================================================
# apply
# =============================================================================

## Writes the PNGs from `images` (item_id -> Image), points each item at its
## icon (and its suggested grid with apply_grid), patches the UI scripts, and
## records one undo step. Items without an image are reported as skipped.
func apply_icons(p: Dictionary, plan: Dictionary, images: Dictionary, notes: Dictionary = {}) -> Dictionary:
	var changes: Array = []   ## [path, PackedByteArray or String, what]
	var icons: Array = []
	var skipped: Array = (plan.skipped as Array).duplicate()
	for it in plan.items:
		if not images.has(it.item_id):
			skipped.append({"item_id": it.item_id, "reason": notes.get(it.item_id, "not rendered")})
			continue
		var image: Image = images[it.item_id]
		var png := image.save_png_to_buffer()
		if png.is_empty():
			skipped.append({"item_id": it.item_id, "reason": "could not encode the PNG"})
			continue
		changes.append([it.icon, png, "icon %dx%d" % [image.get_width(), image.get_height()]])
		var text := FileAccess.get_file_as_string(it.item_file)
		text = set_tres_icon(text, it.icon)
		var grid: Vector2i = it.grid
		if p.apply_grid and it.suggested_grid != it.grid:
			grid = it.suggested_grid
			text = set_tres_int(text, "grid_width", grid.x)
			text = set_tres_int(text, "grid_height", grid.y)
		changes.append([it.item_file, text, "icon = %s%s" % [it.icon, (", grid %dx%d" % [grid.x, grid.y]) if grid != it.grid else ""]])
		icons.append({
			"item_id": it.item_id, "item_file": it.item_file, "icon": it.icon,
			"absolute_path": ProjectSettings.globalize_path(it.icon), "size_px": [image.get_width(), image.get_height()],
			"grid": [grid.x, grid.y], "suggested_grid": [it.suggested_grid.x, it.suggested_grid.y],
			"grid_changed": grid != it.grid,
		})
	var ui_notes: Array = []
	for u in plan.ui:
		if u.has("text") and not icons.is_empty():
			changes.append([u.path, u.text, u.change])
		elif u.has("note"):
			ui_notes.append(u)
	var report := {"icons": icons, "skipped": skipped}
	if icons.is_empty():
		report["note"] = "no icon was made"
		return {"data": report}

	## Compile-check patched scripts before writing anything.
	for c in changes:
		if String(c[0]).ends_with(".gd"):
			var probe := GDScript.new()
			probe.source_code = c[1]
			if probe.reload() != OK:
				return Util.error(Util.INTERNAL_ERROR, "%s would not compile after the patch; nothing was changed (pass patch_ui=false to skip it)" % c[0])
	var paths: Array = []
	for c in changes:
		paths.append(c[0])
		if String(c[0]).ends_with(".png"):
			paths.append(String(c[0]) + ".import")
	var before := ItemTools.FileSnapshot.capture(paths)
	for c in changes:
		Util.ensure_dir(String(c[0]).get_base_dir())
		var f := FileAccess.open(c[0], FileAccess.WRITE)
		if f == null:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [c[0], error_string(FileAccess.get_open_error())])
		if c[1] is PackedByteArray:
			f.store_buffer(c[1])
		else:
			f.store_string(c[1])
		f.close()
	var reloaders: Array = []
	for c in changes:
		if String(c[0]).ends_with(".gd"):
			var r := InventoryTools.ScriptReloader.new()
			r.path = c[0]
			reloaders.append(r)
	for r in reloaders:
		r.reload()
	var written: Array = changes.map(func(c): return c[0])
	Util.refresh_filesystem(written)
	if Engine.is_editor_hint():
		## The .png.import files the editor writes are in `before` (as absent),
		## so undo removes them with the PNGs; redo restores the PNGs and
		## the editor imports them again.
		var after := ItemTools.FileSnapshot.capture(written)
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Item icons (%d)" % icons.size(), UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(before, "restore")
		for r in reloaders:
			ur.add_do_method(r, "reload")
			ur.add_undo_method(r, "reload")
		ur.commit_action(false)
	report["files"] = changes.map(func(c): return {"path": c[0], "change": c[2]})
	if not ui_notes.is_empty():
		report["ui_notes"] = ui_notes
	report["undo"] = "One editor undo step (Edit > Undo) restores the items, scripts and removes the PNGs."
	report["see_it"] = "Open the inventory (Tab) or the hideout stash: the cells show the icons. Look at the PNGs: %s" % ", ".join(icons.map(func(i): return i.absolute_path))
	return {"data": report}


func _import_pngs(pngs: Array, deadline_msec: int) -> bool:
	if pngs.is_empty() or not Engine.is_editor_hint():
		return true
	var assets := AssetTools.new()
	var all_ok := true
	for png in pngs:
		var ok: bool = await assets.wait_for_import(png, AssetTools.folder_known(String(png).get_base_dir()), deadline_msec)
		all_ok = all_ok and ok
	return all_ok


## Plans the icon drawing for older inventory_ui.gd / hideout.gd copies:
## [{path, text, change}] to write, or [{path, note}] when not possible.
static func plan_ui_patches(script_dir: String) -> Array:
	var out: Array = []
	for spec in UI_PATCHES:
		var path: String = script_dir + "/" + spec.file
		if not FileAccess.file_exists(path):
			continue
		var src := FileAccess.get_file_as_string(path)
		var patched: Variant = patch_ui_source(src, FileAccess.get_file_as_string(Util.TEMPLATE_DIR + spec.template), spec.anchor)
		if patched == null:
			continue
		if patched is String and String(patched).begins_with("!"):
			out.append({"path": path, "note": String(patched).substr(1)})
		else:
			out.append({"path": path, "text": patched, "change": "draws item icons in the cells"})
	return out


## The UI script with the template's icon block inserted after `anchor`;
## null when it already draws icons; "!why" when it cannot be patched.
static func patch_ui_source(src: String, template: String, anchor: String) -> Variant:
	if src.contains(UI_MARKER_BEGIN):
		return null
	var a := template.find(UI_MARKER_BEGIN)
	var b := template.find(UI_MARKER_END)
	if a < 0 or b < 0:
		return "!the addon template has no icon block"
	## From the start of the marker's line to the end of the end marker's line.
	var line_start := template.rfind("\n", a) + 1
	var line_end := template.find("\n", b)
	var block := template.substr(line_start, line_end + 1 - line_start)
	if src.count(anchor) != 1:
		return "!was edited by hand (the cell border line was not found once), so it was not patched; copy the block between '%s' and '%s' from the addon template into the function that draws a cell" % [UI_MARKER_BEGIN, UI_MARKER_END]
	return src.replace(anchor, anchor + block)


# =============================================================================
# .tres text
# =============================================================================

## Points the item at `icon_path`: an ext_resource for the texture (the one
## icon already uses, or a new one) and `icon = ExtResource(...)`.
static func set_tres_icon(text: String, icon_path: String) -> String:
	var lines := Array(text.split("\n"))
	var res_start := lines.find("[resource]")
	var icon_line := -1
	var ext_id := ""
	if res_start >= 0:
		for i in range(res_start + 1, lines.size()):
			if String(lines[i]).begins_with("["):
				break
			if String(lines[i]).begins_with("icon = "):
				icon_line = i
				var m := RegEx.create_from_string("ExtResource\\(\"([^\"]+)\"\\)").search(lines[i])
				if m != null:
					ext_id = m.get_string(1)
	var ext_line := "[ext_resource type=\"Texture2D\" path=\"%s\" id=\"%s\"]"
	if not ext_id.is_empty():
		for i in lines.size():
			var l := String(lines[i])
			if l.begins_with("[ext_resource") and l.contains("id=\"%s\"" % ext_id):
				lines[i] = ext_line % [icon_path, ext_id]
				return "\n".join(lines)
	## A new ext_resource after the last one (or after the header).
	var ids := {}
	var last_ext := -1
	for i in lines.size():
		var l := String(lines[i])
		if l.begins_with("[ext_resource"):
			last_ext = i
			var m := RegEx.create_from_string("id=\"([^\"]+)\"").search(l)
			if m != null:
				ids[m.get_string(1)] = true
	var id := ICON_EXT_ID
	var n := 2
	while ids.has(id):
		id = "%s_%d" % [ICON_EXT_ID, n]
		n += 1
	var insert_at := last_ext + 1
	if last_ext < 0:
		insert_at = 1 if lines.size() > 0 and String(lines[0]).begins_with("[gd_resource") else 0
		lines.insert(insert_at, "")
		insert_at += 1
	lines.insert(insert_at, ext_line % [icon_path, id])
	var value := "icon = ExtResource(\"%s\")" % id
	res_start = lines.find("[resource]")
	if icon_line >= 0:
		## The line moved down by the inserts above.
		for i in range(res_start + 1, lines.size()):
			if String(lines[i]).begins_with("icon = "):
				lines[i] = value
				return "\n".join(lines)
	if res_start < 0:
		return "\n".join(lines).rstrip("\n") + "\n\n[resource]\n" + value + "\n"
	var at := res_start + 1
	for i in range(res_start + 1, lines.size()):
		var l := String(lines[i])
		if l.begins_with("["):
			break
		if l.begins_with("script = ") or l.begins_with("item_id = ") or l.begins_with("display_name = ") \
				or l.begins_with("description = ") or l.begins_with("category = ") or l.begins_with("rarity = "):
			at = i + 1
	lines.insert(at, value)
	return "\n".join(lines)


## A string value of the [resource] section ("" when absent).
static func tres_string(text: String, key: String) -> String:
	var m := RegEx.create_from_string("(?m)^%s = (\".*\")\\s*$" % key).search(text)
	if m == null:
		return ""
	var v: Variant = JSON.parse_string(m.get_string(1))
	return String(v) if v is String else ""


static func tres_int(text: String, key: String, default_value: int) -> int:
	var m := RegEx.create_from_string("(?m)^%s = (-?\\d+)\\s*$" % key).search(text)
	return int(m.get_string(1)) if m != null else default_value


## Sets `key = value` (an int) in the [resource] section.
static func set_tres_int(text: String, key: String, value: int) -> String:
	var lines := Array(text.split("\n"))
	var res_start := lines.find("[resource]")
	if res_start < 0:
		return text.rstrip("\n") + "\n\n[resource]\n%s = %d\n" % [key, value]
	var end := lines.size()
	for i in range(res_start + 1, lines.size()):
		if String(lines[i]).begins_with("["):
			end = i
			break
		if String(lines[i]).begins_with(key + " = "):
			lines[i] = "%s = %d" % [key, value]
			return "\n".join(lines)
	## Before trailing blank lines of the section.
	var at := end
	while at > res_start + 1 and String(lines[at - 1]).strip_edges().is_empty():
		at -= 1
	lines.insert(at, "%s = %d" % [key, value])
	return "\n".join(lines)

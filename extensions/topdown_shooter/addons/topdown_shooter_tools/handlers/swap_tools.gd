@tool
extends RefCounted

## swap_placeholder: puts an imported model where a blockout shape was,
## without touching what the game uses. The placeholder mesh stays in the
## scene, hidden, and the model goes in a sibling "<Placeholder>Skin" node,
## so collision shapes, scripts, WeaponMount, NavigationAgent3D and node
## paths keep working, and revert=true (or one undo step) brings the
## blockout back.
##
## Targets:
##   player / enemy  scene file: hide Body (+ Nose), model scaled to the
##                   capsule height; the player's goes under Aim so it turns
##                   with the aim.
##   weapon          scene file: hide Model, model at the weapon origin (the
##                   grip), Muzzle moved to the model's Muzzle point (or its
##                   front-most point).
##   map             open scene: every StaticBody3D in one group of a
##                   raid_map_blockout map (Walls, Cover, Crates, Floors), the
##                   model fitted to each box (walls tiled along their length).
##   node            open scene: any MeshInstance3D.
##   item            item .tres: sets item.model, and teaches the project's
##                   item_data.gd / loot_pickup.gd about models if they are
##                   older copies; dropped items then show the model.
##
## A scene that is open and current is edited live (one undo step); a scene
## that is not open is edited on disk (one undo step in the global history).

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")

const TARGETS := ["player", "enemy", "weapon", "map", "node", "item"]
const FITS := ["auto", "height", "fit", "fill", "stretch", "tile", "none"]
## A fitted model smaller than this share of its box on any axis gets a
## warning: what you see no longer matches what blocks bullets.
const MISMATCH_RATIO := 0.6
const TARGET_KIND := {"player": "character", "enemy": "character", "weapon": "weapon", "map": "prop", "node": "prop", "item": "item"}
const DEFAULT_PLAYER_SCENE := "res://scenes/player/player.tscn"
const DEFAULT_ENEMY_DIR := "res://scenes/enemies"
const DEFAULT_WEAPON_DIR := "res://scenes/weapons"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const SKIN_META := &"swap_placeholder"
const MAP_GROUPS := ["Walls", "Cover", "Crates", "Floors"]
const MAX_MAP_BODIES := 2000
const PICKUP_MODEL_MARKER := "# --- item model (asset pipeline) "


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func swap_placeholder(params: Dictionary, _ctx = null) -> Dictionary:
	var p: Variant = read_params(params)
	if Util.is_error(p):
		return p
	if p.target == "item":
		return _swap_item(p)
	if p.target in ["map", "node"]:
		var root := Util.edited_root()
		if root == null:
			return Util.no_scene_error()
		var plan: Variant = _plan(root, p)
		if Util.is_error(plan):
			return plan
		return _apply_live(root, p, plan)
	## player / enemy / weapon: a scene file.
	var scene_path: String = p.scene
	if not FileAccess.file_exists(scene_path):
		return Util.error(Util.INVALID_PARAMS, "scene %s not found; pass scene=res://...tscn (the %s scene made by the scaffold tool)" % [scene_path, p.target])
	var edited := Util.edited_root()
	if edited != null and edited.scene_file_path == scene_path:
		var plan: Variant = _plan(edited, p)
		if Util.is_error(plan):
			return plan
		return _apply_live(edited, p, plan)
	if Engine.is_editor_hint() and scene_path in EditorInterface.get_open_scenes():
		return Util.error(Util.EDITOR_NOT_READY, "%s is open in another editor tab; switch to that tab (then it is edited live) or close it" % scene_path)
	return _apply_file(scene_path, p)


static func read_params(params: Dictionary) -> Variant:
	var allowed := ["target", "model", "asset_id", "scene", "node_path", "map_path", "group", "name_prefix", "fit",
		"yaw_degrees", "size", "revert", "dry_run", "item_id", "database_path", "script_dir", "move_muzzle"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var target: Variant = Util.text(params, "target", "")
	if Util.is_error(target):
		return target
	if not target in TARGETS:
		return Util.error(Util.INVALID_PARAMS, "'target' must be one of %s" % ", ".join(TARGETS))
	var p := {"target": target}
	for spec in [["model", ""], ["asset_id", ""], ["scene", ""], ["node_path", ""], ["map_path", ""], ["group", ""],
			["name_prefix", ""], ["fit", "auto"], ["item_id", ""], ["database_path", DEFAULT_DATABASE], ["script_dir", DEFAULT_SCRIPT_DIR]]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var yaw: Variant = Util.num(params, "yaw_degrees", 0.0, -360.0, 360.0)
	var size: Variant = Util.num(params, "size", 0.0, 0.0, 1000.0)
	var revert: Variant = Util.boolean(params, "revert", false)
	var dry: Variant = Util.boolean(params, "dry_run", false)
	var move_muzzle: Variant = Util.boolean(params, "move_muzzle", true)
	for v in [yaw, size, revert, dry, move_muzzle]:
		if Util.is_error(v):
			return v
	p["yaw_degrees"] = yaw
	p["size"] = size
	p["revert"] = revert
	p["dry_run"] = dry
	p["move_muzzle"] = move_muzzle
	if not p.fit in FITS:
		return Util.error(Util.INVALID_PARAMS, "'fit' must be one of %s" % ", ".join(FITS))

	## The model: model=res://..., else the rule folder of asset_id.
	var kind: String = TARGET_KIND[target]
	if p.model.is_empty() and not p.revert:
		var id: String = p.asset_id if not p.asset_id.is_empty() else p.item_id
		if id.is_empty():
			return Util.error(Util.INVALID_PARAMS, "pass model=res://assets/... (from asset_import) or asset_id")
		p.model = AssetTools.default_model_path(kind, id)
	if not p.revert:
		if not p.model.begins_with("res://"):
			return Util.error(Util.INVALID_PARAMS, "'model' must be a res:// path (import it with asset_import first)")
		if not ResourceLoader.exists(p.model):
			return Util.error(Util.INVALID_PARAMS, "model %s not found or not imported yet (asset_import imports it)" % p.model)

	match target:
		"player":
			if p.scene.is_empty():
				p.scene = DEFAULT_PLAYER_SCENE
		"enemy", "weapon":
			if p.scene.is_empty():
				if p.asset_id.is_empty():
					return Util.error(Util.INVALID_PARAMS, "pass scene=res://scenes/%s/<id>.tscn" % ("enemies" if target == "enemy" else "weapons"))
				p.scene = "%s/%s.tscn" % [DEFAULT_ENEMY_DIR if target == "enemy" else DEFAULT_WEAPON_DIR, p.asset_id]
		"map":
			if p.group.is_empty():
				return Util.error(Util.INVALID_PARAMS, "target=map needs group: one of %s (or another child of the map)" % ", ".join(MAP_GROUPS))
		"node":
			if p.node_path.is_empty():
				return Util.error(Util.INVALID_PARAMS, "target=node needs node_path (a MeshInstance3D in the open scene)")
		"item":
			if p.item_id.is_empty():
				return Util.error(Util.INVALID_PARAMS, "target=item needs item_id")
	if not p.scene.is_empty():
		var reason := Util.check_res_path(p.scene, "tscn")
		if not reason.is_empty():
			return Util.error(Util.INVALID_PARAMS, reason)
	return p


# =============================================================================
# planning: which placeholders, where the model goes
# =============================================================================

## Returns {"swaps": [swap...], "model_info": {...}} or an error. A swap is
## {host, hide:[Node3D], skin_name, transforms:[Transform3D], muzzle, muzzle_to,
## old_skin, fit, label}.
func _plan(root: Node, p: Dictionary) -> Variant:
	var placeholders: Variant = _find_placeholders(root, p)
	if Util.is_error(placeholders):
		return placeholders
	var model_box := AABB()
	var model_muzzle: Variant = null
	if not p.revert:
		var packed := load(p.model) as PackedScene
		if packed == null:
			return Util.error(Util.INVALID_PARAMS, "%s is not a scene/model" % p.model)
		var probe := packed.instantiate() as Node3D
		if probe == null:
			return Util.error(Util.INVALID_PARAMS, "%s has no 3D root" % p.model)
		var stats := AssetTools.measure(probe)
		model_box = stats.aabb
		var m := AssetTools.find_named(probe, "muzzle")
		if m != null:
			model_muzzle = AssetTools.relative_transform(m, probe).origin
		probe.free()
		if model_box.size.length() < 0.0001:
			return Util.error(Util.INVALID_PARAMS, "%s has no visible mesh" % p.model)
	var swaps: Array = []
	for ph in placeholders:
		var swap := {
			"host": ph.host, "hide": ph.hide, "skin_name": ph.skin_name, "label": ph.label,
			"old_skin": ph.host.get_node_or_null(NodePath(ph.skin_name)),
			"transforms": [], "muzzle": null, "muzzle_to": Vector3.ZERO, "fit": "", "box": ph.box,
		}
		if not p.revert:
			var fit: String = p.fit if p.fit != "auto" else ph.default_fit
			swap.fit = fit
			swap.transforms = fit_transforms(model_box, ph.box, fit, p.yaw_degrees, p.size, ph.align_origin)
			if p.target == "weapon" and p.move_muzzle:
				var muzzle := ph.host.get_node_or_null(^"Muzzle") as Node3D
				if muzzle != null:
					var t: Transform3D = swap.transforms[0]
					var local: Vector3 = model_muzzle if model_muzzle != null else Vector3(model_box.get_center().x, model_box.get_center().y, model_box.position.z)
					swap.muzzle = muzzle
					swap.muzzle_to = t * local
					swap["muzzle_source"] = "model Muzzle node" if model_muzzle != null else "front-most point of the model"
		elif swap.old_skin == null:
			continue
		swaps.append(swap)
	if swaps.is_empty():
		return Util.error(Util.NODE_NOT_FOUND, "nothing to revert: no %s skin found" % p.target if p.revert else "no placeholder found")
	return {"swaps": swaps, "model_box": model_box, "model_has_muzzle": model_muzzle != null}


## [{host, hide, skin_name, box (AABB in host space), default_fit, align_origin, label}]
func _find_placeholders(root: Node, p: Dictionary) -> Variant:
	var out: Array = []
	match p.target:
		"player", "enemy":
			var body := root.get_node_or_null(^"Body") as Node3D
			if body == null:
				return Util.error(Util.NODE_NOT_FOUND, "%s has no Body node (made by %s_scaffold)" % [root.scene_file_path, "player_controller" if p.target == "player" else "enemy_ai"])
			var host: Node3D = root as Node3D
			var hide: Array = [body]
			if p.target == "player":
				var aim := root.get_node_or_null(^"Aim") as Node3D
				if aim != null:
					host = aim
				var nose := root.get_node_or_null(^"Aim/Nose") as Node3D
				if nose != null:
					hide.append(nose)
			else:
				var nose := root.get_node_or_null(^"Nose") as Node3D
				if nose != null:
					hide.append(nose)
			out.append({"host": host, "hide": hide, "skin_name": "BodySkin", "box": _box_in(body, host), "default_fit": "height", "align_origin": false, "label": Util.scene_path_of(body, root)})
		"weapon":
			var model := root.get_node_or_null(^"Model") as Node3D
			if model == null:
				return Util.error(Util.NODE_NOT_FOUND, "%s has no Model node (made by weapon_create)" % root.scene_file_path)
			out.append({"host": root, "hide": [model], "skin_name": "ModelSkin", "box": _box_in(model, root), "default_fit": "none", "align_origin": true, "label": Util.scene_path_of(model, root)})
		"node":
			var node := Util.resolve(p.node_path, root)
			if node == null:
				return Util.error(Util.NODE_NOT_FOUND, "node_path '%s' not found in the open scene" % p.node_path)
			if not node is GeometryInstance3D or node == root:
				return Util.error(Util.INVALID_PARAMS, "%s is a %s; pass the placeholder MeshInstance3D" % [p.node_path, node.get_class()])
			var err := _check_not_in_instance(node, root)
			if not err.is_empty():
				return err
			var host := node.get_parent() as Node3D
			out.append({"host": host, "hide": [node], "skin_name": String(node.name) + "Skin", "box": _box_in(node, host), "default_fit": "fit", "align_origin": false, "label": Util.scene_path_of(node, root)})
		"map":
			var map: Node = Util.resolve(p.map_path, root) if not p.map_path.is_empty() else _find_map(root, p.group)
			if map == null:
				return Util.error(Util.NODE_NOT_FOUND, "no raid map with a '%s' group in the open scene; pass map_path" % p.group)
			var group := map.get_node_or_null(NodePath(p.group))
			if group == null:
				return Util.error(Util.NODE_NOT_FOUND, "%s has no child '%s' (groups: %s)" % [Util.scene_path_of(map, root), p.group, ", ".join(_child_names(map))])
			var default_fit := "tile" if p.group in ["Walls", "Floors"] else "fit"
			for body in group.get_children():
				if not body is Node3D:
					continue
				if not p.name_prefix.is_empty() and not String(body.name).begins_with(p.name_prefix):
					continue
				var mesh := _placeholder_mesh(body)
				if mesh == null:
					continue
				var err := _check_not_in_instance(mesh, root)
				if not err.is_empty():
					return err
				out.append({"host": body, "hide": [mesh], "skin_name": String(mesh.name) + "Skin", "box": _box_in(mesh, body), "default_fit": default_fit, "align_origin": false, "label": Util.scene_path_of(body, root)})
				if out.size() > MAX_MAP_BODIES:
					return Util.error(Util.INVALID_PARAMS, "more than %d bodies; narrow it with name_prefix" % MAX_MAP_BODIES)
			if out.is_empty():
				return Util.error(Util.NODE_NOT_FOUND, "no box with a Mesh/Body child in %s%s" % [Util.scene_path_of(group, root), " starting with '%s'" % p.name_prefix if not p.name_prefix.is_empty() else ""])
	return out


static func _placeholder_mesh(body: Node) -> MeshInstance3D:
	for name in ["Mesh", "Body"]:
		var n := body.get_node_or_null(NodePath(name)) as MeshInstance3D
		if n != null:
			return n
	return null


static func _find_map(root: Node, group: String) -> Node:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_node_or_null(NodePath(group)) != null and n.has_meta(&"raid_map_seed"):
			return n
		for c in n.get_children():
			stack.append(c)
	## Any node with that group child (a hand-made map).
	stack = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_node_or_null(NodePath(group)) != null:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


static func _child_names(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		out.append(String(c.name))
	return out


static func _check_not_in_instance(node: Node, root: Node) -> Dictionary:
	if node.owner != root:
		var inst := node.owner
		return Util.error(Util.INVALID_PARAMS, "%s belongs to the instanced scene %s; swap it in that scene file instead (target=%s scene=%s)" % [
			Util.scene_path_of(node, root), inst.scene_file_path if inst != null else "?", "weapon", inst.scene_file_path if inst != null else "?"])
	return {}


## The placeholder's visible box in `host` space.
static func _box_in(node: Node3D, host: Node) -> AABB:
	var vi := node as VisualInstance3D
	var local := vi.get_aabb() if vi != null else AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
	return AssetTools.relative_transform(node, host) * local


## Transforms (host space) of one or more model copies filling `box`.
##   none: no scaling, model origin at the box's bottom center (or the host
##         origin when align_origin). height: uniform, model height = box
##         height (or `size`). fit: uniform, inside the box. fill: the
##         footprint uniform inside the box, the height stretched to the
##         box's (the model then covers its collision). stretch: each axis
##         to the box. tile: copies along the box's long side, each
##         stretched to its share (walls).
## fit/fill/stretch/tile turn the model 90 degrees when its long side does
## not match the box's.
static func fit_transforms(model: AABB, box: AABB, fit: String, yaw_degrees: float, size: float, align_origin: bool) -> Array:
	var ms := model.size
	var bs := box.size
	var turn := 0.0
	if fit in ["fit", "fill", "stretch", "tile"] and absf(bs.x - bs.z) > 0.01 and absf(ms.x - ms.z) > 0.01 and (bs.x > bs.z) != (ms.x > ms.z):
		turn = 90.0
	var basis_rot := Basis(Vector3.UP, deg_to_rad(yaw_degrees + turn))
	## Model size along host axes once turned (x and z swap at 90 / 270).
	var swapped := absf(fmod(absf(yaw_degrees + turn), 180.0) - 90.0) < 1.0
	var mx := ms.z if swapped else ms.x
	var mz := ms.x if swapped else ms.z
	var my := ms.y
	var anchor_model := Vector3(model.get_center().x, model.position.y, model.get_center().z)
	var out: Array = []
	match fit:
		"none":
			var b := basis_rot
			var target := Vector3.ZERO if align_origin else Vector3(box.get_center().x, box.position.y, box.get_center().z)
			var from := Vector3.ZERO if align_origin else anchor_model
			out.append(Transform3D(b, target - b * from))
		"height":
			var k := (size if size > 0.0 else bs.y) / maxf(my, 0.0001)
			var b := basis_rot * Basis.from_scale(Vector3(k, k, k))
			var target := Vector3(box.get_center().x, box.position.y, box.get_center().z)
			out.append(Transform3D(b, target - b * anchor_model))
		"fit":
			var k := minf(bs.x / maxf(mx, 0.0001), minf(bs.y / maxf(my, 0.0001), bs.z / maxf(mz, 0.0001)))
			if size > 0.0:
				k = size / maxf(maxf(mx, my), mz)
			var b := basis_rot * Basis.from_scale(Vector3(k, k, k))
			var target := Vector3(box.get_center().x, box.position.y, box.get_center().z)
			out.append(Transform3D(b, target - b * anchor_model))
		"fill":
			var k := minf(bs.x / maxf(mx, 0.0001), bs.z / maxf(mz, 0.0001))
			var ky := bs.y / maxf(my, 0.0001)
			var b := basis_rot * Basis.from_scale(Vector3(k, ky, k))
			var target := Vector3(box.get_center().x, box.position.y, box.get_center().z)
			out.append(Transform3D(b, target - b * anchor_model))
		"stretch", "tile":
			var along_x := bs.x >= bs.z
			var length := bs.x if along_x else bs.z
			var module := mx if along_x else mz
			var count := 1
			if fit == "tile":
				count = maxi(1, int(round(length / maxf(module, 0.0001))))
			var seg := length / count
			## Scale in host axes, then expressed in the model's own axes.
			var host_scale := Vector3(seg / maxf(mx, 0.0001) if along_x else bs.x / maxf(mx, 0.0001), bs.y / maxf(my, 0.0001),
				bs.z / maxf(mz, 0.0001) if along_x else seg / maxf(mz, 0.0001))
			var local_scale := Vector3(host_scale.z, host_scale.y, host_scale.x) if swapped else host_scale
			var b := basis_rot * Basis.from_scale(local_scale)
			for i in count:
				var offset := -length / 2.0 + seg * (i + 0.5)
				var target := Vector3(box.get_center().x + (offset if along_x else 0.0), box.position.y, box.get_center().z + (0.0 if along_x else offset))
				out.append(Transform3D(b, target - b * anchor_model))
	return out


## The node holding the model copies; `owner_root` owns what gets saved.
func _build_skin(swap: Dictionary, p: Dictionary) -> Node3D:
	var skin := Node3D.new()
	skin.name = swap.skin_name
	var hidden: Array = []
	for n in swap.hide:
		hidden.append(String(swap.host.get_path_to(n)))
	skin.set_meta(SKIN_META, {"model": p.model, "hidden": hidden, "fit": swap.fit})
	var packed := load(p.model) as PackedScene
	var i := 0
	for t in swap.transforms:
		i += 1
		var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
		inst.name = "Model" if i == 1 else "Model%d" % i
		inst.transform = t
		skin.add_child(inst)
	return skin


# =============================================================================
# applying
# =============================================================================

## Edits the open scene: one undo step.
func _apply_live(root: Node, p: Dictionary, plan: Dictionary) -> Dictionary:
	var report := _report(root, p, plan)
	if p.dry_run:
		report["dry_run"] = true
		return {"data": report}
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Revert placeholder skins" if p.revert else "Swap placeholder with %s" % p.model.get_file(), UndoRedo.MERGE_DISABLE, root)
	for swap in plan.swaps:
		var host: Node = swap.host
		var old: Node = swap.old_skin
		if old != null:
			ur.add_do_method(host, "remove_child", old)
			ur.add_undo_method(host, "add_child", old, true)
			ur.add_undo_method(host, "move_child", old, old.get_index())
			for n in _owned_subtree(old, root):
				ur.add_undo_method(n, "set_owner", root)
			ur.add_undo_reference(old)
		if p.revert:
			for path in _hidden_paths(old):
				var n := host.get_node_or_null(NodePath(path)) as Node3D
				if n != null and not n.visible:
					ur.add_do_property(n, "visible", true)
					ur.add_undo_property(n, "visible", false)
			continue
		var skin := _build_skin(swap, p)
		ur.add_do_method(host, "add_child", skin, true)
		ur.add_do_method(skin, "set_owner", root)
		for child in skin.get_children():
			ur.add_do_method(child, "set_owner", root)
		ur.add_do_reference(skin)
		ur.add_undo_method(host, "remove_child", skin)
		for n in swap.hide:
			if n.visible:
				ur.add_do_property(n, "visible", false)
				ur.add_undo_property(n, "visible", true)
		if swap.muzzle != null:
			ur.add_do_property(swap.muzzle, "position", swap.muzzle_to)
			ur.add_undo_property(swap.muzzle, "position", swap.muzzle.position)
	ur.commit_action()
	report["scene"] = root.scene_file_path
	report["edited"] = "open scene (unsaved; save with Ctrl+S or scene_save)"
	report["undo"] = "One editor undo step puts the placeholders back."
	return {"data": report}


## Edits a scene file that is not open; one global undo step restores it.
func _apply_file(scene_path: String, p: Dictionary) -> Dictionary:
	var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return Util.error(Util.INVALID_PARAMS, "cannot load %s" % scene_path)
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		return Util.error(Util.INTERNAL_ERROR, "cannot instance %s" % scene_path)
	var plan: Variant = _plan(root, p)
	if Util.is_error(plan):
		root.free()
		return plan
	var report := _report(root, p, plan)
	if p.dry_run:
		root.free()
		report["dry_run"] = true
		return {"data": report}
	for swap in plan.swaps:
		var host: Node = swap.host
		var old: Node = swap.old_skin
		if old != null:
			host.remove_child(old)
			if p.revert:
				for path in _hidden_paths(old):
					var n := host.get_node_or_null(NodePath(path)) as Node3D
					if n != null:
						n.visible = true
			old.free()
		if p.revert:
			continue
		var skin := _build_skin(swap, p)
		host.add_child(skin, true)
		skin.owner = root
		for child in skin.get_children():
			child.owner = root
		for n in swap.hide:
			n.visible = false
		if swap.muzzle != null:
			swap.muzzle.position = swap.muzzle_to
	var before := ItemTools.FileSnapshot.capture([scene_path])
	var err := Util.save_scene(root, scene_path)
	if not err.is_empty():
		before.restore()
		return Util.error(Util.INTERNAL_ERROR, err)
	var after := ItemTools.FileSnapshot.capture([scene_path])
	var reloader := SceneReloader.new()
	reloader.path = scene_path
	reloader.reload()
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Swap placeholder in %s" % scene_path.get_file(), UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_do_method(reloader, "reload")
		ur.add_undo_method(before, "restore")
		ur.add_undo_method(reloader, "reload")
		ur.commit_action(false)
	report["scene"] = scene_path
	report["edited"] = "scene file (saved)"
	report["undo"] = "One editor undo step (Edit > Undo) restores %s. Scenes that instance it pick it up when reopened." % scene_path.get_file()
	return {"data": report}


static func _owned_subtree(node: Node, root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.owner == root:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


static func _hidden_paths(skin: Node) -> Array:
	if skin == null or not skin.has_meta(SKIN_META):
		return []
	var meta: Variant = skin.get_meta(SKIN_META)
	return meta.get("hidden", []) if meta is Dictionary else []


func _report(root: Node, p: Dictionary, plan: Dictionary) -> Dictionary:
	var swaps: Array = []
	var copies := 0
	var mismatched: Array[String] = []
	for swap in plan.swaps:
		var entry := {"placeholder": swap.label, "skin": Util.scene_path_of(swap.host, root) + "/" + swap.skin_name}
		if not p.revert:
			entry["fit"] = swap.fit
			entry["copies"] = swap.transforms.size()
			copies += swap.transforms.size()
			var t: Transform3D = swap.transforms[0]
			entry["scale"] = AssetTools._v3(t.basis.get_scale())
			var fitted: Vector3 = (t * plan.model_box).size
			entry["size"] = AssetTools._v3(fitted)
			var box: AABB = swap.box
			entry["box"] = AssetTools._v3(box.size)
			if swap.fit in ["fit", "fill"] and (fitted.y < box.size.y * MISMATCH_RATIO or maxf(fitted.x, fitted.z) < maxf(box.size.x, box.size.z) * MISMATCH_RATIO):
				mismatched.append("%s (model %.2fx%.2fx%.2f m in a %.2fx%.2fx%.2f m box)" % [swap.label, fitted.x, fitted.y, fitted.z, box.size.x, box.size.y, box.size.z])
			if swap.old_skin != null:
				entry["replaced_skin"] = true
		if swap.muzzle != null:
			entry["muzzle"] = {"from": AssetTools._v3(swap.muzzle.position), "to": AssetTools._v3(swap.muzzle_to), "source": swap.get("muzzle_source", "")}
		swaps.append(entry)
	var out := {"target": p.target}
	out["reverted" if p.revert else "swapped"] = swaps.size()
	if not p.revert:
		out["model"] = p.model
		out["model_size"] = AssetTools._v3(plan.model_box.size)
		out["model_copies"] = copies
	out["swaps"] = swaps if swaps.size() <= 30 else swaps.slice(0, 30) + [{"more": swaps.size() - 30}]
	out["kept"] = "Collision shapes, scripts and other nodes are unchanged; the placeholder meshes are hidden, not deleted."
	if not mismatched.is_empty():
		out["warnings"] = ["The model covers much less than its collision box at %d of %d placeholders, e.g. %s. Use fit=fill (height to the box), fit=stretch, or a model closer to the box's proportions." % [mismatched.size(), plan.swaps.size(), mismatched[0]]]
	if p.target == "weapon" and not plan.model_has_muzzle and not p.revert:
		out["note"] = "The model has no Muzzle node; Muzzle was put at its front-most point. asset_cleanup adds a Muzzle to weapons."
	return out


## Reloads a scene resource from disk after it changed underneath.
class SceneReloader extends RefCounted:
	var path := ""

	func reload() -> void:
		if ResourceLoader.has_cached(path):
			ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		Util.refresh_filesystem([path])


# =============================================================================
# item
# =============================================================================

func _swap_item(p: Dictionary) -> Dictionary:
	var item_path: Variant = _find_item_file(p.item_id, p.database_path)
	if Util.is_error(item_path):
		return item_path
	var item_text := FileAccess.get_file_as_string(item_path)
	var item_script_path := _ext_script_path(item_text)
	var changes: Array = []   ## [path, new_text, what]
	var warnings: Array[String] = []

	## 1. item_data.gd needs a model property.
	if not item_script_path.is_empty() and FileAccess.file_exists(item_script_path):
		var src := FileAccess.get_file_as_string(item_script_path)
		if not RegEx.create_from_string("(?m)^@export[^\\n]*\\bvar\\s+model\\b").search(src) and not p.revert:
			var line := "## 3D model shown when the item lies on the ground (asset pipeline).\n@export_file(\"*.glb\", \"*.gltf\", \"*.fbx\", \"*.obj\", \"*.tscn\", \"*.scn\") var model := \"\"\n"
			var anchor := "@export var icon: Texture2D\n"
			var patched := src.replace(anchor, anchor + line) if src.contains(anchor) else src.rstrip("\n") + "\n\n" + line
			changes.append([item_script_path, patched, "added a model property"])
	else:
		warnings.append("item %s has no script file; only the .tres was changed" % item_path)

	## 2. loot_pickup.gd needs to show models.
	var pickup_path: String = Util.clean_dir(p.script_dir) + "/loot_pickup.gd"
	if FileAccess.file_exists(pickup_path) and not p.revert:
		var src := FileAccess.get_file_as_string(pickup_path)
		if not src.contains("func _apply_model("):
			var template := FileAccess.get_file_as_string(Util.TEMPLATE_DIR + "loot_pickup.gd.tmpl")
			var at := template.find(PICKUP_MODEL_MARKER)
			var call_from := "\tif get_child_count() == 0:\n\t\t_build()\n"
			if at < 0 or not src.contains(call_from):
				warnings.append("%s was edited by hand, so it was not patched: dropped items keep the box until it calls _apply_model() (see the template)" % pickup_path)
			else:
				var patched := src.replace(call_from, call_from + "\t\t_apply_model()\n").rstrip("\n") + "\n\n\n" + template.substr(at)
				changes.append([pickup_path, patched, "shows item models (_apply_model)"])
	elif not p.revert:
		warnings.append("%s not found: run loot_table_edit (it copies loot_pickup.gd) so dropped items appear" % pickup_path)

	## 3. the item's model value.
	var new_item := _set_tres_value(item_text, "model", "" if p.revert else p.model)
	changes.append([item_path, new_item, "model = %s" % ("(none)" if p.revert else p.model)])

	var report := {
		"target": "item", "item_id": p.item_id, "item_file": item_path,
		"model": "" if p.revert else p.model,
		"files": changes.map(func(c): return {"path": c[0], "change": c[2]}),
	}
	if not warnings.is_empty():
		report["warnings"] = warnings
	if p.dry_run:
		report["dry_run"] = true
		return {"data": report}

	## Compile-check patched scripts before writing anything.
	for c in changes:
		if String(c[0]).ends_with(".gd"):
			var probe := GDScript.new()
			probe.source_code = c[1]
			if probe.reload() != OK:
				return Util.error(Util.INTERNAL_ERROR, "%s would not compile after the patch; nothing was changed" % c[0])
	var paths: Array = changes.map(func(c): return c[0])
	var before := ItemTools.FileSnapshot.capture(paths)
	for c in changes:
		var f := FileAccess.open(c[0], FileAccess.WRITE)
		if f == null:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [c[0], error_string(FileAccess.get_open_error())])
		f.store_string(c[1])
		f.close()
	var after := ItemTools.FileSnapshot.capture(paths)
	var reloaders: Array = []
	for path in paths:
		if String(path).ends_with(".gd"):
			var r := InventoryTools.ScriptReloader.new()
			r.path = path
			reloaders.append(r)
	for r in reloaders:
		r.reload()
	_reload_resource(item_path)
	Util.refresh_filesystem(paths)
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Item model %s" % p.item_id, UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(before, "restore")
		for r in reloaders:
			ur.add_do_method(r, "reload")
			ur.add_undo_method(r, "reload")
		ur.commit_action(false)
	report["undo"] = "One editor undo step (Edit > Undo) restores these files."
	report["see_it"] = "Dropped %s pickups show the model (scaled to loot_pickup.model_size, %s) with a rarity glow." % [p.item_id, "0.45 m by default"]
	return {"data": report}


static func _reload_resource(path: String) -> void:
	if ResourceLoader.has_cached(path):
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


func _find_item_file(item_id: String, database_path: String) -> Variant:
	var guess := database_path.get_base_dir() + "/" + item_id + ".tres"
	if FileAccess.file_exists(guess):
		return guess
	if FileAccess.file_exists(database_path):
		var db := load(database_path)
		var items: Variant = db.get("items") if db != null else null
		if items is Array:
			for it in items:
				if it is Resource and String(it.get("item_id")) == item_id and not it.resource_path.is_empty():
					return it.resource_path
	return Util.error(Util.NODE_NOT_FOUND, "item '%s' not found (looked for %s and in %s); import it with item_db_import" % [item_id, guess, database_path])


## The script path of a .tres (its ExtResource with type="Script").
static func _ext_script_path(text: String) -> String:
	var re := RegEx.create_from_string("\\[ext_resource[^\\]]*type=\"Script\"[^\\]]*path=\"([^\"]+)\"")
	var m := re.search(text)
	if m == null:
		re = RegEx.create_from_string("\\[ext_resource[^\\]]*path=\"([^\"]+\\.gd)\"")
		m = re.search(text)
	return m.get_string(1) if m != null else ""


## Sets `key = "value"` in the [resource] section of a .tres text (removes
## the line when value is empty).
static func _set_tres_value(text: String, key: String, value: String) -> String:
	var lines := text.split("\n")
	var start := -1
	var end := lines.size()
	for i in lines.size():
		if lines[i].strip_edges() == "[resource]":
			start = i
		elif start >= 0 and i > start and lines[i].begins_with("["):
			end = i
			break
	var line := "%s = %s" % [key, JSON.stringify(value)]
	if start < 0:
		return text.rstrip("\n") + "\n\n[resource]\n" + line + "\n"
	for i in range(start + 1, end):
		if lines[i].begins_with(key + " = "):
			if value.is_empty():
				lines.remove_at(i)
			else:
				lines[i] = line
			return "\n".join(lines)
	if value.is_empty():
		return text
	## After the script line, else right after [resource].
	var at := start + 1
	for i in range(start + 1, end):
		if lines[i].begins_with("script = "):
			at = i + 1
	lines.insert(at, line)
	return "\n".join(lines)

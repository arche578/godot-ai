@tool
extends RefCounted

## asset_audit: what is still blockout, in one read-only report.
##
##   placeholders  visible primitive meshes (box, capsule, cylinder, sphere,
##                 plane, CSG) in the project's scenes that no swap has
##                 replaced yet, grouped by what they stand for: character
##                 Body/Nose, weapon Model, raid map Walls/Cover/Crates/Floors,
##                 anything else.
##   characters    player/enemy scenes: still a capsule, a model without
##                 animation, or animated (and which clips the library lacks).
##   items         items with no icon or no model (or a path that is gone).
##   budget        imported models over their kind's triangle/texture budget.
##
## Changes nothing. Each finding says which tool fixes it.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const SwapTools := preload("res://addons/topdown_shooter_tools/handlers/swap_tools.gd")
const CharacterTools := preload("res://addons/topdown_shooter_tools/handlers/character_tools.gd")

const CHECKS := ["placeholders", "characters", "items", "budget"]
const SKIP_DIRS := ["res://addons", "res://.godot", "res://asset_sources", "res://playtest_notes"]
const PRIMITIVES := ["BoxMesh", "CapsuleMesh", "CylinderMesh", "SphereMesh", "PlaneMesh", "QuadMesh", "PrismMesh", "TorusMesh"]
const MAX_SCENES := 300
const MAX_MODELS := 300
## Animation roles a character should have; the rest are nice to have.
const CORE_ROLES := ["idle", "walk", "run", "death"]


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func asset_audit(params: Dictionary, _ctx = null) -> Dictionary:
	var p: Variant = read_params(params)
	if Util.is_error(p):
		return p
	var out := {"summary": {}}
	var next: Array = []
	var scenes: Array = p.scenes if not p.scenes.is_empty() else find_files(p.dirs, ["tscn"], MAX_SCENES + 1)
	var truncated := scenes.size() > MAX_SCENES
	if truncated:
		scenes = scenes.slice(0, MAX_SCENES)
	out.summary["scenes_checked"] = scenes.size()

	if "placeholders" in p.checks or "characters" in p.checks:
		var found := _scan_scenes(scenes, p)
		if "placeholders" in p.checks:
			out["placeholders"] = _cap(found.placeholders, p.max_entries)
			out.summary["placeholders"] = found.placeholders.reduce(func(acc, e): return acc + int(e.count), 0)
			var by_kind := {}
			for e in found.placeholders:
				by_kind[e.kind] = int(by_kind.get(e.kind, 0)) + int(e.count)
			out.summary["placeholders_by_kind"] = by_kind
			next.append_array(_placeholder_hints(found.placeholders))
		if "characters" in p.checks:
			out["characters"] = _cap(found.characters, p.max_entries)
			out.summary["characters"] = {
				"placeholder": found.characters.filter(func(c): return c.status == "placeholder").size(),
				"model_without_animation": found.characters.filter(func(c): return c.status == "model_without_animation").size(),
				"animated": found.characters.filter(func(c): return c.status == "animated").size(),
			}
			for c in found.characters:
				if c.has("fix"):
					next.append(c.fix)
	if "items" in p.checks:
		var items := _audit_items(p.database_path)
		if items.has("note"):
			out["items_note"] = items.note
		else:
			out["items"] = {"without_icon": _cap(items.without_icon, p.max_entries), "without_model": _cap(items.without_model, p.max_entries), "broken_paths": _cap(items.broken, p.max_entries)}
			out.summary["items"] = items.total
			out.summary["items_without_icon"] = items.without_icon.size()
			out.summary["items_without_model"] = items.without_model.size()
			if not items.broken.is_empty():
				out.summary["item_broken_paths"] = items.broken.size()
			if not items.without_model.is_empty():
				next.append("Item models: asset_pipeline kind=item asset_id=<item_id> (or swap_placeholder target=item item_id=<id> model=...) for %s" % ", ".join(items.without_model.slice(0, 5).map(func(e): return e.item_id)))
			var renderable: Array = items.without_icon.filter(func(e): return e.has_model)
			if not renderable.is_empty():
				next.append("Icons: item_icon_render all=true renders the %d item(s) that have a model but no icon" % renderable.size())
	if "budget" in p.checks:
		var budget := _audit_budget(p.assets_dir)
		out["over_budget"] = _cap(budget.over, p.max_entries)
		out.summary["models_checked"] = budget.checked
		out.summary["models_over_budget"] = budget.over.size()
		if not budget.over.is_empty():
			next.append("Over budget: asset_cleanup source=<the model> kind=<kind> asset_id=<id> overwrite=true decimates and shrinks textures")
	if truncated:
		out["note"] = "only the first %d scenes were checked; pass dirs or scenes to narrow it" % MAX_SCENES
	out["next"] = next
	out["clean"] = int(out.summary.get("placeholders", 0)) == 0 and int(out.summary.get("items_without_icon", 0)) == 0 \
		and int(out.summary.get("items_without_model", 0)) == 0 and int(out.summary.get("models_over_budget", 0)) == 0 \
		and int(out.summary.get("characters", {}).get("placeholder", 0)) == 0 and int(out.summary.get("characters", {}).get("model_without_animation", 0)) == 0
	return {"data": out}


static func read_params(params: Dictionary) -> Variant:
	var allowed := ["checks", "scenes", "dirs", "database_path", "assets_dir", "library", "max_entries"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var p := {}
	for spec in [["database_path", SwapTools.DEFAULT_DATABASE], ["assets_dir", AssetTools.ASSETS_ROOT], ["library", CharacterTools.DEFAULT_LIBRARY]]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var max_entries: Variant = Util.integer(params, "max_entries", 40, 1, 500)
	if Util.is_error(max_entries):
		return max_entries
	p["max_entries"] = max_entries
	for spec in [["checks", CHECKS], ["scenes", []], ["dirs", ["res://"]]]:
		var v: Variant = params.get(spec[0], spec[1])
		if v is String:
			v = [v]
		if not v is Array or v.any(func(x): return not x is String):
			return Util.error(Util.INVALID_PARAMS, "'%s' must be a list of strings" % spec[0])
		p[spec[0]] = v
	for c in p.checks:
		if not c in CHECKS:
			return Util.error(Util.INVALID_PARAMS, "checks: unknown '%s' (one of %s)" % [c, ", ".join(CHECKS)])
	for s in p.scenes:
		if not String(s).begins_with("res://") or not String(s).ends_with(".tscn") or not FileAccess.file_exists(s):
			return Util.error(Util.INVALID_PARAMS, "scenes: %s is not a .tscn in the project" % s)
	for d in p.dirs:
		if not String(d).begins_with("res://"):
			return Util.error(Util.INVALID_PARAMS, "dirs: %s must be a res:// folder" % d)
	return p


## res:// files with these extensions under `dirs` (skipping addons, .godot,
## asset_sources and folders with a .gdignore), sorted, at most `limit`.
static func find_files(dirs: Array, extensions: Array, limit: int) -> Array:
	var out: Array = []
	var stack: Array = []
	for d in dirs:
		stack.append(Util.clean_dir(d))
	while not stack.is_empty() and out.size() < limit:
		var dir_path: String = stack.pop_front()
		if dir_path in SKIP_DIRS or not DirAccess.dir_exists_absolute(dir_path) or FileAccess.file_exists(dir_path.path_join(".gdignore")):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		var files := dir.get_files()
		files.sort()
		for f in files:
			if f.get_extension().to_lower() in extensions:
				out.append(dir_path.path_join(f))
				if out.size() >= limit:
					break
		var subs := dir.get_directories()
		subs.sort()
		for s in subs:
			if not s.begins_with("."):
				stack.append(dir_path.path_join(s))
	return out


static func _cap(list: Array, n: int) -> Variant:
	if list.size() <= n:
		return list
	return list.slice(0, n) + [{"more": list.size() - n}]


# =============================================================================
# scenes: placeholders and characters
# =============================================================================

func _scan_scenes(scenes: Array, p: Dictionary) -> Dictionary:
	var placeholders: Array = []
	var characters: Array = []
	var lib_roles: Array = []
	var lib := CharacterTools._load_library(p.library) if FileAccess.file_exists(p.library) else null
	if lib != null:
		for r in CharacterTools.ROLES:
			if lib.has_animation(r):
				lib_roles.append(r)
	var edited := Util.edited_root()
	for scene in scenes:
		var root: Node = null
		var temporary := false
		if edited != null and edited.scene_file_path == scene:
			root = edited
		else:
			var packed := ResourceLoader.load(scene, "PackedScene") as PackedScene
			if packed == null:
				continue
			root = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
			temporary = true
		if root == null:
			continue
		var groups := {}
		_collect(root, root, scene, groups)
		for key in groups:
			placeholders.append(groups[key])
		var character := _character_status(root, scene, lib_roles)
		if not character.is_empty():
			characters.append(character)
		if temporary:
			root.free()
	placeholders.sort_custom(func(a, b): return int(a.count) > int(b.count))
	return {"placeholders": placeholders, "characters": characters}


## Groups visible primitive meshes owned by `root` by scene + kind + group.
func _collect(node: Node, root: Node, scene: String, groups: Dictionary) -> void:
	if node is Node3D and not (node as Node3D).visible:
		return
	if node != root and node.owner != root and node.owner != null:
		## Inside an instanced scene: that scene's own file is audited.
		return
	if node.has_meta(SwapTools.SKIN_META) or node.is_in_group(&"no_asset_audit"):
		return
	if is_placeholder(node):
		var kind := placeholder_kind(node, root)
		var key := "%s|%s" % [scene, kind]
		if not groups.has(key):
			groups[key] = {"scene": scene, "kind": kind, "count": 0, "examples": []}
		groups[key].count += 1
		if groups[key].examples.size() < 3:
			groups[key].examples.append(Util.scene_path_of(node, root))
	for c in node.get_children():
		_collect(c, root, scene, groups)


static func is_placeholder(node: Node) -> bool:
	if node is CSGShape3D:
		return (node as CSGShape3D).get_parent() == null or not (node.get_parent() is CSGShape3D)
	if not node is MeshInstance3D:
		return false
	var mesh := (node as MeshInstance3D).mesh
	return mesh != null and mesh.get_class() in PRIMITIVES


## character (Body/Nose of a CharacterBody3D), weapon (Model next to a
## Muzzle), map:<group> (raid map Walls/Cover/Crates/Floors), other.
static func placeholder_kind(node: Node, root: Node) -> String:
	var name := String(node.name)
	if root is CharacterBody3D and name in ["Body", "Nose"]:
		return "character"
	var parent := node.get_parent()
	if name == "Model" and parent != null and parent.get_node_or_null(^"Muzzle") != null:
		return "weapon"
	var n := parent
	while n != null and n != root.get_parent():
		if String(n.name) in SwapTools.MAP_GROUPS:
			return "map:" + String(n.name)
		n = n.get_parent()
	return "other"


static func _character_status(root: Node, scene: String, lib_roles: Array) -> Dictionary:
	if not root is CharacterBody3D or root.get_node_or_null(^"Body") == null:
		return {}
	var target := "player" if root.get_node_or_null(^"Aim") != null else "enemy"
	var skin := CharacterTools._find_skin(root, target)
	var entry := {"scene": scene, "target": target}
	var id := scene.get_file().get_basename()
	if skin == null:
		entry["status"] = "placeholder"
		entry["fix"] = "%s: character_anim_setup target=%s%s model=<rigged .fbx> animations=[...] (swaps the capsule and animates it)" % [scene, target, "" if target == "player" else " asset_id=" + id]
		return entry
	var meta: Variant = skin.get_meta(SwapTools.SKIN_META) if skin.has_meta(SwapTools.SKIN_META) else {}
	entry["model"] = String(meta.get("model", "")) if meta is Dictionary else ""
	var tree := root.get_node_or_null(NodePath(CharacterTools.TREE_NAME))
	if tree == null or not tree.has_meta(CharacterTools.SETUP_META):
		entry["status"] = "model_without_animation"
		entry["fix"] = "%s: character_anim_setup target=%s%s (the model stands in T-pose until it is animated)" % [scene, target, "" if target == "player" else " asset_id=" + id]
		return entry
	entry["status"] = "animated"
	var setup: Variant = tree.get_meta(CharacterTools.SETUP_META)
	var roles: Array = setup.get("roles", []) if setup is Dictionary else []
	entry["roles"] = roles
	var missing := CORE_ROLES.filter(func(r): return not r in roles)
	if target == "player" and not "dodge" in roles:
		missing.append("dodge")
	if not missing.is_empty():
		entry["missing_clips"] = missing
		var in_lib := missing.filter(func(r): return r in lib_roles)
		entry["fix"] = "%s: %s" % [scene, "character_anim_setup again picks up %s from the library" % ", ".join(in_lib) if in_lib.size() == missing.size()
			else "download %s from Mixamo and run character_anim_setup animations=[...]" % ", ".join(missing)]
	return entry


static func _placeholder_hints(list: Array) -> Array:
	var out: Array = []
	var seen := {}
	for e in list:
		var hint := ""
		match String(e.kind):
			"weapon":
				hint = "%s: swap_placeholder target=weapon scene=%s (or asset_pipeline kind=weapon)" % [e.scene, e.scene]
			"other":
				hint = "%s: swap_placeholder target=node node_path=%s model=..." % [e.scene, e.examples[0]]
			_:
				if String(e.kind).begins_with("map:"):
					hint = "%s: swap_placeholder target=map group=%s model=... (open the scene first)" % [e.scene, String(e.kind).substr(4)]
		if not hint.is_empty() and not seen.has(hint):
			seen[hint] = true
			out.append(hint)
	return out.slice(0, 10)


# =============================================================================
# items
# =============================================================================

static func _audit_items(database_path: String) -> Dictionary:
	if not FileAccess.file_exists(database_path):
		return {"note": "no item database at %s (item_db_import makes one); items not checked" % database_path}
	var db := ResourceLoader.load(database_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var items: Variant = db.get("items") if db != null else null
	if not items is Array:
		return {"note": "%s has no items list" % database_path}
	var out := {"total": 0, "without_icon": [], "without_model": [], "broken": []}
	for it in items:
		if not it is Resource:
			continue
		out.total += 1
		var id := String(it.get("item_id"))
		var icon: Variant = it.get("icon")
		var model := String(it.get("model")) if it.get("model") != null else ""
		var has_model := not model.is_empty() and ResourceLoader.exists(model)
		if not model.is_empty() and not has_model:
			out.broken.append({"item_id": id, "model": model, "problem": "model file is gone"})
		if icon is Texture2D and not (icon as Texture2D).resource_path.is_empty() and not ResourceLoader.exists((icon as Texture2D).resource_path):
			out.broken.append({"item_id": id, "icon": (icon as Texture2D).resource_path, "problem": "icon file is gone"})
		if not icon is Texture2D:
			out.without_icon.append({"item_id": id, "has_model": has_model})
		if model.is_empty():
			out.without_model.append({"item_id": id, "category": String(it.get("category")) if it.get("category") != null else ""})
	return out


# =============================================================================
# budget
# =============================================================================

static func _audit_budget(assets_dir: String, extensions: Array = []) -> Dictionary:
	var models := find_files([assets_dir], extensions if not extensions.is_empty() else AssetTools.MODEL_EXTENSIONS, MAX_MODELS)
	var over: Array = []
	var checked := 0
	for path in models:
		## Animation sources only carry clips (their mesh, if any, is unused).
		if not ResourceLoader.exists(path) or String(path).trim_prefix(Util.clean_dir(assets_dir) + "/").begins_with("animations/"):
			continue
		var kind := _kind_of(path, assets_dir)
		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed == null:
			continue
		var root := packed.instantiate()
		if root == null:
			continue
		var stats := AssetTools.measure(root)
		root.free()
		checked += 1
		var budget: Dictionary = AssetTools.BUDGETS[kind]
		var problems: Array = []
		if stats.triangles > budget.triangles:
			problems.append("%d triangles (budget %d)" % [stats.triangles, budget.triangles])
		for t in stats.textures.values():
			if maxi(t.size[0], t.size[1]) > budget.texture:
				problems.append("texture %s %dx%d (budget %d)" % [t.name, t.size[0], t.size[1], budget.texture])
		if not problems.is_empty():
			over.append({"model": path, "kind": kind, "problems": problems})
	return {"over": over, "checked": checked}


## weapon/item/character/prop from res://assets/<kind>s/...; anything else
## (environment kits, materials) counts as a prop.
static func _kind_of(path: String, assets_dir: String) -> String:
	var rel := path.trim_prefix(Util.clean_dir(assets_dir) + "/")
	var top := rel.get_slice("/", 0)
	for kind in AssetTools.KIND_DIRS:
		if AssetTools.KIND_DIRS[kind] == top:
			return kind
	return "prop"

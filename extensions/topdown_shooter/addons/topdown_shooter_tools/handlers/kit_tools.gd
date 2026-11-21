@tool
extends RefCounted

## swap_placeholder target=kit: dresses a blockout map (raid_map_blockout's
## Floors / Walls / Cover, or the 3D hideout's Room) with a modular kit on a
## 1 m grid. Every box keeps its StaticBody3D, collision shape and therefore
## the navigation mesh (both bake from collision only); its placeholder mesh
## is hidden and a <Mesh>Skin sibling holds the kit pieces.
##
## A kit is a folder, res://assets/props/kit/<kit_id>/, of pieces named by
## role and length in grid cells:
##   wall_1m wall_2m wall_4m            walls (length along +X, origin at the
##                                      bottom center), stretched to the box's
##                                      height and thickness
##   low_wall_1m low_wall_2m low_wall_4m  low cover walls and the hideout's
##                                      near wall
##   floor_1m floor_2m floor_4m         square floor tiles (top at y=0)
##   pillar  box                        one per box, stretched to it
## Each piece may be a .glb/.gltf (an imported model) or a .tscn/.scn. A
## missing piece is generated as a .tscn from boxes and the kit materials
## (roles wall / floor / cover / trim: a res:// material or a polyhaven_fetch
## name), so a kit works before any model exists and a model can replace one
## piece at a time. Generated pieces carry kit_generated metadata and only
## those are rebuilt (rebuild_kit=true).
##
## A wall n cells long is split into the largest modules first (4, 2, 1);
## the leftover from corner overlaps is absorbed by stretching the modules
## slightly. Floors are split the same way on both axes.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const EnvTools := preload("res://addons/topdown_shooter_tools/handlers/env_tools.gd")

const KIT_ROOT := "res://assets/props/kit"
const DEFAULT_KIT := "kit"
const MODULES := [4, 2, 1]
const ROLES := ["wall", "low_wall", "floor", "pillar", "box"]
const MODULAR_ROLES := ["wall", "low_wall", "floor"]
const MATERIAL_ROLES := ["wall", "floor", "cover", "trim"]
## Map child -> how its boxes are sorted into roles.
const GROUPS := ["Floors", "Walls", "Cover", "Room"]
const PIECE_EXTENSIONS := ["glb", "gltf", "tscn", "scn"]
const GENERATED_META := &"kit_generated"
const MAX_PIECES := 20000
const LOW_WALL_MAX_HEIGHT := 1.5
## Neutral colors for pieces when no kit material is set.
const ROLE_COLORS := {
	"wall": Color(0.55, 0.55, 0.56),
	"floor": Color(0.45, 0.45, 0.46),
	"cover": Color(0.5, 0.48, 0.45),
	"trim": Color(0.32, 0.32, 0.34),
}
const PRESET_PATH := "res://assets/style_preset.json"
const MATERIAL_DIR := "res://assets/materials"


# =============================================================================
# params
# =============================================================================

## Adds the kit params to swap_placeholder's `p`. Returns p or an error.
static func read_params(params: Dictionary, p: Dictionary) -> Variant:
	var kit: Variant = Util.text(params, "kit", DEFAULT_KIT)
	var grid: Variant = Util.num(params, "grid", 1.0, 0.25, 8.0)
	var rebuild: Variant = Util.boolean(params, "rebuild_kit", false)
	for v in [kit, grid, rebuild]:
		if Util.is_error(v):
			return v
	if not AssetTools.is_asset_id(kit):
		return Util.error(Util.INVALID_PARAMS, "'kit' must be lowercase letters, digits and _ (the folder %s/<kit>)" % KIT_ROOT)
	p["kit"] = kit
	p["kit_dir"] = "%s/%s" % [KIT_ROOT, kit]
	p["grid"] = grid
	p["rebuild_kit"] = rebuild
	var groups: Variant = params.get("groups", null)
	if groups == null:
		p["groups"] = GROUPS.duplicate()
	elif groups is Array and not groups.is_empty() and groups.all(func(g): return g is String and g in GROUPS):
		p["groups"] = groups.duplicate()
	else:
		return Util.error(Util.INVALID_PARAMS, "'groups' must be a list of %s" % ", ".join(GROUPS))
	var materials: Variant = params.get("materials", {})
	if materials == null:
		materials = {}
	if not materials is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "'materials' must be {role: material}, roles %s" % ", ".join(MATERIAL_ROLES))
	var merged := preset_materials()
	for role in materials:
		if not role in MATERIAL_ROLES or not materials[role] is String:
			return Util.error(Util.INVALID_PARAMS, "'materials' keys are %s, values res:// materials or polyhaven_fetch names" % ", ".join(MATERIAL_ROLES))
		merged[role] = materials[role]
	var resolved := {}
	for role in merged:
		var path: Variant = resolve_material(String(merged[role]))
		if Util.is_error(path):
			return path
		if not String(path).is_empty():
			resolved[role] = path
	p["materials"] = resolved
	return p


## style_preset.json environment.kit_materials (game-specific art direction).
static func preset_materials() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(PRESET_PATH):
		return out
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRESET_PATH))
	if not data is Dictionary or not data.get("environment") is Dictionary:
		return out
	var mats: Variant = data.environment.get("kit_materials")
	if mats is Dictionary:
		for role in mats:
			if role in MATERIAL_ROLES and mats[role] is String and not String(mats[role]).is_empty():
				out[role] = mats[role]
	return out


## "" stays "", a res:// path must exist, a bare name is a polyhaven_fetch
## material (res://assets/materials/<name>/<name>.tres).
static func resolve_material(value: String) -> Variant:
	if value.is_empty():
		return ""
	var path := value
	if not value.begins_with("res://"):
		if not AssetTools.is_asset_id(value):
			return Util.error(Util.INVALID_PARAMS, "kit material '%s' must be a res:// material or a polyhaven_fetch name" % value)
		path = "%s/%s/%s.tres" % [MATERIAL_DIR, value, value]
	if not ResourceLoader.exists(path):
		return Util.error(Util.INVALID_PARAMS, "kit material %s not found%s" % [path, "" if value.begins_with("res://") else "; fetch it first: polyhaven_fetch asset=%s" % value])
	return path


# =============================================================================
# the kit
# =============================================================================

## Path of an existing piece file (models before generated scenes), or "".
static func find_piece(kit_dir: String, piece: String) -> String:
	for ext in PIECE_EXTENSIONS:
		var path := "%s/%s.%s" % [kit_dir, piece, ext]
		if FileAccess.file_exists(path) or ResourceLoader.exists(path):
			return path
	return ""


static func piece_names() -> Array:
	var out: Array = []
	for role in ROLES:
		if role in MODULAR_ROLES:
			for m in MODULES:
				out.append("%s_%dm" % [role, m])
		else:
			out.append(role)
	return out


## Finds every piece; generates the missing ones unless `dry`. Returns
## {pieces: {name: {path, aabb}}, generated: [names], kept: [names]} or an
## error. A dry run measures pieces it would generate from their spec.
static func ensure_kit(p: Dictionary, dry: bool) -> Variant:
	var pieces := {}
	var generated: Array = []
	var kept: Array = []
	for piece in piece_names():
		var path := find_piece(p.kit_dir, piece)
		var regenerate := path.is_empty()
		if not regenerate and p.rebuild_kit and path.get_extension() in ["tscn", "scn"]:
			var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
			var probe := packed.instantiate() if packed != null else null
			regenerate = probe != null and probe.has_meta(GENERATED_META)
			if probe != null:
				probe.free()
		if not regenerate:
			var aabb: Variant = measure_piece(path)
			if Util.is_error(aabb):
				return aabb
			pieces[piece] = {"path": path, "aabb": aabb}
			kept.append(piece)
			continue
		var target := "%s/%s.tscn" % [p.kit_dir, piece]
		var root := build_piece(piece, p.grid, p.materials)
		var box: AABB = AssetTools.measure(root).aabb
		if dry:
			root.free()
		else:
			var err := Util.save_scene(root, target)
			if not err.is_empty():
				return Util.error(Util.INTERNAL_ERROR, err)
			EnvTools.register_uid(target)
			ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE)
		pieces[piece] = {"path": target, "aabb": box}
		generated.append(piece)
	if not dry and not generated.is_empty():
		Util.refresh_filesystem(generated.map(func(n): return "%s/%s.tscn" % [p.kit_dir, n]))
	return {"pieces": pieces, "generated": generated, "kept": kept}


static func measure_piece(path: String) -> Variant:
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return Util.error(Util.INVALID_PARAMS, "kit piece %s is not a scene/model (import it with asset_import)" % path)
	var probe := packed.instantiate() as Node3D
	if probe == null:
		return Util.error(Util.INVALID_PARAMS, "kit piece %s has no 3D root" % path)
	var stats := AssetTools.measure(probe)
	var colliders := probe.find_children("*", "CollisionObject3D", true, false).size() + (1 if probe is CollisionObject3D else 0)
	probe.free()
	var box: AABB = stats.aabb
	if box.size.length() < 0.0001:
		return Util.error(Util.INVALID_PARAMS, "kit piece %s has no visible mesh" % path)
	if colliders > 0:
		return Util.error(Util.INVALID_PARAMS, "kit piece %s has its own collision; kit pieces are visual only (the blockout boxes keep the collision and the navigation). Re-import it without -col/-colonly." % path)
	return box


## A generated piece: a few boxes, origin at the bottom center (floors: top
## at y=0), length along +X. Panels sit proud of a darker core so the module
## seams read on the grid without gaps in the wall.
static func build_piece(piece: String, grid: float, materials: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = piece.to_pascal_case()
	root.set_meta(GENERATED_META, true)
	var role := piece
	var length := grid
	var at := piece.rfind("_")
	if piece.ends_with("m") and at > 0 and piece.substr(at + 1).trim_suffix("m").is_valid_int():
		role = piece.substr(0, at)
		length = grid * int(piece.substr(at + 1).trim_suffix("m"))
	var inset := 0.03 * grid
	match role:
		"wall", "low_wall":
			var h := 3.0 if role == "wall" else 1.0
			var t := 0.3 if role == "wall" else 0.5
			_part(root, "Core", Vector3(length, h, t * 0.8), Vector3(0, h / 2.0, 0), _mat(materials, "trim"))
			_part(root, "Panel", Vector3(length - 2.0 * inset, h * 0.86, t), Vector3(0, h * 0.5, 0), _mat(materials, "wall"))
			_part(root, "Cap", Vector3(length, h * 0.06, t * 1.1), Vector3(0, h * 0.97, 0), _mat(materials, "trim"))
		"floor":
			var th := 0.2
			_part(root, "Core", Vector3(length, th, length), Vector3(0, -th / 2.0 - 0.02, 0), _mat(materials, "trim"))
			_part(root, "Tile", Vector3(length - 2.0 * inset, 0.04, length - 2.0 * inset), Vector3(0, -0.02, 0), _mat(materials, "floor"))
		"pillar":
			_part(root, "Core", Vector3(grid, 3.0, grid), Vector3(0, 1.5, 0), _mat(materials, "trim"))
			_part(root, "Panel", Vector3(grid * 1.04, 2.5, grid * 0.9), Vector3(0, 1.5, 0), _mat(materials, "wall"))
		_:
			_part(root, "Core", Vector3(grid, grid * 0.9, grid), Vector3(0, grid * 0.45, 0), _mat(materials, "cover"))
			_part(root, "Lid", Vector3(grid * 1.04, grid * 0.1, grid * 1.04), Vector3(0, grid * 0.95, 0), _mat(materials, "trim"))
	return root


static func _part(root: Node3D, part_name: String, size: Vector3, center: Vector3, material: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	mi.mesh = mesh
	mi.position = center
	root.add_child(mi)
	mi.owner = root


static func _mat(materials: Dictionary, role: String) -> Material:
	if materials.has(role):
		var m := load(materials[role]) as Material
		if m != null:
			return m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ROLE_COLORS[role]
	mat.roughness = 0.9
	return mat


# =============================================================================
# planning
# =============================================================================

## The placeholders of every kit group in the open scene (or under
## map_path). [{host, hide, skin_name, box, label, role}] or an error.
static func find_placeholders(root: Node, p: Dictionary, placeholder_mesh: Callable, box_in: Callable) -> Variant:
	var search_root: Node = root
	if not p.map_path.is_empty():
		search_root = Util.resolve(p.map_path, root)
		if search_root == null:
			return Util.error(Util.NODE_NOT_FOUND, "map_path '%s' not found in the open scene" % p.map_path)
	var groups: Array = []
	var stack: Array[Node] = [search_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != root and n.owner != root:
			continue
		if String(n.name) in p.groups and n != search_root:
			groups.append(n)
			continue
		for c in n.get_children():
			stack.append(c)
	if groups.is_empty():
		return Util.error(Util.NODE_NOT_FOUND, "no %s group in the open scene (raid_map_blockout or hideout_scaffold style=map make them); pass map_path" % "/".join(p.groups))
	var out: Array = []
	for group in groups:
		for body in group.get_children():
			if not body is Node3D or body.owner != root:
				continue
			if not p.name_prefix.is_empty() and not String(body.name).begins_with(p.name_prefix):
				continue
			var mesh: MeshInstance3D = placeholder_mesh.call(body)
			if mesh == null or mesh.owner != root:
				continue
			var box: AABB = box_in.call(mesh, body)
			var role := role_for(String(group.name), String(body.name), box.size)
			if role.is_empty():
				continue
			out.append({"host": body, "hide": [mesh], "skin_name": String(mesh.name) + "Skin", "box": box,
				"label": Util.scene_path_of(body, root), "role": role})
	if out.is_empty():
		return Util.error(Util.NODE_NOT_FOUND, "no floor/wall/cover boxes (StaticBody3D with a Mesh child) under %s" % ", ".join(groups.map(func(g): return Util.scene_path_of(g, root))))
	return out


## Which kit role a blockout box gets ("" = leave it alone).
static func role_for(group: String, body: String, size: Vector3) -> String:
	var tall := size.y >= LOW_WALL_MAX_HEIGHT
	match group:
		"Floors":
			return "floor"
		"Walls":
			return "wall" if tall else "low_wall"
		"Cover":
			if body.begins_with("LowWall"):
				return "low_wall"
			if body.begins_with("Pillar"):
				return "pillar"
			if body.begins_with("Box"):
				return "box"
			var long_side := maxf(size.x, size.z)
			var short_side := maxf(minf(size.x, size.z), 0.001)
			if size.y >= 2.0:
				return "pillar"
			return "low_wall" if long_side / short_side >= 2.0 else "box"
		"Room":
			if body.begins_with("Floor"):
				return "floor"
			if body.begins_with("Wall"):
				return "wall" if tall else "low_wall"
	return ""


## Splits `cells` into module lengths, largest first.
static func split(cells: int, available: Array) -> Array:
	var out: Array = []
	var left := cells
	for m in available:
		while left >= m:
			out.append(m)
			left -= m
	return out


## Cells along a box side: the nearest whole number, at least 1.
static func cells_of(length: float, grid: float) -> int:
	return maxi(1, int(round(length / grid)))


## Pieces for one box: [[piece_name, Transform3D (host space)]].
static func pieces_for(role: String, box: AABB, kit: Dictionary, grid: float) -> Array:
	var out: Array = []
	var bs := box.size
	var base := Vector3(box.get_center().x, box.position.y, box.get_center().z)
	if role in ["pillar", "box"]:
		out.append([role, _stretch(kit[role].aabb, Vector3.ZERO, bs, base, false)])
		return out
	var modules: Array = MODULES.filter(func(m): return kit.has("%s_%dm" % [role, m]))
	if role == "floor":
		var nx := cells_of(bs.x, grid)
		var nz := cells_of(bs.z, grid)
		var sx := bs.x / (nx * grid)
		var sz := bs.z / (nz * grid)
		var x0 := box.position.x
		for wx in split(nx, modules):
			var z0 := box.position.z
			for wz in split(nz, modules):
				## A wx by wz block in squares of the smaller side.
				var m: int = mini(wx, wz)
				var piece := "floor_%dm" % m
				for i in int(float(wx) / m):
					for j in int(float(wz) / m):
						var size := Vector3(m * grid * sx, bs.y, m * grid * sz)
						var center := Vector3(x0 + (i + 0.5) * m * grid * sx, box.end.y, z0 + (j + 0.5) * m * grid * sz)
						out.append([piece, _stretch(kit[piece].aabb, Vector3.ZERO, size, center, true)])
				z0 += wz * grid * sz
			x0 += wx * grid * sx
		return out
	## Walls: modules along the long side.
	var along_x := bs.x >= bs.z
	var length := bs.x if along_x else bs.z
	var n := cells_of(length, grid)
	var s := length / (n * grid)
	var pos := -length / 2.0
	for m in split(n, modules):
		var piece := "%s_%dm" % [role, m]
		var seg: float = m * grid * s
		var center := base + (Vector3(pos + seg / 2.0, 0, 0) if along_x else Vector3(0, 0, pos + seg / 2.0))
		var size := Vector3(seg, bs.y, bs.z) if along_x else Vector3(bs.x, bs.y, seg)
		out.append([piece, _stretch(kit[piece].aabb, Vector3.ZERO, size, center, false, not along_x)])
		pos += seg
	return out


## Transform that maps the piece's box onto `size` at `anchor` (bottom
## center, or top center when `top`), turned 90 degrees when `turn` (the
## piece's length axis X then runs along Z).
static func _stretch(piece: AABB, _unused: Vector3, size: Vector3, anchor: Vector3, top: bool, turn := false) -> Transform3D:
	var ps := piece.size
	var target := Vector3(size.z, size.y, size.x) if turn else size
	var scale := Vector3(target.x / maxf(ps.x, 0.0001), target.y / maxf(ps.y, 0.0001), target.z / maxf(ps.z, 0.0001))
	var b := Basis(Vector3.UP, PI / 2.0 if turn else 0.0) * Basis.from_scale(scale)
	var from := Vector3(piece.get_center().x, piece.end.y if top else piece.position.y, piece.get_center().z)
	return Transform3D(b, anchor - b * from)


## The plan entries swap_tools applies. {swaps, kit, stats} or an error.
static func plan(root: Node, p: Dictionary, placeholder_mesh: Callable, box_in: Callable) -> Variant:
	var found: Variant = find_placeholders(root, p, placeholder_mesh, box_in)
	if Util.is_error(found):
		return found
	var kit := {}
	var kit_info := {"generated": [], "kept": []}
	if not p.revert:
		var ensured: Variant = ensure_kit(p, p.dry_run)
		if Util.is_error(ensured):
			return ensured
		kit = ensured.pieces
		kit_info = ensured
	var swaps: Array = []
	var total := 0
	var roles := {}
	var max_stretch := 0.0
	for ph in found:
		var swap := {
			"host": ph.host, "hide": ph.hide, "skin_name": ph.skin_name, "label": ph.label, "box": ph.box,
			"old_skin": ph.host.get_node_or_null(NodePath(ph.skin_name)), "transforms": [], "pieces": [],
			"muzzle": null, "muzzle_to": Vector3.ZERO, "fit": "kit:" + ph.role, "role": ph.role,
		}
		if p.revert:
			if swap.old_skin == null:
				continue
		else:
			for entry in pieces_for(ph.role, ph.box, kit, p.grid):
				swap.pieces.append([kit[entry[0]].path, entry[1]])
				swap.transforms.append(entry[1])
			total += swap.pieces.size()
			if total > MAX_PIECES:
				return Util.error(Util.INVALID_PARAMS, "more than %d kit pieces; narrow it with groups or name_prefix, or use a larger grid" % MAX_PIECES)
			if ph.role in MODULAR_ROLES:
				var bs: Vector3 = ph.box.size
				for length in ([bs.x, bs.z] if ph.role == "floor" else [maxf(bs.x, bs.z)]):
					var cells := cells_of(length, p.grid)
					max_stretch = maxf(max_stretch, absf(length / (cells * p.grid) - 1.0))
		roles[ph.role] = int(roles.get(ph.role, 0)) + 1
		swaps.append(swap)
	if swaps.is_empty():
		return Util.error(Util.NODE_NOT_FOUND, "nothing to revert: no kit skins found" if p.revert else "no placeholder found")
	return {"swaps": swaps, "model_box": AABB(), "model_has_muzzle": false,
		"kit": {"dir": p.kit_dir, "generated": kit_info.generated, "kept": kit_info.kept, "materials": p.materials},
		"stats": {"pieces": total, "roles": roles, "max_stretch": snappedf(max_stretch, 0.001)}}


## swap_placeholder's report for target=kit.
static func report(root: Node, p: Dictionary, plan_data: Dictionary) -> Dictionary:
	var swaps: Array = []
	for swap in plan_data.swaps:
		var entry := {"placeholder": swap.label, "role": swap.role, "skin": Util.scene_path_of(swap.host, root) + "/" + swap.skin_name}
		if not p.revert:
			entry["pieces"] = swap.pieces.size()
			entry["box"] = AssetTools._v3(swap.box.size)
			if swap.old_skin != null:
				entry["replaced_skin"] = true
		swaps.append(entry)
	var out := {"target": "kit"}
	out["reverted" if p.revert else "swapped"] = swaps.size()
	out["swaps"] = swaps if swaps.size() <= 30 else swaps.slice(0, 30) + [{"more": swaps.size() - 30}]
	if not p.revert:
		var kit: Dictionary = plan_data.kit
		out["kit"] = {"dir": kit.dir, "grid": p.grid, ("would_generate" if p.dry_run else "generated"): kit.generated, "existing": kit.kept,
			"materials": kit.materials if not kit.materials.is_empty() else "none (neutral colors); set style_preset.json environment.kit_materials or pass materials"}
		out["pieces"] = plan_data.stats.pieces
		out["by_role"] = plan_data.stats.roles
		out["max_stretch"] = plan_data.stats.max_stretch
		out["kept"] = "Collision shapes and the navigation mesh are unchanged (both come from the blockout boxes; kit pieces have no collision). The placeholder meshes are hidden, not deleted."
		if not kit.generated.is_empty() and not p.dry_run:
			out["kit_note"] = "Generated pieces stay in %s after an undo. Replace any of them with a model of the same name (wall_2m.glb ...) and rerun." % kit.dir
	return out

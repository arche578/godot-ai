@tool
extends RefCounted

## character_anim_setup: animates a rigged character with a shared,
## retargeted humanoid animation library.
##
## 1. The rigged model (Mixamo, Meshy, Tripo, ...) and the animation files
##    (Mixamo FBX "without skin", one clip per file) are copied into the
##    project and imported with a BoneMap onto Godot's SkeletonProfileHumanoid
##    (the bone map is guessed from the bone names). The importer renames
##    the bones to the profile and the skeleton to %GeneralSkeleton, so every
##    clip fits every character, whatever rig it came from.
## 2. Each clip gets a role from its file name (idle, walk, run, aim, fire,
##    reload, dodge, hit, death, attack, walk_back, strafe_left/right),
##    is made in-place, looped where it should be, and goes into one
##    AnimationLibrary (res://assets/animations/humanoid/humanoid.res).
## 3. The model replaces the Body placeholder (swap_placeholder), and the
##    scene gets an AnimationTree built from the roles it has plus a
##    CharacterAnimator node (templates/character_animator.gd) that feeds it
##    movement speed, AI state, died, damage, weapon fire/reload and dodge,
##    and keeps the weapon mount in the hand while the game runs.
##
## Files: one undo step; the swap and the scene edit: one each.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const SwapTools := preload("res://addons/topdown_shooter_tools/handlers/swap_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")

const TARGETS := ["player", "enemy"]
const ROLES := ["idle", "walk", "run", "walk_back", "strafe_left", "strafe_right", "aim", "fire", "reload", "dodge", "hit", "death", "attack"]
const LOOP_ROLES := ["idle", "walk", "run", "walk_back", "strafe_left", "strafe_right", "aim"]
## One-shot clips, in tree order (later ones play over earlier ones).
const ONE_SHOT_ROLES := ["hit", "fire", "reload", "attack", "dodge"]
const UPPER_BODY_ROLES := ["hit", "fire", "reload"]
## File/clip name words -> role, checked in this order.
const ROLE_WORDS := [
	["death", ["death", "dying", "die", "dead", "killed"]],
	["hit", ["hit", "impact", "hurt", "damage", "reaction"]],
	["reload", ["reload", "reloading"]],
	["fire", ["fire", "firing", "shoot", "shooting", "shot", "recoil"]],
	["dodge", ["roll", "dodge", "dive", "evade"]],
	["attack", ["punch", "punching", "attack", "attacking", "melee", "swipe", "swiping", "slash", "slashing", "stab", "stabbing", "kick", "kicking", "hook", "jab"]],
	["aim", ["aim", "aiming"]],
	["strafe_left", ["strafe left", "left strafe", "strafing left", "left strafing"]],
	["strafe_right", ["strafe right", "right strafe", "strafing right", "right strafing"]],
	["walk_back", ["backward", "backwards", "walk back", "walking back"]],
	["run", ["run", "running", "sprint", "sprinting", "jog", "jogging"]],
	["walk", ["walk", "walking"]],
	["idle", ["idle", "breathing", "standing", "stand"]],
]

const ANIM_EXTENSIONS := ["fbx", "glb", "gltf"]
const DEFAULT_LIBRARY := "res://assets/animations/humanoid/humanoid.res"
const DEFAULT_ANIM_DIR := "res://assets/animations/humanoid/sources"
const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const LIBRARY_NAME := "humanoid"
const SKELETON_NAME := "GeneralSkeleton"
const TRACK_PREFIX := "%GeneralSkeleton:"
const TREE_NAME := "AnimationTree"
const ANIMATOR_NAME := "CharacterAnimator"
const SETUP_META := &"character_anim_setup"
const MAX_FILES := 40

## Bones a humanoid retarget cannot do without.
const REQUIRED_BONES := ["Hips", "Spine", "Head",
	"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]
## Profile bones a one-shot upper-body clip moves (hips and legs keep walking).
const UPPER_BONES := ["Spine", "Chest", "UpperChest", "Neck", "Head", "Jaw", "LeftEye", "RightEye"]
const ARM_BONES := ["Shoulder", "UpperArm", "LowerArm", "Hand",
	"ThumbMetacarpal", "ThumbProximal", "ThumbDistal", "IndexProximal", "IndexIntermediate", "IndexDistal",
	"MiddleProximal", "MiddleIntermediate", "MiddleDistal", "RingProximal", "RingIntermediate", "RingDistal",
	"LittleProximal", "LittleIntermediate", "LittleDistal"]

## Side-less bone keys (lowercase, no separators) -> profile bone suffix.
const SIDE_BONES := {
	"shoulder": "Shoulder", "clavicle": "Shoulder", "collar": "Shoulder", "collarbone": "Shoulder",
	"arm": "UpperArm", "upperarm": "UpperArm", "uparm": "UpperArm", "armupper": "UpperArm",
	"forearm": "LowerArm", "lowerarm": "LowerArm", "armlower": "LowerArm", "elbow": "LowerArm",
	"hand": "Hand", "wrist": "Hand",
	"upleg": "UpperLeg", "upperleg": "UpperLeg", "thigh": "UpperLeg", "legupper": "UpperLeg",
	"leg": "LowerLeg", "lowerleg": "LowerLeg", "calf": "LowerLeg", "shin": "LowerLeg", "knee": "LowerLeg", "leglower": "LowerLeg",
	"foot": "Foot", "ankle": "Foot",
	"toebase": "Toes", "toes": "Toes", "toe": "Toes", "ball": "Toes",
	"eye": "Eye",
}
const CENTER_BONES := {"hips": "Hips", "hip": "Hips", "pelvis": "Hips", "neck": "Neck", "neck1": "Neck", "neck01": "Neck", "head": "Head", "jaw": "Jaw"}
const FINGERS := {"thumb": "Thumb", "index": "Index", "middle": "Middle", "ring": "Ring", "pinky": "Little", "little": "Little"}
const FINGER_JOINTS := {"Thumb": ["Metacarpal", "Proximal", "Distal"], "_": ["Proximal", "Intermediate", "Distal"]}


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func character_anim_setup(params: Dictionary, ctx = null) -> Dictionary:
	var p: Variant = read_params(params)
	if Util.is_error(p):
		return p
	var plan: Variant = _plan(p)
	if Util.is_error(plan):
		return plan
	if p.dry_run:
		return {"data": _dry_report(p, plan)}
	var copied: Variant = _copy_sources(p, plan)
	if Util.is_error(copied):
		return copied
	var pending := _start_imports(plan)
	if pending.is_empty():
		return _continue(p, plan)
	if ctx == null or not ctx.has_method("send_deferred"):
		return {"data": {"import_pending": pending, "copied": plan.copied,
			"note": "the editor imports %s on its next file scan; call character_anim_setup again with the same parameters once it is done" % ", ".join(pending)}}
	_continue_async(p, plan, pending, ctx)
	return {"_deferred": true}


func _continue_async(p: Dictionary, plan: Dictionary, pending: Array, ctx) -> void:
	var deadline := Time.get_ticks_msec() + int(AssetTools.IMPORT_WAIT_SEC * 1000.0)
	if "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		deadline = mini(deadline, int(ctx.deadline_msec) - AssetTools.REPLY_MARGIN_MSEC - 15000)
	var state := await _wait_imports(pending, deadline)
	if not state.failed.is_empty():
		ctx.send_deferred(Util.error(Util.INTERNAL_ERROR, "the editor could not import %s (see the Output panel). An FBX needs Godot's built-in FBX importer (ufbx); re-download it as FBX Binary, or export it to .glb." % ", ".join(state.failed)))
		return
	if not state.waiting.is_empty():
		ctx.send_deferred({"data": {"import_pending": state.waiting, "copied": plan.copied,
			"note": "the editor had not imported %s in time. Focus the Godot window, then call character_anim_setup again with the same parameters (copied files are kept)." % ", ".join(state.waiting)}})
		return
	ctx.send_deferred(_continue(p, plan))


## Waits until each path is imported or its import failed. Coroutine.
## {failed: [...], waiting: [...]}
func _wait_imports(paths: Array, deadline: int) -> Dictionary:
	var efs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	var scanned := false
	while true:
		var failed: Array = []
		var waiting: Array = []
		var idle := not efs.is_scanning() and not efs.is_importing()
		for path in paths:
			if AssetTools._import_valid(path):
				continue
			if idle and scanned and _import_failed(path):
				failed.append(path)
			else:
				waiting.append(path)
		if waiting.is_empty() or Time.get_ticks_msec() >= deadline:
			return {"failed": failed, "waiting": waiting}
		if idle and not scanned:
			scanned = true
			efs.scan_sources()
		elif idle:
			## Known now but not imported: ask for it once more.
			var known: PackedStringArray = []
			for path in waiting:
				if AssetTools.folder_known(String(path).get_base_dir()) and not FileAccess.file_exists(path + ".import.lock"):
					efs.update_file(path)
					known.append(path)
			if not known.is_empty() and not _import_failed(known[0]):
				efs.reimport_files(known)
		await tree.create_timer(0.3).timeout
	return {"failed": [], "waiting": paths}


## The editor tried and gave up (it writes valid=false into the .import).
static func _import_failed(path: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path + ".import") != OK:
		return false
	return cfg.get_value("remap", "valid", true) == false


# =============================================================================
# parameters and plan
# =============================================================================

static func read_params(params: Dictionary) -> Variant:
	var allowed := ["target", "scene", "asset_id", "model", "animations", "clips", "library", "anim_dir", "in_place",
		"walk_speed", "run_speed", "weapon_follow", "hand", "grip_offset", "upper_body", "swap", "yaw_degrees",
		"script_dir", "overwrite", "overwrite_scripts", "dry_run"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var p := {}
	for spec in [["target", ""], ["scene", ""], ["asset_id", ""], ["model", ""], ["library", DEFAULT_LIBRARY],
			["anim_dir", DEFAULT_ANIM_DIR], ["weapon_follow", "hand_position"], ["hand", "right"], ["script_dir", DEFAULT_SCRIPT_DIR]]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for spec in [["in_place", true], ["upper_body", true], ["swap", true], ["overwrite", false], ["overwrite_scripts", false], ["dry_run", false]]:
		var v: Variant = Util.boolean(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for spec in [["walk_speed", 1.6, 0.1, 20.0], ["run_speed", 4.0, 0.1, 40.0], ["yaw_degrees", 0.0, -360.0, 360.0]]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var grip: Variant = Util.vec3(params, "grip_offset", Vector3.ZERO)
	if Util.is_error(grip):
		return grip
	p["grip_offset"] = grip
	if not p.target in TARGETS:
		return Util.error(Util.INVALID_PARAMS, "'target' must be one of %s" % ", ".join(TARGETS))
	if not p.weapon_follow in ["hand_position", "hand", "none"]:
		return Util.error(Util.INVALID_PARAMS, "'weapon_follow' must be hand_position, hand or none")
	if not p.hand in ["right", "left"]:
		return Util.error(Util.INVALID_PARAMS, "'hand' must be right or left")
	if p.walk_speed >= p.run_speed:
		return Util.error(Util.INVALID_PARAMS, "walk_speed must be below run_speed")
	if not p.asset_id.is_empty() and not AssetTools.is_asset_id(p.asset_id):
		return Util.error(Util.INVALID_PARAMS, "'asset_id' must be lowercase letters, digits and _ (e.g. player, grunt)")
	if p.asset_id.is_empty():
		if p.target == "player":
			p.asset_id = "player"
		else:
			return Util.error(Util.INVALID_PARAMS, "target=enemy needs asset_id (the enemy id, e.g. grunt: scene res://scenes/enemies/grunt.tscn, model res://assets/characters/grunt/)")
	if p.scene.is_empty():
		p.scene = SwapTools.DEFAULT_PLAYER_SCENE if p.target == "player" else "%s/%s.tscn" % [SwapTools.DEFAULT_ENEMY_DIR, p.asset_id]
	for spec in [[p.scene, "tscn"], [p.library, "res"]]:
		var reason := Util.check_res_path(spec[0])
		if not reason.is_empty():
			return Util.error(Util.INVALID_PARAMS, reason)
	if not p.library.get_extension() in ["res", "tres"]:
		return Util.error(Util.INVALID_PARAMS, "'library' must be a .res or .tres file")
	if not p.scene.ends_with(".tscn"):
		return Util.error(Util.INVALID_PARAMS, "'scene' must be a .tscn file")
	p.anim_dir = Util.clean_dir(p.anim_dir)
	p.script_dir = Util.clean_dir(p.script_dir)
	for dir in [p.anim_dir, p.script_dir]:
		if not String(dir).begins_with("res://"):
			return Util.error(Util.INVALID_PARAMS, "%s must be a res:// folder" % dir)
	if String(p.anim_dir).begins_with(AssetTools.SOURCES_ROOT):
		return Util.error(Util.INVALID_PARAMS, "anim_dir must not be inside %s (the editor ignores that folder)" % AssetTools.SOURCES_ROOT)

	## animations: a list of files/folders, or one string.
	var anims: Variant = params.get("animations", [])
	if anims is String:
		anims = [anims] if not String(anims).is_empty() else []
	if not anims is Array:
		return Util.error(Util.INVALID_PARAMS, "'animations' must be a list of files or folders (FBX/GLB)")
	for a in anims:
		if not a is String or String(a).is_empty():
			return Util.error(Util.INVALID_PARAMS, "'animations' entries must be file or folder paths")
	p["animations"] = anims
	var clips: Variant = params.get("clips", {})
	if not clips is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "'clips' must be {role: file or clip name}, e.g. {\"fire\": \"Firing Rifle\"}")
	for role in clips:
		if not role in ROLES:
			return Util.error(Util.INVALID_PARAMS, "clips: unknown role '%s' (roles: %s)" % [role, ", ".join(ROLES)])
		if not clips[role] is String:
			return Util.error(Util.INVALID_PARAMS, "clips.%s must be a file or clip name" % role)
	p["clips"] = clips
	return p


## {model: {source, dest, copy}, anims: [{source, dest, copy}], copied: []}
func _plan(p: Dictionary) -> Variant:
	if not FileAccess.file_exists(p.scene):
		return Util.error(Util.INVALID_PARAMS, "scene %s not found (make it with %s first)" % [p.scene, "player_controller_scaffold" if p.target == "player" else "enemy_ai_scaffold"])
	var plan := {"copied": [], "anims": [], "model": {}}
	## The model: model=<file> (copied into the rule folder) or the rule folder.
	var model_dir := AssetTools.default_dest_dir("character", p.asset_id)
	if p.model.is_empty():
		var found := AssetTools.default_model_path("character", p.asset_id)
		if not FileAccess.file_exists(found):
			return Util.error(Util.INVALID_PARAMS, "no model in %s; pass model=<rigged .fbx/.glb> (e.g. ~/Downloads/%s.fbx from Mixamo)" % [model_dir, p.asset_id])
		plan.model = {"source": found, "dest": found, "copy": false}
	else:
		var src := AssetTools.resolve_source(p.model)
		var ext := src.get_extension().to_lower()
		if not ext in ANIM_EXTENSIONS:
			return Util.error(Util.INVALID_PARAMS, "model must be a rigged .fbx, .glb or .gltf")
		if src.begins_with("res://"):
			if not FileAccess.file_exists(src):
				return Util.error(Util.INVALID_PARAMS, "model %s not found" % src)
			plan.model = {"source": src, "dest": src, "copy": false, "is_model": true}
		else:
			if not FileAccess.file_exists(src):
				return Util.error(Util.INVALID_PARAMS, "model file not found: %s" % src)
			var dest := "%s/%s.%s" % [model_dir, p.asset_id, ext]
			var conflict := _copy_conflict(src, dest, p.overwrite)
			if not conflict.is_empty():
				return conflict
			plan.model = {"source": src, "dest": dest, "copy": true, "is_model": true}

	## Animation files.
	var files: Array[String] = []
	for entry in p.animations:
		var path := AssetTools.resolve_source(entry)
		if DirAccess.dir_exists_absolute(path):
			var dir := DirAccess.open(path)
			if dir == null:
				return Util.error(Util.INVALID_PARAMS, "cannot open folder %s" % path)
			var names := dir.get_files()
			names.sort()
			for name in names:
				if name.get_extension().to_lower() in ANIM_EXTENSIONS:
					files.append(path.path_join(name))
		elif FileAccess.file_exists(path):
			if not path.get_extension().to_lower() in ANIM_EXTENSIONS:
				return Util.error(Util.INVALID_PARAMS, "%s is not an animation file (.fbx/.glb/.gltf)" % path)
			files.append(path)
		else:
			return Util.error(Util.INVALID_PARAMS, "animation file or folder not found: %s" % path)
	if files.size() > MAX_FILES:
		return Util.error(Util.INVALID_PARAMS, "%d animation files; at most %d per call" % [files.size(), MAX_FILES])
	var seen := {}
	for src in files:
		if src == plan.model.source:
			continue
		var dest := src
		var copy := false
		if not src.begins_with("res://"):
			dest = p.anim_dir.path_join(_file_id(src) + "." + src.get_extension().to_lower())
			copy = true
			var conflict := _copy_conflict(src, dest, true)
			if not conflict.is_empty():
				return conflict
		if seen.has(dest):
			return Util.error(Util.INVALID_PARAMS, "two animation files would both become %s; rename one" % dest)
		seen[dest] = true
		plan.anims.append({"source": src, "dest": dest, "copy": copy, "label": src.get_file().get_basename()})
	var existing := _load_library(p.library)
	if plan.anims.is_empty() and (existing == null or existing.get_animation_list().is_empty()):
		return Util.error(Util.INVALID_PARAMS, "no animations yet: pass animations=[files or a folder] (Mixamo FBX, 'Without Skin', 'In Place'); later characters reuse %s" % p.library)
	return plan


## A project file name from a download name: "Rifle Walk (1).fbx" -> rifle_walk_1.
static func _file_id(path: String) -> String:
	var base := path.get_file().get_basename().to_lower()
	var out := ""
	for ch in base:
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.trim_prefix("_").trim_suffix("_")
	return out if not out.is_empty() else "clip"


static func _copy_conflict(src: String, dest: String, same_ok: bool) -> Dictionary:
	if not FileAccess.file_exists(dest):
		return {}
	## Animation sources (same_ok): a changed download replaces the old copy.
	if same_ok or FileAccess.get_file_as_bytes(src) == FileAccess.get_file_as_bytes(dest):
		return {}
	return Util.error(Util.ALREADY_EXISTS, "%s already exists with other content; pass overwrite=true to replace it" % dest)


## Role for a file or clip name, or "".
static func guess_role(name: String) -> String:
	var words := " " + _words(name) + " "
	for entry in ROLE_WORDS:
		for w in entry[1]:
			if words.contains(" " + w + " "):
				return entry[0]
	return ""


static func _words(name: String) -> String:
	var out := ""
	var prev := ""
	for ch in name:
		## Split camelCase too: RifleWalk -> rifle walk.
		if ch >= "A" and ch <= "Z" and prev >= "a" and prev <= "z":
			out += " "
		var lower := ch.to_lower()
		out += lower if (lower >= "a" and lower <= "z") else " "
		prev = ch
	while out.contains("  "):
		out = out.replace("  ", " ")
	return out.strip_edges()


# =============================================================================
# copying and importing
# =============================================================================

func _copy_sources(p: Dictionary, plan: Dictionary) -> Variant:
	var entries: Array = [plan.model] + plan.anims
	var targets: Array = []
	for e in entries:
		if e.copy:
			targets.append(e.dest)
		targets.append(e.dest + ".import")
	var before := ItemTools.FileSnapshot.capture(targets)
	plan["snapshot_paths"] = targets
	plan["before"] = before
	for e in entries:
		var is_model: bool = e.get("is_model", false)
		if e.copy:
			var bytes := FileAccess.get_file_as_bytes(e.source)
			if bytes.is_empty():
				before.restore()
				return Util.error(Util.INTERNAL_ERROR, "cannot read %s: %s" % [e.source, error_string(FileAccess.get_open_error())])
			var same := FileAccess.file_exists(e.dest) and FileAccess.get_file_as_bytes(e.dest) == bytes
			if not same:
				Util.ensure_dir(String(e.dest).get_base_dir())
				var f := FileAccess.open(e.dest, FileAccess.WRITE)
				if f == null:
					before.restore()
					return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [e.dest, error_string(FileAccess.get_open_error())])
				f.store_buffer(bytes)
				f.close()
				plan.copied.append(e.dest)
				e["changed"] = true
		var wrote: Variant = _write_base_import(e.dest, is_model)
		if wrote is String:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, wrote)
		if wrote:
			e["changed"] = true
	return true


## Our import settings, keeping the file's other keys (and a bone map set
## by an earlier run). Returns true when the file changed, false when it
## already had them, or an error message.
static func _write_base_import(path: String, is_model: bool) -> Variant:
	var cfg_path := path + ".import"
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(cfg_path):
		cfg.load(cfg_path)
	var changed := false
	for spec in [["remap", "importer", "scene"], ["remap", "importer_version", 1], ["remap", "type", "PackedScene"], ["deps", "source_file", path]]:
		if not cfg.has_section_key(spec[0], spec[1]) or cfg.get_value(spec[0], spec[1]) != spec[2]:
			cfg.set_value(spec[0], spec[1], spec[2])
			changed = true
	var settings := {
		"nodes/apply_root_scale": true,
		"skins/use_named_skins": true,
		"animation/import": true,
		"animation/fps": 30,
		"animation/remove_immutable_tracks": true,
	}
	if path.get_extension().to_lower() == "fbx":
		## Godot's built-in importer (ufbx); 1 would need the FBX2glTF tool.
		settings["fbx/importer"] = 0
	if is_model:
		settings.merge({"meshes/ensure_tangents": true, "meshes/generate_lods": true, "meshes/create_shadow_meshes": true, "meshes/light_baking": 1})
	else:
		settings.merge({"meshes/generate_lods": false, "meshes/create_shadow_meshes": false})
	for key in settings:
		var forced: bool = key == "fbx/importer"
		if not cfg.has_section_key("params", key) or (forced and cfg.get_value("params", key) != settings[key]):
			cfg.set_value("params", key, settings[key])
			changed = true
	if not changed:
		return false
	var err := cfg.save(cfg_path)
	return true if err == OK else "cannot write %s: %s" % [cfg_path, error_string(err)]


## Imports what is not imported yet where it can be done at once (a folder
## the editor knows). Returns the paths that wait for the editor's scan.
func _start_imports(plan: Dictionary) -> Array:
	var entries: Array = [plan.model] + plan.anims
	var now: PackedStringArray = []
	var pending: Array = []
	var efs := EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	for e in entries:
		var path: String = e.dest
		if not e.get("changed", false) and AssetTools._import_valid(path):
			continue
		if efs != null and AssetTools.folder_known(path.get_base_dir()) and not efs.is_scanning() and not efs.is_importing():
			efs.update_file(path)
			now.append(path)
		else:
			pending.append(path)
	if not now.is_empty():
		efs.reimport_files(now)
	if not pending.is_empty() and efs != null and not efs.is_scanning():
		efs.scan_sources()
	return pending


# =============================================================================
# retargeting
# =============================================================================

## {path, skeleton_path, bones: [names], parents: [int], retargeted, clips: [names], meshes}
static func skeleton_info(path: String) -> Dictionary:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return {"error": "cannot load %s as a scene (see the Output panel for import errors)" % path}
	var root := packed.instantiate()
	if root == null:
		return {"error": "%s has no root node" % path}
	var info := {"path": path, "skeleton_path": "", "bones": [], "parents": [], "retargeted": false, "clips": [], "meshes": 0}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Skeleton3D and info.skeleton_path.is_empty():
			var sk := n as Skeleton3D
			info.skeleton_path = String(root.get_path_to(sk))
			for i in sk.get_bone_count():
				info.bones.append(sk.get_bone_name(i))
				info.parents.append(sk.get_bone_parent(i))
			info.retargeted = String(sk.name) == SKELETON_NAME and sk.find_bone("Hips") >= 0
		elif n is MeshInstance3D:
			info.meshes += 1
		elif n is AnimationPlayer:
			for a in (n as AnimationPlayer).get_animation_list():
				if String(a) != "RESET" and not String(a).ends_with("/RESET"):
					info.clips.append(String(a))
					info["lengths"] = info.get("lengths", {})
					info.lengths[String(a)] = (n as AnimationPlayer).get_animation(a).length
		for c in n.get_children():
			stack.append(c)
	root.free()
	return info


## Guesses profile bone -> skeleton bone from names (Mixamo, Meshy, Tripo,
## Unreal, Rigify-like). Returns {map: {profile: bone}, missing: [required]}.
static func auto_bone_map(bones: Array, parents: Array) -> Dictionary:
	var map := {}
	var spine: Array = []   ## [depth, index]
	for i in bones.size():
		var parsed := _parse_bone(String(bones[i]))
		if parsed.is_empty():
			continue
		var profile := ""
		var key: String = parsed.key
		if parsed.side.is_empty():
			if CENTER_BONES.has(key):
				profile = CENTER_BONES[key]
			elif RegEx.create_from_string("^(spine\\d*|chest|upperchest|torso)$").search(key) != null:
				spine.append([_depth(i, parents), i])
				continue
		else:
			var side: String = "Left" if parsed.side == "l" else "Right"
			var finger := RegEx.create_from_string("^(?:hand)?(thumb|index|middle|ring|pinky|little)(\\d)$").search(key)
			if finger != null:
				var f: String = FINGERS[finger.get_string(1)]
				var joints: Array = FINGER_JOINTS["Thumb"] if f == "Thumb" else FINGER_JOINTS["_"]
				var n := int(finger.get_string(2))
				## Some rigs count from 0 (thumb_01 / thumb0).
				if n >= 1 and n <= 3:
					profile = side + f + joints[n - 1]
			elif SIDE_BONES.has(key):
				profile = side + SIDE_BONES[key]
		if not profile.is_empty() and not map.has(profile):
			map[profile] = String(bones[i])
	spine.sort_custom(func(a, b): return a[0] < b[0])
	var chain := ["Spine", "Chest", "UpperChest"]
	if spine.size() >= 1:
		map["Spine"] = String(bones[spine[0][1]])
	if spine.size() >= 2:
		map["Chest"] = String(bones[spine[1][1]])
	if spine.size() >= 3:
		map["UpperChest"] = String(bones[spine[spine.size() - 1][1]])
	var missing: Array = []
	for b in REQUIRED_BONES:
		if not map.has(b):
			missing.append(b)
	return {"map": map, "missing": missing}


## {side: "l"|"r"|"", key: "upperarm"} or {} for end/helper bones.
static func _parse_bone(name: String) -> Dictionary:
	var n := name
	if n.contains(":"):
		n = n.get_slice(":", n.get_slice_count(":") - 1)
	n = n.to_lower()
	var prefix := RegEx.create_from_string("^(mixamorig\\d*|bip0*1|armature|def|cc_base|j_bip)[_\\-. ]*")
	n = prefix.sub(n, "")
	if n.ends_with("end") or n.ends_with("_nub") or n.ends_with("nub") or n.contains("twist") or n.contains("ik"):
		return {}
	var side := ""
	for spec in [["left", "l"], ["right", "r"]]:
		if n.begins_with(spec[0]):
			side = spec[1]
			n = n.substr(spec[0].length())
			break
	if side.is_empty():
		var lead := RegEx.create_from_string("^([lr])[_\\-. ]+").search(n)
		if lead != null:
			side = lead.get_string(1)
			n = n.substr(lead.get_end())
	if side.is_empty():
		var tail := RegEx.create_from_string("[_\\-. ]([lr])$").search(n)
		if tail != null:
			side = tail.get_string(1)
			n = n.substr(0, tail.get_start())
	if side.is_empty():
		for spec in [["left", "l"], ["right", "r"]]:
			if n.ends_with(spec[0]):
				side = spec[1]
				n = n.substr(0, n.length() - spec[0].length())
				break
	var key := ""
	for ch in n:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			key += ch
	## spine_01 -> spine1, neck_01 -> neck1, thumb_01 -> thumb1.
	key = RegEx.create_from_string("0(\\d)$").sub(key, "$1")
	return {"side": side, "key": key} if not key.is_empty() else {}


static func _depth(index: int, parents: Array) -> int:
	var d := 0
	var i := index
	while i >= 0 and d < 512:
		i = int(parents[i])
		d += 1
	return d


static func bone_map_path(source: String) -> String:
	return source.get_basename() + "_bone_map.tres"


## Writes a BoneMap for each file that is not retargeted yet and puts it in
## the file's import settings. Returns {retargeted: [paths], maps: {...}} or
## an error.
func _retarget(plan: Dictionary) -> Variant:
	var entries: Array = [plan.model] + plan.anims
	var reimport: PackedStringArray = []
	var maps := {}
	for e in entries:
		var info := skeleton_info(e.dest)
		if info.has("error"):
			return Util.error(Util.INTERNAL_ERROR, info.error)
		e["info"] = info
		if info.skeleton_path.is_empty():
			return Util.error(Util.INVALID_PARAMS, "%s has no skeleton; %s" % [e.dest,
				"rig the character first (Mixamo auto-rigger: upload it, then Download FBX 'With Skin')" if e.get("is_model", false) else "export the animation with its skeleton (Mixamo: FBX, 'Without Skin' is fine)"])
		if info.retargeted:
			continue
		var guess := auto_bone_map(info.bones, info.parents)
		if not guess.missing.is_empty():
			return Util.error(Util.INVALID_PARAMS, "%s: no bone found for %s (bones: %s). Use a Mixamo-rigged file, or set the bone map in the import dock (Retarget > Bone Map) and run again." % [
				e.dest, ", ".join(guess.missing), ", ".join(info.bones.slice(0, 40))])
		var bm := BoneMap.new()
		bm.profile = SkeletonProfileHumanoid.new()
		for profile_bone in guess.map:
			bm.set_skeleton_bone_name(profile_bone, guess.map[profile_bone])
		var bm_path := bone_map_path(e.dest)
		plan.snapshot_paths.append(bm_path)
		if not plan.before.files.has(bm_path):
			plan.before.files[bm_path] = FileAccess.get_file_as_bytes(bm_path) if FileAccess.file_exists(bm_path) else null
		var err := Util.save_resource(bm, bm_path)
		if not err.is_empty():
			return Util.error(Util.INTERNAL_ERROR, err)
		var saved := ResourceLoader.load(bm_path, "BoneMap", ResourceLoader.CACHE_MODE_REPLACE)
		var cfg := ConfigFile.new()
		if cfg.load(e.dest + ".import") != OK:
			return Util.error(Util.INTERNAL_ERROR, "cannot read %s.import" % e.dest)
		var sub: Variant = cfg.get_value("params", "_subresources", {})
		if not sub is Dictionary:
			sub = {}
		var nodes: Dictionary = sub.get("nodes", {})
		var opts: Dictionary = nodes.get("PATH:" + info.skeleton_path, {})
		opts["retarget/bone_map"] = saved
		if not e.get("is_model", false):
			opts["retarget/remove_tracks/unmapped_bones"] = true
		nodes["PATH:" + info.skeleton_path] = opts
		sub["nodes"] = nodes
		cfg.set_value("params", "_subresources", sub)
		var save_err := cfg.save(e.dest + ".import")
		if save_err != OK:
			return Util.error(Util.INTERNAL_ERROR, "cannot write %s.import: %s" % [e.dest, error_string(save_err)])
		reimport.append(e.dest)
		maps[e.dest] = {"bone_map": bm_path, "mapped": guess.map.size(), "skeleton": info.skeleton_path}
	if not reimport.is_empty():
		if not Engine.is_editor_hint():
			return Util.error(Util.EDITOR_NOT_READY, "retargeting needs the editor's importer")
		var efs := EditorInterface.get_resource_filesystem()
		if efs.is_scanning() or efs.is_importing():
			return Util.error(Util.EDITOR_NOT_READY, "the editor is busy importing; call again in a moment (bone maps are written)")
		Util.refresh_filesystem(Array(reimport).map(func(x): return bone_map_path(x)))
		efs.reimport_files(reimport)
		for path in reimport:
			var info := skeleton_info(path)
			if info.has("error") or not info.retargeted:
				return Util.error(Util.INTERNAL_ERROR, "%s did not retarget (no %%%s after import); see the Output panel" % [path, SKELETON_NAME])
			for e in entries:
				if e.dest == path:
					e["info"] = info
	return {"retargeted": Array(reimport), "maps": maps}


# =============================================================================
# animation library
# =============================================================================

static func _load_library(path: String) -> AnimationLibrary:
	if not FileAccess.file_exists(path):
		return null
	return ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_REPLACE) as AnimationLibrary


## Picks a role per clip and fills the library. Returns
## {added: {role: from}, skipped: [...], roles: [...], lib: AnimationLibrary}.
func _build_library(p: Dictionary, plan: Dictionary) -> Variant:
	var lib := _load_library(p.library)
	if lib == null:
		lib = AnimationLibrary.new()
	## Candidates: one per clip; single-clip files are named by the file.
	var candidates: Array = []
	for e in plan.anims:
		var clips: Array = e.info.clips
		## Several clips none of which names a role (Mixamo FBX: "mixamo.com"
		## and an empty "Take 001"): the file is one clip, its longest.
		if clips.size() > 1 and clips.all(func(c): return guess_role(String(c)).is_empty()):
			var lengths: Dictionary = e.info.get("lengths", {})
			var longest: String = clips[0]
			for c in clips:
				if float(lengths.get(c, 0.0)) > float(lengths.get(longest, 0.0)):
					longest = c
			clips = [longest]
		for clip in clips:
			var label: String = e.label if clips.size() == 1 else String(clip).get_file()
			candidates.append({"file": e.dest, "label": label, "clip": clip, "role": guess_role(label) if clips.size() == 1 else guess_role(String(clip))})
			if clips.size() == 1 and candidates[-1].role.is_empty():
				candidates[-1].role = guess_role(String(clip))
	## The model's own clips (Meshy/Tripo rigs often bring a walk or idle).
	for clip in plan.model.info.clips:
		candidates.append({"file": plan.model.dest, "label": String(clip), "clip": clip, "role": guess_role(String(clip)), "from_model": true})
	for role in p.clips:
		var want := String(p.clips[role]).to_lower()
		var hit := false
		for c in candidates:
			if String(c.label).to_lower() == want or String(c.clip).to_lower() == want or String(c.file).to_lower() == want \
					or _file_id(c.file) == _file_id(want) or String(c.file).get_file().to_lower() == want:
				for other in candidates:
					if other.role == role:
						other.role = ""
				c.role = role
				c["pinned"] = true
				hit = true
				break
		if not hit:
			return Util.error(Util.INVALID_PARAMS, "clips.%s: no animation file or clip named '%s' (have: %s)" % [role, p.clips[role], ", ".join(candidates.map(func(c): return c.label))])
	var added := {}
	var skipped: Array = []
	for c in candidates:
		if c.role.is_empty():
			if not c.get("from_model", false):
				skipped.append("%s: no role in its name (pass clips={role: '%s'})" % [c.label, c.label])
			continue
		if added.has(c.role):
			if not c.get("from_model", false):
				skipped.append("%s: %s already comes from %s" % [c.label, c.role, added[c.role]])
			continue
		## The model's own clips never replace a library clip.
		if c.get("from_model", false) and lib.has_animation(c.role):
			continue
		var anim := _extract_clip(c.file, c.clip)
		if anim == null:
			skipped.append("%s: clip %s did not load" % [c.label, c.clip])
			continue
		var stats := _prepare_clip(anim, c.role, p.in_place)
		if stats.bone_tracks == 0:
			skipped.append("%s: no %s tracks after retargeting" % [c.label, SKELETON_NAME])
			continue
		if lib.has_animation(c.role):
			lib.remove_animation(c.role)
		lib.add_animation(c.role, anim)
		added[c.role] = c.label
	var roles: Array = []
	for r in ROLES:
		if lib.has_animation(r):
			roles.append(r)
	return {"added": added, "skipped": skipped, "roles": roles, "lib": lib}


static func _extract_clip(path: String, clip: String) -> Animation:
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate()
	var out: Animation = null
	var stack: Array[Node] = [root]
	while not stack.is_empty() and out == null:
		var n: Node = stack.pop_back()
		if n is AnimationPlayer and (n as AnimationPlayer).has_animation(clip):
			out = (n as AnimationPlayer).get_animation(clip).duplicate(true) as Animation
		for c in n.get_children():
			stack.append(c)
	root.free()
	return out


## Keeps the skeleton tracks, makes it in-place and sets looping.
static func _prepare_clip(anim: Animation, role: String, in_place: bool) -> Dictionary:
	var removed := 0
	for t in range(anim.get_track_count() - 1, -1, -1):
		if not String(anim.track_get_path(t)).begins_with(TRACK_PREFIX):
			anim.remove_track(t)
			removed += 1
	if in_place:
		var hips := anim.find_track(NodePath(TRACK_PREFIX + "Hips"), Animation.TYPE_POSITION_3D)
		if hips >= 0 and anim.track_get_key_count(hips) > 0:
			var first: Vector3 = anim.track_get_key_value(hips, 0)
			for k in anim.track_get_key_count(hips):
				var v: Vector3 = anim.track_get_key_value(hips, k)
				anim.track_set_key_value(hips, k, Vector3(first.x, v.y, first.z))
	anim.loop_mode = Animation.LOOP_LINEAR if role in LOOP_ROLES else Animation.LOOP_NONE
	anim.resource_name = role
	return {"bone_tracks": anim.get_track_count(), "removed": removed}


# =============================================================================
# the scene: swap, AnimationTree, CharacterAnimator
# =============================================================================

func _continue(p: Dictionary, plan: Dictionary) -> Dictionary:
	var retarget: Variant = _retarget(plan)
	if Util.is_error(retarget):
		plan.before.restore()
		return retarget
	if not plan.model.info.retargeted:
		plan.before.restore()
		return Util.error(Util.INTERNAL_ERROR, "the model %s did not retarget" % plan.model.dest)
	var built: Variant = _build_library(p, plan)
	if Util.is_error(built):
		plan.before.restore()
		return built
	if not "idle" in built.roles:
		plan.before.restore()
		return Util.error(Util.INVALID_PARAMS, "the library has no idle clip; add one (Mixamo 'Idle' or 'Rifle Idle'), or name it with clips={\"idle\": \"<file>\"}")
	if not plan.before.files.has(p.library):
		plan.before.files[p.library] = FileAccess.get_file_as_bytes(p.library) if FileAccess.file_exists(p.library) else null
	var lib_err := Util.save_resource(built.lib, p.library)
	if not lib_err.is_empty():
		plan.before.restore()
		return Util.error(Util.INTERNAL_ERROR, lib_err)
	Util.refresh_filesystem([p.library])
	var after := ItemTools.FileSnapshot.capture(plan.before.files.keys())
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Character animation files (%s)" % p.asset_id, UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(plan.before, "restore")
		ur.commit_action(false)

	var report := {
		"target": p.target, "scene": p.scene, "model": plan.model.dest, "library": p.library,
		"clips_added": built.added, "roles": built.roles, "retargeted": retarget.retargeted,
		"bone_maps": retarget.maps.values().map(func(m): return m.bone_map),
		"copied": plan.copied,
	}
	var warnings: Array = []
	if not built.skipped.is_empty():
		report["skipped"] = built.skipped
	for role in ["walk", "run", "death"]:
		if not role in built.roles:
			warnings.append("no %s clip: %s" % [role, {"walk": "the character slides while moving", "run": "fast moves play the walk faster", "death": "the character freezes when it dies"}[role]])
	if p.target == "player" and not "dodge" in built.roles:
		warnings.append("no dodge clip (Mixamo 'Sprinting Forward Roll'): the roll shows the run pose")

	## 1. The model in the Body's place.
	if p.swap:
		var swapped := _swap_if_needed(p, plan.model.dest)
		if Util.is_error(swapped):
			swapped["error"]["message"] = "files are ready, but the swap failed: " + swapped.error.message
			return swapped
		report["swap"] = swapped
	## 2. Script, AnimationTree, animator.
	var script := Util.install_script("character_animator.gd.tmpl", p.script_dir + "/character_animator.gd", p.overwrite_scripts)
	if Util.is_error(script):
		return script
	report["script"] = {"path": script.path, "status": script.status}
	var edit := _edit_scene(p, built, script.script)
	if Util.is_error(edit):
		return edit
	report.merge(edit)
	warnings.append_array(edit.get("warnings", []))
	report.erase("warnings")
	if not warnings.is_empty():
		report["warnings"] = warnings
	report["undo"] = "Three editor undo steps: the scene edit, the swap and the files (copies, bone maps, library)."
	report["next"] = "Run the game (or raid_playtest) to watch it. Tune walk_speed/run_speed to the clips, grip_offset for the gun. Other characters: character_anim_setup target=enemy asset_id=<id> (the library is shared)."
	return {"data": report}


func _swap_if_needed(p: Dictionary, model: String) -> Variant:
	var root := _scene_root_for_read(p.scene)
	if root == null:
		return Util.error(Util.INVALID_PARAMS, "cannot load %s" % p.scene)
	var skin := _find_skin(root.node, p.target)
	var current := ""
	if skin != null and skin.has_meta(SwapTools.SKIN_META):
		var meta: Variant = skin.get_meta(SwapTools.SKIN_META)
		current = String(meta.get("model", "")) if meta is Dictionary else ""
	if root.temporary:
		root.node.free()
	if current == model:
		return {"status": "kept", "model": model}
	var swap := SwapTools.new()
	var params := {"target": p.target, "scene": p.scene, "model": model}
	if p.yaw_degrees != 0.0:
		params["yaw_degrees"] = p.yaw_degrees
	var result := swap.swap_placeholder(params)
	if Util.is_error(result):
		return result
	return {"status": "swapped", "model": model, "skin": result.data.swaps[0].skin if not result.data.swaps.is_empty() else ""}


## {node, temporary}: the open scene when it is this file, else a fresh
## instance of the file (temporary; the caller frees it).
static func _scene_root_for_read(scene: String) -> Variant:
	var edited := Util.edited_root()
	if edited != null and edited.scene_file_path == scene:
		return {"node": edited, "temporary": false}
	var packed := ResourceLoader.load(scene, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return null
	return {"node": packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN), "temporary": true}


static func _find_skin(root: Node, target: String) -> Node3D:
	for path in (["Aim/BodySkin", "BodySkin"] if target == "player" else ["BodySkin", "Aim/BodySkin"]):
		var n := root.get_node_or_null(NodePath(path)) as Node3D
		if n != null:
			return n
	return null


## Adds (or replaces) the AnimationTree and CharacterAnimator.
func _edit_scene(p: Dictionary, built: Dictionary, script: Script) -> Variant:
	var edited := Util.edited_root()
	var live: bool = edited != null and edited.scene_file_path == p.scene
	if not live and Engine.is_editor_hint() and p.scene in EditorInterface.get_open_scenes():
		EditorInterface.open_scene_from_path(p.scene)
		edited = Util.edited_root()
		live = edited != null and edited.scene_file_path == p.scene
		if not live:
			return Util.error(Util.EDITOR_NOT_READY, "%s is open in another tab and switching to it failed; switch to it or close it" % p.scene)
	var root: Node = edited if live else null
	if not live:
		var packed := ResourceLoader.load(p.scene, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
		if packed == null:
			return Util.error(Util.INVALID_PARAMS, "cannot load %s" % p.scene)
		root = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	var made: Variant = _make_nodes(root, p, built, script)
	if Util.is_error(made):
		if not live:
			root.free()
		return made
	var tree: AnimationTree = made.tree
	var animator: Node = made.animator
	var old := []
	for name in [TREE_NAME, ANIMATOR_NAME]:
		var n := root.get_node_or_null(NodePath(name))
		if n != null:
			if not n.has_meta(SETUP_META):
				if not live:
					root.free()
				tree.free()
				animator.free()
				return Util.error(Util.ALREADY_EXISTS, "%s already has a %s that character_anim_setup did not make; rename or remove it" % [p.scene, name])
			old.append(n)
	var out: Dictionary = made.report
	if live:
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Character animation (%s)" % p.scene.get_file(), UndoRedo.MERGE_DISABLE, root)
		for n in old:
			ur.add_do_method(root, "remove_child", n)
			ur.add_undo_method(root, "add_child", n, true)
			ur.add_undo_method(root, "move_child", n, n.get_index())
			ur.add_undo_method(n, "set_owner", root)
			ur.add_undo_reference(n)
		for n in [tree, animator]:
			ur.add_do_method(root, "add_child", n, true)
			ur.add_do_method(n, "set_owner", root)
			ur.add_do_reference(n)
			ur.add_undo_method(root, "remove_child", n)
		for change in made.root_changes:
			ur.add_do_property(root, change[0], change[1])
			ur.add_undo_property(root, change[0], root.get(change[0]))
		ur.commit_action()
		out["edited"] = "open scene (unsaved; save with Ctrl+S or scene_save)"
		return out
	for n in old:
		root.remove_child(n)
		n.free()
	for n in [tree, animator]:
		root.add_child(n, true)
		n.owner = root
	for change in made.root_changes:
		root.set(change[0], change[1])
	var before := ItemTools.FileSnapshot.capture([p.scene])
	var err := Util.save_scene(root, p.scene)
	if not err.is_empty():
		before.restore()
		return Util.error(Util.INTERNAL_ERROR, err)
	var after := ItemTools.FileSnapshot.capture([p.scene])
	var reloader := SwapTools.SceneReloader.new()
	reloader.path = p.scene
	reloader.reload()
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Character animation in %s" % p.scene.get_file(), UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_do_method(reloader, "reload")
		ur.add_undo_method(before, "restore")
		ur.add_undo_method(reloader, "reload")
		ur.commit_action(false)
	out["edited"] = "scene file (saved)"
	return out


## Builds the nodes (not in the tree yet). {tree, animator, root_changes, report}
func _make_nodes(root: Node, p: Dictionary, built: Dictionary, script: Script) -> Variant:
	var skin := _find_skin(root, p.target)
	if skin == null:
		return Util.error(Util.NODE_NOT_FOUND, "%s has no BodySkin: run swap_placeholder target=%s first (or pass swap=true)" % [p.scene, p.target])
	var model := skin.get_node_or_null(^"Model") as Node3D
	if model == null:
		return Util.error(Util.NODE_NOT_FOUND, "%s/BodySkin has no Model" % p.scene)
	var skeleton := model.get_node_or_null(NodePath("%" + SKELETON_NAME)) as Skeleton3D
	if skeleton == null:
		return Util.error(Util.INVALID_PARAMS, "the model in %s has no %%%s (it is not retargeted); run character_anim_setup with model=<its file>" % [p.scene, SKELETON_NAME])
	var lib: AnimationLibrary = load(p.library) as AnimationLibrary
	var roles: Array = built.roles
	var directional := "walk" in roles and ("walk_back" in roles or "strafe_left" in roles or "strafe_right" in roles)

	var tree := AnimationTree.new()
	tree.name = TREE_NAME
	tree.set_meta(SETUP_META, {"library": p.library, "roles": roles})
	tree.add_animation_library(LIBRARY_NAME, lib)
	tree.tree_root = build_tree(roles, p.walk_speed, p.run_speed, directional, p.upper_body)
	## Relative to the tree once it is a child of the root.
	tree.root_node = NodePath("../" + String(root.get_path_to(model)))
	tree.active = true

	var animator := Node.new()
	animator.name = ANIMATOR_NAME
	animator.set_meta(SETUP_META, true)
	animator.set_script(script)
	var mount_path := NodePath(root.get("weapon_mount_path")) if root.get("weapon_mount_path") != null else (^"Aim/WeaponMount" if p.target == "player" else ^"WeaponMount")
	var props := {
		"body_path": ^"..", "animation_tree_path": NodePath("../" + TREE_NAME), "roles": PackedStringArray(roles),
		"walk_speed": p.walk_speed, "run_speed": p.run_speed, "directional": directional,
		"weapon_follow": p.weapon_follow, "weapon_mount_path": NodePath("../" + String(mount_path)),
		"hand_bone": StringName("RightHand" if p.hand == "right" else "LeftHand"), "grip_offset": p.grip_offset,
		"aim_when_armed": p.target == "player",
	}
	for key in props:
		animator.set(key, props[key])

	var root_changes: Array = []
	var warnings: Array = []
	## Enemies are freed death_free_delay seconds after dying: let the clip finish.
	if p.target == "enemy" and "death" in roles and root.get("death_free_delay") != null and root.get("free_on_death") == true:
		var needed := snappedf(lib.get_animation("death").length + 0.5, 0.1)
		if float(root.get("death_free_delay")) < needed:
			root_changes.append(["death_free_delay", needed])
	if skeleton.find_bone("RightHand" if p.hand == "right" else "LeftHand") < 0 and p.weapon_follow != "none":
		warnings.append("the skeleton has no %s bone; the weapon stays on its mount" % props.hand_bone)
	if root.get_node_or_null(mount_path) == null and p.weapon_follow != "none":
		warnings.append("no weapon mount at %s; weapon_follow does nothing" % mount_path)
	var params: Array = ["locomotion/blend_position"]
	for role in ONE_SHOT_ROLES:
		if role in roles:
			params.append(role + "/request")
	return {"tree": tree, "animator": animator, "root_changes": root_changes, "report": {
		"animation_tree": {"node": TREE_NAME, "root_node": String(tree.root_node), "locomotion": "BlendSpace2D (strafes)" if directional else ("BlendSpace1D (speed)" if "walk" in roles or "run" in roles else "idle only"),
			"aim": "aim" in roles, "one_shots": ONE_SHOT_ROLES.filter(func(r): return r in roles), "death": "death" in roles, "parameters": params},
		"animator": {"node": ANIMATOR_NAME, "weapon_follow": p.weapon_follow, "hand_bone": String(props.hand_bone), "weapon_mount": String(mount_path)},
		"changed": root_changes.map(func(c): return "%s = %s" % [c[0], str(c[1])]),
		"warnings": warnings,
	}}


## The blend tree for the roles the library has:
## locomotion -> loco_speed -> aim -> hit -> fire -> reload -> attack -> dodge -> life -> output
static func build_tree(roles: Array, walk_speed: float, run_speed: float, directional: bool, upper_body: bool) -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	var x := 0.0
	var locomotion: AnimationRootNode
	if "walk" in roles or "run" in roles:
		if directional:
			var bs := AnimationNodeBlendSpace2D.new()
			var top := run_speed if "run" in roles else walk_speed
			bs.min_space = Vector2(-top, -top)
			bs.max_space = Vector2(top, top)
			for spec in [["idle", Vector2.ZERO], ["walk", Vector2(0, walk_speed)], ["run", Vector2(0, run_speed)],
					["walk_back", Vector2(0, -walk_speed)], ["strafe_left", Vector2(-walk_speed, 0)], ["strafe_right", Vector2(walk_speed, 0)]]:
				if spec[0] in roles:
					bs.add_blend_point(_clip_node(spec[0]), spec[1], -1, StringName(spec[0]))
			locomotion = bs
		else:
			var bs1 := AnimationNodeBlendSpace1D.new()
			bs1.min_space = 0.0
			bs1.max_space = (run_speed if "run" in roles else walk_speed) * 1.25
			for spec in [["idle", 0.0], ["walk", walk_speed], ["run", run_speed]]:
				if spec[0] in roles:
					bs1.add_blend_point(_clip_node(spec[0]), spec[1], -1, StringName(spec[0]))
			locomotion = bs1
	else:
		locomotion = _clip_node("idle")
	bt.add_node(&"locomotion", locomotion, Vector2(x, 0))
	x += 220.0
	bt.add_node(&"loco_speed", AnimationNodeTimeScale.new(), Vector2(x, 0))
	bt.connect_node(&"loco_speed", 0, &"locomotion")
	var last := &"loco_speed"
	var upper := _upper_body_paths()
	if "aim" in roles:
		x += 220.0
		var blend := AnimationNodeBlend2.new()
		_filter(blend, upper, upper_body)
		bt.add_node(&"aim_clip", _clip_node("aim"), Vector2(x - 110.0, 200))
		bt.add_node(&"aim", blend, Vector2(x, 0))
		bt.connect_node(&"aim", 0, last)
		bt.connect_node(&"aim", 1, &"aim_clip")
		last = &"aim"
	for role in ONE_SHOT_ROLES:
		if not role in roles:
			continue
		x += 220.0
		var shot := AnimationNodeOneShot.new()
		shot.fadein_time = 0.05 if role == "fire" else 0.12
		shot.fadeout_time = 0.1 if role == "fire" else 0.2
		if role in UPPER_BODY_ROLES:
			_filter(shot, upper, upper_body)
		var clip_name := StringName(role + "_clip")
		var speed_name := StringName(role + "_speed")
		bt.add_node(clip_name, _clip_node(role), Vector2(x - 220.0, 200))
		bt.add_node(speed_name, AnimationNodeTimeScale.new(), Vector2(x - 110.0, 200))
		bt.add_node(StringName(role), shot, Vector2(x, 0))
		bt.connect_node(speed_name, 0, clip_name)
		bt.connect_node(StringName(role), 0, last)
		bt.connect_node(StringName(role), 1, speed_name)
		last = StringName(role)
	if "death" in roles:
		x += 220.0
		var life := AnimationNodeTransition.new()
		life.xfade_time = 0.2
		life.add_input("alive")
		life.add_input("dead")
		bt.add_node(&"death_clip", _clip_node("death"), Vector2(x - 110.0, 200))
		bt.add_node(&"life", life, Vector2(x, 0))
		bt.connect_node(&"life", 0, last)
		bt.connect_node(&"life", 1, &"death_clip")
		last = &"life"
	bt.set_node_position(&"output", Vector2(x + 220.0, 0))
	bt.connect_node(&"output", 0, last)
	return bt


static func _clip_node(role: String) -> AnimationNodeAnimation:
	var n := AnimationNodeAnimation.new()
	n.animation = StringName(LIBRARY_NAME + "/" + role)
	return n


static func _upper_body_paths() -> Array:
	var out: Array = []
	for b in UPPER_BONES:
		out.append(TRACK_PREFIX + b)
	for side in ["Left", "Right"]:
		for b in ARM_BONES:
			out.append(TRACK_PREFIX + side + b)
	return out


static func _filter(node: AnimationNode, paths: Array, enabled: bool) -> void:
	if not enabled:
		return
	node.filter_enabled = true
	for path in paths:
		node.set_filter_path(NodePath(path), true)


# =============================================================================
# dry run
# =============================================================================

func _dry_report(p: Dictionary, plan: Dictionary) -> Dictionary:
	var files: Array = []
	for e in plan.anims:
		var role := guess_role(e.label)
		for r in p.clips:
			var want := String(p.clips[r]).to_lower()
			if e.label.to_lower() == want or _file_id(e.source) == _file_id(want):
				role = r
		files.append({"file": e.source, "dest": e.dest, "role": role if not role.is_empty() else "(none: name it with clips)"})
	var existing := _load_library(p.library)
	return {
		"dry_run": true, "target": p.target, "scene": p.scene,
		"model": {"source": plan.model.source, "dest": plan.model.dest},
		"animations": files, "library": p.library,
		"library_roles": [] if existing == null else Array(existing.get_animation_list()).map(func(s): return String(s)),
		"swap": p.swap, "weapon_follow": p.weapon_follow,
		"note": "Roles come from the file names (or clips={role: name}). Bone maps are guessed from the bone names when the files are imported.",
	}

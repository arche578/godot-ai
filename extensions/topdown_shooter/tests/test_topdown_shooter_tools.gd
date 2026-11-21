@tool
extends McpTestSuite

## Tests for the top-down shooter custom tools. Run them with
## extensions/topdown_shooter/script/link-test-project, which links the
## addon and this suite into test_project/ for the Godot AI test runner.
##
## Files are written under res://zz_mcp_test_topdown/ and removed afterwards.
## Generated game scripts are not @tool, so the editor only holds
## placeholder instances of them; logic tests run a @tool copy instead.
## Input actions use a unique prefix and are removed from project.godot.

const Tools := preload("res://addons/topdown_shooter_tools/handlers/topdown_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const LootTools := preload("res://addons/topdown_shooter_tools/handlers/loot_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")
const RaidTools := preload("res://addons/topdown_shooter_tools/handlers/raid_tools.gd")
const PlaytestTools := preload("res://addons/topdown_shooter_tools/handlers/playtest_tools.gd")
const HideoutTools := preload("res://addons/topdown_shooter_tools/handlers/hideout_tools.gd")
const NotesTools := preload("res://addons/topdown_shooter_tools/handlers/notes_tools.gd")
const FeedbackTools := preload("res://addons/topdown_shooter_tools/handlers/feedback_tools.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const SwapTools := preload("res://addons/topdown_shooter_tools/handlers/swap_tools.gd")
const ToolSpecs := preload("res://addons/topdown_shooter_tools/tool_specs.gd")
const GenTools := preload("res://addons/topdown_shooter_tools/handlers/gen_tools.gd")
const GenProviders := preload("res://addons/topdown_shooter_tools/handlers/gen_providers.gd")
const IconTools := preload("res://addons/topdown_shooter_tools/handlers/icon_tools.gd")
const EnvTools := preload("res://addons/topdown_shooter_tools/handlers/env_tools.gd")
const KitTools := preload("res://addons/topdown_shooter_tools/handlers/kit_tools.gd")

const WORK_DIR := "res://zz_mcp_test_topdown"
const ACTION_PREFIX := "mcp_test_td_"

var _tools: Tools
var _items: ItemTools
var _loot: LootTools
var _inventory: InventoryTools
var _raid: RaidTools
var _playtest: PlaytestTools
var _hideout: HideoutTools
var _main_scene_before := ""
var _notes: NotesTools
var _feedback: FeedbackTools
var _assets: AssetTools
var _swap: SwapTools
var _undo_redo: EditorUndoRedoManager
var _added: Array[Node] = []


func suite_name() -> String:
	return "topdown_shooter"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_tools = Tools.new()
	_items = ItemTools.new()
	_loot = LootTools.new()
	_inventory = InventoryTools.new()
	_raid = RaidTools.new()
	_playtest = PlaytestTools.new()
	_hideout = HideoutTools.new()
	_main_scene_before = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	_notes = NotesTools.new()
	_feedback = FeedbackTools.new()
	_assets = AssetTools.new()
	_swap = SwapTools.new()
	_notes.notes_dir = WORK_DIR + "/notes/"
	if EditorInterface.get_edited_scene_root() == null:
		skip_suite("needs an open scene")


func teardown() -> void:
	for node in _added:
		if is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()
	_added.clear()


func suite_teardown() -> void:
	teardown()
	_remove_tree(ProjectSettings.globalize_path(WORK_DIR))
	_remove_asset_test_files()
	_remove_gen_test_files()
	_remove_env_test_files()
	var changed := false
	for suffix in Tools.INPUT_ACTIONS.keys() + ["inventory", "interact"]:
		var action: String = ACTION_PREFIX + suffix
		if ProjectSettings.has_setting("input/" + action):
			ProjectSettings.clear("input/" + action)
			changed = true
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	if ProjectSettings.has_setting(PlaytestTools.autoload_key()) and str(ProjectSettings.get_setting(PlaytestTools.autoload_key())).contains(WORK_DIR):
		ProjectSettings.set_setting(PlaytestTools.autoload_key(), null)
		changed = true
	## hideout_scaffold settings left by a failed test.
	if str(ProjectSettings.get_setting("autoload/" + HideoutTools.AUTOLOAD_NAME, "")).contains(WORK_DIR):
		ProjectSettings.set_setting("autoload/" + HideoutTools.AUTOLOAD_NAME, null)
		changed = true
	if str(ProjectSettings.get_setting(HideoutTools.SETTINGS_PREFIX + "raid_scene", "")).contains(WORK_DIR):
		for key in ["hideout_scene", "menu_scene", "raid_scene", "save_path", "item_database", "return_delay", "quit_counts_as_death", "track_direct_raids", "starting_stash"]:
			ProjectSettings.set_setting(HideoutTools.SETTINGS_PREFIX + key, null)
		changed = true
	if str(ProjectSettings.get_setting("application/run/main_scene", "")).contains(WORK_DIR):
		ProjectSettings.set_setting("application/run/main_scene", _main_scene_before)
		changed = true
	_remove_tree(ProjectSettings.globalize_path(HIDEOUT_SAVE.get_base_dir()))
	if ProjectSettings.has_setting(NotesTools.autoload_key()) and str(ProjectSettings.get_setting(NotesTools.autoload_key())).contains(WORK_DIR):
		ProjectSettings.set_setting(NotesTools.autoload_key(), null)
		changed = true
	if changed:
		ProjectSettings.save()


func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _track(path: String) -> Node:
	var node := McpScenePath.resolve(path, _root())
	if node != null:
		_added.append(node)
	return node


func _remove_tree(abs_path: String) -> void:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(abs_path.path_join(sub))
	for file in dir.get_files():
		DirAccess.remove_absolute(abs_path.path_join(file))
	DirAccess.remove_absolute(abs_path)


func _player_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"scene_path": WORK_DIR + "/player/player.tscn",
		"script_dir": WORK_DIR + "/scripts",
		"action_prefix": ACTION_PREFIX,
		"overwrite": true,
	}
	params.merge(extra, true)
	return params


func _weapon_params(id: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"weapon_id": id,
		"data_dir": WORK_DIR + "/data",
		"scene_dir": WORK_DIR + "/weapons",
		"script_dir": WORK_DIR + "/scripts",
		"overwrite": true,
	}
	params.merge(extra, true)
	return params


# --- specs -------------------------------------------------------------------

func test_specs_validate() -> void:
	var specs := ToolSpecs.build()
	assert_eq(specs.size(), 23)
	var names := []
	for spec in specs:
		assert_eq(spec.validate(), [] as Array[String], "spec %s" % spec.name)
		assert_true(spec.promoted)
		## The playtest runs while the game plays, so it must not be gated.
		## playtest_notes is read while the game runs, so it is not gated either.
		assert_eq(spec.requires_writable, not spec.name in ["raid_playtest", "playtest_notes", "asset_audit"], "requires_writable of %s" % spec.name)
		assert_eq(spec.deferred, spec.name in ["raid_playtest", "asset_cleanup", "asset_import", "asset_generate", "asset_job", "asset_pipeline", "polyhaven_fetch", "item_icon_render", "character_anim_setup"], "deferred of %s" % spec.name)
		names.append(spec.name)
	assert_eq(names, ["topdown_camera_setup", "player_controller_scaffold", "weapon_create", "combat_feedback_setup", "enemy_ai_scaffold", "item_db_import", "loot_table_edit", "inventory_ui_scaffold", "raid_map_blockout", "raid_playtest", "playtest_notes", "hideout_scaffold", "asset_cleanup", "asset_import", "swap_placeholder", "asset_generate", "asset_job", "asset_pipeline", "polyhaven_fetch", "environment_setup", "item_icon_render", "character_anim_setup", "asset_audit"])


# --- player ------------------------------------------------------------------

func test_player_scaffold_writes_scene_script_and_actions() -> void:
	var result := _tools.player_scaffold(_player_params({"add_to_scene": false, "move_speed": 7.5}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_true(FileAccess.file_exists(data.scene_path))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/player_controller.gd"))
	assert_eq(data.input_actions.created.size() + data.input_actions.kept_existing.size(), Tools.INPUT_ACTIONS.size())
	assert_true(InputMap.has_action(ACTION_PREFIX + "fire"))
	assert_true(ProjectSettings.has_setting("input/" + ACTION_PREFIX + "move_left"))

	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_true(packed != null, "player scene loads")
	var player := packed.instantiate()
	assert_true(player is CharacterBody3D)
	assert_true(player.get_node_or_null("Aim/WeaponMount") != null)
	assert_true(player.get_node_or_null("CollisionShape3D") != null)
	assert_true(player.is_in_group(&"player"))
	assert_eq(player.get("move_speed"), 7.5)
	assert_eq(player.get("action_fire"), StringName(ACTION_PREFIX + "fire"))
	player.free()


func test_player_scaffold_instances_into_scene_with_undo() -> void:
	var result := _tools.player_scaffold(_player_params({"position": [1, 0, 2]}))
	assert_has_key(result, "data", str(result))
	var inst := _track(result.data.instance_path)
	assert_true(inst != null, "instance exists at %s" % result.data.instance_path)
	assert_eq((inst as Node3D).position, Vector3(1, 0, 2))
	assert_eq(inst.owner, _root())
	assert_true(editor_undo(_undo_redo))
	assert_true(not is_instance_valid(inst) or inst.get_parent() == null, "undo removes the instance")


func test_player_scaffold_refuses_existing_scene_without_overwrite() -> void:
	_tools.player_scaffold(_player_params({"add_to_scene": false}))
	var result := _tools.player_scaffold(_player_params({"add_to_scene": false, "overwrite": false}))
	assert_is_error(result, "ALREADY_EXISTS")


func test_player_scaffold_rejects_bad_params() -> void:
	assert_is_error(_tools.player_scaffold(_player_params({"move_speed": "fast"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"scene_path": "res://addons/x/p.tscn"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"scene_path": "/tmp/p.tscn"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"action_prefix": "bad-prefix"})), "INVALID_PARAMS")


# --- camera ------------------------------------------------------------------

func test_camera_setup_follows_given_target() -> void:
	var player_result := _tools.player_scaffold(_player_params({"position": [3, 0, -4]}))
	var player := _track(player_result.data.instance_path)
	var result := _tools.camera_setup({
		"target_path": player_result.data.instance_path,
		"script_dir": WORK_DIR + "/scripts",
		"name": "TestFollowCam",
		"pitch_degrees": 60.0,
		"distance": 10.0,
	})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path) as Node3D
	assert_true(rig != null)
	assert_eq(rig.get_node_or_null(rig.get("target_path")), player, "target_path resolves to the player")
	assert_true(rig.top_level)
	var cam := rig.get_node("Camera3D") as Camera3D
	assert_true(cam.current)
	assert_true(rig.global_position.is_equal_approx(Vector3(3, 0, -4)), "rig snaps onto the target")
	var expected := Vector3(0, sin(deg_to_rad(60.0)) * 10.0, cos(deg_to_rad(60.0)) * 10.0)
	assert_true(cam.position.is_equal_approx(expected), "arm %s vs %s" % [cam.position, expected])
	## Camera looks back at the rig origin.
	var forward := -cam.global_basis.z
	var to_rig := (rig.global_position - cam.global_position).normalized()
	assert_true(forward.is_equal_approx(to_rig), "camera faces the target")


func test_camera_setup_auto_finds_player_group() -> void:
	var player_result := _tools.player_scaffold(_player_params())
	var player := _track(player_result.data.instance_path)
	var result := _tools.camera_setup({"script_dir": WORK_DIR + "/scripts", "name": "TestAutoCam"})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path)
	## The open scene may already hold another player; any group member counts.
	var target := rig.get_node_or_null(rig.get("target_path"))
	assert_true(target != null and target.is_in_group(&"player"), "rig follows a node in group 'player'")
	assert_eq(result.data.target_path, McpScenePath.from_node(target, _root()))
	assert_true(player != null)


func test_camera_setup_undo_restores_previous_current_camera() -> void:
	var existing := Camera3D.new()
	existing.name = "ExistingCam"
	_root().add_child(existing)
	existing.owner = _root()
	existing.current = true
	_added.append(existing)
	var result := _tools.camera_setup({"script_dir": WORK_DIR + "/scripts", "name": "TestUndoCam", "target_path": "ExistingCam"})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path)
	assert_false(existing.current, "new rig camera takes over")
	assert_true(editor_undo(_undo_redo))
	assert_true(existing.current, "undo gives current back")
	assert_true(not is_instance_valid(rig) or rig.get_parent() == null, "undo removes the rig")


func test_camera_setup_errors() -> void:
	var base := {"name": "TestErrCam", "script_dir": WORK_DIR + "/scripts"}
	assert_is_error(_tools.camera_setup(base.merged({"target_path": "Nope"})), "NODE_NOT_FOUND", "missing target")
	assert_is_error(_tools.camera_setup(base.merged({"pitch_degrees": 5})), "INVALID_PARAMS", "pitch out of range")
	assert_is_error(_tools.camera_setup(base.merged({"parent_path": "Nope"})), "NODE_NOT_FOUND", "missing parent")
	assert_is_error(_tools.camera_setup(base.merged({"name": "Bad/Name"}, true)), "INVALID_PARAMS", "bad node name")


# --- weapon ------------------------------------------------------------------

func test_weapon_create_hitscan_files() -> void:
	var result := _tools.weapon_create(_weapon_params("test_pistol", {"damage": 25, "magazine_size": 7}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	var res := ResourceLoader.load(data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(res != null, "weapon data loads")
	assert_eq(res.get("damage"), 25.0)
	assert_eq(res.get("magazine_size"), 7)
	assert_eq(res.get("fire_mode"), "hitscan")
	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var weapon := packed.instantiate()
	assert_true(weapon.get_node_or_null("Muzzle") is Marker3D)
	assert_true(weapon.get("data") != null, "scene references the data resource")
	assert_false(data.scripts.has("projectile"))
	weapon.free()


func test_weapon_create_projectile_reuses_shared_scene() -> void:
	var first := _tools.weapon_create(_weapon_params("test_launcher", {"fire_mode": "projectile", "projectile_speed": 30}))
	assert_has_key(first, "data", str(first))
	assert_true(FileAccess.file_exists(first.data.projectile_scene.path))
	var res := ResourceLoader.load(first.data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(res.get("projectile_scene") is PackedScene)
	var second := _tools.weapon_create(_weapon_params("test_launcher2", {"fire_mode": "projectile", "overwrite": false}))
	assert_has_key(second, "data", str(second))
	assert_eq(second.data.projectile_scene.status, "kept")
	assert_eq(second.data.scripts.weapon.status, "kept")


func test_weapon_fire_cooldown_ammo_and_reload() -> void:
	var result := _tools.weapon_create(_weapon_params("test_smg", {"magazine_size": 2, "fire_rate": 10, "reload_time": 0.5, "auto_reload": false}))
	assert_has_key(result, "data", str(result))
	var weapon := _tool_weapon(result.data)
	assert_eq(weapon.ammo, 2)
	var aim := weapon.global_position + Vector3(0, 0, -10)
	assert_true(weapon.try_fire(aim), "first shot fires")
	assert_false(weapon.try_fire(aim), "cooldown blocks the next shot")
	weapon._physics_process(0.2)
	assert_true(weapon.try_fire(aim), "second shot after cooldown")
	weapon._physics_process(0.2)
	assert_false(weapon.try_fire(aim), "empty magazine")
	assert_eq(weapon.ammo, 0)
	assert_true(weapon.reload())
	assert_true(weapon.is_reloading())
	weapon._physics_process(0.6)
	assert_eq(weapon.ammo, 2, "reload refills the magazine")


func test_weapon_hitscan_damages_target() -> void:
	var result := _tools.weapon_create(_weapon_params("test_rail", {"damage": 40, "spread_degrees": 0}))
	assert_has_key(result, "data", str(result))
	var weapon := _tool_weapon(result.data)
	var target := StaticBody3D.new()
	target.name = "DamageTarget"
	target.set_script(_damage_receiver_script())
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 1)
	shape.shape = box
	target.add_child(shape)
	_root().add_child(target)
	_added.append(target)
	target.global_position = weapon.global_position + Vector3(0, 0, -5)
	## Let the physics server pick up the new body's transform.
	PhysicsServer3D.body_set_state(target.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target.global_transform)
	assert_true(weapon.try_fire(target.global_position))
	assert_eq(target.received, 40.0, "hitscan ray delivered damage")


## Instantiates the weapon with a @tool copy of its script so its methods
## run inside the editor, and adds it to the edited scene.
func _tool_weapon(data: Dictionary) -> Node3D:
	var res := ResourceLoader.load(data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var weapon := Node3D.new()
	weapon.name = "ToolWeapon"
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	weapon.add_child(muzzle)
	weapon.set_script(_tool_copy(data.scripts.weapon.path))
	weapon.set("data", res)
	_root().add_child(weapon)
	_added.append(weapon)
	weapon.set_physics_process(false)
	## Far above whatever geometry the open scene has.
	weapon.global_position = Vector3(0, 500, 0)
	return weapon


func _tool_copy(path: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\n" + FileAccess.get_file_as_string(path)
	assert_eq(script.reload(), OK, "tool copy of %s compiles" % path)
	return script


func _damage_receiver_script() -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\nextends StaticBody3D\nvar received := 0.0\nfunc take_damage(amount: float, _info: Dictionary = {}) -> void:\n\treceived += amount\n"
	script.reload()
	return script


func test_weapon_attach_to_player_mount() -> void:
	var player_result := _tools.player_scaffold(_player_params())
	var player := _track(player_result.data.instance_path)
	var result := _tools.weapon_create(_weapon_params("test_rifle", {"attach_to": player_result.data.instance_path}))
	assert_has_key(result, "data", str(result))
	var inst := McpScenePath.resolve(result.data.instance_path, _root())
	assert_true(inst != null)
	assert_eq(inst.get_parent(), player.get_node("Aim/WeaponMount"))
	assert_eq(inst.owner, _root())
	assert_true(_root().is_editable_instance(player), "player instance gets Editable Children so the weapon is saved")
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root()), OK)
	var state := packed.get_state()
	var saved := false
	for i in state.get_node_count():
		if String(state.get_node_name(i)) == String(inst.name) and String(state.get_node_path(i, true)).ends_with("WeaponMount"):
			saved = true
	assert_true(saved, "packing the edited scene keeps the attached weapon")
	assert_true(editor_undo(_undo_redo))
	assert_false(_root().is_editable_instance(player), "undo turns Editable Children back off")


func test_weapon_create_rejects_bad_params() -> void:
	assert_is_error(_tools.weapon_create({}), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("Bad-Id")), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"fire_mode": "laser"})), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"pellets": 1.5})), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"attach_to": "Nope"})), "NODE_NOT_FOUND")


# --- enemy -------------------------------------------------------------------

const TARGET_GROUP := &"mcp_test_td_target"


func _enemy_params(id: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"enemy_id": id,
		"scene_dir": WORK_DIR + "/enemies",
		"script_dir": WORK_DIR + "/scripts",
		"overwrite": true,
		"add_to_scene": false,
	}
	params.merge(extra, true)
	return params


func test_enemy_scaffold_writes_scene() -> void:
	var result := _tools.enemy_scaffold(_enemy_params("test_grunt", {"max_health": 80, "sight_angle_degrees": 90}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/enemy_ai.gd"))
	assert_eq(data.instances, [])
	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var enemy := packed.instantiate()
	assert_true(enemy is CharacterBody3D)
	assert_eq(String(enemy.name), "TestGrunt")
	assert_true(enemy.is_in_group(&"enemy"))
	for child in ["CollisionShape3D", "Body", "Nose", "WeaponMount", "NavigationAgent3D"]:
		assert_true(enemy.get_node_or_null(child) != null, "has %s" % child)
	assert_eq(enemy.get("max_health"), 80.0)
	assert_eq(enemy.get("sight_angle_degrees"), 90.0)
	assert_eq(enemy.get("attack_mode"), "melee")
	assert_eq(enemy.get("attack_range"), 1.8)
	assert_eq(enemy.get("target_group"), &"player")
	enemy.free()


func test_enemy_scaffold_ranged_mounts_weapon_scene() -> void:
	var weapon := _tools.weapon_create(_weapon_params("test_enemy_rifle"))
	assert_has_key(weapon, "data", str(weapon))
	var result := _tools.enemy_scaffold(_enemy_params("test_gunner", {"attack_mode": "ranged", "weapon_scene": weapon.data.scene_path}))
	assert_has_key(result, "data", str(result))
	var packed := ResourceLoader.load(result.data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var enemy := packed.instantiate()
	assert_eq(enemy.get("attack_mode"), "ranged")
	assert_eq(enemy.get("attack_range"), 12.0, "ranged default range")
	var mount := enemy.get_node("WeaponMount")
	assert_eq(mount.get_child_count(), 1)
	assert_eq(mount.get_child(0).scene_file_path, weapon.data.scene_path, "weapon is linked as an instance")
	enemy.free()


func test_enemy_scaffold_rejects_bad_params() -> void:
	assert_is_error(_tools.enemy_scaffold({}), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("Bad-Id")), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"attack_mode": "magic"})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"weapon_scene": "res://x.tscn"})), "INVALID_PARAMS", "weapon on melee")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"attack_mode": "ranged", "weapon_scene": WORK_DIR + "/nope.tscn"})), "NODE_NOT_FOUND")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"positions": [[1, 2]]})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"patrol_points": "here"})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"sight_angle_degrees": 400})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"add_to_scene": true, "parent_path": "Nope"})), "NODE_NOT_FOUND")


func test_enemy_scaffold_refuses_existing_scene_without_overwrite() -> void:
	_tools.enemy_scaffold(_enemy_params("test_dupe"))
	assert_is_error(_tools.enemy_scaffold(_enemy_params("test_dupe", {"overwrite": false})), "ALREADY_EXISTS")


func test_enemy_scaffold_places_instances_and_bakes_navigation() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "TestNavFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	shape.shape = box
	floor_body.add_child(shape)
	_root().add_child(floor_body)
	floor_body.owner = _root()
	shape.owner = _root()
	_added.append(floor_body)
	floor_body.position = Vector3(0, -300.5, 0)
	var was_in_group := _root().is_in_group(Tools.NAV_SOURCE_GROUP)

	var result := _tools.enemy_scaffold(_enemy_params("test_patroller", {
		"add_to_scene": true,
		"positions": [[2, -300, 3], [-2, -300, 3]],
		"patrol_points": [[0, -300, 0], [5, -300, 5]],
	}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.instances.size(), 2)
	var first := _track(data.instances[0]) as Node3D
	var second := _track(data.instances[1]) as Node3D
	assert_true(first != null and second != null)
	assert_ne(String(first.name), String(second.name))
	assert_eq(first.position, Vector3(2, -300, 3))
	assert_eq(first.owner, _root())
	assert_eq(first.get("patrol_points"), PackedVector3Array([Vector3(0, -300, 0), Vector3(5, -300, 5)]))
	assert_eq(data.navigation.status, "created", str(data.navigation))
	var region := _track(data.navigation.region_path) as NavigationRegion3D
	assert_true(region != null, "navigation region added")
	assert_gt(data.navigation.polygons, 0, "bake found the floor")
	assert_true(_root().is_in_group(Tools.NAV_SOURCE_GROUP))

	assert_true(editor_undo(_undo_redo))
	assert_true(not is_instance_valid(first) or first.get_parent() == null, "undo removes the enemies")
	assert_true(not is_instance_valid(region) or region.get_parent() == null, "undo removes the region")
	assert_eq(_root().is_in_group(Tools.NAV_SOURCE_GROUP), was_in_group, "undo restores the root's groups")


## Builds a running (@tool copy) enemy far from the open scene's geometry.
func _tool_enemy(extra: Dictionary = {}) -> CharacterBody3D:
	var result := _tools.enemy_scaffold(_enemy_params("test_ai"))
	assert_has_key(result, "data", str(result))
	var enemy := CharacterBody3D.new()
	enemy.name = "ToolEnemy"
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	enemy.add_child(shape)
	enemy.set_script(_tool_copy(result.data.script.path))
	enemy.set("target_group", TARGET_GROUP)
	enemy.set("free_on_death", false)
	enemy.set("perception_interval", 0.0)
	enemy.set("alert_radius", 0.0)
	for key in extra:
		enemy.set(key, extra[key])
	_root().add_child(enemy)
	_added.append(enemy)
	enemy.set_physics_process(false)
	enemy.global_position = Vector3(0, 500, 0)
	_sync_body(enemy)
	return enemy


func _target(offset: Vector3, enemy: Node3D) -> StaticBody3D:
	var target := StaticBody3D.new()
	target.name = "AiTarget"
	target.set_script(_damage_receiver_script())
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 3.0, 0.8)
	shape.shape = box
	shape.position = Vector3(0, 1.5, 0)
	target.add_child(shape)
	target.add_to_group(TARGET_GROUP)
	_root().add_child(target)
	_added.append(target)
	target.global_position = enemy.global_position + offset
	_sync_body(target)
	return target


func _wall(at: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = "AiWall"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 6, 0.5)
	shape.shape = box
	wall.add_child(shape)
	_root().add_child(wall)
	_added.append(wall)
	wall.global_position = at
	_sync_body(wall)
	return wall


## Lets the physics server see a body's transform without a physics step.
func _sync_body(body: CollisionObject3D) -> void:
	PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)


func test_enemy_sees_target_in_cone_and_chases() -> void:
	var enemy := _tool_enemy()
	var target := _target(Vector3(0, 0, -6), enemy)
	var spotted := []
	enemy.target_spotted.connect(func(t): spotted.append(t))
	assert_true(enemy.can_see(target), "in front, in range, clear line")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	assert_eq(enemy.target, target)
	assert_eq(spotted, [target])


func test_enemy_ignores_target_behind_or_out_of_range() -> void:
	var enemy := _tool_enemy({"sight_range": 10.0})
	var behind := _target(Vector3(0, 0, 6), enemy)
	assert_false(enemy.can_see(behind), "outside the vision cone")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "PATROL")
	behind.global_position = enemy.global_position + Vector3(0, 0, 2)
	_sync_body(behind)
	assert_true(enemy.can_see(behind), "within proximity_radius any direction counts")
	behind.global_position = enemy.global_position + Vector3(0, 0, -12)
	_sync_body(behind)
	assert_false(enemy.can_see(behind), "beyond sight_range")


func test_enemy_sight_blocked_by_wall() -> void:
	var enemy := _tool_enemy()
	var target := _target(Vector3(0, 0, -8), enemy)
	_wall(enemy.global_position + Vector3(0, 1, -4))
	assert_false(enemy.can_see(target), "wall blocks line of sight")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "PATROL")


func test_enemy_melee_windup_then_damage() -> void:
	var enemy := _tool_enemy({"attack_windup": 0.3, "attack_damage": 15.0, "attack_cooldown": 1.0})
	var target := _target(Vector3(0, 0, -1.5), enemy)
	var started := []
	enemy.attack_started.connect(func(t): started.append(t))
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "ATTACK", "in range goes straight to attack")
	enemy.think(0.1)
	assert_eq(started.size(), 1, "windup started")
	assert_eq(target.received, 0.0, "no damage during windup")
	enemy.think(0.35)
	assert_eq(target.received, 15.0, "hit after windup")
	enemy.think(0.1)
	enemy.think(0.5)
	assert_eq(target.received, 15.0, "cooldown blocks the next hit")
	enemy.think(0.5)
	enemy.think(0.4)
	assert_eq(target.received, 30.0, "second hit after cooldown and windup")


func test_enemy_ranged_ray_damages_target() -> void:
	var enemy := _tool_enemy({"attack_mode": "ranged", "attack_range": 12.0, "attack_windup": 0.0, "aim_error_degrees": 0.0, "attack_damage": 7.0})
	var target := _target(Vector3(0, 0, -8), enemy)
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "ATTACK")
	enemy.think(0.1)
	assert_eq(target.received, 7.0, "ranged ray hit")


func test_enemy_damage_aggro_and_death() -> void:
	var enemy := _tool_enemy({"max_health": 30.0})
	var attacker := _target(Vector3(0, 0, 10), enemy)
	var deaths := []
	enemy.died.connect(func(): deaths.append(true))
	enemy.take_damage(10.0, {"source": attacker, "position": enemy.global_position})
	assert_eq(enemy.health, 20.0)
	assert_eq(enemy.get_state_name(), "CHASE", "damage from an unseen attacker starts a chase")
	assert_eq(enemy.target, attacker)
	enemy.take_damage(25.0, {"source": attacker})
	assert_eq(enemy.get_state_name(), "DEAD")
	assert_true(enemy.is_dead)
	assert_eq(deaths.size(), 1)
	assert_eq(enemy.collision_layer, 0, "corpse stops blocking bullets")
	enemy.take_damage(5.0, {})
	assert_eq(deaths.size(), 1, "dies once")


func test_enemy_loses_target_searches_then_patrols() -> void:
	var enemy := _tool_enemy({"lose_sight_time": 0.5, "search_time": 0.5})
	var target := _target(Vector3(0, 0, -6), enemy)
	var lost := []
	enemy.target_lost.connect(func(): lost.append(true))
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	target.remove_from_group(TARGET_GROUP)
	enemy.think(0.1)
	assert_eq(enemy.target, null, "a target that left the group is dropped")
	assert_eq(enemy.get_state_name(), "SEARCH")
	## The enemy cannot walk here (no physics step), so the search gives up on
	## reaching the spot after its leg timer and looks around instead.
	for i in 25:
		enemy.think(0.5)
	assert_eq(enemy.get_state_name(), "PATROL")
	assert_eq(lost.size(), 1)


func test_enemy_alerts_nearby_allies() -> void:
	var enemy := _tool_enemy({"alert_radius": 10.0})
	var ally := _tool_enemy({"alert_radius": 0.0})
	ally.name = "ToolAlly"
	ally.global_position = enemy.global_position + Vector3(3, 0, 0)
	ally.rotation.y = PI
	_sync_body(ally)
	var target := _target(Vector3(0, 0, -6), enemy)
	assert_false(ally.can_see(target), "ally faces away")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	assert_eq(ally.get_state_name(), "CHASE", "ally joins the chase")
	assert_eq(ally.target, target)


# --- items -------------------------------------------------------------------

const ITEM_DIR := WORK_DIR + "/items"

const ITEM_CSV := """id,이름,category,rarity,무게,price,stack,tags,description,durability
bandage,Bandage,medical,common,0.1,50,5,heal;cheap,"Stops bleeding, slowly",
ammo_9mm,9mm Round,ammo,Common,0.01,2,60,ammo,,
# comment row
gold_watch,"Gold ""Rolex"" Watch",valuable,rare,0.2,1500,1,,"Line one
line two",80
"""


func _item_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"csv_text": ITEM_CSV,
		"data_dir": ITEM_DIR,
		"script_dir": WORK_DIR + "/scripts",
		"weapon_data_dir": WORK_DIR + "/data",
	}
	params.merge(extra, true)
	return params


func _load_fresh(path: String) -> Resource:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)


## Item ids in a database file, read from its stored `items` list.
func _db_ids(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for item in _load_fresh(path).get("items"):
		out.append(item.get("item_id"))
	return out


## The database with a @tool copy of its script, so its lookup methods run.
func _tool_db(path: String) -> Resource:
	var stored := _load_fresh(path)
	var db := Resource.new()
	db.set_script(_tool_copy(WORK_DIR + "/scripts/item_database.gd"))
	db.set("items", stored.get("items"))
	return db


func _clear_items() -> void:
	_remove_tree(ProjectSettings.globalize_path(ITEM_DIR))


func test_item_csv_parser_handles_quotes_and_newlines() -> void:
	var rows := ItemTools.parse_csv("a,b,c\r\n1,\"x, y\",\"he said \"\"hi\"\"\"\n2,\"multi\nline\",\n\n3,,", ",")
	assert_eq(rows.size(), 4)
	assert_eq(rows[1].cells, PackedStringArray(["1", "x, y", "he said \"hi\""]))
	assert_eq(rows[2].cells, PackedStringArray(["2", "multi\nline", ""]))
	assert_eq(rows[2].line, 3)
	assert_eq(rows[3].line, 6, "line numbers count the newline inside quotes and the blank line")
	assert_eq(rows[3].cells, PackedStringArray(["3", "", ""]))


func test_item_db_import_creates_items_and_database() -> void:
	_clear_items()
	var result := _items.item_db_import(_item_params())
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.item_count, 3)
	assert_eq(data.created, ["bandage", "ammo_9mm", "gold_watch"])
	assert_eq(data.columns["이름"], "display_name")
	assert_eq(data.columns["price"], "value")
	assert_eq(data.extra_columns, ["durability"])
	assert_eq(data.blank_or_comment_rows, 1)

	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_true(bandage != null, "bandage.tres loads")
	assert_eq(bandage.get("item_id"), "bandage")
	assert_eq(bandage.get("category"), "medical")
	assert_eq(bandage.get("weight"), 0.1)
	assert_eq(bandage.get("value"), 50)
	assert_eq(bandage.get("max_stack"), 5)
	assert_eq(bandage.get("tags"), ["heal", "cheap"])
	assert_eq(bandage.get("description"), "Stops bleeding, slowly")
	assert_eq(bandage.get("extra"), {})
	var ammo := _load_fresh(ITEM_DIR + "/ammo_9mm.tres")
	assert_eq(ammo.get("rarity"), "common", "enum match ignores case")
	var watch := _load_fresh(ITEM_DIR + "/gold_watch.tres")
	assert_eq(watch.get("display_name"), "Gold \"Rolex\" Watch")
	assert_eq(watch.get("description"), "Line one\nline two")
	assert_eq(watch.get("extra"), {"durability": 80})

	assert_eq(data.database.item_count, 3)
	var db := _tool_db(data.database.path)
	assert_eq(db.get_ids(), PackedStringArray(["bandage", "ammo_9mm", "gold_watch"]))
	assert_eq(db.get_item("gold_watch").get("value"), 1500)
	assert_true(db.has_item("bandage"))
	assert_false(db.has_item("nope"))
	assert_eq(db.find_by("category", "ammo").size(), 1)
	assert_eq(db.find_by_tag("heal").size(), 1)


func test_item_db_import_reimport_updates_in_place_and_merges_database() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var result := _items.item_db_import(_item_params({"csv_text": "id,price,name\nbandage,75,\nmedkit,300,Medkit\n"}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.updated, ["bandage"])
	assert_eq(result.data.created, ["medkit"])
	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_eq(bandage.get("value"), 75)
	assert_eq(bandage.get("display_name"), "Bandage", "blank cell keeps the old value")
	assert_eq(bandage.get("max_stack"), 5, "missing column keeps the old value")
	assert_eq(_db_ids(result.data.database.path), PackedStringArray(["bandage", "ammo_9mm", "gold_watch", "medkit"]))


func test_item_db_import_existing_modes() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var sheet := "id,price\nbandage,99\n"
	assert_is_error(_items.item_db_import(_item_params({"csv_text": sheet, "existing": "error"})), "ALREADY_EXISTS")
	var skipped := _items.item_db_import(_item_params({"csv_text": sheet, "existing": "skip"}))
	assert_eq(skipped.data.skipped, ["bandage"])
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 50)
	var replaced := _items.item_db_import(_item_params({"csv_text": sheet, "existing": "replace"}))
	assert_eq(replaced.data.replaced, ["bandage"])
	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_eq(bandage.get("value"), 99)
	assert_eq(bandage.get("max_stack"), 1, "replace starts from a fresh item")


func test_item_db_import_bad_rows_write_nothing() -> void:
	_clear_items()
	var sheet := "id,category,weight,price\ngood_item,misc,1,5\nbad item!,misc,1,5\nworse,food_court,heavy,1.5\ngood_item,misc,1,5\n"
	var result := _items.item_db_import(_item_params({"csv_text": sheet}))
	assert_is_error(result, "INVALID_PARAMS")
	var msg: String = result.error.message
	assert_contains(msg, "line 3")
	assert_contains(msg, "'food_court' is not one of")
	assert_contains(msg, "'heavy' is not a number")
	assert_contains(msg, "'1.5' is not a whole number")
	assert_contains(msg, "repeats line 2")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/good_item.tres"), "nothing written")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/item_database.tres"))


func test_item_db_import_param_errors() -> void:
	assert_is_error(_items.item_db_import({"data_dir": ITEM_DIR}), "INVALID_PARAMS", "no source")
	assert_is_error(_items.item_db_import(_item_params({"csv_path": WORK_DIR + "/x.csv"})), "INVALID_PARAMS", "both sources")
	assert_is_error(_items.item_db_import({"csv_path": WORK_DIR + "/missing.csv"}), "NODE_NOT_FOUND")
	assert_is_error(_items.item_db_import(_item_params({"csv_text": "name,price\nA,1\n"})), "INVALID_PARAMS", "no id column")
	assert_is_error(_items.item_db_import(_item_params({"data_dir": "res://addons/x"})), "INVALID_PARAMS")
	assert_is_error(_items.item_db_import(_item_params({"existing": "merge"})), "INVALID_PARAMS")
	assert_is_error(_items.item_db_import(_item_params({"column_map": {"price": "nope"}})), "INVALID_PARAMS")


func test_item_db_import_dry_run_writes_nothing() -> void:
	_clear_items()
	var result := _items.item_db_import(_item_params({"dry_run": true}))
	assert_has_key(result, "data", str(result))
	assert_true(result.data.dry_run)
	assert_eq(result.data.created.size(), 3)
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ITEM_DIR)), "no item folder")


func test_item_db_import_reads_file_tsv_column_map_and_weapon() -> void:
	_clear_items()
	assert_has_key(_tools.weapon_create(_weapon_params("test_item_rifle")), "data")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR))
	var path := WORK_DIR + "/sheet.tsv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	f.store_string("Code\tGun\tKind\t#note\tSize\nrifle_item\ttest_item_rifle\tweapon\tignored\t4\n")
	f.close()
	var result := _items.item_db_import(_item_params({
		"csv_text": null,
		"csv_path": path,
		"column_map": {"Code": "item_id", "Gun": "weapon", "Kind": "category", "Size": "grid_width"},
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.ignored_columns, ["#note"])
	var rifle := _load_fresh(ITEM_DIR + "/rifle_item.tres")
	assert_eq(rifle.get("grid_width"), 4)
	assert_true(rifle.get("weapon") != null, "weapon id resolves to the weapon .tres")
	assert_eq(rifle.get("weapon").resource_path, WORK_DIR + "/data/test_item_rifle.tres")

	var latin1 := WORK_DIR + "/latin1.csv"
	var g := FileAccess.open(latin1, FileAccess.WRITE)
	g.store_buffer(PackedByteArray([0x69, 0x64, 0x0A, 0xE9, 0x0A]))
	g.close()
	assert_is_error(_items.item_db_import(_item_params({"csv_text": null, "csv_path": latin1})), "INVALID_PARAMS", "non-UTF-8 file")


func test_item_db_import_undo_restores_files() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var result := _items.item_db_import(_item_params({"csv_text": "id,price\nbandage,75\nmedkit,300\n"}))
	assert_has_key(result, "data", str(result))
	assert_has_key(result.data, "undo")
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo runs")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/medkit.tres"), "undo deletes the new item")
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 50, "undo restores the old value")
	assert_eq(_db_ids(ITEM_DIR + "/item_database.tres").size(), 3)
	assert_true(global_ur.redo(), "redo runs")
	assert_true(FileAccess.file_exists(ITEM_DIR + "/medkit.tres"))
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 75)


# --- loot tables ---------------------------------------------------------------

const LOOT_DIR := WORK_DIR + "/loot"


func _loot_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"table_id": "test_grunt",
		"data_dir": LOOT_DIR,
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"seed": 7,
		"simulate": 4000,
	}
	params.merge(extra, true)
	return params


const LOOT_ENTRIES := [
	{"item_id": "bandage", "weight": 3, "min_count": 1, "max_count": 2},
	{"item_id": "ammo_9mm", "weight": 1, "min_count": 10, "max_count": 30},
	{"item_id": "gold_watch", "guaranteed": true},
]


func _fresh_loot() -> void:
	_remove_tree(ProjectSettings.globalize_path(LOOT_DIR))
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")


func _row(data: Dictionary, id: String) -> Dictionary:
	for row in data.entries:
		if row.item_id == id:
			return row
	return {}


func test_loot_chances_math() -> void:
	var t := {"rolls_min": 1, "rolls_max": 1, "empty_weight": 0.0, "entries": [
		{"item_id": "a", "weight": 1.0, "min": 1, "max": 1, "guaranteed": false},
		{"item_id": "b", "weight": 3.0, "min": 2, "max": 4, "guaranteed": false},
	]}
	var odds := LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 0.25)
	assert_eq(odds.per_item.b.expected, 0.75 * 3.0)
	assert_eq(odds.nothing, 0.0)
	t.rolls_max = 2
	t.rolls_min = 2
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 1.0 - 0.75 * 0.75)
	t.rolls_min = 1
	t.rolls_max = 1
	t.empty_weight = 4.0
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 0.125)
	assert_eq(odds.nothing, 0.5)
	t.entries.append({"item_id": "g", "weight": 0.0, "min": 0, "max": 1, "guaranteed": true})
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.g.drop, 0.5, "min 0 guaranteed drops half the time")
	assert_eq(odds.nothing, 0.25)


func test_loot_table_create_and_simulate() -> void:
	_fresh_loot()
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "empty_weight": 4}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.status, "created")
	assert_eq(data.added, ["bandage", "ammo_9mm", "gold_watch"])
	assert_eq(data.total_weight, 8.0)
	assert_eq(_row(data, "bandage").roll_percent, 37.5)
	assert_eq(_row(data, "gold_watch").drop_percent, 100.0)
	assert_eq(_row(data, "gold_watch").simulated_drop_percent, 100.0)
	for id in ["bandage", "ammo_9mm"]:
		var row := _row(data, id)
		assert_true(absf(row.drop_percent - row.simulated_drop_percent) < 3.0, "%s simulated %s vs exact %s" % [id, row.simulated_drop_percent, row.drop_percent])
		assert_true(absf(row.expected_count - row.simulated_avg_count) < row.expected_count * 0.15 + 0.05, "%s average count" % id)
	assert_eq(data.nothing_chance_percent, 0.0, "the watch always drops")
	assert_eq(data.simulation.samples.size(), 5)
	assert_contains(data.simulation.samples[0], "gold_watch")

	var again := _loot.loot_table_edit(_loot_params())
	assert_eq(again.data.status, "unchanged", "table_id alone only simulates")
	assert_eq(again.data.simulation.samples, data.simulation.samples, "same seed, same samples")

	var table := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	assert_eq(table.get("table_id"), "test_grunt")
	assert_eq(table.get("empty_weight"), 4.0)
	assert_eq(table.get("entries").size(), 3)
	assert_eq(table.get("entries")[1], {"item_id": "ammo_9mm", "weight": 1.0, "min": 10, "max": 30, "guaranteed": false})
	assert_eq(table.get("item_database").resource_path, ITEM_DIR + "/item_database.tres")


func test_loot_table_roll_resolves_items() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var stored := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	var t := Resource.new()
	t.set_script(_tool_copy(WORK_DIR + "/scripts/loot_table.gd"))
	t.set("entries", stored.get("entries"))
	t.set("item_database", _tool_db(ITEM_DIR + "/item_database.tres"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var drops: Array = t.roll(rng)
	assert_eq(drops.size(), 2, "the watch plus one rolled item")
	assert_eq(drops[0].item_id, "gold_watch")
	assert_eq(drops[0].item.get("value"), 1500)
	assert_eq(t.get_roll_chances().bandage, 0.75)


func test_loot_table_edit_upserts_removes_and_expands_categories() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var result := _loot.loot_table_edit(_loot_params({
		"entries": [{"item_id": "bandage", "weight": 10}, {"category": "valuable", "weight": 2, "max_count": 2}],
		"remove_items": ["ammo_9mm"],
		"rolls_max": 3,
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "updated")
	assert_eq(result.data.changed, ["bandage", "gold_watch"])
	assert_eq(result.data.removed, ["ammo_9mm"])
	assert_eq(result.data.rolls, [1, 3])
	var entries: Array = _load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")
	assert_eq(entries.size(), 2)
	assert_eq(entries[0].weight, 10.0)
	assert_eq(entries[1], {"item_id": "gold_watch", "weight": 2.0, "min": 1, "max": 2, "guaranteed": false})

	result = _loot.loot_table_edit(_loot_params({"entries": [{"tag": "heal", "weight": 1}, {"item_id": "bandage", "weight": 5}], "replace_entries": true}))
	assert_eq(result.data.added, ["bandage"])
	assert_eq(result.data.changed, [], "a later entry for an item added in the same call is not a change")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 5.0, "the later entry wins")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries").size(), 1)


func test_loot_table_errors_write_nothing() -> void:
	_fresh_loot()
	assert_is_error(_loot.loot_table_edit({}), "INVALID_PARAMS", "no table_id")
	assert_is_error(_loot.loot_table_edit(_loot_params({"table_id": "Bad Id"})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params()), "INVALID_PARAMS", "new table without entries")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "nope"}]})), "INVALID_PARAMS", "unknown item")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "chance": 1}]})), "INVALID_PARAMS", "unknown key")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "tag": "heal"}]})), "INVALID_PARAMS", "two selectors")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "min_count": 3, "max_count": 1}]})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"category": "weapon"}]})), "INVALID_PARAMS", "no matching items")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "rolls_min": 3, "rolls_max": 1})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "data_dir": "res://addons/x"})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "database_path": WORK_DIR + "/none.tres"})), "NODE_NOT_FOUND")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": ["/Nope"]})), "NODE_NOT_FOUND")
	assert_false(FileAccess.file_exists(LOOT_DIR + "/test_grunt.tres"))
	var loose := _loot.loot_table_edit(_loot_params({"entries": [{"item_id": "mystery"}], "allow_unknown_items": true, "database_path": WORK_DIR + "/none.tres"}))
	assert_has_key(loose, "data", str(loose))
	assert_eq(loose.data.warnings.size(), 1)


func test_loot_table_dry_run_writes_nothing() -> void:
	_fresh_loot()
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "dry_run": true}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "would create")
	assert_eq(_row(result.data, "bandage").drop_percent, 75.0)
	assert_false(FileAccess.file_exists(LOOT_DIR + "/test_grunt.tres"))


func test_loot_table_undo_restores_file() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var result := _loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "weight": 50}]}))
	assert_has_key(result.data, "undo")
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo runs")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 3.0)
	assert_true(global_ur.redo(), "redo runs")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 50.0)


func _died_source() -> Node3D:
	var script := GDScript.new()
	script.source_code = "@tool\nextends Node3D\nsignal died\n"
	script.reload()
	var node := Node3D.new()
	node.set_script(script)
	node.name = "LootTestEnemy"
	node.add_to_group(&"mcp_test_loot", true)
	_root().add_child(node)
	node.owner = _root()
	_added.append(node)
	return node


func test_loot_attach_adds_dropper_with_undo() -> void:
	_fresh_loot()
	var enemy := _died_source()
	var plain := Node3D.new()
	plain.name = "LootTestCrate"
	_root().add_child(plain)
	plain.owner = _root()
	_added.append(plain)
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": [Util_path(plain)], "attach_to_group": "mcp_test_loot"}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.attached.size(), 2)
	assert_eq(result.data.warnings.size(), 1, "the crate has no died signal: " + str(result.data.warnings))
	var dropper := enemy.get_node_or_null(^"LootDropper")
	assert_true(dropper != null, "dropper added under the enemy")
	assert_eq(dropper.owner, _root())
	assert_eq(dropper.get("loot_table").resource_path, LOOT_DIR + "/test_grunt.tres")
	assert_eq(dropper.get("pickup_script_path"), WORK_DIR + "/scripts/loot_pickup.gd")
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/loot_dropper.gd"))

	var again := _loot.loot_table_edit(_loot_params({"attach_to": [Util_path(enemy)], "trigger_signal": "opened"}))
	assert_eq(again.data.attached, [Util_path(enemy) + "/LootDropper (updated)"])
	assert_eq(enemy.get_child_count(), 1, "no second dropper")
	assert_eq(dropper.get("trigger_signal"), &"opened")

	var scene_ur := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root()))
	assert_true(scene_ur.undo(), "undo the update")
	assert_eq(dropper.get("trigger_signal"), &"died")
	assert_true(scene_ur.undo(), "undo the attach")
	assert_eq(enemy.get_child_count(), 0)
	assert_eq(plain.get_child_count(), 0)


func Util_path(node: Node) -> String:
	return "/" + String(_root().name) + "/" + String(_root().get_path_to(node))


func test_loot_dropper_spawns_pickups_and_pickup_collects() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": []})), "data")
	var stored := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	var t := Resource.new()
	t.set_script(_tool_copy(WORK_DIR + "/scripts/loot_table.gd"))
	t.set("entries", stored.get("entries"))
	t.set("item_database", _tool_db(ITEM_DIR + "/item_database.tres"))

	var holder := Node3D.new()
	holder.name = "LootTestHolder"
	_root().add_child(holder)
	_added.append(holder)
	var enemy := Node3D.new()
	holder.add_child(enemy)
	enemy.position = Vector3(4, 0, 2)
	var dropper := Node3D.new()
	dropper.set_script(_tool_copy(_install_template("loot_dropper")))
	dropper.set("loot_table", t)
	dropper.set("pickup_script_path", _install_template("loot_pickup"))
	enemy.add_child(dropper)
	var got := []
	dropper.dropped.connect(func(d): got.append(d))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var drops: Array = dropper.drop(rng)
	assert_eq(drops.size(), 2)
	assert_eq(got.size(), 1, "dropped signal")
	assert_eq(dropper.drop(rng), [], "drops once")
	var pickups := holder.get_children().filter(func(n): return n != enemy)
	assert_eq(pickups.size(), 2, "pickups land next to the enemy, not under it")
	var watch: Node3D = pickups[0]
	assert_eq(watch.get("item_id"), "gold_watch")
	assert_eq(watch.get("count"), 1)
	assert_true(watch.global_position.distance_to(enemy.global_position) <= 0.81)

	var pickup := Area3D.new()
	pickup.set_script(_tool_copy(_install_template("loot_pickup")))
	pickup.set("item_id", "bandage")
	pickup.set("count", 2)
	holder.add_child(pickup)
	assert_true(pickup.get_node_or_null(^"Visual") != null, "builds its visual")
	var bag_script := GDScript.new()
	bag_script.source_code = "@tool\nextends Node3D\nvar got := {}\nvar full := false\nfunc add_item(item, count):\n\tif full: return false\n\tgot[item] = count\n\treturn true\n"
	bag_script.reload()
	var bag := Node3D.new()
	bag.set_script(bag_script)
	bag.add_to_group(&"player")
	holder.add_child(bag)
	bag.set("full", true)
	assert_false(pickup._try_collect(bag), "a full inventory leaves it")
	bag.set("full", false)
	assert_false(pickup._try_collect(enemy), "only the collector group")
	assert_true(pickup._try_collect(bag))
	assert_eq(bag.get("got"), {"bandage": 2})
	assert_true(pickup.is_queued_for_deletion())


## Installs a loot template into the test scripts folder and returns its path.
func _install_template(name: String) -> String:
	var path := WORK_DIR + "/scripts/%s.gd" % name
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/%s.gd.tmpl" % name))
		f.close()
	return path


# --- inventory -------------------------------------------------------------------

## A @tool item resource with the item_data.gd fields the inventory reads.
func _test_item(id: String, w := 1, h := 1, stack := 1, weight := 1.0, value := 10) -> Resource:
	var script := _tool_copy(_install_item_template())
	var item := Resource.new()
	item.set_script(script)
	item.set("item_id", id)
	item.set("display_name", id)
	item.set("grid_width", w)
	item.set("grid_height", h)
	item.set("max_stack", stack)
	item.set("weight", weight)
	item.set("value", value)
	return item


func _install_item_template() -> String:
	var path := WORK_DIR + "/scripts/item_data.gd"
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/item_data.gd.tmpl"))
		f.close()
	return path


## An inventory (tool copy of the template) under a body with move_speed.
func _test_bag(w := 4, h := 3, max_weight := 0.0) -> Node:
	_install_item_template()
	var body_script := GDScript.new()
	body_script.source_code = "@tool\nextends Node3D\nvar move_speed := 6.0\n"
	body_script.reload()
	var body := Node3D.new()
	body.set_script(body_script)
	body.name = "InvTestBody"
	var bag := Node.new()
	bag.set_script(_tool_copy(_install_template("inventory")))
	bag.set("grid_width", w)
	bag.set("grid_height", h)
	bag.set("max_weight", max_weight)
	bag.set("encumbered_weight", 0.0)
	body.add_child(bag)
	_root().add_child(body)
	_added.append(body)
	return bag


func test_inventory_stacks_and_fills_grid_all_or_nothing() -> void:
	var bag := _test_bag(4, 3)
	var ammo := _test_item("ammo", 1, 1, 30, 0.01)
	var rifle := _test_item("rifle", 4, 2, 1, 3.5)
	assert_true(bag.add_item(ammo, 45), "45 rounds")
	assert_eq(bag.entries.size(), 2, "two stacks of up to 30")
	assert_eq(bag.count_of(ammo), 45)
	assert_true(bag.add_item(ammo, 15), "tops up the partial stack")
	assert_eq(bag.entries.size(), 2)
	assert_true(bag.add_item(rifle), "4x2 rifle fits under the ammo")
	assert_eq([bag.entries[2].x, bag.entries[2].y], [0, 1])
	var before: Array = bag.to_data()
	assert_false(bag.add_item(rifle), "no room for a second rifle")
	assert_false(bag.add_item(ammo, 100), "no room for 100 more rounds")
	assert_eq(bag.to_data(), before, "a failed add changes nothing")
	assert_true(bag.add_item(ammo, 30), "one more stack fits in the last free cells")
	assert_eq(bag.remove_item(ammo, 50), 50)
	assert_eq(bag.count_of(ammo), 40)


func test_inventory_rotates_to_fit_and_respects_weight() -> void:
	var bag := _test_bag(2, 4, 5.0)
	var long := _test_item("long", 3, 1, 1, 1.0)
	assert_true(bag.add_item(long), "3x1 fits a 2-wide bag turned")
	assert_true(bag.entries[0].rotated)
	assert_eq(bag.entry_size(0), Vector2i(1, 3))
	bag.set("allow_rotation", false)
	assert_false(bag.add_item(long), "not without rotation")
	bag.set("allow_rotation", true)
	var brick := _test_item("brick", 1, 1, 10, 1.0)
	assert_true(bag.add_item(brick, 4), "4 kg more: 5 kg total")
	assert_false(bag.add_item(brick, 1), "over max_weight")
	assert_true(is_equal_approx(bag.get_total_weight(), 5.0), "5 kg")


func test_inventory_move_merge_split_sort_and_speed() -> void:
	var bag := _test_bag(4, 2)
	var med := _test_item("med", 1, 1, 5, 0.5, 100)
	var box := _test_item("box", 2, 2, 1, 2.0, 300)
	assert_true(bag.add_item(med, 4))
	assert_true(bag.split_entry(0), "split 4 into 2 + 2")
	assert_eq(bag.entries.size(), 2)
	assert_true(bag.move_entry(1, Vector2i(0, 0)), "drop on the same item merges")
	assert_eq(bag.entries.size(), 1)
	assert_eq(int(bag.entries[0].count), 4)
	assert_true(bag.add_item(box))
	assert_false(bag.move_entry(1, Vector2i(3, 0)), "2x2 does not fit at the right edge")
	assert_true(bag.move_entry(1, Vector2i(2, 0)))
	assert_eq(bag.entry_at(Vector2i(3, 1)), 1)
	assert_true(bag.sort_items())
	assert_eq([bag.entries[0].x, bag.entries[0].y], [0, 0], "largest first")
	assert_eq(bag.item_id_of(bag.entries[0].item), "box")
	assert_eq(bag.get_total_value(), 700)
	var body := bag.get_parent()
	bag.set("encumbered_weight", 1.0)
	bag.set("max_weight", 6.0)
	bag._base_speed = 6.0
	bag._update_speed()
	assert_true(is_equal_approx(float(body.get("move_speed")), 4.2), "4 kg of 1..6 kg slows to 70%%: %s" % body.get("move_speed"))


func _inventory_player() -> Node3D:
	var path := WORK_DIR + "/scripts/inv_test_player.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("extends Node3D\n\nvar move_speed := 6.0\n")
	f.close()
	var player := Node3D.new()
	player.name = "InvTestPlayer"
	player.set_script(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE))
	_root().add_child(player)
	player.owner = _root()
	_added.append(player)
	return player


func _inventory_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"player_path": "InvTestPlayer",
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"toggle_action": ACTION_PREFIX + "inventory",
	}
	params.merge(extra, true)
	return params


func test_inventory_scaffold_adds_nodes_patches_player_with_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var player := _inventory_player()
	var result := _inventory.inventory_ui_scaffold(_inventory_params({"grid_width": 5, "starting_items": [{"item_id": "bandage", "count": 2}]}))
	assert_has_key(result, "data", str(result))
	var inv := player.get_node_or_null(^"Inventory")
	assert_true(inv != null, "Inventory under the player")
	assert_eq(inv.owner, _root())
	assert_eq(inv.get("grid_width"), 5)
	assert_eq(inv.get("starting_items").size(), 1)
	assert_eq(inv.get("starting_items")[0], {"item_id": "bandage", "count": 2})
	assert_eq(inv.get("item_database").resource_path, ITEM_DIR + "/item_database.tres")
	var ui := _root().get_node_or_null(^"InventoryUI")
	assert_true(ui != null and ui is CanvasLayer, "InventoryUI under the scene root")
	_added.append(ui)
	assert_eq(ui.get("inventory_path"), NodePath("../InvTestPlayer/Inventory"))
	assert_eq(ui.get("toggle_action"), StringName(ACTION_PREFIX + "inventory"))
	assert_true(InputMap.has_action(ACTION_PREFIX + "inventory"), "toggle action added")
	var source := FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd")
	assert_true(source.contains("func add_item(item: Variant, count: int = 1) -> bool:"), "add_item appended")
	assert_true(player.get_script().get_script_method_list().any(func(m): return m.name == "add_item"), "cached script reloaded")

	var again := _inventory.inventory_ui_scaffold(_inventory_params({"max_weight": 80}))
	assert_eq(again.data.inventory, "/%s/InvTestPlayer/Inventory (updated)" % _root().name)
	assert_eq(again.data.player_script, "kept (already has add_item)")
	assert_eq(inv.get("max_weight"), 80.0)
	assert_eq(player.get_child_count(), 1, "no second inventory")

	var scene_ur := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root()))
	assert_true(scene_ur.undo(), "undo the update")
	assert_eq(inv.get("max_weight"), 40.0)
	assert_true(scene_ur.undo(), "undo the nodes")
	assert_eq(player.get_child_count(), 0)
	assert_true(_root().get_node_or_null(^"InventoryUI") == null)
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the script patch")
	assert_false(FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd").contains("add_item"))


func test_inventory_scaffold_errors_change_nothing() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var player := _inventory_player()
	for bad in [
		{"starting_items": [{"item_id": "nope"}]},
		{"encumbered_weight": 50, "max_weight": 40},
		{"player_path": "Missing"},
		{"inventory_name": "bad name"},
	]:
		var result := _inventory.inventory_ui_scaffold(_inventory_params(bad))
		assert_has_key(result, "error", "%s -> %s" % [bad, result])
	var dry := _inventory.inventory_ui_scaffold(_inventory_params({"dry_run": true}))
	assert_eq(dry.data.would, {"inventory": "create", "ui": "create"})
	assert_eq(dry.data.player_script, "will patch")
	assert_eq(player.get_child_count(), 0)
	assert_false(FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd").contains("add_item"))


# --- raid map ------------------------------------------------------------------

func _raid_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"name": "RaidTestMap",
		"seed": 1234,
		"room_count": 4,
		"room_size_min": 9,
		"room_size_max": 12,
		"origin": [200, 0, 0],
		"script_dir": WORK_DIR + "/scripts",
		"interact_action": ACTION_PREFIX + "interact",
		"move_player": false,
		"add_light": false,
		"setup_navigation": false,
	}
	params.merge(extra, true)
	return params


func _raid_layout(extra: Dictionary = {}) -> Dictionary:
	var p: Variant = _raid._read_params(_raid_params(extra))
	assert_false(p is Dictionary and p.has("status"), str(p))
	var layout: Variant = _raid._plan(p)
	assert_false(layout.has("status"), str(layout))
	return layout


## Walkable cells reachable from the first walkable cell.
func _flood(grid: Dictionary) -> int:
	var start := -1
	for i in grid.cells.size():
		if grid.cells[i] != 0:
			start = i
			break
	var seen := {start: true}
	var stack := [start]
	while not stack.is_empty():
		var c: int = stack.pop_back()
		var x := c % int(grid.w)
		var z := c / int(grid.w)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var nz: int = z + d.y
			var n: int = nz * int(grid.w) + nx
			if nx >= 0 and nz >= 0 and nx < grid.w and nz < grid.h and grid.cells[n] != 0 and not seen.has(n):
				seen[n] = true
				stack.append(n)
	return seen.size()


func test_raid_layout_connected_walls_outside_and_seeded() -> void:
	var layout := _raid_layout()
	assert_eq(layout.rooms.size(), 4)
	var walkable := 0
	for c in layout.grid.cells:
		if c != 0:
			walkable += 1
	assert_eq(_flood(layout.grid), walkable, "every room and corridor is reachable")
	assert_true(layout.links.size() >= 3, "spanning tree plus extra")
	assert_true(layout.walls.size() >= 8)
	var grid: Dictionary = layout.grid
	for r in layout.walls:
		var c: Vector2 = r.get_center()
		assert_false(RaidTools._walk(grid, int(floor(c.x)) - grid.x0, int(floor(c.y)) - grid.z0), "wall %s stands outside the floor" % r)
	assert_eq(layout.extraction_indices.size(), 1)
	assert_ne(layout.extraction_indices[0], layout.spawn_index, "extraction away from the spawn")
	assert_eq(layout.enemy_spawns.size(), 3, "one per room except the spawn room")
	assert_eq(layout.crates.size(), 3)
	## Props keep ROOM_MARGIN from their room's walls.
	for room in layout.rooms:
		var inner := Rect2(room.rect).grow(-RaidTools.ROOM_MARGIN + 0.01)
		for c in layout.cover:
			if c.room == room.name:
				assert_true(inner.encloses(c.rect), "cover %s inside %s" % [c.rect, inner])
	var again := _raid_layout()
	assert_eq(_raid._preview(again), _raid._preview(layout), "same seed, same map")
	var other := _raid_layout({"seed": 99})
	assert_ne(_raid._preview(other), _raid._preview(layout))


func test_raid_explicit_rooms_connections_and_roles() -> void:
	var layout := _raid_layout({
		"rooms": [
			{"name": "Gate", "position": [0, 20], "size": [10, 10], "enemies": 0},
			{"name": "Yard", "position": [0, 0], "size": [16, 14], "cover": 5, "crates": 2, "enemies": 2},
			{"name": "Bunker", "position": [24, 0], "size": [10, 10]},
		],
		"connections": [["Gate", "Yard"], ["Yard", 2]],
		"extraction_rooms": ["Bunker", "Gate"],
		"player_spawn_room": "Gate",
	})
	assert_eq(layout.links, [[0, 1], [1, 2]])
	assert_eq(layout.spawn_index, 0)
	assert_eq(layout.extractions.size(), 2)
	assert_eq(layout.rooms[1].counts, {"cover": 5, "crates": 2, "enemies": 2})
	assert_eq(layout.rooms[0].roles, ["player_spawn", "extraction"])
	var walkable := 0
	for c in layout.grid.cells:
		if c != 0:
			walkable += 1
	assert_eq(_flood(layout.grid), walkable)
	var spawn: Vector3 = layout.player_spawn
	for e in layout.extractions:
		assert_true(e.position.distance_to(spawn) >= 2.0, "zone and spawn do not overlap in a shared room")
	assert_eq(layout.enemy_spawns[0].patrol.size(), 4)


func test_raid_rejects_bad_params() -> void:
	for bad in [
		{"room_size_min": 14, "room_size_max": 8},
		{"rooms": [{"position": [0, 0], "size": [2, 2]}]},
		{"rooms": [{"position": [0, 0], "size": [8, 8], "color": "red"}]},
		{"rooms": [{"position": [0, 0], "size": [8, 8]}], "connections": [[0, 5]]},
		{"player_spawn_room": "Nowhere"},
		{"enemy_scenes": ["res://zz_missing/enemy.tscn"]},
		{"crate_loot_table": "no_such_table"},
		{"script_dir": "res://addons/x"},
		{"name": "bad/name"},
		{"room_count": 64, "room_size_max": 100, "room_size_min": 100, "room_gap": 100},
	]:
		var result := _raid.raid_map_blockout(_raid_params(bad))
		assert_has_key(result, "error", "%s -> %s" % [bad, result])
	var dry := _raid.raid_map_blockout(_raid_params({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.status, "dry_run")
	assert_true(dry.data.preview.size() > 5)
	assert_true(_root().get_node_or_null(^"RaidTestMap") == null, "dry run adds nothing")


func test_raid_builds_map_in_scene_with_navigation_and_undo() -> void:
	var regions_before := _root().find_children("*", "NavigationRegion3D", true, false).size()
	var result := _raid.raid_map_blockout(_raid_params({"setup_navigation": true, "room_count": 3, "seed": 5}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.status, "created")
	var map := _track(data.map_path) as Node3D
	assert_true(map != null)
	assert_eq(map.owner, _root())
	assert_eq(map.position, Vector3(200, 0, 0))
	var wall := map.get_node("Walls").get_child(0) as StaticBody3D
	assert_true(wall != null and wall.get_node("Shape").shape is BoxShape3D)
	assert_eq(wall.owner, _root(), "walls are saved with the scene")
	assert_eq(map.get_node("Walls").get_child_count(), data.counts.walls)
	assert_eq(map.get_node("Rooms").get_child_count(), 3)
	var spawn := map.get_node("PlayerSpawn") as Marker3D
	assert_true(spawn.is_in_group(&"player_spawn"))
	assert_eq(map.get_node("Extractions").get_child_count(), 1)
	var zone := map.get_node("Extractions/Extraction1")
	assert_eq(zone.get_script().resource_path, WORK_DIR + "/scripts/raid_extraction.gd")
	var crate := map.get_node("Crates/Crate1")
	assert_eq(crate.get_script().resource_path, WORK_DIR + "/scripts/loot_crate.gd")
	assert_eq(crate.get("interact_action"), StringName(ACTION_PREFIX + "interact"))
	assert_true(InputMap.has_action(ACTION_PREFIX + "interact"), "interact action created")
	assert_true(data.counts.enemy_spawns >= 1)
	assert_eq(map.get_node("EnemySpawns").get_child_count(), data.counts.enemy_spawns)
	## Navigation: a new region baked from the map.
	assert_eq(data.navigation.status, "created", str(data.navigation))
	assert_true(data.navigation.polygons > 0, "nav mesh covers the floor")
	assert_true(map.is_in_group(&"navigation_source") or _root().is_in_group(&"navigation_source"))
	var region := McpScenePath.resolve(data.navigation.region_path, _root())
	assert_true(region != null)

	assert_true(editor_undo(_undo_redo))
	assert_true(map.get_parent() == null, "undo removes the map")
	assert_eq(_root().find_children("*", "NavigationRegion3D", true, false).size(), regions_before, "and the new region")


func test_raid_replace_places_enemies_crate_loot_and_restores_on_undo() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var enemy_result := _tools.enemy_scaffold({
		"enemy_id": "raid_test_grunt",
		"scene_dir": WORK_DIR + "/enemies",
		"script_dir": WORK_DIR + "/scripts",
		"add_to_scene": false,
		"overwrite": true,
	})
	assert_has_key(enemy_result, "data", str(enemy_result))
	var first := _raid.raid_map_blockout(_raid_params({"room_count": 2, "enemies_per_room": 0}))
	assert_has_key(first, "data", str(first))
	var old_map := _track(first.data.map_path)
	assert_is_error(_raid.raid_map_blockout(_raid_params()), "ALREADY_EXISTS")

	var result := _raid.raid_map_blockout(_raid_params({
		"replace": true,
		"enemy_scenes": [enemy_result.data.scene_path],
		"crate_loot_table": LOOT_DIR + "/test_grunt.tres",
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "replaced")
	assert_eq(result.data.enemies_placed, 3)
	var map := _track(result.data.map_path)
	assert_true(old_map.get_parent() == null, "old map removed")
	var enemy := map.get_node("Enemies").get_child(0)
	assert_eq(enemy.scene_file_path, enemy_result.data.scene_path)
	assert_eq(enemy.owner, _root())
	var route: PackedVector3Array = enemy.get("patrol_points")
	assert_eq(route.size(), 4, "patrol loop through the room corners")
	assert_true(route[0].x > 150.0, "route in world space (origin x=200)")
	var dropper := map.get_node("Crates/Crate1/LootDropper")
	assert_eq(dropper.get("trigger_signal"), &"opened")
	assert_eq(dropper.get("loot_table").resource_path, LOOT_DIR + "/test_grunt.tres")
	assert_eq(dropper.owner, _root())

	assert_true(editor_undo(_undo_redo))
	assert_true(map.get_parent() == null)
	assert_eq(old_map.get_parent(), _root(), "undo brings the old map back")
	assert_eq(old_map.get_node("Walls").get_child(0).owner, _root(), "with its owners, so it still saves")


func test_raid_crate_search_and_open() -> void:
	var crate := StaticBody3D.new()
	crate.set_script(_tool_copy(_install_raid_template("loot_crate")))
	crate.set("search_time", 0.5)
	var holder := Node3D.new()
	holder.name = "RaidCrateHolder"
	_root().add_child(holder)
	_added.append(holder)
	holder.add_child(crate)
	var player := Node3D.new()
	player.add_to_group(&"player")
	holder.add_child(player)
	player.position = Vector3(5, 0, 0)
	assert_true(crate.nearest_player() == null, "too far")
	player.position = Vector3(1, 0, 0.5)
	assert_eq(crate.nearest_player(), player)
	var opened := []
	crate.opened.connect(func(by): opened.append(by))
	crate.start_search(player)
	assert_false(crate.get("is_open"))
	crate.open(player)
	assert_true(crate.get("is_open"))
	assert_eq(opened, [player])
	crate.open(player)
	assert_eq(opened.size(), 1, "opens once")


func test_raid_extraction_extracts_player() -> void:
	var zone := Area3D.new()
	zone.set_script(_tool_copy(_install_raid_template("raid_extraction")))
	zone.set("restart_delay", 0.0)
	var holder := Node3D.new()
	holder.name = "RaidZoneHolder"
	_root().add_child(holder)
	_added.append(holder)
	holder.add_child(zone)
	var bag_script := GDScript.new()
	bag_script.source_code = "@tool\nextends Node\nfunc get_total_value():\n\treturn 1550\n"
	bag_script.reload()
	var player := CharacterBody3D.new()
	player.add_to_group(&"player")
	var bag := Node.new()
	bag.name = "Inventory"
	bag.set_script(bag_script)
	player.add_child(bag)
	holder.add_child(player)
	var other := CharacterBody3D.new()
	holder.add_child(other)
	zone._on_body_entered(other)
	assert_eq(zone.time_left(), -1.0, "only the player group")
	zone._on_body_entered(player)
	assert_eq(zone.time_left(), 5.0)
	zone._on_body_exited(player)
	assert_eq(zone.time_left(), -1.0, "leaving cancels")
	var got := []
	zone.extracted.connect(func(b): got.append(b))
	zone.extract(player)
	assert_eq(got, [player])
	assert_eq(player.process_mode, Node.PROCESS_MODE_DISABLED, "player frozen")
	assert_contains(zone._hud.text, "1550")
	zone.extract(player)
	assert_eq(got.size(), 1, "extracts once")


func _install_raid_template(name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _install_template(name)


# --- raid playtest -----------------------------------------------------------------

func _agent() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("raid_playtest_agent"))


func test_playtest_run_params_defaults_and_errors() -> void:
	var p: Dictionary = PlaytestTools.read_run_params({})
	assert_eq(p.duration, 60.0)
	assert_eq(p.time_scale, 1.0)
	assert_true(p.wait)
	assert_true(p.crates and p.loot and p.fight and p.extract and p.stop_after)
	assert_false(p.hunt or p.explore or p.invulnerable)
	assert_eq(p.max_crates, -1)
	assert_eq(p.script_dir, "res://scripts/topdown")
	assert_is_error(PlaytestTools.read_run_params({"bogus": 1}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"duration": 1}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"time_scale": 9}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"hunt": "yes"}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"max_crates": 1.5}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"script_dir": "res://addons/x"}), "INVALID_PARAMS")


func test_playtest_tool_rejects_bad_calls() -> void:
	assert_is_error(_playtest.raid_playtest({"op": "dance"}), "INVALID_PARAMS")
	assert_is_error(_playtest.raid_playtest({"op": "report", "duration": 5}), "INVALID_PARAMS")
	assert_is_error(_playtest.raid_playtest({"scene": "res://nope/missing.tscn"}), "NODE_NOT_FOUND")
	assert_is_error(_playtest.raid_playtest({"scene": "scenes/raid.tscn"}), "INVALID_PARAMS")
	## wait=true must fit the tool's 120 s budget in real seconds.
	assert_is_error(_playtest.raid_playtest({"duration": 300}), "INVALID_PARAMS")
	## No deferred context (e.g. a direct call): refuses before touching anything.
	assert_is_error(_playtest.raid_playtest({"duration": 300, "time_scale": 4}), "INTERNAL_ERROR")


func test_playtest_request_matches_agent_defaults() -> void:
	var agent := _agent()
	var defaults: Dictionary = agent.get_script_constant_map()["DEFAULTS"]
	var request := PlaytestTools.build_request(PlaytestTools.read_run_params({"hunt": true, "duration": 30}), "abc")
	assert_eq(request.token, "abc")
	assert_true(request.hunt)
	assert_eq(request.duration, 30.0)
	assert_gt(float(request.created_unix), 0.0)
	for key in request:
		if key != "created_unix":
			assert_true(defaults.has(key), "agent understands '%s'" % key)


func test_playtest_input_inverts_camera_relative_movement() -> void:
	var agent := _agent()
	## The player controller's _camera_relative(), for comparison.
	var forward_of := func(cam: Basis, input: Vector2) -> Vector3:
		var f := -cam.z
		f.y = 0.0
		var r := cam.x
		r.y = 0.0
		return (r.normalized() * input.x - f.normalized() * input.y).limit_length(1.0)
	var cam := Basis.from_euler(Vector3(deg_to_rad(-55.0), deg_to_rad(30.0), 0.0))
	for dir in [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-0.6, 0, 0.8), Vector3(0.3, 0, 0.3)]:
		var input: Vector2 = agent.input_for_direction(dir, cam)
		var moved: Vector3 = forward_of.call(cam, input)
		var want: Vector3 = dir.limit_length(1.0)
		assert_true(moved.distance_to(want) < 0.001, "input %s moves %s, wanted %s" % [input, moved, want])
	assert_eq(agent.input_for_direction(Vector3.ZERO, cam), Vector2.ZERO)
	## A straight-down camera falls back to world axes.
	var down := Basis.from_euler(Vector3(deg_to_rad(-90.0), 0.0, 0.0))
	var input2: Vector2 = agent.input_for_direction(Vector3(1, 0, 0), down)
	assert_true(input2.distance_to(Vector2(1, 0)) < 0.001, "top-down camera: %s" % input2)


func test_playtest_agent_inert_without_request() -> void:
	var agent := _agent()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PlaytestTools.REQUEST_PATH))
	assert_eq(agent.read_request(), null)
	## A stale request is consumed and ignored.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PlaytestTools.DIR))
	var f := FileAccess.open(PlaytestTools.REQUEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "old", "created_unix": Time.get_unix_time_from_system() - 3600}))
	f.close()
	assert_eq(agent.read_request(), null)
	assert_false(FileAccess.file_exists(PlaytestTools.REQUEST_PATH), "consumed")
	f = FileAccess.open(PlaytestTools.REQUEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "new", "created_unix": Time.get_unix_time_from_system(), "hunt": true}))
	f.close()
	var request: Dictionary = agent.read_request()
	assert_eq(request.token, "new")
	var config: Dictionary = agent.merge_config(request)
	assert_true(config.hunt)
	assert_eq(config.duration, 60.0, "defaults fill the rest")


func test_playtest_performance_summary() -> void:
	var agent := _agent()
	var frames := PackedFloat32Array()
	for i in 99:
		frames.append(10.0)
	frames.append(50.0)
	var perf: Dictionary = agent.performance_summary(frames, [100, 60, 95])
	assert_eq(perf.frames, 100)
	assert_eq(perf.frame_ms_max, 50.0)
	assert_eq(perf.fps_min, 60.0)
	assert_eq(perf.fps_1pct_low, 20.0)
	assert_true(absf(perf.fps_avg - 1000.0 / 10.4) < 0.1, "avg %s" % perf.fps_avg)
	var empty: Dictionary = agent.performance_summary(PackedFloat32Array(), [])
	assert_eq(empty.frames, 0)


func test_playtest_issues_and_verdict() -> void:
	var agent := _agent()
	var clean := {
		"result": "extracted", "game_time": 40.0,
		"errors": {"count": 0},
		"combat": {"weapon": "Smg", "shots": 10, "hits": 5, "enemies_killed": 2, "enemies_total": 2},
		"navigation": {"nav_ready": true, "stuck": [], "unreachable": []},
		"loot": {"pickups_refused": 0, "crates_opened": 3, "crates_total": 3},
		"performance": {"frames": 100, "fps_min": 58.0, "fps_avg": 60.0},
	}
	assert_eq(agent.find_issues(clean, {}), [])
	clean["issues"] = []
	var ok := PlaytestTools.summarize(clean, {"token": "t"})
	assert_eq(ok.verdict, "pass")
	assert_eq(ok.token, "t")
	assert_contains(ok.summary, "crates 3/3")
	var bad := clean.duplicate(true)
	bad.result = "died"
	bad.errors = {"count": 2}
	bad.combat.weapon = ""
	bad.navigation = {"nav_ready": false, "stuck": [{"t": 1}], "unreachable": [{"kind": "crate", "target": "Crate2", "reason": "stuck"}]}
	bad.loot.pickups_refused = 1
	bad.performance.fps_min = 12.0
	var issues: Array = agent.find_issues(bad, {"min_fps": 30.0})
	assert_eq(issues.size(), 8, str(issues))
	assert_contains(str(issues), "Crate2")
	bad["issues"] = issues
	assert_eq(PlaytestTools.summarize(bad).verdict, "issues")
	## A timeout only counts when extraction was the goal.
	var timeout := clean.duplicate(true)
	timeout.result = "timeout"
	assert_eq(agent.find_issues(timeout, {"extract": false}), [])
	assert_eq(agent.find_issues(timeout, {"extract": true}).size(), 1)


func test_playtest_report_op_reads_matching_token() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PlaytestTools.DIR))
	var f := FileAccess.open(PlaytestTools.REPORT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "r1", "result": "extracted", "issues": []}))
	f.close()
	assert_eq(PlaytestTools.read_report("other"), null)
	assert_eq(PlaytestTools.read_report("r1").result, "extracted")
	var out: Dictionary = _playtest.raid_playtest({"op": "report"})
	assert_eq(out.data.verdict, "pass")
	assert_eq(out.data.result, "extracted")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PlaytestTools.REPORT_PATH))
	assert_eq(_playtest.raid_playtest({"op": "report"}).data.status, "no_report")


func test_playtest_install_registers_autoload_with_undo() -> void:
	var key := PlaytestTools.autoload_key()
	var before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var dir := WORK_DIR + "/agent"
	var out: Dictionary = _playtest.raid_playtest({"op": "install", "script_dir": dir})
	assert_eq(out.data.script, dir + "/raid_playtest_agent.gd")
	assert_eq(out.data.script_status, "created")
	assert_true(FileAccess.file_exists(dir + "/raid_playtest_agent.gd"))
	assert_eq(ProjectSettings.get_setting(key), "*" + dir + "/raid_playtest_agent.gd")
	assert_contains(FileAccess.get_file_as_string("res://project.godot"), dir + "/raid_playtest_agent.gd", "saved to project.godot")
	var again: Dictionary = _playtest.raid_playtest({"op": "install", "script_dir": dir})
	assert_eq(again.data.script_status, "kept")
	assert_eq(again.data.autoload_status, "kept")
	EditorInterface.get_editor_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY).undo()
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, before, "undo restores the autoload")
	_playtest.raid_playtest({"op": "install", "script_dir": dir})
	var removed: Dictionary = _playtest.raid_playtest({"op": "uninstall"})
	assert_true(removed.data.removed)
	assert_false(ProjectSettings.has_setting(key))
	assert_true(FileAccess.file_exists(dir + "/raid_playtest_agent.gd"), "script kept")
	if before != null:
		ProjectSettings.set_setting(key, before)
		ProjectSettings.save()


# --- hideout -------------------------------------------------------------------------

const HIDEOUT_SAVE := "user://zz_mcp_test_hideout/save.json"


## A @tool item database holding bandage (stack 5, 0.1 kg, 50), rifle (3x1,
## 3.5 kg, 9000) and watch (0.2 kg, 1500).
func _hideout_db() -> Resource:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	var db := Resource.new()
	db.set_script(_tool_copy(_install_template("item_database")))
	var items: Array[Resource] = [
		_test_item("bandage", 1, 1, 5, 0.1, 50),
		_test_item("rifle", 3, 1, 1, 3.5, 9000),
		_test_item("watch", 1, 1, 1, 0.2, 1500),
	]
	db.set("items", items)
	return db


func _hideout_bag(db: Resource, w: int, h: int, max_weight := 0.0) -> Node:
	var bag := _test_bag(w, h, max_weight)
	bag.set("item_database", db)
	return bag


func _hideout_state_script() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("hideout_state"))


## A HideoutState (tool copy) outside the tree, saving to HIDEOUT_SAVE.
func _hideout_state(db: Resource) -> Node:
	var state := Node.new()
	state.set_script(_hideout_state_script())
	state.set("save_path", HIDEOUT_SAVE)
	state.set("hideout_scene", "")
	state.set("_db", db)
	_added.append(state)
	return state


func _read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func test_hideout_fill_transfer_and_move_all() -> void:
	var db := _hideout_db()
	var S := _hideout_state_script()
	var stash := _hideout_bag(db, 4, 3)
	var bag := _hideout_bag(db, 2, 2, 4.0)
	var left: Array = S.fill_inventory(stash, [
		{"item_id": "rifle", "count": 1, "x": 1, "y": 0, "rotated": false},
		{"item_id": "bandage", "count": 4, "x": 0, "y": 0, "rotated": false},
		{"item_id": "bandage", "count": 3, "x": 1, "y": 0, "rotated": false},
		{"item_id": "ghost", "count": 1, "x": 0, "y": 2, "rotated": false},
	])
	assert_eq(left, [{"item_id": "ghost", "count": 1, "unknown": true}], "unknown ids come back")
	assert_eq([stash.entries[0].x, stash.entries[0].y], [1, 0], "saved cell kept")
	assert_eq(stash.count_of("bandage"), 7, "a stack on a taken cell is placed elsewhere")
	var rifle_index := 0
	assert_eq(S.transfer(stash, rifle_index, bag, Vector2i(0, 0)), 0, "3x1 rifle does not fit a 2x2 bag")
	assert_eq(S.transfer(stash, rifle_index, bag, Vector2i(0, 0), true), 0, "nor turned")
	assert_eq(stash.count_of("rifle"), 1, "a failed move changes nothing")
	var full_stack := -1
	for i in stash.entries.size():
		if stash.item_id_of(stash.entries[i].item) == "bandage" and int(stash.entries[i].count) == 5:
			full_stack = i
	assert_eq(S.transfer(stash, full_stack, bag, Vector2i(0, 0)), 5, "stack dropped on a cell")
	assert_eq(S.transfer(stash, stash.entries.size() - 1, bag, Vector2i(0, 0)), 0, "full stack under it: no merge")
	assert_eq(S.transfer(stash, stash.entries.size() - 1, bag, Vector2i(1, 0)), 2, "free cell")
	assert_eq(stash.count_of("bandage"), 0)
	assert_true(is_equal_approx(bag.get_total_weight(), 0.7), "0.7 kg in the bag")
	bag.set("max_weight", 1.0)
	stash.add_item("bandage", 5)
	var idx: int = stash.entries.size() - 1
	assert_eq(S.transfer(stash, idx, bag), 3, "weight limit lets 3 more in")
	assert_eq(stash.count_of("bandage"), 2, "the rest stays")
	assert_eq(S.move_all(bag, stash), {"bandage": 10})
	assert_true(bag.entries.is_empty())
	var tiny := _hideout_bag(db, 1, 1)
	tiny.add_item("watch")
	assert_eq(S.move_all(stash, tiny), {}, "nothing fits a full grid")
	assert_eq(stash.count_of("rifle"), 1, "and nothing is lost")
	assert_eq(S.count_items([{"item_id": "a", "count": 2}, {"item_id": "a", "count": 3}, {"item_id": "b", "count": 1}]), {"a": 5, "b": 1})


func test_hideout_state_extract_death_mia_and_save() -> void:
	_remove_tree(ProjectSettings.globalize_path(HIDEOUT_SAVE.get_base_dir()))
	var db := _hideout_db()
	var state := _hideout_state(db)
	var bag := _hideout_bag(db, 4, 3)
	bag.name = "Inventory"
	var body: Node = bag.get_parent()
	bag.add_item("bandage", 3)
	bag.add_item("watch")
	state.set("raid_active", true)
	state.set("_player", body)
	state.set("_kit_value", 150)
	state._on_extracted(null)
	assert_true(state.pending_return, "bag is on its way home")
	assert_eq(state.loadout, bag.to_data())
	assert_eq(state.stats.extracted, 1)
	assert_eq(state.stats.raids, 1)
	assert_eq(state.last_raid.value, 1650)
	assert_eq(state.last_raid.profit, 1500)
	assert_eq(state.last_raid.items, {"bandage": 3, "watch": 1})
	var saved: Dictionary = _read_json(HIDEOUT_SAVE)
	assert_true(saved.pending_return, "saved at extraction")
	assert_eq(saved.loadout.size(), 2)
	state._on_extracted(null)
	assert_eq(state.stats.extracted, 1, "ends once")

	## Back in the hideout: the bag moves into the stash.
	var home := _hideout_state(db)
	home.load_game()
	assert_true(home.pending_return)
	var stash := _hideout_bag(db, 4, 3)
	var bag2 := _hideout_bag(db, 2, 2)
	var got := []
	home.hideout_ready.connect(func(_h, s): got.append(s))
	var summary: Dictionary = home.enter_hideout(null, stash, bag2)
	assert_true(summary.returned)
	assert_eq(summary.moved, {"bandage": 3, "watch": 1})
	assert_true(bag2.entries.is_empty(), "bag emptied into the stash")
	assert_eq(stash.count_of("watch"), 1)
	assert_false(home.pending_return)
	assert_eq(got.size(), 1, "hideout_ready")
	saved = _read_json(HIDEOUT_SAVE)
	assert_eq(saved.stash.size(), 2)
	assert_eq(saved.loadout, [])
	assert_false(saved.pending_return)

	## Dying loses the bag.
	state.set("_ending", false)
	state.set("raid_active", true)
	state._on_player_died()
	assert_eq(state.loadout, [])
	assert_eq(state.stats.died, 1)
	assert_eq(state.stats.raids, 2)
	assert_eq(state.last_raid.result, "died")
	assert_eq(state.last_raid.value_lost, 1650)
	assert_eq(state.stats.value_lost, 1650)

	## Closing the game mid-raid counts as a loss on the next start.
	state.set("in_raid", true)
	state.set("loadout", [{"item_id": "rifle", "count": 1, "x": 0, "y": 0, "rotated": false}])
	state.save_game()
	var next := _hideout_state(db)
	next.load_game()
	assert_eq(next.stats.mia, 1)
	assert_eq(next.last_raid.result, "mia")
	assert_eq(next.last_raid.value_lost, 9000)
	assert_eq(next.loadout, [])
	assert_false(next.in_raid)
	assert_false(_read_json(HIDEOUT_SAVE).in_raid, "loss saved")

	## A new game waits to put starting_stash into the stash.
	next.set("starting_stash", [{"item_id": "bandage", "count": 2}])
	next.new_game()
	assert_eq(next.overflow, [{"item_id": "bandage", "count": 2}])
	assert_eq(next.stats.raids, 0)
	var fresh := _hideout_bag(db, 3, 3)
	var s2: Dictionary = next.enter_hideout(null, fresh, _hideout_bag(db, 2, 2))
	assert_eq(s2.placed_waiting, {"bandage": 2})
	assert_eq(fresh.count_of("bandage"), 2)
	assert_eq(next.overflow, [])

	## A broken save is set aside.
	var f := FileAccess.open(HIDEOUT_SAVE, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	var broken := _hideout_state(db)
	broken.load_game()
	assert_true(FileAccess.file_exists(HIDEOUT_SAVE + ".bad"), "kept as .bad")
	assert_eq(broken.stash, [])


func test_hideout_state_deploy_gives_player_the_bag() -> void:
	var db := _hideout_db()
	var state := _hideout_state(db)
	var bag := _hideout_bag(db, 4, 3)
	bag.name = "Inventory"
	var body: Node = bag.get_parent()
	body.add_to_group(&"player")
	bag.add_item("bandage", 2)
	var zone := Area3D.new()
	zone.set_script(_tool_copy(_install_raid_template("raid_extraction")))
	zone.set("restart_delay", 4.0)
	body.get_parent().add_child(zone)
	_added.append(zone)
	_root().add_child(state)
	state.set_process(false)
	state.set("save_path", HIDEOUT_SAVE)
	state.set("hideout_scene", "res://zz_mcp_test_topdown/hideout.tscn")
	state.set("_db", db)
	state.set("loadout", [{"item_id": "rifle", "count": 1, "x": 0, "y": 0, "rotated": false}])
	state.set("_deploy_pending", true)
	var got := []
	state.raid_started.connect(func(f): got.append(f))
	state.begin_raid()
	assert_eq(got, [true], "raid from the hideout")
	assert_eq(bag.count_of("rifle"), 1, "the bag replaces the starting kit")
	assert_eq(bag.count_of("bandage"), 0)
	assert_true(state.raid_active)
	assert_true(zone.is_connected(&"extracted", Callable(state, "_on_extracted")), "extraction hooked")
	assert_eq(zone.get("restart_delay"), 0.0, "the zone no longer reloads the raid")
	assert_eq(state.deploy(bag, bag, "res://zz_mcp_test_topdown/nope.tscn"), ERR_FILE_NOT_FOUND)


func test_hideout_ui_builds_and_moves_between_grids() -> void:
	var db := _hideout_db()
	var inv_script := _tool_copy(_install_template("inventory"))
	var ui := Control.new()
	ui.name = "HideoutUiTest"
	ui.set_script(_tool_copy(_install_template("hideout")))
	ui.set("raid_scene", "res://zz_mcp_test_topdown/nope.tscn")
	for spec in [["Stash", 6, 4, 0.0], ["Loadout", 2, 2, 5.0]]:
		var inv := Node.new()
		inv.name = spec[0]
		inv.set_script(inv_script)
		inv.set("grid_width", spec[1])
		inv.set("grid_height", spec[2])
		inv.set("max_weight", spec[3])
		inv.set("item_database", db)
		ui.add_child(inv)
	_root().add_child(ui)
	_added.append(ui)
	assert_true(ui.is_hideout())
	var stash: Node = ui.get("stash")
	var bag: Node = ui.get("loadout")
	assert_true(stash != null and bag != null, "finds both grids")
	stash.add_item("rifle")
	stash.add_item("watch")
	assert_contains(ui.get("_stash_label").text, "10,500")
	assert_eq(ui.transfer_entry(stash, 0), 0, "rifle does not fit the 2x2 bag")
	assert_eq(ui.transfer_entry(stash, 1), 1, "watch goes in")
	assert_eq(bag.count_of("watch"), 1)
	assert_contains(ui.get("_bag_label").text, "0.2")
	ui.unpack_bag()
	assert_eq(stash.count_of("watch"), 1)
	assert_true(bag.entries.is_empty())
	assert_eq(ui.deploy(), ERR_FILE_NOT_FOUND, "missing raid scene")


## A raid scene file with an extraction zone and a player whose Inventory
## is 5x4 / 22 kg and starts with 2 bandages.
func _hideout_raid_scene() -> String:
	_install_raid_template("raid_extraction")
	_install_template("inventory")
	_install_template("player_controller")
	var root := Node3D.new()
	root.name = "RaidTest"
	var zone := Area3D.new()
	zone.name = "Exit"
	zone.set_script(load(WORK_DIR + "/scripts/raid_extraction.gd"))
	root.add_child(zone)
	zone.owner = root
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load(WORK_DIR + "/scripts/player_controller.gd"))
	root.add_child(player)
	player.owner = root
	var inv := Node.new()
	inv.name = "Inventory"
	inv.set_script(load(WORK_DIR + "/scripts/inventory.gd"))
	inv.set("grid_width", 5)
	inv.set("grid_height", 4)
	inv.set("max_weight", 22.0)
	var start: Array[Dictionary] = [{"item_id": "bandage", "count": 2}]
	inv.set("starting_items", start)
	player.add_child(inv)
	inv.owner = root
	var path := WORK_DIR + "/raid_test.tscn"
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	ResourceSaver.save(packed, path)
	return path


func _hideout_params(raid: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"raid_scene": raid,
		"hideout_scene": WORK_DIR + "/hideout.tscn",
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"save_path": HIDEOUT_SAVE,
	}
	params.merge(extra, true)
	return params


func test_hideout_scaffold_scene_settings_and_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var info := HideoutTools.inspect_scene(raid)
	assert_eq(info.extractions, 1)
	assert_true(info.player)
	assert_eq(info.inventory.grid_width, 5)
	var key := "autoload/" + HideoutTools.AUTOLOAD_NAME
	var autoload_before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var main_before := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var scene_path := WORK_DIR + "/hideout.tscn"

	var dry := _hideout.hideout_scaffold(_hideout_params(raid, {"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.loadout.grid, [5, 4], "bag size from the raid player's inventory")
	assert_eq(dry.data.loadout.max_weight, 22.0)
	assert_eq(dry.data.starting_stash, [{"item_id": "bandage", "count": 2}], "starting stash from its starting_items")
	assert_false(FileAccess.file_exists(scene_path), "dry run writes nothing")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before)

	var result := _hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 8, "stash_height": 9}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.hideout_scene_status, "created")
	assert_true(FileAccess.file_exists(scene_path))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/hideout_state.gd"))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/hideout.gd"))
	var scene := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq(scene.get_node("Stash").get("grid_width"), 8)
	assert_eq(scene.get_node("Stash").get("grid_height"), 9)
	assert_eq(scene.get_node("Stash").get("max_weight"), 0.0)
	assert_eq(scene.get_node("Loadout").get("grid_width"), 5)
	assert_eq(scene.get_node("Loadout").get("max_weight"), 22.0)
	assert_eq(scene.get_node("Loadout").get("item_database").resource_path, ITEM_DIR + "/item_database.tres")
	scene.free()
	assert_eq(ProjectSettings.get_setting(key), "*" + WORK_DIR + "/scripts/hideout_state.gd")
	assert_eq(ProjectSettings.get_setting("game/hideout/raid_scene"), raid)
	assert_eq(ProjectSettings.get_setting("game/hideout/save_path"), HIDEOUT_SAVE)
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), scene_path)
	assert_contains(FileAccess.get_file_as_string("res://project.godot"), "hideout_state.gd", "saved to project.godot")

	var again := _hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 12, "return_delay": 1.0}))
	assert_eq(again.data.hideout_scene_status, "kept")
	assert_eq(again.data.starting_stash_from, "kept")
	assert_true(again.data.warnings.any(func(w): return String(w).contains("kept")), "says the scene was kept")
	assert_eq(ProjectSettings.get_setting("game/hideout/return_delay"), 1.0)

	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the rerun")
	assert_eq(ProjectSettings.get_setting("game/hideout/return_delay"), 3.0)
	assert_true(FileAccess.file_exists(scene_path), "the rerun did not write the scene")
	assert_true(global_ur.undo(), "undo the scaffold")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before, "autoload removed")
	assert_eq(str(ProjectSettings.get_setting("application/run/main_scene", "")), main_before, "main scene restored")
	assert_false(ProjectSettings.has_setting("game/hideout/raid_scene"))
	assert_false(FileAccess.file_exists(scene_path), "scene file removed")


func test_hideout_scaffold_rejects_bad_params() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"bogus": 1})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"save_path": "res://save.json"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"save_path": "user://save.txt"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"hideout_scene": "res://addons/x.tscn"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"hideout_scene": raid})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(WORK_DIR + "/missing.tscn")), "NODE_NOT_FOUND")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 0})), "INVALID_PARAMS")
	var unknown := _hideout.hideout_scaffold(_hideout_params(raid, {"starting_stash": [{"item_id": "nope"}]}))
	assert_is_error(unknown, "INVALID_PARAMS")
	assert_contains(unknown.error.message, "nope")
	var none := _hideout.hideout_scaffold(_hideout_params(""))
	if str(ProjectSettings.get_setting("game/hideout/raid_scene", "")).is_empty():
		assert_is_error(none, "INVALID_PARAMS", "no raid scene to find")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout.tscn"), "errors write nothing")
	assert_false(ProjectSettings.has_setting("game/hideout/raid_scene"))


func test_hideout_map_scaffold_builds_room_and_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var key := "autoload/" + HideoutTools.AUTOLOAD_NAME
	var autoload_before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var main_before := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var menu_path := WORK_DIR + "/hideout.tscn"
	var map_path := WORK_DIR + "/hideout_map.tscn"
	var params := _hideout_params(raid, {"style": "map", "map_scene": map_path, "map_size": [16, 12], "deploy_time": 2.0, "interact_action": ACTION_PREFIX + "interact"})

	var dry := _hideout.hideout_scaffold(params.merged({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.would.map_scene, "create")
	assert_eq(dry.data.map.room, [16.0, 12.0])
	assert_false(FileAccess.file_exists(map_path), "dry run writes nothing")

	var result := _hideout.hideout_scaffold(params)
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.map.status, "created")
	assert_eq(result.data.hideout_scene_status, "created")
	assert_true(FileAccess.file_exists(map_path))
	for f in ["hideout_map.gd", "hideout_door.gd", "hideout_locker.gd", "topdown_camera_rig.gd"]:
		assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/" + f), f)
	assert_true(InputMap.has_action(ACTION_PREFIX + "interact"), "interact action created")
	assert_eq(ProjectSettings.get_setting("game/hideout/hideout_scene"), map_path, "raids come home to the map")
	assert_eq(ProjectSettings.get_setting("game/hideout/menu_scene"), menu_path)
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), map_path)

	var map := (ResourceLoader.load(map_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq((map.get_script() as Script).resource_path.get_file(), "hideout_map.gd")
	assert_eq(map.get("interact_action"), StringName(ACTION_PREFIX + "interact"))
	for path in ["Player", "TopdownCamera/Camera3D", "StashLocker/Label", "DeployDoor/Shape", "Room/Floor", "Room/WallFarLeft", "PlayerSpawn", "StashScreen/Hideout/Stash", "StashScreen/Hideout/Loadout"]:
		assert_true(map.get_node_or_null(path) != null, "map has " + path)
	assert_eq(map.get_node("StashScreen/Hideout").scene_file_path, menu_path, "stash screen is the menu hideout")
	assert_false(map.get_node("StashScreen").visible, "stash screen starts hidden")
	assert_eq(map.get_node("DeployDoor").get("deploy_time"), 2.0)
	assert_eq(map.get_node("TopdownCamera").get("target_path"), NodePath("../Player"))
	assert_true(map.get_node("Player").get_script() != null, "player has a controller")
	## The room is 16 x 12: the door pad sits inside, at the far wall.
	assert_true(absf(map.get_node("DeployDoor").position.z - (-6.0 + 1.2)) < 0.01)
	map.free()

	var again := _hideout.hideout_scaffold(params)
	assert_eq(again.data.map.status, "kept")
	assert_true(again.data.warnings.any(func(w): return String(w).contains("hideout_map.tscn exists")), "says the map was kept")

	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the rerun")
	assert_true(FileAccess.file_exists(map_path), "the rerun did not write the map")
	assert_true(global_ur.undo(), "undo the scaffold")
	assert_false(FileAccess.file_exists(map_path), "map file removed")
	assert_false(FileAccess.file_exists(menu_path), "menu scene removed")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before, "autoload removed")
	assert_eq(str(ProjectSettings.get_setting("application/run/main_scene", "")), main_before, "main scene restored")
	assert_false(ProjectSettings.has_setting("game/hideout/hideout_scene"))


func test_hideout_map_rejects_bad_params() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var base := {"style": "map", "map_scene": WORK_DIR + "/hideout_map.tscn"}
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"style": "3d"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_size": [4, 4]}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_size": "big"}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_scene": raid}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"player_scene": WORK_DIR + "/nope.tscn"}, true))), "NODE_NOT_FOUND")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"interact_action": "bad action"}, true))), "INVALID_PARAMS")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout_map.tscn"), "errors write nothing")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout.tscn"))


func test_hideout_map_locker_door_and_disarm() -> void:
	var db := _hideout_db()
	var inv_script := _tool_copy(_install_template("inventory"))
	_install_template("player_controller")
	var map := Node3D.new()
	map.name = "HideoutMapTest"
	map.set_script(_tool_copy(_install_template("hideout_map")))
	map.set("interact_action", StringName(ACTION_PREFIX + "interact"))
	var screen := CanvasLayer.new()
	screen.name = "StashScreen"
	map.add_child(screen)
	var ui := Control.new()
	ui.name = "Hideout"
	ui.set_script(_tool_copy(_install_template("hideout")))
	ui.set("raid_scene", "res://zz_mcp_test_topdown/nope.tscn")
	for spec in [["Stash", 6, 4, 0.0], ["Loadout", 3, 3, 0.0]]:
		var inv := Node.new()
		inv.name = spec[0]
		inv.set_script(inv_script)
		inv.set("grid_width", spec[1])
		inv.set("grid_height", spec[2])
		inv.set("max_weight", spec[3])
		inv.set("item_database", db)
		ui.add_child(inv)
	screen.add_child(ui)
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(_tool_copy(WORK_DIR + "/scripts/player_controller.gd"))
	var aim := Node3D.new()
	aim.name = "Aim"
	player.add_child(aim)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	aim.add_child(mount)
	var gun_script := GDScript.new()
	gun_script.source_code = "@tool\nextends Node3D\nfunc try_fire(_at: Vector3) -> bool:\n\treturn true\n"
	assert_eq(gun_script.reload(), OK)
	var gun := Node3D.new()
	gun.name = "Gun"
	gun.set_script(gun_script)
	mount.add_child(gun)
	map.add_child(player)
	var locker := StaticBody3D.new()
	locker.name = "StashLocker"
	locker.set_script(_tool_copy(_install_template("hideout_locker")))
	locker.position = Vector3(-5, 0, 0)
	map.add_child(locker)
	var door := Area3D.new()
	door.name = "DeployDoor"
	door.set_script(_tool_copy(_install_template("hideout_door")))
	door.position = Vector3(0, 0, -5)
	map.add_child(door)
	_root().add_child(map)
	_added.append(map)

	assert_true(map.is_hideout())
	assert_eq(map.get("player"), player)
	assert_eq(map.get("ui"), ui)
	assert_false(screen.visible, "stash screen starts hidden")
	assert_true(gun.is_queued_for_deletion() or gun.get_parent() == null, "no guns at home")
	var deploy_button: Button = ui.get("_deploy_button")
	assert_false(deploy_button.visible, "the menu's deploy button gives way to the door")
	assert_true(ui.find_child("CloseButton", true, false) is Button, "close button instead")
	assert_eq(map.get_stash(), ui.get("stash"))

	player.global_position = Vector3(0, 0, 3)
	assert_true(map.nearest_locker() == null, "locker out of reach")
	player.global_position = Vector3(-3.5, 0, 0.5)
	assert_eq(map.nearest_locker(), locker, "locker in reach")
	map.open_stash()
	assert_true(screen.visible)
	assert_true(map.is_stash_open)
	assert_false(player.is_physics_processing(), "player frozen while the stash is open")
	map.close_stash()
	assert_false(screen.visible)
	assert_true(player.is_physics_processing())

	ui.get("stash").add_item("bandage", 2)
	map._refresh_info()
	assert_contains(map.get("_info").text, "창고 ₩100")

	assert_eq(door.get_map(), map)
	assert_eq(door.time_left(), -1.0, "nobody on the pad")
	assert_eq(door.deploy(player), ERR_FILE_NOT_FOUND, "missing raid scene")
	assert_false(door.is_done, "the door stays usable after a failed deploy")
	assert_false(map.is_deploying)
	assert_eq(map.key_label(&"mcp_test_td_nope"), "mcp_test_td_nope")


func test_playtest_hideout_issues() -> void:
	var agent := _agent()
	var base := {"result": "extracted", "game_time": 30.0, "combat": {"weapon": "Rifle"}, "navigation": {"nav_ready": true}}
	var good := base.duplicate(true)
	good["hideout"] = {"linked": true, "raid_result": "extracted", "returned": true, "missing": {}, "unexpected": {}, "save_matches": true, "redeploy": {"ok": true}}
	assert_eq(agent.find_issues(good, {}), [])
	var not_linked := base.duplicate(true)
	not_linked["hideout"] = {"linked": false}
	assert_eq(agent.find_issues(not_linked, {}), [], "no hideout, no hideout issues")
	var lost := base.duplicate(true)
	lost["hideout"] = {"linked": true, "raid_result": "extracted", "returned": false, "error": "timeout while returning"}
	assert_contains(str(agent.find_issues(lost, {})), "은신처로 돌아가지 못함")
	var bad := base.duplicate(true)
	bad["hideout"] = {"linked": true, "raid_result": "extracted", "returned": true, "missing": {"watch": 1}, "unexpected": {}, "save_matches": false, "redeploy": {"ok": false, "expected_bag": {"a": 1}, "bag": {}}}
	var issues := str(agent.find_issues(bad, {}))
	assert_contains(issues, "watch x1")
	assert_contains(issues, "세이브")
	assert_contains(issues, "다시 출격")
	var summary: Dictionary = PlaytestTools.summarize({"result": "extracted", "issues": [], "hideout": good.hideout})
	assert_contains(str(summary.get("hideout", "")), "redeploy ok")
# --- playtest notes ------------------------------------------------------------------

func _notes_dir() -> String:
	return WORK_DIR + "/notes/"


## Writes a note file the way the in-game overlay does.
func _write_note(id: String, extra: Dictionary = {}) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_notes_dir()))
	var note := {
		"id": id, "status": "open", "text": "wall %s has a gap" % id, "category": "bug",
		"scene": "res://scenes/raid.tscn", "position": [1.0, 0.0, -2.0],
		"created": "2026-11-20T20:00:00", "created_unix": 1000.0 + float(id.hash() % 100),
		"screenshot": _notes_dir() + id + ".png",
	}
	note.merge(extra, true)
	var f := FileAccess.open(_notes_dir() + id + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(note))
	f.close()
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.save_png(_notes_dir() + id + ".png")
	return note


func _clear_notes() -> void:
	_remove_tree(ProjectSettings.globalize_path(_notes_dir()))


func _overlay() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("playtest_notes_overlay"))


func _global_undo() -> UndoRedo:
	return EditorInterface.get_editor_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func test_notes_list_filters_and_hints() -> void:
	_clear_notes()
	var empty: Dictionary = _notes.playtest_notes({})
	assert_eq(empty.data.count, 0)
	_write_note("n-a", {"created_unix": 10.0})
	_write_note("n-b", {"created_unix": 20.0, "category": "idea", "scene": "res://scenes/other.tscn"})
	_write_note("n-c", {"created_unix": 30.0, "status": "resolved"})
	var f := FileAccess.open(_notes_dir() + "broken.json", FileAccess.WRITE)
	f.store_string("{nope")
	f.close()
	var out: Dictionary = _notes.playtest_notes({"op": "list"}).data
	assert_eq(out.count, 2, "open only by default")
	assert_eq(out.notes[0].id, "n-a", "oldest first")
	assert_eq(out.open_total, 2)
	assert_eq(out.resolved_total, 1)
	assert_eq(out.broken_files.size(), 1)
	assert_true(String(out.notes[0].screenshot_path).ends_with("n-a.png"))
	assert_eq(_notes.playtest_notes({"status": "all"}).data.count, 3)
	assert_eq(_notes.playtest_notes({"status": "resolved"}).data.notes[0].id, "n-c")
	assert_eq(_notes.playtest_notes({"category": "idea"}).data.notes[0].id, "n-b")
	assert_eq(_notes.playtest_notes({"scene": "res://scenes/raid.tscn", "status": "all"}).data.count, 2)
	var limited: Dictionary = _notes.playtest_notes({"status": "all", "limit": 1}).data
	assert_eq(limited.shown, 1)
	assert_eq(limited.notes[0].id, "n-c", "limit keeps the newest")
	_clear_notes()


func test_notes_categories_default_and_project_setting() -> void:
	var script := _overlay()
	var key := NotesTools.CATEGORIES_SETTING
	var had := ProjectSettings.has_setting(key)
	var previous: Variant = ProjectSettings.get_setting(key) if had else null
	ProjectSettings.set_setting(key, null)
	var ids: Array = NotesTools.category_ids()
	assert_eq(ids.size(), 12)
	for id in ["bug", "balance", "level", "graphics", "art_style", "ui", "character", "vfx", "sound", "experience", "idea", "other"]:
		assert_true(ids.has(id), "default category %s" % id)
	assert_eq(script.DEFAULT_CATEGORIES, NotesTools.DEFAULT_CATEGORIES, "game and editor defaults match")
	var labels: Array = []
	for c in script.categories():
		labels.append(c.label)
	assert_true(labels.has("스타일(아트 컨셉)"))
	assert_true(labels.has("게임 경험"))
	assert_eq(NotesTools.category_color("bug"), Color(0.95, 0.25, 0.2))
	assert_eq(NotesTools.category_color("no_such"), NotesTools.FALLBACK_COLOR, "old or removed ids still get a pin")
	ProjectSettings.set_setting(key, [
		{"id": "camera", "label": "카메라", "color": "#ff0000"},
		{"id": "camera", "label": "dup"},
		{"label": "no id"},
		"not a dict",
		{"id": "pace", "color": Color.BLUE},
	])
	var custom: Array = script.categories()
	assert_eq(custom.size(), 2, "bad and repeated entries skipped")
	assert_eq(custom[0].label, "카메라")
	assert_eq(custom[0].color, Color(1, 0, 0))
	assert_eq(custom[1].label, "pace", "label falls back to the id")
	assert_eq(NotesTools.category_color("pace"), Color.BLUE)
	assert_eq(NotesTools.category_color("bug"), NotesTools.FALLBACK_COLOR)
	_clear_notes()
	assert_eq(_notes.playtest_notes({}).data.categories, ["camera", "pace"], "list reports the ids in use")
	ProjectSettings.set_setting(key, [{"label": "only junk"}])
	assert_eq(script.categories().size(), 12, "no valid entry: defaults")
	ProjectSettings.set_setting(key, previous)


func test_notes_rejects_bad_calls() -> void:
	assert_is_error(_notes.playtest_notes({"op": "dance"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "list", "id": "x"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"status": "maybe"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"scene": "scenes/a.tscn"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get", "id": "../../project"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get", "id": "missing-1"}), "NODE_NOT_FOUND")
	assert_is_error(_notes.playtest_notes({"op": "resolve", "ids": "a"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "install", "script_dir": "res://addons/x"}), "INVALID_PARAMS")


func test_notes_get_returns_full_note_and_screenshot() -> void:
	_clear_notes()
	_write_note("g-1", {"recent_errors": [{"kind": "error", "message": "boom"}], "cursor_node": "/Raid/Wall3"})
	var out: Dictionary = _notes.playtest_notes({"op": "get", "id": "g-1"}).data
	assert_eq(out.text, "wall g-1 has a gap")
	assert_eq(out.recent_errors[0].message, "boom")
	assert_true(out.screenshot_exists)
	assert_true(String(out.screenshot_path).begins_with("/") or String(out.screenshot_path).contains(":"), "absolute path")
	assert_true(String(out.note_path).ends_with("g-1.json"))
	_clear_notes()


func test_notes_resolve_reopen_with_undo() -> void:
	_clear_notes()
	_write_note("r-1")
	_write_note("r-2")
	var before := FileAccess.get_file_as_string(_notes_dir() + "r-1.json")
	var out: Dictionary = _notes.playtest_notes({"op": "resolve", "ids": ["r-1", "r-2"], "resolution": "closed the gap"}).data
	assert_eq(out.changed, ["r-1", "r-2"])
	var note: Dictionary = _notes.read_note("r-1")
	assert_eq(note.status, "resolved")
	assert_eq(note.resolution, "closed the gap")
	assert_true(note.has("resolved"))
	assert_eq(_notes.playtest_notes({}).data.count, 0)
	_global_undo().undo()
	assert_eq(FileAccess.get_file_as_string(_notes_dir() + "r-1.json"), before, "undo restores the file byte for byte")
	_global_undo().redo()
	assert_eq(_notes.read_note("r-2").status, "resolved", "redo")
	var again: Dictionary = _notes.playtest_notes({"op": "resolve", "id": "r-1"}).data
	assert_eq(again.changed, [], "already resolved")
	var reopened: Dictionary = _notes.playtest_notes({"op": "reopen", "id": "r-1"}).data
	assert_eq(reopened.changed, ["r-1"])
	assert_eq(_notes.read_note("r-1").status, "open")
	assert_false(_notes.read_note("r-1").has("resolved"))
	## A missing id fails before anything is written.
	assert_is_error(_notes.playtest_notes({"op": "resolve", "ids": ["r-2", "nope-9"]}), "NODE_NOT_FOUND")
	_clear_notes()


func test_notes_delete_with_undo() -> void:
	_clear_notes()
	_write_note("d-1")
	var out: Dictionary = _notes.playtest_notes({"op": "delete", "id": "d-1"}).data
	assert_eq(out.files.size(), 2, "json + png")
	assert_false(FileAccess.file_exists(_notes_dir() + "d-1.json"))
	assert_false(FileAccess.file_exists(_notes_dir() + "d-1.png"))
	_global_undo().undo()
	assert_true(FileAccess.file_exists(_notes_dir() + "d-1.json"), "undo brings the note back")
	assert_true(FileAccess.file_exists(_notes_dir() + "d-1.png"), "and its screenshot")
	_clear_notes()


func test_notes_markers_are_view_only() -> void:
	var root := _root()
	if not root is Node3D:
		skip("needs a 3D scene")
		return
	_clear_notes()
	var scene := root.scene_file_path
	_write_note("m-1", {"scene": scene, "position": [2.0, 0.0, 3.0]})
	_write_note("m-2", {"scene": scene, "status": "resolved"})
	_write_note("m-3", {"scene": "res://elsewhere.tscn"})
	var out: Dictionary = _notes.playtest_notes({"op": "markers"}).data
	assert_eq(out.count, 1, "open notes of the open scene")
	var holder := root.get_node_or_null(NotesTools.MARKERS_NAME)
	if holder == null:
		for child in root.get_children(true):
			if child.name == NotesTools.MARKERS_NAME:
				holder = child
	assert_true(holder != null, "pins added")
	assert_eq(holder.owner, null, "never saved")
	assert_eq(holder.get_child(0).position, Vector3(2, 0, 3))
	assert_eq(holder.get_child(0).get_meta(&"playtest_note_id"), "m-1")
	assert_false(out.undoable)
	## Resolving redraws the pins with the same filter.
	_notes.playtest_notes({"op": "resolve", "id": "m-1"})
	var count := 0
	for child in root.get_children(true):
		if child.name == NotesTools.MARKERS_NAME:
			count += 1
	assert_eq(count, 0, "no open notes left, so no pins")
	assert_eq(_notes.playtest_notes({"op": "markers", "status": "all"}).data.count, 2)
	assert_true(_notes.playtest_notes({"op": "clear_markers"}).data.removed)
	for child in root.get_children(true):
		assert_true(child.name != NotesTools.MARKERS_NAME, "cleared")
	_clear_notes()


func test_notes_install_registers_autoload_with_undo() -> void:
	var key := NotesTools.autoload_key()
	var before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var dir := WORK_DIR + "/notes_script"
	var out: Dictionary = _notes.playtest_notes({"op": "install", "script_dir": dir})
	assert_eq(out.data.script, dir + "/playtest_notes_overlay.gd")
	assert_eq(out.data.script_status, "created")
	assert_eq(ProjectSettings.get_setting(key), "*" + dir + "/playtest_notes_overlay.gd")
	assert_eq(_notes.playtest_notes({"op": "install", "script_dir": dir}).data.autoload_status, "kept")
	_global_undo().undo()
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, before, "undo restores the autoload")
	_notes.playtest_notes({"op": "install", "script_dir": dir})
	assert_true(_notes.playtest_notes({"op": "uninstall"}).data.removed)
	assert_false(ProjectSettings.has_setting(key))
	if before != null:
		ProjectSettings.set_setting(key, before)
		ProjectSettings.save()


func test_notes_overlay_note_key() -> void:
	var overlay := _overlay()
	var f8 := InputEventKey.new()
	f8.physical_keycode = KEY_F8
	f8.pressed = true
	if InputMap.has_action(&"playtest_note"):
		skip("project defines its own playtest_note action")
		return
	assert_true(overlay.is_note_key(f8), "F8")
	var f9 := f8.duplicate()
	f9.physical_keycode = KEY_F9
	assert_true(overlay.is_note_key(f9), "F9 (Windows editor eats F8)")
	var echo := f8.duplicate()
	echo.echo = true
	assert_false(overlay.is_note_key(echo), "no key repeat")
	var ctrl_n := InputEventKey.new()
	ctrl_n.physical_keycode = KEY_N
	ctrl_n.ctrl_pressed = true
	ctrl_n.pressed = true
	assert_true(overlay.is_note_key(ctrl_n), "Ctrl+N")
	var cmd_n := ctrl_n.duplicate()
	cmd_n.ctrl_pressed = false
	cmd_n.meta_pressed = true
	assert_true(overlay.is_note_key(cmd_n), "Cmd+N")
	var n := InputEventKey.new()
	n.physical_keycode = KEY_N
	n.pressed = true
	assert_false(overlay.is_note_key(n), "plain N is a game key")
	var id: String = overlay.new_id()
	assert_true(NotesTools.valid_id(id), "id %s is file safe" % id)


func test_notes_overlay_saves_note_the_tool_reads() -> void:
	_clear_notes()
	var script := _overlay()
	var overlay: Node = script.new()
	overlay.notes_folder = _notes_dir()
	overlay.set("_context", {
		"scene": "res://scenes/raid.tscn", "scene_name": "Raid",
		"cursor_position": [4.0, 0.0, 1.0], "player_position": [0.0, 0.0, 0.0],
		"cursor_node": "/Raid/Crate2", "fps": 60.0,
	})
	var shot := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	shot.fill(Color.BLACK)
	overlay.set("_shot", shot)
	var note: Dictionary = overlay.save_note("  crate floats  ", "bug", false)
	assert_false(note.has("error"), str(note))
	assert_eq(note.text, "crate floats")
	assert_eq(note.position, [4.0, 0.0, 1.0], "mouse spot by default")
	assert_eq(note.position_source, "cursor")
	assert_true(FileAccess.file_exists(_notes_dir() + ".gdignore"), "editor skips the folder")
	assert_true(FileAccess.file_exists(note.screenshot))
	var by_player: Dictionary = overlay.save_note("here", "idea", true)
	assert_eq(by_player.position, [0.0, 0.0, 0.0])
	assert_eq(by_player.position_source, "player")
	var listed: Dictionary = _notes.playtest_notes({"status": "all"}).data
	assert_eq(listed.count, 2, "the tool reads what the game wrote")
	var got: Dictionary = _notes.playtest_notes({"op": "get", "id": note.id}).data
	assert_eq(got.cursor_node, "/Raid/Crate2")
	assert_true(got.screenshot_exists)
	overlay.free()
	_clear_notes()


func test_notes_overlay_pin_and_ring() -> void:
	var script := _overlay()
	var pin: Node3D = script.make_pin(Vector3(1, 2, 3), Color.RED, "label")
	assert_eq(pin.position, Vector3(1, 2, 3))
	assert_eq(pin.get_child_count(), 4, "stick, head, ring, label")
	pin.free()
	var img := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	script.call("_ring", img, Vector2(20, 20), 10.0, 2.0, Color.RED)
	assert_eq(img.get_pixel(30, 20), Color.RED, "ring drawn")
	assert_eq(img.get_pixel(20, 20), Color.BLACK, "center left clear")
	var tool_pin := NotesTools.make_pin(Vector3.ZERO, Color.RED, "x")
	assert_eq(tool_pin.get_child_count(), 4, "editor pins match the game's")
	tool_pin.free()


# --- combat feedback -----------------------------------------------------------

func _feedback_params(extra: Dictionary = {}) -> Dictionary:
	var params := {"script_dir": WORK_DIR + "/scripts", "name": "TestCombatFeedback"}
	params.merge(extra, true)
	return params


func test_combat_feedback_setup_adds_node_with_undo() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	var result := _feedback.combat_feedback_setup(_feedback_params({"shell_casings": false, "shake_strength": 0.5}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.mode, "created")
	var node := _track(result.data.node_path)
	assert_true(node != null, "node added")
	assert_eq((node.get_script() as Script).resource_path, WORK_DIR + "/scripts/combat_feedback.gd")
	assert_eq(node.get("shell_casings"), false, "switch applied")
	assert_eq(node.get("shake_strength"), 0.5, "tuning applied")
	assert_eq(result.data.effects.shell_casings, false)
	assert_eq(result.data.effects.muzzle_flash, true, "untouched switches keep the script default")
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/combat_feedback.gd"))
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).undo()
	assert_true(McpScenePath.resolve(result.data.node_path, _root()) == null, "undo removes the node")
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).redo()
	assert_true(McpScenePath.resolve(result.data.node_path, _root()) != null, "redo adds it back")


func test_combat_feedback_rerun_retunes_existing_node() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	var first := _feedback.combat_feedback_setup(_feedback_params())
	assert_has_key(first, "data", str(first))
	var node := _track(first.data.node_path)
	var second := _feedback.combat_feedback_setup(_feedback_params({"screen_shake": false, "hitmarker_size": 20}))
	assert_has_key(second, "data", str(second))
	assert_eq(second.data.mode, "updated")
	assert_eq(second.data.node_path, first.data.node_path, "no second node")
	assert_eq(node.get("screen_shake"), false)
	assert_eq(node.get("hitmarker_size"), 20.0)
	assert_has_key(second.data.changed, "screen_shake")
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).undo()
	assert_eq(node.get("screen_shake"), true, "undo restores the old settings")


func test_combat_feedback_rejects_bad_params() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	for bad in [{"shake_strength": 9}, {"hitmarker": "yes"}, {"damage_number_font_size": 1.5}, {"name": "a/b"}, {"parent_path": "Nope/Missing"}, {"flesh_color": "not a color"}]:
		var result := _feedback.combat_feedback_setup(_feedback_params(bad))
		assert_eq(result.get("status"), "error", "rejects %s" % bad)


func _health_body_script(base: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\nextends " + base + "\nsignal health_changed(current: float, maximum: float)\nvar health := 30.0\nvar max_health := 30.0\nfunc take_damage(amount: float, _info: Dictionary = {}) -> void:\n\thealth = maxf(health - amount, 0.0)\n\thealth_changed.emit(health, max_health)\n"
	assert_eq(script.reload(), OK)
	return script


func test_combat_feedback_reacts_to_shots_hits_kills_and_hurt() -> void:
	var weapon_result := _tools.weapon_create(_weapon_params("test_fx_gun", {"damage": 20, "spread_degrees": 0, "fire_rate": 100}))
	assert_has_key(weapon_result, "data", str(weapon_result))
	var setup := _feedback.combat_feedback_setup(_feedback_params({"name": "FxProbe"}))
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	assert_has_key(setup, "data", str(setup))
	_track(setup.data.node_path)

	var arena := Node3D.new()
	arena.name = "FxArena"
	_root().add_child(arena)
	_added.append(arena)
	arena.global_position = Vector3(0, 700, 0)
	var camera := Camera3D.new()
	camera.name = "Cam"
	arena.add_child(camera)
	## The shooter: a body in the player group, hurt by take_damage.
	var player := StaticBody3D.new()
	player.name = "FxPlayer"
	player.set_script(_health_body_script("StaticBody3D"))
	player.add_to_group(&"player")
	arena.add_child(player)
	var weapon := Node3D.new()
	weapon.name = "Gun"
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	weapon.add_child(muzzle)
	weapon.set_script(_tool_copy(weapon_result.data.scripts.weapon.path))
	weapon.set("data", ResourceLoader.load(weapon_result.data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE))
	player.add_child(weapon)
	weapon.set_physics_process(false)
	var target := StaticBody3D.new()
	target.name = "FxTarget"
	target.set_script(_health_body_script("StaticBody3D"))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 1)
	shape.shape = box
	target.add_child(shape)
	arena.add_child(target)
	target.position = Vector3(0, 0, -5)
	PhysicsServer3D.body_set_state(target.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target.global_transform)

	var fx := Node.new()
	fx.name = "Fx"
	fx.set_script(_tool_copy(WORK_DIR + "/scripts/combat_feedback.gd"))
	fx.set("camera_path", NodePath("../Cam"))
	arena.add_child(fx)

	assert_true(weapon.try_fire(target.global_position), "shot 1")
	var stats: Dictionary = fx.get("stats")
	assert_eq(stats.shots, 1)
	assert_eq(stats.hits, 1, "hit on a damageable body")
	assert_eq(stats.kills, 0)
	var flash := muzzle.get_node_or_null("MuzzleFlash") as Node3D
	assert_true(flash != null and flash.visible, "muzzle flash shown at the muzzle")
	var effects: Node = fx.get_node("Effects")
	var labels := effects.get_children().filter(func(n: Node) -> bool: return n is Label3D)
	assert_eq(labels.size(), 1, "one damage number")
	assert_eq(labels[0].text, "20")
	assert_true(effects.get_children().any(func(n: Node) -> bool: return n is CPUParticles3D), "hit particles")
	assert_true(effects.get_children().any(func(n: Node) -> bool: return n is MeshInstance3D), "shell casing")
	assert_eq(fx.get("_markers").size(), 1, "hitmarker")

	weapon.set("_cooldown", 0.0)
	assert_true(weapon.try_fire(target.global_position), "shot 2")
	assert_eq(stats.kills, 1, "second hit kills (10 hp left)")
	labels = effects.get_children().filter(func(n: Node) -> bool: return n is Label3D)
	assert_eq(labels.size(), 1, "quick hits merge into one number")
	assert_eq(labels[0].text, "30", "merged total counts only the health actually lost")
	assert_eq(labels[0].modulate.r, (fx.get("kill_number_color") as Color).r, "kill color")
	assert_true(fx.get("_markers").back().kill, "kill marker")

	weapon.set("_cooldown", 0.0)
	weapon.try_fire(target.global_position)
	assert_eq(stats.hits, 2, "no hit counted on a dead body")

	player.take_damage(15.0)
	assert_eq(stats.hurts, 1, "player hurt")
	assert_true(float(fx.get("_vignette_alpha")) > 0.0, "vignette")
	assert_true(float(fx.get("_trauma")) > 0.0, "screen shake")
	fx.call("_update_shake", 0.016)
	assert_true(absf(camera.h_offset) + absf(camera.v_offset) > 0.0, "camera shakes")

	fx.set("enabled", false)
	weapon.set("_cooldown", 0.0)
	weapon.try_fire(target.global_position + Vector3(3, 0, 0))
	assert_eq(stats.shots, 3, "master switch off: nothing reacts")



# --- asset pipeline ------------------------------------------------------------

## A folder the editor already knows, so imports run synchronously in tests
## (a brand-new folder needs the deferred tool's scan_sources wait).
const ASSET_KNOWN_DIR := "res://tests"
const ASSET_PREFIX := "zz_mcp_test_asset_"
const MODEL_DIR := WORK_DIR + "/models"


func _remove_asset_test_files() -> void:
	var dir := DirAccess.open(ASSET_KNOWN_DIR)
	if dir != null:
		for file in dir.get_files():
			if file.begins_with(ASSET_PREFIX):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(ASSET_KNOWN_DIR.path_join(file)))
	var sources := ProjectSettings.globalize_path(AssetTools.SOURCES_ROOT)
	var sdir := DirAccess.open(sources)
	if sdir == null:
		return
	for sub in sdir.get_directories():
		if sub.begins_with(ASSET_PREFIX):
			_remove_tree(sources.path_join(sub))
	if DirAccess.get_directories_at(sources).is_empty():
		## .gdignore is hidden, so _remove_tree's listing skips it.
		DirAccess.remove_absolute(sources.path_join(".gdignore"))
		_remove_tree(sources)


## A box model (optionally with a thin barrel and a Muzzle marker) as a
## node tree; free it or pass it to _save_model / _export_glb.
func _box_model(size: Vector3, center: Vector3, barrel: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "TestModel"
	var mesh := MeshInstance3D.new()
	mesh.name = "Body"
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = center
	root.add_child(mesh)
	if barrel:
		var b := MeshInstance3D.new()
		b.name = "Barrel"
		var bm := BoxMesh.new()
		bm.size = Vector3(0.04, 0.04, 0.4)
		b.mesh = bm
		b.position = center + Vector3(0, 0.03, size.z / 2.0 + 0.2)
		root.add_child(b)
		var grip := MeshInstance3D.new()
		grip.name = "Grip"
		var gm := BoxMesh.new()
		gm.size = Vector3(0.06, 0.16, 0.08)
		grip.mesh = gm
		grip.position = center + Vector3(0, -size.y / 2.0 - 0.08, -size.z * 0.25)
		root.add_child(grip)
	Util_own(root)
	return root


static func Util_own(root: Node) -> void:
	for child in root.get_children():
		child.owner = root


func _save_model(root: Node3D, path: String, muzzle_at: Variant = null) -> String:
	if muzzle_at != null:
		var m := Marker3D.new()
		m.name = "Muzzle"
		m.position = muzzle_at
		root.add_child(m)
		m.owner = root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	assert_eq(ResourceSaver.save(packed, path), OK, "save model %s" % path)
	return path


func _export_glb(root: Node3D, abs_path: String) -> String:
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	assert_eq(doc.append_from_scene(root, state), OK, "gltf append")
	assert_eq(doc.write_to_filesystem(state, abs_path), OK, "gltf write")
	root.free()
	return abs_path


func test_asset_params_rejected() -> void:
	assert_is_error(_assets.asset_import({"kind": "prop", "asset_id": "crate"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.glb", "kind": "gun", "asset_id": "crate"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.glb", "kind": "prop", "asset_id": "Big Crate"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.png", "kind": "prop", "asset_id": "crate"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.glb", "kind": "prop", "asset_id": "crate"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.glb", "kind": "prop", "asset_id": "crate", "dest_dir": "res://addons/x"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"source": "/nope/x.glb", "kind": "prop", "asset_id": "crate", "colour": 1}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_cleanup({"source": "/nope/x.glb", "kind": "weapon", "asset_id": "smg"}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_cleanup({"source": "/nope/x.glb", "kind": "weapon", "asset_id": "smg", "forward": "north"}), "INVALID_PARAMS")
	assert_true(AssetTools.is_asset_id("gold_watch_2"))
	assert_false(AssetTools.is_asset_id("_x"))
	assert_eq(AssetTools.default_dest_dir("weapon", "smg"), "res://assets/weapons/smg")
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	assert_eq(AssetTools.resolve_source("~/Downloads/a.glb"), home.path_join("Downloads/a.glb").replace("\\", "/"), "~ expands; Windows separators become /")


func test_asset_import_copies_imports_and_reports() -> void:
	var src := _export_glb(_box_model(Vector3(1.0, 0.6, 0.8), Vector3(0, 0.3, 0)), ProjectSettings.globalize_path(WORK_DIR + "/src/crate.glb"))
	var id := ASSET_PREFIX + "crate"
	var params := {"source": src, "kind": "prop", "asset_id": id, "dest_dir": ASSET_KNOWN_DIR, "preview": false, "generate_lods": false}
	var dry := _assets.asset_import(params.merged({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_false(FileAccess.file_exists(ASSET_KNOWN_DIR + "/%s.glb" % id), "dry run writes nothing")

	var result := _assets.asset_import(params)
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	var dest := ASSET_KNOWN_DIR + "/%s.glb" % id
	assert_eq(data.path, dest)
	assert_false(data.get("import_pending", false), "known folder imports at once")
	assert_false(data.has("error"), str(data))
	assert_true(FileAccess.file_exists(src), "source untouched")
	assert_true(ResourceLoader.exists(dest), "imported")
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(dest + ".import"), OK)
	assert_eq(cfg.get_value("params", "meshes/generate_lods"), false, "our import settings")
	assert_true(String(cfg.get_value("remap", "path", "")).begins_with("res://.godot/imported/"), "editor wrote the import result")
	assert_eq(data.triangles, 12)
	assert_true(absf(data.size[0] - 1.0) < 0.01 and absf(data.size[1] - 0.6) < 0.01 and absf(data.size[2] - 0.8) < 0.01, "size %s" % str(data.size))
	assert_eq(data.warnings, [], "bottom-centered 1 m box is fine: %s" % str(data.warnings))
	assert_true(FileAccess.file_exists(AssetTools.work_dir(id) + "/asset.json"), "history record")
	assert_true(FileAccess.file_exists(AssetTools.SOURCES_ROOT + "/.gdignore"), "work files hidden from the editor")

	assert_is_error(_assets.asset_import(params), "ALREADY_EXISTS")
	var again := _assets.asset_import(params.merged({"overwrite": true}))
	assert_has_key(again, "data", str(again))
	assert_eq(again.data.get("triangles"), 12, "overwrite in a known, idle folder reimports at once: %s" % str(again.data))

	var inspected := _assets.asset_import({"kind": "prop", "asset_id": id, "dest_dir": ASSET_KNOWN_DIR, "inspect_only": true, "preview": false})
	assert_has_key(inspected, "data", str(inspected))
	assert_eq(inspected.data.get("triangles"), 12, "inspect_only reports without copying")
	assert_eq(inspected.data.path, dest)
	var record: Variant = AssetTools.read_json(AssetTools.work_dir(id) + "/asset.json")
	assert_true(record.history.any(func(e): return e.step == "report" and e.triangles == 12), "report summary kept in asset.json")
	assert_is_error(_assets.asset_import({"kind": "prop", "asset_id": id + "_none", "dest_dir": ASSET_KNOWN_DIR, "inspect_only": true}), "INVALID_PARAMS")
	assert_is_error(_assets.asset_import({"kind": "prop", "asset_id": id, "inspect_only": true, "overwrite": true}), "INVALID_PARAMS")

	assert_true(_global_ur().undo(), "undo of the overwrite runs")
	assert_true(_global_ur().undo(), "undo runs")
	assert_false(FileAccess.file_exists(dest), "undo removes the copy")


func test_asset_stale_textures_only_from_records() -> void:
	var dir := "res://assets/props/crate"
	var record := {"asset_id": "crate", "history": [
		{"step": "import", "dest": dir + "/crate.gltf", "files": [dir + "/crate.gltf", dir + "/crate.bin", dir + "/wood.jpg", dir + "/tex/metal.webp", dir + "/../x.png", "res://assets/props/other/o.png"]},
		{"step": "report", "path": dir + "/crate.gltf", "textures": [{"name": "crate_Albedo.png", "size": [4, 4]}, {"name": "Albedo", "size": [4, 4]}, {"name": "a/b.png"}]},
		{"step": "report", "path": dir + "/crate.glb", "texture_files": [dir + "/crate_0.png", dir + "/crate_0.png"]},
		{"step": "cleanup", "files": [dir + "/cleanup.png"]},
		"junk",
	]}
	var stale := AssetTools.stale_texture_files(record, dir, [dir + "/crate_0.png"])
	assert_eq(stale, [dir + "/wood.jpg", dir + "/tex/metal.webp", dir + "/crate_Albedo.png"], "recorded textures in the folder, minus the ones in use: %s" % str(stale))
	assert_eq(AssetTools.stale_texture_files(null, dir, []), [], "no record, nothing to remove")
	assert_eq(AssetTools.stale_texture_files({"history": "x"}, dir, []), [])


func test_asset_overwrite_removes_old_textures() -> void:
	var id := ASSET_PREFIX + "retex"
	var params := {"kind": "prop", "asset_id": id, "dest_dir": ASSET_KNOWN_DIR, "preview": false, "generate_lods": false}
	var first_src := _export_glb(_box_model(Vector3(1.0, 0.6, 0.8), Vector3(0, 0.3, 0)), ProjectSettings.globalize_path(WORK_DIR + "/src/retex_a.glb"))
	var first := _assets.asset_import(params.merged({"source": first_src}))
	assert_has_key(first, "data", str(first))
	assert_false(first.data.has("removed_old_textures"), "first import removes nothing")
	var record: Variant = AssetTools.read_json(AssetTools.work_dir(id) + "/asset.json")
	assert_true(record.history.any(func(e): return e.step == "import" and e.get("files") == [ASSET_KNOWN_DIR + "/%s.glb" % id]), "import records the files it wrote")

	## An earlier run's texture (as a .gltf import records it), its .import,
	## and a texture the user put there by hand.
	var old_tex := ASSET_KNOWN_DIR + "/%s_old.jpg" % id
	var mine := ASSET_KNOWN_DIR + "/%s_mine.png" % id
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color.RED)
	assert_eq(img.save_jpg(ProjectSettings.globalize_path(old_tex)), OK)
	assert_eq(img.save_png(ProjectSettings.globalize_path(mine)), OK)
	var cfg := FileAccess.open(old_tex + ".import", FileAccess.WRITE)
	cfg.store_string("[remap]\n\nimporter=\"texture\"\ntype=\"CompressedTexture2D\"\n")
	cfg.close()
	record.history.append({"step": "import", "dest": ASSET_KNOWN_DIR + "/%s.gltf" % id, "files": [ASSET_KNOWN_DIR + "/%s.gltf" % id, old_tex]})
	var f := FileAccess.open(AssetTools.work_dir(id) + "/asset.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(record))
	f.close()

	var second_src := _export_glb(_box_model(Vector3(1.0, 0.6, 0.8), Vector3(0, 0.3, 0)), ProjectSettings.globalize_path(WORK_DIR + "/src/retex_b.glb"))
	var again := _assets.asset_import(params.merged({"source": second_src, "overwrite": true}))
	assert_has_key(again, "data", str(again))
	assert_eq(again.data.get("removed_old_textures"), [old_tex], "the recorded old texture goes: %s" % str(again.data))
	assert_false(FileAccess.file_exists(old_tex), "old texture deleted")
	assert_false(FileAccess.file_exists(old_tex + ".import"), "its .import deleted")
	assert_true(FileAccess.file_exists(mine), "a file no record names stays")
	record = AssetTools.read_json(AssetTools.work_dir(id) + "/asset.json")
	assert_true(record.history.back().has("texture_files"), "report records the textures in use")

	assert_true(_global_ur().undo(), "one undo step")
	assert_true(FileAccess.file_exists(old_tex), "undo brings the old texture back")
	assert_true(FileAccess.file_exists(old_tex + ".import"), "and its .import")
	assert_true(_global_ur().redo(), "redo")
	assert_false(FileAccess.file_exists(old_tex), "redo deletes it again")
	assert_true(FileAccess.file_exists(mine), "the hand-made file still stays")
	assert_true(_global_ur().undo(), "undo the overwrite (textures and model)")
	assert_true(_global_ur().undo(), "the overwrite's copy step (already restored)")
	assert_true(_global_ur().undo(), "undo the first import")
	assert_false(FileAccess.file_exists(ASSET_KNOWN_DIR + "/%s.glb" % id), "undo removes the copy")


func test_asset_inspect_warns_over_budget_and_bad_origin() -> void:
	var path := _save_model(_box_model(Vector3(0.1, 0.12, 0.9), Vector3(0, 0, 0)), MODEL_DIR + "/sideways.tscn")
	var info := AssetTools.inspect_model(path, "item")
	assert_true(info.warnings.any(func(w): return String(w).contains("origin")), "centered item origin warned: %s" % str(info.warnings))
	var gun := AssetTools.inspect_model(_save_model(_box_model(Vector3(0.9, 0.12, 0.1), Vector3(0, 0.06, 0)), MODEL_DIR + "/gun_x.tscn"), "weapon")
	assert_true(gun.warnings.any(func(w): return String(w).contains("-Z")), "weapon along x warned: %s" % str(gun.warnings))
	assert_true(gun.warnings.any(func(w): return String(w).contains("Muzzle")), "missing Muzzle warned")


func test_fit_transforms() -> void:
	var model := AABB(Vector3(-0.5, 0, -0.25), Vector3(1, 2, 0.5))
	## height: 1.8 m tall, feet on the box bottom.
	var h: Transform3D = SwapTools.fit_transforms(model, AABB(Vector3(-0.4, 0, -0.4), Vector3(0.8, 1.8, 0.8)), "height", 0, 0, false)[0]
	assert_true(h.basis.get_scale().is_equal_approx(Vector3(0.9, 0.9, 0.9)), str(h.basis.get_scale()))
	assert_true((h * model).position.y == 0.0)
	## fit inside a 1 m cube: limited by height 2 -> 0.5.
	var f: Transform3D = SwapTools.fit_transforms(model, AABB(Vector3(4.5, 0, -0.5), Vector3(1, 1, 1)), "fit", 0, 0, false)[0]
	var fb := f * model
	assert_true(fb.size.is_equal_approx(Vector3(0.5, 1, 0.25)), str(fb.size))
	assert_true(fb.get_center().x == 5.0 and fb.position.y == 0.0)
	## fill: footprint in proportion, height to the box.
	var fl: Transform3D = SwapTools.fit_transforms(model, AABB(Vector3(4.5, 0, -0.5), Vector3(1, 1, 1)), "fill", 0, 0, false)[0]
	assert_true((fl * model).size.is_equal_approx(Vector3(1, 1, 0.5)), str((fl * model).size))
	## stretch a model long in x into a box long in z: turned 90 degrees.
	var st: Transform3D = SwapTools.fit_transforms(model, AABB(Vector3(-0.1, 0, -2), Vector3(0.2, 3, 4)), "stretch", 0, 0, false)[0]
	assert_true((st * model).size.is_equal_approx(Vector3(0.2, 3, 4)), str((st * model).size))
	## tile a 1 m module along a 4 m wall: 4 copies covering it.
	var tiles: Array = SwapTools.fit_transforms(model, AABB(Vector3(0, 0, 0), Vector3(4, 3, 0.3)), "tile", 0, 0, false)
	assert_eq(tiles.size(), 4)
	var merged: AABB = tiles[0] * model
	for t in tiles:
		merged = merged.merge(t * model)
	assert_true(merged.size.is_equal_approx(Vector3(4, 3, 0.3)), str(merged.size))
	## none + origin: model origin at the host origin.
	var n: Transform3D = SwapTools.fit_transforms(model, AABB(Vector3(0, 0, -0.6), Vector3(0.1, 0.1, 0.6)), "none", 0, 0, true)[0]
	assert_eq(n.origin, Vector3.ZERO)


func _test_map() -> Node3D:
	var map := Node3D.new()
	map.name = "SwapTestMap"
	map.set_meta(&"raid_map_seed", 1)
	_root().add_child(map)
	_added.append(map)
	map.owner = _root()
	for spec in [["Crates", "Crate1", "Body", Vector3(1.0, 0.7, 0.8), Vector3(3, 0, 0)], ["Walls", "Wall1", "Mesh", Vector3(0.3, 3, 6), Vector3(0, 1.5, 0)]]:
		var group := Node3D.new()
		group.name = spec[0]
		map.add_child(group)
		group.owner = _root()
		var body := StaticBody3D.new()
		body.name = spec[1]
		body.position = spec[4]
		group.add_child(body)
		body.owner = _root()
		var mi := MeshInstance3D.new()
		mi.name = spec[2]
		var box := BoxMesh.new()
		box.size = spec[3]
		mi.mesh = box
		if spec[2] == "Body":
			mi.position.y = spec[3].y / 2.0
		body.add_child(mi)
		mi.owner = _root()
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		var shape := BoxShape3D.new()
		shape.size = spec[3]
		cs.shape = shape
		body.add_child(cs)
		cs.owner = _root()
	return map


func test_swap_map_crates_and_walls_with_undo_and_revert() -> void:
	var map := _test_map()
	var model := _save_model(_box_model(Vector3(2, 1, 1), Vector3(0, 0.5, 0)), MODEL_DIR + "/crate_model.tscn")
	var crate := map.get_node("Crates/Crate1")
	var dry := _swap.swap_placeholder({"target": "map", "group": "Crates", "model": model, "dry_run": true})
	assert_has_key(dry, "data", str(dry))
	assert_eq(crate.get_node_or_null("BodySkin"), null, "dry run changes nothing")

	var result := _swap.swap_placeholder({"target": "map", "group": "Crates", "model": model})
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.swapped, 1)
	var skin := crate.get_node_or_null("BodySkin") as Node3D
	assert_true(skin != null, "skin added")
	assert_eq(skin.owner, _root(), "skin saved with the scene")
	assert_false((crate.get_node("Body") as Node3D).visible, "placeholder hidden")
	assert_true(crate.get_node("Shape") is CollisionShape3D, "collision kept")
	var fitted: AABB = AssetTools.measure(skin).aabb
	assert_true(fitted.size.x <= 1.001 and fitted.size.y <= 0.701 and fitted.size.z <= 0.801, "fits the crate box: %s" % str(fitted.size))
	assert_true(absf(fitted.position.y) < 0.001, "sits on the floor")

	## Rerun replaces the skin instead of stacking.
	assert_has_key(_swap.swap_placeholder({"target": "map", "group": "Crates", "model": model}), "data")
	assert_eq(crate.get_children().filter(func(n): return String(n.name).begins_with("BodySkin")).size(), 1, "one skin")

	var walls := _swap.swap_placeholder({"target": "map", "group": "Walls", "model": model})
	assert_has_key(walls, "data", str(walls))
	var wall := map.get_node("Walls/Wall1")
	var wall_skin := wall.get_node("MeshSkin") as Node3D
	assert_eq(wall_skin.get_child_count(), 3, "6 m wall tiled with 2 m modules")
	var wb: AABB = AssetTools.measure(wall_skin).aabb
	assert_true(wb.size.is_equal_approx(Vector3(0.3, 3, 6)), "tiles cover the wall: %s" % str(wb.size))

	assert_true(_scene_ur().undo(), "undo runs")
	assert_eq(wall.get_node_or_null("MeshSkin"), null, "undo removes the wall skin")
	assert_true((wall.get_node("Mesh") as Node3D).visible, "undo shows the wall again")
	assert_true(_scene_ur().redo(), "redo runs")
	assert_true(wall.get_node_or_null("MeshSkin") != null, "redo")

	var reverted := _swap.swap_placeholder({"target": "map", "group": "Crates", "revert": true})
	assert_has_key(reverted, "data", str(reverted))
	assert_eq(crate.get_node_or_null("BodySkin"), null, "revert removes the skin")
	assert_true((crate.get_node("Body") as Node3D).visible, "revert shows the placeholder")
	assert_is_error(_swap.swap_placeholder({"target": "map", "group": "Crates", "revert": true}), "NODE_NOT_FOUND")
	assert_is_error(_swap.swap_placeholder({"target": "map", "group": "Nope", "model": model}), "NODE_NOT_FOUND")
	assert_is_error(_swap.swap_placeholder({"target": "map", "model": model}), "INVALID_PARAMS")
	assert_is_error(_swap.swap_placeholder({"target": "map", "group": "Crates", "model": "res://nope.glb"}), "INVALID_PARAMS")


func test_swap_map_flat_model_warns_and_fill_matches_collision() -> void:
	var map := _test_map()
	var flat := _save_model(_box_model(Vector3(1.8, 0.3, 1.0), Vector3(0, 0.15, 0)), MODEL_DIR + "/flat_crate.tscn")
	var fit := _swap.swap_placeholder({"target": "map", "group": "Crates", "model": flat})
	assert_has_key(fit, "data", str(fit))
	assert_true(fit.data.has("warnings") and String(fit.data.warnings[0]).contains("fill"), "low crate warned: %s" % str(fit.data.get("warnings")))
	var box: Array = fit.data.swaps[0].box
	assert_true(Vector3(box[0], box[1], box[2]).is_equal_approx(Vector3(1.0, 0.7, 0.8)), "box size reported: %s" % str(box))
	var filled := _swap.swap_placeholder({"target": "map", "group": "Crates", "model": flat, "fit": "fill"})
	assert_has_key(filled, "data", str(filled))
	assert_false(filled.data.has("warnings"), str(filled.data.get("warnings")))
	var skin := map.get_node("Crates/Crate1/BodySkin") as Node3D
	var b: AABB = AssetTools.measure(skin).aabb
	assert_true(absf(b.size.y - 0.7) < 0.001 and absf(b.position.y) < 0.001, "height matches the collision box: %s" % str(b))
	assert_true(b.size.x <= 1.001 and b.size.z <= 0.801, "footprint inside the box: %s" % str(b.size))


func test_swap_weapon_scene_file_moves_muzzle() -> void:
	var made := _tools.weapon_create(_weapon_params("swap_gun"))
	assert_has_key(made, "data", str(made))
	var scene_path: String = made.data.scene_path
	var model := _save_model(_box_model(Vector3(0.08, 0.14, 0.7), Vector3(0, 0, -0.25)), MODEL_DIR + "/gun_model.tscn", Vector3(0, 0.03, -0.62))
	var result := _swap.swap_placeholder({"target": "weapon", "scene": scene_path, "model": model})
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.edited, "scene file (saved)")
	var weapon := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_false((weapon.get_node("Model") as Node3D).visible, "box hidden")
	var skin := weapon.get_node_or_null("ModelSkin/Model") as Node3D
	assert_true(skin != null, "model instanced")
	assert_eq(skin.scene_file_path, model, "saved as an instance of the model")
	assert_true((weapon.get_node("Muzzle") as Node3D).position.is_equal_approx(Vector3(0, 0.03, -0.62)), "muzzle moved to the model's Muzzle")
	assert_true(weapon.get("data") != null, "script and data kept")
	weapon.free()

	assert_true(_global_ur().undo(), "undo runs")
	var restored := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq(restored.get_node_or_null("ModelSkin"), null, "undo restores the scene file")
	assert_true((restored.get_node("Model") as Node3D).visible)
	restored.free()


func test_swap_player_body_turns_with_aim() -> void:
	var made := _tools.player_scaffold(_player_params({"add_to_scene": false}))
	assert_has_key(made, "data", str(made))
	var model := _save_model(_box_model(Vector3(0.6, 2.0, 0.4), Vector3(0, 1.0, 0)), MODEL_DIR + "/hero.tscn")
	var result := _swap.swap_placeholder({"target": "player", "scene": made.data.scene_path, "model": model})
	assert_has_key(result, "data", str(result))
	var player := (ResourceLoader.load(made.data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var skin := player.get_node_or_null("Aim/BodySkin") as Node3D
	assert_true(skin != null, "skin under Aim")
	assert_false((player.get_node("Body") as Node3D).visible)
	assert_false((player.get_node("Aim/Nose") as Node3D).visible)
	var box: AABB = AssetTools.measure(skin).aabb
	assert_true(absf(box.size.y - 1.8) < 0.001 and absf(box.position.y) < 0.001, "1.8 m tall on the floor: %s" % str(box))
	assert_true(player.get_node("CollisionShape3D") is CollisionShape3D)
	player.free()


func test_swap_item_patches_old_scripts_and_pickup_shows_model() -> void:
	_fresh_loot()
	## Older project copies: no model property, no _apply_model.
	var item_script := WORK_DIR + "/scripts/item_data.gd"
	var old_item := FileAccess.get_file_as_string(item_script).replace(
		"## 3D model shown when the item lies on the ground (asset_import /\n## swap_placeholder fill this in). Empty: a box in the rarity color.\n@export_file(\"*.glb\", \"*.gltf\", \"*.fbx\", \"*.obj\", \"*.tscn\", \"*.scn\") var model := \"\"\n", "")
	assert_false(old_item.contains("var model"), "simulated old item_data.gd")
	_write(item_script, old_item)
	var pickup_path := _install_template("loot_pickup")
	var tmpl := FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/loot_pickup.gd.tmpl")
	var old_pickup := tmpl.substr(0, tmpl.find(SwapTools.PICKUP_MODEL_MARKER)).replace("\t\t_apply_model()\n", "").rstrip("\n") + "\n"
	_write(pickup_path, old_pickup)
	var model := _save_model(_box_model(Vector3(0.05, 0.02, 0.05), Vector3(0, 0.01, 0)), MODEL_DIR + "/watch.tscn")

	var params := {"target": "item", "item_id": "gold_watch", "model": model, "database_path": ITEM_DIR + "/item_database.tres", "script_dir": WORK_DIR + "/scripts"}
	var result := _swap.swap_placeholder(params)
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.files.size(), 3, str(result.data.files))
	assert_true(FileAccess.get_file_as_string(item_script).contains("var model"), "item_data.gd gained model")
	assert_true(FileAccess.get_file_as_string(pickup_path).contains("func _apply_model("), "loot_pickup.gd shows models")
	var item := _load_fresh(ITEM_DIR + "/gold_watch.tres")
	assert_eq(item.get("model"), model)

	## The patched pickup shows the model scaled to model_size with a glow.
	var holder := Node3D.new()
	_root().add_child(holder)
	_added.append(holder)
	var pickup := Area3D.new()
	pickup.set_script(_tool_copy(pickup_path))
	pickup.set("item", item)
	pickup.set("item_id", "gold_watch")
	holder.add_child(pickup)
	var shown := pickup.get_node_or_null("Visual/Model") as Node3D
	assert_true(shown != null, "model under Visual")
	var box: AABB = AssetTools.measure(shown).aabb
	assert_true(absf(maxf(box.size.x, maxf(box.size.y, box.size.z)) * shown.scale.x - 0.45) < 0.01, "scaled to model_size")
	assert_true(pickup.get_node_or_null("Glow") != null, "rarity glow")
	assert_false(pickup.get_node("Visual").get_children().any(func(n): return n is MeshInstance3D and n.visible), "box hidden")

	assert_true(_global_ur().undo(), "undo runs")
	assert_eq(FileAccess.get_file_as_string(item_script), old_item, "undo restores item_data.gd")
	assert_eq(FileAccess.get_file_as_string(pickup_path), old_pickup, "undo restores loot_pickup.gd")
	assert_eq(_load_fresh(ITEM_DIR + "/gold_watch.tres").get("model"), null, "undo restores the item")
	assert_is_error(_swap.swap_placeholder(params.merged({"item_id": "nope"}, true)), "NODE_NOT_FOUND")


func test_tres_value_edit() -> void:
	var text := "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://a.gd\" id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\")\nitem_id = \"x\"\n"
	var set1 := SwapTools._set_tres_value(text, "model", "res://m.glb")
	assert_true(set1.contains("script = ExtResource(\"1\")\nmodel = \"res://m.glb\"\n"), set1)
	var set2 := SwapTools._set_tres_value(set1, "model", "res://n.glb")
	assert_eq(set2.count("model = "), 1)
	assert_eq(SwapTools._set_tres_value(set2, "model", ""), text)
	assert_eq(SwapTools._ext_script_path(text), "res://a.gd")


# --- item icons (item_icon_render) --------------------------------------------

const ICON_DIR := WORK_DIR + "/icons"


func _icon_params(extra: Dictionary = {}) -> Dictionary:
	var params := {"database_path": ITEM_DIR + "/item_database.tres", "icon_dir": ICON_DIR, "script_dir": WORK_DIR + "/scripts"}
	params.merge(extra, true)
	return params


## A UI script as an older project copy has it: the template without the
## icon block.
func _old_ui_copy(template: String, dest: String) -> String:
	var tmpl := FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/" + template)
	var a := tmpl.find(IconTools.UI_MARKER_BEGIN)
	var b := tmpl.find(IconTools.UI_MARKER_END)
	assert_true(a > 0 and b > a, "%s has the icon block" % template)
	var start := tmpl.rfind("\n", a) + 1
	var end := tmpl.find("\n", b) + 1
	var old := tmpl.substr(0, start) + tmpl.substr(end)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest.get_base_dir()))
	_write(dest, old)
	return old


func test_icon_params_rejected() -> void:
	var icons := IconTools.new()
	assert_is_error(icons.item_icon_render({}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_id": "a", "all": true}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_ids": ["a", "b"], "model": "res://m.glb"}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_id": "a", "model": "/tmp/m.glb"}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_id": "a", "cell_px": 8}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_id": "a", "icon_dir": "/tmp"}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_id": "a", "colour": 1}), "INVALID_PARAMS")
	assert_is_error(icons.item_icon_render({"item_ids": "a"}), "INVALID_PARAMS")


func test_icon_grid_suggestion_and_framing() -> void:
	assert_eq(IconTools.suggest_grid(0.1, 0.1), Vector2i(1, 1))
	assert_eq(IconTools.suggest_grid(0.1, 0.2), Vector2i(2, 1))
	assert_eq(IconTools.suggest_grid(0.1, 0.3), Vector2i(3, 1))
	assert_eq(IconTools.suggest_grid(0.1, 0.5), Vector2i(3, 1), "items stop at 3 cells")
	assert_eq(IconTools.suggest_grid(0.1, 0.5, "weapon"), Vector2i(4, 1))
	## A side view (pitch 0, yaw 0) of a 2 x 1 x 0.5 box fits its width on a
	## 2:1 image and centers on the box.
	var basis := IconTools.camera_basis(0.0, 0.0)
	var f := IconTools.frame_box(AABB(Vector3(-1, 0, -0.25), Vector3(2, 1, 0.5)), basis, 2.0, 0.0)
	assert_true(absf(f.height - 1.0) < 0.001, "ortho size %s" % f.height)
	assert_true(f.center.distance_to(Vector3(0, 0.5, 0)) < 0.001, "center %s" % str(f.center))
	var wide := IconTools.frame_box(AABB(Vector3(-1, 0, -0.25), Vector3(2, 1, 0.5)), basis, 1.0, 0.0)
	assert_true(absf(wide.height - 2.0) < 0.001, "square image fits the width: %s" % wide.height)
	var down := IconTools.camera_basis(90.0, 0.0)
	assert_true(down.z.distance_to(Vector3.UP) < 0.001, "pitch 90 looks straight down")
	## The outline darkens transparent pixels next to opaque ones only.
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.set_pixel(4, 4, Color(1, 1, 1, 1))
	var out := IconTools.add_outline(img)
	assert_true(out.get_pixel(5, 4).a > 0.5, "edge pixel")
	assert_eq(out.get_pixel(0, 0).a, 0.0, "far pixel stays clear")
	assert_eq(out.get_pixel(4, 4), Color(1, 1, 1, 1), "opaque pixel kept")


func test_icon_tres_edits() -> void:
	var text := "[gd_resource type=\"Resource\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://a.gd\" id=\"1_s\"]\n\n[resource]\nscript = ExtResource(\"1_s\")\nitem_id = \"x\"\nrarity = \"rare\"\nweight = 0.2\n"
	var one := IconTools.set_tres_icon(text, "res://i/x.png")
	assert_true(one.contains("[ext_resource type=\"Script\" path=\"res://a.gd\" id=\"1_s\"]\n[ext_resource type=\"Texture2D\" path=\"res://i/x.png\" id=\"icon_tex\"]"), one)
	assert_true(one.contains("rarity = \"rare\"\nicon = ExtResource(\"icon_tex\")\nweight"), one)
	var two := IconTools.set_tres_icon(one, "res://i/y.png")
	assert_eq(two.count("Texture2D"), 1, two)
	assert_eq(two.count("icon = "), 1, two)
	assert_true(two.contains("path=\"res://i/y.png\" id=\"icon_tex\""), two)
	var grid := IconTools.set_tres_int(IconTools.set_tres_int(one, "grid_width", 3), "grid_height", 1)
	assert_true(grid.contains("grid_width = 3\ngrid_height = 1\n"), grid)
	assert_eq(IconTools.set_tres_int(grid, "grid_width", 2).count("grid_width"), 1)
	## An id already taken gets a new one.
	var taken := text.replace("id=\"1_s\"", "id=\"icon_tex\"").replace("ExtResource(\"1_s\")", "ExtResource(\"icon_tex\")")
	assert_true(IconTools.set_tres_icon(taken, "res://i/x.png").contains("id=\"icon_tex_2\""))


func test_icon_plan_dry_run_and_apply() -> void:
	_fresh_loot()
	var watch := _save_model(_box_model(Vector3(0.1, 0.05, 0.3), Vector3(0, 0.025, 0)), MODEL_DIR + "/icon_watch.tscn")
	assert_has_key(_swap.swap_placeholder({"target": "item", "item_id": "gold_watch", "model": watch, "database_path": ITEM_DIR + "/item_database.tres", "script_dir": WORK_DIR + "/scripts"}), "data")
	var icons := IconTools.new()
	var inv_ui := WORK_DIR + "/scripts/inventory_ui.gd"
	var hideout := WORK_DIR + "/scripts/hideout.gd"
	var old_inv := _old_ui_copy("inventory_ui.gd.tmpl", inv_ui)
	var old_hideout := _old_ui_copy("hideout.gd.tmpl", hideout)

	var dry := icons.item_icon_render(_icon_params({"item_ids": ["gold_watch", "bandage"], "dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.items.size(), 1, str(dry.data))
	var row: Dictionary = dry.data.items[0]
	assert_eq(row.item_id, "gold_watch")
	assert_eq(row.icon, ICON_DIR + "/gold_watch.png")
	assert_eq(row.suggested_grid, [3, 1], "0.3 m long, 0.1 m wide: %s" % str(row))
	assert_eq(row.icon_px, [128, 128], "current 1x1 grid")
	assert_eq(dry.data.skipped.size(), 1)
	assert_eq(dry.data.skipped[0].item_id, "bandage")
	assert_eq(dry.data.ui.size(), 2, str(dry.data.ui))
	assert_eq(icons.item_icon_render(_icon_params({"all": true, "dry_run": true})).data.items.size(), 1, "all: only items with models")
	assert_eq(icons.item_icon_render(_icon_params({"item_id": "gold_watch", "dry_run": true, "apply_grid": true, "cell_px": 64})).data.items[0].icon_px, [192, 64])
	assert_false(FileAccess.file_exists(ICON_DIR + "/gold_watch.png"), "dry run writes nothing")
	assert_eq(FileAccess.get_file_as_string(inv_ui), old_inv)
	assert_is_error(icons.item_icon_render(_icon_params({"item_id": "nope"})), "NODE_NOT_FOUND")

	## Apply with a stand-in image (rendering needs a GUI editor).
	var p: Dictionary = IconTools.read_params(_icon_params({"item_id": "gold_watch", "apply_grid": true}))
	var plan: Dictionary = icons.make_plan(p)
	var img := Image.create(384, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.6, 0.2, 1))
	var result := icons.apply_icons(p, plan, {"gold_watch": img})
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.icons.size(), 1)
	assert_eq(result.data.icons[0].grid, [3, 1])
	assert_true(result.data.icons[0].grid_changed)
	assert_true(FileAccess.file_exists(ICON_DIR + "/gold_watch.png"), "PNG written")
	var png := Image.load_from_file(ProjectSettings.globalize_path(ICON_DIR + "/gold_watch.png"))
	assert_eq(png.get_size(), Vector2i(384, 128))
	var item_text := FileAccess.get_file_as_string(ITEM_DIR + "/gold_watch.tres")
	assert_true(item_text.contains("path=\"%s/gold_watch.png\"" % ICON_DIR), item_text)
	assert_true(item_text.contains("grid_width = 3") and item_text.contains("grid_height = 1"), item_text)
	for path in [inv_ui, hideout]:
		var src := FileAccess.get_file_as_string(path)
		assert_true(src.contains(IconTools.UI_MARKER_BEGIN), "%s draws icons" % path)
		var probe := GDScript.new()
		probe.source_code = src
		assert_eq(probe.reload(), OK, "%s compiles" % path)
	## A second run does not patch the UI again.
	assert_eq(IconTools.plan_ui_patches(WORK_DIR + "/scripts"), [])
	## Hand-edited copies are reported, not patched.
	assert_true(String(IconTools.patch_ui_source("func x():\n\tpass\n", FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/inventory_ui.gd.tmpl"), IconTools.UI_PATCHES[0].anchor)).begins_with("!"))

	assert_true(_global_ur().undo(), "undo runs")
	assert_false(FileAccess.file_exists(ICON_DIR + "/gold_watch.png"), "undo removes the PNG")
	assert_eq(FileAccess.get_file_as_string(inv_ui), old_inv, "undo restores inventory_ui.gd")
	assert_eq(FileAccess.get_file_as_string(hideout), old_hideout, "undo restores hideout.gd")
	assert_false(FileAccess.get_file_as_string(ITEM_DIR + "/gold_watch.tres").contains("Texture2D"), "undo restores the item")
	## Headless editors cannot render.
	if DisplayServer.get_name() == "headless":
		assert_is_error(icons.item_icon_render(_icon_params({"item_id": "gold_watch"})), "EDITOR_NOT_READY")


func test_gen_inspection_flags_cleanup_warnings() -> void:
	var job := {"asset_id": ASSET_PREFIX + "shred", "cleanup": {"warnings": ["decimating 800000 -> 2000 triangles broke the model into 900 loose pieces"]}, "steps": []}
	var out := GenTools.inspection(job, {}, {})
	assert_eq(out.verdict, "check")
	assert_true(out.issues.any(func(i): return String(i).begins_with("cleanup: decimating")), str(out.issues))
	assert_eq(GenTools.inspection({"asset_id": ASSET_PREFIX + "fine", "cleanup": {"warnings": []}, "steps": []}, {}, {}).verdict, "ok")

func test_icon_ui_templates_draw_icons() -> void:
	## The inventory grid draws an entry's icon (turned with the stack).
	for name in ["inventory_ui", "hideout"]:
		var src := FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/%s.gd.tmpl" % name)
		assert_eq(src.count(IconTools.UI_MARKER_BEGIN), 1, name)
		assert_true(src.contains("draw_texture_rect(icon"), name)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Runs the real Blender script when Blender is available (BLENDER_PATH or a
## standard install); skipped otherwise.
func test_asset_cleanup_runs_blender() -> void:
	if AssetTools.find_blender("").is_empty():
		skip("Blender not installed")
		return
	var model := _box_model(Vector3(0.12, 0.15, 0.4), Vector3(0, 0, -0.1), true)
	var src := _export_glb(model, ProjectSettings.globalize_path(WORK_DIR + "/src/gun.glb"))
	var id := ASSET_PREFIX + "gun"
	var result := _assets.asset_cleanup({"source": src, "kind": "weapon", "asset_id": id, "import": false, "preview": false})
	assert_has_key(result, "data", str(result))
	var cleanup: Dictionary = result.data.cleanup
	assert_true(String(cleanup.get("forward_detected", "")).contains("+z"), "barrel end found: %s" % str(cleanup.get("forward_detected")))
	assert_true(absf(cleanup.result.size[2] - 0.7) < 0.01, "length 0.7 m: %s" % str(cleanup.result.size))
	assert_true(cleanup.muzzle.position[2] < -0.3, "muzzle in front (-Z): %s" % str(cleanup.muzzle.position))
	assert_true(FileAccess.file_exists(AssetTools.clean_output_path(id)), "cleaned glb written")
	assert_true(FileAccess.file_exists(src), "source kept")


func _global_ur() -> UndoRedo:
	return _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func _scene_ur() -> UndoRedo:
	return _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root()))



# --- AI generation (asset_generate / asset_job / asset_pipeline) ---------------

const GEN_USAGE := "user://zz_mcp_test_gen_usage.json"


## Answers like Meshy/Tripo at once, so the tools run synchronously.
class FakeTransport extends RefCounted:
	var requests: Array = []
	var downloads: Array = []
	## Task id -> status payload fields.
	var tasks := {}
	var next_id := 0
	var glb := PackedByteArray()
	var fail_create_code := 0

	func request(req: Dictionary, _timeout: float = 30.0) -> Dictionary:
		requests.append(req)
		var url: String = req.url
		if req.get("method") == "POST":
			if fail_create_code != 0:
				return {"code": fail_create_code, "json": {"message": "nope"}, "text": ""}
			if url.ends_with("/files"):
				return {"code": 200, "json": {"code": 0, "data": {"file_token": "file_tok"}}, "text": ""}
			next_id += 1
			var id := "task%d" % next_id
			tasks[id] = "queued"
			if url.contains("meshy"):
				return {"code": 202, "json": {"result": id}, "text": ""}
			return {"code": 200, "json": {"code": 0, "data": {"task_id": id}}, "text": ""}
		if url.ends_with("/balance"):
			return {"code": 200, "json": {"balance": 123} if url.contains("meshy") else {"code": 0, "data": {"balance": 45.0, "frozen": 0}}, "text": ""}
		var id := url.get_file()
		var st: String = tasks.get(id, "missing")
		if url.contains("meshy"):
			var meshy_st: String = {"queued": "PENDING", "succeeded": "SUCCEEDED", "failed": "FAILED"}.get(st, "IN_PROGRESS")
			return {"code": 200, "json": {"id": id, "status": meshy_st, "progress": 100 if st == "succeeded" else 10,
				"model_urls": {"glb": "https://cdn.example/%s.glb" % id} if st == "succeeded" else {},
				"thumbnail_url": "https://cdn.example/%s.png" % id if st == "succeeded" else "",
				"task_error": {"message": "bad mesh"} if st == "failed" else null, "consumed_credits": 20}, "text": ""}
		var tripo_st: String = {"queued": "queued", "succeeded": "success", "failed": "failed"}.get(st, "running")
		return {"code": 200, "json": {"code": 0, "data": {"task_id": id, "status": tripo_st, "progress": 100 if st == "succeeded" else 5,
			"output": {"model_url": "https://cdn.example/%s.glb" % id, "rendered_image_url": "https://cdn.example/%s.png" % id} if st == "succeeded" else {}}}, "text": ""}

	func download(url: String, abs_path: String, _timeout: float = 100.0) -> Dictionary:
		downloads.append(url)
		DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
		var f := FileAccess.open(abs_path, FileAccess.WRITE)
		if url.ends_with(".glb"):
			f.store_buffer(glb)
		else:
			var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
			f.store_buffer(img.save_png_to_buffer())
		f.close()
		return {"ok": true, "bytes": glb.size()}

	func finish_all(status := "succeeded") -> void:
		for id in tasks:
			tasks[id] = status


func _gen(provider := "meshy") -> Array:
	var gen := GenTools.new()
	var fake := FakeTransport.new()
	var model := _box_model(Vector3(0.3, 0.2, 0.3), Vector3(0, 0.1, 0))
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(model, state)
	fake.glb = doc.generate_buffer(state)
	model.free()
	gen.transport = fake
	gen.usage_path_override = ProjectSettings.globalize_path(GEN_USAGE)
	gen.today_override = "2099-01-01"
	gen.settings_override = {"meshy_api_key": "msy_test", "tripo_api_key": "tsk_test", "default_provider": provider,
		"candidates": 2, "daily_task_limit": 20, "meshy_base_url": "", "tripo_base_url": ""}
	return [gen, fake]


func _remove_gen_test_files() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GEN_USAGE))


func _preset_existed() -> bool:
	return FileAccess.file_exists(GenTools.PRESET_PATH)


func _drop_preset(existed: bool) -> void:
	if existed:
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GenTools.PRESET_PATH))
	var dir := ProjectSettings.globalize_path(GenTools.PRESET_PATH.get_base_dir())
	if DirAccess.get_files_at(dir).is_empty() and DirAccess.get_directories_at(dir).is_empty():
		DirAccess.remove_absolute(dir)


func _template_preset() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(GenTools.PRESET_TEMPLATE))


func test_gen_compose_prompt() -> void:
	var preset := _template_preset()
	var c: Dictionary = GenTools.compose_prompt(preset, "weapon", "compact submachine gun", "meshy")
	assert_true(String(c.prompt).begins_with("compact submachine gun, "), c.prompt)
	assert_contains(String(c.prompt), "readable silhouette")
	assert_false(String(c.prompt).contains("moss"), "the addon default holds no game-specific art concept")
	assert_contains(String(c.prompt), "original firearm")
	assert_eq(c.negative_prompt, "", "Meshy takes no negative prompt")
	assert_eq(c.target_polycount, 5000)
	var t: Dictionary = GenTools.compose_prompt(preset, "item", "first aid kit", "tripo")
	assert_true(String(t.negative_prompt).length() <= 255 and not String(t.negative_prompt).is_empty(), t.negative_prompt)
	assert_eq(t.target_polycount, 2000)
	var plain: Dictionary = GenTools.compose_prompt(preset, "item", "first aid kit", "tripo", false)
	assert_eq(plain.prompt, "first aid kit")
	assert_is_error(GenTools.compose_prompt(preset, "item", "x".repeat(900), "meshy"), "INVALID_PARAMS")
	assert_is_error(GenTools.compose_prompt(preset, "item", "medkit with a brand name on it", "meshy"), "INVALID_PARAMS")


func test_gen_estimate_credits() -> void:
	var preset := _template_preset()
	var m := GenTools.estimate_credits(preset, "meshy", "text", 2, true)
	assert_eq(m.total, 50)
	assert_eq(m.tasks, 3)
	var i := GenTools.estimate_credits(preset, "tripo", "image", 2, true)
	assert_eq(i.total, 60, "image candidates come textured, no texture task")
	preset["credits"] = {"meshy": {"text_draft": 5}}
	assert_eq(GenTools.estimate_credits(preset, "meshy", "text", 2, false).total, 10)


func test_gen_provider_parsers() -> void:
	var req := GenProviders.text_draft_request("meshy", "https://api.meshy.ai", "k", {"prompt": "p", "target_polycount": 2000, "kind": "character"})
	assert_eq(req.url, "https://api.meshy.ai/openapi/v2/text-to-3d")
	assert_eq(req.body.mode, "preview")
	assert_eq(req.body.pose_mode, "a-pose")
	assert_true("Authorization: Bearer k" in req.headers)
	var tex := GenProviders.texture_request("tripo", "https://t/v3", "k", "abc", {"texture_prompt": "mossy"})
	assert_eq(tex.url, "https://t/v3/models/texture")
	assert_eq(tex.body.input, "abc")
	assert_eq(tex.body.texture_prompt.text, "mossy")
	assert_eq(GenProviders.parse_create("meshy", 202, {"result": "id1"}).task_id, "id1")
	assert_eq(GenProviders.parse_create("tripo", 200, {"code": 0, "data": {"task_id": "t1"}}).task_id, "t1")
	assert_contains(String(GenProviders.parse_create("meshy", 401, {"message": "bad"}).error), "API key")
	assert_contains(String(GenProviders.parse_create("tripo", 403, {"code": 2010, "message": "x"}).error), "2010")
	var st := GenProviders.parse_status("tripo", 200, {"code": 0, "data": {"status": "success", "progress": 100, "output": {"model_url": "u.glb", "rendered_image_url": "r.png"}}})
	assert_eq(st.status, "succeeded")
	assert_eq(st.model_url, "u.glb")
	assert_eq(GenProviders.parse_status("meshy", 200, {"status": "FAILED", "task_error": {"message": "m"}}).error, "m")
	assert_eq(GenProviders.parse_status("meshy", 429, null).retryable, true)
	assert_eq(GenProviders.status_request("meshy", "B", "k", "image-to-3d", "x").url, "B/openapi/v1/image-to-3d/x")


func test_gen_dry_run_spends_nothing() -> void:
	var existed := _preset_existed()
	var pair := _gen()
	var gen: GenTools = pair[0]
	var fake: FakeTransport = pair[1]
	gen.settings_override.meshy_api_key = ""
	var id := ASSET_PREFIX + "dry"
	var r := gen.asset_generate({"kind": "weapon", "asset_id": id, "prompt": "compact smg", "dry_run": true})
	assert_has_key(r, "data", str(r))
	assert_eq(r.data.estimated_credits.total, 50)
	assert_has_key(r.data, "warning", "missing key is reported")
	assert_eq(r.data.api_key, "missing")
	assert_eq(fake.requests.size(), 0)
	assert_false(FileAccess.file_exists(GenTools.job_path(id)), "no job file")
	assert_eq(_preset_existed(), existed, "dry_run does not write the preset")
	## Without dry_run the missing key stops it, telling where to enter it.
	var e := gen.asset_generate({"kind": "weapon", "asset_id": id, "prompt": "compact smg"})
	assert_is_error(e, "INVALID_PARAMS")
	assert_contains(String(e.error.message), "Editor Settings")
	assert_is_error(gen.asset_generate({"kind": "weapon", "asset_id": id}), "INVALID_PARAMS")
	assert_is_error(gen.asset_generate({"kind": "gun", "asset_id": id, "prompt": "x"}), "INVALID_PARAMS")
	assert_is_error(gen.asset_generate({"kind": "weapon", "asset_id": id, "prompt": "x", "provider": "other"}), "INVALID_PARAMS")
	_drop_preset(existed)


func test_gen_daily_limit() -> void:
	var existed := _preset_existed()
	var pair := _gen()
	var gen: GenTools = pair[0]
	gen.settings_override.daily_task_limit = 3
	gen.record_usage(2, 40, "earlier")
	assert_eq(gen.usage_today().tasks, 2)
	var r := gen.asset_generate({"kind": "item", "asset_id": ASSET_PREFIX + "limit", "prompt": "can of beans"})
	assert_is_error(r, "INVALID_PARAMS")
	assert_contains(String(r.error.message), "daily")
	var dry := gen.asset_generate({"kind": "item", "asset_id": ASSET_PREFIX + "limit", "prompt": "can of beans", "dry_run": true})
	assert_has_key(dry.data, "warning_limit")
	_remove_gen_test_files()
	_drop_preset(existed)


func test_gen_meshy_text_flow_to_import() -> void:
	var existed := _preset_existed()
	var pair := _gen("meshy")
	var gen: GenTools = pair[0]
	var fake: FakeTransport = pair[1]
	var id := ASSET_PREFIX + "medkit"
	var r := gen.asset_generate({"kind": "item", "asset_id": id, "prompt": "first aid kit"})
	assert_has_key(r, "data", str(r))
	assert_eq(r.data.stage, "generating")
	assert_eq(r.data.candidates.size(), 2)
	assert_eq(fake.requests.size(), 2)
	assert_eq(fake.requests[0].body.mode, "preview")
	assert_eq(gen.usage_today().tasks, 2)
	assert_true(FileAccess.file_exists(GenTools.job_path(id)))
	assert_true(FileAccess.file_exists(GenTools.PRESET_PATH), "preset created on first use")
	## A second start is refused while the job is open.
	assert_is_error(gen.asset_generate({"kind": "item", "asset_id": id, "prompt": "first aid kit"}), "ALREADY_EXISTS")
	## Not finished yet.
	var s := gen.asset_job({"asset_id": id})
	assert_eq(s.data.stage, "generating")
	assert_is_error(gen.asset_job({"op": "pick", "asset_id": id, "index": 1}), "INVALID_PARAMS")
	fake.finish_all()
	s = gen.asset_job({"asset_id": id})
	assert_eq(s.data.stage, "candidates_ready", str(s))
	assert_true(FileAccess.file_exists(String(s.data.candidates[0].preview)), "thumbnail saved")
	## The pipeline stops here for the user's choice.
	var stop := gen.asset_pipeline({"asset_id": id})
	assert_true(String(stop.data.next).begins_with("STOP"), stop.data.next)
	## Pick 2: textures it (one more task).
	var pk := gen.asset_job({"op": "pick", "asset_id": id, "index": 2})
	assert_eq(pk.data.stage, "texturing", str(pk))
	var refine: Dictionary = fake.requests[fake.requests.size() - 1]
	assert_eq(refine.body.mode, "refine")
	assert_eq(refine.body.preview_task_id, "task2")
	assert_eq(gen.usage_today().tasks, 3)
	assert_is_error(gen.asset_job({"op": "pick", "asset_id": id, "index": 1}), "ALREADY_EXISTS")
	fake.finish_all()
	var done := gen.asset_pipeline({"asset_id": id, "cleanup": false, "swap": false, "dest_dir": ASSET_KNOWN_DIR, "preview": false})
	assert_has_key(done, "data", str(done))
	assert_eq(done.data.stage, "done", str(done))
	assert_true(String(fake.downloads[fake.downloads.size() - 1]).ends_with("task3.glb"), "downloads the textured model")
	assert_true(FileAccess.file_exists(ASSET_KNOWN_DIR + "/" + id + ".glb"), "imported")
	assert_eq(done.data.import.triangles, 12)
	var job: Dictionary = GenTools.load_job(id)
	assert_eq(job.pick.index, 2)
	var listed := gen.asset_job({"op": "list"})
	assert_true(listed.data.jobs.any(func(j): return j.asset_id == id))
	_remove_gen_test_files()
	_drop_preset(existed)


func test_gen_tripo_image_job() -> void:
	var existed := _preset_existed()
	var pair := _gen("tripo")
	var gen: GenTools = pair[0]
	var fake: FakeTransport = pair[1]
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var png := ProjectSettings.globalize_path(WORK_DIR + "/ref/front.png")
	DirAccess.make_dir_recursive_absolute(png.get_base_dir())
	img.save_png(png)
	var id := ASSET_PREFIX + "crate"
	var r := gen.asset_generate({"kind": "prop", "asset_id": id, "prompt": "supply crate", "reference_image": png, "candidates": 1})
	assert_has_key(r, "data", str(r))
	assert_eq(r.data.mode, "image")
	assert_true(fake.requests[0].has("multipart"), "the image is uploaded first")
	assert_eq(fake.requests[1].body.input, "file_tok")
	assert_eq(fake.requests[1].body.texture, true)
	fake.finish_all()
	gen.asset_job({"asset_id": id})
	var pk := gen.asset_job({"op": "pick", "asset_id": id, "index": 1})
	assert_eq(pk.data.stage, "ready", "image candidates need no texture task")
	assert_eq(gen.usage_today().tasks, 1)
	var c := gen.asset_job({"op": "cancel", "asset_id": id})
	assert_eq(c.data.stage, "canceled")
	## A canceled job can be replaced without overwrite.
	var again := gen.asset_generate({"kind": "prop", "asset_id": id, "prompt": "supply crate", "dry_run": true})
	assert_has_key(again, "data", str(again))
	_remove_gen_test_files()
	_drop_preset(existed)


func test_gen_failed_create_reported() -> void:
	var existed := _preset_existed()
	var pair := _gen("meshy")
	var gen: GenTools = pair[0]
	var fake: FakeTransport = pair[1]
	fake.fail_create_code = 402
	var r := gen.asset_generate({"kind": "item", "asset_id": ASSET_PREFIX + "broke", "prompt": "bottle"})
	assert_is_error(r, "INTERNAL_ERROR")
	assert_contains(String(r.error.message), "credits")
	assert_eq(fake.requests.size(), 1, "stops at the first refusal")
	assert_eq(gen.usage_today().tasks, 0)
	var b := gen.asset_job({"op": "balance"})
	assert_eq(b.data.providers.meshy.balance, 123)
	assert_eq(b.data.providers.tripo.balance, 45.0)
	_remove_gen_test_files()
	_drop_preset(existed)


func test_gen_pipeline_swap_defaults() -> void:
	var cfg := {"swap": null}
	assert_eq(GenTools._swap_params("weapon", "smg", cfg), {"target": "weapon", "asset_id": "smg"})
	assert_eq(GenTools._swap_params("item", "medkit", cfg), {"target": "item", "item_id": "medkit"})
	assert_eq(GenTools._swap_params("character", "grunt", cfg), null)
	assert_eq(GenTools._swap_params("weapon", "smg", {"swap": false}), null)
	assert_eq(GenTools._swap_params("character", "grunt", {"swap": {"target": "enemy"}}), {"target": "enemy", "asset_id": "grunt"})
	assert_is_error(GenTools._swap_params("prop", "crate", {"swap": {"group": "Crates"}}), "INVALID_PARAMS")
	assert_is_error(GenTools._swap_params("weapon", "smg", {"swap": {"target": "weapon", "revert": true}}), "INVALID_PARAMS")
	var pair := _gen()
	var gen: GenTools = pair[0]
	assert_is_error(gen.asset_pipeline({"asset_id": "x", "swap": "yes"}), "INVALID_PARAMS")
	assert_is_error(gen.asset_pipeline({"asset_id": "x", "cleanup_options": {"source": "a"}}), "INVALID_PARAMS")
	assert_is_error(gen.asset_job({"op": "status", "asset_id": "zz_never_made"}), "NODE_NOT_FOUND")


func test_gen_adopt_external_model() -> void:
	var pair := _gen()
	var gen: GenTools = pair[0]
	var fake: FakeTransport = pair[1]
	var inbox_dir := WORK_DIR + "/inbox/tripo_export"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(inbox_dir))
	var src := inbox_dir + "/smg_tripo.glb"
	var f := FileAccess.open(src, FileAccess.WRITE)
	f.store_buffer(fake.glb)
	f.close()
	gen.settings_override["inbox_dirs"] = WORK_DIR + "/inbox, res://zz_mcp_test_no_such_dir"
	var box := gen.asset_job({"op": "inbox"})
	assert_has_key(box, "data", str(box))
	assert_eq(box.data.count, 1, str(box))
	assert_eq(box.data.models[0].path, src)
	assert_eq(box.data.missing_dirs.size(), 1)
	var id := ASSET_PREFIX + "adopted"
	var base := {"asset_id": id, "kind": "weapon", "source": src, "provider": "tripo"}
	## Generation-only params and unknown origins are refused.
	assert_is_error(gen.asset_pipeline(_merged(base, {"candidates": 2})), "INVALID_PARAMS")
	assert_is_error(gen.asset_pipeline(_merged(base, {"provider": "acme"})), "INVALID_PARAMS")
	assert_is_error(gen.asset_pipeline(_merged(base, {"source": inbox_dir + "/missing.glb"})), "INVALID_PARAMS")
	var dry := gen.asset_pipeline(_merged(base, {"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.estimated_credits.total, 0)
	assert_eq(dry.data.pipeline.swap, {"target": "weapon", "asset_id": id})
	assert_false(FileAccess.file_exists(GenTools.job_path(id)), "dry_run writes no job")
	var done := gen.asset_pipeline(_merged(base, {"cleanup": false, "swap": false, "dest_dir": ASSET_KNOWN_DIR, "preview": false}))
	assert_has_key(done, "data", str(done))
	assert_eq(done.data.stage, "done", str(done))
	assert_eq(done.data.mode, "external")
	assert_eq(done.data.import.triangles, 12)
	assert_true(FileAccess.file_exists(GenTools.raw_model_path(id)), "the export is copied next to the job")
	assert_true(FileAccess.file_exists(src), "the original export stays")
	assert_eq(fake.requests.size(), 0, "no service calls")
	assert_eq(gen.usage_today().tasks, 0, "no credits counted")
	assert_is_error(gen.asset_job({"op": "pick", "asset_id": id, "index": 1}), "INVALID_PARAMS")
	var again := gen.asset_job({"op": "inbox"})
	assert_eq(again.data.models[0].get("used_by"), id)
	## A .blend needs Blender cleanup.
	var blend := inbox_dir + "/thing.blend"
	var bf := FileAccess.open(blend, FileAccess.WRITE)
	bf.store_string("x")
	bf.close()
	assert_is_error(gen.asset_pipeline({"asset_id": id + "_b", "kind": "prop", "source": blend, "cleanup": false}), "INVALID_PARAMS")
	_remove_gen_test_files()


func _merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	out.merge(b, true)
	return out



# --- environment (polyhaven_fetch / swap_placeholder target=kit / environment_setup)

const KIT_ID := "zz_mcp_test_kit"
const ENV_NAME := "zz_mcp_test_asset_concrete"


func _remove_env_test_files() -> void:
	var kit_dir := ProjectSettings.globalize_path(KitTools.KIT_ROOT + "/" + KIT_ID)
	_remove_tree(kit_dir)
	## Drop res://assets/props/kit, props and assets when the tests made them.
	for dir in [KitTools.KIT_ROOT, KitTools.KIT_ROOT.get_base_dir(), KitTools.KIT_ROOT.get_base_dir().get_base_dir()]:
		var abs := ProjectSettings.globalize_path(dir)
		if DirAccess.dir_exists_absolute(abs) and DirAccess.get_files_at(abs).is_empty() and DirAccess.get_directories_at(abs).is_empty():
			DirAccess.remove_absolute(abs)
	for name in [ENV_NAME, ENV_NAME + "_sky"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EnvTools.RECORD_DIR + "/" + name + ".json"))
	var rec := ProjectSettings.globalize_path(EnvTools.RECORD_DIR)
	if DirAccess.dir_exists_absolute(rec) and DirAccess.get_files_at(rec).is_empty():
		DirAccess.remove_absolute(rec)
	var sources := ProjectSettings.globalize_path(AssetTools.SOURCES_ROOT)
	if DirAccess.dir_exists_absolute(sources) and DirAccess.get_directories_at(sources).is_empty():
		DirAccess.remove_absolute(sources.path_join(".gdignore"))
		_remove_tree(sources)


## A raid-map-like blockout (Floors / Walls / Cover) and a hideout-like Room.
func _kit_map() -> Node3D:
	var map := Node3D.new()
	map.name = "KitTestMap"
	map.set_meta(&"raid_map_seed", 1)
	_root().add_child(map)
	_added.append(map)
	map.owner = _root()
	var specs := [
		["Floors", "Floor1", Vector3(4, 0.5, 6), Vector3(0, -0.25, 0)],
		["Walls", "Wall1", Vector3(0.4, 3, 6.4), Vector3(-2.2, 1.5, 0)],
		["Walls", "Wall2", Vector3(5, 1, 0.4), Vector3(0, 0.5, 3.2)],
		["Cover", "LowWall1", Vector3(3, 1.1, 0.6), Vector3(0, 0.55, 1)],
		["Cover", "Pillar2", Vector3(1, 3, 1), Vector3(1, 1.5, -1)],
		["Cover", "Box3", Vector3(1.4, 1.3, 1.4), Vector3(-1, 0.65, -2)],
		["Crates", "Crate1", Vector3(1, 0.7, 0.8), Vector3(1.5, 0.35, 2)],
		["Hideout/Room", "Floor", Vector3(8.8, 0.2, 6.8), Vector3(20, -0.1, 0)],
		["Hideout/Room", "WallNear", Vector3(8.8, 1, 0.4), Vector3(20, 0.5, 3.6)],
	]
	for spec in specs:
		var group := map.get_node_or_null(NodePath(spec[0])) as Node3D
		if group == null:
			var parent: Node = map
			for part in String(spec[0]).split("/"):
				var n := parent.get_node_or_null(NodePath(part)) as Node3D
				if n == null:
					n = Node3D.new()
					n.name = part
					parent.add_child(n)
					n.owner = _root()
				parent = n
			group = parent
		var body := StaticBody3D.new()
		body.name = spec[1]
		body.position = spec[3]
		group.add_child(body)
		body.owner = _root()
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		var box := BoxMesh.new()
		box.size = spec[2]
		mi.mesh = box
		body.add_child(mi)
		mi.owner = _root()
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		var shape := BoxShape3D.new()
		shape.size = spec[2]
		cs.shape = shape
		body.add_child(cs)
		cs.owner = _root()
	return map


func _kit_params(extra: Dictionary = {}) -> Dictionary:
	var p := {"target": "kit", "kit": KIT_ID, "map_path": "KitTestMap"}
	p.merge(extra, true)
	return p


func test_kit_split_and_roles() -> void:
	assert_eq(KitTools.split(7, [4, 2, 1]), [4, 2, 1])
	assert_eq(KitTools.split(6, [4, 2, 1]), [4, 2])
	assert_eq(KitTools.split(3, [1]), [1, 1, 1])
	assert_eq(KitTools.cells_of(6.4, 1.0), 6)
	assert_eq(KitTools.cells_of(0.2, 1.0), 1)
	assert_eq(KitTools.role_for("Walls", "Wall3", Vector3(0.4, 3, 5)), "wall")
	assert_eq(KitTools.role_for("Walls", "Wall3", Vector3(5, 1, 0.4)), "low_wall")
	assert_eq(KitTools.role_for("Cover", "LowWall2", Vector3(3, 1.1, 0.6)), "low_wall")
	assert_eq(KitTools.role_for("Cover", "Thing", Vector3(1, 1, 1)), "box")
	assert_eq(KitTools.role_for("Room", "WallLeft", Vector3(0.4, 3, 6)), "wall")
	assert_eq(KitTools.role_for("Room", "Table", Vector3(2, 0.8, 1)), "", "hideout furniture is left alone")


func test_kit_dresses_raid_groups_and_room_keeping_collision_with_undo_and_revert() -> void:
	_remove_env_test_files()
	var map := _kit_map()
	var dry := _swap.swap_placeholder(_kit_params({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.swapped, 8, "6 raid boxes + 2 Room boxes; crates and furniture untouched: %s" % str(dry.data.by_role))
	assert_eq(dry.data.kit.would_generate.size(), KitTools.piece_names().size())
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(KitTools.KIT_ROOT + "/" + KIT_ID)), "dry run writes no kit")
	assert_eq(map.get_node("Walls/Wall1").get_node_or_null("MeshSkin"), null, "dry run changes nothing")

	var result := _swap.swap_placeholder(_kit_params())
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.by_role, {"floor": 2, "wall": 1, "low_wall": 3, "pillar": 1, "box": 1}, str(result.data.by_role))
	assert_true(FileAccess.file_exists(KitTools.KIT_ROOT + "/" + KIT_ID + "/wall_4m.tscn"), "missing pieces generated")
	## The 6.4 m wall: 6 cells -> a 4 m and a 2 m module, stretched to cover it.
	var wall := map.get_node("Walls/Wall1")
	var skin := wall.get_node("MeshSkin") as Node3D
	assert_eq(skin.get_child_count(), 2, "4 m + 2 m modules")
	assert_eq(skin.owner, _root(), "skin saved with the scene")
	var wb: AABB = AssetTools.measure(skin).aabb
	assert_true(absf(wb.size.x - 0.4) < 0.01 and absf(wb.size.y - 3.0) < 0.01 and absf(wb.size.z - 6.4) < 0.01, "modules cover the wall box: %s" % str(wb))
	assert_true(absf(wb.position.y + 1.5) < 0.01, "from the floor up (body origin at the box center): %s" % str(wb))
	assert_false((wall.get_node("Mesh") as Node3D).visible, "placeholder hidden")
	assert_true(wall.get_node("Shape") is CollisionShape3D and (wall.get_node("Shape") as CollisionShape3D).shape.size == Vector3(0.4, 3, 6.4), "collision kept")
	assert_eq(skin.find_children("*", "CollisionObject3D", true, false).size(), 0, "kit pieces add no collision (navigation bakes from colliders only)")
	## The 4x6 floor: 4 m tile + two 2 m tiles, top flush with the box top.
	var floor_skin := map.get_node("Floors/Floor1/MeshSkin") as Node3D
	assert_eq(floor_skin.get_child_count(), 3, "4x4 + 2x 2x2 tiles")
	var fb: AABB = AssetTools.measure(floor_skin).aabb
	assert_true(absf(fb.end.y - 0.25) < 0.01 and absf(fb.size.x - 4) < 0.01 and absf(fb.size.z - 6) < 0.01, "floor tiles cover the floor: %s" % str(fb))
	assert_true(map.get_node("Hideout/Room/Floor").get_node_or_null("MeshSkin") != null, "hideout Room floor dressed")
	assert_eq(map.get_node("Crates/Crate1").get_node_or_null("MeshSkin"), null, "crates are not part of the kit")
	assert_true(result.data.max_stretch > 0.0 and result.data.max_stretch < 0.1, "corner overlaps absorbed by a small stretch: %s" % str(result.data.max_stretch))

	## Rerun replaces the skins instead of stacking them.
	assert_has_key(_swap.swap_placeholder(_kit_params({"groups": ["Walls"]})), "data")
	assert_eq(wall.get_children().filter(func(n): return String(n.name).begins_with("MeshSkin")).size(), 1, "one skin")

	assert_true(_scene_ur().undo(), "undo runs")
	assert_true(_scene_ur().undo(), "undo the first kit pass")
	assert_eq(wall.get_node_or_null("MeshSkin"), null, "undo removes the skin")
	assert_true((wall.get_node("Mesh") as Node3D).visible, "undo shows the wall again")
	assert_true(_scene_ur().redo(), "redo runs")
	assert_true(wall.get_node_or_null("MeshSkin") != null, "redo")

	var reverted := _swap.swap_placeholder(_kit_params({"revert": true}))
	assert_has_key(reverted, "data", str(reverted))
	assert_eq(wall.get_node_or_null("MeshSkin"), null, "revert removes the skins")
	assert_true((wall.get_node("Mesh") as Node3D).visible, "revert shows the placeholders")
	assert_is_error(_swap.swap_placeholder(_kit_params({"revert": true})), "NODE_NOT_FOUND")


func test_kit_prefers_model_pieces_and_rejects_bad_ones() -> void:
	_remove_env_test_files()
	_kit_map()
	var dir := KitTools.KIT_ROOT + "/" + KIT_ID
	## A hand-made box piece (could be an imported .glb) is used as is.
	_save_model(_box_model(Vector3(2, 2, 2), Vector3(0, 1, 0)), dir + "/box.tscn")
	var result := _swap.swap_placeholder(_kit_params({"groups": ["Cover"]}))
	assert_has_key(result, "data", str(result))
	assert_true("box" in result.data.kit.existing, str(result.data.kit))
	var box_skin := _root().get_node("KitTestMap/Cover/Box3/MeshSkin") as Node3D
	var bb: AABB = AssetTools.measure(box_skin).aabb
	assert_true(bb.size.is_equal_approx(Vector3(1.4, 1.3, 1.4)), "model piece stretched to the box: %s" % str(bb.size))
	## rebuild_kit regenerates only generated pieces.
	var rebuilt := _swap.swap_placeholder(_kit_params({"groups": ["Cover"], "rebuild_kit": true}))
	assert_has_key(rebuilt, "data", str(rebuilt))
	assert_true("box" in rebuilt.data.kit.existing and "pillar" in rebuilt.data.kit.generated, str(rebuilt.data.kit))
	## A piece with collision would change the navigation: refused.
	var solid := _box_model(Vector3(1, 1, 1), Vector3(0, 0.5, 0))
	var body := StaticBody3D.new()
	body.name = "Col"
	solid.add_child(body)
	body.owner = solid
	_save_model(solid, dir + "/box.tscn")
	assert_is_error(_swap.swap_placeholder(_kit_params({"groups": ["Cover"]})), "INVALID_PARAMS")
	## Param checks.
	assert_is_error(_swap.swap_placeholder(_kit_params({"groups": ["Crates"]})), "INVALID_PARAMS")
	assert_is_error(_swap.swap_placeholder(_kit_params({"materials": {"wall": "no_such_material"}})), "INVALID_PARAMS")
	assert_is_error(_swap.swap_placeholder(_kit_params({"materials": {"glass": "res://x.tres"}})), "INVALID_PARAMS")
	assert_is_error(_swap.swap_placeholder({"target": "map", "group": "Walls", "kit": "x", "model": "res://nope.glb"}), "INVALID_PARAMS")
	assert_is_error(_swap.swap_placeholder(_kit_params({"map_path": "NoSuchMap"})), "NODE_NOT_FOUND")


## Answers like api.polyhaven.com at once.
class FakePolyHaven extends RefCounted:
	var requests: Array = []
	var downloads: Array = []

	func request(req: Dictionary, _timeout: float = 30.0) -> Dictionary:
		requests.append(req)
		var url: String = req.url
		if url.ends_with("/info/concrete_test"):
			return {"code": 200, "json": {"name": "Concrete Test", "type": 1, "authors": {"Someone": "All"}}, "text": ""}
		if url.ends_with("/info/sky_test"):
			return {"code": 200, "json": {"name": "Sky Test", "type": 0, "authors": {"Someone": "All"}}, "text": ""}
		if url.ends_with("/info/chair_test"):
			return {"code": 200, "json": {"name": "Chair", "type": 2}, "text": ""}
		if url.contains("/info/"):
			return {"code": 404, "json": {"error": "not found"}, "text": ""}
		if url.ends_with("/files/concrete_test"):
			var out := {}
			for key in ["Diffuse", "nor_gl", "nor_dx", "arm", "Rough", "Displacement"]:
				out[key] = {"1k": {"jpg": {"url": "https://dl.example/%s_1k.jpg" % key, "size": 1000}, "png": {"url": "https://dl.example/%s_1k.png" % key, "size": 3000}},
					"2k": {"jpg": {"url": "https://dl.example/%s_2k.jpg" % key, "size": 4000}}}
			out["blend"] = {"1k": {"blend": {"url": "https://dl.example/x.blend", "size": 1}}}
			return {"code": 200, "json": out, "text": ""}
		if url.ends_with("/files/sky_test"):
			return {"code": 200, "json": {"hdri": {"2k": {"hdr": {"url": "https://dl.example/sky_2k.hdr", "size": 5000}}}, "tonemapped": {}}, "text": ""}
		if url.contains("/assets?type=textures"):
			return {"code": 200, "json": {"concrete_wall_008": {"name": "Concrete Wall 008", "tags": ["wall"], "categories": ["concrete"], "download_count": 5},
				"mossy_rock": {"name": "Mossy Rock", "tags": ["moss"], "categories": ["rock"], "download_count": 9}}, "text": ""}
		if url.contains("/assets?type=hdris"):
			return {"code": 200, "json": {"overcast_soil": {"name": "Overcast Soil", "tags": ["overcast"], "categories": ["outdoor"]}}, "text": ""}
		return {"code": 500, "json": null, "text": "unexpected " + url}

	func download(url: String, abs_path: String, _timeout: float = 100.0) -> Dictionary:
		downloads.append(url)
		DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
		var f := FileAccess.open(abs_path, FileAccess.WRITE)
		var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
		f.store_buffer(img.save_png_to_buffer())
		f.close()
		return {"ok": true, "bytes": 10}


func _env_tools() -> Array:
	var env := EnvTools.new()
	var fake := FakePolyHaven.new()
	env.transport = fake
	env.trigger_import = false
	return [env, fake]


func _ph_params(extra: Dictionary = {}) -> Dictionary:
	var p := {"asset": "concrete_test", "name": ENV_NAME, "material_dir": WORK_DIR + "/materials", "hdri_dir": WORK_DIR + "/hdri"}
	p.merge(extra, true)
	return p


func test_polyhaven_fetch_texture_material_record_and_undo() -> void:
	var pair := _env_tools()
	var env: EnvTools = pair[0]
	var fake: FakePolyHaven = pair[1]
	var dry := env.polyhaven_fetch(_ph_params({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	var maps: Array = dry.data.files.map(func(f): return f.map)
	assert_eq(maps, ["albedo", "normal", "arm"], "GL normal over DX, ARM over separate roughness, no displacement: %s" % str(maps))
	assert_eq(dry.data.material_type, "ORMMaterial3D")
	assert_true(String(dry.data.files[0].path).ends_with("_albedo.jpg"), "jpg preferred")
	assert_eq(fake.downloads.size(), 0, "dry run downloads nothing")
	assert_true(fake.requests[0].headers[0].begins_with("User-Agent: "), "identifies itself to Poly Haven")

	var result := env.polyhaven_fetch(_ph_params({"tile_meters": 4.0, "tint": [0.8, 0.9, 0.8]}))
	assert_has_key(result, "data", str(result))
	assert_eq(fake.downloads.size(), 3)
	var mat_path: String = result.data.material
	assert_eq(mat_path, WORK_DIR + "/materials/%s/%s.tres" % [ENV_NAME, ENV_NAME])
	var text := FileAccess.get_file_as_string(mat_path)
	assert_contains(text, "[gd_resource type=\"ORMMaterial3D\"")
	assert_contains(text, "orm_texture = ExtResource(")
	assert_contains(text, "normal_enabled = true")
	assert_contains(text, "uv1_world_triplanar = true")
	assert_contains(text, "uv1_scale = Vector3(0.25, 0.25, 0.25)")
	assert_contains(text, "albedo_color = Color(0.8")
	var normal_cfg := ConfigFile.new()
	assert_eq(normal_cfg.load(WORK_DIR + "/materials/%s/%s_normal.jpg.import" % [ENV_NAME, ENV_NAME]), OK, "normal .import written")
	assert_eq(normal_cfg.get_value("params", "compress/normal_map"), 1, "flagged as a normal map")
	var albedo_cfg := ConfigFile.new()
	albedo_cfg.load(WORK_DIR + "/materials/%s/%s_albedo.jpg.import" % [ENV_NAME, ENV_NAME])
	assert_eq(albedo_cfg.get_value("params", "compress/normal_map"), 2, "albedo is not a normal map")
	var record: Variant = _read_json(EnvTools.RECORD_DIR + "/%s.json" % ENV_NAME)
	assert_true(record is Dictionary and record.license == "CC0" and record.id == "concrete_test", str(record))
	assert_is_error(env.polyhaven_fetch(_ph_params()), "ALREADY_EXISTS")

	assert_true(_global_undo().undo(), "undo runs")
	assert_false(FileAccess.file_exists(mat_path), "undo removes the material")
	assert_false(FileAccess.file_exists(WORK_DIR + "/materials/%s/%s_albedo.jpg" % [ENV_NAME, ENV_NAME]), "undo removes the textures")
	assert_true(_global_undo().redo(), "redo runs")
	assert_true(FileAccess.file_exists(mat_path), "redo")


func test_polyhaven_fetch_hdri_search_and_errors() -> void:
	var pair := _env_tools()
	var env: EnvTools = pair[0]
	var hdri := env.polyhaven_fetch(_ph_params({"asset": "sky_test", "name": ENV_NAME + "_sky"}))
	assert_has_key(hdri, "data", str(hdri))
	assert_eq(hdri.data.type, "hdri")
	assert_eq(hdri.data.resolution, "2k", "nearest available resolution")
	assert_eq(hdri.data.hdri, WORK_DIR + "/hdri/%s_sky.hdr" % ENV_NAME)
	assert_true(FileAccess.file_exists(hdri.data.hdri), "hdr downloaded")
	assert_true(String(hdri.data.next).begins_with("environment_setup"), hdri.data.next)
	assert_eq(EnvTools.guess_kit_role("concrete_floor_02"), "floor")
	assert_eq(EnvTools.guess_kit_role("rusty_metal_02"), "cover")
	assert_eq(EnvTools.guess_kit_role("concrete_wall_008"), "wall")

	var found := env.polyhaven_fetch({"search": "moss rock"})
	assert_has_key(found, "data", str(found))
	assert_eq(found.data.results[0].id, "mossy_rock", str(found.data.results))
	assert_is_error(env.polyhaven_fetch(_ph_params({"asset": "missing_thing"})), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch(_ph_params({"asset": "chair_test"})), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch(_ph_params({"type": "hdri"})), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch({"name": "x"}), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch(_ph_params({"asset": "Bad Id"})), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch(_ph_params({"resolution": "3k"})), "INVALID_PARAMS")
	assert_is_error(env.polyhaven_fetch(_ph_params({"material_dir": "res://addons/x"})), "INVALID_PARAMS")


func test_environment_setup_world_environment_sun_and_undo() -> void:
	var env := EnvTools.new()
	var path := WORK_DIR + "/env/world_environment.tres"
	var root := _root()
	var worlds_before := root.find_children("*", "WorldEnvironment", true, false).size()
	var dry := env.environment_setup({"environment_path": path, "dry_run": true, "fog": true})
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.values.fog, true)
	assert_false(FileAccess.file_exists(path), "dry run writes nothing")

	var result := env.environment_setup({"environment_path": path, "fog": true, "fog_density": 0.05, "fog_color": "#8899aa",
		"volumetric_fog": true, "sun_energy": 0.6, "sun_color": [1, 0.9, 0.8], "tonemap": "aces"})
	assert_has_key(result, "data", str(result))
	assert_true(FileAccess.file_exists(path), "shared environment saved")
	var world := Util_find_world(root)
	assert_true(world != null and world.environment != null, "WorldEnvironment present")
	var e: Environment = world.environment
	assert_true(e.fog_enabled and absf(e.fog_density - 0.05) < 0.0001, "fog on")
	assert_true(e.fog_light_color.is_equal_approx(Color.html("#8899aa")), "fog color")
	assert_true(e.volumetric_fog_enabled, "volumetric fog")
	assert_eq(e.tonemap_mode, Environment.TONE_MAPPER_ACES)
	assert_true(e.sky != null and e.sky.sky_material is ProceduralSkyMaterial, "procedural sky without an HDRI")
	assert_eq(e.resource_path, path, "the scene uses the shared file")
	var env_uid := ResourceLoader.get_resource_uid(path)
	assert_true(env_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(env_uid) and ResourceUID.get_id_path(env_uid) == path, "UID registered at once")
	var sun := McpScenePath.resolve(result.data.sun, root) as DirectionalLight3D
	assert_true(sun != null and absf(sun.light_energy - 0.6) < 0.0001, "sun set: %s" % result.data.sun)

	assert_true(_scene_ur().undo(), "undo runs")
	assert_eq(root.find_children("*", "WorldEnvironment", true, false).size(), worlds_before, "undo puts the scene back")
	assert_true(_scene_ur().redo(), "redo")
	assert_true(_scene_ur().undo(), "undo again")

	assert_is_error(env.environment_setup({"tonemap": "sepia"}), "INVALID_PARAMS")
	assert_is_error(env.environment_setup({"hdri": "no_such_sky"}), "INVALID_PARAMS")
	assert_is_error(env.environment_setup({"fog_color": [2, "x", 0]}), "INVALID_PARAMS")
	assert_is_error(env.environment_setup({"environment_path": "res://addons/x.tres"}), "INVALID_PARAMS")
	assert_is_error(env.environment_setup({"colour": 1}), "INVALID_PARAMS")


func Util_find_world(root: Node) -> WorldEnvironment:
	for n in root.find_children("*", "WorldEnvironment", true, false):
		if n.owner == root:
			return n
	return null


func test_env_preset_template_is_neutral_and_parses() -> void:
	var preset := _template_preset()
	assert_true(preset.has("environment"), "template has an environment section")
	var text := FileAccess.get_file_as_string(GenTools.PRESET_TEMPLATE).to_lower()
	for word in ["moss", "ruin", "vine"]:
		assert_false(text.contains(word), "the addon default holds no game-specific art concept (%s)" % word)
	var p: Variant = EnvTools.read_env_params({}, EnvTools.ENV_DEFAULTS)
	assert_false(Util_is_error(p), str(p))
	assert_eq(p.fog, false)
	assert_eq(p.tonemap, "filmic")


static func Util_is_error(v: Variant) -> bool:
	return v is Dictionary and v.get("status", "") == "error"


# --- characters (character_anim_setup) and asset_audit --------------------------

const CharacterTools := preload("res://addons/topdown_shooter_tools/handlers/character_tools.gd")
const AuditTools := preload("res://addons/topdown_shooter_tools/handlers/audit_tools.gd")
const CHAR_LIB := ASSET_KNOWN_DIR + "/" + ASSET_PREFIX + "humanoid.res"
## Mixamo-style rig: [bone, parent, rest offset].
const MIXAMO_BONES := [
	["mixamorig_Hips", "", Vector3(0, 1, 0)],
	["mixamorig_Spine", "mixamorig_Hips", Vector3(0, 0.1, 0)],
	["mixamorig_Spine1", "mixamorig_Spine", Vector3(0, 0.12, 0)],
	["mixamorig_Spine2", "mixamorig_Spine1", Vector3(0, 0.12, 0)],
	["mixamorig_Neck", "mixamorig_Spine2", Vector3(0, 0.15, 0)],
	["mixamorig_Head", "mixamorig_Neck", Vector3(0, 0.1, 0)],
	["mixamorig_HeadTop_End", "mixamorig_Head", Vector3(0, 0.2, 0)],
	["mixamorig_LeftShoulder", "mixamorig_Spine2", Vector3(0.05, 0.1, 0)],
	["mixamorig_LeftArm", "mixamorig_LeftShoulder", Vector3(0.12, 0, 0)],
	["mixamorig_LeftForeArm", "mixamorig_LeftArm", Vector3(0.25, 0, 0)],
	["mixamorig_LeftHand", "mixamorig_LeftForeArm", Vector3(0.25, 0, 0)],
	["mixamorig_LeftHandIndex1", "mixamorig_LeftHand", Vector3(0.08, 0, 0)],
	["mixamorig_RightShoulder", "mixamorig_Spine2", Vector3(-0.05, 0.1, 0)],
	["mixamorig_RightArm", "mixamorig_RightShoulder", Vector3(-0.12, 0, 0)],
	["mixamorig_RightForeArm", "mixamorig_RightArm", Vector3(-0.25, 0, 0)],
	["mixamorig_RightHand", "mixamorig_RightForeArm", Vector3(-0.25, 0, 0)],
	["mixamorig_LeftUpLeg", "mixamorig_Hips", Vector3(0.1, -0.05, 0)],
	["mixamorig_LeftLeg", "mixamorig_LeftUpLeg", Vector3(0, -0.45, 0)],
	["mixamorig_LeftFoot", "mixamorig_LeftLeg", Vector3(0, -0.42, 0)],
	["mixamorig_LeftToeBase", "mixamorig_LeftFoot", Vector3(0, -0.05, 0.1)],
	["mixamorig_RightUpLeg", "mixamorig_Hips", Vector3(-0.1, -0.05, 0)],
	["mixamorig_RightLeg", "mixamorig_RightUpLeg", Vector3(0, -0.45, 0)],
	["mixamorig_RightFoot", "mixamorig_RightLeg", Vector3(0, -0.42, 0)],
	["mixamorig_RightToeBase", "mixamorig_RightFoot", Vector3(0, -0.05, 0.1)],
]


func test_character_bone_map_guess() -> void:
	var names: Array = MIXAMO_BONES.map(func(b): return b[0])
	var parents: Array = []
	for b in MIXAMO_BONES:
		parents.append(names.find(b[1]))
	var guess := CharacterTools.auto_bone_map(names, parents)
	assert_eq(guess.missing, [], str(guess))
	assert_eq(guess.map.Hips, "mixamorig_Hips")
	assert_eq(guess.map.Spine, "mixamorig_Spine")
	assert_eq(guess.map.Chest, "mixamorig_Spine1")
	assert_eq(guess.map.UpperChest, "mixamorig_Spine2")
	assert_eq(guess.map.LeftUpperArm, "mixamorig_LeftArm")
	assert_eq(guess.map.RightLowerArm, "mixamorig_RightForeArm")
	assert_eq(guess.map.LeftUpperLeg, "mixamorig_LeftUpLeg")
	assert_eq(guess.map.LeftLowerLeg, "mixamorig_LeftLeg")
	assert_eq(guess.map.RightToes, "mixamorig_RightToeBase")
	assert_eq(guess.map.LeftIndexProximal, "mixamorig_LeftHandIndex1")
	assert_false(guess.map.values().has("mixamorig_HeadTop_End"), "end bones stay unmapped")
	## Unreal-style names, with the Mixamo-in-FBX colon form too.
	var ue := ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head", "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
		"clavicle_r", "upperarm_r", "lowerarm_r", "hand_r", "thigh_l", "calf_l", "foot_l", "ball_l", "thigh_r", "calf_r", "foot_r", "ball_r", "thumb_01_l"]
	var ue_parents := [-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20, 9]
	var g2 := CharacterTools.auto_bone_map(ue, ue_parents)
	assert_eq(g2.missing, [], str(g2))
	assert_eq(g2.map.UpperChest, "spine_03")
	assert_eq(g2.map.LeftLowerLeg, "calf_l")
	assert_eq(g2.map.LeftThumbMetacarpal, "thumb_01_l")
	assert_eq(CharacterTools.auto_bone_map(["mixamorig:Hips", "Bone", "Bone.001"], [-1, 0, 1]).missing.size(), CharacterTools.REQUIRED_BONES.size() - 1, "only Hips found")
	## Roles from download names.
	for case in [["Rifle Idle", "idle"], ["Walking", "walk"], ["Rifle Run", "run"], ["Sprinting Forward Roll", "dodge"], ["Firing Rifle", "fire"],
			["Reloading", "reload"], ["Hit Reaction", "hit"], ["Dying", "death"], ["Walking Backwards", "walk_back"], ["Left Strafe Walking", "strafe_left"],
			["Rifle Aiming Idle", "aim"], ["Zombie Punching", "attack"], ["RifleWalk", "walk"], ["mixamo.com", ""]]:
		assert_eq(CharacterTools.guess_role(case[0]), case[1], case[0])
	assert_eq(CharacterTools._file_id("Rifle Walk (1).fbx"), "rifle_walk_1")


func test_character_sources_in_gdignore_folder_are_copied() -> void:
	## asset_sources/ has .gdignore: Godot never imports files there, so
	## character_anim_setup must copy them in instead of waiting for an import.
	var dir := "res://zz_mcp_test_ignored"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/mixamo"))
	var f := FileAccess.open(dir + "/.gdignore", FileAccess.WRITE)
	f.close()
	assert_false(CharacterTools.godot_imports(dir + "/mixamo/Rifle Idle.fbx"), "file under a .gdignore folder")
	assert_false(CharacterTools.godot_imports("/Users/me/Downloads/Rifle Idle.fbx"), "file outside res://")
	assert_false(CharacterTools.godot_imports("res://.hidden/a.fbx"), "hidden folder")
	assert_true(CharacterTools.godot_imports("res://assets/characters/a.fbx"), "normal project file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/.gdignore"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/mixamo"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func test_character_params_rejected() -> void:
	var chars := CharacterTools.new()
	assert_is_error(chars.character_anim_setup({}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "boss"}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "enemy"}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "player", "colour": 1}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "player", "weapon_follow": "teeth"}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "player", "walk_speed": 5, "run_speed": 4}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "player", "clips": {"dance": "x"}}), "INVALID_PARAMS")
	assert_is_error(chars.character_anim_setup({"target": "player", "scene": WORK_DIR + "/nope.tscn"}), "INVALID_PARAMS")


func test_character_tree_build() -> void:
	var bt := CharacterTools.build_tree(["idle", "walk", "run", "fire", "reload", "death"], 1.6, 4.0, false, true)
	for n in ["locomotion", "loco_speed", "fire", "fire_clip", "fire_speed", "reload", "life", "death_clip"]:
		assert_true(bt.has_node(n), "node %s" % n)
	for n in ["aim", "hit", "dodge", "attack"]:
		assert_false(bt.has_node(n), "no %s without its clip" % n)
	var loco := bt.get_node("locomotion") as AnimationNodeBlendSpace1D
	assert_true(loco != null and loco.get_blend_point_count() == 3, "idle/walk/run on speed")
	assert_eq(loco.get_blend_point_position(2), 4.0)
	var fire := bt.get_node("fire") as AnimationNodeOneShot
	assert_true(fire.filter_enabled and fire.is_path_filtered(NodePath("%GeneralSkeleton:RightHand")), "fire moves the arms")
	assert_false(fire.is_path_filtered(NodePath("%GeneralSkeleton:LeftUpperLeg")), "not the legs")
	var dir := CharacterTools.build_tree(["idle", "walk", "walk_back", "strafe_left", "strafe_right"], 1.6, 4.0, true, true)
	assert_true(dir.get_node("locomotion") is AnimationNodeBlendSpace2D, "strafes -> 2D")
	assert_eq((dir.get_node("locomotion") as AnimationNodeBlendSpace2D).get_blend_point_count(), 5)
	var idle_only := CharacterTools.build_tree(["idle"], 1.6, 4.0, false, true)
	assert_true(idle_only.get_node("locomotion") is AnimationNodeAnimation)


## A Mixamo-style skinned rig (capsule bound to Hips) with one clip, exported
## to a .glb. walk: Hips moves forward; death: falls.
func _export_rig(abs_path: String, clip: String = "") -> String:
	var root := Node3D.new()
	root.name = "Rig"
	var arm := Node3D.new()
	arm.name = "Armature"
	root.add_child(arm)
	arm.owner = root
	var sk := Skeleton3D.new()
	sk.name = "Skeleton3D"
	arm.add_child(sk)
	sk.owner = root
	for b in MIXAMO_BONES:
		var i := sk.add_bone(b[0])
		if b[1] != "":
			sk.set_bone_parent(i, sk.find_bone(b[1]))
		sk.set_bone_rest(i, Transform3D(Basis(), b[2]))
	sk.reset_bone_poses()
	var cap := CapsuleMesh.new()
	cap.height = 1.8
	cap.radius = 0.3
	var arrays := cap.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for v in verts.size():
		verts[v].y += 0.9
		bones.append_array([0, 0, 0, 0])
		weights.append_array([1.0, 0.0, 0.0, 0.0])
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = am
	sk.add_child(mi)
	mi.owner = root
	mi.skeleton = NodePath("..")
	mi.skin = sk.create_skin_from_rest_transforms()
	if not clip.is_empty():
		var ap := AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		root.add_child(ap)
		ap.owner = root
		var anim := Animation.new()
		anim.length = 1.0
		var t := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(t, "Armature/Skeleton3D:mixamorig_Hips")
		anim.position_track_insert_key(t, 0.0, Vector3(0, 1, 0))
		anim.position_track_insert_key(t, 1.0, Vector3(0, 0.3 if clip == "death" else 0.95, 0 if clip == "death" else 1.5))
		var r := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(r, "Armature/Skeleton3D:mixamorig_LeftArm")
		anim.rotation_track_insert_key(r, 0.0, Quaternion())
		anim.rotation_track_insert_key(r, 1.0, Quaternion(Vector3.FORWARD, 0.8))
		var lib := AnimationLibrary.new()
		lib.add_animation("mixamo.com", anim)
		ap.add_animation_library("", lib)
	## The glTF writer needs the skeleton in the tree to export joints.
	var host := (Engine.get_main_loop() as SceneTree).root
	host.add_child(root)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	assert_eq(doc.append_from_scene(root, state), OK, "gltf append")
	assert_eq(doc.write_to_filesystem(state, abs_path), OK, "gltf write")
	host.remove_child(root)
	root.free()
	return abs_path


func _char_downloads() -> String:
	return ProjectSettings.globalize_path("user://zz_mcp_test_downloads")


func _remove_char_test_files() -> void:
	_remove_asset_test_files()
	_remove_tree(_char_downloads())


func test_character_anim_setup_retargets_builds_tree_and_animator() -> void:
	_remove_char_test_files()
	var made := _tools.player_scaffold(_player_params({"add_to_scene": false}))
	assert_has_key(made, "data", str(made))
	var scene: String = made.data.scene_path
	## The model in a folder the editor knows (imports at once in tests).
	var model := ASSET_KNOWN_DIR + "/" + ASSET_PREFIX + "hero.glb"
	_export_rig(ProjectSettings.globalize_path(model))
	var downloads := _char_downloads()
	for spec in [["Rifle Idle", "idle"], ["Walking", "walk"], ["Dying", "death"], ["Firing Rifle", "fire"], ["Thriller Part 3", "walk"]]:
		_export_rig(downloads.path_join(ASSET_PREFIX + spec[0] + ".glb"), spec[1])
	var params := {"target": "player", "scene": scene, "model": model, "animations": [downloads], "library": CHAR_LIB,
		"anim_dir": ASSET_KNOWN_DIR, "script_dir": WORK_DIR + "/scripts", "clips": {"run": ASSET_PREFIX + "Thriller Part 3"}}

	var dry := CharacterTools.new().character_anim_setup(params.merged({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.animations.size(), 5)
	assert_false(FileAccess.file_exists(CHAR_LIB), "dry run writes nothing")

	var result := CharacterTools.new().character_anim_setup(params)
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.roles, ["idle", "walk", "run", "fire", "death"], str(data))
	assert_true(data.retargeted.has(model), "model retargeted: %s" % str(data.retargeted))
	assert_eq(data.copied.size(), 5, "clips copied in: %s" % str(data.copied))
	## The model: renamed bones under %GeneralSkeleton, bone map in .import.
	var info := CharacterTools.skeleton_info(model)
	assert_true(info.retargeted, str(info))
	assert_true(info.bones.has("LeftUpperArm") and info.bones.has("RightHand"), str(info.bones))
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(model + ".import"), OK)
	assert_true(str(cfg.get_value("params", "_subresources")).contains("retarget/bone_map"), "bone map in the import settings")
	assert_true(FileAccess.file_exists(CharacterTools.bone_map_path(model)))
	## The library: skeleton tracks only, in place, loops.
	var lib := load(CHAR_LIB) as AnimationLibrary
	assert_true(lib != null and lib.has_animation("walk") and lib.has_animation("death"))
	var walk := lib.get_animation("walk")
	assert_eq(walk.loop_mode, Animation.LOOP_LINEAR)
	assert_eq(lib.get_animation("death").loop_mode, Animation.LOOP_NONE)
	for t in walk.get_track_count():
		assert_true(String(walk.track_get_path(t)).begins_with("%GeneralSkeleton:"), str(walk.track_get_path(t)))
	var hips := walk.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
	assert_true(hips >= 0, "hips track")
	var first: Vector3 = walk.track_get_key_value(hips, 0)
	var last: Vector3 = walk.track_get_key_value(hips, walk.track_get_key_count(hips) - 1)
	assert_true(absf(last.z - first.z) < 0.0001 and absf(last.x - first.x) < 0.0001, "in place: %s -> %s" % [first, last])

	## The scene: model swapped under Aim, tree and animator added.
	var player := (ResourceLoader.load(scene, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_true(player.get_node_or_null("Aim/BodySkin/Model") != null, "model swapped in")
	assert_false((player.get_node("Body") as Node3D).visible)
	var tree := player.get_node_or_null("AnimationTree") as AnimationTree
	assert_true(tree != null, "AnimationTree added")
	assert_eq(String(tree.root_node), "../Aim/BodySkin/Model")
	assert_true(tree.get_node(tree.root_node).get_node_or_null("%GeneralSkeleton") is Skeleton3D, "tracks resolve from the tree's root node")
	assert_true(tree.has_animation_library("humanoid"))
	assert_true((tree.tree_root as AnimationNodeBlendTree).has_node("fire"))
	var animator := player.get_node_or_null("CharacterAnimator")
	assert_true(animator != null, "animator added")
	assert_eq(animator.get("roles"), PackedStringArray(["idle", "walk", "run", "fire", "death"]))
	assert_eq(String(animator.get("weapon_mount_path")), "../Aim/WeaponMount")
	assert_eq(String(animator.get("hand_bone")), "RightHand")
	player.free()

	## Rerun with no new clips: files unchanged, nodes replaced (not doubled).
	var again := CharacterTools.new().character_anim_setup({"target": "player", "scene": scene, "model": model, "library": CHAR_LIB, "script_dir": WORK_DIR + "/scripts"})
	assert_has_key(again, "data", str(again))
	assert_eq(again.data.swap.status, "kept")
	assert_eq(again.data.retargeted, [], "already retargeted")
	var p2 := (ResourceLoader.load(scene, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq(p2.get_children().filter(func(c): return String(c.name).begins_with("AnimationTree")).size(), 1)
	p2.free()
	## Undo the scene edit: the tree is gone again.
	assert_true(_global_ur().undo(), "undo the scene edit")
	var p3 := (ResourceLoader.load(scene, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_true(p3.get_node_or_null("AnimationTree") != null, "the first run's tree is back (undo restores the file as it was)")
	p3.free()
	_remove_char_test_files()


func test_character_animator_drives_tree() -> void:
	_remove_char_test_files()
	var model := ASSET_KNOWN_DIR + "/" + ASSET_PREFIX + "hero.glb"
	_export_rig(ProjectSettings.globalize_path(model))
	var downloads := _char_downloads()
	for spec in [["Idle", "idle"], ["Walking", "walk"], ["Running", "walk"], ["Dying", "death"], ["Hit Reaction", "walk"]]:
		_export_rig(downloads.path_join(ASSET_PREFIX + spec[0] + ".glb"), spec[1])
	var made := _tools.player_scaffold(_player_params({"add_to_scene": false}))
	var result := CharacterTools.new().character_anim_setup({"target": "player", "scene": made.data.scene_path, "model": model, "animations": [downloads],
		"library": CHAR_LIB, "anim_dir": ASSET_KNOWN_DIR, "script_dir": WORK_DIR + "/scripts"})
	assert_has_key(result, "data", str(result))
	## A @tool copy of the animator runs in the editor on a stand-in body.
	var src := FileAccess.get_file_as_string(WORK_DIR + "/scripts/character_animator.gd")
	var script := GDScript.new()
	script.source_code = "@tool\n" + src
	assert_eq(script.reload(), OK, "animator compiles")
	var body := CharacterBody3D.new()
	body.name = "AnimTestBody"
	body.add_user_signal("died")
	body.add_user_signal("health_changed", [{"name": "current", "type": TYPE_FLOAT}, {"name": "maximum", "type": TYPE_FLOAT}])
	var aim := Node3D.new()
	aim.name = "Aim"
	body.add_child(aim)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	mount.position = Vector3(0, 1.2, -0.5)
	aim.add_child(mount)
	var skin := Node3D.new()
	skin.name = "BodySkin"
	aim.add_child(skin)
	var inst := (load(model) as PackedScene).instantiate()
	inst.name = "Model"
	skin.add_child(inst)
	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	tree.add_animation_library("humanoid", load(CHAR_LIB))
	tree.tree_root = CharacterTools.build_tree(result.data.roles, 1.6, 4.0, false, true)
	tree.root_node = NodePath("../Aim/BodySkin/Model")
	body.add_child(tree)
	var animator := Node.new()
	animator.name = "CharacterAnimator"
	animator.set_script(script)
	animator.set("roles", PackedStringArray(result.data.roles))
	body.add_child(animator)
	_root().add_child(body)
	_added.append(body)
	assert_true(result.data.roles.has("hit"), str(result.data.roles))
	body.velocity = Vector3(0, 0, -3)
	for i in 20:
		animator._process(0.1)
	assert_true(absf(float(tree.get("parameters/locomotion/blend_position")) - 3.0) < 0.05, "speed drives the blend: %s" % tree.get("parameters/locomotion/blend_position"))
	var hand_skel := inst.get_node("%GeneralSkeleton") as Skeleton3D
	var hand: Transform3D = hand_skel.global_transform * hand_skel.get_bone_global_pose(hand_skel.find_bone("RightHand"))
	assert_true(mount.global_position.distance_to(hand.origin) < 0.001, "weapon mount in the hand: %s vs %s" % [mount.global_position, hand.origin])
	body.emit_signal("health_changed", 100.0, 100.0)
	body.emit_signal("health_changed", 80.0, 100.0)
	assert_eq(int(tree.get("parameters/hit/request")), AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE, "damage plays the hit clip")
	body.emit_signal("died")
	tree.advance(0.05)
	assert_eq(String(tree.get("parameters/life/current_state")), "dead", "died -> death clip")
	body.velocity = Vector3.ZERO
	_remove_char_test_files()


func test_asset_audit_reports_placeholders_items_and_characters() -> void:
	var made := _tools.player_scaffold(_player_params({"add_to_scene": false}))
	assert_has_key(made, "data", str(made))
	var audit := AuditTools.new()
	assert_is_error(audit.asset_audit({"checks": ["vibes"]}), "INVALID_PARAMS")
	assert_is_error(audit.asset_audit({"scenes": ["res://nope.tscn"]}), "INVALID_PARAMS")
	var report := audit.asset_audit({"scenes": [made.data.scene_path], "checks": ["placeholders", "characters"]})
	assert_has_key(report, "data", str(report))
	var data: Dictionary = report.data
	assert_true(int(data.summary.placeholders_by_kind.get("character", 0)) >= 1, str(data.summary))
	assert_eq(data.characters[0].status, "placeholder")
	assert_true(String(data.characters[0].fix).contains("character_anim_setup"))
	assert_false(data.clean)
	## After a swap the capsule no longer counts; the model needs animation.
	var model := _save_model(_box_model(Vector3(0.6, 2.0, 0.4), Vector3(0, 1.0, 0)), MODEL_DIR + "/audit_hero.tscn")
	var swapped := _swap.swap_placeholder({"target": "player", "scene": made.data.scene_path, "model": model})
	assert_has_key(swapped, "data", str(swapped))
	assert_true(String(swapped.data.get("next", "")).contains("character_anim_setup"), "swap points to the animation step: %s" % str(swapped.data))
	var after: Dictionary = audit.asset_audit({"scenes": [made.data.scene_path], "checks": ["placeholders", "characters"]}).data
	assert_eq(int(after.summary.placeholders_by_kind.get("character", 0)), 0, str(after.summary))
	assert_eq(after.characters[0].status, "model_without_animation")
	## Items: the test item sheet has no icons or models.
	var items := _items.item_db_import(_item_params())
	assert_has_key(items, "data", str(items))
	var it: Dictionary = audit.asset_audit({"checks": ["items"], "database_path": ITEM_DIR + "/item_database.tres"}).data
	assert_true(int(it.summary.items_without_icon) > 0 and int(it.summary.items_without_icon) == int(it.summary.items), str(it))
	## Budget: an over-budget box in a kind folder is flagged.
	var budget_dir := WORK_DIR + "/audit_assets/items/big"
	var big := _box_model(Vector3(0.3, 0.3, 0.3), Vector3(0, 0.15, 0))
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radial_segments = 128
	sm.rings = 64
	sphere.mesh = sm
	big.add_child(sphere)
	sphere.owner = big
	var packed_path := _save_model(big, budget_dir + "/big.tscn")
	assert_true(FileAccess.file_exists(packed_path))
	var over: Variant = AuditTools._audit_budget(WORK_DIR + "/audit_assets", ["tscn"])
	assert_eq(over.over.size(), 1, str(over))
	assert_eq(over.over[0].kind, "item")
	assert_eq(AuditTools._kind_of(WORK_DIR + "/audit_assets/items/big/big.glb", WORK_DIR + "/audit_assets"), "item")
	assert_eq(AuditTools._kind_of(WORK_DIR + "/audit_assets/env/wall.glb", WORK_DIR + "/audit_assets"), "prop")

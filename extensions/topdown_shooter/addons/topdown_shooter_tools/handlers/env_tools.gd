@tool
extends RefCounted

## polyhaven_fetch and environment_setup: the environment half of the asset
## pipeline.
##
##   polyhaven_fetch     downloads a CC0 texture set or HDRI from Poly Haven's
##                       public API (no key). Textures go to
##                       res://assets/materials/<name>/ with their .import
##                       settings (normal maps flagged) and a material
##                       <name>.tres (world-space triplanar, so stretched
##                       blockout boxes and modular kit pieces never smear it).
##                       HDRIs go to res://assets/hdri/<name>.hdr. search=...
##                       lists matching assets instead. Every fetch is
##                       recorded in res://asset_sources/polyhaven/<name>.json
##                       (id, authors, license, files).
##   environment_setup   adds or updates the open scene's WorldEnvironment
##                       and sun: sky (an HDRI or a plain procedural sky),
##                       ambient light, tonemap, SSAO, depth/height fog,
##                       volumetric fog. The Environment is saved to a shared
##                       .tres (default res://assets/environment/
##                       world_environment.tres) so the raid map and the
##                       hideout use the same one.
##
## Art direction never lives here: every value comes from the call, else
## the project's res://assets/style_preset.json "environment" section, else
## a neutral default.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const GenHttp := preload("res://addons/topdown_shooter_tools/handlers/gen_http.gd")

const API := "https://api.polyhaven.com"
## Poly Haven asks API users for an identifying User-Agent.
const USER_AGENT := "User-Agent: godot-ai-topdown-shooter-tools/1.0"
const MATERIAL_DIR := "res://assets/materials"
const HDRI_DIR := "res://assets/hdri"
const RECORD_DIR := "res://asset_sources/polyhaven"
const ENVIRONMENT_PATH := "res://assets/environment/world_environment.tres"
const PRESET_PATH := "res://assets/style_preset.json"
const PRESET_TEMPLATE := "res://addons/topdown_shooter_tools/templates/style_preset.json.tmpl"
const RESOLUTIONS := ["1k", "2k", "4k", "8k"]
const TYPES := ["auto", "texture", "hdri"]
## Poly Haven's /info "type": 0 hdri, 1 texture, 2 model.
const TYPE_CODES := {0: "hdri", 1: "texture", 2: "model"}
## Our map name -> Poly Haven map keys, most wanted first.
const TEXTURE_MAPS := {
	"albedo": ["Diffuse", "diff", "Color", "albedo"],
	"normal": ["nor_gl", "Normal", "normal"],
	"normal_dx": ["nor_dx"],
	"arm": ["arm"],
	"roughness": ["Rough", "rough", "roughness"],
	"ao": ["AO", "ao"],
	"metal": ["Metal", "metal", "metallic"],
}
const IMAGE_FORMATS := ["jpg", "png"]
const MAX_TOTAL_BYTES := 250 * 1024 * 1024
const SEARCH_LIMIT := 20
const IMPORT_WAIT_MSEC := 60000
const REPLY_MARGIN_MSEC := 5000
const TONEMAPS := {"linear": 0, "reinhard": 1, "filmic": 2, "aces": 3, "agx": 4}
const BACKGROUNDS := ["sky", "color"]

## Neutral defaults; a project's style_preset.json "environment" section
## overrides any of them (and the call overrides that).
const ENV_DEFAULTS := {
	"hdri": "",
	"background": "sky",
	"background_color": [0.3, 0.3, 0.32],
	"sky_energy": 1.0,
	"ambient_energy": 1.0,
	"tonemap": "filmic",
	"exposure": 1.0,
	"ssao": true,
	"ssao_intensity": 2.0,
	"glow": false,
	"fog": false,
	"fog_color": [0.7, 0.72, 0.75],
	"fog_density": 0.01,
	"fog_sky_affect": 1.0,
	"fog_height": 0.0,
	"fog_height_density": 0.0,
	"volumetric_fog": false,
	"volumetric_fog_density": 0.03,
	"volumetric_fog_albedo": [0.85, 0.85, 0.85],
	"volumetric_fog_length": 64.0,
	"sun": true,
	"sun_color": [1.0, 1.0, 1.0],
	"sun_energy": 1.0,
	"sun_pitch": -55.0,
	"sun_yaw": 30.0,
	"sun_shadows": true,
}

## Sends the HTTP requests; tests put a fake with request()/download() here.
var transport: Object = GenHttp.new()
## Test hook: false skips the editor import (tests write into folders the
## test runner should not scan).
var trigger_import := true
var _busy := false


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


# =============================================================================
# polyhaven_fetch
# =============================================================================

func polyhaven_fetch(params: Dictionary, ctx = null) -> Dictionary:
	var p: Variant = read_fetch_params(params)
	if Util.is_error(p):
		return p
	if _busy:
		return Util.error(Util.EDITOR_NOT_READY, "another polyhaven_fetch is running; wait for it to finish")
	var fn := _search_async.bind(p) if not p.search.is_empty() else _fetch_async.bind(p, ctx)
	return _run(ctx, fn)


static func read_fetch_params(params: Dictionary) -> Variant:
	var allowed := ["asset", "search", "type", "resolution", "name", "tile_meters", "triplanar", "tint", "overwrite", "dry_run", "material_dir", "hdri_dir"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var p := {}
	for spec in [["asset", ""], ["search", ""], ["type", "auto"], ["resolution", "1k"], ["name", ""], ["material_dir", MATERIAL_DIR], ["hdri_dir", HDRI_DIR]]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var tile: Variant = Util.num(params, "tile_meters", 2.0, 0.05, 100.0)
	var triplanar: Variant = Util.boolean(params, "triplanar", true)
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var dry: Variant = Util.boolean(params, "dry_run", false)
	for v in [tile, triplanar, overwrite, dry]:
		if Util.is_error(v):
			return v
	p["tile_meters"] = tile
	p["triplanar"] = triplanar
	p["overwrite"] = overwrite
	p["dry_run"] = dry
	var tint: Variant = read_color(params, "tint", null)
	if Util.is_error(tint):
		return tint
	p["tint"] = tint
	if not p.type in TYPES:
		return Util.error(Util.INVALID_PARAMS, "'type' must be one of %s" % ", ".join(TYPES))
	if not p.resolution in RESOLUTIONS:
		return Util.error(Util.INVALID_PARAMS, "'resolution' must be one of %s" % ", ".join(RESOLUTIONS))
	if p.search.is_empty():
		if p.asset.is_empty():
			return Util.error(Util.INVALID_PARAMS, "pass asset=<Poly Haven id> (e.g. concrete_wall_008), or search=<words> to list ids")
		if not AssetTools.is_asset_id(p.asset):
			return Util.error(Util.INVALID_PARAMS, "'asset' must be a Poly Haven id (lowercase letters, digits, _), got '%s'" % p.asset)
		if p.name.is_empty():
			p.name = p.asset
		if not AssetTools.is_asset_id(p.name):
			return Util.error(Util.INVALID_PARAMS, "'name' must be lowercase letters, digits and _ (it names the folder and files)")
	for key in ["material_dir", "hdri_dir"]:
		p[key] = Util.clean_dir(p[key])
		var reason := Util.check_res_path(p[key])
		if not reason.is_empty():
			return Util.error(Util.INVALID_PARAMS, reason)
	return p


func _search_async(p: Dictionary) -> Dictionary:
	var kinds: Array = ["texture", "hdri"] if p.type == "auto" else [p.type]
	var words: PackedStringArray = String(p.search).to_lower().split(" ", false)
	var hits: Array = []
	for kind in kinds:
		var res: Dictionary = await transport.request(_get_request(API + "/assets?type=%s" % ("textures" if kind == "texture" else "hdris")), 30.0)
		if res.code != 200 or not res.json is Dictionary:
			return _http_error("search", res)
		for id in res.json:
			var info: Variant = res.json[id]
			if not info is Dictionary:
				continue
			var hay := " ".join([String(id), String(info.get("name", "")), " ".join(info.get("tags", [])), " ".join(info.get("categories", []))]).to_lower()
			var score := 0
			for w in words:
				if hay.contains(w):
					score += 2 if String(id).contains(w) else 1
			if score > 0:
				hits.append({"id": id, "type": kind, "name": info.get("name", id), "categories": info.get("categories", []),
					"tags": info.get("tags", []).slice(0, 8), "score": score, "downloads": int(info.get("download_count", 0))})
	hits.sort_custom(func(a, b): return a.score > b.score or (a.score == b.score and a.downloads > b.downloads))
	var out: Array = []
	for h in hits.slice(0, SEARCH_LIMIT):
		h.erase("score")
		out.append(h)
	return {"data": {"search": p.search, "matches": hits.size(), "results": out,
		"next": "polyhaven_fetch asset=<id> (dry_run=true shows the files first). Browse: https://polyhaven.com/textures"}}


func _fetch_async(p: Dictionary, ctx) -> Dictionary:
	## 1. What it is.
	var kind: String = p.type
	var info := {}
	var res: Dictionary = await transport.request(_get_request(API + "/info/" + p.asset), 20.0)
	if res.code == 404 or (res.code == 200 and not res.json is Dictionary):
		return Util.error(Util.INVALID_PARAMS, "Poly Haven has no asset '%s'; try polyhaven_fetch search=<words>" % p.asset)
	if res.code != 200:
		return _http_error("info", res)
	info = res.json
	var actual: String = TYPE_CODES.get(int(info.get("type", -1)), "unknown")
	if kind == "auto":
		kind = actual
	if kind != actual:
		return Util.error(Util.INVALID_PARAMS, "'%s' is a %s on Poly Haven, not a %s" % [p.asset, actual, kind])
	if not kind in ["texture", "hdri"]:
		return Util.error(Util.INVALID_PARAMS, "'%s' is a %s; polyhaven_fetch takes textures and HDRIs (models: download the .glb and use asset_import)" % [p.asset, kind])

	## 2. Which files.
	res = await transport.request(_get_request(API + "/files/" + p.asset), 30.0)
	if res.code != 200 or not res.json is Dictionary:
		return _http_error("files", res)
	var plan: Variant = plan_files(res.json, kind, p)
	if Util.is_error(plan):
		return plan
	var targets: Array = plan.targets
	for t in targets:
		if FileAccess.file_exists(t) and not p.overwrite:
			return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass overwrite=true to replace it (one undo step restores it), or a different name" % t)
	var report := {
		"asset": p.asset, "type": kind, "name": p.name, "resolution": plan.resolution,
		"files": plan.downloads.map(func(d): return {"map": d.map, "path": d.path, "bytes": d.bytes}),
		"total_mb": snappedf(plan.total_bytes / 1048576.0, 0.1),
		"license": "CC0 (Poly Haven)", "authors": info.get("authors", {}).keys() if info.get("authors") is Dictionary else [],
	}
	if kind == "texture":
		report["material"] = plan.material
		report["material_type"] = plan.material_class
		report["tile_meters"] = p.tile_meters
	if not plan.notes.is_empty():
		report["notes"] = plan.notes
	if p.dry_run:
		report["dry_run"] = true
		return {"data": report}

	## 3. Download (all or nothing).
	_busy = true
	var before := ItemTools.FileSnapshot.capture(targets)
	for d in plan.downloads:
		var got: Dictionary = await transport.download(d.url, ProjectSettings.globalize_path(d.path), 120.0)
		if not got.get("ok", false):
			before.restore()
			_busy = false
			return Util.error(Util.INTERNAL_ERROR, "%s: %s; nothing was kept" % [d.url.get_file(), got.get("error", "download failed")])
	## 4. Import settings, material, record.
	for d in plan.downloads:
		if d.has("import"):
			var err := write_texture_import(d.path, d.import)
			if not err.is_empty():
				before.restore()
				_busy = false
				return Util.error(Util.INTERNAL_ERROR, err)
	if kind == "texture":
		var f := FileAccess.open(plan.material, FileAccess.WRITE)
		if f == null:
			before.restore()
			_busy = false
			return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [plan.material, error_string(FileAccess.get_open_error())])
		f.store_string(material_text(plan, p))
		f.close()
	_write_record(plan.record, p, kind, info, plan)
	var after := ItemTools.FileSnapshot.capture(targets)
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Poly Haven %s" % p.name, UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(before, "restore")
		ur.commit_action(false)
	report["undo"] = "One editor undo step (Edit > Undo) removes these files (or puts the old ones back)."

	## 5. Import (deferred calls wait for it).
	var images: Array = plan.downloads.map(func(d): return d.path)
	var imported := false
	if trigger_import and Engine.is_editor_hint():
		_start_import(images)
		if ctx != null and ctx.has_method("send_deferred"):
			imported = await _wait_imported(images, _deadline(ctx))
	_busy = false
	if kind == "texture":
		if plan.material_class != "":
			var role := guess_kit_role(p.asset)
			report["next"] = "swap_placeholder target=kit materials={\"%s\": \"%s\"} (kit roles: wall, floor, cover, trim; or style_preset.json environment.kit_materials), or drag %s onto a mesh" % [role, p.name, plan.material]
	else:
		report["hdri"] = plan.hdri
		report["next"] = "environment_setup hdri=%s" % plan.hdri
	report["imported"] = imported
	if not imported:
		report["note"] = "The editor imports the files on its next scan (focus the Godot window). The material works once they are imported."
	return {"data": report}


## The kit role a texture most likely fits, from its id (only a hint).
static func guess_kit_role(asset_id: String) -> String:
	var id := asset_id.to_lower()
	for word in ["floor", "ground", "tile", "pavement", "asphalt", "road", "dirt", "gravel", "soil"]:
		if id.contains(word):
			return "floor"
	for word in ["metal", "rust", "wood", "plank", "crate", "plastic"]:
		if id.contains(word):
			return "cover"
	return "wall"


## Registers a just-saved resource's UID with the running editor, so a
## scene that references it right away resolves it by UID (no "invalid
## UID, using text path" warning before the next file scan).
static func register_uid(path: String) -> void:
	var uid := ResourceLoader.get_resource_uid(path)
	if uid == ResourceUID.INVALID_ID:
		return
	if ResourceUID.has_id(uid):
		ResourceUID.set_id(uid, path)
	else:
		ResourceUID.add_id(uid, path)


## Which files to download and where. {downloads: [{map, url, path, bytes,
## import?}], targets, material, material_class, record, hdri, notes,
## total_bytes, resolution} or an error.
static func plan_files(files: Dictionary, kind: String, p: Dictionary) -> Variant:
	var notes: Array[String] = []
	var downloads: Array = []
	var res: String = p.resolution
	var out := {"notes": notes, "resolution": res, "material": "", "material_class": "", "hdri": "", "maps": {}}
	if kind == "hdri":
		var table: Variant = files.get("hdri")
		if not table is Dictionary or table.is_empty():
			return Util.error(Util.INVALID_PARAMS, "Poly Haven lists no HDRI files for '%s'" % p.asset)
		var picked_res := _closest_resolution(table, res)
		if picked_res != res:
			notes.append("no %s file; using %s" % [res, picked_res])
		var by_format: Dictionary = table[picked_res]
		var fmt := "hdr" if by_format.has("hdr") else ("exr" if by_format.has("exr") else "")
		if fmt.is_empty():
			return Util.error(Util.INVALID_PARAMS, "no .hdr or .exr for '%s' at %s" % [p.asset, picked_res])
		var path: String = "%s/%s.%s" % [p.hdri_dir, p.name, fmt]
		downloads.append({"map": "hdri", "url": by_format[fmt].url, "path": path, "bytes": int(by_format[fmt].get("size", 0))})
		out.hdri = path
		out.resolution = picked_res
	else:
		var dir: String = "%s/%s" % [p.material_dir, p.name]
		for map in TEXTURE_MAPS:
			for key in TEXTURE_MAPS[map]:
				var table: Variant = files.get(key)
				if not table is Dictionary or table.is_empty():
					continue
				var picked_res := _closest_resolution(table, res)
				var by_format: Variant = table.get(picked_res)
				if not by_format is Dictionary:
					continue
				for fmt in IMAGE_FORMATS:
					if by_format.has(fmt) and by_format[fmt] is Dictionary and by_format[fmt].has("url"):
						var d := {"map": map, "url": String(by_format[fmt].url), "path": "%s/%s_%s.%s" % [dir, p.name, map, fmt],
							"bytes": int(by_format[fmt].get("size", 0)), "import": {"normal_map": map in ["normal", "normal_dx"]}}
						out.maps[map] = d
						if picked_res != res:
							notes.append("%s: no %s file; using %s" % [map, res, picked_res])
						break
				if out.maps.has(map):
					break
		if not out.maps.has("albedo"):
			return Util.error(Util.INVALID_PARAMS, "'%s' has no color (Diffuse) map in jpg/png at any resolution" % p.asset)
		## One normal map, OpenGL style (what Godot expects).
		if out.maps.has("normal"):
			out.maps.erase("normal_dx")
		elif out.maps.has("normal_dx"):
			notes.append("only a DirectX normal map exists; bumps may look inverted (green channel)")
		## ARM (AO, roughness, metal) packs three maps into one ORM texture.
		if out.maps.has("arm"):
			for m in ["roughness", "ao", "metal"]:
				out.maps.erase(m)
			out.material_class = "ORMMaterial3D"
		else:
			out.material_class = "StandardMaterial3D"
		for map in TEXTURE_MAPS:
			if out.maps.has(map):
				downloads.append(out.maps[map])
		out.material = "%s/%s.tres" % [dir, p.name]
	var total := 0
	for d in downloads:
		total += int(d.bytes)
	if total > MAX_TOTAL_BYTES:
		return Util.error(Util.INVALID_PARAMS, "the files are %d MB; pick a lower resolution" % int(total / 1048576.0))
	out["downloads"] = downloads
	out["total_bytes"] = total
	out["record"] = "%s/%s.json" % [RECORD_DIR, p.name]
	var targets: Array = []
	for d in downloads:
		targets.append(d.path)
		if d.has("import"):
			targets.append(d.path + ".import")
	if not out.material.is_empty():
		targets.append(out.material)
	out["targets"] = targets
	return out


## The resolution key closest to `wanted` that the table has (lower first).
static func _closest_resolution(table: Dictionary, wanted: String) -> String:
	if table.has(wanted):
		return wanted
	var order := RESOLUTIONS.duplicate()
	var at := order.find(wanted)
	for step in range(1, order.size()):
		for i in [at - step, at + step]:
			if i >= 0 and i < order.size() and table.has(order[i]):
				return order[i]
	return table.keys()[0]


## Writes <image>.import so the first import already gets the right flags
## (normal maps compressed as normal maps, VRAM compression, mipmaps).
static func write_texture_import(path: String, flags: Dictionary) -> String:
	var cfg := ConfigFile.new()
	var import_path := path + ".import"
	if FileAccess.file_exists(import_path):
		cfg.load(import_path)
	cfg.set_value("remap", "importer", "texture")
	cfg.set_value("remap", "type", "CompressedTexture2D")
	cfg.set_value("deps", "source_file", path)
	cfg.set_value("params", "compress/mode", 2)
	cfg.set_value("params", "compress/normal_map", 1 if flags.get("normal_map", false) else 2)
	cfg.set_value("params", "mipmaps/generate", true)
	cfg.set_value("params", "detect_3d/compress_to", 0)
	var err := cfg.save(import_path)
	return "" if err == OK else "cannot write %s: %s" % [import_path, error_string(err)]


## The material .tres as text: it can be written before the editor has
## imported the images (it only names them).
static func material_text(plan: Dictionary, p: Dictionary) -> String:
	var maps: Dictionary = plan.maps
	var ext: Array[String] = []
	var ids := {}
	var n := 0
	for map in TEXTURE_MAPS:
		if maps.has(map):
			n += 1
			ids[map] = "%d_%s" % [n, map]
			ext.append("[ext_resource type=\"Texture2D\" path=\"%s\" id=\"%s\"]" % [maps[map].path, ids[map]])
	var lines: Array[String] = []
	lines.append("[gd_resource type=\"%s\" load_steps=%d format=3]" % [plan.material_class, ext.size() + 1])
	lines.append("")
	lines.append_array(ext)
	lines.append("")
	lines.append("[resource]")
	lines.append("resource_name = \"%s\"" % p.name)
	if p.tint is Color:
		var c: Color = p.tint
		lines.append("albedo_color = Color(%s, %s, %s, 1)" % [c.r, c.g, c.b])
	lines.append("albedo_texture = ExtResource(\"%s\")" % ids.albedo)
	if plan.material_class == "ORMMaterial3D":
		lines.append("orm_texture = ExtResource(\"%s\")" % ids.arm)
		lines.append("metallic = 1.0")
	else:
		if ids.has("metal"):
			lines.append("metallic = 1.0")
			lines.append("metallic_texture = ExtResource(\"%s\")" % ids.metal)
		if ids.has("roughness"):
			lines.append("roughness_texture = ExtResource(\"%s\")" % ids.roughness)
		if ids.has("ao"):
			lines.append("ao_enabled = true")
			lines.append("ao_texture = ExtResource(\"%s\")" % ids.ao)
	var normal_id: String = ids.get("normal", ids.get("normal_dx", ""))
	if not normal_id.is_empty():
		lines.append("normal_enabled = true")
		lines.append("normal_texture = ExtResource(\"%s\")" % normal_id)
	var k := 1.0 / float(p.tile_meters)
	lines.append("uv1_scale = Vector3(%s, %s, %s)" % [k, k, k])
	if p.triplanar:
		lines.append("uv1_triplanar = true")
		lines.append("uv1_world_triplanar = true")
	return "\n".join(lines) + "\n"


static func _write_record(path: String, p: Dictionary, kind: String, info: Dictionary, plan: Dictionary) -> void:
	if not AssetTools.ensure_sources_dir(path.get_base_dir()).is_empty():
		return
	var record := {
		"source": "polyhaven", "id": p.asset, "type": kind, "name": info.get("name", p.asset),
		"url": "https://polyhaven.com/a/" + p.asset, "license": "CC0",
		"authors": info.get("authors", {}), "resolution": plan.resolution,
		"files": plan.downloads.map(func(d): return {"map": d.map, "path": d.path, "url": d.url}),
		"material": plan.material, "time": Time.get_datetime_string_from_system(false, true),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(record, "  "))
		f.close()


func _start_import(paths: Array) -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return
	var known := true
	for path in paths:
		if not AssetTools.folder_known(String(path).get_base_dir()):
			known = false
	if not known or efs.is_scanning() or efs.is_importing():
		## A new folder: one incremental scan (never a full scan()).
		if not efs.is_scanning():
			efs.scan_sources()
		return
	for path in paths:
		efs.update_file(path)
	efs.reimport_files(PackedStringArray(paths))


func _wait_imported(paths: Array, deadline: int) -> bool:
	var efs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	var stop := Time.get_ticks_msec() + IMPORT_WAIT_MSEC
	if deadline > 0:
		stop = mini(stop, deadline)
	var rescanned := false
	while Time.get_ticks_msec() < stop:
		if not efs.is_scanning() and not efs.is_importing():
			var all := true
			for path in paths:
				if not AssetTools._import_valid(path):
					all = false
			if all:
				return true
			if not rescanned:
				rescanned = true
				_start_import(paths)
		await tree.create_timer(0.25).timeout
	return false


static func _get_request(url: String) -> Dictionary:
	return {"method": "GET", "url": url, "headers": PackedStringArray([USER_AGENT, "Accept: application/json"])}


static func _http_error(step: String, res: Dictionary) -> Dictionary:
	if int(res.get("code", 0)) == 0:
		return Util.error(Util.INTERNAL_ERROR, "Poly Haven %s request failed: %s (offline, or api.polyhaven.com blocked?)" % [step, res.get("text", "")])
	return Util.error(Util.INTERNAL_ERROR, "Poly Haven %s request answered HTTP %d: %s" % [step, int(res.code), String(res.get("text", "")).left(200)])


# =============================================================================
# environment_setup
# =============================================================================

func environment_setup(params: Dictionary, _ctx = null) -> Dictionary:
	var root := Util.edited_root()
	if root == null or not root is Node3D:
		return Util.no_scene_error() if root == null else Util.error(Util.INVALID_PARAMS, "the open scene's root is a %s; open a 3D scene (the raid map or the hideout)" % root.get_class())
	var preset := environment_preset()
	if Util.is_error(preset):
		return preset
	var p: Variant = read_env_params(params, preset.values)
	if Util.is_error(p):
		return p
	var env: Variant = build_environment(p)
	if Util.is_error(env):
		return env
	var warnings: Array[String] = env.warnings

	## Where it goes: the scene's WorldEnvironment (or a new one) and sun.
	var world: WorldEnvironment = null
	if not p.node_path.is_empty():
		world = Util.resolve(p.node_path, root) as WorldEnvironment
		if world == null:
			return Util.error(Util.NODE_NOT_FOUND, "node_path '%s' is not a WorldEnvironment in the open scene" % p.node_path)
	else:
		for n in root.find_children("*", "WorldEnvironment", true, false):
			if n.owner == root:
				world = n
				break
	var sun: DirectionalLight3D = null
	for n in ([root] + root.find_children("*", "DirectionalLight3D", true, false)):
		if n is DirectionalLight3D and (n == root or n.owner == root):
			sun = n
			break
	for cam in root.find_children("*", "Camera3D", true, false):
		if (cam as Camera3D).environment != null:
			warnings.append("%s has its own environment, which overrides the WorldEnvironment for that camera" % Util.scene_path_of(cam, root))
	if ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus") != "forward_plus":
		if p.volumetric_fog or p.ssao:
			warnings.append("volumetric fog and SSAO need the Forward+ renderer (Project Settings > Rendering > Renderer); this project uses %s" % ProjectSettings.get_setting("rendering/renderer/rendering_method"))

	var report := {
		"scene": root.scene_file_path, "environment_path": p.environment_path,
		"world_environment": Util.scene_path_of(world, root) if world != null else "(new) WorldEnvironment",
		"sky": env.sky_desc, "values": p.report, "from_preset": preset.from,
	}
	if p.sun:
		report["sun"] = Util.scene_path_of(sun, root) if sun != null else "(new) Sun"
	if not warnings.is_empty():
		report["warnings"] = warnings
	if p.dry_run:
		report["dry_run"] = true
		return {"data": report}

	## Save the shared Environment, then point the scene at it.
	var environment: Environment = env.environment
	var before := ItemTools.FileSnapshot.capture([p.environment_path])
	var err := Util.save_resource(environment, p.environment_path)
	if not err.is_empty():
		before.restore()
		return Util.error(Util.INTERNAL_ERROR, err)
	var after := ItemTools.FileSnapshot.capture([p.environment_path])
	register_uid(p.environment_path)
	Util.refresh_filesystem([p.environment_path])

	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Environment setup", UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(after, "restore")
	ur.add_undo_method(before, "restore")
	if world == null:
		world = WorldEnvironment.new()
		world.name = "WorldEnvironment"
		world.environment = environment
		ur.add_do_method(root, "add_child", world, true)
		ur.add_do_method(world, "set_owner", root)
		ur.add_do_reference(world)
		ur.add_undo_method(root, "remove_child", world)
	else:
		ur.add_do_property(world, "environment", environment)
		ur.add_undo_property(world, "environment", world.environment)
	if p.sun:
		var values := {
			"light_color": p.sun_color, "light_energy": p.sun_energy, "shadow_enabled": p.sun_shadows,
			"rotation_degrees": Vector3(p.sun_pitch, p.sun_yaw, 0.0),
		}
		if sun == null:
			sun = DirectionalLight3D.new()
			sun.name = "Sun"
			for key in values:
				sun.set(key, values[key])
			ur.add_do_method(root, "add_child", sun, true)
			ur.add_do_method(sun, "set_owner", root)
			ur.add_do_reference(sun)
			ur.add_undo_method(root, "remove_child", sun)
		else:
			for key in values:
				ur.add_do_property(sun, key, values[key])
				ur.add_undo_property(sun, key, sun.get(key))
	ur.commit_action()
	report["world_environment"] = Util.scene_path_of(world, root)
	if p.sun:
		report["sun"] = Util.scene_path_of(sun, root)
	report["edited"] = "open scene (unsaved; save with Ctrl+S or scene_save) + %s" % p.environment_path
	report["undo"] = "One editor undo step restores the scene and the environment file."
	report["next"] = "Open the other scene (raid map / hideout) and run environment_setup again to share %s." % p.environment_path
	return {"data": report}


## The project's preset environment section merged over the neutral
## defaults. {values, from} or an error.
static func environment_preset() -> Variant:
	var values := ENV_DEFAULTS.duplicate(true)
	var from := "defaults"
	var section: Variant = null
	if FileAccess.file_exists(PRESET_PATH):
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(PRESET_PATH)) != OK or not json.data is Dictionary:
			return Util.error(Util.INVALID_PARAMS, "%s is not valid JSON (line %d: %s)" % [PRESET_PATH, json.get_error_line(), json.get_error_message()])
		section = json.data.get("environment")
		from = PRESET_PATH
	if section is Dictionary:
		for key in section:
			if values.has(key):
				values[key] = section[key]
	elif from != "defaults":
		from = "defaults (%s has no environment section)" % PRESET_PATH
	return {"values": values, "from": from}


static func read_env_params(params: Dictionary, base: Dictionary) -> Variant:
	var allowed: Array = ENV_DEFAULTS.keys() + ["environment_path", "node_path", "dry_run"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var merged := base.duplicate(true)
	for key in params:
		if merged.has(key) and params[key] != null:
			merged[key] = params[key]
	var p := {"report": {}}
	for key in ["hdri", "background", "tonemap"]:
		var v: Variant = Util.text(merged, key, String(ENV_DEFAULTS[key]))
		if Util.is_error(v):
			return v
		p[key] = v
	for spec in [["sky_energy", 0.0, 16.0], ["ambient_energy", 0.0, 16.0], ["exposure", 0.0, 16.0], ["ssao_intensity", 0.0, 16.0],
			["fog_density", 0.0, 1.0], ["fog_sky_affect", 0.0, 1.0], ["fog_height", -1024.0, 1024.0], ["fog_height_density", -16.0, 16.0],
			["volumetric_fog_density", 0.0, 1.0], ["volumetric_fog_length", 1.0, 1024.0], ["sun_energy", 0.0, 16.0],
			["sun_pitch", -90.0, 90.0], ["sun_yaw", -360.0, 360.0]]:
		var v: Variant = Util.num(merged, spec[0], float(ENV_DEFAULTS[spec[0]]), spec[1], spec[2])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for key in ["ssao", "glow", "fog", "volumetric_fog", "sun", "sun_shadows"]:
		var v: Variant = Util.boolean(merged, key, bool(ENV_DEFAULTS[key]))
		if Util.is_error(v):
			return v
		p[key] = v
	for key in ["background_color", "fog_color", "volumetric_fog_albedo", "sun_color"]:
		var v: Variant = read_color(merged, key, color_of(ENV_DEFAULTS[key]))
		if Util.is_error(v):
			return v
		p[key] = v
	if not p.tonemap in TONEMAPS:
		return Util.error(Util.INVALID_PARAMS, "'tonemap' must be one of %s" % ", ".join(TONEMAPS.keys()))
	if not p.background in BACKGROUNDS:
		return Util.error(Util.INVALID_PARAMS, "'background' must be one of %s" % ", ".join(BACKGROUNDS))
	var path: Variant = Util.text(params, "environment_path", ENVIRONMENT_PATH)
	var node_path: Variant = Util.text(params, "node_path", "")
	var dry: Variant = Util.boolean(params, "dry_run", false)
	for v in [path, node_path, dry]:
		if Util.is_error(v):
			return v
	var reason := Util.check_res_path(path, "tres")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)
	p["environment_path"] = path
	p["node_path"] = node_path
	p["dry_run"] = dry
	## The HDRI: a res:// .hdr/.exr, or a polyhaven_fetch name.
	if not p.hdri.is_empty() and not p.hdri.begins_with("res://"):
		if not AssetTools.is_asset_id(p.hdri):
			return Util.error(Util.INVALID_PARAMS, "'hdri' must be a res:// .hdr/.exr path or a polyhaven_fetch name")
		var found := ""
		for ext in ["hdr", "exr"]:
			var guess := "%s/%s.%s" % [HDRI_DIR, p.hdri, ext]
			if FileAccess.file_exists(guess):
				found = guess
				break
		if found.is_empty():
			return Util.error(Util.INVALID_PARAMS, "no %s/%s.hdr; fetch it first: polyhaven_fetch asset=%s" % [HDRI_DIR, p.hdri, p.hdri])
		p.hdri = found
	for key in merged:
		if ENV_DEFAULTS.has(key):
			var v: Variant = p.get(key)
			p.report[key] = [snappedf(v.r, 0.001), snappedf(v.g, 0.001), snappedf(v.b, 0.001)] if v is Color else v
	return p


## An Environment built from the values. {environment, sky_desc, warnings}
## or an error.
static func build_environment(p: Dictionary) -> Variant:
	var warnings: Array[String] = []
	var env := Environment.new()
	var sky_desc := "none"
	if p.background == "sky":
		var sky := Sky.new()
		if not p.hdri.is_empty():
			var tex := ResourceLoader.load(p.hdri, "Texture2D") as Texture2D if ResourceLoader.exists(p.hdri) else null
			if tex == null:
				return Util.error(Util.EDITOR_NOT_READY, "%s is not imported yet; focus the Godot window and try again in a moment" % p.hdri)
			var mat := PanoramaSkyMaterial.new()
			mat.panorama = tex
			mat.energy_multiplier = p.sky_energy
			sky.sky_material = mat
			sky_desc = "HDRI %s" % p.hdri
		else:
			var mat := ProceduralSkyMaterial.new()
			mat.energy_multiplier = p.sky_energy
			sky.sky_material = mat
			sky_desc = "procedural (pass hdri= for a Poly Haven sky)"
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = p.background_color
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = p.background_color
		sky_desc = "color"
	env.ambient_light_energy = p.ambient_energy
	env.tonemap_mode = TONEMAPS[p.tonemap]
	env.tonemap_exposure = p.exposure
	env.ssao_enabled = p.ssao
	env.ssao_intensity = p.ssao_intensity
	env.glow_enabled = p.glow
	env.fog_enabled = p.fog
	env.fog_light_color = p.fog_color
	env.fog_density = p.fog_density
	env.fog_sky_affect = p.fog_sky_affect
	env.fog_height = p.fog_height
	env.fog_height_density = p.fog_height_density
	env.volumetric_fog_enabled = p.volumetric_fog
	env.volumetric_fog_density = p.volumetric_fog_density
	env.volumetric_fog_albedo = p.volumetric_fog_albedo
	env.volumetric_fog_length = p.volumetric_fog_length
	return {"environment": env, "sky_desc": sky_desc, "warnings": warnings}


# =============================================================================
# helpers
# =============================================================================

## [r, g, b] / [r, g, b, a] (0-1) or "#rrggbb". Returns Color, `default_value`
## when absent, or an error.
static func read_color(params: Dictionary, key: String, default_value: Variant) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	var c: Variant = color_of(params[key])
	if c == null:
		return Util.error(Util.INVALID_PARAMS, "'%s' must be [r, g, b] (0-1) or \"#rrggbb\"" % key)
	return c


static func color_of(raw: Variant) -> Variant:
	if raw is Color:
		return raw
	if raw is String and Color.html_is_valid(raw):
		return Color.html(raw)
	if raw is Array and raw.size() in [3, 4]:
		for v in raw:
			if not (v is float or v is int) or float(v) < 0.0 or float(v) > 16.0:
				return null
		return Color(raw[0], raw[1], raw[2], raw[3] if raw.size() == 4 else 1.0)
	return null


func _run(ctx, fn: Callable) -> Dictionary:
	if ctx != null and ctx.has_method("send_deferred"):
		_deliver(ctx, fn)
		return {"_deferred": true}
	var r: Variant = fn.call()
	if r is Dictionary:
		return r
	_busy = false
	return Util.error(Util.INTERNAL_ERROR, "this tool needs the deferred channel (call it through MCP)")


func _deliver(ctx, fn: Callable) -> void:
	## The dispatcher registers the request only after the tool returns
	## {"_deferred": true}; start on the next frame.
	await (Engine.get_main_loop() as SceneTree).process_frame
	var r: Variant = await fn.call()
	_busy = false
	ctx.send_deferred(r if r is Dictionary else Util.error(Util.INTERNAL_ERROR, "no result"))


static func _deadline(ctx) -> int:
	if ctx != null and "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		return int(ctx.deadline_msec) - REPLY_MARGIN_MSEC
	return 0

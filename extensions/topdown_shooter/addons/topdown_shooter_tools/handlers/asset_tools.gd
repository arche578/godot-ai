@tool
extends RefCounted

## asset_cleanup and asset_import: the first half of the asset pipeline.
##
## asset_cleanup runs Blender without a window on a downloaded or generated
## model (.glb/.gltf/.fbx/.obj/.blend) and writes a cleaned .glb: front
## faces -Z, real size in meters, origin at the bottom center (the grip for
## weapons), triangles within the budget, textures shrunk, and a Muzzle
## point on weapons. The source file is never changed. By default it then
## runs asset_import on the result.
##
## asset_import copies a model into the rule folder
## res://assets/<kind>s/<asset_id>/<asset_id>.<ext>, writes its import
## settings (.import), imports it and reports what Godot actually got: size
## in meters, triangles, materials, texture sizes, bones, animation clips,
## where the origin sits, the Muzzle point and anything over budget.
##
## Never a full EditorFileSystem.scan() (it crashes the GUI editor when
## stacked): a file in a folder the editor already knows is imported with
## update_file() + reimport_files(); a brand-new folder needs one
## incremental scan_sources() (what the editor does when its window gets
## focus), which the deferred tool calls once and waits for.
##
## Work files (copies of the source, the Blender job and report, previews)
## go to res://asset_sources/<asset_id>/, which a .gdignore hides from the
## editor.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")

const ASSETS_ROOT := "res://assets"
const SOURCES_ROOT := "res://asset_sources"
const BLENDER_SCRIPT := "res://addons/topdown_shooter_tools/blender/asset_cleanup.py"
const BLENDER_SETTING := "filesystem/import/blender/blender_path"

const KINDS := ["weapon", "item", "prop", "character"]
const KIND_DIRS := {"weapon": "weapons", "item": "items", "prop": "props", "character": "characters"}
const MODEL_EXTENSIONS := ["glb", "gltf", "fbx", "obj"]
const CLEANUP_EXTENSIONS := ["glb", "gltf", "fbx", "obj", "blend"]
## Triangles and the largest texture side per kind (asset pipeline plan).
const BUDGETS := {
	"weapon": {"triangles": 5000, "texture": 512},
	"item": {"triangles": 2000, "texture": 512},
	"prop": {"triangles": 5000, "texture": 512},
	"character": {"triangles": 15000, "texture": 1024},
}
## Sizes in meters that look plausible for a kind: [axis, min, max].
const SIZE_SANITY := {
	"weapon": ["length", 0.15, 2.5],
	"item": ["max", 0.02, 1.5],
	"prop": ["max", 0.05, 20.0],
	"character": ["height", 1.0, 3.0],
}
const SIZE_MODES := ["height", "length", "width", "max", "keep"]
const ORIGIN_MODES := ["bottom_center", "center", "grip", "keep"]
const AXES := ["auto", "+x", "-x", "+y", "-y", "+z", "-z"]
const IMPORT_WAIT_SEC := 90.0
## Time kept back from a deferred call's deadline to send the reply.
const REPLY_MARGIN_MSEC := 5000
## Longest wait for the preview's frames (an unfocused or hidden editor
## window may not draw at all).
const PREVIEW_WAIT_MSEC := 8000
const PREVIEW_SIZE := 512

## A blender run that is still going (asset_cleanup is one at a time).
var _busy := false


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


# =============================================================================
# asset_cleanup
# =============================================================================

func asset_cleanup(params: Dictionary, ctx = null) -> Dictionary:
	var p: Variant = read_cleanup_params(params)
	if Util.is_error(p):
		return p
	if _busy:
		return Util.error(Util.EDITOR_NOT_READY, "asset_cleanup is already running a Blender job; wait for it to finish")
	var blender := find_blender(p.blender_path)
	if blender.is_empty():
		return Util.error(Util.INVALID_PARAMS, "Blender not found. Pass blender_path (macOS: /Applications/Blender.app/Contents/MacOS/Blender), set Editor Settings > %s, or the BLENDER_PATH environment variable." % BLENDER_SETTING)
	var import_p: Variant = null
	if p["import"]:
		import_p = read_import_params(_import_params_from_cleanup(p))
		if Util.is_error(import_p):
			return import_p
		var exists_err := _check_destination(import_p)
		if not exists_err.is_empty():
			return exists_err
	var job: Variant = _write_job(p)
	if Util.is_error(job):
		return job
	if p.dry_run:
		return {"data": {"dry_run": true, "blender": blender, "job": job.job, "destination": import_p.dest if import_p != null else null}}

	if ctx != null and ctx.has_method("send_deferred"):
		_busy = true
		_cleanup_async(p, blender, job, import_p, ctx)
		return {"_deferred": true}
	## No deferred channel (tests, batch): run Blender blocking.
	var report: Variant = run_blender_blocking(blender, job)
	return _finish_cleanup(p, job, report, import_p)


static func read_cleanup_params(params: Dictionary) -> Variant:
	var allowed := ["source", "kind", "asset_id", "size", "size_mode", "forward", "up", "yaw_degrees", "origin",
		"max_triangles", "max_texture", "muzzle", "blender_path", "import", "overwrite", "dry_run", "preview",
		"generate_lods", "timeout_sec"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var common: Variant = _read_common(params)
	if Util.is_error(common):
		return common
	var p: Dictionary = common
	var source: Variant = Util.text(params, "source", "")
	if Util.is_error(source):
		return source
	var src := resolve_source(source)
	if src.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'source' is required: the downloaded model file (absolute path, ~/..., or res://)")
	if not FileAccess.file_exists(src):
		return Util.error(Util.INVALID_PARAMS, "source file not found: %s" % src)
	if not src.get_extension().to_lower() in CLEANUP_EXTENSIONS:
		return Util.error(Util.INVALID_PARAMS, "source must be one of .%s" % ", .".join(CLEANUP_EXTENSIONS))
	p["source"] = src
	for spec in [["size_mode", SIZE_MODES], ["origin", ORIGIN_MODES], ["forward", AXES], ["up", AXES]]:
		var v: Variant = Util.text(params, spec[0], "")
		if Util.is_error(v):
			return v
		if not String(v).is_empty() and not String(v).to_lower() in spec[1]:
			return Util.error(Util.INVALID_PARAMS, "'%s' must be one of %s" % [spec[0], ", ".join(spec[1])])
		p[spec[0]] = String(v).to_lower()
	if p.up == "auto":
		p.up = ""
	var size: Variant = Util.num(params, "size", 0.0, 0.0, 1000.0)
	var yaw: Variant = Util.num(params, "yaw_degrees", 0.0, -360.0, 360.0)
	var tris: Variant = Util.integer(params, "max_triangles", 0, 0, 2000000)
	var tex: Variant = Util.integer(params, "max_texture", 0, 0, 16384)
	var muzzle: Variant = Util.boolean(params, "muzzle", p.kind == "weapon")
	var blender_path: Variant = Util.text(params, "blender_path", "")
	var do_import: Variant = Util.boolean(params, "import", true)
	var timeout: Variant = Util.num(params, "timeout_sec", 100.0, 5.0, 110.0)
	for v in [size, yaw, tris, tex, muzzle, blender_path, do_import, timeout]:
		if Util.is_error(v):
			return v
	p["size"] = size
	p["yaw_degrees"] = yaw
	p["max_triangles"] = tris
	p["max_texture"] = tex
	p["muzzle"] = muzzle
	p["blender_path"] = blender_path
	p["import"] = do_import
	p["timeout_sec"] = timeout
	return p


func _import_params_from_cleanup(p: Dictionary) -> Dictionary:
	return {
		"source": clean_output_path(p.asset_id),
		"kind": p.kind,
		"asset_id": p.asset_id,
		"overwrite": p.overwrite,
		"generate_lods": p.generate_lods,
		"preview": p.preview,
	}


## Writes the Blender job file. Returns {job, job_path, report_path, output}.
func _write_job(p: Dictionary) -> Variant:
	var work := work_dir(p.asset_id)
	var err := ensure_sources_dir(work)
	if not err.is_empty():
		return Util.error(Util.INTERNAL_ERROR, err)
	var job := {
		"source": ProjectSettings.globalize_path(p.source) if String(p.source).contains("://") else p.source,
		"output": ProjectSettings.globalize_path(clean_output_path(p.asset_id)),
		"report_path": ProjectSettings.globalize_path(work + "/cleanup_report.json"),
		"kind": p.kind,
		"size": p.size if p.size > 0.0 else null,
		"size_mode": p.size_mode if not p.size_mode.is_empty() else null,
		"forward": p.forward if not p.forward.is_empty() else null,
		"up": p.up if not p.up.is_empty() else null,
		"yaw_degrees": p.yaw_degrees,
		"origin": p.origin if not p.origin.is_empty() else null,
		"max_triangles": p.max_triangles if p.max_triangles > 0 else null,
		"max_texture": p.max_texture if p.max_texture > 0 else null,
		"muzzle": p.muzzle,
	}
	var job_path := work + "/cleanup_job.json"
	var f := FileAccess.open(job_path, FileAccess.WRITE)
	if f == null:
		return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [job_path, error_string(FileAccess.get_open_error())])
	f.store_string(JSON.stringify(job, "  "))
	f.close()
	## A stale report from an earlier run must not pass for this one.
	if FileAccess.file_exists(job.report_path):
		DirAccess.remove_absolute(job.report_path)
	return {"job": job, "job_path": ProjectSettings.globalize_path(job_path), "report_path": job.report_path, "output": job.output}


static func blender_args(job_path: String) -> PackedStringArray:
	return PackedStringArray(["-b", "--factory-startup", "--python", ProjectSettings.globalize_path(BLENDER_SCRIPT), "--", job_path])


## Runs Blender and waits (blocks the editor; tests and batch only).
static func run_blender_blocking(blender: String, job: Dictionary) -> Variant:
	var output: Array = []
	var code := OS.execute(blender, blender_args(job.job_path), output, true)
	var report: Variant = read_json(job.report_path)
	if report == null:
		return {"ok": false, "error": "Blender exited (code %d) without a report" % code, "log": _tail("\n".join(output), 1500)}
	return report


func _cleanup_async(p: Dictionary, blender: String, job: Dictionary, import_p: Variant, ctx) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var pid := OS.create_process(blender, blender_args(job.job_path))
	if pid <= 0:
		_busy = false
		ctx.send_deferred(Util.error(Util.INTERNAL_ERROR, "could not start Blender at %s" % blender))
		return
	var started := Time.get_ticks_msec()
	var deadline := started + int(p.timeout_sec * 1000.0)
	if "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		deadline = mini(deadline, int(ctx.deadline_msec) - 8000)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.25).timeout
	if OS.is_process_running(pid):
		OS.kill(pid)
		_busy = false
		ctx.send_deferred(Util.error(Util.INTERNAL_ERROR, "Blender did not finish within %d s and was stopped; raise timeout_sec or lower max_triangles" % int((Time.get_ticks_msec() - started) / 1000)))
		return
	var report: Variant = read_json(job.report_path)
	if report == null:
		report = {"ok": false, "error": "Blender exited without a report (wrong blender_path, or Blender crashed). Run it by hand: %s %s" % [blender, " ".join(blender_args(job.job_path))]}
	report["seconds"] = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)
	var result := _finish_cleanup(p, job, report, import_p)
	if Util.is_error(result) or import_p == null:
		_busy = false
		ctx.send_deferred(result)
		return
	var data: Dictionary = result.data
	data["import"] = await _settle_import(import_p, data["import"], ctx)
	_busy = false
	ctx.send_deferred({"data": data})


func _finish_cleanup(p: Dictionary, job: Dictionary, report: Variant, import_p: Variant) -> Dictionary:
	if not report is Dictionary or not report.get("ok", false):
		var msg := "Blender cleanup failed"
		if report is Dictionary and report.has("error"):
			msg += ": " + String(report.error)
		var err := Util.error(Util.INTERNAL_ERROR, msg)
		err.error["data"] = {"report": report}
		return err
	var data := {
		"source": p.source,
		"cleaned": clean_output_path(p.asset_id),
		"cleanup": _summarize_cleanup(report),
		"work_dir": work_dir(p.asset_id),
	}
	_append_record(p.asset_id, {"step": "cleanup", "source": p.source, "kind": p.kind, "report": report})
	if import_p == null:
		data["next"] = "Call asset_import with source=%s to bring it into the project." % clean_output_path(p.asset_id)
		return {"data": data}
	var imported := import_asset(import_p)
	if Util.is_error(imported):
		data["import"] = {"error": imported.error}
	else:
		data["import"] = imported.data
	return {"data": data}


static func _summarize_cleanup(report: Dictionary) -> Dictionary:
	var out := {}
	for key in ["blender_version", "seconds", "source", "forward_detected", "rotation", "scale", "decimated", "origin", "muzzle", "result", "warnings"]:
		if report.has(key):
			out[key] = report[key]
	var textures: Array = []
	for t in report.get("textures", []):
		if t.has("resized_to"):
			textures.append("%s %dx%d -> %dx%d" % [t.name, t.size[0], t.size[1], t.resized_to[0], t.resized_to[1]])
	if not textures.is_empty():
		out["textures_resized"] = textures
	return out


## Blender to run: param, BLENDER_PATH, the editor's Blender import setting,
## then the usual install places. "" when none exists.
static func find_blender(wanted: String) -> String:
	var candidates: Array[String] = []
	if not wanted.is_empty():
		return resolve_source(wanted) if FileAccess.file_exists(resolve_source(wanted)) else ""
	var env := OS.get_environment("BLENDER_PATH")
	if not env.is_empty():
		candidates.append(env)
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if settings != null and settings.has_setting(BLENDER_SETTING):
			var configured := String(settings.get_setting(BLENDER_SETTING))
			if not configured.is_empty():
				## The setting may name the .app bundle on macOS.
				if configured.ends_with(".app"):
					configured = configured.path_join("Contents/MacOS/Blender")
				candidates.append(configured)
	match OS.get_name():
		"macOS":
			candidates.append("/Applications/Blender.app/Contents/MacOS/Blender")
			candidates.append(OS.get_environment("HOME").path_join("Applications/Blender.app/Contents/MacOS/Blender"))
		"Windows":
			var base := "C:/Program Files/Blender Foundation"
			var dir := DirAccess.open(base)
			if dir != null:
				var versions := dir.get_directories()
				versions.reverse()
				for v in versions:
					candidates.append(base.path_join(v).path_join("blender.exe"))
		_:
			candidates.append("/usr/bin/blender")
			candidates.append("/usr/local/bin/blender")
			candidates.append("/snap/bin/blender")
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


# =============================================================================
# asset_import
# =============================================================================

func asset_import(params: Dictionary, ctx = null) -> Dictionary:
	if params.get("inspect_only", false) == true:
		return _inspect_only(params, ctx)
	var p: Variant = read_import_params(params)
	if Util.is_error(p):
		return p
	if not FileAccess.file_exists(p.source):
		return Util.error(Util.INVALID_PARAMS, "source file not found: %s" % p.source)
	var exists_err := _check_destination(p)
	if not exists_err.is_empty():
		return exists_err
	if p.dry_run:
		return {"data": {"dry_run": true, "source": p.source, "destination": p.dest, "import_settings": import_settings(p), "folder_known": folder_known(p.dest_dir)}}
	var result := import_asset(p)
	if Util.is_error(result):
		return result
	var deferred: bool = ctx != null and ctx.has_method("send_deferred")
	if not deferred:
		return result
	if not result.data.get("import_pending", false) and not p.preview:
		return result
	_import_async(p, result.data, ctx)
	return {"_deferred": true}


## Report (and preview) for a model already in the rule folder, without
## copying anything: for a call that ran out of time, or after edits.
func _inspect_only(params: Dictionary, ctx) -> Dictionary:
	var allowed := ["inspect_only", "kind", "asset_id", "dest_dir", "source", "preview"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "with inspect_only=true only %s are allowed (got '%s')" % [", ".join(allowed), key])
	var common: Variant = _read_common(params)
	if Util.is_error(common):
		return common
	var p: Dictionary = common
	var dest_dir: Variant = Util.text(params, "dest_dir", "")
	if Util.is_error(dest_dir):
		return dest_dir
	var dir := Util.clean_dir(dest_dir) if not String(dest_dir).is_empty() else default_dest_dir(p.kind, p.asset_id)
	var dest := ""
	for ext in MODEL_EXTENSIONS:
		var candidate: String = dir + "/" + p.asset_id + "." + ext
		if FileAccess.file_exists(candidate):
			dest = candidate
			break
	if dest.is_empty():
		return Util.error(Util.INVALID_PARAMS, "no %s.(%s) in %s; import it first" % [p.asset_id, "|".join(MODEL_EXTENSIONS), dir])
	p["dest_dir"] = dir
	p["dest"] = dest
	p["source"] = dest
	var data := {"asset_id": p.asset_id, "kind": p.kind, "path": dest, "import_pending": not _import_valid(dest), "reimport": false}
	if not data.import_pending:
		data = finish_import(p, true)
	if ctx == null or not ctx.has_method("send_deferred"):
		if data.get("import_pending", false):
			data["note"] = "the editor has not imported %s yet; try again in a moment" % dest
		return {"data": data}
	_import_async(p, data, ctx)
	return {"_deferred": true}


func _import_async(p: Dictionary, data: Dictionary, ctx) -> void:
	ctx.send_deferred({"data": await _settle_import(p, data, ctx)})


## Waits for a pending import and renders the preview, both within the
## call's deadline, so the reply always arrives before the MCP timeout.
func _settle_import(p: Dictionary, data: Dictionary, ctx) -> Dictionary:
	var deadline := 0
	if ctx != null and "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		deadline = int(ctx.deadline_msec) - REPLY_MARGIN_MSEC
	if data.get("import_pending", false):
		var waited := await wait_for_import(p.dest, bool(data.get("reimport", false)), deadline)
		data = finish_import(p, waited)
	if p.preview and not data.has("error") and not data.get("import_pending", false):
		data["preview"] = await render_preview(p.dest, preview_path(p.asset_id), deadline)
	return data


static func read_import_params(params: Dictionary) -> Variant:
	var allowed := ["source", "kind", "asset_id", "dest_dir", "overwrite", "dry_run", "preview", "generate_lods", "root_scale"]
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var common: Variant = _read_common(params)
	if Util.is_error(common):
		return common
	var p: Dictionary = common
	var source: Variant = Util.text(params, "source", "")
	var dest_dir: Variant = Util.text(params, "dest_dir", "")
	var root_scale: Variant = Util.num(params, "root_scale", 1.0, 0.0001, 10000.0)
	for v in [source, dest_dir, root_scale]:
		if Util.is_error(v):
			return v
	var src := resolve_source(source)
	if src.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'source' is required: a .glb/.gltf/.fbx/.obj file (absolute path, ~/..., or res://)")
	var ext := src.get_extension().to_lower()
	if not ext in MODEL_EXTENSIONS:
		return Util.error(Util.INVALID_PARAMS, "source must be one of .%s (run asset_cleanup first for .blend)" % ", .".join(MODEL_EXTENSIONS))
	p["source"] = src
	p["root_scale"] = root_scale
	var dir := Util.clean_dir(dest_dir) if not String(dest_dir).is_empty() else default_dest_dir(p.kind, p.asset_id)
	var reason := Util.check_res_path(dir + "/x." + ext, ext)
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "dest_dir: " + reason)
	if dir.begins_with(SOURCES_ROOT):
		return Util.error(Util.INVALID_PARAMS, "dest_dir must not be inside %s (the editor ignores that folder)" % SOURCES_ROOT)
	p["dest_dir"] = dir
	p["dest"] = dir + "/" + p.asset_id + "." + ext
	if ProjectSettings.globalize_path(p.dest) == ProjectSettings.globalize_path(src):
		return Util.error(Util.INVALID_PARAMS, "source is already the destination %s; to re-import it call filesystem_manage op=reimport" % p.dest)
	return p


## kind, asset_id, overwrite, dry_run, preview, generate_lods.
static func _read_common(params: Dictionary) -> Variant:
	var kind: Variant = Util.text(params, "kind", "")
	var asset_id: Variant = Util.text(params, "asset_id", "")
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var dry_run: Variant = Util.boolean(params, "dry_run", false)
	var preview: Variant = Util.boolean(params, "preview", true)
	var lods: Variant = Util.boolean(params, "generate_lods", true)
	for v in [kind, asset_id, overwrite, dry_run, preview, lods]:
		if Util.is_error(v):
			return v
	if not kind in KINDS:
		return Util.error(Util.INVALID_PARAMS, "'kind' must be one of %s" % ", ".join(KINDS))
	if not is_asset_id(asset_id):
		return Util.error(Util.INVALID_PARAMS, "'asset_id' must be lowercase letters, digits and _ (e.g. gold_watch, smg_01); use the item/weapon id so tools can match them")
	return {"kind": kind, "asset_id": asset_id, "overwrite": overwrite, "dry_run": dry_run, "preview": preview, "generate_lods": lods}


func _check_destination(p: Dictionary) -> Dictionary:
	if FileAccess.file_exists(p.dest) and not p.overwrite:
		return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass overwrite=true to replace it (one undo step restores it)" % p.dest)
	return {}


## Copies the model (plus a .gltf's external files) into the rule folder,
## writes the .import settings and imports it. Returns {"data": report}.
## data.import_pending is true when the folder is new to the editor: then
## call wait_for_import() and finish_import() (deferred tools do).
func import_asset(p: Dictionary) -> Dictionary:
	var copies: Variant = _plan_copies(p.source, p.dest)
	if Util.is_error(copies):
		return copies
	var targets: Array = []
	for c in copies:
		targets.append(c[1])
	targets.append(p.dest + ".import")
	var before := ItemTools.FileSnapshot.capture(targets)
	var dir_err := Util.ensure_dir(p.dest_dir)
	if dir_err != OK:
		return Util.error(Util.INTERNAL_ERROR, "cannot create %s: %s" % [p.dest_dir, error_string(dir_err)])
	for c in copies:
		var bytes := FileAccess.get_file_as_bytes(c[0])
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot read %s: %s" % [c[0], error_string(FileAccess.get_open_error())])
		Util.ensure_dir(String(c[1]).get_base_dir())
		var f := FileAccess.open(c[1], FileAccess.WRITE)
		if f == null:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot write %s: %s" % [c[1], error_string(FileAccess.get_open_error())])
		f.store_buffer(bytes)
		f.close()
	var cfg_err := _write_import_config(p)
	if not cfg_err.is_empty():
		before.restore()
		return Util.error(Util.INTERNAL_ERROR, cfg_err)
	var after := ItemTools.FileSnapshot.capture(targets)
	if Engine.is_editor_hint():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Import asset %s" % p.asset_id, UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(before, "restore")
		ur.commit_action(false)
	_append_record(p.asset_id, {"step": "import", "source": p.source, "kind": p.kind, "dest": p.dest})

	var copied: Array = []
	for c in copies:
		copied.append(c[1])
	var known := folder_known(p.dest_dir)
	var efs := EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	if not known or efs == null or efs.is_scanning() or efs.is_importing():
		## A reimport_files() while the editor imports something else
		## collides ("Task 'reimport' already exists"); wait_for_import()
		## starts ours once the editor is idle.
		return {"data": {
			"asset_id": p.asset_id, "kind": p.kind, "path": p.dest, "copied": copied,
			"import_pending": true, "reimport": known,
			"note": ("%s is a new folder; the editor imports the model on its next file scan" % p.dest_dir if not known
				else "the editor is busy importing; %s is imported when it is done" % p.dest) + " (asset_import/asset_cleanup wait for it).",
		}}
	efs.update_file(p.dest)
	efs.reimport_files(PackedStringArray([p.dest]))
	return {"data": finish_import(p, true)}


## Report for an imported model, or {"error": ...} when it did not import.
func finish_import(p: Dictionary, imported: bool) -> Dictionary:
	var data := {"asset_id": p.asset_id, "kind": p.kind, "path": p.dest, "source": p.source}
	if not imported:
		data["import_pending"] = true
		data["note"] = "the editor had not finished importing %s when this call ran out of time. Focus the Godot window, then call asset_import kind=%s asset_id=%s inspect_only=true for the report." % [p.dest, p.kind, p.asset_id]
		return data
	var info := inspect_model(p.dest, p.kind)
	if info.has("error"):
		data["error"] = info.error
		return data
	data.merge(info)
	_append_record(p.asset_id, {"step": "report", "path": p.dest, "size": info.get("size"), "triangles": info.get("triangles"),
		"materials": info.get("materials"), "textures": info.get("textures"), "warnings": info.get("warnings")})
	data["undo"] = "One editor undo step (Edit > Undo) restores the files as they were before this import."
	data["next"] = _next_hint(p.kind, p.asset_id, p.dest)
	return data


static func _next_hint(kind: String, asset_id: String, path: String) -> String:
	match kind:
		"weapon":
			return "swap_placeholder target=weapon scene=res://scenes/weapons/%s.tscn model=%s (puts the model in the weapon scene and moves Muzzle)" % [asset_id, path]
		"item":
			return "swap_placeholder target=item item_id=%s model=%s (dropped items show the model)" % [asset_id, path]
		"character":
			return "swap_placeholder target=player (or enemy) model=%s" % path
	return "swap_placeholder target=map group=Crates (or Cover/Walls) model=%s" % path


func _plan_copies(source: String, dest: String) -> Variant:
	var out: Array = [[source, dest]]
	if source.get_extension().to_lower() != "gltf":
		return out
	var json: Variant = read_json(source)
	if not json is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "%s is not valid glTF JSON" % source)
	var uris: Array = []
	for key in ["buffers", "images"]:
		for entry in json.get(key, []):
			if entry is Dictionary and entry.has("uri"):
				var uri := String(entry.uri)
				if uri.begins_with("data:"):
					continue
				uris.append(uri.uri_decode())
	for uri in uris:
		if uri.contains("..") or uri.begins_with("/") or uri.contains(":"):
			return Util.error(Util.INVALID_PARAMS, "%s refers to %s outside its folder; export a .glb instead" % [source, uri])
		var from := source.get_base_dir().path_join(uri)
		if not FileAccess.file_exists(from):
			return Util.error(Util.INVALID_PARAMS, "%s needs %s, which is missing" % [source, from])
		out.append([from, dest.get_base_dir().path_join(uri)])
	return out


static func import_settings(p: Dictionary) -> Dictionary:
	return {
		"nodes/root_scale": float(p.get("root_scale", 1.0)),
		"nodes/apply_root_scale": true,
		"meshes/ensure_tangents": true,
		"meshes/generate_lods": bool(p.generate_lods),
		"meshes/create_shadow_meshes": true,
		"meshes/light_baking": 1,
		"skins/use_named_skins": true,
		"animation/import": true,
		"animation/fps": 30,
		"animation/remove_immutable_tracks": true,
	}


## Writes <dest>.import with our settings. An existing one keeps its other
## keys (and its uid) and only gets ours set.
func _write_import_config(p: Dictionary) -> String:
	var path: String = p.dest + ".import"
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(path):
		cfg.load(path)
	cfg.set_value("remap", "importer", "scene")
	cfg.set_value("remap", "importer_version", 1)
	cfg.set_value("remap", "type", "PackedScene")
	cfg.set_value("deps", "source_file", p.dest)
	var settings := import_settings(p)
	for key in settings:
		cfg.set_value("params", key, settings[key])
	var err := cfg.save(path)
	return "" if err == OK else "cannot write %s: %s" % [path, error_string(err)]


static func folder_known(res_dir: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	var efs := EditorInterface.get_resource_filesystem()
	return efs != null and efs.get_filesystem_path(res_dir) != null


## Waits until `path` is imported. A folder the editor has not seen yet
## gets one incremental scan_sources() (never a full scan()).
## `reimport`: the file changed in a known folder, so an older import may
## still look valid; import it again once the editor is idle.
## `deadline_msec` (Time.get_ticks_msec) caps the wait for deferred calls.
func wait_for_import(path: String, reimport := false, deadline_msec := 0) -> bool:
	if not Engine.is_editor_hint():
		return false
	var efs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(IMPORT_WAIT_SEC * 1000.0)
	if deadline_msec > 0:
		deadline = mini(deadline, deadline_msec)
	var asked := false
	while Time.get_ticks_msec() < deadline:
		if not efs.is_scanning() and not efs.is_importing():
			if (asked or not reimport) and _import_valid(path):
				return true
			if not asked:
				asked = true
				if folder_known(path.get_base_dir()):
					efs.update_file(path)
					efs.reimport_files(PackedStringArray([path]))
				else:
					efs.scan_sources()
		await tree.create_timer(0.2).timeout
	return _import_valid(path)


static func _import_valid(path: String) -> bool:
	var efs := EditorInterface.get_resource_filesystem()
	var dir := efs.get_filesystem_path(path.get_base_dir())
	if dir == null:
		return false
	var index := dir.find_file_index(path.get_file())
	return index >= 0 and dir.get_file_import_is_valid(index) and ResourceLoader.exists(path)


# =============================================================================
# inspection
# =============================================================================

## What Godot imported: size, origin, triangles, materials, textures, bones,
## animations, Muzzle, warnings against the kind's budget.
static func inspect_model(path: String, kind: String) -> Dictionary:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return {"error": "cannot load %s as a scene (check the Output panel for import errors)" % path}
	var root := packed.instantiate() as Node
	if root == null:
		return {"error": "%s has no root node" % path}
	var stats := measure(root)
	var muzzle := find_named(root, "muzzle")
	var info := {
		"root_type": root.get_class(),
		"size": _v3(stats.aabb.size),
		"bounds_min": _v3(stats.aabb.position),
		"bounds_max": _v3(stats.aabb.end),
		"origin_offset": _v3(_bottom_center(stats.aabb)),
		"triangles": stats.triangles,
		"meshes": stats.meshes,
		"materials": stats.materials.keys(),
		"textures": stats.textures.values(),
		"bones": stats.bones,
		"animations": stats.animations,
	}
	if muzzle != null:
		info["muzzle"] = _v3(relative_transform(muzzle, root).origin)
	info["budget"] = BUDGETS[kind]
	info["warnings"] = _warnings(kind, stats, muzzle != null)
	root.free()
	return info


static func _warnings(kind: String, stats: Dictionary, has_muzzle: bool) -> Array[String]:
	var out: Array[String] = []
	var budget: Dictionary = BUDGETS[kind]
	if stats.meshes == 0:
		out.append("no mesh in the model")
		return out
	if stats.triangles > budget.triangles:
		out.append("%d triangles is over the %s budget of %d (asset_cleanup decimates)" % [stats.triangles, kind, budget.triangles])
	for t in stats.textures.values():
		if maxi(t.size[0], t.size[1]) > budget.texture:
			out.append("texture %s is %dx%d, over %d (asset_cleanup shrinks it)" % [t.name, t.size[0], t.size[1], budget.texture])
	var size: Vector3 = stats.aabb.size
	var sanity: Array = SIZE_SANITY[kind]
	var measured := maxf(size.x, maxf(size.y, size.z))
	if sanity[0] == "height":
		measured = size.y
	elif sanity[0] == "length":
		measured = size.z
	if measured < sanity[1] or measured > sanity[2]:
		out.append("%s %.3f m looks wrong for a %s (expected %s..%s m); fix the size with asset_cleanup size=..." % [sanity[0], measured, kind, sanity[1], sanity[2]])
	var off := _bottom_center(stats.aabb)
	var flat := maxf(0.01, maxf(size.x, size.z) * 0.1)
	if kind != "weapon" and (Vector2(off.x, off.z).length() > flat or absf(off.y) > maxf(0.01, size.y * 0.1)):
		out.append("the origin is not at the bottom center (bottom center is at %s); asset_cleanup origin=bottom_center fixes it" % str(_v3(off)))
	if kind == "weapon":
		if size.x > size.z:
			out.append("the weapon is wider (x) than long (z): it probably does not face -Z; run asset_cleanup (forward=auto)")
		if not has_muzzle:
			out.append("no Muzzle node: swap_placeholder will put the muzzle at the front-most point")
	return out


## Merged AABB (in root space), triangles, materials, textures, bones and
## animation names of a node tree that need not be in the scene tree.
static func measure(root: Node, skip: Array = []) -> Dictionary:
	var out := {"aabb": AABB(), "has_aabb": false, "triangles": 0, "meshes": 0, "materials": {}, "textures": {}, "bones": 0, "animations": []}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node in skip:
			continue
		if node is VisualInstance3D and not (node is Light3D or node is Label3D) and (node as Node3D).visible:
			var vi := node as VisualInstance3D
			var box := relative_transform(vi, root) * vi.get_aabb()
			if box.size != Vector3.ZERO or vi is MeshInstance3D:
				out.aabb = box if not out.has_aabb else out.aabb.merge(box)
				out.has_aabb = true
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mi := node as MeshInstance3D
			out.meshes += 1
			out.triangles += mesh_triangles(mi.mesh)
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if mat != null:
					var key := mat.resource_name if not mat.resource_name.is_empty() else "material_%d" % out.materials.size()
					out.materials[key] = true
					_collect_textures(mat, out.textures)
		if node is Skeleton3D:
			out.bones += (node as Skeleton3D).get_bone_count()
		if node is AnimationPlayer:
			for anim in (node as AnimationPlayer).get_animation_list():
				out.animations.append(String(anim))
		for child in node.get_children():
			stack.append(child)
	return out


static func mesh_triangles(mesh: Mesh) -> int:
	var total := 0
	if mesh is ArrayMesh:
		var am := mesh as ArrayMesh
		for i in am.get_surface_count():
			var indices := am.surface_get_array_index_len(i)
			total += (indices if indices > 0 else am.surface_get_array_len(i)) / 3
	elif mesh is PrimitiveMesh:
		var arrays := mesh.surface_get_arrays(0)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		total += (idx.size() if idx != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total


static func _collect_textures(mat: Material, out: Dictionary) -> void:
	if not mat is BaseMaterial3D:
		return
	var m := mat as BaseMaterial3D
	for param in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_ORM,
			BaseMaterial3D.TEXTURE_METALLIC, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_EMISSION,
			BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]:
		var tex := m.get_texture(param)
		if tex == null:
			continue
		var name := tex.resource_name if not tex.resource_name.is_empty() else tex.resource_path.get_file()
		if name.is_empty():
			name = "texture_%d" % out.size()
		out[name] = {"name": name, "size": [tex.get_width(), tex.get_height()]}


## Transform of `node` in `ancestor` space, without needing the scene tree.
static func relative_transform(node: Node, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func find_named(root: Node, lowercase_name: String) -> Node3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != root and node is Node3D and String(node.name).to_lower() == lowercase_name:
			return node
		for child in node.get_children():
			stack.append(child)
	return null


static func _bottom_center(aabb: AABB) -> Vector3:
	return Vector3(aabb.get_center().x, aabb.position.y, aabb.get_center().z)


static func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


# =============================================================================
# preview
# =============================================================================

## Renders the model from a 3/4 top-down angle into a PNG (needs a GUI
## editor; a headless one has no renderer). Returns the res:// path or a
## note. Coroutine.
func render_preview(model_path: String, png_path: String, deadline_msec := 0) -> Variant:
	if DisplayServer.get_name() == "headless":
		return "skipped (headless editor has no renderer)"
	var stop := Time.get_ticks_msec() + PREVIEW_WAIT_MSEC
	if deadline_msec > 0:
		stop = mini(stop, deadline_msec)
	if stop - Time.get_ticks_msec() < 1000:
		return "skipped (out of time; call asset_import inspect_only=true for a preview)"
	var packed := load(model_path) as PackedScene
	if packed == null:
		return "skipped (model did not load)"
	var model := packed.instantiate() as Node3D
	if model == null:
		return "skipped (the scene root is not a Node3D)"
	return await render_node(model, png_path, stop)


## Renders a Node3D tree (not in the scene tree; it is freed afterwards) into
## a PNG. `stop` is a Time.get_ticks_msec() deadline. Coroutine.
func render_node(model: Node3D, png_path: String, stop: int) -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	var vp := SubViewport.new()
	vp.size = Vector2i(PREVIEW_SIZE, PREVIEW_SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	EditorInterface.get_base_control().add_child(vp)
	vp.add_child(model)
	var stats := measure(model)
	var aabb: AABB = stats.aabb
	var radius := maxf(0.05, aabb.size.length() * 0.5)
	var center := aabb.get_center()
	var cam := Camera3D.new()
	cam.fov = 35.0
	var dir := Vector3(0.8, 1.1, 1.0).normalized()
	var dist := radius / sin(deg_to_rad(cam.fov * 0.5)) * 1.1
	vp.add_child(cam)
	cam.look_at_from_position(center + dir * dist, center, Vector3.UP)
	cam.near = maxf(0.01, dist - radius * 2.0)
	cam.far = dist + radius * 4.0
	var sun := DirectionalLight3D.new()
	vp.add_child(sun)
	sun.look_at_from_position(Vector3(2, 4, 3), Vector3.ZERO, Vector3.UP)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.8)
	e.ambient_light_energy = 0.6
	env.environment = e
	vp.add_child(env)
	var frames := [0]
	var count := func() -> void: frames[0] += 1
	RenderingServer.frame_post_draw.connect(count)
	## The editor (low processor mode) only draws when something asks.
	var base := EditorInterface.get_base_control()
	while frames[0] < 3 and Time.get_ticks_msec() < stop:
		base.queue_redraw()
		await tree.create_timer(0.05).timeout
	RenderingServer.frame_post_draw.disconnect(count)
	if frames[0] < 3:
		vp.queue_free()
		return "skipped (the editor window is not drawing; bring Godot to the front and call asset_import inspect_only=true)"
	var image := vp.get_texture().get_image()
	vp.queue_free()
	if image == null or image.is_empty():
		return "skipped (renderer returned no image)"
	ensure_sources_dir(png_path.get_base_dir())
	var err := image.save_png(png_path)
	if err != OK:
		return "skipped (cannot save %s: %s)" % [png_path, error_string(err)]
	return {"path": png_path, "absolute_path": ProjectSettings.globalize_path(png_path)}


# =============================================================================
# paths and records
# =============================================================================

static func is_asset_id(value: Variant) -> bool:
	if not value is String or String(value).is_empty() or String(value).length() > 64:
		return false
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9_]*$")
	return re.search(value) != null


static func default_dest_dir(kind: String, asset_id: String) -> String:
	return "%s/%s/%s" % [ASSETS_ROOT, KIND_DIRS[kind], asset_id]


static func default_model_path(kind: String, asset_id: String) -> String:
	var dir := default_dest_dir(kind, asset_id)
	for ext in MODEL_EXTENSIONS:
		var path := "%s/%s.%s" % [dir, asset_id, ext]
		if FileAccess.file_exists(path):
			return path
	return "%s/%s.glb" % [dir, asset_id]


static func work_dir(asset_id: String) -> String:
	return SOURCES_ROOT + "/" + asset_id


static func clean_output_path(asset_id: String) -> String:
	return work_dir(asset_id) + "/" + asset_id + "_clean.glb"


static func preview_path(asset_id: String) -> String:
	return work_dir(asset_id) + "/preview.png"


## Creates `res_dir` (under asset_sources/) and the .gdignore that keeps the
## editor from importing work files.
static func ensure_sources_dir(res_dir: String) -> String:
	var err := Util.ensure_dir(res_dir)
	if err != OK:
		return "cannot create %s: %s" % [res_dir, error_string(err)]
	var ignore := SOURCES_ROOT + "/.gdignore"
	if not FileAccess.file_exists(ignore):
		var f := FileAccess.open(ignore, FileAccess.WRITE)
		if f == null:
			return "cannot write %s" % ignore
		f.store_string("Work files of the asset pipeline (asset_cleanup / asset_import). Godot ignores this folder.\n")
		f.close()
	return ""


## Appends one step to asset_sources/<id>/asset.json (where an asset came
## from and what was done to it).
static func _append_record(asset_id: String, entry: Dictionary) -> void:
	var dir := work_dir(asset_id)
	if not ensure_sources_dir(dir).is_empty():
		return
	var path := dir + "/asset.json"
	var record: Variant = read_json(path)
	if not record is Dictionary:
		record = {"asset_id": asset_id, "history": []}
	entry["time"] = Time.get_datetime_string_from_system(false, true)
	record.history.append(entry)
	if record.history.size() > 50:
		record.history = record.history.slice(-50)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(record, "  "))
		f.close()


## Absolute OS path for a param: "~/x", "res://x", "user://x" or absolute.
static func resolve_source(path: String) -> String:
	var p := path.strip_edges()
	if p.is_empty():
		return ""
	if p.begins_with("~/") or p == "~":
		var home := OS.get_environment("HOME")
		if home.is_empty():
			home = OS.get_environment("USERPROFILE")
		p = home.path_join(p.substr(2))
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	return p.replace("\\", "/")


static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func _tail(text: String, n: int) -> String:
	return text if text.length() <= n else text.substr(text.length() - n)

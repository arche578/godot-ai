@tool
extends RefCounted

## asset_generate, asset_job and asset_pipeline: the AI half of the asset
## pipeline (Meshy or Tripo over their REST APIs).
##
##   asset_generate  builds the prompt from the shared style preset
##                   (res://assets/style_preset.json) and starts one provider
##                   task per candidate. Returns the job at once; generation
##                   takes minutes.
##   asset_job       status (polls the provider, saves candidate previews),
##                   preview (top-down renders of the candidates), pick,
##                   download, cancel, list, balance.
##   asset_pipeline  generate -> wait -> STOP for a pick -> texture the pick
##                   -> download -> asset_cleanup (Blender) -> asset_import
##                   -> swap_placeholder -> inspection renders. Call it again
##                   with the same asset_id to move on; every call goes as
##                   far as it can within its time and says what is next.
##
## Text jobs make cheap untextured candidates and texture only the pick.
## Image jobs (reference_image) come back textured.
##
## The job record is res://asset_sources/<asset_id>/job.json (a folder the
## editor ignores): provider, prompts, task ids, candidates, the pick, every
## step. API keys never enter the project: Editor Settings
## (topdown_shooter/asset_generation/*) or MESHY_API_KEY / TRIPO_API_KEY.
##
## Credit guards: candidates per request (default 2), a daily task limit
## (default 20) counted in the editor's data folder for every project, and
## dry_run, which shows the prompt and estimated credits only.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const AssetTools := preload("res://addons/topdown_shooter_tools/handlers/asset_tools.gd")
const SwapTools := preload("res://addons/topdown_shooter_tools/handlers/swap_tools.gd")
const IconTools := preload("res://addons/topdown_shooter_tools/handlers/icon_tools.gd")
const Providers := preload("res://addons/topdown_shooter_tools/handlers/gen_providers.gd")
const GenHttp := preload("res://addons/topdown_shooter_tools/handlers/gen_http.gd")

const SETTING_PREFIX := "topdown_shooter/asset_generation/"
const SETTING_DEFAULTS := {
	"meshy_api_key": "",
	"tripo_api_key": "",
	"default_provider": "meshy",
	"candidates": 2,
	"daily_task_limit": 20,
	"meshy_base_url": "",
	"tripo_base_url": "",
	"inbox_dirs": "res://TripoModels",
}
const KEY_ENV := {"meshy": "MESHY_API_KEY", "tripo": "TRIPO_API_KEY"}
const PRESET_PATH := "res://assets/style_preset.json"
const PRESET_TEMPLATE := "res://addons/topdown_shooter_tools/templates/style_preset.json.tmpl"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const MAX_CANDIDATES := 4
const MAX_IMAGE_BYTES := 20 * 1024 * 1024
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp"]
const STAGES := ["generating", "candidates_ready", "texturing", "ready", "downloaded", "imported", "swapped", "done", "failed", "canceled"]
## Stages after which a new generation for the same asset_id needs overwrite.
const ACTIVE_STAGES := ["generating", "candidates_ready", "texturing", "ready", "downloaded", "imported", "swapped"]
const JOB_OPS := ["status", "preview", "pick", "download", "cancel", "list", "balance", "inbox"]
## Models made outside the tools (Tripo Studio through the Tripo Godot Bridge,
## the meshy CLI, a manual download) join the pipeline with source=...
const ADOPT_EXTENSIONS := ["glb", "gltf", "fbx", "obj", "blend"]
const EXTERNAL_PROVIDERS := ["tripo", "meshy", "other"]
const INBOX_LIMIT := 30
const INBOX_DEPTH := 3
const SWAP_TARGET_FOR_KIND := {"weapon": "weapon", "item": "item"}
## swap_placeholder parameters the pipeline passes through (model is filled in).
const SWAP_KEYS := ["target", "model", "asset_id", "scene", "node_path", "map_path", "group", "name_prefix", "fit",
	"yaw_degrees", "size", "item_id", "database_path", "script_dir", "move_muzzle"]
## Time a pipeline call keeps for each slow step (ms).
const CLEANUP_BUDGET_MSEC := 105000
const DOWNLOAD_BUDGET_MSEC := 30000
const REPLY_MARGIN_MSEC := 5000

## Sends the HTTP requests; tests put a fake with request()/download() here.
var transport: Object = GenHttp.new()
## Test hooks: setting values ({"meshy_api_key": ...}), the usage file and
## today's date.
var settings_override := {}
var usage_path_override := ""
var today_override := ""
## Asset ids with a call in flight (one call per job at a time).
var _locks := {}


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


# =============================================================================
# settings
# =============================================================================

## Adds the settings to Editor Settings (called by plugin.gd). Values live in
## the editor's own settings file, outside every project and git.
static func register_settings() -> void:
	if not Engine.is_editor_hint():
		return
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	var hints := {
		"meshy_api_key": [TYPE_STRING, PROPERTY_HINT_PASSWORD, ""],
		"tripo_api_key": [TYPE_STRING, PROPERTY_HINT_PASSWORD, ""],
		"default_provider": [TYPE_STRING, PROPERTY_HINT_ENUM, "meshy,tripo"],
		"candidates": [TYPE_INT, PROPERTY_HINT_RANGE, "1,%d,1" % MAX_CANDIDATES],
		"daily_task_limit": [TYPE_INT, PROPERTY_HINT_RANGE, "0,500,1"],
		"meshy_base_url": [TYPE_STRING, PROPERTY_HINT_NONE, ""],
		"tripo_base_url": [TYPE_STRING, PROPERTY_HINT_NONE, ""],
		"inbox_dirs": [TYPE_STRING, PROPERTY_HINT_NONE, ""],
	}
	for key in SETTING_DEFAULTS:
		var name: String = SETTING_PREFIX + key
		if not es.has_setting(name):
			es.set_setting(name, SETTING_DEFAULTS[key])
		es.set_initial_value(name, SETTING_DEFAULTS[key], false)
		es.add_property_info({"name": name, "type": hints[key][0], "hint": hints[key][1], "hint_string": hints[key][2]})


func setting(key: String) -> Variant:
	if settings_override.has(key):
		return settings_override[key]
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		if es != null and es.has_setting(SETTING_PREFIX + key):
			return es.get_setting(SETTING_PREFIX + key)
	return SETTING_DEFAULTS.get(key)


## {key, source}; key "" when none is set. The key itself is never reported.
func api_key(provider: String) -> Dictionary:
	var from_settings := String(setting(provider + "_api_key")).strip_edges()
	if not from_settings.is_empty():
		return {"key": from_settings, "source": "editor_settings"}
	if not settings_override.has(provider + "_api_key"):
		var env := OS.get_environment(KEY_ENV[provider]).strip_edges()
		if not env.is_empty():
			return {"key": env, "source": "environment"}
	return {"key": "", "source": "missing"}


func base_url(provider: String) -> String:
	var custom := String(setting(provider + "_base_url")).strip_edges().trim_suffix("/")
	return custom if not custom.is_empty() else Providers.DEFAULT_BASE[provider]


static func missing_key_message(provider: String) -> String:
	return ("No %s API key. Ask the user to enter it themselves (never paste it into the chat): Godot > Editor > Editor Settings, "
		+ "turn on Advanced Settings, search \"%s_api_key\" (section Topdown Shooter > Asset Generation) and paste the key there; "
		+ "or set the %s environment variable before starting Godot. The key stays in the editor's settings, outside the project and git.") % [
			provider.capitalize(), provider, KEY_ENV[provider]]


# =============================================================================
# style preset and prompts
# =============================================================================

## The project's preset, created from the template on first use (unless
## `write` is false). {preset, path, created} or an error.
static func load_preset(write: bool) -> Variant:
	var created := false
	if not FileAccess.file_exists(PRESET_PATH):
		var text := FileAccess.get_file_as_string(PRESET_TEMPLATE)
		if text.is_empty():
			return Util.error(Util.INTERNAL_ERROR, "style preset template %s is missing" % PRESET_TEMPLATE)
		if write:
			var err := Util.ensure_dir(PRESET_PATH.get_base_dir())
			var f := FileAccess.open(PRESET_PATH, FileAccess.WRITE) if err == OK else null
			if f == null:
				return Util.error(Util.INTERNAL_ERROR, "cannot write %s" % PRESET_PATH)
			f.store_string(text)
			f.close()
			created = true
		var parsed: Variant = JSON.parse_string(text)
		return {"preset": parsed, "path": PRESET_PATH, "created": created, "from_template": not write}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(PRESET_PATH)) != OK or not json.data is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "%s is not valid JSON (line %d: %s); fix it or delete it to get the default back" % [PRESET_PATH, json.get_error_line(), json.get_error_message()])
	return {"preset": json.data, "path": PRESET_PATH, "created": false}


## Builds the prompts. {prompt, negative_prompt, texture_prompt,
## target_polycount, provider_options} or an error.
static func compose_prompt(preset: Dictionary, kind: String, user_prompt: String, provider: String, use_style := true) -> Variant:
	var lower := user_prompt.to_lower()
	for term in preset.get("blocked_terms", []):
		if not String(term).is_empty() and lower.contains(String(term).to_lower()):
			return Util.error(Util.INVALID_PARAMS, "the prompt contains the blocked term '%s' (style_preset.json blocked_terms)" % term)
	var kinds: Dictionary = preset.get("kinds", {})
	var kind_cfg: Dictionary = kinds.get(kind, {})
	var parts: Array[String] = [user_prompt.strip_edges().trim_suffix(".")]
	if use_style:
		for extra in [String(kind_cfg.get("prompt", "")), String(preset.get("style", ""))]:
			if not extra.strip_edges().is_empty():
				parts.append(extra.strip_edges())
	var prompt := ", ".join(parts)
	var limit: int = Providers.PROMPT_LIMIT[provider]
	if prompt.length() > limit:
		return Util.error(Util.INVALID_PARAMS, "the prompt is %d characters with the style preset; %s takes %d. Shorten the prompt by %d (or the preset's style line)." % [
			prompt.length(), provider.capitalize(), limit, prompt.length() - limit])
	var negative := String(preset.get("negative", "")) if use_style else ""
	var neg_limit: int = Providers.NEGATIVE_LIMIT[provider]
	if neg_limit <= 0:
		negative = ""
	elif negative.length() > neg_limit:
		negative = negative.left(neg_limit).rsplit(",", true, 1)[0]
	var texture := user_prompt.strip_edges()
	if use_style and not String(preset.get("texture_style", "")).is_empty():
		texture += ", " + String(preset.texture_style)
	var budget := int(kind_cfg.get("target_polycount", AssetTools.BUDGETS[kind].triangles))
	var all_opts: Dictionary = preset.get("provider_options", {})
	return {
		"prompt": prompt,
		"negative_prompt": negative,
		"texture_prompt": texture.left(600),
		"target_polycount": clampi(budget, 100, 300000),
		"provider_options": all_opts.get(provider, {}) if all_opts.get(provider) is Dictionary else {},
	}


## Estimated credits for a job: drafts now, the texture task later.
static func estimate_credits(preset: Dictionary, provider: String, mode: String, candidates: int, texture_on_pick: bool) -> Dictionary:
	var table: Dictionary = Providers.CREDITS[provider].duplicate()
	var custom: Variant = preset.get("credits", {})
	if custom is Dictionary and custom.get(provider) is Dictionary:
		table.merge(custom[provider], true)
	var draft := int(table.image_draft if mode == "image" else table.text_draft)
	var texture := int(table.texture) if mode == "text" and texture_on_pick else 0
	return {
		"per_candidate": draft,
		"candidates_total": draft * candidates,
		"texture_on_pick": texture,
		"total": draft * candidates + texture,
		"tasks": candidates + (1 if texture > 0 else 0),
		"note": "estimate from the %s price list; the job records what the service reports" % provider.capitalize(),
	}


## A prompt from the item sheet (name, description, category) when none is
## given. "" when the item is not found.
static func prompt_from_item(item_id: String, database_path: String) -> String:
	var path := database_path.get_base_dir() + "/" + item_id + ".tres"
	var item: Resource = null
	if FileAccess.file_exists(path):
		item = load(path)
	elif FileAccess.file_exists(database_path):
		var db := load(database_path)
		if db != null and db.has_method("get_item"):
			item = db.call("get_item", item_id)
	if item == null:
		return ""
	var parts: Array[String] = []
	for key in ["display_name", "description"]:
		var v: Variant = item.get(key)
		if v is String and not String(v).strip_edges().is_empty():
			parts.append(String(v).strip_edges().replace("\n", " "))
	var cat: Variant = item.get("category")
	if cat is String and not String(cat).is_empty() and String(cat) != "misc":
		parts.append(String(cat) + " item")
	return ", ".join(parts)


# =============================================================================
# daily usage
# =============================================================================

func usage_path() -> String:
	if not usage_path_override.is_empty():
		return usage_path_override
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_paths().get_data_dir().path_join("topdown_shooter_tools/generation_usage.json")
	return OS.get_user_data_dir().path_join("generation_usage.json")


func today() -> String:
	return today_override if not today_override.is_empty() else Time.get_date_string_from_system()


func usage_today() -> Dictionary:
	var data: Variant = AssetTools.read_json(usage_path())
	var limit := int(setting("daily_task_limit"))
	var day: Dictionary = {}
	if data is Dictionary and data.get("days") is Dictionary and data.days.get(today()) is Dictionary:
		day = data.days[today()]
	var used := int(day.get("tasks", 0))
	return {"date": today(), "tasks": used, "estimated_credits": int(day.get("credits", 0)), "limit": limit,
		"remaining": maxi(0, limit - used) if limit > 0 else -1}


## An error when `tasks` more would pass the daily limit, else {}.
func check_limit(tasks: int) -> Dictionary:
	var u := usage_today()
	if u.limit > 0 and u.tasks + tasks > u.limit:
		return Util.error(Util.INVALID_PARAMS, "daily generation limit: %d of %d tasks used today, this needs %d. Raise Editor Settings > %sdaily_task_limit (ask the user first) or wait until tomorrow." % [
			u.tasks, u.limit, tasks, SETTING_PREFIX])
	return {}


func record_usage(tasks: int, credits: int, note: String) -> void:
	var path := usage_path()
	var data: Variant = AssetTools.read_json(path)
	if not data is Dictionary or not data.get("days") is Dictionary:
		data = {"days": {}}
	var day: Dictionary = data.days.get(today(), {"tasks": 0, "credits": 0, "log": []})
	day.tasks = int(day.get("tasks", 0)) + tasks
	day.credits = int(day.get("credits", 0)) + credits
	var log: Array = day.get("log", [])
	log.append({"time": Time.get_time_string_from_system(), "tasks": tasks, "credits": credits, "what": note})
	day.log = log.slice(-100)
	data.days[today()] = day
	## Keep 31 days.
	var dates: Array = data.days.keys()
	dates.sort()
	while dates.size() > 31:
		data.days.erase(dates.pop_front())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()


# =============================================================================
# job records
# =============================================================================

static func job_path(asset_id: String) -> String:
	return AssetTools.work_dir(asset_id) + "/job.json"


static func load_job(asset_id: String) -> Variant:
	var job: Variant = AssetTools.read_json(job_path(asset_id))
	return job if job is Dictionary else null


static func save_job(job: Dictionary) -> String:
	var dir := AssetTools.work_dir(job.asset_id)
	var err := AssetTools.ensure_sources_dir(dir)
	if not err.is_empty():
		return err
	job["updated"] = Time.get_datetime_string_from_system(false, true)
	var f := FileAccess.open(job_path(job.asset_id), FileAccess.WRITE)
	if f == null:
		return "cannot write %s" % job_path(job.asset_id)
	f.store_string(JSON.stringify(job, "  "))
	f.close()
	return ""


static func log_step(job: Dictionary, step: String, info: Dictionary = {}) -> void:
	var entry := {"time": Time.get_datetime_string_from_system(false, true), "step": step}
	entry.merge(info)
	var steps: Array = job.get("steps", [])
	steps.append(entry)
	job["steps"] = steps.slice(-80)


## A previous job file is kept as job_<time>.json when a new one starts.
static func archive_job(asset_id: String) -> void:
	var path := job_path(asset_id)
	if not FileAccess.file_exists(path):
		return
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "").replace("-", "").replace("T", "_")
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(AssetTools.work_dir(asset_id) + "/job_%s.json" % stamp))


static func candidate_preview_path(asset_id: String, index: int, suffix := "") -> String:
	return AssetTools.work_dir(asset_id) + "/candidates/c%d%s.png" % [index, suffix]


static func raw_model_path(asset_id: String) -> String:
	return AssetTools.work_dir(asset_id) + "/" + asset_id + "_raw.glb"


# =============================================================================
# asset_generate
# =============================================================================

func asset_generate(params: Dictionary, ctx = null) -> Dictionary:
	var p: Variant = read_generate_params(params, GENERATE_KEYS)
	if Util.is_error(p):
		return p
	var plan: Variant = plan_generation(p)
	if Util.is_error(plan):
		return plan
	if p.dry_run:
		return {"data": plan}
	return _run(ctx, p.asset_id, _generate_async.bind(p, plan))


const GENERATE_KEYS := ["kind", "asset_id", "prompt", "reference_image", "provider", "candidates", "texture_on_pick",
	"target_polycount", "use_style", "database_path", "overwrite", "dry_run"]


func read_generate_params(params: Dictionary, allowed: Array) -> Variant:
	for key in params:
		if not key in allowed:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(allowed)])
	var kind: Variant = Util.text(params, "kind", "")
	var asset_id: Variant = Util.text(params, "asset_id", "")
	var prompt: Variant = Util.text(params, "prompt", "")
	var image: Variant = Util.text(params, "reference_image", "")
	var provider: Variant = Util.text(params, "provider", String(setting("default_provider")))
	var count: Variant = Util.integer(params, "candidates", clampi(int(setting("candidates")), 1, MAX_CANDIDATES), 1, MAX_CANDIDATES)
	var texture_on_pick: Variant = Util.boolean(params, "texture_on_pick", true)
	var polycount: Variant = Util.integer(params, "target_polycount", 0, 0, 300000)
	var use_style: Variant = Util.boolean(params, "use_style", true)
	var db: Variant = Util.text(params, "database_path", DEFAULT_DATABASE)
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var dry: Variant = Util.boolean(params, "dry_run", false)
	for v in [kind, asset_id, prompt, image, provider, count, texture_on_pick, polycount, use_style, db, overwrite, dry]:
		if Util.is_error(v):
			return v
	if not kind in AssetTools.KINDS:
		return Util.error(Util.INVALID_PARAMS, "'kind' must be one of %s" % ", ".join(AssetTools.KINDS))
	if not AssetTools.is_asset_id(asset_id):
		return Util.error(Util.INVALID_PARAMS, "'asset_id' must be lowercase letters, digits and _ (the item/weapon id, e.g. medkit, smg)")
	provider = String(provider).to_lower()
	if not provider in Providers.PROVIDERS:
		return Util.error(Util.INVALID_PARAMS, "'provider' must be one of %s" % ", ".join(Providers.PROVIDERS))
	if String(prompt).length() > 1000:
		return Util.error(Util.INVALID_PARAMS, "'prompt' is too long (%d characters; keep it under 300)" % String(prompt).length())
	return {"kind": kind, "asset_id": asset_id, "prompt": prompt, "reference_image": image, "provider": provider,
		"candidates": count, "texture_on_pick": texture_on_pick, "target_polycount": polycount, "use_style": use_style,
		"database_path": db, "overwrite": overwrite, "dry_run": dry}


## Checks everything that can be checked without spending credits. Returns
## the plan (what dry_run shows) or an error.
func plan_generation(p: Dictionary) -> Variant:
	var existing: Variant = load_job(p.asset_id)
	if existing != null and String(existing.get("stage", "")) in ACTIVE_STAGES and not p.overwrite:
		return Util.error(Util.ALREADY_EXISTS, "asset '%s' already has a job (stage %s). Continue it with asset_job/asset_pipeline asset_id=%s, or pass overwrite=true to start a new one (the old job file is kept as job_<time>.json)." % [
			p.asset_id, existing.stage, p.asset_id])
	## The preset file is written only by a call that will go ahead.
	var key := api_key(p.provider)
	var loaded: Variant = load_preset(not p.dry_run and not key.key.is_empty())
	if Util.is_error(loaded):
		return loaded
	var prompt: String = p.prompt
	var prompt_source := "param"
	if prompt.is_empty() and p.kind == "item":
		prompt = prompt_from_item(p.asset_id, p.database_path)
		prompt_source = "item sheet"
	var mode := "image" if not String(p.reference_image).is_empty() else "text"
	if prompt.is_empty() and mode == "text":
		return Util.error(Util.INVALID_PARAMS, "'prompt' is required (what to make, e.g. \"compact submachine gun with a folding stock\"); items can take it from the item sheet")
	var image: Variant = null
	if mode == "image":
		image = check_reference_image(p.reference_image)
		if Util.is_error(image):
			return image
	var composed: Variant = compose_prompt(loaded.preset, p.kind, prompt if not prompt.is_empty() else String(p.kind), p.provider, p.use_style)
	if Util.is_error(composed):
		return composed
	if p.target_polycount > 0:
		composed.target_polycount = p.target_polycount
	var tasks: int = p.candidates
	var plan := {
		"dry_run": p.dry_run,
		"asset_id": p.asset_id,
		"kind": p.kind,
		"provider": p.provider,
		"mode": mode,
		"candidates": p.candidates,
		"texture_on_pick": p.texture_on_pick and mode == "text",
		"prompt": composed.prompt,
		"prompt_source": prompt_source,
		"prompt_length": "%d/%d" % [String(composed.prompt).length(), Providers.PROMPT_LIMIT[p.provider]],
		"negative_prompt": composed.negative_prompt,
		"texture_prompt": composed.texture_prompt if mode == "text" and p.texture_on_pick else "",
		"target_polycount": composed.target_polycount,
		"style_preset": loaded.path + (" (created)" if loaded.created else (" (not created yet: dry_run)" if loaded.get("from_template", false) else "")),
		"estimated_credits": estimate_credits(loaded.preset, p.provider, mode, p.candidates, p.texture_on_pick),
		"usage_today": usage_today(),
		"api_key": key.source,
		"job_file": job_path(p.asset_id),
	}
	if image != null:
		plan["reference_image"] = image.describe
	plan["_composed"] = composed
	plan["_image"] = image
	if key.key.is_empty():
		if p.dry_run:
			plan["warning"] = missing_key_message(p.provider)
		else:
			return Util.error(Util.INVALID_PARAMS, missing_key_message(p.provider))
	var limit := check_limit(tasks)
	if not limit.is_empty():
		if p.dry_run:
			plan["warning_limit"] = limit.error.message
		else:
			return limit
	if p.dry_run:
		plan.erase("_composed")
		plan.erase("_image")
		plan["next"] = "Show the user the prompt and the estimated credits; with their OK call again without dry_run."
	return plan


## {kind: url|file, value (url or absolute path), describe} or an error.
static func check_reference_image(value: String) -> Variant:
	if value.begins_with("https://") or value.begins_with("http://"):
		return {"kind": "url", "value": value, "describe": value.left(200)}
	var path := AssetTools.resolve_source(value)
	var abs := ProjectSettings.globalize_path(path) if path.contains("://") else path
	if not FileAccess.file_exists(abs):
		return Util.error(Util.INVALID_PARAMS, "reference_image not found: %s (an https URL or a .png/.jpg/.webp file)" % value)
	if not abs.get_extension().to_lower() in IMAGE_EXTENSIONS:
		return Util.error(Util.INVALID_PARAMS, "reference_image must be .png, .jpg or .webp")
	var f := FileAccess.open(abs, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	if size <= 0 or size > MAX_IMAGE_BYTES:
		return Util.error(Util.INVALID_PARAMS, "reference_image must be 1 byte to 20 MB (got %d bytes)" % size)
	return {"kind": "file", "value": abs, "describe": abs}


func _generate_async(p: Dictionary, plan: Dictionary) -> Dictionary:
	var key: String = api_key(p.provider).key
	var base := base_url(p.provider)
	var composed: Dictionary = plan._composed
	var job := {
		"version": 1,
		"job_id": p.asset_id,
		"asset_id": p.asset_id,
		"kind": p.kind,
		"provider": p.provider,
		"mode": plan.mode,
		"prompt": p.prompt,
		"full_prompt": composed.prompt,
		"negative_prompt": composed.negative_prompt,
		"texture_prompt": composed.texture_prompt,
		"target_polycount": composed.target_polycount,
		"provider_options": composed.provider_options,
		"texture_on_pick": plan.texture_on_pick,
		"reference_image": plan.get("reference_image", ""),
		"estimated_credits": plan.estimated_credits,
		"created": Time.get_datetime_string_from_system(false, true),
		"stage": "generating",
		"candidates": [],
		"pick": null,
		"steps": [],
	}
	## The image goes up once and serves every candidate.
	var image_ref := ""
	if plan.mode == "image":
		var img: Dictionary = plan._image
		var copy := AssetTools.work_dir(p.asset_id) + "/reference." + String(img.value).get_extension().to_lower()
		if img.kind == "file":
			AssetTools.ensure_sources_dir(AssetTools.work_dir(p.asset_id))
			DirAccess.copy_absolute(img.value, ProjectSettings.globalize_path(copy))
			job.reference_copy = copy
		if img.kind == "url":
			image_ref = img.value
		elif p.provider == "meshy":
			var bytes := FileAccess.get_file_as_bytes(img.value)
			var ext := String(img.value).get_extension().to_lower()
			var mime := "image/png" if ext == "png" else ("image/webp" if ext == "webp" else "image/jpeg")
			image_ref = "data:%s;base64,%s" % [mime, Marshalls.raw_to_base64(bytes)]
		else:
			var up: Dictionary = await transport.request(Providers.upload_request(p.provider, base, key, img.value), 60.0)
			var token := Providers.parse_upload(int(up.code), up.json)
			if token.has("error"):
				return Util.error(Util.INTERNAL_ERROR, "uploading the reference image failed: " + String(token.error))
			image_ref = token.file_token
	if load_job(p.asset_id) != null:
		archive_job(p.asset_id)
	var opts := {"prompt": composed.prompt, "negative_prompt": composed.negative_prompt, "texture_prompt": composed.texture_prompt,
		"target_polycount": composed.target_polycount, "kind": p.kind, "provider_options": composed.provider_options}
	var created := 0
	var errors: Array = []
	for i in p.candidates:
		opts["seed"] = randi_range(1, 2000000000)
		var req: Dictionary
		if plan.mode == "image":
			req = Providers.image_draft_request(p.provider, base, key, image_ref, opts)
		else:
			req = Providers.text_draft_request(p.provider, base, key, opts)
		var res: Dictionary = await transport.request(req, 30.0)
		var parsed := Providers.parse_create(p.provider, int(res.code), res.json)
		var cand := {"index": i + 1, "endpoint": req.endpoint, "status": "queued", "progress": 0, "seed": opts.seed}
		if parsed.has("error"):
			cand.status = "failed"
			cand.error = parsed.error
			errors.append(parsed.error)
			job.candidates.append(cand)
			## Charges and limits apply to every create; stop at the first refusal.
			if int(res.code) in [401, 402, 403, 429] or int(res.code) == 0:
				break
			continue
		cand.task_id = parsed.task_id
		job.candidates.append(cand)
		created += 1
	var draft_cost: int = plan.estimated_credits.per_candidate
	if created > 0:
		record_usage(created, created * draft_cost, "%s %s: %d candidate(s)" % [p.provider, p.asset_id, created])
	log_step(job, "generate", {"created": created, "errors": errors})
	if created == 0:
		job.stage = "failed"
		save_job(job)
		return Util.error(Util.INTERNAL_ERROR, "no candidate started: " + "; ".join(errors))
	var err := save_job(job)
	if not err.is_empty():
		return Util.error(Util.INTERNAL_ERROR, err + " (the provider tasks were started: %s)" % JSON.stringify(job.candidates))
	var data := summarize(job)
	data["next"] = "Generation takes 1-5 minutes. Then call asset_job op=status asset_id=%s (or asset_pipeline asset_id=%s) to see the candidates." % [p.asset_id, p.asset_id]
	if not errors.is_empty():
		data["errors"] = errors
	return {"data": data}


# =============================================================================
# asset_job
# =============================================================================

const JOB_KEYS := ["op", "asset_id", "job_id", "index", "render", "repick", "provider", "dir"]


func asset_job(params: Dictionary, ctx = null) -> Dictionary:
	for key in params:
		if not key in JOB_KEYS:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(JOB_KEYS)])
	var op: Variant = Util.text(params, "op", "status")
	if Util.is_error(op):
		return op
	if not op in JOB_OPS:
		return Util.error(Util.INVALID_PARAMS, "'op' must be one of %s" % ", ".join(JOB_OPS))
	if op == "list":
		return {"data": list_jobs()}
	if op == "inbox":
		var dir: Variant = Util.text(params, "dir", "")
		if Util.is_error(dir):
			return dir
		return {"data": inbox(String(dir))}
	if op == "balance":
		return _run(ctx, "", _balance_async.bind(String(params.get("provider", ""))))
	var asset_id: Variant = Util.text(params, "asset_id", String(params.get("job_id", "")))
	if Util.is_error(asset_id):
		return asset_id
	if not AssetTools.is_asset_id(asset_id):
		return Util.error(Util.INVALID_PARAMS, "'asset_id' (the job id) is required")
	var job: Variant = load_job(asset_id)
	if job == null:
		return Util.error(Util.NODE_NOT_FOUND, "no job for '%s' (%s); start one with asset_generate" % [asset_id, job_path(asset_id)])
	var index: Variant = Util.integer(params, "index", 0, 0, MAX_CANDIDATES)
	var render: Variant = Util.boolean(params, "render", true)
	var repick: Variant = Util.boolean(params, "repick", false)
	for v in [index, render, repick]:
		if Util.is_error(v):
			return v
	if job.get("mode") == "external" and op in ["pick", "download", "preview"]:
		return Util.error(Util.INVALID_PARAMS, "'%s' was made outside these tools (source %s): there is nothing to %s. asset_pipeline asset_id=%s continues with cleanup, import and swap." % [asset_id, job.get("source", ""), op, asset_id])
	match op:
		"cancel":
			return {"data": cancel_job(job)}
		"pick":
			var check := _check_pick(job, index, repick)
			if not check.is_empty():
				return check
	return _run(ctx, asset_id, _job_async.bind(op, job, {"index": index, "render": render, "repick": repick}))


func _job_async(op: String, job: Dictionary, opts: Dictionary) -> Dictionary:
	var deadline := _deadline()
	var notes: Array = []
	match op:
		"status":
			await refresh(job, notes)
		"preview":
			await refresh(job, notes)
			if opts.render:
				await render_candidates(job, notes, deadline)
		"pick":
			var r: Dictionary = await pick(job, opts.index, notes)
			if Util.is_error(r):
				return r
		"download":
			await refresh(job, notes)
			var d: Dictionary = await download_pick(job, notes)
			if Util.is_error(d):
				return d
	save_job(job)
	var data := summarize(job)
	if not notes.is_empty():
		data["notes"] = notes
	data["next"] = next_hint(job)
	return {"data": data}


## Polls every unfinished task, saves candidate thumbnails, moves the stage.
func refresh(job: Dictionary, notes: Array) -> void:
	if job.get("mode") == "external":
		return
	var key: String = api_key(job.provider).key
	if key.is_empty():
		notes.append(missing_key_message(job.provider))
		return
	var base := base_url(job.provider)
	for cand in job.candidates:
		if cand.has("task_id") and not cand.status in Providers.TERMINAL:
			await _poll_task(job.provider, base, key, cand, notes)
		if cand.status == "succeeded" and not String(cand.get("thumbnail_url", "")).is_empty() and not cand.has("preview"):
			var png := candidate_preview_path(job.asset_id, int(cand.index))
			var got: Dictionary = await transport.download(cand.thumbnail_url, ProjectSettings.globalize_path(png), 30.0)
			if got.get("ok", false):
				cand.preview = png
			else:
				notes.append("candidate %d preview: %s" % [cand.index, got.get("error", "")])
	var pick: Variant = job.get("pick")
	if pick is Dictionary and pick.get("texture") is Dictionary:
		var tex: Dictionary = pick.texture
		if tex.has("task_id") and not tex.status in Providers.TERMINAL:
			await _poll_task(job.provider, base, key, tex, notes)
	_update_stage(job)


func _poll_task(provider: String, base: String, key: String, task: Dictionary, notes: Array) -> void:
	var res: Dictionary = await transport.request(Providers.status_request(provider, base, key, task.endpoint, task.task_id), 20.0)
	var st := Providers.parse_status(provider, int(res.code), res.json)
	if String(st.status).is_empty():
		notes.append("task %s: %s" % [task.task_id, st.error])
		return
	task.status = st.status
	task.progress = st.progress
	if not String(st.model_url).is_empty():
		task.model_url = st.model_url
	if not String(st.thumbnail_url).is_empty():
		task.thumbnail_url = st.thumbnail_url
	if not String(st.error).is_empty():
		task.error = st.error
	if st.credits != null:
		task.credits = st.credits


func _update_stage(job: Dictionary) -> void:
	var stage := String(job.stage)
	if stage == "generating":
		var done := 0
		var ok := 0
		for cand in job.candidates:
			if cand.status in Providers.TERMINAL:
				done += 1
			if cand.status == "succeeded":
				ok += 1
		if done == job.candidates.size():
			job.stage = "candidates_ready" if ok > 0 else "failed"
			log_step(job, job.stage, {"succeeded": ok})
	elif stage == "texturing":
		var tex: Dictionary = job.pick.texture
		if tex.status == "succeeded":
			job.pick.model_url = tex.get("model_url", "")
			job.stage = "ready"
			log_step(job, "textured")
		elif tex.status in ["failed", "canceled"]:
			job.stage = "candidates_ready"
			log_step(job, "texture_failed", {"error": tex.get("error", "")})


func _check_pick(job: Dictionary, index: int, repick: bool) -> Dictionary:
	if index < 1 or index > job.candidates.size():
		return Util.error(Util.INVALID_PARAMS, "'index' must be a candidate number 1..%d" % job.candidates.size())
	if job.candidates[index - 1].status != "succeeded":
		return Util.error(Util.INVALID_PARAMS, "candidate %d is %s, not finished; pick one that succeeded (asset_job op=status)" % [index, job.candidates[index - 1].status])
	if job.get("pick") is Dictionary and not repick:
		if int(job.pick.index) == index:
			return {}
		return Util.error(Util.ALREADY_EXISTS, "candidate %d is already picked (stage %s); pass repick=true to pick %d instead (a text job textures it again: one more task)" % [job.pick.index, job.stage, index])
	if not job.stage in ["candidates_ready", "texturing", "ready", "downloaded", "imported", "swapped", "done"]:
		return Util.error(Util.INVALID_PARAMS, "the job is at stage %s; candidates are not ready yet" % job.stage)
	return {}


## Picks candidate `index`: text jobs start the texture task, image jobs are
## ready at once.
func pick(job: Dictionary, index: int, notes: Array) -> Dictionary:
	if job.get("pick") is Dictionary and int(job.pick.index) == index:
		notes.append("candidate %d was already picked" % index)
		return {}
	var cand: Dictionary = job.candidates[index - 1]
	var pick := {"index": index, "draft_task_id": cand.get("task_id", ""), "texture": null, "model_url": ""}
	if job.mode == "text" and job.texture_on_pick:
		var limit := check_limit(1)
		if not limit.is_empty():
			return limit
		var key: String = api_key(job.provider).key
		if key.is_empty():
			return Util.error(Util.INVALID_PARAMS, missing_key_message(job.provider))
		var opts := {"texture_prompt": job.get("texture_prompt", ""), "provider_options": job.get("provider_options", {})}
		var req := Providers.texture_request(job.provider, base_url(job.provider), key, cand.task_id, opts)
		var res: Dictionary = await transport.request(req, 30.0)
		var parsed := Providers.parse_create(job.provider, int(res.code), res.json)
		if parsed.has("error"):
			return Util.error(Util.INTERNAL_ERROR, "texturing candidate %d did not start: %s" % [index, parsed.error])
		pick.texture = {"task_id": parsed.task_id, "endpoint": req.endpoint, "status": "queued", "progress": 0}
		record_usage(1, int(job.estimated_credits.get("texture_on_pick", 0)), "%s %s: texture candidate %d" % [job.provider, job.asset_id, index])
		job.stage = "texturing"
	else:
		pick.model_url = cand.get("model_url", "")
		job.stage = "ready"
	job.pick = pick
	log_step(job, "pick", {"index": index})
	return {}


## Downloads the picked model to asset_sources/<id>/<id>_raw.glb.
func download_pick(job: Dictionary, notes: Array) -> Dictionary:
	if job.stage == "texturing":
		return Util.error(Util.EDITOR_NOT_READY, "the picked candidate is still being textured (%d%%); try again in a minute" % int(job.pick.texture.get("progress", 0)))
	if not job.get("pick") is Dictionary or String(job.pick.get("model_url", "")).is_empty():
		return Util.error(Util.INVALID_PARAMS, "nothing to download: pick a candidate first (stage %s)" % job.stage)
	var raw := raw_model_path(job.asset_id)
	var got: Dictionary = await transport.download(job.pick.model_url, ProjectSettings.globalize_path(raw), 100.0)
	if not got.get("ok", false):
		return Util.error(Util.INTERNAL_ERROR, String(got.get("error", "download failed")))
	job.raw_model = raw
	if job.stage == "ready":
		job.stage = "downloaded"
	log_step(job, "download", {"path": raw, "bytes": got.get("bytes", 0)})
	notes.append("downloaded %s (%d KB)" % [raw, int(got.get("bytes", 0)) / 1024])
	return {}


## Top-down renders of the finished candidates (downloads each draft once).
func render_candidates(job: Dictionary, notes: Array, deadline: int) -> void:
	if DisplayServer.get_name() == "headless" or not Engine.is_editor_hint():
		notes.append("top-down renders skipped (needs the Godot window); the service thumbnails are in candidates/")
		return
	for cand in job.candidates:
		if cand.status != "succeeded" or String(cand.get("model_url", "")).is_empty():
			continue
		if deadline > 0 and deadline - Time.get_ticks_msec() < 20000:
			notes.append("out of time for more renders; call op=preview again")
			return
		var glb := AssetTools.work_dir(job.asset_id) + "/candidates/c%d.glb" % cand.index
		if not FileAccess.file_exists(glb):
			var got: Dictionary = await transport.download(cand.model_url, ProjectSettings.globalize_path(glb), 60.0)
			if not got.get("ok", false):
				notes.append("candidate %d: %s" % [cand.index, got.get("error", "")])
				continue
		var png := candidate_preview_path(job.asset_id, int(cand.index), "_top")
		var r: Variant = await render_gltf(glb, png, deadline)
		if r is Dictionary:
			cand.preview_top = png
		else:
			notes.append("candidate %d render: %s" % [cand.index, r])


## Loads a .glb at runtime (no import) and renders it like AssetTools does.
func render_gltf(glb_path: String, png_path: String, deadline: int) -> Variant:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(glb_path), state) != OK:
		return "cannot read %s" % glb_path
	var root := doc.generate_scene(state) as Node3D
	if root == null:
		return "no scene in %s" % glb_path
	_bake_importer_meshes(root)
	var stop := Time.get_ticks_msec() + AssetTools.PREVIEW_WAIT_MSEC
	if deadline > 0:
		stop = mini(stop, deadline)
	return await AssetTools.new().render_node(root, png_path, stop)


## In the editor GLTFDocument leaves ImporterMeshInstance3D nodes, which do
## not draw; swap them for MeshInstance3D.
static func _bake_importer_meshes(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is ImporterMeshInstance3D:
			var src := node as ImporterMeshInstance3D
			var mi := MeshInstance3D.new()
			mi.name = src.name
			mi.transform = src.transform
			mi.mesh = src.mesh.get_mesh() if src.mesh != null else null
			mi.skin = src.skin
			var parent := src.get_parent()
			var index := src.get_index()
			parent.add_child(mi)
			parent.move_child(mi, index)
			for child in src.get_children():
				child.reparent(mi, false)
			parent.remove_child(src)
			src.free()


static func cancel_job(job: Dictionary) -> Dictionary:
	var before := String(job.stage)
	job.stage = "canceled"
	log_step(job, "cancel", {"from": before})
	save_job(job)
	var data := summarize(job)
	data["note"] = "Marked canceled here. Tasks already running at the service finish there and keep their charge; nothing else is downloaded or imported for this job."
	return data


func _balance_async(only: String) -> Dictionary:
	var out := {"usage_today": usage_today(), "providers": {}}
	for provider in Providers.PROVIDERS:
		if not only.is_empty() and provider != only:
			continue
		var key := api_key(provider)
		if key.key.is_empty():
			out.providers[provider] = {"api_key": "missing", "how_to_set": missing_key_message(provider)}
			continue
		var res: Dictionary = await transport.request(Providers.balance_request(provider, base_url(provider), key.key), 15.0)
		var bal: Variant = Providers.parse_balance(provider, int(res.code), res.json)
		out.providers[provider] = {"api_key": key.source, "balance": bal} if bal != null else {"api_key": key.source, "error": Providers.describe_error(provider, int(res.code), res.json)}
	return {"data": out}


static func list_jobs() -> Dictionary:
	var jobs: Array = []
	var root := ProjectSettings.globalize_path(AssetTools.SOURCES_ROOT)
	var dir := DirAccess.open(root)
	if dir != null:
		for sub in dir.get_directories():
			var job: Variant = load_job(sub)
			if job != null:
				var done := 0
				for c in job.get("candidates", []):
					if c.get("status") == "succeeded":
						done += 1
				jobs.append({"asset_id": job.asset_id, "kind": job.get("kind"), "provider": job.get("provider"), "stage": job.get("stage"),
					"candidates": "%d/%d ready" % [done, job.get("candidates", []).size()], "pick": job.pick.index if job.get("pick") is Dictionary else null,
					"updated": job.get("updated", "")})
	jobs.sort_custom(func(a, b): return String(a.updated) > String(b.updated))
	return {"jobs": jobs, "count": jobs.size()}


## What a tool returns about a job (no signed URLs, no keys).
static func summarize(job: Dictionary) -> Dictionary:
	var cands: Array = []
	for c in job.get("candidates", []):
		var entry := {"index": int(c.index), "status": c.status, "progress": int(c.get("progress", 0))}
		if c.has("task_id"):
			entry["task_id"] = c.task_id
		for key in ["preview", "preview_top"]:
			if c.has(key):
				entry[key] = ProjectSettings.globalize_path(c[key])
		if c.has("error"):
			entry["error"] = c.error
		if c.get("credits") != null:
			entry["credits"] = c.credits
		cands.append(entry)
	var out := {
		"job_id": job.get("job_id", job.asset_id),
		"asset_id": job.asset_id,
		"kind": job.kind,
		"provider": job.provider,
		"mode": job.get("mode", "text"),
		"stage": job.stage,
		"prompt": job.get("full_prompt", ""),
		"candidates": cands,
		"job_file": ProjectSettings.globalize_path(job_path(job.asset_id)),
	}
	if job.get("pick") is Dictionary:
		var p: Dictionary = job.pick
		var pick := {"index": int(p.index)}
		if p.get("texture") is Dictionary:
			pick["texture"] = {"task_id": p.texture.get("task_id"), "status": p.texture.status, "progress": int(p.texture.get("progress", 0))}
			if p.texture.has("error"):
				pick.texture["error"] = p.texture.error
		out["pick"] = pick
	if job.has("raw_model"):
		out["raw_model"] = job.raw_model
	if job.has("source"):
		out["source"] = job.source
	return out


static func next_hint(job: Dictionary) -> String:
	var id: String = job.asset_id
	match String(job.stage):
		"generating":
			return "Still generating; check again in a minute: asset_job op=status asset_id=%s." % id
		"candidates_ready":
			return "Show the user the candidate previews (open the PNG paths) and let them choose; then asset_job op=pick asset_id=%s index=N (or asset_pipeline asset_id=%s pick=N)." % [id, id]
		"texturing":
			return "Texturing the pick; check again in a minute: asset_job op=status asset_id=%s." % id
		"ready":
			return "asset_job op=download asset_id=%s, or asset_pipeline asset_id=%s to download, clean, import and swap." % [id, id]
		"downloaded":
			return "asset_pipeline asset_id=%s continues with asset_cleanup -> asset_import -> swap_placeholder." % id
		"failed":
			return "Every candidate failed (see errors). Adjust the prompt and run asset_generate overwrite=true."
		"canceled":
			return "Canceled. asset_generate overwrite=true starts again."
	return "asset_pipeline asset_id=%s continues." % id


# =============================================================================
# asset_pipeline
# =============================================================================

const PIPELINE_KEYS := ["kind", "asset_id", "prompt", "reference_image", "provider", "candidates", "texture_on_pick",
	"target_polycount", "use_style", "database_path", "overwrite", "dry_run", "pick", "repick", "cleanup", "cleanup_options",
	"swap", "dest_dir", "preview", "inspect", "blender_path", "source", "icon"]
const PIPELINE_CONFIG_KEYS := ["cleanup", "cleanup_options", "swap", "dest_dir", "preview", "inspect", "blender_path", "icon"]


func asset_pipeline(params: Dictionary, ctx = null) -> Dictionary:
	for key in params:
		if not key in PIPELINE_KEYS:
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s' (allowed: %s)" % [key, ", ".join(PIPELINE_KEYS)])
	var asset_id: Variant = Util.text(params, "asset_id", "")
	if Util.is_error(asset_id):
		return asset_id
	if not AssetTools.is_asset_id(asset_id):
		return Util.error(Util.INVALID_PARAMS, "'asset_id' must be lowercase letters, digits and _ (the item/weapon id)")
	var job: Variant = load_job(asset_id)
	var starting: bool = job == null or not String(job.get("stage", "")) in ACTIVE_STAGES or params.get("overwrite", false) == true
	var config: Variant = read_pipeline_config(params, job)
	if Util.is_error(config):
		return config
	var pick_index: Variant = Util.integer(params, "pick", 0, 0, MAX_CANDIDATES)
	var repick: Variant = Util.boolean(params, "repick", false)
	for v in [pick_index, repick]:
		if Util.is_error(v):
			return v
	var source: Variant = Util.text(params, "source", "")
	if Util.is_error(source):
		return source
	if not String(source).is_empty():
		return _pipeline_adopt(params, asset_id, String(source), job, config, ctx)
	if starting:
		var gen_params := {}
		for key in GENERATE_KEYS:
			if params.has(key):
				gen_params[key] = params[key]
		var p: Variant = read_generate_params(gen_params, GENERATE_KEYS)
		if Util.is_error(p):
			return p
		var plan: Variant = plan_generation(p)
		if Util.is_error(plan):
			return plan
		var swap_check: Variant = _swap_params(p.kind, asset_id, config)
		if Util.is_error(swap_check):
			return swap_check
		if p.dry_run:
			plan["pipeline"] = {"cleanup": config.cleanup, "swap": swap_check if swap_check != null else "none (pass swap={target: ...} to replace a placeholder)",
				"steps": "generate -> wait -> STOP for the user's pick -> %s -> download -> %s -> asset_import -> %s -> inspection renders" % [
					"texture the pick" if plan.texture_on_pick else "(textured already)",
					"asset_cleanup (Blender)" if config.cleanup else "(no cleanup)",
					"swap_placeholder" if swap_check != null else "(no swap)"]}
			return {"data": plan}
		return _run(ctx, asset_id, _pipeline_start_async.bind(p, plan, config, ctx))
	if params.get("dry_run", false) == true:
		var data := summarize(job)
		data["dry_run"] = true
		data["next"] = next_hint(job)
		return {"data": data}
	if pick_index > 0:
		var check := _check_pick(job, pick_index, repick)
		if not check.is_empty():
			return check
	return _run(ctx, asset_id, _pipeline_continue_async.bind(job, config, pick_index, ctx))


## source=...: a model made elsewhere joins at "downloaded" and goes on to
## cleanup, import, swap and inspection in the same call. Spends no credits.
func _pipeline_adopt(params: Dictionary, asset_id: String, source: String, job: Variant, config: Dictionary, ctx) -> Dictionary:
	for key in ["reference_image", "candidates", "texture_on_pick", "pick", "repick"]:
		if params.has(key):
			return Util.error(Util.INVALID_PARAMS, "'%s' is for generation; with 'source' the model already exists" % key)
	var kind: Variant = Util.text(params, "kind", String(job.get("kind", "")) if job is Dictionary else "")
	var provider: Variant = Util.text(params, "provider", "other")
	var prompt: Variant = Util.text(params, "prompt", "")
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var dry: Variant = Util.boolean(params, "dry_run", false)
	for v in [kind, provider, prompt, overwrite, dry]:
		if Util.is_error(v):
			return v
	if not kind in AssetTools.KINDS:
		return Util.error(Util.INVALID_PARAMS, "'kind' must be one of %s" % ", ".join(AssetTools.KINDS))
	provider = String(provider).to_lower()
	if not provider in EXTERNAL_PROVIDERS:
		return Util.error(Util.INVALID_PARAMS, "'provider' with 'source' labels where the model came from: one of %s" % ", ".join(EXTERNAL_PROVIDERS))
	var src := AssetTools.resolve_source(source)
	if not FileAccess.file_exists(src):
		return Util.error(Util.INVALID_PARAMS, "source file not found: %s (asset_job op=inbox lists the models waiting in %s)" % [src, setting("inbox_dirs")])
	var ext := src.get_extension().to_lower()
	if not ext in ADOPT_EXTENSIONS:
		return Util.error(Util.INVALID_PARAMS, "source must be one of .%s" % ", .".join(ADOPT_EXTENSIONS))
	if ext == "blend" and not config.cleanup:
		return Util.error(Util.INVALID_PARAMS, "a .blend source needs cleanup=true (Blender exports it)")
	if job is Dictionary and String(job.get("stage", "")) in ACTIVE_STAGES and not overwrite:
		if job.get("mode") == "external" and AssetTools.resolve_source(String(job.get("source", ""))) == src:
			return _pipeline_resume_or_dry(job, config, dry, ctx)
		return Util.error(Util.ALREADY_EXISTS, "asset '%s' already has a job (stage %s). Continue it with asset_pipeline asset_id=%s (no source), or pass overwrite=true to replace it (the old job file is kept as job_<time>.json)." % [asset_id, job.stage, asset_id])
	var swap_check: Variant = _swap_params(kind, asset_id, config)
	if Util.is_error(swap_check):
		return swap_check
	if dry:
		return {"data": {"dry_run": true, "asset_id": asset_id, "kind": kind, "mode": "external", "provider": provider, "source": src,
			"estimated_credits": {"total": 0, "note": "made outside these tools: nothing is charged here"},
			"pipeline": {"cleanup": config.cleanup, "swap": swap_check if swap_check != null else "none (pass swap={target: ...} to replace a placeholder)",
				"steps": "copy the source to %s -> %s -> asset_import -> %s -> inspection renders" % [AssetTools.work_dir(asset_id),
					"asset_cleanup (Blender)" if config.cleanup else "(no cleanup)", "swap_placeholder" if swap_check != null else "(no swap)"]}}}
	var adopted: Variant = adopt_job(asset_id, String(kind), String(provider), src, String(prompt))
	if Util.is_error(adopted):
		return adopted
	adopted["pipeline"] = config
	var err := save_job(adopted)
	if not err.is_empty():
		return Util.error(Util.INTERNAL_ERROR, err)
	return _run(ctx, asset_id, _pipeline_continue_async.bind(adopted, config, 0, ctx))


func _pipeline_resume_or_dry(job: Dictionary, config: Dictionary, dry: bool, ctx) -> Dictionary:
	if dry:
		var data := summarize(job)
		data["dry_run"] = true
		data["next"] = next_hint(job)
		return {"data": data}
	return _run(ctx, job.asset_id, _pipeline_continue_async.bind(job, config, 0, ctx))


## A job record for a model made elsewhere. A .glb is copied next to the job
## (the original may be moved or re-exported later); .gltf/.obj/.fbx keep
## their side files where they are, so they are used in place.
func adopt_job(asset_id: String, kind: String, provider: String, src: String, prompt: String) -> Variant:
	var work := AssetTools.work_dir(asset_id)
	var dir_err := AssetTools.ensure_sources_dir(work)
	if not dir_err.is_empty():
		return Util.error(Util.INTERNAL_ERROR, dir_err)
	var raw := src
	if src.get_extension().to_lower() == "glb":
		raw = raw_model_path(asset_id)
		if ProjectSettings.globalize_path(raw) != ProjectSettings.globalize_path(src):
			var cp := DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(raw))
			if cp != OK:
				return Util.error(Util.INTERNAL_ERROR, "cannot copy %s: %s" % [src, error_string(cp)])
	if load_job(asset_id) != null:
		archive_job(asset_id)
	var job := {
		"version": 1,
		"job_id": asset_id,
		"asset_id": asset_id,
		"kind": kind,
		"provider": provider,
		"mode": "external",
		"prompt": prompt,
		"full_prompt": prompt,
		"source": src,
		"raw_model": raw,
		"estimated_credits": {"total": 0},
		"created": Time.get_datetime_string_from_system(false, true),
		"stage": "downloaded",
		"candidates": [],
		"pick": null,
		"steps": [],
	}
	log_step(job, "adopt", {"source": src, "raw_model": raw})
	return job


## Model files waiting to be used: the Tripo Godot Bridge's export folder
## (res://TripoModels) and any folder in Editor Settings inbox_dirs
## (comma separated), newest first, with the job that already used each.
func inbox(extra_dir: String) -> Dictionary:
	var dirs: Array[String] = []
	for d in String(setting("inbox_dirs")).split(",", false):
		if not d.strip_edges().is_empty():
			dirs.append(AssetTools.resolve_source(d.strip_edges()))
	if not extra_dir.is_empty():
		dirs.append(AssetTools.resolve_source(extra_dir))
	var used := {}
	for j in list_jobs().jobs:
		var job: Variant = load_job(j.asset_id)
		if job is Dictionary and job.has("source"):
			used[AssetTools.resolve_source(String(job.source))] = job.asset_id
	var files: Array = []
	var missing: Array[String] = []
	for d in dirs:
		if DirAccess.open(d) == null:
			missing.append(d)
			continue
		_collect_models(d, INBOX_DEPTH, files)
	files.sort_custom(func(a, b): return int(a._mtime) > int(b._mtime))
	var out: Array = []
	for f in files.slice(0, INBOX_LIMIT):
		var entry := {"path": f.path, "modified": Time.get_datetime_string_from_unix_time(int(f._mtime), true), "kb": int(f._bytes) / 1024}
		if used.has(f.path):
			entry["used_by"] = used[f.path]
		out.append(entry)
	var data := {"dirs": dirs, "models": out, "count": files.size()}
	if not missing.is_empty():
		data["missing_dirs"] = missing
	data["next"] = "asset_pipeline asset_id=<id> kind=<kind> source=<path> provider=tripo|meshy|other: cleanup, import, swap, inspection. dry_run=true shows the steps first."
	if files.is_empty():
		data["note"] = "No models yet. Tripo: export from Tripo Studio with the DCC Bridge (Godot) button; it lands in res://TripoModels. Meshy CLI: pass its output file as source, or add its folder to Editor Settings %sinbox_dirs." % SETTING_PREFIX
	return data


static func _collect_models(dir_path: String, depth: int, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		if name.get_extension().to_lower() in ADOPT_EXTENSIONS:
			var path := dir_path.path_join(name)
			var f := FileAccess.open(path, FileAccess.READ)
			out.append({"path": path, "_mtime": FileAccess.get_modified_time(path), "_bytes": f.get_length() if f != null else 0})
	if depth > 0:
		for sub in dir.get_directories():
			if not sub.begins_with("."):
				_collect_models(dir_path.path_join(sub), depth - 1, out)


## cleanup, cleanup_options, swap, dest_dir, preview, inspect, blender_path,
## from params, else from the job (so later calls need only asset_id).
func read_pipeline_config(params: Dictionary, job: Variant) -> Variant:
	var saved: Dictionary = job.get("pipeline", {}) if job is Dictionary and job.get("pipeline") is Dictionary else {}
	var cleanup: Variant = Util.boolean(params, "cleanup", bool(saved.get("cleanup", true)))
	var preview: Variant = Util.boolean(params, "preview", bool(saved.get("preview", true)))
	var inspect: Variant = Util.boolean(params, "inspect", bool(saved.get("inspect", true)))
	var dest_dir: Variant = Util.text(params, "dest_dir", String(saved.get("dest_dir", "")))
	var blender: Variant = Util.text(params, "blender_path", String(saved.get("blender_path", "")))
	for v in [cleanup, preview, inspect, dest_dir, blender]:
		if Util.is_error(v):
			return v
	var cleanup_options: Variant = params.get("cleanup_options", saved.get("cleanup_options", {}))
	if not cleanup_options is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "'cleanup_options' must be an object of asset_cleanup parameters (size, forward, origin, ...)")
	for key in cleanup_options:
		if key in ["source", "kind", "asset_id", "import", "dry_run", "overwrite"]:
			return Util.error(Util.INVALID_PARAMS, "cleanup_options.%s is set by the pipeline" % key)
	var swap: Variant = params.get("swap", saved.get("swap", null))
	if swap != null and not (swap is Dictionary or swap is bool):
		return Util.error(Util.INVALID_PARAMS, "'swap' must be false or a swap_placeholder object (target, scene, group, ...)")
	var icon: Variant = params.get("icon", saved.get("icon", true))
	if not (icon is Dictionary or icon is bool):
		return Util.error(Util.INVALID_PARAMS, "'icon' must be true, false or an object of item_icon_render parameters (cell_px, apply_grid, ...)")
	if icon is Dictionary:
		for key in icon:
			if key in ["item_id", "item_ids", "all", "model", "dry_run"]:
				return Util.error(Util.INVALID_PARAMS, "icon.%s is set by the pipeline" % key)
	return {"cleanup": cleanup, "cleanup_options": cleanup_options, "swap": swap, "dest_dir": dest_dir, "preview": preview,
		"inspect": inspect, "blender_path": blender, "icon": icon}


## swap_placeholder params for the job, null for no swap, or an error.
## Weapons and items swap by default; characters and props need swap={...}.
static func _swap_params(kind: String, asset_id: String, config: Dictionary) -> Variant:
	var swap: Variant = config.swap
	if swap is bool and swap == false:
		return null
	var params := {}
	if swap is Dictionary:
		params = (swap as Dictionary).duplicate()
	elif SWAP_TARGET_FOR_KIND.has(kind):
		params = {"target": SWAP_TARGET_FOR_KIND[kind]}
	else:
		return null
	if not params.has("target"):
		if not SWAP_TARGET_FOR_KIND.has(kind):
			return Util.error(Util.INVALID_PARAMS, "swap needs a target for a %s (player, enemy, map or node)" % kind)
		params["target"] = SWAP_TARGET_FOR_KIND[kind]
	for key in ["dry_run", "revert"]:
		if params.has(key):
			return Util.error(Util.INVALID_PARAMS, "swap.%s is not allowed in the pipeline" % key)
	match String(params.target):
		"item":
			if not params.has("item_id"):
				params["item_id"] = asset_id
		"weapon", "enemy":
			if not params.has("asset_id") and not params.has("scene"):
				params["asset_id"] = asset_id
	if not params.target in SwapTools.TARGETS:
		return Util.error(Util.INVALID_PARAMS, "swap.target must be one of %s" % ", ".join(SwapTools.TARGETS))
	for key in params:
		if not key in SWAP_KEYS:
			return Util.error(Util.INVALID_PARAMS, "unknown swap parameter '%s' (allowed: %s)" % [key, ", ".join(SWAP_KEYS)])
	return params


static func _with_model(params: Dictionary, model: String) -> Dictionary:
	var out := params.duplicate()
	if not out.has("model"):
		out["model"] = model
	return out


func _pipeline_start_async(p: Dictionary, plan: Dictionary, config: Dictionary, ctx) -> Dictionary:
	var started: Dictionary = await _generate_async(p, plan)
	if Util.is_error(started):
		return started
	var job: Variant = load_job(p.asset_id)
	if job == null:
		return started
	job["pipeline"] = config
	log_step(job, "pipeline_start")
	save_job(job)
	var data: Dictionary = started.data
	data["pipeline_stage"] = "waiting for candidates"
	data["next"] = "Generation takes 1-5 minutes. Then call asset_pipeline asset_id=%s again: it stops at the candidates for the user to pick." % p.asset_id
	return {"data": data}


func _pipeline_continue_async(job: Dictionary, config: Dictionary, pick_index: int, ctx) -> Dictionary:
	job["pipeline"] = config
	var notes: Array = []
	var deadline := _deadline()
	var report := {}
	## Generation and texturing: poll once; they take minutes.
	if job.stage in ["generating", "texturing"]:
		await refresh(job, notes)
	if job.stage == "candidates_ready" or (pick_index > 0 and not (job.get("pick") is Dictionary and int(job.pick.index) == pick_index)):
		if pick_index <= 0:
			return _pipeline_reply(job, notes, report, "STOP: the user picks a candidate. " + next_hint(job))
		var r: Dictionary = await pick(job, pick_index, notes)
		if Util.is_error(r):
			save_job(job)
			return r
		if job.stage == "texturing":
			return _pipeline_reply(job, notes, report, "Texturing candidate %d (1-3 minutes). Call asset_pipeline asset_id=%s again." % [pick_index, job.asset_id])
	if job.stage in ["generating", "texturing"]:
		var what := "candidates" if job.stage == "generating" else "the texture"
		return _pipeline_reply(job, notes, report, "Waiting for %s (%s). Call asset_pipeline asset_id=%s again in a minute." % [what, _progress_text(job), job.asset_id])
	if job.stage in ["failed", "canceled"]:
		return _pipeline_reply(job, notes, report, next_hint(job))
	if job.stage == "ready":
		var d: Dictionary = await download_pick(job, notes)
		if Util.is_error(d):
			save_job(job)
			return d
	if job.stage == "downloaded":
		if config.cleanup and deadline > 0 and deadline - Time.get_ticks_msec() < CLEANUP_BUDGET_MSEC:
			return _pipeline_reply(job, notes, report, "Downloaded. Call asset_pipeline asset_id=%s again for Blender cleanup and import (it needs a fresh call's full time)." % job.asset_id)
		await _shoot_before(job, config, deadline)
		var imp: Dictionary = await _cleanup_and_import(job, config, ctx)
		report["import"] = imp
		if imp.has("error"):
			save_job(job)
			return _pipeline_reply(job, notes, report, "Fix the problem above, then call asset_pipeline asset_id=%s again (or run asset_cleanup / asset_import by hand on %s)." % [job.asset_id, job.raw_model])
		job.stage = "imported"
		job["model"] = imp.get("path", "")
		log_step(job, "imported", {"path": imp.get("path", ""), "warnings": imp.get("warnings", [])})
	if job.stage == "imported":
		var swap: Variant = _swap_params(job.kind, job.asset_id, config)
		if Util.is_error(swap):
			save_job(job)
			return swap
		if swap == null:
			job.stage = "done"
			log_step(job, "done", {"swap": "none"})
		else:
			var result: Dictionary = await _swap_and_inspect(job, swap, config, deadline)
			report["swap"] = result.get("swap")
			if result.has("inspection"):
				report["inspection"] = result.inspection
			if result.has("error"):
				save_job(job)
				return _pipeline_reply(job, notes, report, "The swap failed; fix it and call asset_pipeline asset_id=%s again, or call swap_placeholder by hand." % job.asset_id)
			if String(swap.target) == "item" and not (config.get("icon", true) is bool and config.get("icon", true) == false):
				var icon: Dictionary = await _make_icon(job, String(swap.get("item_id", job.asset_id)), config, ctx)
				report["icon"] = icon
				if report.has("inspection") and icon.get("icons", []) is Array and not icon.get("icons", []).is_empty():
					report.inspection.images["icon"] = icon.icons[0].absolute_path
				elif report.has("inspection"):
					report.inspection.issues.append("icon: " + str(icon.get("error", icon.get("skipped", "not made"))))
					report.inspection.verdict = "check"
			job.stage = "done"
			log_step(job, "done", {"swap": swap.target})
	var msg := "Done: %s is in the game." % job.asset_id if job.stage == "done" else next_hint(job)
	return _pipeline_reply(job, notes, report, msg)


func _pipeline_reply(job: Dictionary, notes: Array, report: Dictionary, next: String) -> Dictionary:
	save_job(job)
	var data := summarize(job)
	data.merge(report)
	if not notes.is_empty():
		data["notes"] = notes
	data["next"] = next
	return {"data": data}


static func _progress_text(job: Dictionary) -> String:
	if job.stage == "texturing":
		return "%d%%" % int(job.pick.texture.get("progress", 0))
	var parts: Array[String] = []
	for c in job.candidates:
		parts.append("%d: %s %d%%" % [c.index, c.status, int(c.get("progress", 0))])
	return ", ".join(parts)


## asset_cleanup (which imports) or asset_import alone. The import report,
## or {"error": ...}.
func _cleanup_and_import(job: Dictionary, config: Dictionary, ctx) -> Dictionary:
	var assets := AssetTools.new()
	var deferred: bool = ctx != null and ctx.has_method("send_deferred")
	var result: Dictionary
	if config.cleanup:
		var params: Dictionary = (config.cleanup_options as Dictionary).duplicate()
		params["source"] = job.raw_model
		params["kind"] = job.kind
		params["asset_id"] = job.asset_id
		params["overwrite"] = true
		params["preview"] = config.preview
		if not String(config.blender_path).is_empty():
			params["blender_path"] = config.blender_path
		result = await _call_tool(assets.asset_cleanup, params, deferred)
		if Util.is_error(result):
			return {"error": result.error}
		job["cleanup"] = result.data.get("cleanup", {})
		var imported: Variant = result.data.get("import", {})
		if imported is Dictionary and imported.has("error"):
			return {"error": imported.error}
		return imported if imported is Dictionary else {"error": "asset_cleanup returned no import report"}
	var iparams := {"source": job.raw_model, "kind": job.kind, "asset_id": job.asset_id, "overwrite": true, "preview": config.preview}
	if not String(config.dest_dir).is_empty():
		iparams["dest_dir"] = config.dest_dir
	result = await _call_tool(assets.asset_import, iparams, deferred)
	if Util.is_error(result):
		return {"error": result.error}
	var data: Dictionary = result.data
	if data.get("import_pending", false):
		return {"error": data.get("note", "the editor has not imported the model yet; focus the Godot window and call again")}
	return data


## Runs a tool method, through a capturing context when the tool answers
## later (deferred), so the pipeline can wait for it.
func _call_tool(method: Callable, params: Dictionary, deferred: bool) -> Dictionary:
	if not deferred:
		return method.call(params, null)
	var cap := CaptureCtx.new()
	cap.deadline_msec = _deadline() + REPLY_MARGIN_MSEC if _deadline() > 0 else 0
	var first: Dictionary = method.call(params, cap)
	if not first.get("_deferred", false):
		return first
	if cap.result == null:
		await cap.done
	return cap.result


class CaptureCtx extends RefCounted:
	signal done
	var deadline_msec := 0
	var result: Variant = null

	func send_deferred(payload: Dictionary) -> void:
		result = payload
		done.emit()


## item_icon_render for a swapped item. Its report, or {"error": ...}.
func _make_icon(job: Dictionary, item_id: String, config: Dictionary, ctx) -> Dictionary:
	var params: Dictionary = (config.icon as Dictionary).duplicate() if config.get("icon") is Dictionary else {}
	params["item_id"] = item_id
	if not String(job.get("model", "")).is_empty():
		params["model"] = job.model
	var deferred: bool = ctx != null and ctx.has_method("send_deferred")
	var result: Dictionary = await _call_tool(IconTools.new().item_icon_render, params, deferred)
	if Util.is_error(result):
		log_step(job, "icon", {"error": result.error.message})
		return {"error": result.error.message}
	var data: Dictionary = result.data
	var made: Array = data.get("icons", [])
	log_step(job, "icon", {"icons": made.map(func(i): return i.icon)})
	return data


## swap_placeholder, with before/after renders of the target.
func _swap_and_inspect(job: Dictionary, swap: Dictionary, config: Dictionary, deadline: int) -> Dictionary:
	var params := _with_model(swap, String(job.get("model", "")))
	var out := {}
	var inspect_scene := "none"
	if config.inspect:
		inspect_scene = _inspect_target(params)
	var shots := {}
	if job.has("inspect_before"):
		shots["before"] = job.inspect_before
		job.erase("inspect_before")
	elif inspect_scene != "none":
		shots["before"] = await _shot(inspect_scene, AssetTools.work_dir(job.asset_id) + "/inspect_before.png", deadline)
	var result: Dictionary = SwapTools.new().swap_placeholder(params)
	if Util.is_error(result):
		out["error"] = result.error
		out["swap"] = result.error
		return out
	out["swap"] = result.data
	_save_live_swap(params, result.data, _inspect_target(params))
	log_step(job, "swap", {"target": params.target})
	if config.inspect:
		if inspect_scene != "none":
			shots["after"] = await _shot(inspect_scene, AssetTools.work_dir(job.asset_id) + "/inspect_after.png", deadline)
		out["inspection"] = inspection(job, result.data, shots)
	return out


## swap_placeholder edits a player/enemy/weapon scene in place when it is
## the scene open in the editor, and leaves it unsaved. The pipeline's
## "after" render and the game both read the file, so save it. Map and node
## swaps stay unsaved: that scene may hold other unsaved work of the user's.
func _save_live_swap(params: Dictionary, data: Dictionary, scene: String) -> void:
	if not Engine.is_editor_hint() or not String(data.get("edited", "")).begins_with("open scene"):
		return
	if not String(params.target) in ["player", "enemy", "weapon"] or scene.is_empty():
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != scene:
		return
	var err := EditorInterface.save_scene()
	data["edited"] = "open scene, saved" if err == OK else "open scene (save failed: %s; save with Ctrl+S)" % error_string(err)
	## The swap switched tabs to edit this scene: go back to where the user was.
	var previous := String(data.get("switched_from", ""))
	if err == OK and not previous.is_empty() and previous in EditorInterface.get_open_scenes():
		EditorInterface.open_scene_from_path(previous)


## The "before" render is taken ahead of the import: when the scene already
## uses res://assets/<kind>s/<id>/<id>.glb (an earlier swap), the import
## overwrites that file and a later "before" would show the new model.
func _shoot_before(job: Dictionary, config: Dictionary, deadline: int) -> void:
	job.erase("inspect_before")
	if not config.inspect:
		return
	var swap: Variant = _swap_params(job.kind, job.asset_id, config)
	if not swap is Dictionary:
		return
	var scene := _inspect_target(swap)
	if scene == "none":
		return
	job["inspect_before"] = await _shot(scene, AssetTools.work_dir(job.asset_id) + "/inspect_before.png", deadline)


## The scene file to render before and after, "" for the editor's 3D
## viewport (map, node), "none" when the import preview says it all (item).
static func _inspect_target(params: Dictionary) -> String:
	match String(params.target):
		"item":
			return "none"
		"player":
			return String(params.get("scene", SwapTools.DEFAULT_PLAYER_SCENE))
		"enemy":
			return String(params.get("scene", "%s/%s.tscn" % [SwapTools.DEFAULT_ENEMY_DIR, params.get("asset_id", "")]))
		"weapon":
			return String(params.get("scene", "%s/%s.tscn" % [SwapTools.DEFAULT_WEAPON_DIR, params.get("asset_id", "")]))
	return ""


## Renders a scene file, or captures the 3D editor viewport when `scene` is "".
func _shot(scene: String, png: String, deadline: int) -> Variant:
	if DisplayServer.get_name() == "headless" or not Engine.is_editor_hint():
		return "skipped (headless editor has no renderer)"
	if not scene.is_empty():
		if not FileAccess.file_exists(scene):
			return "skipped (%s not found)" % scene
		return await AssetTools.new().render_preview(scene, png, deadline)
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return "skipped (no 3D viewport)"
	## The editor (low processor mode) draws only when asked; wait for a
	## couple of frames, but never past the deadline.
	var frames := [0]
	var count := func() -> void: frames[0] += 1
	RenderingServer.frame_post_draw.connect(count)
	var stop := Time.get_ticks_msec() + 3000
	if deadline > 0:
		stop = mini(stop, deadline)
	var tree := Engine.get_main_loop() as SceneTree
	while frames[0] < 2 and Time.get_ticks_msec() < stop:
		EditorInterface.get_base_control().queue_redraw()
		await tree.create_timer(0.05).timeout
	RenderingServer.frame_post_draw.disconnect(count)
	if frames[0] < 2:
		return "skipped (the editor window is not drawing; bring Godot to the front)"
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return "skipped (viewport returned no image)"
	AssetTools.ensure_sources_dir(png.get_base_dir())
	img.save_png(png)
	return {"path": png, "absolute_path": ProjectSettings.globalize_path(png)}


## The checks after a swap: budget and size warnings from the import, the
## swap's own warnings, and the renders to look at.
static func inspection(job: Dictionary, swap_data: Dictionary, shots: Dictionary) -> Dictionary:
	var issues: Array = []
	for w in swap_data.get("warnings", []):
		issues.append("swap: " + str(w))
	var cleanup: Variant = job.get("cleanup", {})
	if cleanup is Dictionary:
		for w in cleanup.get("warnings", []):
			issues.append("cleanup: " + str(w))
	var steps: Array = job.get("steps", [])
	for i in range(steps.size() - 1, -1, -1):
		if steps[i].get("step") == "imported":
			for w in steps[i].get("warnings", []):
				issues.append("import: " + str(w))
			break
	var images := {}
	for key in shots:
		if shots[key] is Dictionary:
			images[key] = shots[key].absolute_path
		else:
			images[key] = str(shots[key])
	var preview := AssetTools.preview_path(job.asset_id)
	if FileAccess.file_exists(preview):
		images["model"] = ProjectSettings.globalize_path(preview)
	return {"verdict": "ok" if issues.is_empty() else "check", "issues": issues, "images": images,
		"next": "Open the images: the model should face the aim direction (-Z), stand on the ground and match the placeholder's size. Undo: Edit > Undo reverts the swap, then the import."}


# =============================================================================
# running
# =============================================================================

## Deferred tools answer through ctx; without one (tests, batch) the call
## runs inline and must not wait (the test transport answers at once).
func _run(ctx, asset_id: String, fn: Callable) -> Dictionary:
	if not asset_id.is_empty() and _locks.has(asset_id):
		return Util.error(Util.EDITOR_NOT_READY, "another call is working on '%s'; wait for it to finish" % asset_id)
	_set_deadline(ctx)
	if ctx != null and ctx.has_method("send_deferred"):
		_deliver(ctx, asset_id, fn)
		return {"_deferred": true}
	if not asset_id.is_empty():
		_locks[asset_id] = true
	var r: Variant = fn.call()
	_locks.erase(asset_id)
	if r is Dictionary:
		return r
	return Util.error(Util.INTERNAL_ERROR, "this tool needs the deferred channel (call it through MCP)")


func _deliver(ctx, asset_id: String, fn: Callable) -> void:
	if not asset_id.is_empty():
		_locks[asset_id] = true
	## The dispatcher registers the request only after the tool returns
	## {"_deferred": true}; a reply sent before that (a path with no network
	## wait, e.g. a missing key) would be dropped. Start on the next frame.
	await (Engine.get_main_loop() as SceneTree).process_frame
	var r: Variant = await fn.call()
	_locks.erase(asset_id)
	ctx.send_deferred(r if r is Dictionary else Util.error(Util.INTERNAL_ERROR, "no result"))


var _call_deadline := 0


func _deadline() -> int:
	return _call_deadline


## Remembered by the spec wrapper's ctx for the slow steps.
func _set_deadline(ctx) -> void:
	_call_deadline = int(ctx.deadline_msec) - REPLY_MARGIN_MSEC if ctx != null and "deadline_msec" in ctx and int(ctx.deadline_msec) > 0 else 0

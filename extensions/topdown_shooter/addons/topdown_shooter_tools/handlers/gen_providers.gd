@tool
extends RefCounted

## Request builders and response parsers for the 3D generation services
## (Meshy, Tripo). Pure functions: no network, no files. gen_tools.gd sends
## the requests; tests feed canned responses to the parsers.
##
## Every generation is split in two kinds of provider task:
##   draft    one candidate: a mesh from text (untextured, cheap) or from a
##            reference image (textured in one go).
##   texture  run on the picked text candidate only, so rejected candidates
##            never pay for textures.
##
## A request is {method, url, headers, body (Dictionary or null)}; an image
## upload is {method, url, headers, multipart: {field, file, mime}}.
##
## A parsed task is {status, progress, model_url, thumbnail_url, error,
## credits}; status is one of queued, running, succeeded, failed, canceled.

const PROVIDERS := ["meshy", "tripo"]
const DEFAULT_BASE := {
	"meshy": "https://api.meshy.ai",
	"tripo": "https://openapi.tripo3d.com/v3",
}
## Longest prompt each service takes.
const PROMPT_LIMIT := {"meshy": 800, "tripo": 1024}
const NEGATIVE_LIMIT := {"meshy": 0, "tripo": 255}
## Estimated credits per task, from each service's price list (Nov 2026).
## Real charges are in the task's credits field once it finishes; a
## style_preset.json "credits" block overrides these.
const CREDITS := {
	"meshy": {"text_draft": 20, "texture": 10, "image_draft": 30},
	"tripo": {"text_draft": 10, "texture": 10, "image_draft": 30},
}
const TERMINAL := ["succeeded", "failed", "canceled"]


static func headers(api_key: String, json_body := true) -> PackedStringArray:
	var out := PackedStringArray(["Authorization: Bearer " + api_key, "Accept: application/json"])
	if json_body:
		out.append("Content-Type: application/json")
	return out


# --- create -------------------------------------------------------------------

## Draft from text. `opts`: prompt, negative_prompt, target_polycount, kind,
## seed, plus the preset's provider_options.
static func text_draft_request(provider: String, base: String, api_key: String, opts: Dictionary) -> Dictionary:
	var extra: Dictionary = opts.get("provider_options", {})
	if provider == "meshy":
		var body := {
			"mode": "preview",
			"prompt": opts.prompt,
			"ai_model": extra.get("ai_model", "latest"),
			"topology": "triangle",
			"should_remesh": true,
			"target_polycount": int(opts.target_polycount),
		}
		if opts.get("kind", "") == "character":
			body["pose_mode"] = "a-pose"
		_merge_extra(body, extra, ["ai_model"])
		return {"method": "POST", "url": base + "/openapi/v2/text-to-3d", "headers": headers(api_key), "body": body, "endpoint": "text-to-3d"}
	var tbody := {
		"prompt": opts.prompt,
		"texture": false,
		"pbr": false,
		"face_limit": int(opts.target_polycount),
		"model_seed": int(opts.get("seed", 0)),
	}
	if not String(opts.get("negative_prompt", "")).is_empty():
		tbody["negative_prompt"] = opts.negative_prompt
	_merge_extra(tbody, extra, [])
	return {"method": "POST", "url": base + "/generation/text-to-model", "headers": headers(api_key), "body": tbody, "endpoint": "task"}


## Draft from a reference image, textured. `image` is an https URL, a
## data: URI (Meshy) or an uploaded file token (Tripo).
static func image_draft_request(provider: String, base: String, api_key: String, image: String, opts: Dictionary) -> Dictionary:
	var extra: Dictionary = opts.get("provider_options", {})
	if provider == "meshy":
		var body := {
			"image_url": image,
			"ai_model": extra.get("ai_model", "latest"),
			"topology": "triangle",
			"should_remesh": true,
			"target_polycount": int(opts.target_polycount),
			"should_texture": true,
			"enable_pbr": true,
		}
		if not String(opts.get("texture_prompt", "")).is_empty():
			body["texture_prompt"] = String(opts.texture_prompt).left(600)
		_merge_extra(body, extra, ["ai_model"])
		return {"method": "POST", "url": base + "/openapi/v1/image-to-3d", "headers": headers(api_key), "body": body, "endpoint": "image-to-3d"}
	var tbody := {
		"input": image,
		"texture": true,
		"pbr": true,
		"face_limit": int(opts.target_polycount),
		"model_seed": int(opts.get("seed", 0)),
	}
	_merge_extra(tbody, extra, [])
	return {"method": "POST", "url": base + "/generation/image-to-model", "headers": headers(api_key), "body": tbody, "endpoint": "task"}


## Texture the picked text draft.
static func texture_request(provider: String, base: String, api_key: String, draft_task_id: String, opts: Dictionary) -> Dictionary:
	var text := String(opts.get("texture_prompt", "")).left(600)
	if provider == "meshy":
		var body := {"mode": "refine", "preview_task_id": draft_task_id, "enable_pbr": true}
		if not text.is_empty():
			body["texture_prompt"] = text
		var extra: Dictionary = opts.get("provider_options", {})
		if extra.has("ai_model"):
			body["ai_model"] = extra.ai_model
		return {"method": "POST", "url": base + "/openapi/v2/text-to-3d", "headers": headers(api_key), "body": body, "endpoint": "text-to-3d"}
	var tbody := {"input": draft_task_id, "pbr": true, "texture_quality": "standard"}
	if not text.is_empty():
		tbody["texture_prompt"] = {"text": text}
	return {"method": "POST", "url": base + "/models/texture", "headers": headers(api_key), "body": tbody, "endpoint": "task"}


## Tripo only: upload a local reference image, answered by a file token.
static func upload_request(provider: String, base: String, api_key: String, abs_file: String) -> Dictionary:
	if provider != "tripo":
		return {}
	var ext := abs_file.get_extension().to_lower()
	var mime := "image/png" if ext == "png" else ("image/webp" if ext == "webp" else "image/jpeg")
	return {"method": "POST", "url": base + "/files", "headers": PackedStringArray(["Authorization: Bearer " + api_key]),
		"multipart": {"field": "file", "file": abs_file, "mime": mime}}


static func parse_upload(code: int, json: Variant) -> Dictionary:
	if code >= 200 and code < 300 and json is Dictionary and json.get("data") is Dictionary and json.data.has("file_token"):
		return {"file_token": String(json.data.file_token)}
	return {"error": describe_error("tripo", code, json)}


## {task_id} or {error, retryable}.
static func parse_create(provider: String, code: int, json: Variant) -> Dictionary:
	if code >= 200 and code < 300 and json is Dictionary:
		if provider == "meshy" and json.has("result"):
			return {"task_id": String(json.result)}
		if provider == "tripo" and int(json.get("code", -1)) == 0 and json.get("data") is Dictionary and json.data.has("task_id"):
			return {"task_id": String(json.data.task_id)}
	return {"error": describe_error(provider, code, json)}


# --- status -------------------------------------------------------------------

static func status_request(provider: String, base: String, api_key: String, endpoint: String, task_id: String) -> Dictionary:
	var url := ""
	if provider == "meshy":
		var version := "v1" if endpoint == "image-to-3d" else "v2"
		url = "%s/openapi/%s/%s/%s" % [base, version, endpoint, task_id.uri_encode()]
	else:
		url = "%s/tasks/%s" % [base, task_id.uri_encode()]
	return {"method": "GET", "url": url, "headers": headers(api_key, false), "body": null}


static func parse_status(provider: String, code: int, json: Variant) -> Dictionary:
	if code < 200 or code >= 300 or not json is Dictionary:
		return {"status": "", "error": describe_error(provider, code, json), "retryable": code == 429 or code >= 500 or code == 0}
	if provider == "meshy":
		var urls: Variant = json.get("model_urls", {})
		var err: Variant = json.get("task_error")
		var message := ""
		if err is Dictionary:
			message = String(err.get("message", ""))
		return {
			"status": _meshy_status(String(json.get("status", ""))),
			"progress": int(json.get("progress", 0)),
			"model_url": String(urls.get("glb", "")) if urls is Dictionary else "",
			"thumbnail_url": String(json.get("thumbnail_url", "")),
			"error": message,
			"credits": json.get("consumed_credits"),
		}
	if int(json.get("code", -1)) != 0 or not json.get("data") is Dictionary:
		return {"status": "", "error": describe_error(provider, code, json), "retryable": false}
	var data: Dictionary = json.data
	var output: Variant = data.get("output", {})
	if not output is Dictionary:
		output = {}
	return {
		"status": _tripo_status(String(data.get("status", ""))),
		"progress": int(data.get("progress", 0)),
		"model_url": String(output.get("model_url", output.get("pbr_model", output.get("model", "")))),
		"thumbnail_url": String(output.get("rendered_image_url", output.get("rendered_image", ""))),
		"error": String(data.get("error_message", "")),
		"credits": data.get("credits_consumed"),
	}


static func _meshy_status(s: String) -> String:
	match s:
		"PENDING":
			return "queued"
		"IN_PROGRESS":
			return "running"
		"SUCCEEDED":
			return "succeeded"
		"FAILED":
			return "failed"
		"CANCELED", "CANCELLED", "EXPIRED":
			return "canceled"
	return "running"


static func _tripo_status(s: String) -> String:
	match s:
		"queued":
			return "queued"
		"running":
			return "running"
		"success":
			return "succeeded"
		"failed", "banned":
			return "failed"
		"cancelled", "canceled", "expired":
			return "canceled"
	return "running"


# --- balance -----------------------------------------------------------------

static func balance_request(provider: String, base: String, api_key: String) -> Dictionary:
	var url := base + ("/openapi/v1/balance" if provider == "meshy" else "/account/balance")
	return {"method": "GET", "url": url, "headers": headers(api_key, false), "body": null}


static func parse_balance(provider: String, code: int, json: Variant) -> Variant:
	if code < 200 or code >= 300 or not json is Dictionary:
		return null
	if provider == "meshy":
		return json.get("balance")
	var data: Variant = json.get("data")
	return data.get("balance") if data is Dictionary else null


# --- errors -------------------------------------------------------------------

## A short, user-facing reason for a failed call. Never contains the key.
static func describe_error(provider: String, code: int, json: Variant) -> String:
	var detail := ""
	if json is Dictionary:
		for key in ["message", "error", "detail", "suggestion"]:
			if json.get(key) is String and not String(json[key]).is_empty():
				detail = String(json[key])
				break
	var name := provider.capitalize()
	var reason := ""
	match code:
		0:
			reason = "%s did not answer (network or TLS error)" % name
		401:
			reason = "%s rejected the API key (401); check the key in Editor Settings" % name
		402:
			reason = "%s: not enough credits (402)" % name
		403:
			reason = "%s refused the request (403: not enough credits or blocked by moderation)" % name
		404:
			reason = "%s: task not found (404)" % name
		429:
			reason = "%s is rate limiting (429); try again in a minute" % name
		_:
			reason = "%s answered HTTP %d" % [name, code]
	if json is Dictionary and provider == "tripo" and json.has("code") and int(json.code) != 0:
		reason += " (code %s)" % str(json.code)
	return reason + (": " + detail.left(300) if not detail.is_empty() else "")


static func _merge_extra(body: Dictionary, extra: Dictionary, skip: Array) -> void:
	for key in extra:
		if key in skip or body.has(key) and key in ["prompt", "image_url", "input", "mode"]:
			continue
		body[key] = extra[key]

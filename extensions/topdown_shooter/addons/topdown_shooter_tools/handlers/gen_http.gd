@tool
extends RefCounted

## HTTP for the generation tools, on HTTPRequest nodes parked under the
## editor's base control (they need the scene tree to run). Both methods are
## coroutines. Tests swap in a fake with the same two methods that answers
## at once, so the tool code runs synchronously there.

const MAX_DOWNLOAD_BYTES := 300 * 1024 * 1024


## Sends one request. `req`: {method, url, headers, body (Dictionary/null)}
## or {..., multipart: {field, file, mime}}. Returns {code, json, text};
## code 0 when the request never got an answer.
func request(req: Dictionary, timeout_sec: float = 30.0) -> Dictionary:
	var node := _make_node(timeout_sec)
	if node == null:
		return {"code": 0, "json": null, "text": "no scene tree to run HTTPRequest"}
	var method := HTTPClient.METHOD_GET
	match String(req.get("method", "GET")):
		"POST":
			method = HTTPClient.METHOD_POST
		"DELETE":
			method = HTTPClient.METHOD_DELETE
	var headers: PackedStringArray = req.get("headers", PackedStringArray())
	var err := OK
	if req.has("multipart"):
		var mp: Dictionary = req.multipart
		var bytes := FileAccess.get_file_as_bytes(mp.file)
		if bytes.is_empty():
			node.queue_free()
			return {"code": 0, "json": null, "text": "cannot read %s" % mp.file}
		var boundary := "----godotgen%d" % Time.get_ticks_usec()
		var body := PackedByteArray()
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % [boundary, mp.field, String(mp.file).get_file(), mp.mime]).to_utf8_buffer())
		body.append_array(bytes)
		body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
		var h := PackedStringArray(headers)
		h.append("Content-Type: multipart/form-data; boundary=" + boundary)
		err = node.request_raw(req.url, h, method, body)
	else:
		var text := ""
		if req.get("body") != null:
			text = JSON.stringify(req.body)
		err = node.request(req.url, headers, method, text)
	if err != OK:
		node.queue_free()
		return {"code": 0, "json": null, "text": "request failed to start: %s" % error_string(err)}
	var result: Array = await node.request_completed
	node.queue_free()
	var outcome: int = result[0]
	if outcome != HTTPRequest.RESULT_SUCCESS:
		return {"code": 0, "json": null, "text": _result_name(outcome)}
	var body_text := (result[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(result[1]), "json": JSON.parse_string(body_text) if not body_text.is_empty() else null, "text": body_text.left(2000)}


## Downloads `url` to `abs_path` (via a .part file, so a cut download never
## passes for a whole one). Returns {ok, bytes, error}.
func download(url: String, abs_path: String, timeout_sec: float = 100.0) -> Dictionary:
	var node := _make_node(timeout_sec)
	if node == null:
		return {"ok": false, "error": "no scene tree to run HTTPRequest"}
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var part := abs_path + ".part"
	node.download_file = part
	node.body_size_limit = MAX_DOWNLOAD_BYTES
	var err := node.request(url)
	if err != OK:
		node.queue_free()
		return {"ok": false, "error": "download failed to start: %s" % error_string(err)}
	var result: Array = await node.request_completed
	node.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) < 200 or int(result[1]) >= 300:
		DirAccess.remove_absolute(part)
		var why := _result_name(int(result[0])) if int(result[0]) != HTTPRequest.RESULT_SUCCESS else "HTTP %d" % int(result[1])
		return {"ok": false, "error": "download failed: %s (links from the service expire after a few days)" % why}
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
	var mv := DirAccess.rename_absolute(part, abs_path)
	if mv != OK:
		return {"ok": false, "error": "cannot move the download into place: %s" % error_string(mv)}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	return {"ok": true, "bytes": size}


func _make_node(timeout_sec: float) -> HTTPRequest:
	var parent: Node = null
	if Engine.is_editor_hint():
		parent = EditorInterface.get_base_control()
	else:
		var tree := Engine.get_main_loop() as SceneTree
		parent = tree.root if tree != null else null
	if parent == null:
		return null
	var node := HTTPRequest.new()
	node.use_threads = true
	node.timeout = timeout_sec
	parent.add_child(node)
	return node


static func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "cannot connect"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "cannot resolve the host (offline?)"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "file too large"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
	return "request error %d" % result

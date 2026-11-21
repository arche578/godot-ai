@tool
extends RefCounted

## Player-facing words, the money format and the rarity colors that the
## scaffold templates put on screen, in one place.
##
## Templates hold tokens inside their string literals:
##   {{ui:<key>}}             a word or sentence from TEXT (format specs kept)
##   {{money}}                the money format, one %s (default "%s")
##   {{rarity_color:<id>}}    "#rrggbb" for common..legendary
## render() fills them in when a template is copied into a game, so the
## game's copy holds plain text that the game owns and may edit.
##
## The genre addon ships English and Korean and defaults to English with no
## currency sign. A game picks its own in res://assets/style_preset.json:
##   "ui": {"locale": "ko", "money_format": "₩%s",
##          "text": {"deploy": "Go"}, "rarity_colors": {"rare": "#3080ff"}}
## "text" overrides single keys. A key missing from the locale falls back
## to English, so a new key never breaks a game.

const PRESET_PATH := "res://assets/style_preset.json"
const DEFAULT_LOCALE := "en"
const DEFAULT_MONEY_FORMAT := "%s"
const RARITIES := ["common", "uncommon", "rare", "epic", "legendary"]
const RARITY_COLORS := {
	"common": "#9e9e9e",
	"uncommon": "#4dbf4d",
	"rare": "#4d80f2",
	"epic": "#a64df2",
	"legendary": "#f29919",
}

const _TOKEN := "\\{\\{(ui:[a-z0-9_]+|money|rarity_color:[a-z]+)\\}\\}"

const TEXT := {
	"en": {
		"rarity_common": "Common",
		"rarity_uncommon": "Uncommon",
		"rarity_rare": "Rare",
		"rarity_epic": "Epic",
		"rarity_legendary": "Legendary",
		"cat_weapon": "Weapon",
		"cat_ammo": "Ammo",
		"cat_armor": "Armor",
		"cat_helmet": "Helmet",
		"cat_backpack": "Backpack",
		"cat_medical": "Medical",
		"cat_food": "Food",
		"cat_key": "Key",
		"cat_valuable": "Valuable",
		"cat_material": "Material",
		"cat_misc": "Misc",
		"sort": "Sort",
		"close": "Close",
		"weight": "Weight",
		"value": "Value",
		"each": "each",
		"stash": "Stash",
		"bag": "Bag",
		"raid_bag": "Raid bag",
		"deploy": "Deploy",
		"crate": "Crate",
		"extraction": "Extraction",
		"inventory_title": "Inventory",
		"hideout_title": "Hideout",
		"no_room_to_sort": "No room to sort",
		"inv_hint": "Drag: move · R: rotate · Right-click: drop · Shift+click: split",
		"inv_speed": "  (speed %d%%)",
		"inv_hud": "Bag %.1f%s  [%s]",
		"too_heavy": "Too heavy",
		"bag_no_room": "No room in the bag",
		"unknown_item": "Unknown item",
		"tip_weight_each": "Weight %.2f kg (%.2f each)",
		"tip_size": "Size %dx%d · stack %d",
		"new_game": "New game",
		"new_game_tip": "Deletes the save and starts a new game (press twice)",
		"confirm_reset": "Really delete?",
		"no_raid_scene": "No raid scene: %s",
		"no_room": "No room",
		"bag_too_heavy": "The bag is too heavy",
		"stash_no_room": "No room in the stash",
		"all_to_stash": "All to stash",
		"hideout_hint": "Drag: move · R: rotate · Right-click: send across · Shift+click: split · Extract and the bag goes to the stash; die and it is lost",
		"no_deploy_scene": "No raid scene to deploy to",
		"stats_short": "Raids %d · Extracted %d · Died %d",
		"stats_rest": " · Survival %s · Total earned ",
		"extract_report": "Extracted · brought back {{money}} · %d moved to the stash",
		"stash_overflow": "The stash was full, so some items stayed in the bag",
		"died_report": "Died · lost {{money}} of gear",
		"mia_report": "The game closed during the raid, so the bag was lost",
		"starter_kit": "Starter items were put in the stash",
		"waiting": "Not enough stash room: %d stacks are waiting",
		"send_to": "Right-click: send to %s",
		"cant_deploy_no_screen": "Cannot deploy: no stash screen",
		"cant_deploy_no_scene": "Cannot deploy: no raid scene (%s)",
		"door_note": "To deploy, stand at the hideout's deploy door",
		"item_count": "%d items",
		"deploy_countdown": "Deploying in %.1fs · step off the door to cancel",
		"open_prompt": "[%s] Open %s",
		"extract_overlay": "Extracted!\nBrought back {{money}} · %d items\nReturning to the hideout",
		"died_overlay": "Died\nLost {{money}} of gear\nReturning to the hideout",
		"searching": "Searching... %d%%",
		"extract_in": "%s: extracting in %.1fs",
		"extracted": "Extracted!",
		"loot_value": "Loot value",
		"extraction_done": "Extraction complete",
		"note_bug": "Bug",
		"note_balance": "Balance",
		"note_level": "Level/map",
		"note_graphics": "Graphics",
		"note_art_style": "Style (art direction)",
		"note_ui": "UI",
		"note_character": "Character",
		"note_vfx": "VFX",
		"note_sound": "Sound",
		"note_experience": "Game feel",
		"note_idea": "Idea",
		"note_other": "Other",
		"note_save_failed": "Note not saved: %s",
		"note_saved": "Note saved (%s)",
		"note_title": "Playtest note (paused)",
		"note_kind": "Type",
		"note_placeholder": "What feels wrong? (Enter save · Shift+Enter new line · Esc cancel · Tab switch position)",
		"cancel_esc": "Cancel (Esc)",
		"save_enter": "Save (Enter)",
		"no_position": "No position",
		"player": "Player",
		"mouse": "Mouse",
		"position_at": "%s position (%.1f, %.1f, %.1f)",
		"note_info": "%s · %s%s · screenshot %s · open notes in this scene: %d",
		"saved_word": "saved",
		"none_word": "none",
		"new_note": "New note",
	},
	"ko": {
		"rarity_common": "일반",
		"rarity_uncommon": "고급",
		"rarity_rare": "희귀",
		"rarity_epic": "영웅",
		"rarity_legendary": "전설",
		"cat_weapon": "무기",
		"cat_ammo": "탄약",
		"cat_armor": "방어구",
		"cat_helmet": "헬멧",
		"cat_backpack": "가방",
		"cat_medical": "의료",
		"cat_food": "음식",
		"cat_key": "열쇠",
		"cat_valuable": "귀중품",
		"cat_material": "재료",
		"cat_misc": "기타",
		"sort": "정렬",
		"close": "닫기",
		"weight": "무게",
		"value": "가치",
		"each": "개당",
		"stash": "창고",
		"bag": "가방",
		"raid_bag": "출격 가방",
		"deploy": "출격",
		"crate": "상자",
		"extraction": "탈출 지점",
		"inventory_title": "인벤토리",
		"hideout_title": "은신처",
		"no_room_to_sort": "정렬할 공간이 없습니다",
		"inv_hint": "드래그: 이동 · R: 회전 · 우클릭: 버리기 · Shift+클릭: 나누기",
		"inv_speed": "  (속도 %d%%)",
		"inv_hud": "가방 %.1f%s  [%s]",
		"too_heavy": "너무 무겁습니다",
		"bag_no_room": "가방에 공간이 없습니다",
		"unknown_item": "알 수 없는 아이템",
		"tip_weight_each": "무게 %.2f kg (개당 %.2f)",
		"tip_size": "크기 %dx%d · 최대 %d개",
		"new_game": "처음부터",
		"new_game_tip": "세이브를 지우고 새 게임을 시작합니다 (두 번 누르기)",
		"confirm_reset": "정말 지울까요?",
		"no_raid_scene": "레이드 씬이 없습니다: %s",
		"no_room": "공간이 없습니다",
		"bag_too_heavy": "가방이 너무 무겁습니다",
		"stash_no_room": "창고에 공간이 없습니다",
		"all_to_stash": "모두 창고로",
		"hideout_hint": "드래그: 이동 · R: 회전 · 우클릭: 반대편으로 보내기 · Shift+클릭: 나누기 · 탈출하면 가방이 창고로, 죽으면 가방을 잃습니다",
		"no_deploy_scene": "출격할 레이드 씬이 없습니다",
		"stats_short": "레이드 %d · 탈출 %d · 사망 %d",
		"stats_rest": " · 생존율 %s · 총 수익 ",
		"extract_report": "탈출 성공 · 가져온 물건 {{money}} · %d개를 창고로 옮겼습니다",
		"stash_overflow": "창고가 가득 차서 일부는 가방에 남았습니다",
		"died_report": "사망 · 가지고 간 물건 {{money}}를 잃었습니다",
		"mia_report": "레이드 중에 게임이 꺼져 가방을 잃었습니다",
		"starter_kit": "기본 지급품을 창고에 넣었습니다",
		"waiting": "창고 공간이 부족해 %d묶음이 자리를 기다립니다",
		"send_to": "우클릭: %s(으)로 보내기",
		"cant_deploy_no_screen": "출격할 수 없습니다: 창고 화면이 없습니다",
		"cant_deploy_no_scene": "출격할 수 없습니다: 레이드 씬이 없습니다 (%s)",
		"door_note": "출격은 은신처의 출격 문 앞에 서 있으면 됩니다",
		"item_count": "%d개",
		"deploy_countdown": "출격까지 %.1f초 · 문에서 벗어나면 취소",
		"open_prompt": "[%s] %s 열기",
		"extract_overlay": "탈출 성공!\n가져온 물건 {{money}} · %d개\n은신처로 돌아갑니다",
		"died_overlay": "사망\n가지고 간 물건 {{money}}를 잃었습니다\n은신처로 돌아갑니다",
		"searching": "수색 중... %d%%",
		"extract_in": "%s: %.1f초 뒤 탈출",
		"extracted": "탈출 성공!",
		"loot_value": "가져온 물건 가치",
		"extraction_done": "탈출 완료",
		"note_bug": "버그",
		"note_balance": "밸런스",
		"note_level": "레벨/맵",
		"note_graphics": "그래픽",
		"note_art_style": "스타일(아트 컨셉)",
		"note_ui": "UI",
		"note_character": "캐릭터",
		"note_vfx": "특수효과",
		"note_sound": "사운드",
		"note_experience": "게임 경험",
		"note_idea": "아이디어",
		"note_other": "기타",
		"note_save_failed": "메모 저장 실패: %s",
		"note_saved": "메모 저장됨 (%s)",
		"note_title": "플레이테스트 메모 (일시정지됨)",
		"note_kind": "종류",
		"note_placeholder": "무엇이 이상한가요? (Enter 저장 · Shift+Enter 줄바꿈 · Esc 취소 · Tab 위치 전환)",
		"cancel_esc": "취소 (Esc)",
		"save_enter": "저장 (Enter)",
		"no_position": "위치 없음",
		"player": "플레이어",
		"mouse": "마우스",
		"position_at": "%s 위치 (%.1f, %.1f, %.1f)",
		"note_info": "%s · %s%s · 스크린샷 %s · 이 씬의 열린 메모 %d개",
		"saved_word": "저장",
		"none_word": "없음",
		"new_note": "새 메모",
	},
}


## The game's "ui" section of style_preset.json, cleaned: {locale,
## money_format, text, rarity_colors, warnings}. Bad values fall back to the
## defaults and add a warning instead of failing a scaffold.
static func settings(preset_path := PRESET_PATH) -> Dictionary:
	var out := {"locale": DEFAULT_LOCALE, "money_format": DEFAULT_MONEY_FORMAT, "text": {}, "rarity_colors": RARITY_COLORS.duplicate(), "warnings": []}
	if not FileAccess.file_exists(preset_path):
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(preset_path))
	if not parsed is Dictionary or not parsed.get("ui") is Dictionary:
		return out
	return apply(out, parsed.ui)


## Merges a raw "ui" dictionary into `out` (from settings()), validating it.
static func apply(out: Dictionary, ui: Dictionary) -> Dictionary:
	var locale := str(ui.get("locale", DEFAULT_LOCALE)).strip_edges().to_lower()
	if TEXT.has(locale):
		out.locale = locale
	else:
		out.warnings.append("ui.locale '%s' is not one of %s; using %s" % [locale, ", ".join(TEXT.keys()), DEFAULT_LOCALE])
	if ui.has("money_format"):
		var money := str(ui.money_format)
		if money.count("%") == 1 and money.contains("%s"):
			out.money_format = money
		else:
			out.warnings.append("ui.money_format must hold exactly one %%s (e.g. \"$%%s\"); got '%s'" % money)
	if ui.get("text") is Dictionary:
		for key in ui.text:
			if not TEXT.en.has(str(key)):
				out.warnings.append("ui.text.%s is not a known key" % key)
			elif _specs(str(ui.text[key])) != _specs(String(TEXT.en[key])):
				out.warnings.append("ui.text.%s must keep the format specs %s" % [key, _specs(String(TEXT.en[key]))])
			else:
				out.text[str(key)] = str(ui.text[key])
	if ui.get("rarity_colors") is Dictionary:
		for id in ui.rarity_colors:
			var hex := str(ui.rarity_colors[id])
			if not RARITY_COLORS.has(str(id)):
				out.warnings.append("ui.rarity_colors.%s is not a rarity (%s)" % [id, ", ".join(RARITIES)])
			elif not Color.html_is_valid(hex):
				out.warnings.append("ui.rarity_colors.%s must be \"#rrggbb\", got '%s'" % [id, hex])
			else:
				out.rarity_colors[str(id)] = "#" + Color.html(hex).to_html(false)
	return out


## One entry of TEXT for the settings' locale (overrides first, then the
## locale, then English), with {{money}} filled in.
static func text(key: String, ui: Dictionary = {}) -> String:
	if ui.is_empty():
		ui = settings()
	var value: String
	if ui.text.has(key):
		value = ui.text[key]
	else:
		value = String(TEXT.get(ui.locale, {}).get(key, TEXT.en.get(key, key)))
	return value.replace("{{money}}", ui.money_format)


static func rarity_color(id: String, ui: Dictionary = {}) -> Color:
	if ui.is_empty():
		ui = settings()
	return Color.html(String(ui.rarity_colors.get(id, ui.rarity_colors.common)))


## Fills a template's tokens. Values land inside "..." literals, so they are
## escaped. Unknown keys are left as they are (a test catches them).
static func render(source: String, ui: Dictionary = {}) -> String:
	if not source.contains("{{"):
		return source
	if ui.is_empty():
		ui = settings()
	var regex := RegEx.create_from_string(_TOKEN)
	var out := ""
	var at := 0
	for m in regex.search_all(source):
		out += source.substr(at, m.get_start() - at)
		var token := m.get_string(1)
		var value: String
		if token == "money":
			value = ui.money_format
		elif token.begins_with("ui:"):
			var key := token.substr(3)
			value = text(key, ui) if TEXT.en.has(key) else m.get_string()
		else:
			value = String(ui.rarity_colors.get(token.substr(13), m.get_string()))
		out += value.c_escape()
		at = m.get_end()
	return out + source.substr(at)


## Every token key a source uses (for tests and checks).
static func tokens(source: String) -> Array:
	var out: Array = []
	for m in RegEx.create_from_string(_TOKEN).search_all(source):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


## The %-format specs of a string, in order (so a translation keeps them).
static func _specs(value: String) -> Array:
	var out: Array = []
	for m in RegEx.create_from_string("%[-+ 0#]*[0-9]*(?:\\.[0-9]+)?[sdfxXc%]").search_all(value.replace("{{money}}", "%s")):
		out.append(m.get_string().right(1) if m.get_string() != "%%" else "%%")
	return out

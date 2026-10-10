## 场景管家 —— 共享资源，参与者请勿修改本文件。
##
## 它是 autoload（单例），负责三件事，群友一行代码都不用写：
##   1. 在 entry_point 位置生成玩家
##   2. 把 NPC 说的话送到共享对话框（谁想说话都可以调 say()）
##   3. 场景里找不到导航层时提醒一句
##
## 对话框的开和关也归它管：NPC / 可交互组件只负责「说什么」，
## 「什么时候收起」由玩家按 E 决定 —— 玩家调 close_dialogue()。
##
## 导航网格不用谁去烘焙：NavLayer 上刷了导航瓦片之后，引擎会自己把它
## 注册进场景的导航地图。群友只需要在自己的 entry.tscn 里放一个 Marker2D
## 并加入 entry_point 组。

extends Node

const PLAYER_SCENE := preload("res://shared/player/player.tscn")
const DIALOGUE_UI_SCENE := preload("res://shared/dialogue/dialogue_ui.tscn")

## 调试用：把游戏内时间固定在 HH:MM，例如 "22:30"。
## 留空则使用系统真实时间。评审时改这个值就能看 NPC 在不同时段说什么。
@export var time_override: String = ""

var _last_scene: Node = null
var _player: Node = null
var _ui: DialogueUI = null

## 正在说话时为真。玩家每帧问一次，说话期间不许动。
var _busy: bool = false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _process(_delta: float) -> void:
	var current := get_tree().current_scene
	if current == _last_scene:
		return
	_last_scene = current
	_setup.call_deferred()


# ---------------------------------------------------------------- 时间

## 当前游戏内时刻，返回一天中的第几分钟。
func minutes_of_day() -> int:
	if not time_override.is_empty():
		var forced := DialogueSet.parse_time(time_override)
		if forced >= 0:
			return forced
		push_warning("[管家] time_override 格式不对（应该是 HH:MM）：%s" % time_override)
	var t := Time.get_time_dict_from_system()
	return int(t["hour"]) * 60 + int(t["minute"])


func clock_text() -> String:
	return DialogueSet.format_time(minutes_of_day())


# ---------------------------------------------------------------- 场景装配

func _setup() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	_ensure_ui()
	_warn_if_no_navmesh(scene)
	_connect_npcs(scene)
	_spawn_player(scene)


## 导航网格是引擎自己从 NavLayer 上收集的，这里只在找不到导航层时提醒一句。
func _warn_if_no_navmesh(scene: Node) -> void:
	if _find_nav_layer(scene) != null:
		return
	push_warning("[管家] 场景 %s 里找不到刷了导航瓦片的 NavLayer，NPC 会原地不动。"
		% scene.name)


func _find_nav_layer(node: Node) -> TileMapLayer:
	if node is TileMapLayer:
		var layer := node as TileMapLayer
		if layer.tile_set != null and layer.tile_set.get_navigation_layers_count() > 0:
			return layer
	for child in node.get_children():
		var found := _find_nav_layer(child)
		if found != null:
			return found
	return null


func _spawn_player(scene: Node) -> void:
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
	_player = PLAYER_SCENE.instantiate()
	scene.add_child(_player)
	var entry := get_tree().get_first_node_in_group("entry_point") as Node2D
	if entry != null:
		_player.global_position = entry.global_position
	else:
		push_warning("[管家] 场景 %s 里没有 entry_point 组的节点，玩家从原点出现。"
			% scene.name)


func _ensure_ui() -> void:
	if _ui != null and is_instance_valid(_ui):
		return
	_ui = DIALOGUE_UI_SCENE.instantiate()
	get_tree().root.add_child(_ui)
	_ui.opened.connect(_on_dialogue_opened)
	_ui.closed.connect(_on_dialogue_closed)


# ---------------------------------------------------------------- 说话期间冻住玩家

func _on_dialogue_opened() -> void:
	_busy = true


func _on_dialogue_closed() -> void:
	_busy = false


## 玩家每帧调用：正在说话就返回 true，这时候不该响应方向键。
func is_busy() -> bool:
	return _busy


# ---------------------------------------------------------------- 对话框

## 说一句话。NPC 通过 spoke 信号走到这里；可交互组件的「说话」也是走这里。
## speaker 非空时会在前面加上「说话人：」。
func say(text: String, speaker: String = "") -> void:
	_ensure_ui()
	_ui.show_line(text if speaker.is_empty() else "%s：%s" % [speaker, text])


## 对话框现在开着吗。
func is_dialogue_open() -> bool:
	return _ui != null and is_instance_valid(_ui) and _ui.is_open()


## 收起对话框。玩家按 E 时调它 —— 返回 true 表示这次按键确实收掉了一个对话框，
## 玩家会把这个按键吃掉，不再触发别的交互。
func close_dialogue() -> bool:
	if not is_dialogue_open():
		return false
	return _ui.close()


## 对话开着的时候按交互键（E）该干什么，由玩家的 try_interact() 调过来：
##   还在打字 → 把整句直接补全，对话框继续开着
##   已经打完 → 收起来
##   没开着   → 什么都不做，返回 false（这次按键可以去触发别的交互）
##
## 补全和收起是两次按 E，所以不会出现「手快按一下就把没看的台词跳过去」。
func advance_dialogue() -> bool:
	if not is_dialogue_open():
		return false
	if _ui.is_typing():
		_ui.skip_typing()
		return true
	return close_dialogue()


# ---------------------------------------------------------------- 对话转发

## 把场景里已有的 NPC 都接上。
##
## 光靠 node_added 是不够的：autoload 的 _ready 跑起来的时候，主场景
## 早就已经进树了，那会儿的 node_added 我们没赶上，NPC 会漏掉。
## 所以每次切场景时主动扫一遍。（node_added 留着接运行中新增的 NPC。）
func _connect_npcs(node: Node) -> void:
	if node is VillageNpc:
		_bind_npc(node as VillageNpc)
	for child in node.get_children():
		_connect_npcs(child)


func _bind_npc(npc: VillageNpc) -> void:
	if not npc.spoke.is_connected(_on_npc_spoke):
		npc.spoke.connect(_on_npc_spoke)


func _on_node_added(node: Node) -> void:
	if node is VillageNpc:
		_bind_npc(node as VillageNpc)


func _on_npc_spoke(text: String) -> void:
	say(text)


# ---------------------------------------------------------------- 工具

## 村民 NPC 壳子 —— 共享资源，参与者请勿修改本文件。
##
## 用法：把 npc.tscn 实例化到你的 entry.tscn 里，然后在检查器里填三样东西：
##   1. Sheet          拖入生成器导出的 sheet.png（2688x1920）
##   2. Dialogue Json  拖入你的 dialogue.json（留空会自动找场景同目录的 dialogue.json）
##   3. 在 NPC 节点下面摆几个 Marker2D 当巡游点（不摆就原地不动）
##
## 角色不会响应方向键，它会自己寻路在巡游点之间走动。
## 玩家靠近后按交互键（默认 E）触发对话。
##
## 按键不在这里听：NPC 身上挂着一个 InteractiveComponent（第 4 层 Interactable），
## 玩家的 TalkArea 检测到它之后，按 E 会回调到下面的 player_interact。
## 这样「谁在响应 E」只有玩家一个人，不会出现 NPC 和对话框抢同一次按键。
## 非共享代码请照抄这个套路：实现 player_interact / enter_interact / exit_interact，
## 不要自己写 _unhandled_input 去听 interact。

class_name VillageNpc
extends CharacterBody2D

@export_group("素材")
## 生成器导出的角色图集，规格 2688x1920。
@export var sheet: Texture2D

@export_group("巡游")
## 移动速度（像素/秒）。
@export var speed: float = 80.0
## 走到巡游点后停下来播的动作。推荐值见 CharacterSheet.RECOMMENDED。
@export var waypoint_activity: String = "idle"
## 每个巡游点停留几秒。
@export var dwell_time: float = 3.0
## 到点后是否强制面向下（坐、躺、看书这类动作只有下朝向）。
@export var face_down_at_waypoint: bool = false

@export_group("对话")
## 对话表。留空则自动查找本场景同目录的 dialogue.json。
@export_file("*.json") var dialogue_json: String = ""

## 对话被触发时发出，参数是这一句要显示的完整文本。
signal spoke(text: String)

@onready var _sprite: Sprite2D = $Sprite
@onready var _agent: NavigationAgent2D = $NavigationAgent2D

var _cs := CharacterSheet.new()
var _anim := SheetAnimator.new(_cs)

var _waypoints: Array[Vector2] = []
var _wp_index: int = 0
var _dwell_left: float = 0.0

var _dialogue: DialogueSet = null
var _player_in_range: bool = false


func _ready() -> void:
	_build_waypoints()

	var problem := CharacterSheet.validate_size(sheet)
	if not problem.is_empty():
		push_error("[NPC] %s（场景：%s）" % [problem, _entry_dir()])
		return

	_sprite.hframes = CharacterSheet.SHEET_COLS
	_sprite.vframes = CharacterSheet.SHEET_ROWS
	_sprite.texture = sheet
	_sprite.offset = Vector2(0, -CharacterSheet.FRAME_H / 2.0)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_agent.radius = 12.0
	_agent.path_desired_distance = 8.0
	_agent.target_desired_distance = 12.0

	_load_dialogue()
	_anim.play("idle", CharacterSheet.DIR_DOWN)
	_sync_sprite()


# ---------------------------------------------------------------- 巡游

func _physics_process(delta: float) -> void:
	if _waypoints.is_empty():
		velocity = Vector2.ZERO
		_tick(delta)
		return

	if _dwell_left > 0.0:
		_dwell_left -= delta
		velocity = Vector2.ZERO
		if _dwell_left <= 0.0:
			_next_waypoint()
		_tick(delta)
		return

	# is_target_reachable 为假说明导航网格还没烘焙好（场景刚加载的头几帧），
	# 这时算不出路径，当成「到了」站在原地等，免得朝原点走。
	if _agent.is_navigation_finished() or not _agent.is_target_reachable():
		_arrive()
		_tick(delta)
		return

	var next := _agent.get_next_path_position()
	var to_next := global_position.direction_to(next)
	if to_next.length_squared() < 0.000001:
		velocity = Vector2.ZERO
		_tick(delta)
		return
	velocity = to_next * speed
	_anim.play("walk", CharacterSheet.dir_from_vector(to_next))
	move_and_slide()
	_tick(delta)


## 巡游点写成 NPC 的子节点，方便在编辑器里拖着摆。但子节点会跟着 NPC 一起走，
## 所以这里只记下开场的坐标，之后不再读节点 —— 否则目标点会越走越偏。
func _build_waypoints() -> void:
	for child in get_children():
		if child is Marker2D:
			_waypoints.append((child as Marker2D).global_position)
	if _waypoints.is_empty():
		return
	# 从离自己最近的巡游点开始，避免开场横穿整个房间
	var best := 0
	var best_d := INF
	for i in _waypoints.size():
		var d := global_position.distance_squared_to(_waypoints[i])
		if d < best_d:
			best_d = d
			best = i
	_wp_index = best
	_agent.target_position = _waypoints[_wp_index]


func _arrive() -> void:
	velocity = Vector2.ZERO
	# 下限 0.01 秒：dwell_time 填 0 时也要过一帧才走，否则会卡在「到点→再判定到点」的死循环
	_dwell_left = maxf(dwell_time, 0.01)
	var act := waypoint_activity
	if not _cs.has(act):
		push_warning("[NPC] 没有叫 %s 的动作，回退到 idle。" % act)
		act = "idle"
	var d := CharacterSheet.DIR_DOWN if face_down_at_waypoint else _anim.dir
	_anim.play(act, d)
	_tick(0.0)


func _next_waypoint() -> void:
	_wp_index = (_wp_index + 1) % _waypoints.size()
	_agent.target_position = _waypoints[_wp_index]


func _tick(delta: float) -> void:
	_anim.advance(delta)
	_sync_sprite()


func _sync_sprite() -> void:
	_sprite.frame = _anim.index()


# ---------------------------------------------------------------- 对话

func _load_dialogue() -> void:
	var path := dialogue_json
	if path.is_empty():
		path = _entry_dir().path_join("dialogue.json")
	if not FileAccess.file_exists(path):
		return
	_dialogue = DialogueSet.load_from_json(path)


# ---------------------------------------------------------------- 交互
#
# 下面三个方法由玩家调用：玩家的 TalkArea 检测到 NPC 身上的 InteractiveComponent，
# 按 E（player_interact）或进出范围（enter_interact / exit_interact）时回调过来。
# NPC 自己不听按键 —— 按键只归玩家管。

## 玩家按 E：挑一句台词说出去，并停下来面向玩家。
func player_interact(player: Node2D) -> void:
	if _dialogue == null:
		return
	var line := _dialogue.pick_now()
	if line == null:
		return

	# 说话时停下来面向玩家
	velocity = Vector2.ZERO
	_dwell_left = maxf(_dwell_left, 1.5)
	_face(player)

	spoke.emit(_wrap(line))


## 玩家走进交互范围。站着不动的时候顺手转个身，让人看得出「它注意到你了」。
func enter_interact(player: Node2D) -> void:
	_player_in_range = true
	if _waypoints.is_empty() or _dwell_left > 0.0:
		_face(player)


## 玩家走出交互范围。
func exit_interact(_player: Node2D) -> void:
	_player_in_range = false


## 玩家现在在不在交互范围内。
func is_player_in_range() -> bool:
	return _player_in_range


## 转身面向某个节点。face_vector 可能把朝向换到这个动作不支持的方向，
## play 自己会挑一个支持的。
func _face(target: Node2D) -> void:
	if target == null or not is_instance_valid(target):
		return
	_anim.face_vector(global_position.direction_to(target.global_position))
	_anim.play(_anim.anim, _anim.dir)
	_sync_sprite()


func _wrap(line: DialogueSet.Line) -> String:
	var who := _display_name()
	return line.text if who.is_empty() else "%s：%s" % [who, line.text]


## 优先用 meta.json 里的 name，没有就用 NPC 节点名。
func _display_name() -> String:
	var meta_path := _entry_dir().path_join("meta.json")
	if FileAccess.file_exists(meta_path):
		var f := FileAccess.open(meta_path, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary and parsed.has("name"):
				return str(parsed["name"])
	return name


## NPC 属于哪个 entry 目录。以 owner 的场景路径为准，找不到就退回自己的。
func _entry_dir() -> String:
	var scene_path := ""
	if owner != null and not owner.scene_file_path.is_empty():
		scene_path = owner.scene_file_path
	elif not scene_file_path.is_empty():
		scene_path = scene_file_path
	return scene_path.get_base_dir()

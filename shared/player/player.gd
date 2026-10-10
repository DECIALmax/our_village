## 共享玩家 —— 共享资源，参与者请勿修改本文件。
##
## 玩家由 GameShell 自动生成，群友不需要在自己的场景里摆。
## 你只要在场景里放一个 Marker2D 并加入 entry_point 组，玩家就会从那里出现。
##
## 操作：WASD / 方向键移动，E 交互（跟 NPC 对话、触发可交互组件、收起对话框）。
##
## 交互是怎么串起来的：
##   玩家身上的 TalkArea（Area2D）只检测第 4 层 Interactable 上的 InteractiveComponent；
##   走进哪个组件的范围，哪个组件就成为交互目标（talk_target，多个时取最近的），
##   同时把玩家头顶的 TalkIcon 亮起来，告诉玩家「现在按 E 有反应」；
##   按 E 由玩家统一分发 —— try_interact() 是唯一的入口，别的地方不要再听 interact 键。

class_name VillagePlayer
extends CharacterBody2D

@export_group("素材")
## 玩家角色图集，规格和 NPC 一样是 2688x1920。
## 不填就只有碰撞体、没有图像，调试时仍可正常走动。
@export var sheet: Texture2D

@export var speed: float = 170.0

@onready var _sprite: Sprite2D = $Sprite
@onready var _talk_area: Area2D = $TalkArea
## 头顶的交互提示（玩家自带的节点，可以没有）。
@onready var _talk_icon: CanvasItem = get_node_or_null("TalkIcon")

var _cs := CharacterSheet.new()
var _anim := SheetAnimator.new(_cs)

## 当前站在交互范围内的组件（可能不止一个）。
var _targets: Array[InteractiveComponent] = []

## 当前交互目标：范围内离玩家最近的那个组件。等价于设计文档里的 talk_target。
var talk_target: InteractiveComponent = null


func _ready() -> void:
	add_to_group("player")
	_sprite.hframes = CharacterSheet.SHEET_COLS
	_sprite.vframes = CharacterSheet.SHEET_ROWS
	_sprite.offset = Vector2(0, -CharacterSheet.FRAME_H / 2.0)
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	if sheet == null:
		push_warning("[玩家] 还没有设置玩家图集，先用无图模式运行。"
			+ "把任意一份 2688x1920 的角色图集拖到 player.tscn 的 Sheet 上即可。")
		_sprite.visible = false
	else:
		var problem := CharacterSheet.validate_size(sheet)
		if not problem.is_empty():
			push_error("[玩家] %s" % problem)
			_sprite.visible = false
		else:
			_sprite.texture = sheet

	# 交互检测区：只认第 4 层 Interactable，自己不作为碰撞层被别人检测
	_talk_area.collision_layer = 0
	_talk_area.collision_mask = InteractiveComponent.LAYER_VALUE
	_talk_area.monitoring = true
	_talk_area.monitorable = false
	if not _talk_area.area_entered.is_connected(_on_talk_area_entered):
		_talk_area.area_entered.connect(_on_talk_area_entered)
	if not _talk_area.area_exited.is_connected(_on_talk_area_exited):
		_talk_area.area_exited.connect(_on_talk_area_exited)

	_anim.play("idle", CharacterSheet.DIR_DOWN)
	_sync()
	_sync_talk_icon()


## 玩家离开场景树（切场景、被 GameShell 重新生成）时，跟还在范围内的组件打个招呼，
## 免得它们的提示留在屏幕上。
func _exit_tree() -> void:
	for t in _targets:
		if is_instance_valid(t):
			t.exit_interact(self)
	_targets.clear()
	talk_target = null
	_sync_talk_icon()


func _physics_process(delta: float) -> void:
	# 范围内有东西就顺手对一遍账：组件可能在玩家还站着的时候被释放掉，
	# 那种情况下物理服务器不一定补发 area_exited，靠这里把渣滓清掉。
	if not _targets.is_empty():
		resolve_target()
	# 对话框的开合不经过交互区信号，图标要跟着说话状态走，所以每帧再对一次。
	# 值没变时 CanvasItem 自己会跳过，开销可以忽略。
	_sync_talk_icon()

	# 正在跟 NPC 说话时不许走，否则玩家能一边听一边把自己开出对话框范围
	if GameShell.is_busy():
		velocity = Vector2.ZERO
		_anim.play("idle", _anim.dir)
		move_and_slide()
		_anim.advance(delta)
		_sync()
		return

	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * speed
	if dir.length_squared() > 0.0001:
		_anim.play("walk", CharacterSheet.dir_from_vector(dir))
	else:
		_anim.play("idle", _anim.dir)
	move_and_slide()
	_anim.advance(delta)
	_sync()


# ---------------------------------------------------------------- 交互

## 按 E。按键只在这里听一次，别人不要再监听 interact。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return
	if try_interact():
		get_viewport().set_input_as_handled()


## 交互入口。返回 true 表示这次按 E 被玩家吃掉了。
##
## 优先级（以玩家的逻辑为准）：
##   1. 对话框开着 → E 是「收起对话」，不再触发别的交互
##   2. 范围内有可交互组件 → 交给离得最近的那个
func try_interact() -> bool:
	if GameShell.close_dialogue():
		return true
	var target := resolve_target()
	if target == null:
		return false
	target.player_interact(self)
	return true


## 重新算一遍当前交互目标（顺带清掉已经被释放的组件），并刷新头顶的提示图标。
func resolve_target() -> InteractiveComponent:
	for i in range(_targets.size() - 1, -1, -1):
		var t := _targets[i]
		if not is_instance_valid(t) or t.is_queued_for_deletion():
			_targets.remove_at(i)
	talk_target = _nearest()
	_sync_talk_icon()
	return talk_target


## 头顶的 TalkIcon：站在可交互范围里就亮，走出来就灭。
## 判断依据是 talk_target，跟按 E 时用的是同一个值，不会出现「图标亮着但按 E 没反应」。
## 对话框开着的时候也灭掉 —— 那时候按 E 是收框，不是搭话，亮着反而误导。
func _sync_talk_icon() -> void:
	if _talk_icon == null or not is_instance_valid(_talk_icon):
		return
	_talk_icon.visible = talk_target != null and not GameShell.is_busy()


func _nearest() -> InteractiveComponent:
	var best: InteractiveComponent = null
	var best_d := INF
	for t in _targets:
		if not t.enabled:
			continue
		var d := global_position.distance_squared_to(t.global_position)
		if d < best_d:
			best_d = d
			best = t
	return best


func _on_talk_area_entered(area: Area2D) -> void:
	if not is_instance_valid(area) or not (area is InteractiveComponent):
		return
	var c := area as InteractiveComponent
	if not c.enabled or _targets.has(c):
		return
	_targets.append(c)
	c.enter_interact(self)
	resolve_target()


func _on_talk_area_exited(area: Area2D) -> void:
	# 组件在玩家还站着的时候被释放，这里可能收到一个已经没了的对象
	if not is_instance_valid(area):
		resolve_target()
		return
	if not (area is InteractiveComponent):
		return
	var c := area as InteractiveComponent
	_targets.erase(c)
	c.exit_interact(self)
	resolve_target()


# ---------------------------------------------------------------- 渲染

func _sync() -> void:
	_sprite.frame = _anim.index()

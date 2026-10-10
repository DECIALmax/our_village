## 可交互组件 —— 共享资源，参与者请勿修改本文件。
##
## 玩家身上带一个 TalkArea，走进本组件的范围后，本组件就成为玩家的交互目标，
## 头顶（Prompt 节点）会冒出提示；玩家按 E（interact 动作）时，由玩家统一
## 调用 player_interact / enter_interact / exit_interact 分发到这里。
##
## 换句话说：**按键只归玩家管**。可交互对象自己不要再去监听按键，
## 否则同一次按 E 会被两个人听到，各说各话。
##
## 两种用法，按需要挑一种：
##
##   用法 A —— 转发（代理模式）
##     把本组件挂到你的对象下面，你的对象实现下面任意方法即可：
##
##         func player_interact(player: Node2D) -> void   # 玩家按 E
##         func enter_interact(player: Node2D) -> void    # 玩家走近
##         func exit_interact(player: Node2D) -> void     # 玩家走开
##
##     转发目标默认是父节点；也可以把 Agent 属性指到别的节点。
##     共享的 npc.tscn 就是这么接的，照抄即可。
##
##   用法 B —— 不写代码
##     把 interactive_component.tscn 拖进你的场景，摆在你希望玩家能按 E 的地方，
##     在检查器里把 Action 选成「说话 / 切换场景 / 发信号」，填好内容即可。
##
## 碰撞层固定在第 4 层（Interactable）：本组件自己不检测任何东西
## （monitoring = false），只让玩家的 TalkArea 检测到它。

class_name InteractiveComponent
extends Area2D

## 交互方式。
enum Action {
	FORWARD,      ## 转发给 Agent（Agent 留空则用父节点）
	SAY,          ## 用共享对话框说一句话
	CHANGE_SCENE, ## 切换到 Target Scene
	EMIT,         ## 不发提示、不做事，只发 interacted 信号，交给参与者自己的脚本
}

## 交互被触发时发出。无论哪种 Action 都会发，方便挂音效、统计之类的东西。
signal interacted(player: Node2D)

## 第 4 层（Interactable）的位值。玩家的 TalkArea 用同一个值当 collision_mask。
const LAYER_VALUE := 8

## 默认提示文字。
const DEFAULT_PROMPT := "按 E"

@export_group("开关")
## 关掉之后玩家看不见它、按 E 也没反应（比如任务做完了把交互撤掉）。
@export var enabled: bool = true

@export_group("转发（用法 A）")
## 转发目标。留空 = 自动用父节点。
@export var agent: Node = null

@export_group("自己处理（用法 B）")
## 交互方式。Agent 有对应方法时优先转发；没有就按这里的设置执行。
@export var action: Action = Action.FORWARD
## Action = SAY 时说的话。
@export_multiline var say_text: String = ""
## Action = SAY 时的说话人。留空就只显示 say_text，不前缀名字。
@export var say_speaker: String = ""
## Action = CHANGE_SCENE 时要跳去的场景。只能填你自己目录下的 .tscn。
@export_file("*.tscn") var target_scene: String = ""

@export_group("提示")
## 玩家走近时提示的文字。留空则不显示提示。
@export var prompt_text: String = DEFAULT_PROMPT

var _player: Node2D = null
var _prompt: CanvasItem = null
var _changing_scene: bool = false


func _ready() -> void:
	# 这三个属性写死在代码里，避免参与者在检查器里手滑改出「检测不到」的状态
	collision_layer = LAYER_VALUE
	collision_mask = 0
	monitoring = false
	monitorable = true

	_prompt = get_node_or_null("Prompt") as CanvasItem
	if _prompt != null:
		if _prompt is Label and not prompt_text.is_empty():
			(_prompt as Label).text = prompt_text
		_prompt.visible = false


# ---------------------------------------------------------------- 玩家调用的三个口子

## 玩家按 E 时由玩家调用。
func player_interact(player: Node2D) -> void:
	if not enabled:
		return
	var a := _resolve_agent()
	if a != null and a.has_method("player_interact"):
		a.player_interact(player)
		interacted.emit(player)
		return

	match action:
		Action.SAY:
			if not _say():
				return
		Action.CHANGE_SCENE:
			if not _change_scene():
				return
		Action.EMIT:
			pass
		_:
			push_warning("[交互] %s 没有可转发的对象（Agent 没填，父节点也没有 player_interact），"
				% name + "Action 又不是「说话 / 切换场景 / 发信号」，按 E 不会有反应。")
			return
	interacted.emit(player)


## 玩家走进范围时由玩家调用。
func enter_interact(player: Node2D) -> void:
	if not enabled:
		return
	_player = player
	_show_prompt(true)
	var a := _resolve_agent()
	if a != null and a.has_method("enter_interact"):
		a.enter_interact(player)


## 玩家走出范围时由玩家调用。
func exit_interact(player: Node2D) -> void:
	if _player == player:
		_player = null
	_show_prompt(false)
	var a := _resolve_agent()
	if a != null and a.has_method("exit_interact"):
		a.exit_interact(player)


## 现在是不是有玩家站在里面。
func has_player() -> bool:
	return _player != null and is_instance_valid(_player)


# ---------------------------------------------------------------- 内部

## 转发目标：Agent 优先，留空则用父节点。
func _resolve_agent() -> Node:
	if agent != null:
		return agent if is_instance_valid(agent) else null
	return get_parent()


func _say() -> bool:
	var text := say_text.strip_edges()
	if text.is_empty():
		push_warning("[交互] %s 的 Say Text 是空的，按 E 不会有反应。" % name)
		return false
	if say_speaker.strip_edges().is_empty():
		GameShell.say(text)
	else:
		GameShell.say(text, say_speaker.strip_edges())
	return true


## 切场景。失败（没填 / 文件不存在）时返回 false 并说明原因。
func _change_scene() -> bool:
	if _changing_scene:
		return false
	if target_scene.is_empty():
		push_warning("[交互] %s 没有设置 Target Scene，按 E 不会有反应。" % name)
		return false
	if not FileAccess.file_exists(target_scene):
		push_error("[交互] %s 找不到目标场景：%s" % [name, target_scene])
		return false
	_changing_scene = true
	get_tree().change_scene_to_file(target_scene)
	return true


func _show_prompt(show: bool) -> void:
	if _prompt == null or not is_instance_valid(_prompt):
		return
	_prompt.visible = show and enabled and not prompt_text.strip_edges().is_empty()

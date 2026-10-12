extends "res://shared/npc/npc.gd"

@onready var _interact_prompt: Label = $InteractPrompt

var _dialogue_active: bool = false
var _opened_frame: int = -1
var _local_dialogue_ui: DialogueUI


func _ready() -> void:
	super._ready()
	_restore_idle()
	spoke.connect(_on_spoke)


func _process(_delta: float) -> void:
	_interact_prompt.visible = _player_in_range and not _dialogue_active and not GameShell.is_busy()


func _unhandled_input(event: InputEvent) -> void:
	if _dialogue_active or GameShell.is_busy():
		return
	if event is InputEventKey and event.echo:
		return
	super._unhandled_input(event)


func _input(event: InputEvent) -> void:
	if not _dialogue_active:
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	# 打开对话的那次E不参与关闭，长按产生的重复事件也不关闭。
	if Engine.get_process_frames() <= _opened_frame:
		return
	if not is_instance_valid(_local_dialogue_ui):
		_watch_dialogue_closed()
	if not is_instance_valid(_local_dialogue_ui):
		return
	get_viewport().set_input_as_handled()
	# 共享UI没有公开关闭接口；仅关闭本NPC正在显示的这一轮对话。
	# 必须走其_hide方法发出closed信号，让GameShell同步解除玩家锁定。
	_local_dialogue_ui.get_node("Timer").stop()
	_local_dialogue_ui._hide()


func _on_spoke(_text: String) -> void:
	_dialogue_active = true
	_opened_frame = Engine.get_process_frames()
	_interact_prompt.hide()
	_watch_dialogue_closed.call_deferred()


func _watch_dialogue_closed() -> void:
	for child in get_tree().root.get_children():
		if child is DialogueUI:
			_local_dialogue_ui = child
			if not _local_dialogue_ui.closed.is_connected(_on_dialogue_closed):
				_local_dialogue_ui.closed.connect(_on_dialogue_closed)
			return


func _on_dialogue_closed() -> void:
	_dialogue_active = false
	_restore_idle()


func _restore_idle() -> void:
	_anim.play("idle", CharacterSheet.DIR_RIGHT)
	_sync_sprite()

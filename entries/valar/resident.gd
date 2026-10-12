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


# 这里不再有 _unhandled_input：交互键（E）由玩家统一监听，
# 玩家按 E 时会回调到 NPC 的 player_interact()，不需要 NPC 自己再听一遍按键。
# （父类 VillageNpc 已经删掉了 _unhandled_input，所以 super._unhandled_input() 也不存在了。）


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
	# 只收起本 NPC 正在显示的这一轮对话。
	# close() 是共享 UI 的公开接口：它会停掉打字机和 Timer 再收起，
	# 并发出 closed 让 GameShell 同步解除玩家锁定（不要再去调 _hide() 这种内部方法）。
	_local_dialogue_ui.close()


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

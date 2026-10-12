extends Area2D
## 顶部木板触发整铺阁楼床的淡入淡出。

@export_range(0.05, 2.0, 0.05) var fade_duration: float = 0.45

@onready var _loft_visual: Node2D = $LoftVisual

var _players: Dictionary = {}
var _original_z: Dictionary = {}
var _fade: Tween


func _ready() -> void:
	_loft_visual.hide()
	_loft_visual.modulate.a = 0.0
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player") or _players.has(body):
		return
	_players[body] = true
	if not _original_z.has(body):
		_original_z[body] = body.z_index
	# 阁楼盖住一楼家具，但不能盖住站在顶部的玩家。
	body.z_index = 12
	_fade_to(1.0)


func _on_body_exited(body: Node2D) -> void:
	if not _players.has(body):
		return
	_players.erase(body)
	if _players.is_empty():
		_fade_to(0.0)
	else:
		_restore_player(body)


func _fade_to(alpha: float) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_loft_visual.show()
	var duration := maxf(0.01, fade_duration * absf(alpha - _loft_visual.modulate.a))
	_fade = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade.tween_property(_loft_visual, "modulate:a", alpha, duration)
	_fade.tween_callback(_finish_fade.bind(alpha))


func _finish_fade(alpha: float) -> void:
	if alpha > 0.0:
		return
	_loft_visual.hide()
	# 淡出结束再恢复排序，避免退下楼梯时玩家被尚未消失的床面遮住。
	for body in _original_z.keys():
		if not _players.has(body):
			_restore_player(body)


func _restore_player(body: Node2D) -> void:
	if is_instance_valid(body) and _original_z.has(body):
		body.z_index = _original_z[body]
	_original_z.erase(body)


func _exit_tree() -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	for body in _original_z.keys():
		_restore_player(body)
	_players.clear()

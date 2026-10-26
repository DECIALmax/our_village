## godot --headless --path . --quit-after 3000 res://tools/smoke_test_hub.tscn
## 验证首次引导、锁移动、区域触发、所有小屋往返与再次进入不重复引导。
extends Node

const HUB := "res://main.tscn"
const WELCOME: Array[String] = [
	"欢迎来到Godot新手村",
	"这里是我们新手村村民们一起创造的虚拟空间",
	"每个小屋都是由一位村民设计打造的",
	"希望你玩的愉快",
]
var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	# 测试节点保留在 root，小屋切换时只释放被测场景。
	get_tree().current_scene = null
	GameShell.hub_intro_seen = false
	get_tree().change_scene_to_file(HUB)
	await _wait(35)
	var hub := get_tree().current_scene
	var player := get_tree().get_first_node_in_group("player") as VillagePlayer
	_check(player != null, "主场景自动生成玩家")
	if player == null:
		_finish()
		return
	_check(player.global_position.is_equal_approx(hub.get_node("EntryPoint").global_position), "玩家从入口位置出现，边界限制不改变出生点")
	_check(hub.get_node("HouseEntrance/CollisionShape2D").shape.size == Vector2(30, 30), "区域为 30×30")
	_check(get_viewport().get_camera_2d() == hub.get_node("Camera2D"), "主场景使用固定相机")
	var entrance_position: Vector2 = hub.get_node("HouseEntrance").global_position
	var ui = GameShell.get("_ui")
	for line in WELCOME:
		_check(ui.get_node("Panel/Margin/Text").text == line, "欢迎词顺序和内容：%s" % line)
		_check(GameShell.is_busy(), "每句欢迎词期间锁住移动")
		var before := player.position
		Input.action_press("move_right")
		await _wait(4)
		Input.action_release("move_right")
		_check(player.position == before, "欢迎词期间按移动键不会走动")
		await _key(KEY_E)
		_check(not ui.is_typing(), "第一次 E 补全整句")
		_check(ui.is_open() and ui.get_node("Timer").is_stopped(), "等待玩家确认，不自动跳过欢迎词")
		await _key(KEY_E)
	_check(GameShell.hub_intro_seen and not GameShell.is_busy(), "四句读完后解锁移动")
	Input.action_press("move_up")
	for i in 100:
		await _wait(1)
		if hub.house_picker.visible:
			break
	Input.action_release("move_up")
	await _wait(3)
	_check(hub.house_picker.visible, "玩家走进区域后自动打开选择窗口")
	_check(GameShell.is_busy(), "选择窗口期间锁住移动")
	var before := player.position
	Input.action_press("move_right")
	await _wait(5)
	Input.action_release("move_right")
	_check(player.position == before, "选择窗口期间按移动键不会走动")
	await _key(KEY_ESCAPE)
	_check(not hub.house_picker.visible and not GameShell.is_busy(), "Esc 关闭并恢复移动")
	player.global_position = entrance_position + Vector2(0, 100)
	await _wait(4)
	player.global_position = entrance_position + Vector2(0, 5)
	await _wait(4)
	_check(hub.house_picker.visible, "离开区域再进入可以重新打开")
	var paths: Array[String] = []
	for button in hub.house_buttons.get_children():
		paths.append(button.get_meta("scene_path"))
	_check(not paths.is_empty(), "发现了小屋")
	_check(not paths.has("res://entries/_example/entry.tscn"), "不列出示例目录")
	for path in paths:
		hub = get_tree().current_scene
		if not hub.house_picker.visible:
			player = get_tree().get_first_node_in_group("player") as VillagePlayer
			player.global_position = hub.get_node("HouseEntrance").global_position + Vector2(0, 5)
			await _wait(5)
		var chosen: Button
		for button in hub.house_buttons.get_children():
			if button.get_meta("scene_path") == path:
				chosen = button
		_check(chosen != null, "存在小屋按钮：%s" % path)
		if chosen == null:
			continue
		chosen.pressed.emit()
		await _wait(35)
		_check(get_tree().current_scene.scene_file_path == path, "按钮进入对应小屋：%s" % path)
		_check(not GameShell.is_busy(), "进入小屋后没有残留移动锁")
		var portal := _find_portal(get_tree().current_scene)
		_check(portal != null, "小屋有出口：%s" % path)
		if portal == null:
			continue
		player = get_tree().get_first_node_in_group("player") as VillagePlayer
		# 真实触发 Area2D 的 body_entered，覆盖物理回调中延后切场景。
		player.global_position = portal.get_node("CollisionShape2D").global_position
		await _wait(35)
		_check(get_tree().current_scene.scene_file_path == HUB, "从小屋出口返回村庄：%s" % path)
		if get_tree().current_scene.scene_file_path != HUB:
			get_tree().change_scene_to_file(HUB)
			await _wait(35)
		_check(not GameShell.is_dialogue_open() and not GameShell.is_busy(), "返回后不重复欢迎且能移动")
		player = get_tree().get_first_node_in_group("player") as VillagePlayer
		_check(player.global_position.is_equal_approx(get_tree().current_scene.get_node("EntryPoint").global_position), "返回安全出生点，不立即打开选择窗口")
	# 不经主场景直接运行作品时，保留作者原有的场景目标。
	GameShell.active_house_entry = ""
	_check(GameShell.resolve_exit_target("res://entries/kelei/inner_room.tscn") == "res://entries/kelei/inner_room.tscn", "独立运行小屋保留原有出口目标")
	_finish()


func _find_portal(node: Node) -> ExitPortal:
	if node is ExitPortal:
		return node
	for child in node.get_children():
		var found := _find_portal(child)
		if found != null:
			return found
	return null


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await _wait(2)
	event = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	Input.parse_input_event(event)
	await _wait(2)


func _wait(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fails.append(message)
		push_error("[失败] " + message)


func _finish() -> void:
	if _fails.is_empty():
		print("主场景冒烟测试通过：欢迎词、移动锁、中央区域、窗口和所有小屋往返。")
	else:
		print("主场景冒烟测试失败：", _fails)
	get_tree().quit(0 if _fails.is_empty() else 1)

extends Node2D

const WELCOME_LINES: Array[String] = [
	"欢迎来到Godot新手村",
	"这里是我们新手村村民们一起创造的虚拟空间",
	"每个小屋都是由一位村民设计打造的",
	"希望你玩的愉快",
]

@onready var house_picker: Control = $UI/HousePicker
@onready var house_buttons: VBoxContainer = $UI/HousePicker/Panel/Margin/Contents/Scroll/HouseButtons
@onready var picker_title: Label = $UI/HousePicker/Panel/Margin/Contents/Title
@onready var hint: Label = $UI/Hint

var _player: VillagePlayer
var _intro_active: bool = false


func _ready() -> void:
	GameShell.active_house_entry = ""
	GameShell.dialogue_sequence_finished.connect(_on_intro_finished)
	$HouseEntrance.body_entered.connect(_on_entrance_entered)
	$UI/HousePicker/Panel/Margin/Contents/Close.pressed.connect(_close_picker)
	_build_house_buttons()


## 由 GameShell 生成玩家后调用，避免主场景和共享管家重复生成玩家。
func configure_player(player: VillagePlayer) -> void:
	_player = player
	_player.get_node("Camera2D").enabled = false
	$Camera2D.make_current()
	if not GameShell.hub_intro_seen:
		_intro_active = true
		GameShell.play_dialogue_sequence(WELCOME_LINES)
	else:
		_show_movement_hint()


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_player):
		return
	# 在屏幕坐标中限制边界，再转回世界坐标，兼容相机的锚点、位置和缩放。
	var canvas := get_canvas_transform()
	var screen_position := canvas * _player.global_position
	var bounded := screen_position.clamp(
		Vector2(24, 100), get_viewport_rect().size - Vector2(24, 24))
	if not screen_position.is_equal_approx(bounded):
		_player.global_position = canvas.affine_inverse() * bounded


func _unhandled_input(event: InputEvent) -> void:
	if house_picker.visible and event.is_action_pressed("ui_cancel"):
		_close_picker()
		get_viewport().set_input_as_handled()


func _on_intro_finished() -> void:
	if not _intro_active:
		return
	_intro_active = false
	GameShell.hub_intro_seen = true
	_show_movement_hint()


func _show_movement_hint() -> void:
	hint.text = "Godot新手村"


func _on_entrance_entered(body: Node2D) -> void:
	if body != _player or _intro_active or house_picker.visible:
		return
	_open_picker()


func _open_picker() -> void:
	house_picker.show()
	GameShell.set_controls_locked(self, true)
	if house_buttons.get_child_count() > 0:
		(house_buttons.get_child(0) as Button).grab_focus()
	else:
		$UI/HousePicker/Panel/Margin/Contents/Close.grab_focus()


func _close_picker() -> void:
	house_picker.hide()
	GameShell.set_controls_locked(self, false)
	# 关闭后先走出方框，再走进来就能重新打开。


func _build_house_buttons() -> void:
	var directories := DirAccess.get_directories_at("res://entries")
	directories.sort()
	for directory in directories:
		if directory.begins_with("_") or directory.begins_with("."):
			continue
		var base := "res://entries".path_join(directory)
		var path := base.path_join("entry.tscn")
		if not ResourceLoader.exists(path):
			continue
		var metadata: Dictionary = {}
		var meta_path := base.path_join("meta.json")
		if FileAccess.file_exists(meta_path):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
			if parsed is Dictionary:
				metadata = parsed
		var house_name := str(metadata.get("name", "")).strip_edges()
		if house_name.is_empty():
			house_name = str(metadata.get("author", directory)).strip_edges()
		if house_name.is_empty():
			house_name = directory
		var button := Button.new()
		button.text = "%s的小屋" % house_name
		button.custom_minimum_size = Vector2(0, 48)
		button.add_theme_font_size_override("font_size", 20)
		button.tooltip_text = str(metadata.get("note", ""))
		button.set_meta("scene_path", path)
		button.pressed.connect(_enter_house.bind(path))
		house_buttons.add_child(button)
	if house_buttons.get_child_count() == 0:
		picker_title.text = "暂时还没有开放的小屋"


func _enter_house(path: String) -> void:
	_close_picker()
	var result := GameShell.enter_house(path)
	if result != OK:
		picker_title.text = "小屋暂时无法进入，请重新选择"
		_open_picker()
		push_error("进入小屋失败：%s（%s）" % [path, error_string(result)])

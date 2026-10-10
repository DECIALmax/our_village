## 共享对话框 —— 共享资源，参与者请勿修改本文件。
##
## 由 GameShell 自动放进场景树，NPC 说话时会自动弹出来。
## 想改样式就改 dialogue_ui.tscn，但注意这是共享文件，改动会影响所有人。
##
## 文字是打字机效果：从第一个字起一个一个冒出来，速度由 Chars Per Second 控制
## （默认每秒 5 个字）。整句打完之后才开始算 Hold Seconds 的停留时间 ——
## 所以再长的台词也不会出现「还没打完就自己收起来」。
##
## 对话框自己不监听按键：按 E 收起对话这件事归玩家管
## （玩家 VillagePlayer.try_interact → GameShell.close_dialogue）。
## 这样同一次按 E 只会有一个地方响应，不会出现「对话框收起来的同时又跟 NPC 说了一遍」。

class_name DialogueUI
extends CanvasLayer

## 弹出 / 收起时发出。GameShell 靠它知道「现在在说话」，好把玩家冻住。
signal opened
signal closed

## 整句打完之后停留几秒，然后再自动收起。
@export var hold_seconds: float = 4.0

## 打字机速度：每秒显示几个字。填 0 或负数 = 不打字，整句直接出来。
##
## 想调节奏就改 dialogue_ui.tscn 上 DialogueUI 节点的 Chars Per Second（检查器里就能改），
## 那里写的值优先；这里只是没有场景覆盖时的兜底默认值。
@export var chars_per_second: float = 20.0

## 可选：拖一个中文字体进来。留空则用 Godot 默认字体
## （4.3+ 会自动回退到系统字体，Windows 上一般能正常显示中文）。
@export var font: FontFile

@onready var _panel: PanelContainer = $Panel
@onready var _label: Label = $Panel/Margin/Text
@onready var _timer: Timer = $Timer

## 已经冒出多少字。用小数累加，免得每帧取整把速度拖慢。
var _shown: float = 0.0
## 这一句一共多少字。
var _total: int = 0
## 现在是正在打字。打完就把 _process 关掉，不空转。
var _typing: bool = false


func _ready() -> void:
	_panel.visible = false
	_timer.one_shot = true
	_timer.timeout.connect(_hide)
	if font != null:
		_label.add_theme_font_override("font", font)
	set_process(false)


func show_line(text: String) -> void:
	_label.text = text
	_total = text.length()
	_shown = 0.0
	_panel.visible = true
	# 上一句的停留计时可能还在跑，先掐掉，免得它把这一句提前收走
	_timer.stop()

	if chars_per_second <= 0.0 or _total == 0:
		_finish_typing()
	else:
		# 用 visible_characters 而不是逐帧拼 text：整句先排好版，
		# 字一个个显出来，换行位置不会随着字数变多而跳来跳去。
		_label.visible_characters = 0
		_typing = true
		set_process(true)

	opened.emit()


func _process(delta: float) -> void:
	if not _typing:
		return
	_shown += chars_per_second * delta
	_label.visible_characters = clampi(int(_shown), 0, _total)
	if _shown >= float(_total):
		_finish_typing()


## 整句都显出来了：停下打字，开始数停留时间。
func _finish_typing() -> void:
	_typing = false
	set_process(false)
	_label.visible_characters = _total
	_timer.start(hold_seconds)


## 现在还在打字吗。
func is_typing() -> bool:
	return _typing


## 把整句直接补全（玩家按 E 跳过打字）。真的跳了才返回 true。
## 补完之后停留计时正常开始，所以跳过不会把对话框一直挂在屏幕上。
func skip_typing() -> bool:
	if not _typing:
		return false
	_finish_typing()
	return true


## 现在是不是开着。
func is_open() -> bool:
	return _panel.visible


## 收起对话框。返回是否真的收起来了（本来就关着就返回 false）。
## 玩家按 E 时由 GameShell.close_dialogue() 调过来，不用干等 hold_seconds 走完。
func close() -> bool:
	if not _panel.visible:
		return false
	_stop_typing()
	_timer.stop()
	_hide()
	return true


func _stop_typing() -> void:
	_typing = false
	set_process(false)


func _hide() -> void:
	# 自动超时和手动收起都可能进来，挡一下免得 closed 发两遍
	if not _panel.visible:
		return
	_stop_typing()
	_panel.visible = false
	closed.emit()

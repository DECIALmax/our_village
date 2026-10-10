## 共享对话框 —— 共享资源，参与者请勿修改本文件。
##
## 由 GameShell 自动放进场景树，NPC 说话时会自动弹出来。
## 想改样式就改 dialogue_ui.tscn，但注意这是共享文件，改动会影响所有人。
##
## 对话框自己不监听按键：按 E 收起对话这件事归玩家管
## （玩家 VillagePlayer.try_interact → GameShell.close_dialogue）。
## 这样同一次按 E 只会有一个地方响应，不会出现「对话框收起来的同时又跟 NPC 说了一遍」。

class_name DialogueUI
extends CanvasLayer

## 弹出 / 收起时发出。GameShell 靠它知道「现在在说话」，好把玩家冻住。
signal opened
signal closed

## 一句话停留几秒。
@export var hold_seconds: float = 4.0

## 可选：拖一个中文字体进来。留空则用 Godot 默认字体
## （4.3+ 会自动回退到系统字体，Windows 上一般能正常显示中文）。
@export var font: FontFile

@onready var _panel: PanelContainer = $Panel
@onready var _label: Label = $Panel/Margin/Text
@onready var _timer: Timer = $Timer


func _ready() -> void:
	_panel.visible = false
	_timer.one_shot = true
	_timer.timeout.connect(_hide)
	if font != null:
		_label.add_theme_font_override("font", font)


func show_line(text: String) -> void:
	_label.text = text
	_panel.visible = true
	_timer.start(hold_seconds)
	opened.emit()


## 现在是不是开着。
func is_open() -> bool:
	return _panel.visible


## 收起对话框。返回是否真的收起来了（本来就关着就返回 false）。
## 玩家按 E 时由 GameShell.close_dialogue() 调过来，不用干等 hold_seconds 走完。
func close() -> bool:
	if not _panel.visible:
		return false
	_timer.stop()
	_hide()
	return true


func _hide() -> void:
	# 自动超时和手动收起都可能进来，挡一下免得 closed 发两遍
	if not _panel.visible:
		return
	_panel.visible = false
	closed.emit()

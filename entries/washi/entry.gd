extends Node2D
@onready var bookshelf: PanelContainer = %Bookshelf
@onready var profile_button: Button = %ProfileButton
@onready var game_button: Button = %GameButton
@onready var game_button_2: Button = %GameButton2

func _ready() -> void:
	bookshelf.hide()


func _on_interactive_component_interacted(_player: Node2D) -> void:
	bookshelf.show()


func _on_profile_button_pressed() -> void:
	OS.shell_open("https://www.godotvillage.com/#/talent/11513807-10bc-4429-8ae3-71fbf1a87334")


func _on_game_button_pressed() -> void:
	OS.shell_open("https://ffdash.rika.link")


func _on_game_button_2_pressed() -> void:
	OS.shell_open("https://www.godotvillage.com/#/project/c8be8345-e91f-4c04-97a3-175aa068669e")


func _on_exit_button_pressed() -> void:
	bookshelf.hide()

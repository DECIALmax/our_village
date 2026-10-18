extends PointLight2D


func _ready() -> void:
	var timer = Timer.new()
	timer.one_shot = false
	add_child(timer)
	timer.timeout.connect(_on_timer_timeout)
	timer.start(0.5)
	

func _on_timer_timeout() -> void:
	texture_scale = 2.0 * float(randi_range(95,105)) / 100

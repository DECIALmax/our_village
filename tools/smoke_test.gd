## 冒烟测试：把范例场景真跑一遍，确认「导航烘焙 + 生成玩家 + NPC 巡游」这条链路是通的。
##
##   godot --headless --path . res://tools/smoke_test.tscn
##
## 全绿返回 0，有问题返回 1。改完共享代码记得跑一下。
##
## 注意：这里用「一个场景」而不是 --script 主循环，因为 --script 模式下
## await physics_frame 不会推进，脚本会卡死。

extends Node

const SCENE_PATH := "res://entries/_example/entry.tscn"
const WARMUP_FRAMES := 30      # 留给 GameShell 发现场景、烘焙导航
const OBSERVE_FRAMES := 240    # 观察 NPC 走不走得动

var _fails: Array[String] = []

## 交互测试里数 NPC 说了几次话，用来验证「interact 键只归玩家」。
var _spoke_count: int = 0


func _ready() -> void:
	_run()


func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("load 不到 %s" % SCENE_PATH)
		return _finish()

	# 当成子节点挂进来。GameShell 会从 current_scene 往下找 NavigationRegion2D 和 entry_point，
	# 所以放在这一层它照样能找到。
	var scene := packed.instantiate()
	add_child(scene)

	for i in WARMUP_FRAMES:
		await get_tree().physics_frame

	# 导航网格由 NavLayer 自己注册进场景的导航地图，直接问导航服务器要
	var map := get_viewport().find_world_2d().navigation_map
	var regions: Array = NavigationServer2D.map_get_regions(map)
	if regions.is_empty():
		_fail("导航地图里没有任何导航区域 —— NavLayer 上刷格子了吗？")
	else:
		print("  导航地图里有 %d 个导航区域" % regions.size())

	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		_fail("GameShell 没有生成玩家")
	else:
		var entry := get_tree().get_first_node_in_group("entry_point") as Node2D
		if entry == null:
			_fail("场景里没有 entry_point 组的节点")
		elif player.global_position.distance_to(entry.global_position) > 1.0:
			_fail("玩家没有出现在 entry_point 上（玩家 %s，出生点 %s）"
				% [player.global_position, entry.global_position])
		else:
			print("  玩家已生成在 entry_point：%s" % player.global_position)

	var npc := _find_npc(scene)
	if npc == null:
		_fail("场景里没有 VillageNpc")
		return _finish()
	if npc.get("sheet") == null:
		_fail("NPC 的 Sheet 没有填")

	_check_dialogue(npc)
	await _check_dialogue_link(npc)

	# NPC 站的地方必须落在导航网格上，否则它再努力也走不动
	var on_mesh := NavigationServer2D.map_get_closest_point(map, npc.global_position)
	var off := on_mesh.distance_to(npc.global_position)
	if off > 64.0:
		_fail("NPC 出生点不在导航网格上（离网格 %.0f 像素），NavLayer 要铺到它脚下" % off)

	var from: Vector2 = npc.global_position
	for i in OBSERVE_FRAMES:
		await get_tree().physics_frame
	var to: Vector2 = npc.global_position
	var walked := from.distance_to(to)
	if walked < 8.0:
		_fail("NPC 四秒只挪了 %.1f 像素，八成是没在寻路" % walked)
	else:
		print("  NPC 巡游正常：走了 %.1f 像素，%s -> %s" % [walked, from, to])

	await _check_interaction(scene)

	return _finish()


# ---------------------------------------------------------------- 工具

## 对话表要能加载，而且 24 小时里每一刻都抽得出台词。
## 缺哪个时段，玩家那个点走过来就会没反应 —— 这是最容易漏的一条。
func _check_dialogue(npc: Node) -> void:
	var d = npc.get("_dialogue")
	if d == null:
		_fail("NPC 没有加载到对话表（dialogue.json 路径填错或 JSON 写错了）")
		return

	var silent: Array[String] = []
	for hour in 24:
		if d.pick(hour * 60) == null:
			silent.append("%02d:00" % hour)
	if not silent.is_empty():
		_fail("这些时刻抽不出台词：%s" % ", ".join(silent))
		return
	print("  对话表已加载：%d 条，24 小时全覆盖" % d.lines.size())


## 说话这条链路：NPC 发信号 → 管家接住 → 对话框弹出来 → 玩家被冻住。
## 光有一环对不算数，这里从头发到尾走一遍。
##
## 注意开头那一步：这个测试是把范例场景 add_child 进来的，那时 GameShell 早就
## 连好 node_added 了，信号自然接得上 —— 真实的翻车场景（引擎启动时主场景
## 先于 autoload 的 _ready 进树）在这儿复现不出来。所以先把信号断开，手动
## 制造「漏接」的状态，再看管家重新装配时会不会补上。
func _check_dialogue_link(npc: Node) -> void:
	for c in npc.spoke.get_connections():
		npc.spoke.disconnect(c["callable"])
	if not npc.spoke.get_connections().is_empty():
		_fail("测试自身出错：spoke 信号断不开")
		return

	GameShell.call("_setup")
	await get_tree().process_frame

	var conns: int = npc.spoke.get_connections().size()
	if conns == 0:
		_fail("NPC 的 spoke 信号没接上 —— 台词抽得出来，但永远弹不出对话框")
		return

	# _setup 会重新生成玩家，所以要拿新的那个
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		_fail("_setup 之后找不到玩家")
		return

	# 打字速度压到 1 字/秒：保证下面按 E 的时候台词还在打，
	# 才能确定地测到「第一次补全、第二次收起」，不受机器快慢影响
	var ui = GameShell.get("_ui")
	if ui == null:
		_fail("GameShell 没有对话框实例")
		return
	var keep_cps: float = ui.chars_per_second
	ui.chars_per_second = 1.0

	npc.spoke.emit("冒烟测试台词")
	await get_tree().process_frame

	var panel := ui.get_node_or_null("Panel") as CanvasItem
	if panel == null or not panel.visible:
		_fail("发了 spoke 但对话框没显示出来")
		return
	if not GameShell.is_busy():
		_fail("对话框显示了，但 GameShell 没进入 busy —— 玩家还能一边说一边走")
		return

	# 真的按着方向键走几帧，确认走不动
	var before: Vector2 = player.global_position
	Input.action_press("move_right")
	for i in 8:
		await get_tree().physics_frame
	var drift := before.distance_to(player.global_position)
	Input.action_release("move_right")
	if drift > 1.0:
		_fail("说话期间玩家还挪了 %.1f 像素，没被冻住" % drift)
		return

	# 第一次按 E：台词还在打，应该先把整句补全，对话框继续开着
	await _press_interact()
	await get_tree().process_frame
	if not panel.visible:
		_fail("台词还没打完，按 E 就把对话框收了 —— 应该先把整句补全")
		return
	var text_node := ui.get_node_or_null("Panel/Margin/Text") as Label
	if text_node != null and text_node.visible_characters != text_node.text.length():
		_fail("按 E 没有把整句补全（%d/%d 字）"
			% [text_node.visible_characters, text_node.text.length()])

	# 第二次按 E 才收起对话框（不是干等 hold_seconds 走完）
	await _press_interact()
	await get_tree().process_frame
	if panel.visible:
		_fail("补全之后再按 E 没能收起对话框")
		return
	if GameShell.is_busy():
		_fail("对话框收了，GameShell 还是 busy —— 玩家会被永久卡住")
		return
	ui.chars_per_second = keep_cps

	Input.action_press("move_right")
	for i in 8:
		await get_tree().physics_frame
	var after := before.distance_to(player.global_position)
	Input.action_release("move_right")
	if after <= 1.0:
		_fail("对话框收起后玩家还是走不动，输入没恢复")
		return

	print("  对话链路正常：弹框、冻住玩家、按 E 收起、收起后恢复走动")


## 模拟按一次交互键。
## 注意不能用 Input.action_press —— 那只改动作状态，不会生成 InputEvent，
## 走不到 _unhandled_input，测不出按键逻辑。要用 parse_input_event。
func _press_interact() -> void:
	var ev := InputEventAction.new()
	ev.action = "interact"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = "interact"
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame


func _find_npc(node: Node) -> Node:
	if node is CharacterBody2D and node.get("waypoint_activity") != null:
		return node
	for child in node.get_children():
		var found := _find_npc(child)
		if found != null:
			return found
	return null


# ---------------------------------------------------------------- 交互链路

## 玩家 TalkArea → InteractiveComponent → 玩家按 E 分发。
##
## 这一段同时把「interact 键只归玩家」这条规矩钉住：对话开着的时候再按 E
## 只能把对话框收起来，不能再触发一次 NPC —— 那正是重构前 NPC 和对话框
## 抢同一次按键会出的毛病。
func _check_interaction(scene: Node) -> void:
	var fails_before := _fails.size()
	var player := get_tree().get_first_node_in_group("player") as VillagePlayer
	if player == null:
		_fail("找不到玩家，没法验证交互链路")
		return

	var talk := player.get_node_or_null("TalkArea") as Area2D
	if talk == null:
		_fail("玩家身上没有 TalkArea，走不进任何交互范围")
		return
	if talk.collision_mask != InteractiveComponent.LAYER_VALUE:
		_fail("玩家 TalkArea 的 collision_mask 是 %d，应该是 %d（第 4 层 Interactable）"
			% [talk.collision_mask, InteractiveComponent.LAYER_VALUE])
	if not talk.monitoring:
		_fail("玩家 TalkArea 的 monitoring 关着，什么都检测不到")

	var icon := player.get_node_or_null("TalkIcon") as CanvasItem
	if icon == null:
		_fail("玩家身上没有 TalkIcon 节点，玩家没法知道什么时候能交互")
	elif player.talk_target == null and icon.visible:
		_fail("玩家还没进任何交互范围，TalkIcon 就已经亮着了")

	var npc := _find_npc(scene) as VillageNpc
	if npc == null:
		_fail("找不到 VillageNpc")
		return
	var comp := npc.get_node_or_null("InteractiveComponent") as InteractiveComponent
	if comp == null:
		_fail("NPC 身上没有 InteractiveComponent —— 玩家按 E 不会有任何人应答")
		return
	if comp.collision_layer != InteractiveComponent.LAYER_VALUE or not comp.monitorable:
		_fail("NPC 的 InteractiveComponent 设置不对：collision_layer=%d，monitorable=%s"
			% [comp.collision_layer, comp.monitorable])
	var prompt := comp.get_node_or_null("Prompt") as CanvasItem

	# NPC 会自己走开，测的时候先让它站住
	npc.set("_dwell_left", 999.0)
	# 站到 NPC 下方 60 像素，并明确面朝 NPC（在上方）——
	# 不要沿用前面用例留下的朝向，否则「面朝上才够得着」这个前提是碰运气来的
	player.global_position = npc.global_position + Vector2(0, 60)
	player.velocity = Vector2.ZERO
	player.get("_anim").play("idle", CharacterSheet.DIR_UP)
	for i in 8:
		await get_tree().physics_frame

	if player.talk_target != comp:
		_fail("玩家站到 NPC 旁边，交互目标却不是 NPC 的组件（现在：%s）" % str(player.talk_target))
		return
	if prompt != null and not prompt.visible:
		_fail("玩家已经在交互范围内，NPC 头顶的按 E 提示没显示出来")
	if icon != null and not icon.visible:
		_fail("玩家进了可交互范围，头顶的 TalkIcon 没亮")

	await _check_talk_area_follows_facing(player, comp, talk, icon)

	_spoke_count = 0
	npc.spoke.connect(_count_spoke)

	# 打字速度压到 1 字/秒：保证按完 E 之后台词还在打，
	# 这样「第一次补全、第二次收起」是确定能测到的，不受机器快慢影响。
	var ui = _dialogue_ui()
	var keep_cps: float = ui.chars_per_second
	ui.chars_per_second = 1.0

	# 按 E：应该是 NPC 说话
	await _press_interact()
	await get_tree().process_frame
	if _spoke_count != 1:
		_fail("站在 NPC 旁边按 E，NPC 说了 %d 次（应该是 1 次）" % _spoke_count)
	if not _panel_visible():
		_fail("跟 NPC 交互后对话框没弹出来")
	elif not GameShell.is_busy():
		_fail("跟 NPC 交互后 GameShell 没进入 busy，玩家能一边听一边走")
	# 图标要等物理帧跑过一轮才同步说话状态
	await _settle_physics()
	if icon != null and icon.visible:
		_fail("对话框开着的时候 TalkIcon 还亮着（这时按 E 是收框，不是搭话）")

	# 第一次按 E：台词还在打，应该先补全，既不能收框也不能再触发 NPC
	await _press_interact()
	await get_tree().process_frame
	if _spoke_count != 1:
		_fail("台词还在打的时候按 E 又触发了 NPC（共 %d 次）—— interact 键没被玩家独占" % _spoke_count)
	if not _panel_visible():
		_fail("台词还没打完，按 E 就把对话框收了 —— 应该先把整句补全")
	var label_now := _dialogue_label()
	if label_now != null and label_now.visible_characters != label_now.text.length():
		_fail("按 E 没有把整句补全（%d/%d 字）"
			% [label_now.visible_characters, label_now.text.length()])

	# 第二次按 E：这次才收框
	await _press_interact()
	await get_tree().process_frame
	if _spoke_count != 1:
		_fail("对话框开着再按 E 又触发了 NPC（共 %d 次）—— interact 键没被玩家独占" % _spoke_count)
	if _panel_visible():
		_fail("补全之后再按 E 没能收起对话框")
	if GameShell.is_busy():
		_fail("对话收了，GameShell 还是 busy —— 玩家会被永久卡住")
	ui.chars_per_second = keep_cps
	await _settle_physics()
	if icon != null and not icon.visible:
		_fail("对话收起来之后玩家还在可交互范围里，TalkIcon 没亮回来")

	npc.spoke.disconnect(_count_spoke)

	# 走开：目标和提示都得撤掉
	var entry := get_tree().get_first_node_in_group("entry_point") as Node2D
	if entry != null:
		player.global_position = entry.global_position
	else:
		player.global_position = npc.global_position + Vector2(0, 400)
	for i in 8:
		await get_tree().physics_frame
	if player.talk_target != null:
		_fail("玩家走远之后交互目标还挂着：%s" % str(player.talk_target))
	if prompt != null and prompt.visible:
		_fail("玩家走远之后 NPC 头顶的按 E 提示还亮着")
	if icon != null and icon.visible:
		_fail("玩家走出可交互范围之后，头顶的 TalkIcon 还亮着")

	await _check_placeable_prop(scene, player)

	if _fails.size() == fails_before:
		print("  交互链路正常：TalkArea 认目标、按 E 触发、打字时先补全再收框、走开撤提示")


## 用法 B：参与者不写代码，只把 interactive_component.tscn 摆下去、在检查器里填属性。
func _check_placeable_prop(scene: Node, player: VillagePlayer) -> void:
	# 组件要摆在玩家当前的交互区里。交互区会跟着朝向挪，
	# 所以直接问碰撞体现在在哪，别自己按「玩家位置 ± 固定偏移」猜。
	var center := _talk_area_center(player)
	if center == Vector2.ZERO:
		_fail("拿不到玩家交互区的位置")
		return
	var prop := _spawn_prop(scene, center, "冒烟测试：这是一块告示牌。")
	if prop == null:
		_fail("load 不到或实例化不了 shared/interaction/interactive_component.tscn")
		return
	var prompt := prop.get_node_or_null("Prompt") as CanvasItem

	for i in 8:
		await get_tree().physics_frame
	if player.talk_target != prop:
		_fail("玩家站在告示牌上，交互目标却不是它（现在：%s）" % str(player.talk_target))
		prop.queue_free()
		return
	if prompt != null and not prompt.visible:
		_fail("告示牌在交互范围内，按 E 提示没显示出来")

	await _press_interact()
	await get_tree().process_frame
	var label := _dialogue_label()
	if not _panel_visible() or label == null:
		_fail("跟告示牌按 E 之后对话框没弹出来")
	elif label.text != prop.say_text:
		_fail("告示牌台词不对：对话框显示的是「%s」" % label.text)
	# 这里只是收场，不测按键路径，直接调 API 收干净
	await _dismiss_dialogue()

	# 范围内有两个时，按 E 要打到离玩家最近的那个
	var far := _spawn_prop(scene, center + Vector2(48, 0), "冒烟测试：远的那块。")
	if far != null:
		for i in 8:
			await get_tree().physics_frame
		# 先确认两块都真的进了范围，否则下面那条「取最近的」就是白测
		var inside: Array = player.get("_targets")
		if inside.size() != 2:
			_fail("范围里应该同时有 2 个可交互组件，实际 %d 个 —— 测试自己摆错了位置"
				% inside.size())
		elif player.talk_target != prop:
			_fail("范围内有两块告示牌时，交互目标不是最近的那块（现在：%s）" % str(player.talk_target))
		far.queue_free()
		for i in 4:
			await get_tree().physics_frame

	# say() 是给参与者用的公共口子，说话人前缀也要对
	GameShell.say("正文", "告示牌")
	await get_tree().process_frame
	if label != null and label.text != "告示牌：正文":
		_fail("GameShell.say 的说话人前缀不对：「%s」" % label.text)
	await _dismiss_dialogue()

	# 组件中途被释放，玩家身上不能留渣
	prop.queue_free()
	for i in 4:
		await get_tree().physics_frame
	if player.talk_target != null:
		_fail("告示牌被删掉之后玩家身上还挂着交互目标：%s" % str(player.talk_target))

	await _check_action_branches(scene, player)
	await _check_typewriter()


func _spawn_prop(scene: Node, at: Vector2, text: String) -> InteractiveComponent:
	var packed := load("res://shared/interaction/interactive_component.tscn") as PackedScene
	if packed == null:
		return null
	var prop := packed.instantiate() as InteractiveComponent
	if prop == null:
		return null
	prop.action = InteractiveComponent.Action.SAY
	prop.say_text = text
	prop.prompt_text = "按 E 查看"
	scene.add_child(prop)
	prop.global_position = at
	return prop


## 其余几种 Action 别炸：没填目标场景只该警告，EMIT 该把信号发出去。
func _check_action_branches(scene: Node, player: VillagePlayer) -> void:
	var bare := InteractiveComponent.new()
	scene.add_child(bare)

	var fired := [false]
	bare.interacted.connect(func(_p): fired[0] = true)

	bare.action = InteractiveComponent.Action.CHANGE_SCENE
	bare.player_interact(player)          # 没填 Target Scene → 只警告，不该切场景

	bare.action = InteractiveComponent.Action.EMIT
	bare.player_interact(player)
	if not fired[0]:
		_fail("Action = EMIT 时 interacted 信号没有发出来")

	bare.action = InteractiveComponent.Action.FORWARD
	bare.player_interact(player)          # 没有 agent、父节点也没有方法 → 只警告

	if get_tree().current_scene == null or not is_instance_valid(get_tree().current_scene):
		_fail("交互组件把当前场景弄没了")

	bare.queue_free()
	await get_tree().physics_frame


## 交互检测区要跟着朝向走：面朝 NPC 时够得着，背对着就该够不着。
##
## 玩家被摆在 NPC 下方 60 像素，正好卡在「转个身就出范围」的位置：
## 交互区 64 高、NPC 的组件 96 高，面朝上时重叠 52 像素，面朝下时差 12 像素够不到。
func _check_talk_area_follows_facing(player: VillagePlayer, comp: InteractiveComponent,
		talk: Area2D, icon: CanvasItem) -> void:
	var shape := talk.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape == null:
		_fail("玩家 TalkArea 下面没有 CollisionShape2D，没法跟朝向走")
		return
	var anim = player.get("_anim")
	if anim == null:
		_fail("拿不到玩家的动画播放器，没法测转向")
		return
	# 中立位置、伸出距离、两个下移量都从玩家身上读，免得测试自己另写一套符号约定
	var base: Vector2 = player.get("_talk_base")
	var reach: float = player.talk_reach
	var side_drop: float = player.talk_side_drop
	var down_drop: float = player.talk_down_drop

	# 背对 NPC（玩家在 NPC 下方，朝下 = 背对）
	anim.play("idle", CharacterSheet.DIR_DOWN)
	await _wait_physics(4)
	var want_down := base + Vector2(0, reach + down_drop)
	if not shape.position.is_equal_approx(want_down):
		_fail("玩家朝下时交互区位置不对：%s，应该是 %s" % [shape.position, want_down])
	if down_drop > 0.0 and shape.position.y <= base.y + reach:
		_fail("Talk Down Drop 填的是正数，交互区没有继续往下（y=%.1f，只算 Reach 应该是 y=%.1f）"
			% [shape.position.y, base.y + reach])
	if player.talk_target != null:
		_fail("玩家背对着 NPC，却还把 NPC 当成交互目标 —— 交互区没跟朝向走")
	if icon != null and icon.visible:
		_fail("玩家背对 NPC 时头顶 TalkIcon 还亮着")

	# 转回面朝 NPC（玩家在下方，朝上 = 面向 NPC）
	anim.play("idle", CharacterSheet.DIR_UP)
	await _wait_physics(4)
	var want_up := base + Vector2(0, -reach)
	if not shape.position.is_equal_approx(want_up):
		_fail("玩家朝上时交互区位置不对：%s，应该是 %s" % [shape.position, want_up])
	if player.talk_target != comp:
		_fail("玩家转回面向 NPC 之后，交互目标没回来（现在：%s）" % str(player.talk_target))
	if icon != null and not icon.visible:
		_fail("玩家转回面向 NPC 之后，头顶 TalkIcon 没亮回来")

	# 左右也要跟着挪，而且填了正数就必须是往下（正数=往下，见 player.gd 的注释）
	anim.play("idle", CharacterSheet.DIR_RIGHT)
	await _wait_physics(4)
	var want_right := base + Vector2(reach, side_drop)
	if not shape.position.is_equal_approx(want_right):
		_fail("玩家朝右时交互区位置不对：%s，应该是 %s" % [shape.position, want_right])
	if side_drop > 0.0 and shape.position.y <= base.y:
		_fail("Talk Side Drop 填的是正数，交互区却往上挪了（y=%.1f，中立位置 y=%.1f）"
			% [shape.position.y, base.y])
	anim.play("idle", CharacterSheet.DIR_LEFT)
	await _wait_physics(4)
	var want_left := base + Vector2(-reach, side_drop)
	if not shape.position.is_equal_approx(want_left):
		_fail("玩家朝左时交互区位置不对：%s，应该是 %s" % [shape.position, want_left])
	if side_drop > 0.0 and shape.position.y <= base.y:
		_fail("Talk Side Drop 填的是正数，交互区却往上挪了（y=%.1f，中立位置 y=%.1f）"
			% [shape.position.y, base.y])
	# 最后转回面朝 NPC，后面接着测按键
	anim.play("idle", CharacterSheet.DIR_UP)
	await _wait_physics(4)


## 等 n 个物理帧。挪碰撞体之后重叠是下一个物理帧才重算的，等少了会读到旧状态。
func _wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## 玩家当前交互检测区（碰撞体）的中心，世界坐标。
func _talk_area_center(player: VillagePlayer) -> Vector2:
	var shape := player.get_node_or_null("TalkArea/CollisionShape2D") as CollisionShape2D
	return shape.global_position if shape != null else Vector2.ZERO


func _count_spoke(_text: String) -> void:
	_spoke_count += 1


## 等物理帧真正跑过一轮。
## 注意不能只 await 一次 physics_frame：那个信号是在该帧的 _physics_process
## 之前发出来的，只等一次的话节点这一帧还没动过，会读到上一帧的状态。
func _settle_physics() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


## 收场用：直接把对话框收掉。
## 这里不走按键 —— 打字机开着的时候按一次 E 只是补全，要按两次才收，
## 而且第二次还有可能顺手触发一次交互，测别的用例时不想引入这些变量。
func _dismiss_dialogue() -> void:
	GameShell.close_dialogue()
	await get_tree().process_frame


## 打字机效果：刚弹出来不能整句都在，字要一个个冒出来，速度跟 Chars Per Second 对得上；
## 而且停留计时必须等整句打完才开始，否则长台词会被提前收走。
##
## 速度不写死在断言里：测试自己先把速度设成已知值再量，
## 这样以后调 dialogue_ui.tscn 上的默认速度，不用回来改测试。
func _check_typewriter() -> void:
	var ui = _dialogue_ui()
	if ui == null:
		return
	var timer := ui.get_node_or_null("Timer") as Timer
	var keep: float = ui.chars_per_second

	# 台词要够长：下面按 5 字/秒量 2 秒（约 10 个字），句子太短会先打完
	ui.chars_per_second = 5.0
	GameShell.say("打字机速度测试，这句话故意写长一点，才好量出每秒冒几个字。")
	await get_tree().process_frame

	var label := _dialogue_label()
	if label == null or not _panel_visible():
		_fail("打字机测试：对话框没弹出来")
		ui.chars_per_second = keep
		return
	var total := label.text.length()

	if label.visible_characters >= total:
		_fail("对话框刚弹出来就整句显示了 —— 打字机效果没生效")
	if timer != null and not timer.is_stopped():
		_fail("台词还没打完，停留计时就已经在跑 —— 长台词会被提前收走")

	# 5 字/秒 × 2 秒 ≈ 10 个字
	await get_tree().create_timer(2.0).timeout
	var shown: int = label.visible_characters
	if shown <= 0:
		_fail("等了 2 秒，对话框一个字都没冒出来")
	elif shown >= total:
		_fail("2 秒就把整句（%d 个字）打完了，比每秒 5 个快得多" % total)
	elif shown < 6 or shown > 14:
		_fail("按每秒 5 个字算，2 秒该冒出 10 个左右，实际冒出 %d 个" % shown)

	# 调快速度：确认打得完，而且打完才开始数停留时间
	ui.chars_per_second = 2000.0
	await get_tree().create_timer(0.2).timeout
	if label.visible_characters != total:
		_fail("打字机没有把整句打完（%d/%d 字）" % [label.visible_characters, total])
	if not ui.is_open():
		_fail("台词还没打完，对话框就自己收了")
	if timer != null and timer.is_stopped():
		_fail("整句打完之后没有开始数停留时间，对话框永远不会自己收")

	# 收掉，别影响后面的用例
	await _press_interact()
	await get_tree().process_frame
	ui.chars_per_second = keep


func _dialogue_ui():
	return GameShell.get("_ui")


func _dialogue_label() -> Label:
	var ui = _dialogue_ui()
	if ui == null:
		return null
	return ui.get_node_or_null("Panel/Margin/Text") as Label


func _panel_visible() -> bool:
	var ui = _dialogue_ui()
	if ui == null:
		return false
	var panel := ui.get_node_or_null("Panel") as CanvasItem
	return panel != null and panel.visible


func _fail(msg: String) -> void:
	_fails.append(msg)
	print("  [失败] " + msg)


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("冒烟测试通过。")
		get_tree().quit(0)
	else:
		print("冒烟测试失败，共 %d 项：" % _fails.size())
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)

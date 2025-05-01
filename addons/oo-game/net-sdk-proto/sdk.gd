class_name IoGame
extends Node

const Proto = preload("./proto.gd")

class TitleDictionary:
	var dictionary: Dictionary[int, String] = {}
	var _mutex: Mutex = Mutex.new()

	func add(key: int, value: String) -> void:
		_mutex.lock()
		dictionary[key] = safe_value(value)
		_mutex.unlock()


	func get_value(key: int) -> String:
		_mutex.lock()
		var value = dictionary.get(key)
		_mutex.unlock()
		return safe_value(value)


	func safe_value(value: Variant) -> String:
		return "..." if value == null else str(value)

class CmdKit:
	const CMD_MASK: int = 0xFFFF
	const CMD_SHIFT: int = 16
	
	static var request_dictionary: TitleDictionary = TitleDictionary.new()
	static var broadcast_dictionary: TitleDictionary = TitleDictionary.new()
	static var error_code_dictionary: TitleDictionary = TitleDictionary.new()

	static func get_cmd(cmd_merge: int) -> int:
		return cmd_merge >> CMD_SHIFT


	static func get_sub_cmd(cmd_merge: int) -> int:
		return cmd_merge & CMD_MASK


	static func merge(cmd: int, sub_cmd: int) -> int:
		return (cmd << CMD_SHIFT) | sub_cmd


	static func to_string_merge(cmd_merge: int) -> String:
		var cmd = get_cmd(cmd_merge)
		var sub_cmd = get_sub_cmd(cmd_merge)
		return "cmd: %s - %s" % [cmd, sub_cmd]


	static func mapping_request(cmd_merge: int, title: String) -> int:
		request_dictionary.add(cmd_merge, title)
		return cmd_merge


	static func mapping_broadcast(cmd_merge: int, title: String) -> int:
		broadcast_dictionary.add(cmd_merge, title)
		return cmd_merge


	static func mapping_error_code(error_code: int, title: String) -> int:
		error_code_dictionary.add(error_code, title)
		return error_code


	static func get_request_title(cmd_merge: int) -> String:
		return request_dictionary.get_value(cmd_merge)


	static func get_broadcast_title(cmd_merge: int) -> String:
		return broadcast_dictionary.get_value(cmd_merge)


	static func get_error_code_title(error_code: int) -> String:
		return error_code_dictionary.get_value(error_code)


class WrapKit:
	static func to_byte_value_list(data: Array) -> IoGame.Proto.ByteValueList:
		var value_list := IoGame.Proto.ByteValueList.new()
		
		if data and not data.is_empty():
			for _value in data:
				if _value != null && _value.has_method("to_bytes"):
					var _data = _value.to_bytes()
					value_list.add_values(_data)
		
		return value_list


class Stopwatch:
	var _start_milliseconds: int
	var elapsed_milliseconds: int = 0

	func _init() -> void:
		_start_milliseconds = Time.get_ticks_msec()
		pass


	func stop():
		if elapsed_milliseconds != 0:
			return
		
		elapsed_milliseconds = Time.get_ticks_msec() - _start_milliseconds


	static func start_new() -> Stopwatch:
		return Stopwatch.new()


class ExternalMessageCmdCode:
	## message idle. cn: 心跳
	const idle := 0
	## message biz. cn: 业务
	const biz := 1

class ExternalMessageKit:
	static func of(request_command: RequestCommand) -> IoGame.Proto.ExternalMessage:
		var message = IoGame.Proto.ExternalMessage.new()
		message.set_cmd_code(ExternalMessageCmdCode.biz)
		message.set_cmd_merge(request_command.cmd_merge)
		message.set_msg_id(request_command.msg_id)
		message.set_data(request_command.data)
		
		return message

class CommandManager:
	static var callback_dictionary: Dictionary[int, RequestCommand] = {}
	static var listen_dictionary: Dictionary[int, ListenCommand] = {}

	static func write_and_flush(request_command: RequestCommand) -> void:
		var msg_id := request_command.msg_id
		var message := ExternalMessageKit.of(request_command)
		IoGameSetting.net_channel.write_and_flush(message)
		callback_dictionary.set(msg_id, request_command)
		
		if IoGameSetting.request_command_timeout != 0:
			Engine.get_main_loop().create_timer(IoGameSetting.request_command_timeout).timeout.connect(
				func(): callback_dictionary.erase(msg_id), 
				CONNECT_ONE_SHOT
			)
		
		if IoGameSetting.enable_dev_mode:
			request_command.stopwatch = Stopwatch.new()


	static func accept_message(message: IoGame.Proto.ExternalMessage) -> void:
		var listen_message_callback := IoGameSetting.listen_message_callback
		if message.get_cmd_code() == ExternalMessageCmdCode.idle:
			if message.get_response_status() != 0:
				listen_message_callback.on_error_callback(message)
			else:
				listen_message_callback.on_idle_callback(message)
			return
		
		# request callback
		var msg_id := message.get_msg_id()
		# callback_dictionary
		if callback_dictionary.has(msg_id):
			var request_command := callback_dictionary[msg_id]
			callback_dictionary.erase(msg_id)
			process_request_command(request_command, message, listen_message_callback)
			return
		
		# broadcast callback
		var cmd_merge := message.get_cmd_merge()
		if listen_dictionary.has(cmd_merge):
			var listen_command := listen_dictionary[cmd_merge]
			listen_message_callback.on_listen_callback(message, listen_command)
			return
			
		# other message callback
		listen_message_callback.on_other_callback(message)


	static func process_request_command(
		request_command: RequestCommand
		, message: Proto.ExternalMessage
		, listen_message_callback: ListenMessageCallback):
		
		# ofAwait
		if request_command.wakeup(message):
			return
		
		# error code callback
		if message.get_response_status() != 0:
			listen_message_callback.on_error_callback(message, request_command)
			return
			
		# request callback
		listen_message_callback.on_request_callback(message, request_command)


class ListenCommand:
	var cmd_merge: int
	var callback: Callable

	func _init(cmd_merge: int, callback: Callable) -> void:
		self.cmd_merge = cmd_merge
		self.callback = callback
		CommandManager.listen_dictionary[cmd_merge] = self


	static func of(cmd_merge: int, callback: Callable) -> ListenCommand:
		return ListenCommand.new(cmd_merge, callback)


class ListenMessageCallback:
	func on_error_callback(message: Proto.ExternalMessage, request_command: RequestCommand = null):
		var error_callback: Callable = request_command.error_callback
		if error_callback.is_valid():
			var result := ResponseResult.of(message, request_command)
			error_callback.call(result)
			return
		
		var error_code := message.get_response_status()
		var error_message := message.get_valid_msg()
		if error_message == null or error_message.is_empty():
			error_message = CmdKit.get_error_code_title(error_code)
		
		var merge_title := CmdKit.to_string_merge(message.get_cmd_merge())
		var error_tpl := "[error_code: {error_code}] - [error_message: {error_message}] - [{merge_title}] - [{cmd_code}]".format({
			"error_code": error_code,
			"error_message": error_message,
			"merge_title": merge_title,
			"cmd_code": message.get_cmd_code(),
		})
		
		print(error_tpl)


	func on_idle_callback(message: Proto.ExternalMessage):
		pass


	func on_request_callback(message: Proto.ExternalMessage, request_command: RequestCommand):
		var result := ResponseResult.of(message, request_command)
		request_command.accept_message(result)


	func on_listen_callback(message: Proto.ExternalMessage, listen_command: ListenCommand):
		var result := ResponseResult.of(message)
		result.listen_command = listen_command
		listen_command.callback.call(result)


	func on_other_callback(message: Proto.ExternalMessage) -> void:
		var merge_title := CmdKit.to_string_merge(message.get_cmd_merge())
		var other_callback_name := IoGameSetting.locale.other_callback_name
		var tpl := "{other_callback_name} {merge_title} {message}".format({
			"other_callback_name": other_callback_name,
			"merge_title": merge_title,
			"message": message
		})
		
		print(tpl)


enum RequestExecuteType {
	None,
	Execute,
	ExecuteAwait,
}


class TaskCompletion extends RefCounted:
	signal completed(result: ResponseResult)
	## save result
	var result: ResponseResult
	## time out flag
	var timed_out: bool = false
	var msg_id: int
	var cmd_merge: int

	func set_result(_result: ResponseResult) -> void:
		if not is_queued_for_deletion():
			self.result = _result
			emit_signal("completed", result)


	func do_timeout() -> void:
		if not is_queued_for_deletion() and self.result == null:
			timed_out = true
			
			var _message := Proto.ExternalMessage.new()
			_message.set_msg_id(msg_id)
			_message.set_cmd_merge(cmd_merge)
			_message.set_response_status(-1)
			_message.set_valid_msg("request timeout")
			
			self.result = ResponseResult.of(_message)
			emit_signal("completed", result)


class RequestCommand:
	var msg_id: int
	var cmd_merge: int
	var data_source
	var data: PackedByteArray
	var callback: Callable
	var error_callback: Callable
	var request_execute_type: RequestExecuteType
	signal operation_completed(result: ResponseResult)
	var resolve: TaskCompletion
	var stopwatch: Stopwatch

	func get_data() -> PackedByteArray:
		return data


	func get_data_source() -> Object:
		return data_source


	func on_error(error_callback: Callable) -> RequestCommand:
		self.error_callback = error_callback
		return self


	func on_callback(callback: Callable) -> RequestCommand:
		self.callback = callback
		return self


	func execute() -> RequestCommand:
		if self.request_execute_type != RequestExecuteType.None:
			return self
		
		self.request_execute_type = RequestExecuteType.Execute
		CommandManager.write_and_flush(self)
		return self


	func accept_message(result: ResponseResult) -> void:
		if request_execute_type == RequestExecuteType.Execute:
			callback.call(result)


	func wakeup(message: Proto.ExternalMessage) -> bool:
		if request_execute_type != RequestExecuteType.ExecuteAwait:
			return false
		
		var result := ResponseResult.of(message, self)
		self.resolve.set_result(result)
		
		return true


	func count_time_consumer() -> int:
		if stopwatch == null:
			return 0
		
		stopwatch.stop()
		return stopwatch.elapsed_milliseconds

	static func of_empty(cmd_merge: int) -> RequestCommand:
		var request := RequestCommand.new()
		request.msg_id = IoGameSetting.increment_msg_id()
		request.cmd_merge = cmd_merge
		
		return request


	static func of(cmd_merge: int, data_bytes: PackedByteArray) -> RequestCommand:
		var request := RequestCommand.new()
		request.msg_id = IoGameSetting.increment_msg_id()
		request.cmd_merge = cmd_merge
		request.data = data_bytes
		
		return request


	static func of_int(cmd_merge: int, data: int) -> RequestCommand:
		var message := IoGame.Proto.IntValue.new()
		message.set_value(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_int_list(cmd_merge: int, data: Array[int]) -> RequestCommand:
		var message := IoGame.Proto.IntValueList.new()
		message.get_values().assign(data)
		return of(cmd_merge, message.to_bytes())


	static func of_long(cmd_merge: int, data: int) -> RequestCommand:
		var message := IoGame.Proto.LongValue.new()
		message.set_value(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_long_list(cmd_merge: int, data: Array[int]) -> RequestCommand:
		var message := IoGame.Proto.LongValueList.new()
		message.get_values().assign(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_bool(cmd_merge: int, data: bool) -> RequestCommand:
		var message := IoGame.Proto.BoolValue.new()
		message.set_value(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_bool_list(cmd_merge: int, data: Array[bool]) -> RequestCommand:
		var message := IoGame.Proto.BoolValueList.new()
		message.get_values().assign(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_string(cmd_merge: int, data: String) -> RequestCommand:
		var message := IoGame.Proto.StringValue.new()
		message.set_value(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_string_list(cmd_merge: int, data: Array[String]) -> RequestCommand:
		var message := IoGame.Proto.StringValueList.new()
		message.get_values().assign(data)
		
		var request := of(cmd_merge, message.to_bytes())
		request.data_source = message
		return request


	static func of_await_request_command(request_command: RequestCommand) -> ResponseResult:
		request_command.request_execute_type = RequestExecuteType.ExecuteAwait
		request_command.resolve = TaskCompletion.new()
		request_command.resolve.msg_id = request_command.msg_id
		request_command.resolve.cmd_merge = request_command.cmd_merge
		
		CommandManager.write_and_flush(request_command)
		return await request_command.resolve.completed


	static func of_await_int(cmd_merge: int, data: int) -> ResponseResult:
		var request := of_int(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_int_list(cmd_merge: int, data: Array[int]) -> ResponseResult:
		var request := of_int_list(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_long(cmd_merge: int, data: int) -> ResponseResult:
		var request := of_long(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_long_list(cmd_merge: int, data: Array[int]) -> ResponseResult:
		var request := of_long_list(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_bool(cmd_merge: int, data: bool) -> ResponseResult:
		var request := of_bool(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_bool_list(cmd_merge: int, data: Array[bool]) -> ResponseResult:
		var request := of_bool_list(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_string(cmd_merge: int, data: String) -> ResponseResult:
		var request := of_string(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_string_list(cmd_merge: int, data: Array[String]) -> ResponseResult:
		var request := of_string_list(cmd_merge, data)
		return await RequestCommand.of_await_request_command(request)


	static func of_await_empty(cmd_merge: int) -> ResponseResult:
		var request := of_empty(cmd_merge)
		return await RequestCommand.of_await_request_command(request)


class ResponseResult:
	var _data
	var message: IoGame.Proto.ExternalMessage
	var request_command: RequestCommand
	var listen_command: ListenCommand
	
	func _init(message: IoGame.Proto.ExternalMessage):
		self.message = message
	

	func get_cmd_merge() -> int:
		return message.get_cmd_merge()


	func get_msg_id() -> int:
		return message.get_msg_id()


	func get_response_status() -> int:
		return message.get_response_status()


	func has_error() -> bool:
		return message.get_response_status() != 0


	func success() -> bool:
		return message.get_response_status() == 0


	func get_valid_msg() -> String:
		var valid_msg := message.get_valid_msg()
		
		if valid_msg:
			return valid_msg
		
		return CmdKit.get_error_code_title(self.get_response_status())


	func get_error_info() -> String:
		var error_code := self.get_response_status()
		var error_message := self.get_valid_msg()
		
		return "[errorCode: {error_code}, errorMessage: {error_message}]".format({
			"error_code": error_code,
			"error_message": error_message
		})


	func get_value(value_type: Object) -> Object:
		var obj: Object = value_type.new()
		
		if obj.has_method("from_bytes"):
			obj.from_bytes(message.get_data())
		
		return obj


	func list_value(value_type: Object) -> Array:
		var byte_value_list := Proto.ByteValueList.new()
		byte_value_list.from_bytes(message.get_data())
		
		var _array: Array = []
		
		for _byte_value in byte_value_list.get_values():
			var obj: Object = value_type.new()
			if obj.has_method("from_bytes"):
				obj.from_bytes(_byte_value)
			
			_array.append(obj)
		
		return _array


	func get_int() -> int:
		var value := get_value(IoGame.Proto.IntValue) as IoGame.Proto.IntValue
		return value.get_value()


	func list_int() -> Array[int]:
		var value := get_value(IoGame.Proto.IntValueList) as IoGame.Proto.IntValueList
		return value.get_values()


	func get_long() -> int:
		var value := get_value(IoGame.Proto.LongValue) as IoGame.Proto.LongValue
		return value.get_value()


	func list_long() -> Array[int]:
		var value := get_value(IoGame.Proto.LongValueList) as IoGame.Proto.LongValueList
		return value.get_values()


	func get_bool() -> bool:
		var value := get_value(IoGame.Proto.BoolValue) as IoGame.Proto.BoolValue
		return value.get_value()


	func list_bool() -> Array[bool]:
		var value := get_value(IoGame.Proto.BoolValueList) as IoGame.Proto.BoolValueList
		return value.get_values()


	func get_string() -> String:
		var value := get_value(IoGame.Proto.StringValue) as IoGame.Proto.StringValue
		return value.get_value()


	func list_string() -> Array[String]:
		var value := get_value(IoGame.Proto.StringValueList) as IoGame.Proto.StringValueList
		return value.get_values()


	func log(data):
		if request_command:
			Print.log_res2(self, data)
		elif listen_command:
			Print.log_broadcast(listen_command, data)


	static func of(message: Proto.ExternalMessage, request_command: RequestCommand = null) -> ResponseResult:
		var response_result := ResponseResult.new(message)
		response_result.request_command = request_command
		return response_result

class IoGameLocale:
	var request_name: String = "请求"
	var request_callback_name: String = "请求回调"
	var broadcast_name: String = "广播监听回调"
	var time_name: String = "耗时"
	var other_callback_name: String = "其他回调"
	var idle_callback_name: String = "心跳回调"


enum IoGameLanguage {
	China,
	Us,
}


class GameConsole:
	func log(value) -> void:
		print(value)


class NetChannel:
	## Initializes network resources before communication.
	func prepare() -> void:
		assert(false, "Subclasses must implement this method!")


	## Sends a protocol message and immediately flushes the buffer.
	## @param message: The message to send (IoGame.Proto.ExternalMessage)
	func write_and_flush(message: IoGame.Proto.ExternalMessage) -> void:
		var bytes := message.to_bytes()
		write_and_flush_byte(bytes)


	## Sends raw bytes and flushes the buffer.
	## @param bytes: The packed byte array to send
	func write_and_flush_byte(bytes: PackedByteArray) -> void:
		assert(false, "Subclasses must implement this method!")


	## Processes an incoming network message.
	## @param message: Received message (IoGame.Proto.ExternalMessage)
	func accept_message(message: IoGame.Proto.ExternalMessage) -> void:
		assert(false, "Subclasses must implement this method!")


class SimpleNetChannel extends NetChannel:
	func accept_message(message: IoGame.Proto.ExternalMessage) -> void:
		CommandManager.accept_message(message)


class IoGameSetting:
	## Message tag set by the client during request, 
	## will be included in server response (passed through transparently)
	static var msg_id_seq: int = 1
	static var _counter_mutex := Mutex.new()
	static var locale := IoGameLocale.new()
	static var game_console := GameConsole.new()
	static var net_channel: NetChannel = SimpleNetChannel.new()
	static var listen_message_callback: ListenMessageCallback = ListenMessageCallback.new()
	## second
	static var request_command_timeout: int = 3
	static var url: String = "ws://127.0.0.1:10100/websocket"
	static var enable_dev_mode: bool = false

	static func start_net() -> void:
		net_channel.prepare()

	static func set_language(language: IoGameLanguage) -> void:
		if language == IoGameLanguage.China:
			return
		
		IoGameSetting.locale = IoGameLocale.new()
		var _local = IoGameSetting.locale
		_local.request_name = "Request"
		_local.request_callback_name = "RequestCallback"
		_local.broadcast_name = "BroadcastCallback"
		_local.time_name = "Time"
		_local.other_callback_name = "OtherCallback"
		_local.idle_callback_name = "IdleCallback"

	static func increment_msg_id() -> int:
		_counter_mutex.lock()
		var current_value := msg_id_seq
		msg_id_seq += 1
		_counter_mutex.unlock()
		return current_value


	static func reset_msg_id() -> void:
		_counter_mutex.lock()
		msg_id_seq = 0
		_counter_mutex.unlock()


class Print:
	static func log_req(request_command: RequestCommand) -> void:
		var cmd_merge := request_command.cmd_merge
		var request_title := CmdKit.get_request_title(cmd_merge)
		var merge_title := CmdKit.to_string_merge(cmd_merge)
		var msg_id = request_command.msg_id
		var request_name := IoGameSetting.locale.request_name
		var request_execute_type := request_command.request_execute_type
		var request_execute_type_name: String = RequestExecuteType.keys()[request_execute_type]
		var data_source = request_command.data_source
		var _format = "[msg_id:{msg_id}][{request_execute_type_name}][{request_name}: {request_title}][{merge_title}] [{data_source}]".format({
				"msg_id": msg_id,
				"request_execute_type_name": request_execute_type_name,
				"request_name": request_name,
				"request_title": request_title,
				"merge_title": merge_title,
				"data_source": data_source
		})
		
		IoGameSetting.game_console.log(_format)


	static func log_res(result: ResponseResult) -> void:
		var message := result.message
		log_res2(result, message)


	static func log_res2(result: ResponseResult, data) -> void:
		if IoGameSetting.enable_dev_mode:
			var request_command := result.request_command
			if request_command == null:
				return
			
			var request_callback_name := IoGameSetting.locale.request_callback_name
			var time_name := IoGameSetting.locale.time_name
			var message := result.message
			var msg_id = message.get_msg_id()
			var cmd_merge = message.get_cmd_merge()
			var request_title := CmdKit.get_request_title(cmd_merge)
			var merge_title := CmdKit.to_string_merge(cmd_merge)
			var request_execute_type := request_command.request_execute_type
			var request_execute_type_name: String = RequestExecuteType.keys()[request_execute_type]
			var time_consumer := request_command.count_time_consumer()
			var _format := "[msg_id:{msg_id}][{request_execute_type_name}][{request_callback_name}: {request_title}][{merge_title}][{time_name} {time_consumer} ms] {data}".format({
					"msg_id": msg_id,
					"request_execute_type_name": request_execute_type_name,
					"request_callback_name": request_callback_name,
					"request_title": request_title,
					"merge_title": merge_title,
					"time_name": time_name,
					"time_consumer": time_consumer,
					"data": data
			})
			
			IoGameSetting.game_console.log(_format)
		else :
			IoGameSetting.game_console.log(data)

	static func log_broadcast(listen_command: ListenCommand, data) -> void:
		var cmd_merge := listen_command.cmd_merge
		var merge_title := CmdKit.to_string_merge(cmd_merge)
		var broadcast_name := IoGameSetting.locale.broadcast_name
		var broadcast_title := CmdKit.get_broadcast_title(cmd_merge)
		
		var _format := "[{broadcast_name}] [{broadcast_title}] [{merge_title}] {data}".format({
			"broadcast_name": broadcast_name,
			"broadcast_title": broadcast_title,
			"merge_title": merge_title,
			"data": data
		})
		
		IoGameSetting.game_console.log(_format)

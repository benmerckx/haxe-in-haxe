package core;

import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Mutex;

// Port of haxe/src/core/socket.ml.
class Socket {
	final host:String;
	final port:Int;
	var socket:Null<SysSocket>;
	final sendMutex:Mutex = new Mutex();

	public function new(host:String, port:Int) {
		this.host = host;
		this.port = port;
		var socket = new SysSocket();
		socket.connect(new Host(host), port);
		this.socket = socket;
	}

	public static function create(host:String, port:Int):Socket {
		return new Socket(host, port);
	}

	public function readString():String {
		var socket = getSocket();
		var header = socket.input.read(2);
		var length = readUi16(header, 0);
		return socket.input.read(length).toString();
	}

	public static function readByte(bytes:Bytes, index:Int):Int {
		return bytes.get(index);
	}

	public static function readUi16(bytes:Bytes, index:Int):Int {
		return readByte(bytes, index) | (readByte(bytes, index + 1) << 8);
	}

	public static function writeByte(bytes:Bytes, index:Int, value:Int):Void {
		bytes.set(index, value & 0xFF);
	}

	public static function writeI32(bytes:Bytes, index:Int, value:Int):Void {
		writeByte(bytes, index, value);
		writeByte(bytes, index + 1, value >>> 8);
		writeByte(bytes, index + 2, value >>> 16);
		writeByte(bytes, index + 3, value >>> 24);
	}

	public function sendString(value:String):Void {
		sendMutex.acquire();
		try {
			var socket = getSocket();
			var bytes = Bytes.ofString(value);
			var length = bytes.length;
			var header = Bytes.alloc(4);
			writeI32(header, 0, length);
			socket.output.write(header);
			var remaining = length;
			var offset = 0;
			while (remaining > 0) {
				var chunkLength = remaining < 0xFFFF ? remaining : 0xFFFF;
				socket.output.writeBytes(bytes, offset, chunkLength);
				remaining -= chunkLength;
				offset += chunkLength;
			}
		} catch (error:haxe.Exception) {
			sendMutex.release();
			throw error;
		}
		sendMutex.release();
	}

	function getSocket():SysSocket {
		if (socket == null) throw "no socket";
		return socket;
	}
}

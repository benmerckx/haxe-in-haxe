package compiler.io;

import haxe.io.Input;
import haxe.io.Output;

// haxe/src/compiler/io/compilerIo.ml — mechanical draft; not compile-validated.
// Output pipes use host thread/deque primitives.
typedef CompilerIoData = {
	var stdout:Output;
	var stderr:Output;
	var stdin:Input;
	var getch:Bool->Int;
	var writeOut:String->Void;
	var writeErr:String->Void;
	var writeResult:String->Void;
	var signalError:Void->Void;
	var flush:Void->Void;
	var close:Void->Void;
}

class CompilerIo {
	// Haxe Output replaces the Unix descriptor; a deque retains the asynchronous
	// reader and close/join ordering without an OS pipe dependency.
	public static function makeOutputPipe(writeFn:String->Void):{output:Output, thread:PipeOutput} {
		var output = new PipeOutput(writeFn);
		return {output: output, thread: output};
	}

	public static function getchFromChannel(input:Input, output:Output, echo:Bool):Int {
		var c = try input.readByte() catch (_:haxe.io.Eof) -1;
		if (echo && c >= 0) {
			output.writeByte(c);
			output.flush();
		}
		return c;
	}

	public static function writeOut(io:CompilerIoData, s:String):Void io.writeOut(s);

	public static function writeErr(io:CompilerIoData, s:String):Void io.writeErr(s);

	public static function writeResult(io:CompilerIoData, s:String):Void io.writeResult(s);

	public static function signalError(io:CompilerIoData):Void io.signalError();

	public static function getStdout(io:CompilerIoData):Output return io.stdout;

	public static function getStderr(io:CompilerIoData):Output return io.stderr;

	public static function getStdin(io:CompilerIoData):Input return io.stdin;

	public static function getch(io:CompilerIoData, echo:Bool):Int return io.getch(echo);

	public static function flush(io:CompilerIoData):Void io.flush();

	public static function close(io:CompilerIoData):Void io.close();

	public static function create(writeOut:String->Void, writeErr:String->Void, writeResult:String->Void, signalError:Void->Void,
			stdin:Input):CompilerIoData {
		var out = makeOutputPipe(writeOut), err = makeOutputPipe(writeErr), closed = false;
		return {
			stdout: out.output,
			stderr: err.output,
			stdin: stdin,
			getch: function(echo) return getchFromChannel(stdin, out.output, echo),
			writeOut: writeOut,
			writeErr: writeErr,
			writeResult: writeResult,
			signalError: signalError,
			flush: function() {
				out.output.flush();
				err.output.flush();
			},
			close: function() {
				if (!closed) {
					closed = true;
					out.output.flush();
					try out.output.close()
					catch (_:Dynamic) {}
					out.thread.join();
					err.output.flush();
					try err.output.close()
					catch (_:Dynamic) {}
					err.thread.join();
					try stdin.close()
					catch (_:Dynamic) {}
				}
			}
		};
	}

	public static function createStdioIo():CompilerIoData return {
		stdout: Sys.stdout(),
		stderr: Sys.stderr(),
		stdin: Sys.stdin(),
		getch: Sys.getChar,
		writeOut: function(s) {
			Sys.print(s);
			Sys.stdout().flush();
		},
		writeErr: function(s) Sys.stderr().writeString(s),
		writeResult: function(s) Sys.stderr().writeString(s),
		signalError: function() {},
		flush: function() Sys.stdout().flush(),
		close: function() {}
	};
}

private class PipeOutput extends Output {
	final queue = new sys.thread.Deque<Null<haxe.io.Bytes>>();
	final done = new sys.thread.Lock();
	var closed = false;

	public function new(writeFn:String->Void) {
		sys.thread.Thread.create(function() {
			try {
				while (true) {
					var bytes = queue.pop(true);
					if (bytes == null) break;
					writeFn(bytes.toString());
				}
			} catch (_:haxe.io.Eof) {} catch (e:haxe.Exception) {
				done.release();
				throw e;
			}
			done.release();
		});
	}

	// Like an OCaml out_channel, writes are buffered (65536 bytes) until flushed;
	// the pipe then delivers them in chunks of at most 1024 bytes.
	var buffer = new haxe.io.BytesBuffer();

	static inline var CHANNEL_BUFFER_SIZE = 65536;

	override public function writeByte(byte:Int):Void {
		var bytes = haxe.io.Bytes.alloc(1);
		bytes.set(0, byte);
		writeBytes(bytes, 0, 1);
	}

	override public function writeBytes(bytes:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (closed) throw haxe.io.Error.Custom("Output is closed");
		if (pos < 0 || len < 0 || pos + len > bytes.length) throw haxe.io.Error.OutsideBounds;
		buffer.addBytes(bytes, pos, len);
		if (buffer.length >= CHANNEL_BUFFER_SIZE) flush();
		return len;
	}

	override public function flush():Void {
		if (buffer.length == 0) return;
		var bytes = buffer.getBytes();
		buffer = new haxe.io.BytesBuffer();
		var pos = 0, left = bytes.length;
		while (left > 0) {
			var n = Std.int(Math.min(left, 1024));
			queue.add(bytes.sub(pos, n));
			pos += n;
			left -= n;
		}
	}

	override public function close():Void {
		if (!closed) {
			flush();
			closed = true;
			queue.add(null);
		}
	}

	public function join():Void done.wait();
}

package core;

import haxe.ds.StringMap;
import sys.thread.Thread;

// Mechanical translation of haxe/src/core/timer.ml. Draft; not compiled or tested.
// OCaml Domain identity uses the host runtime's thread identity here.
@:structInit class TimerInfo {
	public var id:Array<String>;
	public var total:Float;
	public var pauses:Float;
	public var calls:Int;

	public inline function new(id:Array<String>, total:Float, pauses:Float, calls:Int) {
		this.id = id;
		this.total = total;
		this.pauses = pauses;
		this.calls = calls;
	}

	public inline function clone():TimerInfo return new TimerInfo(id, total, pauses, calls);
}

enum MeasureTimes {
	Yes;
	No;
	Maybe;
}

@:structInit class TimerContext {
	public var rootTimer:TimerInfo;
	public var current:TimerInfo;
	public var measureTimes:MeasureTimes;
	public var startTime:Float;
	public var timerLut:StringMap<TimerInfo>;
	public var domainId:Thread;

	public inline function new(rootTimer:TimerInfo, current:TimerInfo, measureTimes:MeasureTimes, startTime:Float,
			timerLut:StringMap<TimerInfo>, domainId:Thread) {
		this.rootTimer = rootTimer;
		this.current = current;
		this.measureTimes = measureTimes;
		this.startTime = startTime;
		this.timerLut = timerLut;
		this.domainId = domainId;
	}

	public inline function clone():TimerContext return new TimerContext(rootTimer, current, measureTimes, startTime, timerLut, domainId);
}

@:structInit class TimerNode {
	public var name:String;
	public var path:String;
	public var parent:TimerNode;
	public var info:String;
	public var time:Float;
	public var numCalls:Int;
	public var children:Array<TimerNode>;

	public inline function new(name:String, path:String, parent:TimerNode, info:String, time:Float, numCalls:Int,
			children:Array<TimerNode>) {
		this.name = name;
		this.path = path;
		this.parent = parent;
		this.info = info;
		this.time = time;
		this.numCalls = numCalls;
		this.children = children;
	}

	public inline function clone():TimerNode return new TimerNode(name, path, parent, info, time, numCalls, children);
}

class Timer {
	static function key(id:Array<String>):String return haxe.Json.stringify(id);

	public static function make(id:Array<String>):TimerInfo return {
		id: id,
		total: 0,
		pauses: 0,
		calls: 0
	};

	public static function makeContext(rootTimer:TimerInfo):TimerContext {
		var ctx:TimerContext = {
			rootTimer: rootTimer,
			current: rootTimer,
			timerLut: new StringMap(),
			measureTimes: Maybe,
			startTime: Sys.time(),
			domainId: Thread.current()
		};
		ctx.timerLut.set(key(rootTimer.id), rootTimer);
		return ctx;
	}

	public static function updateTimer(timer:TimerInfo, start:Float):Float {
		var dt = Sys.time() - start;
		timer.total += dt - timer.pauses;
		return dt;
	}

	static function startTimerMeasured(ctx:TimerContext, id:Array<String>):Void->Void {
		var start = Sys.time();
		var old = ctx.current;
		var timer = ctx.timerLut.get(key(id));
		if (timer == null) {
			timer = make(id);
			ctx.timerLut.set(key(id), timer);
		}
		timer.calls++;
		ctx.current = timer;
		return function() {
			var dt = updateTimer(timer, start);
			timer.pauses = 0;
			old.pauses += dt;
			ctx.current = old;
		};
	}

	public static function startTimer(ctx:TimerContext, id:Array<String>):Void->Void {
		if (id.length > 0 && ctx.measureTimes != No && Thread.current() == ctx.domainId) return startTimerMeasured(ctx, id);
		return function() {};
	}

	public static function time<A, R>(ctx:TimerContext, id:Array<String>, f:A->R, arg:A):R {
		if (ctx.measureTimes == No) return f(arg);
		var close = startTimer(ctx, id);
		var result:R;
		try result = f(arg)
		catch (e:haxe.Exception) {
			close();
			throw e;
		}
		close();
		return result;
	}

	public static function determineId(level:Int, baseLabels:Array<String>, label1:Array<String>, label2:Null<String>):Array<String> {
		return switch level {
			case 0: baseLabels;
			case 1: baseLabels.concat(label1);
			case _: label2 == null ? baseLabels : baseLabels.concat(label1).concat([label2]);
		};
	}

	public static function levelFromDefine(defines:core.Define.DefineContext, define:String):Int {
		try {
			var result = Std.parseInt(Define.definedValue(defines, define));
			return result == null ? 0 : result;
		} catch (_:Dynamic) {
			return 0;
		}
	}

	public static final timerThreshold = 0.01;

	public static function buildTimesTree(ctx:TimerContext):{maxName:Int, maxCalls:Int, root:TimerNode} {
		updateTimer(ctx.rootTimer, ctx.startTime);
		var nodes = new StringMap<TimerNode>();
		var root:TimerNode = {
			name: "",
			path: "",
			parent: null,
			info: "",
			time: 0,
			numCalls: 0,
			children: []
		};
		root.parent = root;
		for (timer in ctx.timerLut) {
			function loop(parent:TimerNode, sl:Array<String>):TimerNode {
				if (sl.length == 0) throw "Invalid empty timer ID";
				var s = sl[0];
				var rest = sl.slice(1);
				var path = (parent.path == "" ? "" : parent.path + ".") + s;
				var node = nodes.get(path);
				if (node != null) {
					node.numCalls += timer.calls;
					node.time += timer.total;
				} else {
					var i = s.lastIndexOf(".");
					var name = i < 0 ? s : s.substr(i + 1);
					var info = i < 0 ? "" : s.substr(0, i);
					node = {
						name: name,
						path: path,
						parent: parent,
						info: info,
						time: timer.total,
						numCalls: timer.calls,
						children: []
					};
					nodes.set(path, node);
				}
				if (rest.length != 0) {
					var child = loop(node, rest);
					if (node.children.indexOf(child) < 0) node.children.unshift(child);
				}
				return node;
			}
			var node = loop(root, timer.id);
			if (root.children.indexOf(node) < 0) root.children.unshift(node);
		}
		var maxName = 0;
		var maxCalls = 0;
		function loop(depth:Int, node:TimerNode):Void {
			var l = node.name.length + 2 * depth;
			for (child in node.children) {
				if (depth == 0) {
					node.numCalls += child.numCalls;
					node.time += child.time;
				}
				loop(depth + 1, child);
			}
			node.children.sort(function(a, b) return a.time < b.time ? 1 : a.time > b.time ? -1 : 0);
			if (node.numCalls > maxCalls) maxCalls = node.numCalls;
			if (node.time >= timerThreshold && l > maxName) maxName = l;
		}
		loop(0, root);
		return {maxName: maxName, maxCalls: maxCalls, root: root};
	}

	static function fixed(value:Float, places:Int):String {
		var factor = Math.pow(10, places);
		var s = Std.string(Math.round(value * factor) / factor);
		if (places > 0) {
			if (s.indexOf(".") < 0) s += ".";
			while (s.length - s.indexOf(".") - 1 < places) s += "0";
		}
		return s;
	}

	public static function reportTimes(ctx:TimerContext, print:String->Void):Void {
		var result = buildTimesTree(ctx);
		var maxName = result.maxName;
		var maxCalls = Std.string(result.maxCalls).length;
		var root = result.root;
		print(StringTools.rpad("name", " ", maxName) + " | " + StringTools.lpad("time(s)", " ", 7) + " |   % |  p% | "
			+ StringTools.lpad("#", " ", maxCalls) + " | info");
		var sep = StringTools.rpad("", "-", maxName + maxCalls + 27);
		print(sep);
		inline function printTime(name:String, node:TimerNode):Void {
			if (node.time >= timerThreshold)
				print(StringTools.rpad(name, " ", maxName)
					+ " | "
					+ StringTools.lpad(fixed(node.time, 3), " ", 7)
					+ " | "
					+ StringTools.lpad(fixed(node.time * 100 / root.time, 0), " ", 3)
					+ " | "
					+ StringTools.lpad(fixed(node.time * 100 / node.parent.time, 0), " ", 3)
					+ " | "
					+ StringTools.lpad(Std.string(node.numCalls), " ", maxCalls)
					+ " | "
					+ node.info);
		}
		function loop(depth:Int, node:TimerNode):Void {
			printTime(StringTools.rpad("", " ", depth * 2) + node.name, node);
			for (child in node.children) loop(depth + 1, child);
		}
		for (child in root.children) loop(0, child);
		print(sep);
		printTime("total", root);
	}
}

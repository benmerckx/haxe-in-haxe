package core.display;

import core.Globals;
import core.Globals.Pos;
import core.Path.UniqueKey;

// Shared position state from haxe/src/core/display/displayPosition.ml.
class DisplayPosition {
	public static final displayPosition = new DisplayPositionContainer();

	public static function enclosesPosition(target:Pos,
			p:Pos):Bool return target.pmin != -1 && target.pmax != -1 && p.pmin <= target.pmin && p.pmax >= target.pmax;

	public static function enclosesPositionGt(target:Pos,
			p:Pos):Bool return target.pmin != -1 && target.pmax != -1 && p.pmin <= target.pmin && p.pmax > target.pmax;
}

class DisplayPositionContainer {
	var pos:Pos = Globals.nullPos;
	var fileKey:Null<String> = null;
	var fileKeys:Array<String> = [];
	var lastPos:Pos = Globals.nullPos;

	public function new() {}

	public function set(p:Pos):Void {
		pos = p;
		lastPos = p;
		fileKey = null;
		fileKeys = p.pfile == core.Path.getFullPath("? input") ? [] : [UniqueKey.create(p.pfile)];
	}

	public function setFiles(files:Array<String>):Void fileKeys = files;

	public function getFiles():Array<String> return fileKeys;

	public function get():Pos return pos;

	public function getFileKey():String {
		if (fileKey == null) fileKey = UniqueKey.create(pos.pfile);
		return fileKey;
	}

	public function reset():Void {
		pos = Globals.nullPos;
		fileKey = null;
		fileKeys = [];
	}

	public function enclosedIn(p:Pos):Bool return DisplayPosition.enclosesPosition(pos, p);

	public function isInFile(key:String):Bool return (pos.pfile != "?" && getFileKey() == key) || hasFile(key);

	public function hasFile(key:String):Bool return fileKeys.contains(key);

	public function cut(p:Pos):Pos return {pfile: p.pfile, pmin: p.pmin, pmax: lastPos.pmax};

	public function runOutside<T>(fn:Void->T):T {
		var saved = get();
		reset();
		try {
			var result = fn();
			set(saved);
			return result;
		} catch (error:haxe.Exception) {
			set(saved);
			throw error;
		}
	}

	public function withPos(p:Pos):Pos return {pfile: p.pfile, pmin: lastPos.pmin, pmax: lastPos.pmax};
}

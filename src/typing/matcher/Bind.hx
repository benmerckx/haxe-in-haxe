package typing.matcher;

import core.TType;
import core.Globals.Pos;

// haxe/src/typing/matcher/bind.ml — mechanical draft; not compile-validated.
enum BindStatus {
	BindUsed;
	BindUnused;
	BindDeferred;
}

@:structInit class Bind {
	public var bVar:TVar;
	public var bPos:Pos;
	public var bExpr:TExpr;
	public var bStatus:BindStatus;

	public inline function new(bVar:TVar, bPos:Pos, bExpr:TExpr, bStatus:BindStatus) {
		this.bVar = bVar;
		this.bPos = bPos;
		this.bExpr = bExpr;
		this.bStatus = bStatus;
	}

	public inline function clone():Bind return new Bind(bVar, bPos, bExpr, bStatus);
}

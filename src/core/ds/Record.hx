package core.ds;

import haxe.macro.Expr;

/** OCaml record updates are shallow copies, retaining every unchanged field. */
class Record {
	/**
		Shallow copy. Records that became classes (for direct field access on
		static targets) are cloned with their class; Reflect.copy would return
		an anonymous object (JS, C++) or null (JVM).
	**/
	/**
		Shallow copy, resolved at compile time: a record class's clone() when the
		static type has one, otherwise copyDynamic.
	**/
	public static macro function copy(record:Expr):Expr {
		var t = try haxe.macro.Context.follow(haxe.macro.Context.typeof(record)) catch (_:Dynamic) null;
		switch t {
			case TInst(c, _):
				for (f in c.get().fields.get()) if (f.name == "clone") return macro $record.clone();
			case _:
		}
		return macro core.ds.Record.copyDynamic($record);
	}

	public static function copyDynamic<T>(o:T):T {
		#if !macro
		if (std.Type.getClass(o) == null) return Reflect.copy(o); // anonymous record
		// record classes all have clone(); Reflect.copy would lose the class
		var clone = Reflect.field(o, "clone");
		if (clone != null) return Reflect.callMethod(o, clone, []);
		#end
		return Reflect.copy(o);
	}

	#if macro
	static var nextId = 0;
	#end

	public static macro function withFields(record:Expr, updates:Expr):Expr {
		var fields = switch updates.expr {
			case EObjectDecl(fields): fields;
			case _: haxe.macro.Context.error("Expected a record field update", updates.pos);
		};
		var name = "__hihRecordUpdate" + (nextId++);
		var ref:Expr = {expr: EConst(CIdent(name)), pos: record.pos};
		var result:Array<Expr> = [
			{expr: EVars([{name: name, expr: macro core.ds.Record.copy($record)}]), pos: record.pos}
		];
		for (field in fields) result.push({
			expr: EBinop(OpAssign, {expr: EField(ref, field.field), pos: field.expr.pos}, field.expr),
			pos: field.expr.pos
		});
		result.push(ref);
		return {expr: EBlock(result), pos: record.pos};
	}
}

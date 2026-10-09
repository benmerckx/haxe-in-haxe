package typing;

import core.TType;
import core.TPrinting;

// haxe/src/typing/fieldCallCandidate.ml — mechanical draft; not compile-validated.
@:structInit class FieldCallCandidateData<A> {
	public var fcArgs:Array<TExpr>;
	public var fcRet:T;
	public var fcType:T;
	public var fcField:TClassField;
	public var fcMonos:Array<T>;
	public var fcData:A;

	public inline function new(fcArgs:Array<TExpr>, fcRet:T, fcType:T, fcField:TClassField, fcMonos:Array<T>, fcData:A) {
		this.fcArgs = fcArgs;
		this.fcRet = fcRet;
		this.fcType = fcType;
		this.fcField = fcField;
		this.fcMonos = fcMonos;
		this.fcData = fcData;
	}

	public inline function clone():FieldCallCandidateData<A> return new FieldCallCandidateData(fcArgs, fcRet, fcType, fcField, fcMonos,
		fcData);
}

class FieldCallCandidate {
	public static function makeFieldCallCandidate<A>(args:Array<TExpr>, ret:T, monos:Array<T>, t:T, cf:TClassField,
			data:A):FieldCallCandidateData<A> {
		return {
			fcArgs: args,
			fcType: t,
			fcField: cf,
			fcData: data,
			fcRet: ret,
			fcMonos: monos
		};
	}

	public static function sFieldCallCandidate<A>(fcc:FieldCallCandidateData<A>):String {
		var pctx = TPrinting.printContext();
		var se = function(e) return TPrinting.sExprPretty(false, "", false, function(t) return TPrinting.sType(pctx, t), e);
		return Printer.sRecordFields("", [
			{name: "fc_args", value: fcc.fcArgs.map(se).join(", ")},
			{name: "fc_type", value: TPrinting.sType(pctx, fcc.fcType)},
			{name: "fc_field", value: fcc.fcField.cfName + ": " + TPrinting.sType(pctx, fcc.fcField.cfType)}
		]);
	}
}

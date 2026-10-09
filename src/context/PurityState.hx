package context;

import core.Globals.Pos;
import core.Ast;
import core.TType;
import core.Meta;
import core.Error;

// Draft mechanical translation of haxe/src/context/purityState.ml; unvalidated.
// Fields begin MaybePure unless metadata specifies otherwise; inherited promises
// become ExpectPure and are checked by the later purity inference pass.
enum PurityState {
	Pure;
	Impure;
	MaybePure;
	InferredPure;
	ExpectPure(pos:Pos);
}

class PurityStateTools {
	public static function getPurityFromMeta(meta:Metadata):PurityState {
		var entry = Meta.getOpt(Meta.Pure, meta);
		if (entry == null) return MaybePure;
		if (entry.exprs.length == 0) return Pure;
		if (entry.exprs.length == 1) switch entry.exprs[0] {
			case {expr: EConst(Ident(s)), pos: p}:
				return switch s {
					case "true", "inferredPure": Pure;
					case "false": Impure;
					case "expect": ExpectPure(p);
					case _: Error.raiseTypingError("Unsupported purity value " + s + ", expected true or false", p);
				};
			case _:
		}
		return Error.raiseTypingError("Unsupported purity value", entry.pos);
	}

	public static function getPurity(c:TClass, cf:TClassField):PurityState return switch getPurityFromMeta(cf.cfMeta) {
		case Pure, InferredPure: Pure;
		case Impure: Impure;
		case ExpectPure(p): ExpectPure(p);
		case _: getPurityFromMeta(c.clMeta);
	};

	public static function isPure(c:TClass, cf:TClassField):Bool return getPurity(c, cf) == Pure;

	public static function isPureFieldAccess(fa:TFieldAccess):Bool return switch fa {
		case FInstance(c, _, cf), FStatic(c, cf): isPure(c, cf);
		case FClosure(c, cf): c == null ? getPurityFromMeta(cf.cfMeta) == Pure : isPure(c.cls, cf);
		case FAnon(cf): getPurityFromMeta(cf.cfMeta) == Pure;
		case FEnum(_, _): true;
		case FDynamic(_): false;
	};

	public static function isExplicitlyImpure(fa:TFieldAccess):Bool return switch fa {
		case FInstance(c, _, cf), FStatic(c, cf): getPurityFromMeta(cf.cfMeta) == Impure || getPurityFromMeta(c.clMeta) == Impure;
		case FClosure(c, cf): getPurityFromMeta(cf.cfMeta) == Impure || (c != null && getPurityFromMeta(c.cls.clMeta) == Impure);
		case FAnon(cf): getPurityFromMeta(cf.cfMeta) == Impure;
		case _: false;
	};

	public static function toString(purity:PurityState):String return switch purity {
		case Pure: "pure";
		case Impure: "impure";
		case InferredPure: "inferredPure";
		case MaybePure: "maybe";
		case ExpectPure(_): "expect";
	};
}

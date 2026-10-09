package macros.eval;

import core.ds.NotFound;
import macros.eval.EvalValue;
import macros.eval.EvalContext;

using macros.eval.EvalValue.EvalValueTools;

/** haxe/src/macro/eval/evalField.ml. **/
class EvalField {
	public static final noField:Value = VNull;

	public static function protoFieldDirect(proto:Vprototype,
			name:Int):Value return proto.pfields[EvalContext.getProtoFieldIndexRaise(proto, name)];

	public static function protoFieldRaise(proto:Vprototype, name:Int):Value {
		try
			return protoFieldDirect(proto, name)
		catch (_:NotFound) {
			return switch proto.pparent {
				case null: throw NotFound.raise();
				case proto: protoFieldRaise(proto, name);
			}
		}
	}

	public static function instanceField(vi:Vinstance,
			name:Int):Value return vi.ifields[EvalContext.getInstanceFieldIndexRaise(vi.iproto, name)];

	public static function objectFieldRaise(o:Vobject, name:Int):Value {
		return switch o.oproto {
			case OProto(proto):
				o.ofields[EvalContext.getInstanceFieldIndexRaise(proto, name)];
			case ODictionary(l):
				l.find(name);
		}
	}

	public static function objectField(o:Vobject, name:Int):Value {
		try
			return objectFieldRaise(o, name)
		catch (_:NotFound)
			return VNull;
	}

	public static function fieldRaise(v:Value, f:Int):Value {
		return switch v.vresolve() {
			case VObject(o): objectFieldRaise(o, f);
			case VInstance({ikind: IBytes(s)}) if (f == EvalHash.key_length): VInt32(s.length);
			case VPrototype(proto): protoFieldRaise(proto, f);
			case VArray(va):
				if (f == EvalHash.key_length) VInt32(va.alength) else protoFieldDirect(EvalContext.getCtx().arrayPrototype, f);
			case VVector(vv):
				if (f == EvalHash.key_length) VInt32(vv.length) else protoFieldDirect(EvalContext.getCtx().vectorPrototype, f);
			case VString(s):
				if (f == EvalHash.key_length) VInt32(s.slength) else protoFieldDirect(EvalContext.getCtx().stringPrototype, f);
			case VInstance(vi):
				try instanceField(vi, f) catch (_:NotFound) protoFieldRaise(vi.iproto, f);
			case _: throw NotFound.raise();
		}
	}

	public static function field(v:Value, f:Int):Value {
		try
			return fieldRaise(v, f)
		catch (_:NotFound)
			return noField;
	}

	public static function dynamicField(v:Value, name:Int):Value {
		return switch field(v, name) {
			case VFunction(f, false): VFieldClosure(v, f);
			case v: v;
		}
	}
}

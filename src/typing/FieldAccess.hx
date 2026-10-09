package typing;

import core.TType;
import core.Globals.Pos;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TOther.TClassTools;
import core.Abstract;
import core.Texpr.Builder;
import core.Error.*;
import core.Error;
import context.Typecore;
import context.Typecore.FieldHost as FieldAccessHost;
import context.Typecore.FieldAccess as FieldAccessData;
import core.ds.NotFound;

// haxe/src/typing/fieldAccess.ml — mechanical draft; not compile-validated.
enum FieldHost {
	FGet;
	FCall;
	FRead;
	FWrite;
}

enum AccessorResolution<A> {
	AccessorFound(value:A);
	AccessorAnon;
	AccessorNotFound;
	AccessorInvalid;
}

class FieldAccess {
	public static function create(e:TExpr, cf:TClassField, fh:FieldAccessHost, doInline:Bool, p:Pos, ?fieldPos:Pos):FieldAccessData {
		return {
			faOn: e,
			faField: cf,
			faHost: fh,
			faInline: doInline,
			faPos: p,
			faFieldPos: fieldPos
		};
	}

	public static function applyFa(cf:TClassField, host:FieldAccessHost):TFieldAccess return switch host {
		case FHStatic(c): FStatic(c, cf);
		case FHInstance(c, tl): FInstance(c, tl, cf);
		case FHAbstract(a, tl, c): FStatic(c, cf);
		case FHAnon: FAnon(cf);
	};

	public static function getHost(c:TClass, cf:TClassField):FieldAccessHost {
		if (hasClassFieldFlag(cf, CfStatic)) return FHStatic(c);
		return switch c.clKind {
			case KAbstractImpl(a): FHAbstract(a, extractParamTypes(a.aParams), c);
			case _: FHInstance(c, extractParamTypes(c.clParams));
		};
	}

	public static function getHostClassRaise(host:FieldAccessHost):TClass return switch host {
		case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): c;
		case FHAnon: throw NotFound.raise();
	};

	public static function getMapFunction(fa:FieldAccessData):T->T return switch fa.faHost {
		case FHStatic(_) | FHAnon: function(t) return t;
		case FHInstance(c, tl): TClassTools.getMapFunction(c, tl);
		case FHAbstract(a, tl, _): function(t) return applyParams(a.aParams, tl, t);
	};

	public static function getFieldExpr(fa:FieldAccessData, mode:FieldHost):TExpr {
		var cf = fa.faField;
		var t = mode == FCall ? cf.cfType : fieldType(cf);
		var access:TFieldAccess = switch fa.faHost {
			case FHStatic(c): FStatic(c, cf);
			case FHInstance(c, tl):
				t = TClassTools.getMapFunction(c, tl)(t);
				switch cf.cfKind {
					case Method(_) if (mode == FRead): FClosure({cls: c, params: tl}, cf);
					case _: FInstance(c, tl, cf);
				}
			case FHAbstract(a, tl, c):
				t = applyParams(a.aParams, tl, t);
				FStatic(c, cf);
			case FHAnon:
				switch cf.cfKind {
					case Method(_) if (mode == FRead): FClosure(null, cf);
					case _: FAnon(cf);
				}
		};
		return mk(TField(fa.faOn, access), t, fa.faPos);
	}

	public static function findAccessorForField(host:FieldAccessHost, cf:TClassField, t:T,
			mode:AccessMode):AccessorResolution<{field:TClassField, host:FieldAccessHost}> {
		return switch cf.cfKind {
			case Var(v):
				var writing = switch mode {
					case MSet(_): true;
					case _: false;
				};
				switch (writing ? v.vWrite : v.vRead) {
					case AccCall | AccPrivateCall:
						var name = (writing ? "set_" : "get_") + cf.cfName;
						switch host {
							case FHStatic(c):
								var accessor = c.clStatics.get(name);
								accessor == null ? AccessorAnon : AccessorFound({field: accessor, host: host});
							case FHInstance(c, tl):
								try {
									var actual = switch follow(t) {
										case TInst(c, tl): {cls: c, params: tl};
										case _: {cls: c, params: tl};
									};
									var found = rawClassField(function(f) return f.cfType, actual.cls, actual.params, name);
									var newHost = found.owner == null ? FHAnon : FHInstance(found.owner.cls, found.owner.params);
									AccessorFound({field: found.field, host: newHost});
								} catch (error:NotFound) {
									hasClassFlag(c, CExtern) ? AccessorAnon : AccessorNotFound;
								}
							case FHAbstract(a, tl, c):
								var accessor = c.clStatics.get(name);
								accessor == null ? AccessorAnon : AccessorFound({field: accessor, host: host});
							case FHAnon: AccessorAnon;
						}
					case _: AccessorInvalid;
				}
			case _: AccessorInvalid;
		};
	}

	public static function resolveAccessor(fa:FieldAccessData, mode:AccessMode):AccessorResolution<FieldAccessData> {
		return switch findAccessorForField(fa.faHost, fa.faField, fa.faOn.etype, mode) {
			case AccessorFound(found): AccessorFound(create(fa.faOn, found.field, found.host, fa.faInline, fa.faPos, fa.faFieldPos));
			case AccessorInvalid: AccessorInvalid;
			case AccessorAnon: AccessorAnon;
			case AccessorNotFound: AccessorNotFound;
		};
	}

	public static function getConstructorAccess(c:TClass, tl:TParams, p:Pos):FieldAccessData {
		try {
			var eStatic = Builder.makeStaticThis(c, p);
			var actual = switch c.clKind {
				case KAbstractImpl(a): switch Abstract.followWithForwardCtor(TAbstract(a, tl)) {
						case TInst(c, tl): {cls: c, params: tl};
						case TAbstract(a, tl) if (a.aImpl != null): {cls: a.aImpl, params: tl};
						case _: {cls: c, params: tl};
					}
				case _: {cls: c, params: tl};
			};
			var host:FieldAccessHost;
			var cf = switch actual.cls.clKind {
				case KAbstractImpl(a):
					if (a.aConstructor == null) throw NotFound.raise();
					host = FHAbstract(a, actual.params, actual.cls);
					a.aConstructor;
				case _:
					host = FHInstance(actual.cls, actual.params);
					getConstructor(actual.cls);
			};
			return create(eStatic, cf, host, false, p);
		} catch (error:NotFound) {
			return raiseTypingErrorExt(makeError(NoConstructor(switch c.clKind {
				case KAbstractImpl(a): TAbstractDecl(a);
				case _: TClassDecl(c);
			}), p));
		}
	}

	public static function makeStaticExtensionAccess(c:TClass, cf:TClassField, eThis:TExpr, doInline:Bool, p:Pos):StaticExtensionAccess {
		return {seThis: eThis, seAccess: create(Builder.makeStaticThis(c, p), cf, FHStatic(c), doInline, p)};
	}

	public static function makeAbstractStaticExtensionAccess(a:TAbstract, tl:TParams, c:TClass, cf:TClassField, eThis:TExpr,
			doInline:Bool, p:Pos):StaticExtensionAccess {
		return {seThis: eThis, seAccess: create(Builder.makeStaticThis(c, p), cf, FHAbstract(a, tl, c), doInline, p)};
	}
}

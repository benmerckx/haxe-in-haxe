package typing;

import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.TOther.*;
import core.TOther;
import core.TOther.TClassTools;
import core.TUnification.Unify_error;
import core.TOther.ExtType;
import typing.FieldCallCandidate;
import typing.FieldCallCandidate.FieldCallCandidateData;
import codegen.Overloads;

// haxe/src/typing/overloadResolution.ml — mechanical draft; not compile-validated.
@:structInit class ResolvedOverload {
	public var cls:TClass;
	public var field:TClassField;
	public var monos:Array<T>;

	public inline function new(cls:TClass, field:TClassField, monos:Array<T>) {
		this.cls = cls;
		this.field = field;
		this.monos = monos;
	}

	public inline function clone():ResolvedOverload return new ResolvedOverload(cls, field, monos);
}

class OverloadResolution {
	public static function tryFunctionalInterfaceMatch(tParam:T, tArg:T):Bool {
		return switch [follow(tParam), follow(tArg)] {
			case [TInst(c, tl), TFun(_)] if (hasClassFlag(c, CFunctionalInterface)):
				var cf = TClassTools.getSingularInterfaceField(c.clOrderedFields);
				if (cf == null) false else {
					var monos = cf.cfParams.map(function(_) return mkMono());
					var expected = applyParams(c.clParams, tl, applyParams(cf.cfParams, monos, cf.cfType));
					try {
						unify(tArg, expected);
						true;
					} catch (_:Unify_error) {
						false;
					}
				}
			case _: false;
		};
	}

	public static function unifyCf(mapType:T->T, c:TClass, cf:TClassField, el:Array<TExpr>):Null<FieldCallCandidateData<ResolvedOverload>> {
		var monos = cf.cfParams.map(function(_) return mkMono());
		var tf = follow(applyParams(cf.cfParams, monos, mapType(cf.cfType)));
		return switch tf {
			case TFun(signature):
				function loop2(acc:Array<TExpr>, expressions:Array<TExpr>,
						tl:Array<{name:String, optional:Bool, type:T}>):Null<FieldCallCandidateData<ResolvedOverload>> {
					if (expressions.length > 0 && tl.length > 0) {
						var e = expressions[0], rest = expressions.slice(1), t = tl[0].type;
						try {
							try unify(e.etype, t)
							catch (error:Unify_error) {
								if (!tryFunctionalInterfaceMatch(t, e.etype)) throw error;
							}
							return loop2([e].concat(acc), rest, tl.slice(1));
						} catch (_:Dynamic) {
							if (ExtType.isRest(follow(t))) return switch follow(t) {
								case TAbstract(a, [element])
									if (a.aPath.pack.join(".") == "haxe" && a.aPath.name == "Rest" && tl.length == 1):
									try {
										// Preserve upstream's use of the tail after the failed argument.
										var tail = rest.map(function(e) {
											unify(element, e.etype);
											return e;
										});
										var ordered = acc.copy();
										ordered.reverse();
										FieldCallCandidate.makeFieldCallCandidate(ordered.concat(tail), signature.ret, monos, tf, cf,
											({cls: c, field: cf, monos: monos} : ResolvedOverload));
									} catch (_:Dynamic) {
										null;
									}
								case _: throw "Invalid rest overload";
							};
							return null;
						}
					}
					if (expressions.length == 0 && tl.length == 0) {
						var ordered = acc.copy();
						ordered.reverse();
						return FieldCallCandidate.makeFieldCallCandidate(ordered, signature.ret, monos, tf, cf,
							({cls: c, field: cf, monos: monos} : typing.OverloadResolution.ResolvedOverload));
					}
					return null;
				}
				loop2([], el, signature.args);
			case _: null;
		};
	}

	public static function findOverload(mapType:T->T, c:TClass, cf:TClassField,
			el:Array<TExpr>):Array<FieldCallCandidateData<ResolvedOverload>> {
		var result = [];
		for (field in [cf].concat(cf.cfOverloads)) {
			var candidate = unifyCf(mapType, c, field, el);
			if (candidate != null) result.push(candidate);
		}
		return result;
	}

	public static function filterOverloads<A>(candidates:Array<FieldCallCandidateData<A>>):Null<A> {
		var reduced = codegen.Overloads.Resolution.reduceCompatible(candidates);
		return reduced.length == 0 ? null : reduced[0].fcData;
	}

	public static function resolveInstanceOverload(isCtor:Bool, mapType:T->T, c:TClass, name:String,
			el:Array<TExpr>):Null<ResolvedOverload> {
		var candidates:Array<FieldCallCandidateData<ResolvedOverload>> = [];
		inline function hasFunction(t1:T, fcc2:FieldCallCandidateData<ResolvedOverload>):Bool return switch [follow(t1), fcc2.fcType] {
			case [TFun(s1), TFun(s2)]: typeIseq(TFun({args: s1.args, ret: tDynamic}), TFun({args: s2.args, ret: tDynamic}));
			case _: false;
		};
		function loop(mapType:T->T, c:TClass):Void {
			var cf = isCtor ? c.clConstructor : c.clFields.get(name);
			var searchParents = cf == null;
			if (cf != null) {
				var found = findOverload(mapType, c, cf, el);
				if (found.length == 0) searchParents = true;
				for (fcc in found) {
					if (!core.ds.ArrayTools.exists(candidates,
						function(other) return hasFunction(fcc.fcType, other))) candidates.unshift(fcc);
				}
				if (hasClassFieldFlag(cf, CfOverload) || cf.cfOverloads.length > 0) searchParents = true;
			}
			if (searchParents) {
				if (hasClassFlag(c, CInterface)) {
					for (parent in c.clImplements) {
						var mapped = parent.params.map(mapType);
						loop(function(t) return applyParams(parent.cls.clParams, mapped, t), parent.cls);
					}
				} else if (c.clSuper != null) {
					var parent = c.clSuper;
					var mapped = parent.params.map(mapType);
					loop(function(t) return applyParams(parent.cls.clParams, mapped, t), parent.cls);
				}
			}
		}
		loop(mapType, c);
		candidates.reverse();
		return filterOverloads(candidates);
	}

	public static function maybeResolveInstanceOverload(isCtor:Bool, mapType:T->T, c:TClass, cf:TClassField,
			el:Array<TExpr>):Null<ResolvedOverload> {
		if (hasClassFieldFlag(cf,
			CfOverload) || cf.cfOverloads.length > 0) return resolveInstanceOverload(isCtor, mapType, c, cf.cfName, el);
		var candidate = unifyCf(mapType, c, cf, el);
		return candidate == null ? {cls: c, field: cf, monos: extractParamTypes(cf.cfParams)} : candidate.fcData;
	}

	public static function maybeResolveConstructorOverload(c:TClass, tl:TParams, el:Array<TExpr>):Null<ResolvedOverload> {
		var ctor = getConstructorClass(c, tl);
		return maybeResolveInstanceOverload(true, function(t) return applyParams(ctor.cls.clParams, ctor.params, t), ctor.cls, ctor.field,
			el);
	}

	public static function maybeReapplyOverloadCall(e:TExpr):TExpr {
		return switch e.eexpr {
			case TCall(ef = {eexpr: TField(e1, fa)}, el):
				inline function rebuild(cf:TClassField):TExpr {
					var access = switch fa {
						case FInstance(c, tl, _): FInstance(c, tl, cf);
						case FStatic(c, _): FStatic(c, cf);
						case _: fa;
					};
					return {eexpr: TCall({eexpr: TField(e1, access), etype: ef.etype, epos: ef.epos}, el), etype: e.etype, epos: e.epos};
				}
				var resolved = switch fa {
					case FStatic(c,
						cf) if (hasClassFieldFlag(cf, CfOverload)): filterOverloads(findOverload(function(t) return t, c, cf, el));
					case FInstance(c, tl,
						cf) if (hasClassFieldFlag(cf,
							CfOverload)): resolveInstanceOverload(false, function(t) return
							applyParams(c.clParams, tl, t), c, cf.cfName, el);
					case _: null;
				};
				resolved == null ? e : rebuild(resolved.field);
			case _: e;
		};
	}
}

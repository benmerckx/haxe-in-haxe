package typing;

import core.Globals.Platform;
import core.ds.AtomicLazy;
import core.TFunctions.TypeExit;
import context.Typecore.Typer as TyperContext;
import context.Common.CommonContext;
import context.Common.LocalWrapperApi;
import context.TyperPass.TyperPassTools;
import context.Resolution;
import optimization.Inline;
import core.Globals.Pos;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.Globals;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import context.Typecore.TyperManager;
import context.Common;
import core.Define;
import typing.Typer.*;
import context.Resolution.*;

// haxe/src/typing/typerEntry.ml — mechanical draft; not compile-validated.
class TyperEntry {
	public static function loadStdTypes(ctx:TyperContext):Void {
		var stdTypes:ModuleDef;
		try stdTypes = ModuleTyping.loadModule(ctx, {pack: [], name: "StdTypes"}, Globals.nullPos)
		catch (e:Dynamic) {
			switch e {
				case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound({pack: [], name: "StdTypes"})})):
					stdTypes = raiseStdNotFound();
				case _:
					throw e;
			}
		}
		var types:Array<ModuleType> = stdTypes.mTypes.copy();
		types.reverse();
		for (t in types) {
			ctx.m.importResolution.add(Resolution.moduleTypeResolution(t, null, Globals.nullPos));
			switch t {
				case TAbstractDecl(a):
					switch a.aPath.name {
						case "Void":
							var t = TAbstract(a, []);
							core.TUnification.unify(t, ctx.t.tvoid);
							ctx.t.tvoid = t;
						case "Float":
							var t = TAbstract(a, []);
							core.TUnification.unify(t, ctx.t.tfloat);
							ctx.t.tfloat = t;
						case "Int":
							var t = TAbstract(a, []);
							core.TUnification.unify(t, ctx.t.tint);
							ctx.t.tint = t;
						case "Bool":
							var t = TAbstract(a, []);
							core.TUnification.unify(t, ctx.t.tbool);
							ctx.t.tbool = t;
						case "Dynamic": ctx.g.tDynamicDef = TAbstract(a, extractParamTypes(a.aParams));
						case "Null":
							ctx.t.tnull = function(t:T):T {
								try {
									return !isNull(t, true) && !isExplicitNull(t) ? TAbstract(a, [t]) : t;
								} catch (err:TypeExit) {
									var r = new TLazy(lazyAvailable(tDynamic));
									r.value = lazyWait(function() {
										var t1 = !isNull(t) ? TAbstract(a, [t]) : t;
										r.value = lazyAvailable(t1);
										return t1;
									});
									return TLazy(r);
								}
							};
						case _:
					}
				case TTypeDecl(td):
					if (td.tPath.name == "Iterator") ctx.t.titerator = t -> TType(td, [t]);
				case TEnumDecl(_) | TClassDecl(_):
			}
		}
	}

	public static function loadString(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: [], name: "String"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "String"}}):
				var t = TInst(c, []);
				core.TUnification.unify(t, ctx.t.tstring);
				ctx.t.tstring = t;
			case _:
		}
	}

	public static function loadStd(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: [], name: "Std"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "Std"}}):
				ctx.com.std = c;
			case _:
		}
	}

	public static function loadAny(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: [], name: "Any"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TAbstractDecl(a) if (a.aPath.name == "Any"):
				var t = TAbstract(a, []);
				core.TUnification.unify(t, ctx.t.tany);
				ctx.t.tany = t;
			case _:
		}
	}

	public static function loadArray(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: [], name: "Array"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c = {clPath: {pack: [], name: "Array"}}):
				ctx.t.tarray = t -> TInst(c, [t]);
				return;
			case _:
		}
		throw "Could not locate Array";
	}

	public static function loadUnit(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: ["haxe"], name: "Unit"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TEnumDecl(en) if (en.ePath.name == "Unit"):
				ctx.t.tunit = TEnum(en, []);
			case _:
		}
	}

	public static function loadEnumTools(ctx:TyperContext):Void {
		var m = ModuleTyping.loadModule(ctx, {pack: ["haxe"], name: "EnumTools"}, Globals.nullPos);
		switch m.mTypes {
			case [TClassDecl(c1), TClassDecl(c2)]:
				ctx.g.globalUsing = [{cls: c1, pos: c1.clPos}, {cls: c2, pos: c2.clPos}].concat(ctx.g.globalUsing);
			case [TClassDecl(c1)]:
				var m = ModuleTyping.loadModule(ctx, {pack: ["haxe"], name: "EnumValueTools"}, Globals.nullPos);
				switch m.mTypes {
					case [TClassDecl(c2)]: ctx.g.globalUsing = [
							{cls: c1, pos: c1.clPos},
							{
								cls: c2,
								pos: c2.clPos
							}
						].concat(ctx.g.globalUsing);
					case _: throw "Invalid EnumValueTools module";
				}
			case _:
				throw "Invalid EnumTools module";
		}
	}

	public static function loadLocalWrapper(ctx:TyperContext):LocalWrapperApi {
		if (ctx.com.platform == Jvm) {
			var m = ModuleTyping.loadModule(ctx, {pack: ["jvm"], name: "NativeArray"}, Globals.nullPos);
			for (md in m.mTypes) switch md {
				case TClassDecl(cl = {clPath: {pack: ["jvm"], name: "NativeArray"}}):
					return new CaptureLocalWrapper(ctx.t, cl);
				case _:
			}
			throw core.ds.NotFound.raise();
		}
		return new CaptureLocalWrapper(ctx.t, null);
	}

	public static function loadCoro(ctx:TyperContext):Void {
		ctx.t.tcoro.tcoro = AtomicLazy.fromFun(function() {
			var m = ModuleTyping.loadModule(ctx, {pack: ["haxe", "coro"], name: "Coroutine"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TAbstractDecl(a = {aPath: {pack: ["haxe", "coro"], name: "Coroutine"}}):
					return function(signature:TSignature):T return TAbstract(a, [TFun(signature)]);
				case _:
			}
			throw "Could not locate abstract Coroutine<T> (was it redefined?)";
		});
		ctx.t.tcoro.continuation = AtomicLazy.fromFun(function() {
			var m = ModuleTyping.loadModule(ctx, {pack: ["haxe", "coro"], name: "IContinuation"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TClassDecl(cl = {clPath: {pack: ["haxe", "coro"], name: "IContinuation"}}):
					return TInst(cl, [ctx.t.tany]);
				case _:
			}
			throw "Could not locate class IContinuation<T> (was it redefined?)";
		});
		ctx.t.tcoro.suspensionResultClass = AtomicLazy.fromFun(function() {
			var m = ModuleTyping.loadModule(ctx, {pack: ["haxe", "coro"], name: "SuspensionResult"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TClassDecl(cl = {clPath: {pack: ["haxe", "coro"], name: "SuspensionResult"}}):
					return cl;
				case _:
			}
			throw "Could not locate class SuspensionResult<T> (was it redefined?)";
		});
		ctx.t.tcoro.tasyncIterator = AtomicLazy.fromFun(function() {
			var m = ModuleTyping.loadModule(ctx, {pack: ["haxe", "coro"], name: "AsyncIterator"}, Globals.nullPos);
			for (mt in m.mTypes) switch mt {
				case TTypeDecl(td = {tPath: {pack: ["haxe", "coro"], name: "AsyncIterator"}}):
					return function(t:T):T return TType(td, [t]);
				case _:
			}
			throw "Could not locate typedef AsyncIterator<T> (was it redefined?)";
		});
		var m = ModuleTyping.loadModule(ctx, {pack: ["haxe"], name: "Exception"}, Globals.nullPos);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(cl = {clPath: {pack: ["haxe"], name: "Exception"}}):
				ctx.t.texception = TInst(cl, []);
			case _:
		}
	}

	public static function create(com:CommonContext, macros:Null<{finalize:Void->Void, typer:TyperContext}>):TyperContext {
		typing.Typer.initialize();
		var ctx:TyperContext = {
			com: com,
			t: com.basic,
			g: null,
			m: {
				curmod: nullModule,
				importResolution: new ResolutionList(["import", "typer"]),
				ownResolution: null,
				enumWithType: null,
				moduleUsing: [],
				importStatements: [],
				isDisplayFile: false
			},
			c: {curclass: nullClass, tthis: tDynamic, getBuildInfos: function() return null},
			f: TyperManager.createCtxF(nullField),
			e: TyperManager.createCtxE(FunStatic, FunFunction),
			pass: PBuildModule,
			allowInline: true,
			allowTransform: true,
			typeParams: [],
			memoryMarker: memoryMarker
		};
		ctx.g = {
			coreApi: null,
			macros: macros,
			moduleCheckPolicies: [],
			delayed: [for (_ in 0...TyperPassTools.allTyperPassesLength) {tasks: [], tasksLate: []}],
			delayedMinIndex: 0,
			debugDelayed: [],
			retainMeta: Common.defined(com, Define.RetainUntypedMeta),
			globalUsing: [],
			complete: false,
			typeHints: [],
			loadOnlyCachedModules: false,
			returnPartialType: false,
			buildCount: 0,
			tDynamicDef: tDynamic,
			continuationApi: null,
			doMacro: MacroContext.typeMacro,
			doLoadMacro: MacroContext.loadMacroPrime,
			doLoadModule: ModuleTyping.loadModule,
			doLoadTypeDef: Typeload.loadTypeDef,
			getBuildInfo: InstanceBuilder.getBuildInfo,
			doFormatString: formatString,
			doLoadCoreClass: Typeload.loadCoreClass,
			delayedDisplay: null,
			callArgContext: null,
			rootTyper: ctx
		};
		loadStdTypes(ctx);
		loadString(ctx);
		loadStd(ctx);
		loadAny(ctx);
		loadUnit(ctx);
		loadArray(ctx);
		loadEnumTools(ctx);
		loadCoro(ctx);
		ctx.com.localWrapper = loadLocalWrapper(ctx);
		ctx.g.complete = true;
		return ctx;
	}

	public static function initHooks():Void {
		createContextRef = create;
	}

	static function __init__():Void initHooks();
}

// OCaml objects in load_local_wrapper share captured compiler basic types.
private class CaptureLocalWrapper implements LocalWrapperApi {
	final basic:BasicTypes;
	final nativeClass:Null<TClass>;

	public function new(basic:BasicTypes, nativeClass:Null<TClass>) {
		this.basic = basic;
		this.nativeClass = nativeClass;
	}

	public function capturedType(t:T):T return nativeClass == null ? basic.tarray(t) : TInst(nativeClass, [t]);

	public function mkRef(v:TVar, value:Null<TExpr>, p:Pos):TExpr {
		if (nativeClass == null) return mk(TArrayDecl(value == null ? [] : [value]), v.vType, p);
		if (value == null) {
			var element = switch v.vType {
				case TInst(_, [t]): t;
				case _: throw "Invalid native local wrapper type";
			};
			return mk(TNew(nativeClass, [element], [mk(TConst(TInt(1)), basic.tint, p)]), v.vType, p);
		}
		var e = Inline.mkUntypedCall("__array__", p, [value]);
		e.etype = v.vType;
		return e;
	}

	public function mkRefAccess(e:TExpr, v:TVar):TExpr {
		var array = core.ds.Record.withFields(e, {etype: v.vType});
		return mk(TArray(array, mk(TConst(TInt(0)), basic.tint, e.epos)), e.etype, e.epos);
	}

	public function mkInit(av:TVar, v:TVar, p:Pos):TExpr {
		var local = mk(TLocal(v), v.vType, p);
		var array = nativeClass == null ? mk(TArrayDecl([local]), av.vType, p) : Inline.mkUntypedCall("__array__", p, [local]);
		array.etype = av.vType;
		return mk(TVar(av, array), basic.tvoid, p);
	}
}

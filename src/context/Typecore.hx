package context;

import core.Message.WarningCode;
import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Ast;
import core.TType;
import core.Meta;
import core.ds.PersistentMap;
import core.ds.NotFound;
import context.TyperPass;
import context.Resolution;
import core.TFunctions as TypeOps;
import core.TUnification;
import core.TUnification.Monomorph;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;
import core.Texpr;
import core.Warning;
import core.WarningList;
import Type as StdType;
import core.Error.Error;
import core.Error.ErrorMsg;

// Draft mechanical translation of haxe/src/context/typecore.ml; unvalidated.
// Macro and display callbacks retain their shape; their runtimes are not implemented here.
@:structInit class TypePatch {
	public var tpType:Null<ComplexType>;
	public var tpRemove:Bool;
	public var tpMeta:Metadata;

	public inline function new(tpType:Null<ComplexType>, tpRemove:Bool, tpMeta:Metadata) {
		this.tpType = tpType;
		this.tpRemove = tpRemove;
		this.tpMeta = tpMeta;
	}

	public inline function clone():TypePatch return new TypePatch(tpType, tpRemove, tpMeta);
}

enum CurrentFun {
	FunMember;
	FunStatic;
	FunConstructor;
	FunMemberAbstract;
	FunMemberClassLocal;
	FunMemberAbstractLocal;
}

enum MacroMode {
	MExpr;
	MBuild;
	MMacroType;
	MDisplay;
}

enum AccessMode {
	MGet;
	MSet(rhs:Null<Expr>);
	MCall(args:Array<Expr>);
}

@:structInit class TyperModule {
	public var curmod:ModuleDef;
	public var importResolution:ResolutionList;
	public var ownResolution:Null<ResolutionList>;
	public var enumWithType:Null<ModuleType>;
	public var moduleUsing:Array<{cls:TClass, pos:Pos}>;
	public var importStatements:Array<Import>;
	public var isDisplayFile:Bool;

	public inline function new(curmod:ModuleDef, importResolution:ResolutionList, ownResolution:Null<ResolutionList>,
			enumWithType:Null<ModuleType>, moduleUsing:Array<{
			cls:TClass,
			pos:Pos
		}>, importStatements:Array<Import>, isDisplayFile:Bool) {
		this.curmod = curmod;
		this.importResolution = importResolution;
		this.ownResolution = ownResolution;
		this.enumWithType = enumWithType;
		this.moduleUsing = moduleUsing;
		this.importStatements = importStatements;
		this.isDisplayFile = isDisplayFile;
		}

	public inline function clone():TyperModule return new TyperModule(curmod, importResolution, ownResolution, enumWithType, moduleUsing,
		importStatements, isDisplayFile);
}

@:structInit class TyperClass {
	public var curclass:TClass;
	public var tthis:T;
	public var getBuildInfos:Void->Null<{type:ModuleType, params:TParams, fields:Array<ClassField>}>;

	public inline function new(curclass:TClass, tthis:T,
			getBuildInfos:Void->Null<{type:ModuleType, params:TParams, fields:Array<ClassField>}>) {
		this.curclass = curclass;
		this.tthis = tthis;
		this.getBuildInfos = getBuildInfos;
	}

	public inline function clone():TyperClass return new TyperClass(curclass, tthis, getBuildInfos);
}

enum BuildKind {
	BuildNormal;
	BuildGeneric(cls:TClass);
	BuildGenericBuild;
	BuildMacroType;
}

@:structInit class BuildInfo {
	public var buildKind:BuildKind;
	public var buildPath:GlobalTypePath;
	public var buildParams:TypeParams;
	public var buildExtern:Bool;
	public var buildApply:TParams->T;

	public inline function new(buildKind:BuildKind, buildPath:GlobalTypePath, buildParams:TypeParams, buildExtern:Bool,
			buildApply:TParams->T) {
		this.buildKind = buildKind;
		this.buildPath = buildPath;
		this.buildParams = buildParams;
		this.buildExtern = buildExtern;
		this.buildApply = buildApply;
	}

	public inline function clone():BuildInfo return new BuildInfo(buildKind, buildPath, buildParams, buildExtern, buildApply);
}

enum MacroResult {
	MSuccess(expr:Expr);
	MError;
	MMacroInMacro;
}

@:structInit class TyperPassTasks {
	public var tasks:Array<Void->Void>;
	public var tasksLate:Array<Void->Void>;

	public inline function new(tasks:Array<Void->Void>, tasksLate:Array<Void->Void>) {
		this.tasks = tasks;
		this.tasksLate = tasksLate;
	}

	public inline function clone():TyperPassTasks return new TyperPassTasks(tasks, tasksLate);
}

enum FunctionMode {
	FunFunction;
	FunCoroutine;
	FunNotFunction;
}

@:structInit class CallArgContext {
	public var cacInOverload:Bool;
	public var cacBodyCapture:{value:Array<core.Message.CompilerMessage>};

	public inline function new(cacInOverload:Bool, cacBodyCapture:{value:Array<core.Message.CompilerMessage>}) {
		this.cacInOverload = cacInOverload;
		this.cacBodyCapture = cacBodyCapture;
	}

	public inline function clone():CallArgContext return new CallArgContext(cacInOverload, cacBodyCapture);
}

@:structInit class TyperGlobals {
	public var delayed:Array<TyperPassTasks>;
	public var delayedMinIndex:Int;
	public var debugDelayed:Array<Dynamic>;
	public var retainMeta:Bool;
	public var coreApi:Null<Typer>;
	public var macros:Null<{finalize:Void->Void, typer:Typer}>;
	public var moduleCheckPolicies:Array<{pack:Array<String>, policies:Array<ModuleCheckPolicy>, recursive:Bool}>;
	public var globalUsing:Array<{cls:TClass, pos:Pos}>;
	public var complete:Bool;
	public var typeHints:Array<{display:ModuleDefDisplay, pos:Pos, type:T}>;
	public var loadOnlyCachedModules:Bool;
	public var returnPartialType:Bool;
	public var buildCount:Int;
	public var tDynamicDef:T;
	public var delayedDisplay:Null<core.DisplayTypes.DisplayExceptionKind>;
	public var callArgContext:Null<CallArgContext>;
	public var rootTyper:Typer;
	public var continuationApi:Null<coro.ContTypes.ContinuationApi>;
	public var doMacro:Typer->MacroMode->GlobalTypePath->String->Array<Expr>->Pos->MacroResult;
	public var doLoadMacro:Typer->Bool->GlobalTypePath->String->Pos->typing.MacroContext.MacroMethod;
	public var doLoadModule:(ctx:Typer, path:GlobalTypePath, p:Pos, ?origin:ModuleDepOrigin) -> ModuleDef;
	public var doLoadTypeDef:Typer->Pos->TypePath->ModuleType;
	public var getBuildInfo:Typer->ModuleType->Pos->BuildInfo;
	public var doFormatString:Typer->String->Pos->Expr;
	public var doLoadCoreClass:Typer->TClass->TClass;

	// No explicit constructor: 25 arguments exceed the HashLink JIT limit.
	public function clone():TyperGlobals return {
		delayed: delayed,
		delayedMinIndex: delayedMinIndex,
		debugDelayed: debugDelayed,
		retainMeta: retainMeta,
		coreApi: coreApi,
		macros: macros,
		moduleCheckPolicies: moduleCheckPolicies,
		globalUsing: globalUsing,
		complete: complete,
		typeHints: typeHints,
		loadOnlyCachedModules: loadOnlyCachedModules,
		returnPartialType: returnPartialType,
		buildCount: buildCount,
		tDynamicDef: tDynamicDef,
		delayedDisplay: delayedDisplay,
		callArgContext: callArgContext,
		rootTyper: rootTyper,
		continuationApi: continuationApi,
		doMacro: doMacro,
		doLoadMacro: doLoadMacro,
		doLoadModule: doLoadModule,
		doLoadTypeDef: doLoadTypeDef,
		getBuildInfo: getBuildInfo,
		doFormatString: doFormatString,
		doLoadCoreClass: doLoadCoreClass
	};
}

@:structInit class TyperExpr {
	public var curfun:CurrentFun;
	public var functionMode:FunctionMode;
	public var ret:T;
	public var opened:Array<TAnon>;
	public var monomorphs:Array<{mono:TMono, pos:Pos}>;
	public var inLoop:Bool;
	public var bypassAccessor:Int;
	public var withTypeStack:Array<core.WithType.WithTypeValue>;
	public var callArgumentStack:Array<Array<Expr>>;
	public var macroDepth:Int;

	public inline function new(curfun:CurrentFun, functionMode:FunctionMode, ret:T, opened:Array<TAnon>,
			monomorphs:Array<{mono:TMono, pos:Pos}>, inLoop:Bool, bypassAccessor:Int, withTypeStack:Array<core.WithType.WithTypeValue>,
			callArgumentStack:Array<Array<Expr>>, macroDepth:Int) {
		this.curfun = curfun;
		this.functionMode = functionMode;
		this.ret = ret;
		this.opened = opened;
		this.monomorphs = monomorphs;
		this.inLoop = inLoop;
		this.bypassAccessor = bypassAccessor;
		this.withTypeStack = withTypeStack;
		this.callArgumentStack = callArgumentStack;
		this.macroDepth = macroDepth;
	}

	public inline function clone():TyperExpr return new TyperExpr(curfun, functionMode, ret, opened, monomorphs, inLoop, bypassAccessor,
		withTypeStack, callArgumentStack, macroDepth);
}

@:structInit class TyperField {
	public var curfield:TClassField;
	public var locals:PersistentMap<String, TVar>;
	public var vthis:Null<TVar>;
	public var isUntyped:Bool;
	public var meta:Metadata;
	public var inDisplay:Bool;
	public var inCallArgs:Bool;

	public inline function new(curfield:TClassField, locals:PersistentMap<String, TVar>, vthis:Null<TVar>, isUntyped:Bool, meta:Metadata,
			inDisplay:Bool, inCallArgs:Bool) {
		this.curfield = curfield;
		this.locals = locals;
		this.vthis = vthis;
		this.isUntyped = isUntyped;
		this.meta = meta;
		this.inDisplay = inDisplay;
		this.inCallArgs = inCallArgs;
	}

	public inline function clone():TyperField return new TyperField(curfield, locals, vthis, isUntyped, meta, inDisplay, inCallArgs);
}

@:structInit class Typer {
	public var com:context.Common.CommonContext;
	public var t:BasicTypes;
	public var g:TyperGlobals;
	public var m:TyperModule;
	public var c:TyperClass;
	public var f:TyperField;
	public var e:TyperExpr;
	public var pass:TyperPass;
	public var typeParams:TypeParams;
	public var allowInline:Bool;
	public var allowTransform:Bool;
	public var memoryMarker:Array<Float>;

	public inline function new(com:context.Common.CommonContext, t:BasicTypes, g:TyperGlobals, m:TyperModule, c:TyperClass, f:TyperField,
			e:TyperExpr, pass:TyperPass, typeParams:TypeParams, allowInline:Bool, allowTransform:Bool, memoryMarker:Array<Float>) {
		this.com = com;
		this.t = t;
		this.g = g;
		this.m = m;
		this.c = c;
		this.f = f;
		this.e = e;
		this.pass = pass;
		this.typeParams = typeParams;
		this.allowInline = allowInline;
		this.allowTransform = allowTransform;
		this.memoryMarker = memoryMarker;
	}

	public inline function clone():Typer return new Typer(com, t, g, m, c, f, e, pass, typeParams, allowInline, allowTransform,
		memoryMarker);
}

enum FieldHost {
	FHStatic(cls:TClass);
	FHInstance(cls:TClass, params:TParams);
	FHAbstract(abs:TAbstract, params:TParams, cls:TClass);
	FHAnon;
}

@:structInit class FieldAccess {
	public var faOn:TExpr;
	public var faField:TClassField;
	public var faHost:FieldHost;
	public var faInline:Bool;
	public var faPos:Pos;
	public var faFieldPos:Null<Pos>;

	public inline function new(faOn:TExpr, faField:TClassField, faHost:FieldHost, faInline:Bool, faPos:Pos, faFieldPos:Null<Pos>) {
		this.faOn = faOn;
		this.faField = faField;
		this.faHost = faHost;
		this.faInline = faInline;
		this.faPos = faPos;
		this.faFieldPos = faFieldPos;
	}

	public inline function clone():FieldAccess return new FieldAccess(faOn, faField, faHost, faInline, faPos, faFieldPos);
}

@:structInit class StaticExtensionAccess {
	public var seThis:TExpr;
	public var seAccess:FieldAccess;

	public inline function new(seThis:TExpr, seAccess:FieldAccess) {
		this.seThis = seThis;
		this.seAccess = seAccess;
	}

	public inline function clone():StaticExtensionAccess return new StaticExtensionAccess(seThis, seAccess);
}

enum DotPathPartCase {
	PUppercase;
	PLowercase;
}

@:structInit class DotPathPart {
	public var name:String;
	public var caseKind:DotPathPartCase;
	public var pos:Pos;

	public inline function new(name:String, caseKind:DotPathPartCase, pos:Pos) {
		this.name = name;
		this.caseKind = caseKind;
		this.pos = pos;
	}

	public inline function clone():DotPathPart return new DotPathPart(name, caseKind, pos);
}

class ForbidPackage extends haxe.Exception {
	public final forbidden:{name:String, path:GlobalTypePath, pos:Pos};
	public final positions:Array<Pos>;
	public final reason:String;

	public function new(forbidden, positions, reason) {
		super(reason);
		this.forbidden = forbidden;
		this.positions = positions;
		this.reason = reason;
	}
}

class WithTypeError extends haxe.Exception {
	public final error:core.Error.CompilerError;

	// The message is what Printexc.to_string prints for the uncaught OCaml exception.
	public function new(error:core.Error.CompilerError) {
		super("Typecore.WithTypeError(_)");
		this.error = error;
	}
}

class TyperManager {
	public static function create(ctx:Typer, m:TyperModule, c:TyperClass, f:TyperField, e:TyperExpr, pass:TyperPass,
			params:TypeParams):Typer {
		if (Typecore.passIndex(pass) < Typecore.passIndex(ctx.pass)) throw "Bad context clone from "
			+ Globals.sTypePath(ctx.m.curmod.mPath) + "(" + Typecore.passName(ctx.pass) + ") to " + Globals.sTypePath(m.curmod.mPath)
			+ "(" + Typecore.passName(pass) + ")";
		return {
			com: ctx.com,
			g: ctx.g,
			t: ctx.com.basic,
			m: m,
			c: c,
			f: f,
			e: e,
			pass: pass,
			allowInline: ctx.allowInline,
			allowTransform: ctx.allowTransform,
			typeParams: params,
			memoryMarker: Typecore.memoryMarker
		};
	}

	public static function createCtxC(c:TClass):TyperClass return {
		curclass: c,
		tthis: switch c.clKind {
			case KAbstractImpl(a): switch a.aThis {
					case TMono(r) if (r.tmType == null): TAbstract(a, core.TFunctions.extractParamTypes(c.clParams));
					case t: t;
				}
			case _: TInst(c, core.TFunctions.extractParamTypes(c.clParams));
		},
		getBuildInfos: function() return null
	};

	public static function createCtxF(cf:TClassField):TyperField return {
		locals: PersistentMap.empty(),
		curfield: cf,
		vthis: null,
		isUntyped: false,
		meta: [],
		inDisplay: false,
		inCallArgs: false
	};

	public static function createCtxE(curfun:CurrentFun, functionMode:FunctionMode):TyperExpr return {
		curfun: curfun,
		functionMode: functionMode,
		ret: core.TFunctions.tDynamic,
		opened: [],
		monomorphs: [],
		inLoop: false,
		bypassAccessor: 0,
		withTypeStack: [],
		callArgumentStack: [],
		macroDepth: 0
	};

	public static function cloneForModule(ctx:Typer, m:TyperModule):Typer {
		var out = create(ctx, m, ctx.c, ctx.f, ctx.e, PBuildModule, []);
		out.allowTransform = true;
		out.allowInline = true;
		return out;
	}

	public static function cloneForClass(ctx:Typer, cls:TClass):Typer {
		var c = createCtxC(cls);
		var params = switch cls.clKind {
			case KAbstractImpl(a): a.aParams;
			case _: cls.clParams;
		};
		return create(ctx, ctx.m, c, ctx.f, ctx.e, PBuildClass, params);
	}

	public static function cloneForEnum(ctx:Typer,
			en:TEnum):Typer return create(ctx, ctx.m, createCtxC(core.TFunctions.nullClass), ctx.f, ctx.e, PBuildClass, en.eParams);

	public static function cloneForTypedef(ctx:Typer,
			td:TDef):Typer return create(ctx, ctx.m, createCtxC(core.TFunctions.nullClass), ctx.f, ctx.e, PBuildClass, td.tParams);

	public static function cloneForAbstract(ctx:Typer,
			a:TAbstract):Typer return create(ctx, ctx.m, createCtxC(core.TFunctions.nullClass), ctx.f, ctx.e, PBuildClass, a.aParams);

	public static function cloneForField(ctx:Typer, cf:TClassField,
			params:TypeParams):Typer return create(ctx, ctx.m, ctx.c, createCtxF(cf), ctx.e, PBuildClass, params);

	public static function cloneForEnumField(ctx:Typer,
			params:TypeParams):Typer return create(ctx, ctx.m, ctx.c, createCtxF(core.TFunctions.nullField), ctx.e, PBuildClass, params);

	public static function cloneForExpr(ctx:Typer, curfun:CurrentFun, inFunction:FunctionMode):Typer {
		var e = createCtxE(curfun, inFunction);
		switch curfun {
			case FunMember, FunMemberAbstract, FunStatic, FunConstructor:
				e.monomorphs = ctx.e.monomorphs;
				ctx.e.monomorphs = [];
			case FunMemberAbstractLocal, FunMemberClassLocal:
		}
		return create(ctx, ctx.m, ctx.c, ctx.f, e, PTypeField, ctx.typeParams);
	}

	public static function cloneForTypeParams(ctx:Typer,
			params:TypeParams):Typer return create(ctx, ctx.m, ctx.c, ctx.f, ctx.e, ctx.pass, params);

	public static function cloneForTypeParameterExpression(ctx:Typer):Typer return create(ctx, ctx.m, ctx.c, createCtxF(ctx.f.curfield),
		createCtxE(ctx.e.curfun, FunNotFunction), PTypeField, ctx.typeParams);

	public static function isCoroutineContext(ctx:Typer):Bool return ctx.e.functionMode == FunCoroutine;

	public static function isFunctionContext(ctx:Typer):Bool return switch ctx.e.functionMode {
		case FunFunction, FunCoroutine: true;
		case FunNotFunction: false;
	};
}

class Typecore {
	public static final memoryMarker:Array<Float> = [Sys.time()];
	public static var makeCallRef:(ctx:Typer, e:TExpr, el:Array<TExpr>, t:T, p:Pos,
		?forceInline:Bool) -> TExpr = function(ctx, e, el, t, p, ?forceInline) throw "makeCallRef is not initialized";
	public static var typeExprRef:(ctx:Typer, e:core.Ast.Expr, withType:core.WithType.WithTypeValue,
		?mode:AccessMode) -> TExpr = function(ctx, e, withType, ?mode) throw "typeExprRef is not initialized";
	public static var typeBlockRef:(ctx:Typer, el:Array<Expr>, withType:core.WithType.WithTypeValue,
		p:Pos) -> TExpr = function(ctx, el, withType, p) throw "typeBlockRef is not initialized";
	public static var unifyMinRef:(ctx:Typer, el:Array<TExpr>) -> T = function(ctx, el) throw "unifyMinRef is not initialized";
	public static var unifyMinForTypeSourceRef:(ctx:Typer, el:Array<TExpr>,
		src:Null<core.WithType.WithTypeSource>) -> T = function(ctx, el, src) throw "unifyMinForTypeSourceRef is not initialized";
	public static var analyzerRunOnExprRef:(com:context.Common.CommonContext, name:String,
		e:TExpr) -> TExpr = function(com, name, e) throw "analyzerRunOnExprRef is not initialized";
	public static var castOrUnifyRaiseRef:(ctx:Typer, t:T, e:TExpr, p:Pos,
		?uctx:core.TUnification.UnificationContext) -> TExpr = function(ctx, t, e, p, ?uctx) throw "castOrUnifyRaiseRef is not initialized";
	public static var typeGenericFunctionRef:(ctx:Typer, access:FieldAccess,
		candidate:typing.FieldCallCandidate.FieldCallCandidateData<Void->TExpr>, withType:core.WithType.WithTypeValue,
		p:Pos) -> TExpr = function(ctx, access, candidate, withType, p) throw "typeGenericFunctionRef is not initialized";
	public static var createContextRef:(com:context.Common.CommonContext,
		macros:Null<{finalize:Void->Void, typer:Typer}>) -> Typer = function(com, macros) throw "createContextRef is not initialized";

	public static function passIndex(p:TyperPass):Int return StdType.enumIndex(p);

	public static function passName(p:TyperPass):String return switch p {
		case PBuildModule: "build-module";
		case PBuildClass: "build-class";
		case PConnectField: "connect-field";
		case PTypeField: "type-field";
		case PCheckConstraint: "check-constraint";
		case PForce: "force";
		case PFinal: "final";
	};

	public static function makeBuildInfo(kind:BuildKind, path:GlobalTypePath, params:TypeParams, isExtern:Bool,
			apply:TParams->T):BuildInfo return {
			buildKind: kind,
			buildPath: path,
			buildParams: params,
			buildExtern: isExtern,
			buildApply: apply
		};

	public static function warning(ctx:Typer, w:WarningCode, msg:String, p:Pos, depth:Int = 0):Void {
		var options = Warning.fromMeta(ctx.f.curfield.cfMeta).concat(Warning.fromMeta(ctx.c.curclass.clMeta));
		switch Warning.getMode(w, options) {
			case WMEnable:
				Common.moduleWarning(ctx.com, ctx.m.curmod, w, options, msg, p);
			case WMDisable:
		}
	}

	public static function makeCall(ctx:Typer, e:TExpr, el:Array<TExpr>, t:T, p:Pos):TExpr return makeCallRef(ctx, e, el, t, p);

	public static function typeExpr(ctx:Typer, e:Expr, withType:core.WithType.WithTypeValue,
			?mode:AccessMode):TExpr return typeExprRef(ctx, e, withType, mode == null ? MGet : mode);

	public static function unifyMin(ctx:Typer, el:Array<TExpr>):T return unifyMinRef(ctx, el);

	public static function unifyMinForTypeSource(ctx:Typer, el:Array<TExpr>,
			src:Null<core.WithType.WithTypeSource>):T return unifyMinForTypeSourceRef(ctx, el, src);

	public static function spawnMonomorphRaw(ctx:Typer, p:Pos):TMono {
		var mono = Monomorph.create();
		ctx.e.monomorphs = [{mono: mono, pos: p}].concat(ctx.e.monomorphs);
		return mono;
	}

	public static function spawnMonomorph(ctx:Typer, p:Pos):T return TMono(spawnMonomorphRaw(ctx, p));

	public static function monomorphTransaction(ctx:Typer):Void->Void {
		var current = ctx.e.monomorphs;
		var known:Array<{mono:TMono, constraints:Array<TMonoConstraint>}> = [];
		for (entry in current) if (entry.mono.tmType == null) known.unshift({mono: entry.mono, constraints: entry.mono.tmDownConstraints});
		return function() {
			for (entry in known) {
				if (entry.mono.tmType != null) entry.mono.tmType = null;
				if (entry.constraints != entry.mono.tmDownConstraints) entry.mono.tmDownConstraints = entry.constraints;
			}
			ctx.e.monomorphs = current;
		};
	}

	public static function makeStaticFieldAccess(c:TClass, cf:TClassField, t:T,
			p:Pos):TExpr return core.TFunctions.mk(TField(core.Texpr.Builder.makeStaticThis(c, p), FStatic(c, cf)), t, p);

	public static function enterCallArgs(ctx:Typer, inOverload:Bool):Void->Void {
		var oldInCallArgs = ctx.f.inCallArgs;
		var oldContext = ctx.g.callArgContext;
		ctx.f.inCallArgs = true;
		ctx.g.callArgContext = {cacInOverload: inOverload, cacBodyCapture: {value: []}};
		return function() {
			ctx.f.inCallArgs = oldInCallArgs;
			ctx.g.callArgContext = oldContext;
		};
	}

	public static function inOverloadCallArgs(ctx:Typer):Bool return ctx.g.callArgContext != null && ctx.g.callArgContext.cacInOverload;

	public static function resetCallArgBodyCapture(ctx:Typer):{value:Array<core.Message.CompilerMessage>} {
		var buf = {value: []};
		if (ctx.g.callArgContext != null) ctx.g.callArgContext.cacBodyCapture = buf;
		return buf;
	}

	public static function callArgBodyCapture(ctx:Typer):Null<{value:Array<core.Message.CompilerMessage>}>
		return ctx.g.callArgContext == null ? null : ctx.g.callArgContext.cacBodyCapture;

	public static function raiseWithTypeError(msg:String, p:Pos):Dynamic throw new WithTypeError(Error.makeError(Custom(msg), p));

	public static function raiseOrDisplay(ctx:Typer, l:Array<core.TUnification.UnifyError>, p:Pos):Void {
		if (ctx.f.isUntyped) return;
		if (ctx.f.inCallArgs) throw new WithTypeError(Error.makeError(Unify(l), p));
		Common.displayErrorExt(ctx.com, Error.makeError(Unify(l), p));
	}

	public static function raiseOrDisplayError(ctx:Typer, err:core.Error.CompilerError):Void {
		if (ctx.f.isUntyped) return;
		if (ctx.f.inCallArgs) throw new WithTypeError(err);
		Common.displayErrorExt(ctx.com, err);
	}

	public static function raiseOrDisplayMessage(ctx:Typer, msg:String, p:Pos):Void {
		if (ctx.f.inCallArgs) raiseWithTypeError(msg, p);
		else Common.displayError(ctx.com, msg, p);
	}

	public static function unify(ctx:Typer, t1:T, t2:T, p:Pos):Void {
		try TUnification.unify(t1, t2)
		catch (err:core.TUnification.Unify_error) raiseOrDisplay(ctx, err.errors, p);
	}

	public static function unifyRaiseCustom(uctx:core.TUnification.UnificationContext, t1:T, t2:T, p:Pos):Void {
		try TUnification.unifyCustom(uctx, t1, t2)
		catch (err:core.TUnification.Unify_error) Error.raiseErrorMsg(Unify(err.errors), p);
	}

	public static function unifyRaise(a:T, b:T, p:Pos):Void unifyRaiseCustom(TUnification.defaultUnificationContext(), a, b, p);

	public static function saveLocals(ctx:Typer):Void->Void {
		var locals = ctx.f.locals;
		return function() ctx.f.locals = locals;
	}

	public static function addLocal(ctx:Typer, k:TVarKind, n:String, t:T, p:Pos):TVar {
		var v = core.TFunctions.allocVar(k, n, t, p);
		if (n != "_") switch k {
			case VUser(_):
				try {
					var previous = ctx.f.locals.find(n);
					var inStd = false;
					for (path in ctx.com.classPaths.getStdPaths()) if (StringTools.startsWith(p.pfile, path.path)) {
						inStd = true;
						break;
					}
					if (!inStd) {
						warning(ctx, WVarShadow, "This variable shadows a previously declared variable", p);
						warning(ctx, WVarShadow, core.Error.complMsg("Previous variable was here"), previous.vPos, 1);
					}
				} catch (_:NotFound) {}
			case _:
		}
		ctx.f.locals = ctx.f.locals.add(n, v);
		return v;
	}

	public static function addLocalWithOrigin(ctx:Typer, origin:TVarOrigin, n:String, t:T, p:Pos):TVar {
		core.Naming.checkLocalVariableName(ctx.com, n, origin, p);
		return addLocal(ctx, VUser(origin), n, t, p);
	}

	public static function genLocal(ctx:Typer, t:T, p:Pos):TVar return addLocal(ctx, VGenerated, Globals.genLocalPrefix, t, p);

	public static function isGenLocal(v:TVar):Bool return switch v.vKind {
		case VGenerated: true;
		case _: false;
	};

	// Task lists are stacks with the top at the end of the array (upstream conses onto
	// lists; unshift/shift at the front were quadratic). Same order.
	public static function delay(g:TyperGlobals, p:TyperPass, f:Void->Void):Void {
		var index = passIndex(p);
		var tasks = g.delayed[index];
		tasks.tasks.push(f);
		if (index < g.delayedMinIndex) g.delayedMinIndex = index;
	}

	public static function delayLate(g:TyperGlobals, p:TyperPass, f:Void->Void):Void {
		var index = passIndex(p);
		var tasks = g.delayed[index];
		tasks.tasksLate.push(f);
		if (index < g.delayedMinIndex) g.delayedMinIndex = index;
	}

	public static function delayIfMono(g:TyperGlobals, p:TyperPass, t:T, f:Void->Void):Void switch core.TFunctions.follow(t) {
		case TMono(_):
			delay(g, p, f);
		case _:
			f();
	}

	// `where` is polymorphic and unused upstream (debug information only).
	public static function flushPass<W>(g:TyperGlobals, p:TyperPass, where:W):Void {
		var index = g.delayedMinIndex;
		while (index <= passIndex(p)) {
			var tasks = g.delayed[index];
			if (tasks.tasks.length != 0) {
				var f = tasks.tasks.pop();
				f();
				flushPass(g, p, where);
				return;
			} else if (tasks.tasksLate.length != 0) {
				tasks.tasks = tasks.tasksLate.copy();
				tasks.tasks.reverse();
				tasks.tasksLate = [];
				flushPass(g, p, where);
				return;
			} else {
				index++;
				g.delayedMinIndex = index;
			}
		}
	}

	public static function makePass<T>(ctx:Typer, f:T):T return f;

	public static function enterFieldTypingPass<W>(g:TyperGlobals, info:W):Void flushPass(g, PConnectField, info);

	public static function makeLazy(ctx:TyperGlobals, tProc:T, f:Void->T, where:String):TLazy {
		var r = Common.makeUnforcedLazy(tProc, f, where);
		delay(ctx, PForce, function() {
			core.TFunctions.lazyType(r);
		});
		return r;
	}

	public static function isForcedInline(c:Null<TClass>, cf:TClassField):Bool {
		if (c != null) {
			switch c.clKind {
				case KAbstractImpl(_):
					return true;
				case _:
			}
			if (core.TFunctions.hasClassFlag(c, CExtern)) return true;
		}
		return core.TFunctions.hasClassFieldFlag(cf, CfExtern);
	}

	public static function needsInline(ctx:Typer, c:Null<TClass>, cf:TClassField):Bool return switch cf.cfKind {
		case Method(MethInline): ctx.allowInline && (ctx.com.doinline || isForcedInline(c, cf));
		case _: false;
	};

	public static function canAccess(ctx:Typer, c:TClass, cf:TClassField, stat:Bool, checkProp:Bool = false, isSetter:Bool = false):Bool {
		var isPrivateProp = checkProp && switch cf.cfKind {
			case Var({vRead: AccPrivateCall}) if (!isSetter): true;
			case Var({vWrite: AccPrivateCall}) if (isSetter): true;
			case _: false;
		};
		if (!isPrivateProp && core.TFunctions.hasClassFieldFlag(cf, CfPublic)) return true;
		if (c == ctx.c.curclass) return true;
		if (ctx.m.curmod.mStatics != null && c == ctx.m.curmod.mStatics) return true;
		function makePath(c:TClass, f:TClassField):Array<String> return switch c.clKind {
			case KAbstractImpl(a): a.aPath.pack.concat([a.aPath.name, f.cfName]);
			case KGenericInstance(c, _): makePath(c, f);
			case _ if (c.clPrivate): c.clPath.pack.slice(0, -1).concat([c.clPath.name, f.cfName]);
			case _: c.clPath.pack.concat([c.clPath.name, f.cfName]);
		};
		function exprPath(acc:Array<String>, e:Expr):Array<String> return switch e.expr {
			case EField(e, f, _): exprPath([f].concat(acc), e);
			case EConst(Ident(n)): [n].concat(acc);
			case _: [];
		};
		function chkPath(sub:Array<String>, full:Array<String>, isCurrentPath:Bool):Bool {
			for (i in 0...sub.length) {
				if (i >= full.length || sub[i] != full[i]) return false;
				if (!isCurrentPath && i == sub.length - 1 && !core.StringHelper.startsUppercaseIdentifier(sub[i])) return false;
			}
			return true;
		}
		inline function has(meta:StrictMeta, c:TClass, f:TClassField, entry:{path:Array<String>, isCurrent:Bool}):Bool {
			function loop(metadata:Metadata):Bool {
				for (m in metadata) if (m.meta == meta) for (e in m.exprs) switch e.expr {
					case EConst(Ident("std")):
						if (entry.path.length == 2) return true;
					case _:
						var p = exprPath([], e);
						if (p.length != 0 && chkPath(p, entry.path, entry.isCurrent)) return true;
				}
				return false;
			}
			return loop(c.clMeta) || loop(f.cfMeta);
		}
		var modulePath = ctx.c.curclass.clModule.mPath;
		var curPaths:Array<{path:Array<String>, isCurrent:Bool}> = [{path: modulePath.pack.concat([modulePath.name]), isCurrent: false}];
		function collect(c:TClass, isCurrentPath:Bool):Void {
			curPaths.unshift({path: makePath(c, ctx.f.curfield), isCurrent: isCurrentPath});
			if (c.clSuper != null) collect(c.clSuper.cls, false);
			for (implemented in c.clImplements) collect(implemented.cls, false);
		}
		collect(ctx.c.curclass, true);
		var isConstr = cf.cfName == "new";
		function loop(c:TClass):Bool {
			try {
				if (has(StrictMeta.Access, ctx.c.curclass, ctx.f.curfield, {path: makePath(c, cf), isCurrent: true})) return true;
				function allowed(f:TClassField):Bool {
					if (core.TFunctions.extendsClass(ctx.c.curclass, c)) return true;
					for (p in curPaths) if (has(StrictMeta.Allow, c, f, p)) return true;
					return false;
				}
				var found = false;
				if (isConstr) {
					var constructor = c.clConstructor;
					if (constructor != null) {
						if (allowed(constructor)) found = true;
						else if (constructor.cfExpr != null) throw NotFound.raise();
					}
				} else {
					var field = (stat ? c.clStatics : c.clFields).get(cf.cfName);
					if (field != null) found = allowed(field);
				}
				return found || (c.clSuper != null && loop(c.clSuper.cls));
			} catch (_:NotFound) return false;
		}
		if (loop(c)) return true;
		switch c.clKind {
			case KTypeParameter(ttp):
				for (t in core.TFunctions.getConstraints(ttp)) switch core.TFunctions.follow(t) {
					case TInst(c, _): if (loop(c)) return true;
					case _:
				}
			case _:
		}
		return MetadataTools.has(StrictMeta.PrivateAccess, ctx.f.meta);
	}

	public static function checkFieldAccess(ctx:Typer, c:TClass, f:TClassField, stat:Bool, p:Pos):Void {
		if (!ctx.f.isUntyped && !canAccess(ctx, c, f, stat)) Common.displayError(ctx.com, "Cannot access private field " + f.cfName, p);
	}

	public static function prepareUsingField(cf:TClassField):TClassField return switch core.TFunctions.follow(cf.cfType) {
		case TFun(sig) if (sig.args.length > 0):
			var tf = sig.args[0].type;
			var overloads:Array<TClassField> = [];
			for (cfo in cf.cfOverloads) switch cfo.cfType {
				case TFun(overloadSig) if (overloadSig.args.length > 0):
					var tfo = core.TFunctions.applyParams(cfo.cfParams, core.TFunctions.extractParamTypes(cfo.cfParams),
						overloadSig.args[0].type);
					if (TUnification.typeIseq(tf, tfo)) {
						var copy:TClassField = core.ds.Record.copy(cfo);
						copy.cfType = TFun({args: overloadSig.args.slice(1), ret: overloadSig.ret});
						overloads.unshift(copy);
					}
				case _:
			}
			var out:TClassField = core.ds.Record.copy(cf);
			out.cfOverloads = overloads;
			out.cfType = TFun({args: sig.args.slice(1), ret: sig.ret});
			out;
		case _: cf;
	};

	public static function mergeCoreDoc(ctx:Typer, mt:ModuleType):Void {
		var c:Null<TClass> = switch mt {
			case TClassDecl(c): c;
			case TAbstractDecl(a): a.aImpl;
			case _: null;
		};
		if (c == null || !MetadataTools.has(StrictMeta.CoreApi, c.clMeta)) return;
		var core = ctx.g.doLoadCoreClass(ctx, c);
		if (c.clDoc == null) c.clDoc = core.clDoc;
		inline function maybeMerge(map:TypeMap<TClassField>, cf:TClassField):Void {
			if (cf.cfDoc == null) {
				var other = map.get(cf.cfName);
				if (other != null) cf.cfDoc = other.cfDoc;
			}
		}
		for (cf in c.clOrderedFields) maybeMerge(core.clFields, cf);
		for (cf in c.clOrderedStatics) maybeMerge(core.clStatics, cf);
		if (c.clConstructor != null && c.clConstructor.cfDoc == null && core.clConstructor != null)
			c.clConstructor.cfDoc = core.clConstructor.cfDoc;
	}

	public static function safeMonoClose(ctx:Typer, m:TMono, p:Pos):Void {
		try Monomorph.close(m)
		catch (err:core.TUnification.Unify_error) raiseOrDisplay(ctx, err.errors, p);
	}

	public static function relativePath(ctx:Typer, file:String):String return ctx.com.classPaths.relativePath(file);

	public static function mkInfosT(ctx:Typer, p:Pos, params:Array<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>,
			t:T):TExpr {
		var file = ctx.com.isMacroContext ? p.pfile : Common.defined(ctx.com,
			core.Define.AbsolutePath) ? core.Path.getFullPath(p.pfile) : relativePath(ctx, p.pfile);
		var line = syntax.Lexer.getErrorLine(p);
		var className = Globals.sTypePath(ctx.c.curclass.clPath);
		var fields = [
			{key: {name: "fileName", pos: Globals.nullPos, quote: NoQuotes}, expr: core.Texpr.Builder.makeString(ctx.com.basic, file, p)},
			{key: {name: "lineNumber", pos: Globals.nullPos, quote: NoQuotes}, expr: core.Texpr.Builder.makeInt(ctx.com.basic, line, p)},
			{
				key: {name: "className", pos: Globals.nullPos, quote: NoQuotes},
				expr: core.Texpr.Builder.makeString(ctx.com.basic, className, p)
			}
		];
		if (ctx.f.curfield.cfName != "") fields.push({
			key: {name: "methodName", pos: Globals.nullPos, quote: NoQuotes},
			expr: core.Texpr.Builder.makeString(ctx.com.basic, ctx.f.curfield.cfName, p)
		});
		return core.TFunctions.mk(TObjectDecl(fields.concat(params)), t, p);
	}

	public static function mkInfos(ctx:Typer, p:Pos, params:Array<ObjectField>):Expr {
		var file = ctx.com.isMacroContext ? p.pfile : Common.defined(ctx.com,
			core.Define.AbsolutePath) ? core.Path.getFullPath(p.pfile) : relativePath(ctx, p.pfile);
		var fields:Array<ObjectField> = [
			{key: {name: "fileName", pos: Globals.nullPos, quote: NoQuotes}, expr: {expr: EConst(String(file, SDoubleQuotes)), pos: p}},
			{
				key: {name: "lineNumber", pos: Globals.nullPos, quote: NoQuotes},
				expr: {expr: EConst(Int(Std.string(syntax.Lexer.getErrorLine(p)), null)), pos: p}
			},
			{
				key: {name: "className", pos: Globals.nullPos, quote: NoQuotes},
				expr: {expr: EConst(String(Globals.sTypePath(ctx.c.curclass.clPath), SDoubleQuotes)), pos: p}
			}
		];
		if (ctx.f.curfield.cfName != "") fields.push({
			key: {name: "methodName", pos: Globals.nullPos, quote: NoQuotes},
			expr: {expr: EConst(String(ctx.f.curfield.cfName, SDoubleQuotes)), pos: p}
		});
		return {expr: EObjectDecl(fields.concat(params)), pos: p};
	}

	public static function isPosInfos(t:T):Bool return switch t {
		case TMono(r): r.tmType != null && isPosInfos(r.tmType);
		case TLazy(f): isPosInfos(core.TFunctions.lazyType(f));
		case TType(td, []) if (td.tPath.pack.length == 1 && td.tPath.pack[0] == "haxe" && td.tPath.name == "PosInfos"): true;
		case TType(td, tl): isPosInfos(core.TFunctions.applyTypedef(td, tl));
		case TAbstract(a, [inner]) if (a.aPath.pack.length == 0 && a.aPath.name == "Null"): isPosInfos(inner);
		case _: false;
	};

	public static function isEmptyOrPosInfos(args:Array<{name:String, optional:Bool, type:T}>):Bool return args.length == 0
		|| (args.length == 1 && args[0].optional && isPosInfos(args[0].type));

	static var storedTypedExprUid = 0;

	public static function getNextStoredTypedExprId():Int return ++storedTypedExprUid;

	public static function makeStoredIdExpr(id:Int, p:Pos):Expr return {expr: EConst(Int(Std.string(id), null)), pos: p};

	public static function storeTypedExpr(com:context.Common.CommonContext, te:TExpr, p:Pos):{id:Int, expr:Expr} {
		var id = getNextStoredTypedExprId();
		com.partScope.storedTypedExprs.add(id, te);
		return {
			id: id,
			expr: {
				expr: EMeta({meta: StrictMeta.StoredTypedExpr, exprs: [], pos: Globals.nullPos}, makeStoredIdExpr(id, p)),
				pos: p
			}
		};
	}

	public static function pushThis(ctx:Typer, e:TExpr):{expr:Expr, restore:Void->Void}
		return switch e.eexpr {
			case TConst(ct = TInt(_)), TConst(ct = TFloat(_)), TConst(ct = TString(_)), TConst(ct = TBool(_)):
				{expr: {expr: EConst(core.TFunctions.tconstToConst(ct)), pos: e.epos}, restore: function() {}};
			case _:
				var stored = storeTypedExpr(ctx.com, e, e.epos);
				{expr: stored.expr, restore: function() ctx.com.partScope.storedTypedExprs.remove(stored.id)};
		};

	public static function createDeprecationContext(ctx:Typer):context.display.DeprecationCheck.DeprecationContext {
		var out = context.display.DeprecationCheck.createContext(ctx.com);
		out.classMeta = ctx.c.curclass.clMeta;
		out.fieldMeta = ctx.f.curfield.cfMeta;
		out.curmod = ctx.m.curmod;
		return out;
	}

	public static function getOverloads(com:context.Common.CommonContext, c:TClass, i:String):Array<CastField> {
		var key = {path: c.clPath, name: i};
		try return com.overloadCache.find(key)
		catch (_:NotFound) {
			var overloads = codegen.Overloads.collectOverloads(function(t) return t, c, i);
			com.overloadCache.add(key, overloads);
			return overloads;
		}
	}
}

package typing;

import core.Texpr;
import core.Texpr.DeadEnd;
import core.Error;
import core.Error.*;
import core.TUnification.UnifyError;
import core.TUnification.TUnification.fastEq;
import core.Timer;
import core.Warning;
import core.Message.WarningCode;
import core.Message.WarningOption;
import core.Message.WarningMode;
import core.ds.Hashtbl;
import core.ds.NotFound;
import context.Common;
import context.PurityState.PurityStateTools as PurityState;
import filters.FiltersCommon;
import syntax.Lexer;

using Lambda;
using core.ds.ArrayTools;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.TType;
import core.Ast;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;

// haxe/src/typing/nullSafety.ml — mechanical draft; not compile-validated.
typedef SafetyMessage = {var smMsg:String; var smPos:Pos; var smModule:ModuleDef;}
typedef SafetyWarning = {var swWarning:WarningCode; var swOptions:Array<Array<WarningOption>>; var swMsg:String; var swPos:Pos; var swModule:ModuleDef;}

typedef SafetyReport = {
	var srErrors:Array<SafetyMessage>;
	var srWarnings:Array<SafetyWarning>;
	var srSeenErrors:Hashtbl<{msg:String, pos:Pos, moduleId:Int}, Bool>;
	var srSeenWarnings:Hashtbl<{
		type:WarningCode,
		options:Array<Array<WarningOption>>,
		msg:String,
		pos:Pos,
		moduleId:Int
	}, Bool>;
}

enum ScopeType {
	STNormal;
	STLoop;
	STClosure;
	STImmediateClosure;
}

enum SafetyMode {
	SMOff;
	SMLoose;
	SMStrict;
	SMStrictThreaded;
}

enum SafetySubject {
	SFieldOfClass(path:core.Globals.GlobalTypePath, fields:Array<String>);
	SFieldOfLocalVar(id:Int, fields:Array<String>);
	SFieldOfThis(fields:Array<String>);
	SLocalVar(id:Int);
	SNotSuitable;
}

class SafetyUnifyError extends haxe.Exception {
	public var a:T;
	public var b:T;
	public var access:ErrorAccessKind;

	public function new(a:T, b:T, access:ErrorAccessKind) {
		super("Safety_unify_error");
		this.a = a;
		this.b = b;
		this.access = access;
	}
}

// Structural subject keys preserve field-path identity without depending on Map enumeration.
class SafetyTable {
	var entries:Array<{subject:SafetySubject, expr:TExpr}> = [];

	public function new() {}

	public static function equal(a:SafetySubject, b:SafetySubject):Bool {
		function fields(a:Array<String>, b:Array<String>):Bool {
			if (a.length != b.length) return false;
			for (i in 0...a.length) if (a[i] != b[i]) return false;
			return true;
		}
		return switch [a, b] {
			case [SFieldOfClass(a, x), SFieldOfClass(b, y)]: a.name == b.name && fields(a.pack, b.pack) && fields(x, y);
			case [SFieldOfLocalVar(a, x), SFieldOfLocalVar(b, y)]: a == b && fields(x, y);
			case [SFieldOfThis(x), SFieldOfThis(y)]: fields(x, y);
			case [SLocalVar(a), SLocalVar(b)]: a == b;
			case [SNotSuitable, SNotSuitable]: true;
			case _: false;
		};
	}

	public function has(s:SafetySubject):Bool return entries.exists(function(e) return equal(e.subject, s));

	public function set(s:SafetySubject, e:TExpr):Void {
		for (entry in entries) if (equal(entry.subject, s)) {
			entry.expr = e;
			return;
		}
		entries.push({subject: s, expr: e});
	}

	public function remove(s:SafetySubject):Void entries = entries.filter(function(e) return !equal(e.subject, s));

	public function clear():Void entries = [];

	public function all():Array<{subject:SafetySubject, expr:TExpr}> return entries.copy();

	public function copy():SafetyTable {
		var t = new SafetyTable();
		for (e in entries) t.set(e.subject, e.expr);
		return t;
	}
}

class NullSafety {
	public static function addError(report:SafetyReport, m:ModuleDef, msg:String, p:Pos):Void {
		var e = {smMsg: "Null safety: " + msg, smPos: p, smModule: m};
		var key = {msg: e.smMsg, pos: p, moduleId: m.mId};
		if (!report.srSeenErrors.mem(key)) {
			report.srSeenErrors.add(key, true);
			report.srErrors.unshift(e);
		}
	}

	public static function addWarning(report:SafetyReport, m:ModuleDef, type:WarningCode, options:Array<Array<WarningOption>>, msg:String,
			p:Pos):Void {
		var w = {
			swWarning: type,
			swOptions: options,
			swMsg: "Null safety: " + msg,
			swPos: p,
			swModule: m
		};
		var key = {
			type: type,
			options: options,
			msg: w.swMsg,
			pos: p,
			moduleId: m.mId
		};
		if (!report.srSeenWarnings.mem(key)) {
			report.srSeenWarnings.add(key, true);
			report.srWarnings.unshift(w);
		}
	}

	public static function safetyError(a:T, b:T, access:ErrorAccessKind):Void throw new SafetyUnifyError(a, b, access);

	public static function fail(hxpos:Pos, mlpos:{file:String, line:Int}, msg:Null<String> = null):Dynamic {
		var message = Lexer.getErrorPos(function(file, line) return '$file:$line:', hxpos)
			+ ": Null safety: "
			+ (msg == null ? "unexpected expression." : msg)
			+ "\nSubmit an issue to https://github.com/HaxeFoundation/haxe/issues with expression example and following information:";
		Sys.stderr().writeString(message + "\n" + mlpos.file + ":" + mlpos.line + "\n");
		return die("", "haxe/src/typing/nullSafety.ml");
	}

	static var printContext = core.TPrinting.printContext();

	public static function strType(t:T):String return core.TPrinting.sType(printContext, t);

	public static function strExpr(e:TExpr):String return core.TPrinting.sExprPretty(false, "\t", true, strType, e);

	public static function isStringType(t:T):Bool return switch t {
		case TInst({clPath: {pack: [], name: "String"}}, _) |
			TAbstract({aPath: {pack: [], name: "Null"}}, [TInst({clPath: {pack: [], name: "String"}}, _)]): true;
		case _: false;
	};

	public static function isNullableType(t:T, dynamicIsNullable:Bool = false):Bool return switch t {
		case TMono(r): r.tmType == null ? isNullableMono(r) : isNullableType(r.tmType);
		case TAbstract({aPath: {pack: [], name: "Null"}}, [_]): true;
		case TAbstract({aPath: {pack: [], name: "Any"}}, []): false;
		case TAbstract(a, tl) if (!core.Meta.has(MetaTag.CoreType, a.aMeta)): isNullableType(applyParams(a.aParams, tl, a.aThis));
		case TLazy(f): isNullableType(lazyType(f));
		case TType(td, tl): isNullableType(applyTypedef(td, tl));
		case TDynamic(_): dynamicIsNullable && t == tDynamic;
		case _: false;
	};

	public static function revealExpr(e:TExpr, staySafe:Bool = true):TExpr return switch e.eexpr {
		case TCast(inner, _) if (!staySafe || isNullableType(e.etype)): revealExpr(inner);
		case TMeta(_, inner): revealExpr(inner);
		case _: e;
	};

	public static function symbolName(e:TExpr):String return switch revealExpr(e, false).eexpr {
		case TField(_, access): fieldName(access);
		case TIdent(name): name;
		case TLocal(v): v.vName;
		case TNew(_, _, _): "new";
		case _: "";
	};

	public static function getSubject(mode:SafetyMode, e:TExpr):SafetySubject return switch Texpr.skip(e).eexpr {
		case TLocal(v): SLocalVar(v.vId);
		case TField({eexpr: TTypeExpr(_)},
			FStatic(c, cf)) if (mode != SMStrictThreaded || hasClassFieldFlag(cf, CfFinal)): SFieldOfClass(c.clPath, [cf.cfName]);
		case TField({eexpr: TConst(TThis)}, FInstance(_, _, cf) | FAnon(cf))
			if (mode != SMStrictThreaded || hasClassFieldFlag(cf, CfFinal)): SFieldOfThis([cf.cfName]);
		case TField({eexpr: TLocal(v)},
			FInstance(_, _,
				cf) | FAnon(cf)) if (mode != SMStrictThreaded || hasClassFieldFlag(cf, CfFinal)): SFieldOfLocalVar(v.vId, [cf.cfName]);
		case TField(e, FInstance(_, _, cf) | FAnon(cf)) if (mode != SMStrictThreaded): switch getSubject(mode, e) {
				case SFieldOfClass(p, fs): SFieldOfClass(p, [cf.cfName].concat(fs));
				case SFieldOfThis(fs): SFieldOfThis([cf.cfName].concat(fs));
				case SFieldOfLocalVar(id, fs): SFieldOfLocalVar(id, [cf.cfName].concat(fs));
				case _: SNotSuitable;
			}
		case TBinop(OpAssign, target, _): getSubject(mode, target);
		case _: SNotSuitable;
	};

	public static function isSuitable(mode:SafetyMode, e:TExpr):Bool return switch Texpr.skip(e).eexpr {
		case TField({eexpr: TConst(TThis)}, FInstance(_, _, _)) | TField({eexpr: TLocal(_)}, FInstance(_, _, _) | FAnon(_)) |
			TField({eexpr: TTypeExpr(_)}, FStatic(_, _)) | TLocal(_): true;
		case TField(target, FInstance(_, _, _) | FStatic(_, _) | FAnon(_)) if (mode != SMStrictThreaded): isSuitable(mode, target);
		case TBinop(OpAssign, target, _): isSuitable(mode, target);
		case _: false;
	};

	public static function getArgumentsMeta(callee:TExpr, count:Int):Array<Metadata> {
		inline function empty():Array<Metadata> return [for (_ in 0...count) []];
		return switch callee.eexpr {
			case TField(_, FAnon(cf) | FClosure(_, cf) | FStatic(_, cf) | FInstance(_, _, cf)): try {
					var meta = getMeta(MetaTag.HaxeArguments, cf.cfMeta);
					switch meta.exprs {
						case [{expr: EFunction(_, {fArgs: args})}] if (args.length == count): args.map(function(a) return a.meta);
						case _: empty();
					}
				} catch (ex:NotFound) empty();
			case TFunction(fn) if (fn.tfArgs.length == count): fn.tfArgs.map(function(a) return a.variable.vMeta);
			case _: empty();
		};
	}

	public static function isTrace(e:TExpr):Bool return switch e.eexpr {
		case TIdent("`trace") | TField(_, FStatic({clPath: {pack: ["haxe"], name: "Log"}}, {cfName: "trace"})): true;
		case _: false;
	};

	public static function unfoldNull(t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : unfoldNull(r.tmType);
		case TAbstract({aPath: {pack: [], name: "Null"}}, [t]): unfoldNull(t);
		case TAbstract(a, tl) if (!core.Meta.has(MetaTag.CoreType, a.aMeta)): unfoldNull(applyParams(a.aParams, tl, a.aThis));
		case TLazy(f): unfoldNull(lazyType(f));
		case TType(td, tl): unfoldNull(applyTypedef(td, tl));
		case _: t;
	};

	public static function accessedFieldName(access:TFieldAccess):String return switch access {
		case FInstance(_, _, cf) | FStatic(_, cf) | FAnon(cf) | FClosure(_, cf): cf.cfName;
		case FDynamic(n): n;
		case FEnum(_, ef): ef.efName;
	};

	public static function processCondition(mode:SafetyMode, condition:TExpr, nullable:TExpr->Bool,
			callback:TExpr->Void):{nulls:Array<TExpr>, notNulls:Array<TExpr>} {
		var nulls = [], notNulls = [];
		inline function add(toNulls:Bool, e:TExpr):Void {
			e = revealExpr(e);
			if (toNulls) nulls.unshift(e);
			else notNulls.unshift(e);
		}
		inline function remove(e:TExpr):Void {
			var subject = getSubject(mode, revealExpr(e));
			nulls = nulls.filter(function(e) return !SafetyTable.equal(getSubject(mode, revealExpr(e)), subject));
			notNulls = notNulls.filter(function(e) return !SafetyTable.equal(getSubject(mode, revealExpr(e)), subject));
		}
		function traverse(positive:Bool, e:TExpr):Void switch e.eexpr {
			case TUnop(Not, Prefix, e):
				traverse(!positive, e);
			case TBinop(OpAssign, checked, e) if (isSuitable(mode, checked) && nullable(e)):
				remove(checked);
			case TBlock(el):
				for (e in el) traverse(positive, e);
			case TBinop(OpEq, {eexpr: TConst(TNull)}, checked) | TBinop(OpEq, checked, {eexpr: TConst(TNull)})
				if (isSuitable(mode, checked)):
				add(positive, checked);
			case TBinop(OpNotEq, {eexpr: TConst(TNull)}, checked) | TBinop(OpNotEq, checked, {eexpr: TConst(TNull)})
				if (isSuitable(mode, checked)):
				add(!positive, checked);
			case TBinop(OpEq, e, checked) if (isSuitable(mode, checked) && !nullable(e)):
				if (positive) notNulls.unshift(checked);
			case TBinop(OpEq, checked, e) if (isSuitable(mode, checked) && !nullable(e)):
				if (positive) notNulls.unshift(checked);
			case TBinop(OpBoolAnd, left, right) if (positive):
				traverse(positive, left);
				traverse(positive, right);
			case TBinop(OpBoolAnd, left, right):
				for (_ in [left, right]) {
					var r = processCondition(mode, left, nullable, callback);
					for (e in r.notNulls) add(true, e);
				} // Upstream deliberately calls left_expr in both iterations.
			case TBinop(OpBoolOr, left, right) if (!positive):
				traverse(positive, left);
				traverse(positive, right);
			case TBinop(OpBoolOr, left, right):
				for (_ in [left, right]) {
					var r = processCondition(mode, left, nullable, callback);
					for (e in r.nulls) add(true, e);
				}
			case TParenthesis(e):
				traverse(positive, e);
			case _:
				callback(e);
		};
		traverse(true, condition);
		return {nulls: nulls, notNulls: notNulls};
	}

	public static function containsUnsafeMeta(meta:Metadata):Bool {
		for (m in meta) switch [(m.meta : MetaTag), m.exprs] {
			case [MetaTag.NullSafety, [{expr: EConst(Ident("Off"))}]]:
				return true;
			case _:
		}
		return false;
	}

	public static function containsSafeMeta(meta:Metadata):Bool {
		for (m in meta) switch [(m.meta : MetaTag), m.exprs] {
			case [MetaTag.NullSafety, []] | [
				MetaTag.NullSafety,
				[{expr: EConst(Ident("Loose" | "Strict" | "StrictThreaded"))}]
			]:
				return true;
			case _:
		}
		return false;
	}

	public static function safetyEnabled(meta:Metadata):Bool return containsSafeMeta(meta) && !containsUnsafeMeta(meta);

	public static function getSafetyMode(meta:Metadata):SafetyMode {
		var mode = SMOff;
		for (m in meta) switch [(m.meta : MetaTag), m.exprs] {
			case [MetaTag.NullSafety, [{expr: EConst(Ident("Off"))}]]:
				return SMOff;
			case [MetaTag.NullSafety, []] | [MetaTag.NullSafety, [{expr: EConst(Ident("Loose"))}]]:
				mode = SMLoose;
			case [MetaTag.NullSafety, [{expr: EConst(Ident("Strict"))}]]:
				mode = SMStrict;
			case [MetaTag.NullSafety, [{expr: EConst(Ident("StrictThreaded"))}]]:
				mode = SMStrictThreaded;
			case _:
		}
		return mode;
	}

	public static function validateSafetyMeta(report:SafetyReport, m:ModuleDef,
			meta:Metadata):Void for (entry in meta) if (Type.enumEq(entry.meta, MetaTag.NullSafety)) switch entry.exprs {
			case [] | [{expr: EConst(Ident("Off" | "Loose" | "Strict" | "StrictThreaded"))}]:
			case _:
				addError(report, m, "Invalid argument for @:nullSafety meta", entry.pos);
		}

	public static function shouldBeInitialized(cf:TClassField):Bool return !hasClassFieldFlag(cf, CfExtern) && (switch cf.cfKind {
		case Var({vRead: AccNormal | AccInline | AccNo}) | Var({vWrite: AccNormal | AccNo}): true;
		case Var(_): core.Meta.has(MetaTag.IsVar, cf.cfMeta);
		case _: false;
	});

	public static function listStartsWithList(hay:Array<String>, needle:Array<String>):Bool {
		if (needle.length > hay.length) return false;
		for (i in 0...needle.length) if (hay[i] != needle[i]) return false;
		return true;
	}

	public static function run(com:context.Common.CommonContext, types:Array<ModuleType>):Void {
		var report:SafetyReport = Timer.time(com.timerCtx, ["null safety"], function(_:Null<Bool>) {
			var r:SafetyReport = {
				srErrors: [],
				srWarnings: [],
				srSeenErrors: new Hashtbl(),
				srSeenWarnings: new Hashtbl()
			};
			var immediate = new ImmediateExecution();
			for (type in types) switch type {
				case TClassDecl(c):
					new ClassChecker(c, immediate, r, com.main.mainExpr).check();
				case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
			}
			return r;
		}, null);
		var callbacks = com.callbacks.getNullSafetyReport();
		if (callbacks.length == 0) {
			var warnings = report.srWarnings.copy();
			warnings.reverse();
			for (w in warnings) Common.moduleWarning(com, w.swModule, w.swWarning, w.swOptions, w.swMsg, w.swPos);
			var errors = report.srErrors.copy();
			errors.reverse();
			for (e in errors) Common.displayError(com, e.smMsg, e.smPos);
		} else {
			var errors = report.srErrors.map(function(e) return {msg: e.smMsg, pos: e.smPos});
			var warnings = [];
			for (w in report.srWarnings) switch Warning.getMode(w.swWarning, w.swOptions.concat(com.warningOptions)) {
				case WMEnable:
					warnings.push({warning: w.swWarning, msg: w.swMsg, pos: w.swPos});
				case WMDisable:
			}
			for (fn in callbacks) fn(errors, warnings);
		}
	}
}

class Unificator {
	var stack:Array<{a:T, b:T}> = [];

	public function new() {}

	public function unify(a:T, b:T, ?access:ErrorAccessKind):Void {
		if (access == null) access = Root;
		if (a == b) return;
		switch [a, b] {
			case [
				TAbstract({aPath: {pack: [], name: "Null"}}, [TAnon(aa)]),
				TAbstract({aPath: {pack: [], name: "Null"}}, [TAnon(ba)])
			] | [TAnon(aa), TAbstract({aPath: {pack: [], name: "Null"}}, [TAnon(ba)])]:
				unifyAnonToAnon(aa, ba);
			case [TInst(c, params), TAbstract({aPath: {pack: [], name: "Null"}}, [TAnon(ba)])]:
				unifyClassToAnon(c, params, ba);
			case [_, TAbstract({aPath: {pack: [], name: "Null"}}, [_])] | [_, TDynamic(_)]:
			case [TAbstract({aPath: {pack: [], name: "Null"}}, [_]), _] if (!NullSafety.isNullableType(b)):
				NullSafety.safetyError(a, b, access);
			case [TInst(_, pa), TInst(_, pb)] if (pa.length == pb.length):
				for (i in 0...pa.length) unify(pa[i], pb[i]);
			case [TAnon(aa), TAnon(ba)]:
				unifyAnonToAnon(aa, ba);
			case [TInst(c, params), TAnon(ba)]:
				unifyClassToAnon(c, params, ba);
			case [TFun(sa), TFun(sb)]:
				unifyFunctions(sa, sb);
			case [TLazy(f), _]:
				unify(lazyType(f), b);
			case [_, TLazy(f)]:
				unify(a, lazyType(f));
			case [TMono(r), _]:
				if (r.tmType != null) unify(r.tmType, b);
			case [_, TMono(r)]:
				if (r.tmType != null) unify(a, r.tmType);
			case [TType(td, tl), _]:
				unifyRec(a, b, function() unify(applyTypedef(td, tl), b));
			case [_, TType(td, tl)]:
				unifyRec(a, b, function() unify(a, applyTypedef(td, tl)));
			case [TAbstract(ab, tl), _] if (!core.Meta.has(MetaTag.CoreType, ab.aMeta)):
				unify(applyParams(ab.aParams, tl, ab.aThis), b);
			case [_, TAbstract(ab, tl)] if (!core.Meta.has(MetaTag.CoreType, ab.aMeta)):
				unify(a, applyParams(ab.aParams, tl, ab.aThis));
			case _:
		}
	}

	public function unifyRec(a:T, b:T, run:Void->Void):Void {
		if (stack.exists(function(p) return fastEq(a, p.a) && fastEq(b, p.b))) return;
		stack.unshift({a: a, b: b});
		try {
			run();
			stack.shift();
		} catch (e:haxe.Exception) {
			stack.shift();
			throw e;
		}
	}

	function unifyAnonToAnon(a:TAnon, b:TAnon):Void {
		var names = [for (n in b.aFields.keys()) n];
		names.sort(Reflect.compare);
		for (n in names) {
			var fa = a.aFields.get(n);
			if (fa != null) unify(fa.cfType, b.aFields.get(n).cfType, Field(n));
		}
	}

	function unifyClassToAnon(a:TClass, params:Array<T>, b:TAnon):Void {
		var names = [for (n in b.aFields.keys()) n];
		names.sort(Reflect.compare);
		for (n in names) {
			var fa = a.clFields.get(n);
			if (fa != null) unify(applyParams(a.clParams, params, fa.cfType), b.aFields.get(n).cfType, Field(n));
		}
	}

	function unifyFunctions(a:TSignature, b:TSignature):Void {
		switch (b.ret : T) {
			case TAbstract({aPath: {pack: [], name: "Void"}}, []):
			case _:
				unify(a.ret, b.ret, FunctionReturn);
		}
		for (i in 0...Std.int(Math.min(a.args.length,
			b.args.length))) unify(b.args[i].type, a.args[i].type, FunctionArgument(i + 1, a.args.length));
	}
}

class ImmediateExecution {
	var cache:haxe.ds.ObjectMap<TClassField, Map<Int, Bool>> = new haxe.ds.ObjectMap();

	public function new() {}

	function getCache(field:TClassField):Map<Int, Bool> {
		var found = cache.get(field);
		if (found == null) {
			found = [];
			cache.set(field, found);
		}
		return found;
	}

	public function check(callee:TExpr, argNum:Int):Bool return switch NullSafety.revealExpr(callee).eexpr {
		case TField(_, FClosure({cls: cls}, field = {cfKind: Method(MethNormal | MethInline)})) |
			TField(_, FStatic(cls, field = {cfKind: Method(MethNormal | MethInline)})) |
			TField(_, FInstance(cls, _, field = {cfKind: Method(MethNormal | MethInline)})):
			if (PurityState.isPure(cls,
				field)) true; else if (cls.clPath.pack.length == 0 && cls.clPath.name == "Array") true; else switch field.cfExpr {
				case {eexpr: TFunction(fn)} if (hasClassFieldFlag(field,
					CfFinal) || !FiltersCommon.isOverridden(cls, field)): if (argNum < 0 || argNum >= fn.tfArgs.length) false; else {
						var c = getCache(field);
						if (c.exists(argNum)) c.get(argNum);
						else {
							c.set(argNum, true);
							var result = !isStored(fn.tfArgs[argNum].variable, fn.tfExpr);
							c.set(argNum, result);
							result;
						}
					}
				case _: false;
			}
		case _: false;
	};

	function isStored(v:TVar, e:TExpr):Bool return switch e.eexpr {
		case TThrow({eexpr: TLocal(local)}) | TReturn({eexpr: TLocal(local)}) | TCast({eexpr: TLocal(local)}, _) |
			TMeta(_, {eexpr: TLocal(local)}) | TBinop(OpAssign, _, {eexpr: TLocal(local)}) if (local.vId == v.vId): true;
		case TFunction(fn):
			function captured(e:TExpr):Bool return switch e.eexpr {
				case TLocal(local): local.vId == v.vId;
				case _: Texpr.checkExpr(captured, e);
			};
			captured(fn.tfExpr);
		case TCall(callee, args): if (isStored(v, callee)) true; else {
				var result = false;
				for (i in 0...args.length) {
					result = switch args[i].eexpr {
						case TLocal(local) if (local.vId == v.vId): !check(callee, i);
						case _: isStored(v, args[i]);
					};
					if (result) break;
				}
				result;
			}
		case _: Texpr.checkExpr(function(e) return isStored(v, e), e);
	};
}

class SafetyScope {
	var mode:SafetyMode;
	var type:ScopeType;
	var safe:SafetyTable;
	var never:SafetyTable;
	var declarations:Map<Int, TVar> = [];

	public function new(mode:SafetyMode, type:ScopeType, safe:SafetyTable, never:SafetyTable) {
		this.mode = mode;
		this.type = type;
		this.safe = safe;
		this.never = never;
	}

	public function getSafeLocals():SafetyTable return safe;

	public function getNeverSafe():SafetyTable return never;

	public function getType():ScopeType return type;

	public function resetTo(state:SafetyTable):Void {
		safe.clear();
		for (e in state.all()) safe.set(e.subject, e.expr);
	}

	public function declareVar(v:TVar):Void declarations.set(v.vId, v);

	public function ownsVar(v:TVar):Bool return declarations.exists(v.vId);

	public function isSafe(e:TExpr):Bool {
		if (!NullSafety.isNullableType(e.etype)) return true;
		var s = getSubject(e);
		return s != SNotSuitable && !never.has(s) && safe.has(s);
	}

	public function addToSafety(e:TExpr):Void {
		var s = getSubject(e);
		if (s != SNotSuitable) safe.set(s, e);
	}

	public function removeFromSafety(e:TExpr, forever:Bool = false):Void {
		var s = getSubject(e);
		if (s != SNotSuitable) {
			safe.remove(s);
			if (forever) never.set(s, e);
		}
	}

	public function filterSafety(sample:SafetyTable):Void for (e in safe.copy().all()) if (!sample.has(e.subject)) safe.remove(e.subject);

	public function reassigned(e:TExpr):Void {
		var subject = getSubject(e);
		if (subject == SNotSuitable) return;
		switch subject {
			case SFieldOfClass(_, _) | SFieldOfLocalVar(_, _) | SFieldOfThis(_):
				dropSafeFieldsInStrictMode();
			case _:
		}
		inline function starts(safeFields:Array<String>, fields:Array<String>):Bool {
			var a = safeFields.copy(), b = fields.copy();
			a.reverse();
			b.reverse();
			return NullSafety.listStartsWithList(a, b);
		}
		var remove = [];
		for (entry in safe.all()) {
			var yes = switch [entry.subject, subject] {
				case [SFieldOfLocalVar(id, _), SLocalVar(v)] if (id == v): true;
				case [SFieldOfLocalVar(id, a), SFieldOfLocalVar(v, b)] if (id == v): starts(a, b);
				case [SFieldOfClass(path,
					a), SFieldOfClass(p, b)] if (SafetyTable.equal(SFieldOfClass(path, []), SFieldOfClass(p, []))): starts(a, b);
				case [SFieldOfThis(a), SFieldOfThis(b)]: starts(a, b);
				case _: false;
			};
			if (yes) remove.unshift(entry.subject);
		}
		for (s in remove) safe.remove(s);
	}

	public function callMade():Void dropSafeFieldsInStrictMode();

	function dropSafeFieldsInStrictMode():Void {
		if (mode == SMOff || mode == SMLoose) return;
		var remove = [];
		for (e in safe.all()) switch e.subject {
			case SFieldOfLocalVar(_, _) | SFieldOfClass(_, _) | SFieldOfThis(_):
				remove.unshift(e.subject);
			case _:
		}
		for (s in remove) safe.remove(s);
	}

	public function getSubject(e:TExpr):SafetySubject return NullSafety.getSubject(mode, e);
}

class LocalSafety {
	var mode:SafetyMode;
	var scopes:Array<SafetyScope>;

	public function new(mode:SafetyMode) {
		this.mode = mode;
		clear();
	}

	public function clear():Void scopes = [new SafetyScope(mode, STNormal, new SafetyTable(), new SafetyTable())];

	function current():SafetyScope {
		if (scopes.length == 0) return NullSafety.fail(nullPos, {file: "nullSafety.ml", line: 810}, "List of scopes should never end.");
		return scopes[0];
	}

	public function getSafeLocalsCopy():SafetyTable return current().getSafeLocals().copy();

	public function filterSafety(sample:SafetyTable):Void current().filterSafety(sample);

	public function functionDeclared(immediate:Bool, fn:TFunc):Void {
		var s = immediate
			|| mode == SMLoose ? new SafetyScope(mode, STImmediateClosure, current().getSafeLocals(),
				current().getNeverSafe()) : new SafetyScope(mode, STClosure, new SafetyTable(), new SafetyTable());
		scopes.unshift(s);
		for (a in fn.tfArgs) s.declareVar(a.variable);
	}

	public function blockDeclared():Void scopes.unshift(new SafetyScope(mode, STNormal, current().getSafeLocals(),
		current().getNeverSafe()));

	public function loopDeclared(e:TExpr):Void {
		scopes.unshift(new SafetyScope(mode, STLoop, current().getSafeLocals(), current().getNeverSafe()));
		switch e.eexpr {
			case TWhile(_, _, _):
			case _:
				NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 856}, "Expected TWhile.");
		}
	}

	public function scopeClosed():Void {
		if (scopes.length == 0) NullSafety.fail(nullPos, {file: "nullSafety.ml", line: 862}, "No scopes left.");
		if (scopes.length == 1) NullSafety.fail(nullPos, {file: "nullSafety.ml", line: 863}, "Cannot close the last scope.");
		scopes.shift();
	}

	public function declareVar(v:TVar, isSafe:Bool = false):Void {
		current().declareVar(v);
		if (isSafe) current().addToSafety({eexpr: TVar(v, null), etype: v.vType, epos: v.vPos});
	}

	public function isSafe(e:TExpr):Bool {
		if (!NullSafety.isNullableType(e.etype)) return true;
		var captured = false;
		switch e.eexpr {
			case TLocal(v):
				for (s in scopes) {
					if (s.ownsVar(v)) break;
					if (s.getType() == STClosure) {
						captured = true;
						break;
					}
				}
			case _:
		}
		return (mode == SMLoose || !captured) && current().isSafe(e);
	}

	public function processWhile(e:TExpr, nullable:TExpr->Bool, condition:TExpr->Void, body:(Void->Void)->TExpr->Void):Void switch e.eexpr {
		case TWhile(cond, b, DoWhile):
			var original = getSafeLocalsCopy();
			condition(cond);
			var checked = NullSafety.processCondition(mode, cond, nullable, function(_) {});
			body(function() {
				for (e in checked.notNulls) {
					var subject = NullSafety.getSubject(mode, e);
					if (subject != SNotSuitable && original.has(subject)) current().addToSafety(e);
				}
			}, b);
		case TWhile(cond, b, NormalWhile):
			condition(cond);
			var checked = NullSafety.processCondition(mode, cond, nullable, function(_) {});
			var original = getSafeLocalsCopy();
			for (e in checked.notNulls) current().addToSafety(e);
			body(function() {
				for (e in checked.notNulls) current().addToSafety(e);
			}, b);
			current().filterSafety(original);
		case _:
			NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 934}, "Expected TWhile");
	};

	public function processLoopBody(first:Void->Void, intermediate:Null<Void->Void>, second:Void->Void):Void {
		var original = getSafeLocalsCopy();
		first();
		filterSafety(original);
		if (intermediate != null) intermediate();
		second();
	}

	public function processTry(body:TExpr, catches:Array<{variable:TVar, expr:TExpr}>, check:TExpr->Void):Void {
		var original = getSafeLocalsCopy();
		check(body);
		filterSafety(original);
		var after = getSafeLocalsCopy();
		var afterCatches = getSafeLocalsCopy();
		for (c in catches) {
			current().resetTo(after);
			check(c.expr);
			for (e in afterCatches.copy().all()) if (!isSafe(e.expr)) afterCatches.remove(e.subject);
		}
		current().resetTo(afterCatches);
	}

	public function processIf(e:TExpr, nullable:TExpr->Bool, condition:TExpr->Void, body:TExpr->Void):Void switch e.eexpr {
		case TIf(cond, thenBody, elseBody):
			condition(cond);
			var checked = NullSafety.processCondition(mode, cond, nullable, function(_) {});
			var notNulls = checked.notNulls.filter(function(e) return !isSafe(e));
			var notCond:TExpr = {eexpr: TUnop(Not, Prefix, cond), etype: cond.etype, epos: cond.epos};
			var elseNotNulls = NullSafety.processCondition(mode, notCond, nullable, function(_) {})
				.notNulls.filter(function(e) return !isSafe(e));
			var initial = getSafeLocalsCopy();
			for (e in notNulls) current().addToSafety(e);
			body(thenBody);
			var afterIf = getSafeLocalsCopy();
			current().resetTo(initial);
			inline function deadEnd(body:TExpr,
					vars:Array<TExpr>):Void if (DeadEnd.hasDeadEnd(body)) for (e in vars) current().addToSafety(e);
			if (elseBody == null) {
				for (e in checked.nulls) if (afterIf.has(current().getSubject(e))) current().addToSafety(e);
				for (e in initial.all()) if (!afterIf.has(e.subject)) current().removeFromSafety(e.expr);
				deadEnd(thenBody, elseNotNulls);
			} else {
				for (e in elseNotNulls) current().addToSafety(e);
				body(elseBody);
				var afterElse = getSafeLocalsCopy();
				current().resetTo(initial);
				for (e in initial.all()) {
					if (!afterIf.has(e.subject) || !afterElse.has(e.subject)) current().removeFromSafety(e.expr);
					afterIf.remove(e.subject);
					afterElse.remove(e.subject);
				}
				for (e in afterIf.all()) if (afterElse.has(e.subject)) current().addToSafety(e.expr);
				deadEnd(thenBody, elseNotNulls);
				deadEnd(elseBody, notNulls);
			}
		case _:
			NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 1016}, "Expected TIf");
	};

	public function processAnd(left:TExpr, right:TExpr, nullable:TExpr->Bool, callback:TExpr->Void):Void {
		callback(left);
		var original = getSafeLocalsCopy();
		var checked = NullSafety.processCondition(mode, left, nullable, function(_) {});
		var temp = new SafetyScope(mode, STNormal, original.copy(), new SafetyTable());
		for (e in checked.notNulls) temp.addToSafety(e);
		scopes.unshift(temp);
		callback(right);
		scopeClosed();
		var after = temp.getSafeLocals();
		var finalSafe = new SafetyTable();
		for (e in original.all()) if (original.has(e.subject) && after.has(e.subject)) finalSafe.set(e.subject, e.expr);
		current().resetTo(finalSafe);
	}

	public function processOr(left:TExpr, right:TExpr, nullable:TExpr->Bool, callback:TExpr->Void):Void {
		var original = getSafeLocalsCopy();
		var checked = NullSafety.processCondition(mode, left, nullable, callback);
		var temp = new SafetyScope(mode, STNormal, original.copy(), new SafetyTable());
		for (e in checked.nulls) temp.addToSafety(e);
		scopes.unshift(temp);
		callback(right);
		scopeClosed();
		var after = temp.getSafeLocals();
		var finalSafe = new SafetyTable();
		for (e in original.all()) if (original.has(e.subject) && after.has(e.subject)) finalSafe.set(e.subject, e.expr);
		current().resetTo(finalSafe);
	}

	public function handleAssignment(nullable:TExpr->Bool, left:TExpr, right:TExpr):Void {
		if (NullSafety.isSuitable(mode, left)) current().reassigned(left);
		if (nullable(right)) switch left.eexpr {
			case TLocal(v):
				var captured = false;
				for (s in scopes) {
					if (s.ownsVar(v)) {
						s.removeFromSafety(left, captured);
						break;
					}
					captured = captured || s.getType() == STClosure;
					s.removeFromSafety(left, captured);
				}
			case _:
		}
		else if (NullSafety.isNullableType(left.etype)) current().addToSafety(left);
	}

	public function callMade():Void current().callMade();
}

class ExprChecker {
	var m:ModuleDef;
	var mode:SafetyMode;
	var immediate:ImmediateExecution;
	var report:SafetyReport;
	var options:Array<Array<WarningOption>>;
	var localSafety:LocalSafety;
	var returnTypes:Array<T> = [];
	var inClosure = false;
	var isPretending = false;

	public function new(m:ModuleDef, mode:SafetyMode, immediate:ImmediateExecution, report:SafetyReport,
			options:Array<Array<WarningOption>>) {
		this.m = m;
		this.mode = mode;
		this.immediate = immediate;
		this.report = report;
		this.options = options;
		localSafety = new LocalSafety(mode);
	}

	public function getMode():SafetyMode return mode;

	function firstValid(positions:Array<Pos>):Pos {
		for (p in positions) if (p != nullPos) return p;
		return nullPos;
	}

	public function error(msg:String,
			positions:Array<Pos>):Void if (!isPretending) NullSafety.addError(report, m, msg, firstValid(positions));

	public function errorUnify(trace:Array<UnifyError>,
			p:Pos):Void if (!isPretending) NullSafety.addError(report, m, BetterErrors.betterErrorMessage(trace), p);

	public function warning(type:WarningCode, msg:String,
			positions:Array<Pos>):Void if (!isPretending) NullSafety.addWarning(report, m, type, options, msg, firstValid(positions));

	function checkBinopRedundantNullChecks(e:TExpr):Void switch Texpr.skip(e).eexpr {
		case TBinop(OpEq | OpNotEq, {eexpr: TConst(TNull)}, expr) | TBinop(OpEq | OpNotEq, expr, {eexpr: TConst(TNull)}) |
			TBinop(OpAssignOp(OpNullCoal), expr, _) | TBinop(OpNullCoal, expr, _):
			if (!NullSafety.isNullableType(expr.etype,
				true)) warning(WRedundantNullCheck, "The operand type is not nullable, so null-check should be redundant.",
					[expr.epos, e.epos]);
		case TBinop(_, left, right):
			checkBinopRedundantNullChecks(left);
			checkBinopRedundantNullChecks(right);
		case _:
	};

	public function isNullableExpr(e:TExpr):Bool {
		e = NullSafety.revealExpr(e);
		return switch e.eexpr {
			case TConst(TNull): true;
			case TConst(_): false;
			case TParenthesis(e): isNullableExpr(e);
			case TMeta(meta, _) if (NullSafety.containsUnsafeMeta([meta])): false;
			case TMeta(_, e): isNullableExpr(e);
			case TThrow(_) | TReturn(_) | TContinue | TBreak: false;
			case TBinop(OpAssign | OpAssignOp(_), _, right): isNullableExpr(right);
			case TBlock(el):
				localSafety.blockDeclared();
				var nullable = false;
				for (i in 0...el.length) {
					if (i == el.length - 1) {
						nullable = isNullableExpr(el[i]);
						break;
					}
					switch el[i].eexpr {
						case TVar(v, _): localSafety.declareVar(v);
						case _:
					}
				}
				localSafety.scopeClosed();
				nullable;
			case TIf(_, _, _):
				var nullable = false;
				localSafety.processIf(e, isNullableExpr, function(_) {}, function(body) nullable = nullable || isNullableExpr(body));
				nullable;
			case _: NullSafety.isNullableType(e.etype) && !localSafety.isSafe(e);
		};
	}

	public function canPassExpr(expr:TExpr, toType:T, p:Pos):Bool {
		inline function tryUnify(expr:TExpr, toType:T):Bool {
			if (isNullableExpr(expr) && !NullSafety.isNullableType(toType, true)) return false;
			var type = NullSafety.unfoldNull(expr.etype);
			try {
				new Unificator().unify(type, toType);
				return true;
			} catch (ex:SafetyUnifyError) {
				var errors = switch ex.access {
					case Field(name): [InvalidFieldType(name), CannotUnify(ex.a, ex.b)];
					case FunctionArgument(i, total): [InvalidFunctionArgument(i, total), CannotUnify(ex.a, ex.b)];
					case FunctionReturn: [InvalidReturnType, CannotUnify(ex.a, ex.b)];
					case _: [CannotUnify(ex.a, ex.b)];
				};
				errorUnify(errors, p);
				return true;
			} catch (ex:Dynamic) {
				return NullSafety.fail(expr.epos, {file: "nullSafety.ml", line: 1240}, "Null safety unification failure");
			}
		}
		inline function checkAnon(fields:Array<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>, to:TAnon):Bool {
			var acc = true;
			for (f in fields) {
				var field = to.aFields.get(f.key.name);
				if (field == null) {
					acc = true;
					continue;
				}
				if (!canPassExpr(f.expr, field.cfType, f.expr.epos)) error("Cannot assign nullable value here.", [f.expr.epos]);
				acc = acc && true;
			}
			return acc;
		}
		return switch [expr.eexpr, toType] {
			case [TLocal(v), _] if (NullSafety.containsUnsafeMeta(v.vMeta)): true;
			case [TObjectDecl(fields), TAbstract({aPath: {pack: [], name: "Null"}},
				[TAnon(to)])] | [TObjectDecl(fields), TAnon(to)]: checkAnon(fields, to);
			case [
				TObjectDecl(fields),
				TAbstract({aPath: {pack: [], name: "Null"}}, [TType(td, tl)])
			] | [TObjectDecl(fields), TType(td, tl)]: switch followWithoutNull(td.tType) {
				case TAnon(to): checkAnon(fields, to);
				case _: tryUnify(expr, toType);
			}
			case _: tryUnify(expr, toType);
		};
	}

	public function checkRootExpr(e:TExpr):Void {
		checkExpr(e);
		localSafety.clear();
		returnTypes = [];
		inClosure = false;
	}

	function checkExpr(e:TExpr):Void switch e.eexpr {
		case TConst(_) | TLocal(_) | TTypeExpr(_) | TIdent(_):
		case TArray(arr, idx):
			checkArrayAccess(arr, idx, e.epos);
		case TBinop(op, left, right):
			checkBinopRedundantNullChecks(e);
			checkBinop(op, left, right, e.epos);
		case TField(target, access):
			checkField(target, access, e.epos);
		case TParenthesis(e):
			checkExpr(e);
		case TObjectDecl(fields):
			for (f in fields) checkExpr(f.expr);
		case TArrayDecl(items):
			checkArrayDecl(items, e.etype, e.epos);
		case TCall(callee, args):
			checkCall(callee, args, e.epos);
		case TNew(_, _, _):
			checkNew(e);
		case TUnop(_, _, inner):
			checkUnop(inner, e.epos);
		case TFunction(fn):
			checkFunction(fn);
		case TVar(v, init):
			checkVar(v, init, e.epos);
		case TBlock(el):
			checkBlock(el, e.epos);
		case TIf(_, _, _):
			checkIf(e);
		case TWhile(_, _, _):
			checkWhile(e);
		case TSwitch(s):
			checkSwitch(s, e.epos);
		case TTry(body, catches):
			localSafety.processTry(body, catches, checkExpr);
		case TReturn(inner) if (inner != null):
			checkReturn(inner, e.epos);
		case TReturn(_) | TBreak | TContinue:
		case TThrow(inner):
			checkThrow(inner, e.epos);
		case TCast(inner, _):
			checkCast(inner, e.etype, e.epos);
		case TMeta(meta, _) if (NullSafety.containsUnsafeMeta([meta])):
		case TMeta(meta = {meta: MetaTag.NullSafety}, inner):
			NullSafety.validateSafetyMeta(report, m, [meta]);
			checkExpr(inner);
		case TMeta(_, inner):
			checkExpr(inner);
		case TEnumIndex(idx):
			checkEnumIndex(idx, e.epos);
		case TEnumParameter(inner, _, _):
			checkExpr(inner);
	};

	function checkBlock(el:Array<TExpr>, p:Pos):Void {
		localSafety.blockDeclared();
		for (e in el) checkExpr(e);
		localSafety.scopeClosed();
	}

	function checkArrayDecl(items:Array<TExpr>, type:T, p:Pos):Void {
		switch core.Abstract.followWithAbstracts(type) {
			case TInst({clPath: {pack: [], name: "Array"}}, [itemType]):
				for (e in items) if (!canPassExpr(e, itemType,
					e.epos)) error("Cannot use nullable value of " + NullSafety.strType(e.etype) + " as an item in Array<"
						+ NullSafety.strType(itemType) + ">",
						[e.epos, p]);
			case _:
		}
		for (e in items) checkExpr(e);
	}

	function checkEnumIndex(idx:TExpr, p:Pos):Void {
		if (isNullableExpr(idx)) error("Cannot access nullable enum value.", [idx.epos, p]);
		checkExpr(idx);
	}

	function checkWhile(e:TExpr):Void switch e.eexpr {
		case TWhile(_, _, _):
			function condition(cond:TExpr):Void {
				if (isNullableExpr(cond)) error('Cannot use nullable value as a condition in "while".', [cond.epos, e.epos]);
				checkExpr(cond);
			}
			localSafety.loopDeclared(e);
			localSafety.processWhile(e, isNullableExpr, condition, function(effect, body) checkLoopBody(effect, body));
			localSafety.scopeClosed();
		case _:
			NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 1381}, "Expected TWhile.");
	};

	function checkLoopBody(effect:Null<Void->Void>, body:TExpr):Void localSafety.processLoopBody(function() {
		isPretending = true;
		checkExpr(body);
	}, effect, function() {
		isPretending = false;
		checkExpr(body);
	});

	function checkThrow(e:TExpr, p:Pos):Void {
		if (isNullableExpr(e)) error("Cannot throw nullable value.", [p, e.epos]);
		checkExpr(e);
	}

	function checkCast(e:TExpr, to:T, p:Pos):Void {
		checkExpr(e);
		switch to {
			case TMono(_):
			case _:
				if (!canPassExpr(e, to, p)) error("Cannot cast nullable value to not nullable type.", [p, e.epos]);
		}
	}

	function checkFunction(fn:TFunc, immediateExecution:Bool = false):Void {
		localSafety.functionDeclared(immediateExecution, fn);
		returnTypes.unshift(fn.tfType);
		if (immediateExecution || mode == SMLoose) {
			var original = localSafety.getSafeLocalsCopy();
			isPretending = true;
			checkExpr(fn.tfExpr);
			isPretending = false;
			localSafety.filterSafety(original);
			checkExpr(fn.tfExpr);
		} else checkExpr(fn.tfExpr);
		returnTypes.shift();
		localSafety.scopeClosed();
	}

	function checkReturn(e:TExpr, p:Pos):Void {
		checkExpr(e);
		if (returnTypes.length > 0 && !canPassExpr(e, returnTypes[0],
			p)) error("Cannot return nullable value of " + NullSafety.strType(e.etype) + " as " + NullSafety.strType(returnTypes[0]),
				[p, e.epos]);
	}

	function checkSwitch(s:TSwitch, p:Pos):Void {
		var target:TExpr = s.switchSubject;
		if (isNullableExpr(target)) error("Cannot switch on nullable value.", [target.epos, p]);
		checkExpr(target);
		for (c in s.switchCases) checkExpr(c.caseExpr);
		if (s.switchDefault != null) checkExpr(s.switchDefault);
	}

	function checkIf(e:TExpr):Void {
		function condition(cond:TExpr):Void {
			if (isNullableExpr(cond)) error('Cannot use nullable value as condition in "if".', [cond.epos, e.epos]);
			checkExpr(cond);
		}
		localSafety.processIf(e, isNullableExpr, condition, checkExpr);
	}

	function checkArrayAccess(arr:TExpr, idx:TExpr, p:Pos):Void {
		if (isNullableExpr(arr)) error("Cannot perform array access on nullable value.", [p, arr.epos]);
		if (isNullableExpr(idx)) error("Cannot use nullable value as an index for array access.", [p, idx.epos]);
		checkExpr(arr);
		checkExpr(idx);
	}

	function checkBinop(op:Binop, left:TExpr, right:TExpr, p:Pos):Void {
		inline function both():Void {
			checkExpr(left);
			checkExpr(right);
		}
		switch op {
			case OpEq | OpNotEq:
				both();
			case OpBoolAnd:
				localSafety.processAnd(left, right, isNullableExpr, checkExpr);
			case OpBoolOr:
				localSafety.processOr(left, right, isNullableExpr, checkExpr);
			case OpAdd | OpAssignOp(OpAdd) if (NullSafety.isStringType(left.etype) || NullSafety.isStringType(right.etype)):
				both();
				if (NullSafety.isNullableType(left.etype)
					&& NullSafety.isNullableType(right.etype)) error("Cannot concatenate two nullable values.", [p, left.epos, right.epos]);
			case OpAssign:
				both();
				if (!canPassExpr(right, left.etype, p)) {
					switch left.eexpr {
						case TLocal(v) if (NullSafety.containsUnsafeMeta(v.vMeta)):
						case _: error("Cannot assign nullable value here.", [p, right.epos, left.epos]);
					}
				} else localSafety.handleAssignment(isNullableExpr, left, right);
			case _:
				if (isNullableExpr(left) || isNullableExpr(right)) error("Cannot perform binary operation on nullable value.",
					[p, left.epos, right.epos]);
				both();
		}
	}

	function checkUnop(e:TExpr, p:Pos):Void {
		if (isNullableExpr(e)) error("Cannot perform unary operation on nullable value.", [p, e.epos]);
		checkExpr(e);
	}

	function checkVar(v:TVar, init:Null<TExpr>, p:Pos):Void {
		localSafety.declareVar(v);
		if (init == null) return;
		switch init.eexpr {
			case TConst(TNull) if (Type.enumEq(v.vKind, VUser(TVOLocalFunction))):
				return;
			case TConst(TNull) if (v.vKind == VGenerated):
				switch followWithCoro(v.vType) {
					case Coro(_) | NotCoro(TFun(_)): return;
					case _:
				}
			case _:
		}
		checkBinop(OpAssign, {eexpr: TLocal(v), epos: v.vPos, etype: v.vType}, init, p);
	}

	function checkField(target:TExpr, access:TFieldAccess, p:Pos):Void {
		checkExpr(target);
		if (isNullableExpr(target)) error('Cannot access "${NullSafety.accessedFieldName(access)}" of a nullable value.', [p, target.epos]);
	}

	function checkNew(e:TExpr):Void switch e.eexpr {
		case TNew(cls, params, args):
			var ctor = null;
			try {
				ctor = getConstructor(cls);
			} catch (ex:NotFound) {}
			if (ctor == null) {
				for (e in args) checkExpr(e);
			} else switch follow(applyParams(cls.clParams, params, ctor.cfType)) {
				case TFun(s): checkArgs(e, args, s.args);
				case _: NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 1580}, "Unexpected constructor type.");
			}
		case _:
			NullSafety.fail(e.epos, {file: "nullSafety.ml", line: 1584}, "TNew expected");
	};

	function checkCall(callee:TExpr, args:Array<TExpr>, p:Pos):Void {
		if (isNullableExpr(callee)) error("Cannot call a nullable value.", [callee.epos, p]);
		switch callee.eexpr {
			case TFunction(fn) | TParenthesis({eexpr: TFunction(fn)}):
				checkFunction(fn, true);
			case _:
				checkExpr(callee);
		}
		switch follow(callee.etype) {
			case TFun(s):
				if (NullSafety.isTrace(callee)) {
					var real = args;
					if (args.length == 2) switch args[1].eexpr {
						case TObjectDecl(fields): for (f in fields) if (f.key.name == "customParams") {
								switch f.expr.eexpr {
									case TArrayDecl(rest): real = [args[0]].concat(rest);
									case _:
								}
								break;
							}
						case _:
					}
					for (e in real) checkExpr(e);
				} else checkArgs(callee, args, s.args);
			case _:
				for (e in args) checkExpr(e);
		}
		localSafety.callMade();
	}

	function checkArgs(callee:TExpr, args:Array<TExpr>, types:Array<{name:String, optional:Bool, type:T}>):Void {
		var meta = NullSafety.getArgumentsMeta(callee, types.length);
		var count = Std.int(Math.min(args.length, Math.min(types.length, meta.length)));
		for (i in 0...count) {
			var arg = args[i];
			var type = types[i];
			var unsafe = NullSafety.containsUnsafeMeta(meta[i]);
			if (!type.optional && !unsafe && !canPassExpr(arg, type.type, arg.epos)) {
				var name = NullSafety.symbolName(callee);
				var funStr = name == "" ? "" : ' of function "$name"';
				var argStr = type.name == "" ? "" : ' "${type.name}"';
				error('Cannot pass nullable value to not-nullable argument$argStr$funStr.', [arg.epos, callee.epos]);
			}
			switch arg.eexpr {
				case TFunction(fn):
					checkFunction(fn, immediate.check(callee, i));
				case TCast(e, null) if (unsafe && fastEq(arg.etype, type.type)):
					checkExpr(e);
				case _:
					checkExpr(arg);
			}
		}
	}
}

class ClassChecker {
	var cls:TClass;
	var immediate:ImmediateExecution;
	var report:SafetyReport;
	var mainExpr:Null<TExpr>;
	var m:ModuleDef;
	var clsMeta:Metadata;
	var isSafeClass:Bool;
	var checker:ExprChecker;
	var mode:Null<SafetyMode> = null;

	public function new(cls:TClass, immediate:ImmediateExecution, report:SafetyReport, mainExpr:Null<TExpr>) {
		this.cls = cls;
		this.immediate = immediate;
		this.report = report;
		this.mainExpr = mainExpr;
		m = cls.clModule;
		clsMeta = cls.clMeta.concat(switch cls.clKind {
			case KAbstractImpl(a): a.aMeta;
			case _: [];
		});
		isSafeClass = NullSafety.safetyEnabled(clsMeta);
		checker = new ExprChecker(m, SMLoose, immediate, report, Warning.fromMeta(clsMeta));
	}

	public function check():Void {
		NullSafety.validateSafetyMeta(report, m, clsMeta);
		if (isSafeClass && !hasClassFlag(cls, CExtern) && !hasClassFlag(cls, CInterface)) checkVarFields();
		function field(isStatic:Bool, f:TClassField):Void {
			if (hasClassFieldFlag(f, CfPostProcessed)) return;
			NullSafety.validateSafetyMeta(report, m, f.cfMeta);
			var mode = NullSafety.getSafetyMode(clsMeta.concat(f.cfMeta));
			if (mode == SMOff) return;
			if (f.cfExpr != null) getChecker(mode).checkRootExpr(f.cfExpr);
			checkAccessors(isStatic, f);
		}
		if (isSafeClass) {
			var init = core.TOther.TClassTools.getClInit(cls);
			if (init != null) getChecker(NullSafety.getSafetyMode(clsMeta)).checkRootExpr(init);
		}
		if (cls.clConstructor != null) field(false, cls.clConstructor);
		for (f in cls.clOrderedFields) field(false, f);
		for (f in cls.clOrderedStatics) field(true, f);
	}

	function checkAccessors(isStatic:Bool, field:TClassField):Void switch field.cfKind {
		case Var(access) if (!NullSafety.isNullableType(field.cfType)):
			var fields = isStatic ? cls.clStatics : cls.clFields;
			inline function checkAccessor(prefix:String):Void {
				var accessor = fields.get(prefix + field.cfName);
				if (accessor == null || !isInSafety(accessor)) return;
				switch accessor.cfExpr {
					case e = {eexpr: TFunction(fn)}:
						getChecker(classSafetyMode()).checkRootExpr(core.ds.Record.withFields(e,
							{eexpr: TFunction(core.ds.Record.withFields(fn, {tfType: field.cfType}))}));
					case _:
				}
			}
			if (access.vRead == AccCall) checkAccessor("get_");
			if (access.vWrite == AccCall) checkAccessor("set_");
			if (access.vRead == AccPrivateCall) checkAccessor("get_");
			if (access.vWrite == AccPrivateCall) checkAccessor("set_");
		case _:
	};

	function classSafetyMode():SafetyMode {
		if (mode == null) mode = NullSafety.getSafetyMode(clsMeta);
		return mode;
	}

	function getChecker(mode:SafetyMode):ExprChecker {
		if (checker.getMode() != mode) checker = new ExprChecker(m, mode, immediate, report, Warning.fromMeta(clsMeta));
		return checker;
	}

	function isInSafety(field:TClassField):Bool return isSafeClass
		&& !NullSafety.containsUnsafeMeta(field.cfMeta)
		|| NullSafety.safetyEnabled(field.cfMeta);

	function getMainTfExpr(main:Null<TExpr>):Null<TExpr> {
		if (main == null) return null;
		return switch main.eexpr {
			case TCall({eexpr: TField(_, FStatic(c, field))}, _) if (c == cls): switch field.cfExpr {
					case {eexpr: TFunction({tfExpr: e})}: e;
					case _: null;
				}
			case _: null;
		};
	}

	public function checkVarFields():Void {
		function field(isStatic:Bool, f:TClassField):Void {
			NullSafety.validateSafetyMeta(report, m, f.cfMeta);
			if (NullSafety.shouldBeInitialized(f)
				&& !NullSafety.isNullableType(f.cfType)
				&& isInSafety(f)
				&& f.cfExpr != null
				&& !checker.canPassExpr(f.cfExpr, f.cfType,
					f.cfExpr.epos)) checker.error('Cannot set nullable initial value for not-nullable field "${f.cfName}".', [f.cfPos]);
		}
		for (f in cls.clOrderedFields) field(false, f);
		for (f in cls.clOrderedStatics) field(true, f);
		checkStaticsInitialization();
		checkFieldsInitializationInConstructor();
	}

	function pendingFields(fields:Array<TClassField>):Map<String, TClassField> {
		var pending:Map<String, TClassField> = [];
		for (f in fields) if (NullSafety.shouldBeInitialized(f)
			&& !NullSafety.isNullableType(f.cfType)
			&& !NullSafety.containsUnsafeMeta(f.cfMeta)
			&& f.cfExpr == null) pending.set(f.cfName, f);
		return pending;
	}

	function checkStaticsInitialization():Void {
		var pending = pendingFields(cls.clOrderedStatics);
		var init = core.TOther.TClassTools.getClInit(cls);
		if (init != null) checkFieldsInitialization(pending, init, true, classSafetyMode());
		var main = getMainTfExpr(mainExpr);
		if (main != null) checkFieldsInitialization(pending, main, true, classSafetyMode());
		for (name in pending.keys()) checker.error('Field "$name" is not nullable thus should have an initial value.',
			[pending.get(name).cfPos]);
	}

	function checkFieldsInitializationInConstructor():Void {
		var pending = pendingFields(cls.clOrderedFields);
		switch cls.clConstructor {
			case {cfMeta: meta, cfExpr: {eexpr: TFunction({tfExpr: e})}}:
				checkFieldsInitialization(pending, e, false, NullSafety.getSafetyMode(clsMeta.concat(meta)));
			case _:
		}
		for (name in pending.keys())
			checker.error('Field "$name" is not nullable thus should have an initial value or should be initialized in constructor.',
				[pending.get(name).cfPos]);
	}

	function checkFieldsInitialization(pending:Map<String, TClassField>, expr:TExpr, isStatic:Bool,
			mode:SafetyMode):Map<String, TClassField> {
		var thisVars:Map<Int, TVar> = [];
		inline function unsafeUsage(list:Map<String, TClassField>, mode:SafetyMode, e:TExpr):Void {
			if (!list.keys().hasNext()) return;
			inline function maybeError(mode:SafetyMode, msg:String, p:Pos):Void if (mode != SMOff) checker.error(msg, [p]);
			function loop(mode:SafetyMode, e:TExpr):Void switch e.eexpr {
				case TField({eexpr: TConst(TThis)}, FInstance(_, _, field)) if (!isStatic):
					if (list.exists(field.cfName)) maybeError(mode, "Cannot use field " + field.cfName + " until initialization.", e.epos);
				case TField(_, FStatic(_, field)) if (isStatic):
					if (list.exists(field.cfName)) maybeError(mode, "Cannot use field " + field.cfName + " until initialization.", e.epos);
				case TField({eexpr: TConst(TThis)}, FClosure(_, field)):
					maybeError(mode, "Cannot use method " + field.cfName + " until all instance fields are initialized.", e.epos);
				case TCall({eexpr: TField({eexpr: TConst(TThis)}, FInstance(_, _, field))}, args):
					maybeError(mode, "Cannot call method " + field.cfName + " until all instance fields are initialized.", e.epos);
					for (e in args) loop(mode, e);
				case TConst(TThis):
					maybeError(mode, 'Cannot use "this" until all instance fields are initialized.', e.epos);
				case TLocal(v) if (thisVars.exists(v.vId)):
					maybeError(mode, 'Cannot use "this" until all instance fields are initialized.', e.epos);
				case TMeta(meta = {meta: MetaTag.NullSafety}, inner):
					var metaMode = NullSafety.getSafetyMode([meta]);
					Texpr.iter(function(e) loop(metaMode, e), inner);
				case TMeta(_, inner):
					Texpr.iter(function(e) loop(mode, e), inner);
				case TBinop(OpAssign, left, right):
					switch left.eexpr {
						case TField({eexpr: TConst(TThis)}, FInstance(_, _, _)) if (!isStatic):
						case TField(_, FStatic(_, _)) if (isStatic):
						case _: loop(mode, left);
					}
					loop(mode, right);
				case _:
					Texpr.iterWith(loop, mode, e);
			};
			loop(mode, e);
		}
		function traverse(list:Map<String, TClassField>, mode:SafetyMode, e:TExpr):Map<String, TClassField> {
			switch e.eexpr {
				case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, FInstance(_, _, field))}, right) if (!isStatic):
					traverse(list, mode, right);
					list.remove(field.cfName);
				case TBinop(OpAssign, {eexpr: TField(_, FStatic(_, field))}, right) if (isStatic):
					traverse(list, mode, right);
					list.remove(field.cfName);
				case TMeta(meta = {meta: MetaTag.NullSafety}, inner):
					traverse(list, NullSafety.getSafetyMode([meta]), inner);
				case TMeta(_, inner):
					traverse(list, mode, inner);
				case TWhile(cond, body, DoWhile):
					unsafeUsage(list, mode, cond);
					traverse(list, mode, body);
				case TBlock(el):
					for (e in el) traverse(list, mode, e);
				case TIf(_, thenBody, elseBody) if (elseBody != null):
					var a = traverse(list.copy(), mode, thenBody);
					var b = traverse(list.copy(), mode, elseBody);
					list.clear();
					for (name in a.keys()) list.set(name, a.get(name));
					for (name in b.keys()) list.set(name, b.get(name));
				case TVar(v, {eexpr: TConst(TThis)}):
					thisVars.set(v.vId, v);
				case _:
					unsafeUsage(list, mode, e);
			}
			return list;
		}
		return traverse(pending, mode, expr);
	}
}

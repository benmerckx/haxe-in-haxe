package macros.eval;

import core.Globals;
import core.Globals.Pos;
import core.ds.AtomicLazy;
import core.ds.GlobalsIntMap;
import core.ds.NotFound;
import core.MetaList.StrictMeta;
import core.TType;
import core.TFunctions;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;

using macros.eval.EvalValue.EvalValueTools;

/**
	haxe/src/macro/eval/evalPrototype.ml.

	Deviations:
	- `Context.getObjectPrototype` is typed `(ctx, Array<Int>) -> Vprototype`
	  (Haxe has no polymorphic record fields): it takes the hashed field names
	  in any order and returns the prototype. The upstream function, returning
	  the sorted `(name, value)` list too, is `getObjectPrototypeSorted`; callers
	  that need the sorted values use it (or `sortObjectFields`).
	- `object_name_cache` is keyed by the sorted hashed names joined with ",".
	- `ctx.overrides` is keyed by `sTypePath(path) + "." + fieldName`.
**/
typedef ProtoField = {name:Int, value:AtomicLazy<Value>};

/** A finalized prototype and the function initializing its fields. **/
typedef ProtoInit = {proto:Vprototype, init:Vprototype->Void};

typedef StaticDelay = {persistent:Bool, f:Vprototype->Void};

/** PrototypeBuilder.prototype_context **/
class PrototypeContext {
	public final ctx:Context;
	// The hashed path of the prototype.
	public final key:Int;
	// The parent prototype, if exists.
	public final parent:Null<Vprototype>;
	// The kind of the prototype.
	public final kind:VprototypeKind;
	// The fields of the prototype. A field here is a pair of its hashed name and its (lazyfied) value.
	public final fields:Array<ProtoField> = [];
	// The instance fields of the prototype. See above.
	public final instanceFields:Array<ProtoField> = [];
	// The metadata expression, if exists.
	public final meta:Null<TExpr>;
	// Whether or not the prototype is static.
	public final isStatic:Bool;

	public function new(ctx:Context, key:Int, parent:Null<Vprototype>, kind:VprototypeKind, meta:Null<TExpr>, isStatic:Bool) {
		this.ctx = ctx;
		this.key = key;
		this.parent = parent;
		this.kind = kind;
		this.meta = meta;
		this.isStatic = isStatic;
	}
}

/**
	PrototypeBuilder manages the intermediate state of prototypes. Due to mutual dependencies,
	prototypes have to be created in multiple steps similar to how types have to be loaded.

	The procedure is as follows:

	1. Create an instance of [prototype_context] using [create].
	2. Add fields to it and call [finalize].
	3. Invoke the function returned by [finalize] to initialize fields.
**/
class PrototypeBuilder {
	/** Creates a new prototype context using the provided information. **/
	public static function create(ctx:Context, key:Int, parent:Null<Vprototype>, kind:VprototypeKind, meta:Null<TExpr>):PrototypeContext {
		var isStatic = switch kind {
			case PClass(_) | PEnum(_): true;
			case PInstance | PObject: false;
		}
		return new PrototypeContext(ctx, key, parent, kind, meta, isStatic);
	}

	/** Adds a prototype (static) field. **/
	public static function addProtoField(pctx:PrototypeContext, name:Int, v:AtomicLazy<Value>):Void {
		pctx.fields.push({name: name, value: v});
	}

	/** Adds an instance (non-static) field. **/
	public static function addInstanceField(pctx:PrototypeContext, name:Int, v:AtomicLazy<Value>):Void {
		pctx.instanceFields.push({name: name, value: v});
	}

	/** Forces the lazy field values and assigns them to the prototype. **/
	public static function initializeFields(pctx:PrototypeContext, proto:Vprototype):Void {
		for (i in 0...pctx.fields.length)
			proto.pfields[i] = pctx.fields[i].value.force();
	}

	/** Processes the field information and returns an initialization function. **/
	public static function finalize(pctx:PrototypeContext):ProtoInit {
		var ctx = pctx.ctx;
		// Add builtins (from EvalStdLib).
		var builtins = try (pctx.isStatic ? ctx.builtins.staticBuiltins : ctx.builtins.instanceBuiltins).find(pctx.key) catch (_:NotFound)
			[];
		for (b in builtins) {
			var s = b.name;
			var v = b.value;
			var i = -1;
			for (j in 0...pctx.fields.length)
				if (pctx.fields[j].name == s) {
					i = j;
					break;
				}
			if (i >= 0)
				pctx.fields[i] = {name: s, value: AtomicLazy.fromVal(v)};
			else
				addProtoField(pctx, s, AtomicLazy.fromVal(v));
		}
		// Add metadata field
		switch pctx.meta {
			case null:
			case e:
				pctx.fields.push({
					name: EvalHash.key___meta__,
					value: AtomicLazy.fromFun(() -> switch evalExpr(ctx, EKMethod(pctx.key, EvalHash.key___meta__), e) {
						case null: VNull;
						case e: e;
					})
				});
		}
		// Create the mapping from hashed name to field offset for prototype fields.
		var pnames:GlobalsIntMap<Int> = GlobalsIntMap.empty();
		for (i in 0...pctx.fields.length)
			pnames = pnames.add(pctx.fields[i].name, i);
		var pinstanceNames:GlobalsIntMap<Int>;
		var pinstanceFields:Array<Value>;
		var f:Vprototype->Void;
		if (!pctx.isStatic) {
			// Combines parent instance fields with current instance fields.
			var names:GlobalsIntMap<Int>;
			var fields:Array<Value>;
			switch pctx.parent {
				case null:
					names = GlobalsIntMap.empty();
					fields = [];
				case proto:
					names = proto.pinstanceNames;
					fields = proto.pinstanceFields;
			}
			var offset = fields.length;
			var a = [for (_ in 0...offset + pctx.instanceFields.length) VNull];
			for (i in 0...offset)
				a[i] = fields[i];
			// Create the mapping from hashed name to field offset for instance fields.
			var count = offset;
			for (field in pctx.instanceFields) {
				names = names.add(field.name, count);
				count++;
			}
			pinstanceNames = names;
			pinstanceFields = a;
			f = proto -> {
				for (i in 0...fields.length)
					a[i] = fields[i];
				for (i in 0...pctx.instanceFields.length)
					a[i + offset] = pctx.instanceFields[i].value.force();
				initializeFields(pctx, proto);
			};
		} else {
			pinstanceNames = GlobalsIntMap.empty();
			pinstanceFields = [];
			f = proto -> {
				initializeFields(pctx, proto);
			};
		}
		// Create the prototype.
		var proto = new Vprototype(pctx.key, [for (_ in 0...pctx.fields.length) VNull], pnames, pinstanceFields, pinstanceNames,
			pctx.parent, pctx.kind, VNull);
		proto.pvalue = EvalValueTools.vprototype(proto);
		// Register the prototype.
		if (pctx.isStatic)
			ctx.staticPrototypes.add(proto)
		else {
			ctx.instancePrototypes = ctx.instancePrototypes.add(pctx.key, proto);
			if (pctx.key == EvalHash.key_String)
				ctx.stringPrototype = proto
			else if (pctx.key == EvalHash.key_Array)
				ctx.arrayPrototype = proto
			else if (pctx.key == EvalHash.key_eval_Vector)
				ctx.vectorPrototype = proto;
		}
		return {proto: proto, init: f};
	}

	// evalPrototype.ml's `eval_expr`, used by `finalize` (defined before the module upstream).
	static inline function evalExpr(ctx:Context, kind:EnvKind, e:TExpr):Null<Value> return EvalPrototype.evalExpr(ctx, kind, e);
}

class EvalPrototype {
	/** JITs expression [e] and executes the result immediately. **/
	public static function evalExpr(ctx:Context, kind:EnvKind, e:TExpr):Null<Value> {
		return switch EvalExceptions.catchExceptions(ctx, () -> {
			var r = EvalJit.jitExpr(ctx, e);
			var jit = r.jit;
			var f = r.f;
			var numCaptures = jit.captures.length();
			var info = EvalContext.createEnvInfo(true, e.epos.pfile, ctx.fileKeys.get(e.epos.pfile), kind, jit.captureInfos,
				jit.maxNumLocals, numCaptures);
			var env = EvalContext.pushEnvironment(ctx, info);
			var v:Value;
			try {
				v = f(env);
			} catch (exc:haxe.Exception) {
				EvalContext.popEnvironment(ctx, env);
				throw exc;
			}
			EvalContext.popEnvironment(ctx, env);
			return v;
		}, e.epos) {
			case Some(v): v;
			case None: null;
		}
	}

	/** Creates constructor function for class [c], if it has a constructor. **/
	public static function createConstructor(ctx:Context, c:TClass):Void {
		var cf = c.clConstructor;
		if (cf != null && cf.cfExpr != null && !TFunctions.hasClassFlag(c, CExtern)) {
			switch cf.cfExpr.eexpr {
				case TFunction(tf):
					var pos = cf.cfExpr.epos;
					var key = EvalHash.pathHash(c.clPath);
					var v = AtomicLazy.fromFun(() -> EvalValueTools.vfunction(EvalJit.jitTfunction(ctx, key, EvalHash.key_new, tf, false,
						pos)));
					ctx.constructors = ctx.constructors.add(key, v);
				case _:
			}
		}
	}

	public static function isRemovableField(cf:TClassField):Bool {
		return TFunctions.hasClassFieldFlag(cf, CfExtern) || TFunctions.hasClassFieldFlag(cf, CfGeneric);
	}

	public static function isPersistent(cf:TClassField):Bool {
		return core.Meta.has(StrictMeta.Persistent, cf.cfMeta);
	}

	// `Some {eexpr = TFunction tf}` (null-safe; Haxe structure patterns do not check for null)
	static function tfunctionOf(e:Null<TExpr>):Null<TFunc> {
		if (e == null) return null;
		return switch e.eexpr {
			case TFunction(tf): tf;
			case _: null;
		}
	}

	// OCaml `compare` on strings (PMap order)
	static function compareString(a:String, b:String):Int return a == b ? 0 : (a < b ? -1 : 1);

	public static function createStaticPrototype(ctx:Context, mt:ModuleType):{init:ProtoInit, delays:Array<StaticDelay>} {
		var path = TFunctions.tPath(mt);
		var key = EvalHash.pathHash(path);
		var com = if (ctx.isMacro) ctx.curapi.getMacroCom() else ctx.curapi.getCom();
		var meta = core.Texpr.buildMetadata(com.basic, mt);
		var o:{init:ProtoInit, delays:Array<StaticDelay>} = switch mt {
			case TClassDecl(c):
				var pparent = switch c.clSuper {
					case null: null;
					case csup: EvalContext.getStaticPrototype(ctx, EvalHash.pathHash(csup.cls.clPath), c.clPos);
				}
				function collectInterfaces(acc:Array<Int>, c:TClass):Array<Int> {
					for (i in c.clImplements)
						acc = collectInterfaces(acc, i.cls);
					acc.unshift(EvalHash.pathHash(c.clPath));
					return acc;
				}
				var interfaces = collectInterfaces([], c);
				var pctx = PrototypeBuilder.create(ctx, key, pparent, PClass(interfaces), meta);
				var fields = c.clOrderedStatics.filter(cf -> !isRemovableField(cf));
				var delays:Array<StaticDelay> = [];
				if (!TFunctions.hasClassFlag(c, CExtern))
					for (cf in fields) {
						switch [cf.cfKind, cf.cfExpr] {
							case [Method(_), _] if (tfunctionOf(cf.cfExpr) != null):
								var tf = tfunctionOf(cf.cfExpr);
								var pos = cf.cfExpr.epos;
								var name = EvalHash.hash(cf.cfName);
								PrototypeBuilder.addProtoField(pctx, name,
									AtomicLazy.fromFun(() -> EvalValueTools.vstaticFunction(EvalJit.jitTfunction(ctx, key, name, tf, true,
										pos))));
							case [Var(_), e] if (e != null):
								var name = EvalHash.hash(cf.cfName);
								PrototypeBuilder.addProtoField(pctx, name, AtomicLazy.fromVal(VNull));
								var i = pctx.fields.length - 1;
								var persistent = isPersistent(cf);
								delays.push({
									persistent: persistent,
									f: proto -> {
										proto.pfields[i] = switch evalExpr(ctx, EKMethod(key, name), e) {
											case null: VNull;
											case e: e;
										}
									}
								});
							case [_, null] if (TFunctions.isPhysicalField(cf)):
								PrototypeBuilder.addProtoField(pctx, EvalHash.hash(cf.cfName), AtomicLazy.fromVal(VNull));
							case _:
						}
					}
				switch core.TOther.TClassTools.getClInit(c) {
					case null:
					case e:
						delays.push({
							persistent: false,
							f: _ -> {
								evalExpr(ctx, EKMethod(key, EvalHash.key___init__), e);
							}
						});
				}
				{init: PrototypeBuilder.finalize(pctx), delays: delays};
			case TEnumDecl(en):
				var names = en.eNames.map(name -> {
					var ef = en.eConstrs.get(name);
					if (ef == null) throw NotFound.raise();
					var args = switch TFunctions.follow(ef.efType) {
						case TFun(sig):
							sig.args.map(a -> EvalHash.hash(a.name));
						case _:
							[];
					}
					{name: name, params: args};
				});
				var pctx = PrototypeBuilder.create(ctx, key, null, PEnum(names), meta);
				inline function enumFieldValue(ef:TEnumField):Value {
					return switch TFunctions.follow(ef.efType) {
						case TFun(_):
							var f = (vl:Array<Value>) -> EvalEncode.encodeEnumValue(key, ef.efIndex, vl.copy(), ef.efPos);
							EvalValueTools.vstaticFunction(f);
						case _:
							EvalEncode.encodeEnumValue(key, ef.efIndex, [], ef.efPos);
					}
				}
				// PMap.iter: ascending key order
				var constrNames = [for (k in en.eConstrs.keys()) k];
				constrNames.sort(compareString);
				for (name in constrNames)
					PrototypeBuilder.addProtoField(pctx, EvalHash.hash(name), AtomicLazy.fromVal(enumFieldValue(en.eConstrs.get(name))));
				{init: PrototypeBuilder.finalize(pctx), delays: []};
			case TAbstractDecl(a):
				var pctx = PrototypeBuilder.create(ctx, key, null, PClass([]), meta);
				{init: PrototypeBuilder.finalize(pctx), delays: []};
			case _:
				Globals.die("", "evalPrototype.ml create_static_prototype");
		}
		function loop(v:Value, name:String, path:Array<String>, i:Int):Void {
			if (i >= path.length) {
				EvalMisc.setField(v, EvalHash.hash(name), EvalValueTools.vprototype(o.init.proto));
			} else {
				var key = EvalHash.hash(path[i]);
				var v2 = EvalField.field(v, key);
				var v2 = switch v2 {
					case VNull: EvalEncode.encodeObj([]);
					case _: v2;
				}
				EvalMisc.setField(v, key, v2);
				loop(v2, name, path, i + 1);
			}
		}
		if (ctx.debug.supportDebugger)
			loop(ctx.toplevel, path.name, path.pack, 0);
		return o;
	}

	public static function createInstancePrototype(ctx:Context, c:TClass):ProtoInit {
		var pparent = switch c.clSuper {
			case null: null;
			case sup: EvalContext.getInstancePrototype(ctx, EvalHash.pathHash(sup.cls.clPath), sup.cls.clPos);
		}
		var key = EvalHash.pathHash(c.clPath);
		var pctx = PrototypeBuilder.create(ctx, key, pparent, PInstance, null);
		var fields = c.clOrderedFields.filter(cf -> !isRemovableField(cf));
		if (TFunctions.hasClassFlag(c, CExtern) && !(c.clPath.pack.length == 0 && c.clPath.name == "String")) {} else
			for (cf in fields) {
				switch [cf.cfKind, cf.cfExpr] {
					case [Method(meth), _] if (tfunctionOf(cf.cfExpr) != null):
						var tf = tfunctionOf(cf.cfExpr);
						var pos = cf.cfExpr.epos;
						var name = EvalHash.hash(cf.cfName);
						var v = AtomicLazy.fromFun(() -> EvalValueTools.vfunction(EvalJit.jitTfunction(ctx, key, name, tf, false, pos)));
						if (meth == MethDynamic)
							PrototypeBuilder.addInstanceField(pctx, name, v);
						PrototypeBuilder.addProtoField(pctx, name, v);
					case [Var(_), _] if (TFunctions.isPhysicalField(cf)):
						var name = EvalHash.hash(cf.cfName);
						PrototypeBuilder.addInstanceField(pctx, name, AtomicLazy.fromVal(VNull));
					case [Method(meth), null] if (TFunctions.hasClassFieldFlag(cf, CfAbstract)):
						var name = EvalHash.hash(cf.cfName);
						var v = AtomicLazy.fromVal(VNull);
						PrototypeBuilder.addProtoField(pctx, name, v);
					case _:
				}
			}
		return PrototypeBuilder.finalize(pctx);
	}

	/** Upstream `List.sort` (stable) on the hashed names. **/
	public static function sortObjectFields<T>(l:Array<{name:Int, value:T}>):Array<{name:Int, value:T}> {
		var l = l.copy();
		haxe.ds.ArraySort.sort(l, (f1, f2) -> {
			var i1 = f1.name, i2 = f2.name;
			if (i1 == i2) 0
			else if (i1 < i2) -1
			else 1;
		});
		return l;
	}

	/** Upstream `get_object_prototype`: the prototype and the sorted fields. **/
	public static function getObjectPrototypeSorted<T>(ctx:Context,
			l:Array<{name:Int, value:T}>):{proto:Vprototype, sorted:Array<{name:Int, value:T}>} {
		var l = sortObjectFields(l);
		var name = {
			var ids = l.map(f -> f.name);
			var cacheKey = ids.join(",");
			var cached = ctx.objectNameCache.get(cacheKey);
			if (cached != null) cached
			else {
				var sfields = ids.map(i -> ":" + EvalHash.revHash(i)).join(",");
				var name = EvalHash.hash("eval.object.Object[" + sfields + "]");
				ctx.objectNameCache.set(cacheKey, name);
				name;
			}
		}
		var proto = try {
			ctx.instancePrototypes.find(name);
		} catch (_:NotFound) {
			var pctx = PrototypeBuilder.create(ctx, name, null, PObject, null);
			for (f in l)
				PrototypeBuilder.addInstanceField(pctx, f.name, AtomicLazy.fromVal(VNull));
			var proto = PrototypeBuilder.finalize(pctx).proto;
			ctx.instancePrototypes = ctx.instancePrototypes.add(name, proto);
			proto;
		}
		return {proto: proto, sorted: l};
	}

	/** The function stored in `Context.getObjectPrototype` (see the module comment). **/
	public static function getObjectPrototype(ctx:Context, l:Array<Int>):Vprototype {
		return getObjectPrototypeSorted(ctx, l.map(i -> {name: i, value: (null : Null<Value>)})).proto;
	}

	static function addTypesImpl(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		var newTypes = types.filter(mt -> {
			var inf = TFunctions.tInfos(mt);
			var key = EvalHash.pathHash(inf.mtPath);
			try {
				var inf2 = TFunctions.tInfos(ctx.typeCache.find(key));
				if (inf2.mtModule.mId != inf.mtModule.mId) throw NotFound.raise();
				false;
			} catch (_:NotFound) {
				ctx.instancePrototypes = ctx.instancePrototypes.remove(key);
				ctx.staticPrototypes.remove(key);
				ctx.constructors = ctx.constructors.remove(key);
				ready(mt);
				ctx.typeCache = ctx.typeCache.add(key, mt);
				if (ctx.debug.supportDebugger) {
					throw EvalMain.debuggerNotSupported();
				}
				true;
			}
		});
		// 1. Create prototypes and register them.
		var flInstance:Array<ProtoInit> = [];
		var flStatic:Array<{init:ProtoInit, delays:Array<StaticDelay>}> = [];
		for (mt in newTypes) {
			switch mt {
				case TClassDecl(c):
					function loop(p:Null<{cls:TClass, params:TParams}>, f:TClassField):Bool {
						return switch p {
							case null: false;
							case {cls: p}:
								if (p.clFields.exists(f.cfName) || loop(p.clSuper, f)) {
									ctx.overrides.set(Globals.sTypePath(p.clPath) + "." + f.cfName, true);
									true;
								} else false;
						}
					}
					for (f in c.clOrderedFields)
						if (TFunctions.hasClassFieldFlag(f, CfOverride))
							loop(c.clSuper, f);
					createConstructor(ctx, c);
					flInstance.push(createInstancePrototype(ctx, c));
					flStatic.push(createStaticPrototype(ctx, mt));
				case TEnumDecl(en):
					flStatic.push(createStaticPrototype(ctx, mt));
				case TAbstractDecl(a):
					flStatic.push(createStaticPrototype(ctx, mt));
					/* Create a fake instance prototype for coreType abstracts in case something inspects them (#8778).
						Also do this for extern abstracts with Any as underlying type - these are native opaque types
						that use the typedef trick to satisfy @:coreApi checks. */
					var isNativeOpaque = a.aExtern && switch TFunctions.follow(a.aThis) {
						case TAbstract({aPath: {pack: [], name: "Any"}}, _): true;
						case _: false;
					} if (core.Meta.has(StrictMeta.CoreType, a.aMeta) || isNativeOpaque) {
						var c = TFunctions.nullClass.clone();
						c.clPath = a.aPath;
						flInstance.push(createInstancePrototype(ctx, c));
					}
				case _:
			}
		}
		// 2. Create instance fields.
		for (pf in flInstance)
			pf.init(pf.proto);
		// 3. Create static fields.
		var flStaticInit:Array<{proto:Vprototype, delays:Array<StaticDelay>}> = [];
		for (s in flStatic) {
			var proto = s.init.proto;
			s.init.init(proto);
			var delays = s.delays;
			if (delays.length > 0) {
				flStaticInit.push({proto: proto, delays: delays});
				var nonPersistentDelays = [for (d in delays) if (!d.persistent) d.f];
				ctx.staticPrototypes.addInit(proto, nonPersistentDelays);
			}
		}
		// 4. Initialize static fields.
		for (s in flStaticInit)
			for (d in s.delays)
				d.f(s.proto);
	}

	public static function addTypes(ctx:Context, types:Array<ModuleType>, ready:ModuleType->Void):Void {
		core.Timer.time(ctx.timerCtx, [(if (ctx.isMacro) "macro" else "interp"), "add_types"], (ready:ModuleType->Void) -> {
			addTypesImpl(ctx, types, ready);
			return true;
		}, ready);
	}
}

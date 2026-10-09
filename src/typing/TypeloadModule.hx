package typing;

import core.Ast;
import core.Ast.TypeDecl;
import core.ClassPaths;
import core.ClassPaths.ResolvedFile;
import core.Define;
import core.Define.DefineContext;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import haxe.ds.IntMap;
import haxe.ds.ObjectMap;
import haxe.ds.StringMap;
import typing.TypeloadParse.ParseError;

// Batch-only port of the module-loading and typing path rooted in
// haxe/src/typing/typeloadModule.ml and typer.ml.
class TypeloadModule {
	// haxe/src/typing/typeloadModule.ml: make_curmod.
	public static function makeCurmod(com:context.Common.CommonContext, g:context.Typecore.TyperGlobals,
			m:ModuleDef):context.Typecore.TyperModule {
		return {
			curmod: m,
			importResolution: g.rootTyper.m.importResolution.cloneAs(["import", Globals.sTypePath(m.mPath)]),
			ownResolution: null,
			enumWithType: null,
			moduleUsing: [],
			importStatements: [],
			isDisplayFile: com.display.dmsKind != core.DisplayTypes.DisplayModeValue.DMNone
			&& core.display.DisplayPosition.displayPosition.isInFile(core.Path.UniqueKey.lazyKey(m.mExtra.mFile))};
	}

	var classPaths:ClassPaths;
	var defines:DefineContext;
	var modules:Map<String, ModuleDef> = new Map();
	var moduleImports:Map<String, StringMap<{var modulePath:GlobalTypePath; var typeName:String;}>> = new Map();
	var basicTypes:Map<String, T> = new Map();
	var basicModule:ModuleDef;
	var nextModuleId = 0;
	// tFunctions.ml's alloc_var uses Atomic.fetch_and_add + 1.
	var nextVarId = 1;
	var currentMethodName = "";
	var activeTypeParams:StringMap<T> = new StringMap();
	var deferredClassBodies:Array<Void->Void> = [];
	var deferredDependencyBodies:Array<Void->Void> = [];
	var bodyTypingDepth = 0;
	var moduleLoadDepth = 0;

	public function new(classPaths:ClassPaths, defines:DefineContext) {
		this.classPaths = classPaths;
		this.defines = defines;
		basicModule = {
			mId: -1,
			mPath: {pack: [], name: "StdTypes"},
			mTypes: [],
			mStatics: null,
			mExtra: {
				mFile: core.Path.UniqueKey.createLazy("<built-in>"),
				mSign: "",
				mDisplay: {mInlineCalls: [], mTypeHints: [], mImportPositions: new Map()},
				mCheckPolicy: [],
				mTime: 0,
				mCacheState: MSUnknown,
				mAdded: 0,
				mChecked: 0,
				mProcessed: 0,
				mDeps: new IntMap(),
				mDisplayDeps: null,
				mKind: MFake,
				mCacheBoundObjects: [],
				mFeatures: new Map()
			}
		};
		for (name in ["Void", "Int", "Float", "Bool", "String"]) basicTypes.set(name, makeBasicType(name));
	}

	public function resolveModuleFile(path:GlobalTypePath):ResolvedFile {
		return classPaths.findFile(path.pack.concat([path.name]).join("/") + ".hx");
	}

	public function loadModule(path:GlobalTypePath):ModuleDef {
		var key = moduleKey(path);
		if (modules.exists(key)) return modules.get(key);
		var resolved = resolveModuleFile(path);
		var parsed = TypeloadParse.parseFile(defines, resolved);
		if (!samePath(path.pack,
			parsed.data.pack)) throw new ParseError('Module package does not match file path ' + Globals.sTypePath(path), {
				pfile: parsed.file,
				pmin: 0,
				pmax: 0
			});
		rejectMacroMetadata(parsed.data.declarations);
		var module = makeModule(path, resolved.file);
		modules.set(key, module); // upstream installs the module before creating types.
		moduleLoadDepth++;
		try createModuleTypes(module, parsed.data.declarations)
		catch (error:haxe.Exception) {
			modules.remove(key);
			moduleImports.remove(key);
			moduleLoadDepth--;
			throw error;
		}
		moduleLoadDepth--;
		if (moduleLoadDepth == 0) flushDeferredDependencyBodies();
		return module;
	}

	public function findModule(path:GlobalTypePath):Null<ModuleDef> return modules.get(moduleKey(path));

	function rejectMacroMetadata(declarations:Array<TypeDecl>):Void {
		for (declaration in declarations) {
			var metadata = switch declaration.definition {
				case EClass(value): value.meta;
				case EEnum(value): value.meta;
				case ETypedef(value): value.meta;
				case EAbstract(value): value.meta;
				case EStatic(value): value.meta;
				case EImport(_) | EUsing(_): [];
			};
			for (entry in metadata) {
				var name = Std.string(entry.meta);
				if (name == "build" || name == ":build" || name == "autoBuild" || name == ":autoBuild" || name == "genericBuild"
					|| name == ":genericBuild")
					throw 'Macro metadata @$name requires the Eval macro milestone';
			}
		}
	}

	function tryLoadModule(path:GlobalTypePath):Null<ModuleDef> try return loadModule(path)
	catch (error:Dynamic) {
		if (Std.string(error) == "Not_found") return null;
		throw error;
	}

	/** First step of typerEntry.load_std_types. Basic-type rebinding follows once
		type parameters and abstract typing are available. */
	public function loadStdTypes():ModuleDef return loadModule({pack: [], name: "StdTypes"});

	/** Initial batch subset of typerEntry.create's standard-library sequence.
		Enum/iterator/call-stack modules follow once their typed dependencies are
		available. */
	public function loadStdBootstrap():Void {
		var stdTypes = loadStdTypes();
		for (name in ["Void", "Int", "Float", "Bool"]) switch findModuleType(stdTypes, name) {
			case TAbstractDecl(abs):
				basicTypes.set(name, TAbstract(abs, []));
			case _:
		}
		loadModule({pack: [], name: "Any"});
		var stringModule = loadModule({pack: [], name: "String"});
		switch findModuleType(stringModule, "String") {
			case TClassDecl(cls):
				basicTypes.set("String", TInst(cls, []));
			case _:
		}
		loadModule({pack: [], name: "Std"});
		loadModule({pack: [], name: "Array"});
		loadModule({pack: ["haxe"], name: "EnumTools"});
		loadModule({pack: ["haxe"], name: "Exception"});
		loadModule({pack: ["haxe"], name: "NativeStackTrace"});
		loadModule({pack: ["haxe", "iterators"], name: "ArrayKeyValueIterator"});
		loadModule({pack: [], name: "IntIterator"});
		loadModule({pack: [], name: "Enum"});
		loadModule({pack: [], name: "EnumValue"});
		loadModule({pack: [], name: "Type"});
		loadModule({pack: [], name: "StringBuf"});
	}

	/** Modules in the order they were allocated, matching the batch load graph. */
	public function loadedModules():Array<ModuleDef> {
		var result = [for (module in modules) module];
		result.sort(function(a, b) return a.mId - b.mId);
		return result;
	}

	function makeModule(path:GlobalTypePath, file:String):ModuleDef {
		return {
			mId: nextModuleId++,
			mPath: path,
			mTypes: [],
			mStatics: null,
			mExtra: {
				mFile: core.Path.UniqueKey.createLazy(sys.FileSystem.fullPath(file)),
				mSign: Define.getSignature(defines),
				mDisplay: {mInlineCalls: [], mTypeHints: [], mImportPositions: new Map()},
				mCheckPolicy: [],
				mTime: 0,
				mCacheState: MSUnknown,
				mAdded: 0,
				mChecked: 0,
				mProcessed: 0,
				mDeps: new IntMap(),
				mDisplayDeps: null,
				mKind: MCode,
				mCacheBoundObjects: [],
				mFeatures: new Map()
			}
		};
	}

	function createModuleTypes(module:ModuleDef, declarations:Array<TypeDecl>):Void {
		var imports = new StringMap<{var modulePath:GlobalTypePath; var typeName:String;}>();
		for (declaration in declarations) switch declaration.definition {
			case EImport(value) if (value.path.length > 0):
				var names = [for (part in value.path) part.name];
				var moduleIndex = 0;
				while (moduleIndex < names.length - 1 && Ast.isLowerIdent(names[moduleIndex])) moduleIndex++;
				var importedType = names[names.length - 1];
				var alias = switch value.mode {
					case INormal: importedType;
					case IAsName(name): name.name;
					case IAll: null;
				};
				if (alias != null) imports.set(alias, {
					modulePath: {pack: names.slice(0, moduleIndex), name: names[moduleIndex]},
					typeName: importedType
				});
			case _:
		}
		moduleImports.set(moduleKey(module.mPath), imports);
		// Like typeload's first pass, allocate every declaration before looking at
		// fields. This makes references to later declarations in the same module
		// available while field signatures are built.
		for (declaration in declarations) switch declaration.definition {
			case EClass(value):
				module.mTypes.push(TClassDecl(makeClass(module, value, declaration.pos)));
			case EEnum(value):
				module.mTypes.push(TEnumDecl(makeEnum(module, value, declaration.pos)));
			case ETypedef(value):
				module.mTypes.push(TTypeDecl(makeDef(module, value, declaration.pos)));
			case EAbstract(value):
				var abs = makeAbstract(module, value, declaration.pos);
				module.mTypes.push(TAbstractDecl(abs));
				// typeloadModule.ml creates a private implementation class for every
				// abstract except a fieldless @:coreType declaration.
				if (value.data.length != 0 || !hasMetadata(value.meta, "coreType")) {
					var definition:ClassDefinition = {
						name: {name: value.name.name + "_Impl_", pos: value.name.pos},
						doc: null,
						params: [],
						meta: [],
						flags: [HPrivate],
						data: []
					};
					var impl = makeClass(module, definition, declaration.pos);
					impl.clKind = KAbstractImpl(abs);
					impl.clFlags |= classFlag(CFinal);
					impl.clMeta = [
						for (entry in value.meta) if (hasMetadata([entry], "allow") || hasMetadata([entry], "using")) entry
					];
					impl.clMeta.reverse();
					abs.aImpl = impl;
					module.mTypes.push(TClassDecl(impl));
				}
			case EImport(_) | EUsing(_) | EStatic(_):
		}
		var moduleFields:Array<ClassField> = [];
		var moduleFieldsPos:Null<Pos> = null;
		for (declaration in declarations) switch declaration.definition {
			case EStatic(value):
				if (moduleFieldsPos == null) moduleFieldsPos = declaration.pos;
				moduleFields.push({
					cffName: value.name,
					cffDoc: value.doc,
					cffPos: declaration.pos,
					cffMeta: value.meta,
					cffAccess: ([{access: AStatic, pos: Globals.nullPos}] : Array<core.Ast.PlacedAccess>).concat(value.flags),
					cffKind: value.data
				});
			case _:
		}
		if (moduleFields.length > 0) {
			var position = moduleFieldsPos;
			var definition:ClassDefinition = {
				name: {name: module.mPath.name + "_Fields_", pos: Globals.nullPos},
				doc: null,
				params: [],
				meta: [],
				flags: [HPrivate],
				data: moduleFields
			};
			var fieldsClass = makeClass(module, definition, {pfile: position.pfile, pmin: position.pmin, pmax: position.pmin});
			fieldsClass.clKind = KModuleFields(module);
			fieldsClass.clFlags |= classFlag(CFinal);
			module.mStatics = fieldsClass;
			module.mTypes.push(TClassDecl(fieldsClass));
		}
		// typeloadModule.ml initializes all module-level type parameters after the
		// shells exist, so recursive constraints can resolve sibling declarations.
		for (declaration in declarations) switch declaration.definition {
			case EClass(value):
				var cls = findClass(module, value.name.name);
				cls.clParams = makeTypeParams(module, cls.clPath, value.params, TPHType);
				cls.clType = TInst(cls, [for (param in cls.clParams) param.ttpType]);
			case EEnum(value):
				var en = findEnum(module, value.name.name);
				en.eParams = makeTypeParams(module, en.ePath, value.params, TPHType);
				en.eType = TEnum(en, [for (param in en.eParams) param.ttpType]);
			case ETypedef(value):
				var def = switch findModuleType(module, value.name.name) {
					case TTypeDecl(value): value;
					case _: throw "Expected typedef";
				};
				def.tParams = makeTypeParams(module, def.tPath, value.params, TPHType);
			case EAbstract(value):
				var abs = findAbstract(module, value.name.name);
				abs.aParams = makeTypeParams(module, abs.aPath, value.params, TPHType);
				if (abs.aImpl != null) {
					abs.aImpl.clParams = abs.aParams;
					abs.aImpl.clType = TInst(abs.aImpl, [for (param in abs.aParams) param.ttpType]);
				}
			case EImport(_) | EUsing(_) | EStatic(_):
		}
		// Typedef bodies are loaded after every declaration and type parameter shell
		// exists. This is required for recursive/sibling aliases and keeps their
		// parameter references (such as Iterator<T>) structural instead of Dynamic.
		for (declaration in declarations) switch declaration.definition {
			case ETypedef(value):
				var def = switch findModuleType(module, value.name.name) {
					case TTypeDecl(value): value;
					case _: throw "Expected typedef";
				};
				var previousTypeParams = activeTypeParams;
				activeTypeParams = typeParamMap(def.tParams);
				def.tType = resolveTypeHint(module, value.data);
				activeTypeParams = previousTypeParams;
			case _:
		}
		// The upstream loader installs inheritance after all module type shells
		// exist, so references to later declarations in the same module work too.
		for (declaration in declarations) switch declaration.definition {
			case EClass(value):
				var cls = findClass(module, value.name.name);
				var previousTypeParams = activeTypeParams;
				activeTypeParams = typeParamMap(cls.clParams);
				for (flag in value.flags) switch flag {
					case HExtends(path):
						var parent = resolvePath(module, path.path);
						switch parent {
							case TInst(parentClass, params): cls.clSuper = {cls: parentClass, params: params};
							case _: throw 'Superclass of ${cls.clPath.name} must be a class';
						}
					case HImplements(path):
						var implemented = resolvePath(module, path.path);
						switch implemented {
							case TInst(interfaceClass, params): cls.clImplements.push({cls: interfaceClass, params: params});
							case _: throw 'Implemented type of ${cls.clPath.name} must be a class';
						}
					case _:
				}
				activeTypeParams = previousTypeParams;
			case _:
		}
		// Standard-library implementation bodies are not needed to resolve the
		// signatures used by a user module (notably haxe.Log.trace). Keeping this
		// pass signature-only also mirrors the dependency loading boundary in the
		// upstream typer and avoids pulling target-specific implementation code
		// into a batch module.
		var typeBodies = module.mPath.pack.length == 0
			|| module.mPath.pack[0] != "haxe"
			|| (module.mPath.pack.length > 1 && module.mPath.pack[1] == "iterators")
			|| (module.mPath.pack.length > 1 && module.mPath.pack[1] == "zip")
			|| (module.mPath.pack.length == 1 && (module.mPath.name == "EnumTools" || module.mPath.name == "CallStack"));
		for (declaration in declarations) switch declaration.definition {
			case EClass(value):
				populateClassFields(module, findClass(module, value.name.name), value.data, typeBodies);
			case EEnum(value):
				populateEnumConstructors(module, findEnum(module, value.name.name), value.data);
			case EAbstract(value):
				initializeAbstract(module, findAbstract(module, value.name.name), value, typeBodies);
			case ETypedef(_) | EImport(_) | EUsing(_) | EStatic(_):
		}
		if (module.mStatics != null) populateClassFields(module, module.mStatics, moduleFields, typeBodies);
	}

	function initializeAbstract(module:ModuleDef, abs:TAbstract, definition:AbstractDefinition, typeBodies:Bool):Void {
		var previousTypeParams = activeTypeParams;
		activeTypeParams = typeParamMap(abs.aParams);
		var hasUnderlying = false;
		for (abstractFlag in definition.flags) switch abstractFlag {
			case AbOver(type):
				abs.aThis = resolveTypeHint(module, type);
				hasUnderlying = true;
			case AbFrom(type):
				abs.aFrom.push(resolveTypeHint(module, type));
			case AbTo(type):
				abs.aTo.push(resolveTypeHint(module, type));
			case AbPrivate | AbExtern | AbEnum:
		}
		if (!hasUnderlying && hasMetadata(definition.meta, "coreType")) abs.aThis = TAbstract(abs, []);
		if (abs.aImpl != null) populateAbstractFields(module, abs, definition.data, typeBodies);
		activeTypeParams = previousTypeParams;
	}

	function populateAbstractFields(module:ModuleDef, abs:TAbstract, fields:Array<ClassField>, typeBodies:Bool):Void {
		var transformed:Array<ClassField> = [];
		for (field in fields) {
			var isMember = !hasAccess(field, AStatic);
			var accesses = field.cffAccess.copy();
			if (isMember) accesses.push({access: AStatic, pos: Globals.nullPos});
			var kind = switch field.cffKind {
				case FFun(func) if (isMember && field.cffName.name != "new"):
					var args = func.fArgs.copy();
					args.unshift({
						name: {name: "this", pos: Globals.nullPos},
						optional: false,
						meta: [{meta: "this", exprs: [], pos: Globals.nullPos}],
						type: {
							type: CTPath(Ast.makePtp(Ast.mkTypePath(abs.aPath.pack, abs.aPath.name), Globals.nullPos)),
							pos: Globals.nullPos
						},
						expr: null
					});
					FFun({
						fParams: func.fParams,
						fArgs: args,
						fType: func.fType,
						fExpr: func.fExpr
					});
				case other: other;
			};
			transformed.push({
				cffName: field.cffName,
				cffDoc: field.cffDoc,
				cffPos: field.cffPos,
				cffMeta: field.cffMeta,
				cffAccess: accesses,
				cffKind: kind
			});
		}
		populateClassFields(module, abs.aImpl, transformed, typeBodies);
		for (index in 0...fields.length) {
			var source = fields[index];
			var typed = abs.aImpl.clStatics.get(source.cffName.name);
			if (typed == null) continue;
			if (!hasAccess(source, AStatic)) typed.cfFlags |= flag(CfImpl);
			if (hasMetadata(source.cffMeta, "arrayAccess")) abs.aArray.push(typed);
			if (hasMetadata(source.cffMeta, "to")) abs.aToField.push({
				type: switch typed.cfType {
					case TFun(signature): signature.ret;
					case other: other;
				},
				field: typed
			});
			if (hasMetadata(source.cffMeta, "from")) abs.aFromField.push({
				type: switch typed.cfType {
					case TFun(signature): signature.args.length == 0 ? TDynamic(null) : signature.args[signature.args.length - 1].type;
					case other: other;
				},
				field: typed
			});
		}
	}

	function populateClassFields(module:ModuleDef, cls:TClass, fields:Array<ClassField>, typeBodies:Bool):Void {
		for (field in fields) {
			if (hasAccess(field, AMacro)) throw 'Macro field ${cls.clPath.name}.${field.cffName.name} requires the Eval macro milestone';
			var isStatic = hasAccess(field, AStatic);
			var params = switch field.cffKind {
				case FFun(func): makeTypeParams(module, {pack: [], name: field.cffName.name}, func.fParams, TPHMethod);
				case _: [];
			};
			var previousTypeParams = activeTypeParams;
			activeTypeParams = typeParamMap(cls.clParams.concat(params));
			var type = fieldType(module, cls, field);
			activeTypeParams = previousTypeParams;
			var metadata = field.cffMeta.copy();
			switch field.cffKind {
				case FVar(_, value) | FProp(_, _, _, value) if (value != null):
					metadata.unshift({
						meta: ":value",
						exprs: [value],
						pos: {
							pfile: field.cffPos.pfile,
							pmin: field.cffPos.pmin,
							pmax: field.cffPos.pmin
						}
					});
				case FFun(func):
					var defaults = [
						for (arg in func.fArgs) if (arg.expr != null) ({
							key: {name: arg.name.name, pos: arg.name.pos, quote: NoQuotes},
							expr: arg.expr
						} : core.Ast.ObjectField)
					];
					if (defaults.length > 0) metadata.unshift({
						meta: ":value",
						exprs: [{expr: EObjectDecl(defaults), pos: Globals.nullPos}],
						pos: Globals.nullPos
					});
				case _:
			}
			var typed:TClassField = {
				cfName: field.cffName.name,
				cfType: type,
				cfPos: field.cffPos,
				cfNamePos: field.cffName.pos,
				cfDoc: field.cffDoc,
				cfMeta: metadata,
				cfKind: fieldKind(field),
				cfParams: params,
				cfExpr: null,
				cfExprUnoptimized: null,
				cfOverloads: [],
				cfFlags: fieldFlags(field, isStatic, (cls.clFlags & classFlag(CExtern)) != 0)
			};
			if (field.cffName.name == "new" && !isStatic) cls.clConstructor = typed;
			else if (isStatic) {
				var existing = cls.clStatics.get(typed.cfName);
				if (existing != null && hasAccess(field, AOverload)) existing.cfOverloads.push(typed);
				else {
					cls.clStatics.set(typed.cfName, typed);
					cls.clOrderedStatics.push(typed);
				}
			} else {
				var existing = cls.clFields.get(typed.cfName);
				if (existing != null && hasAccess(field, AOverload)) existing.cfOverloads.push(typed);
				else {
					cls.clFields.set(typed.cfName, typed);
					cls.clOrderedFields.push(typed);
				}
			}
		}
		// Signatures have to be installed before bodies are typed: a method body
		// may call a method declared later in the same class.
		if (typeBodies) {
			var typeBodiesNow = function() {
				bodyTypingDepth++;
				typeClassFieldBodies(module, cls, fields);
				bodyTypingDepth--;
			};
			if (!hasFieldBodies(fields)) {} else if (moduleLoadDepth > 1 && module.mPath.pack.length == 1
				&& module.mPath.pack[0] == "haxe" && module.mPath.name == "CallStack") deferredDependencyBodies.push(typeBodiesNow);
			else if ((bodyTypingDepth > 0
				&& !(module.mPath.pack.length > 1 && module.mPath.pack[0] == "haxe" && module.mPath.pack[1] == "zip"))
				|| (module.mPath.pack.length > 1 && module.mPath.pack[0] == "haxe" && module.mPath.pack[1] == "iterators"))
				deferredClassBodies.push(typeBodiesNow);
			else {
				flushDeferredClassBodies();
				typeBodiesNow();
			}
		} else for (field in fields) switch field.cffKind {
			case FFun(func) if (func.fExpr != null):
				// The upstream typer allocates argument IDs even for bodies which this
				// batch slice defers. Keep the global ID stream deterministic for HXB.
				for (arg in func.fArgs) makeVar(arg.name.name, TDynamic(null), TVOArgument, arg.name.pos, arg.meta);
			case _:
		}
	}

	static function hasFieldBodies(fields:Array<ClassField>):Bool {
		for (field in fields) switch field.cffKind {
			case FFun(func) if (func.fExpr != null):
				return true;
			case FVar(_, value) | FProp(_, _, _, value) if (value != null):
				return true;
			case _:
		}
		return false;
	}

	function flushDeferredClassBodies():Void {
		while (deferredClassBodies.length > 0) deferredClassBodies.pop()();
	}

	function flushDeferredDependencyBodies():Void while (deferredDependencyBodies.length > 0) deferredDependencyBodies.shift()();

	function typeClassFieldBodies(module:ModuleDef, cls:TClass, fields:Array<ClassField>):Void {
		var overloadIndices = new StringMap<Int>();
		for (field in fields) {
			var primary = hasAccess(field,
				AStatic) ? cls.clStatics.get(field.cffName.name) : (field.cffName.name == "new" ? cls.clConstructor : cls.clFields.get(field.cffName.name));
			if (primary == null) throw 'Typed field ${cls.clPath.name}.${field.cffName.name} was not installed';
			var overloadKey = (hasAccess(field, AStatic) ? "static:" : "member:") + field.cffName.name;
			var overloadIndex = overloadIndices.exists(overloadKey) ? overloadIndices.get(overloadKey) : 0;
			var typed = overloadIndex == 0 ? primary : primary.cfOverloads[overloadIndex - 1];
			if (typed == null) throw 'Typed overload ${cls.clPath.name}.${field.cffName.name}[$overloadIndex] was not installed';
			overloadIndices.set(overloadKey, overloadIndex + 1);
			var previousTypeParams = activeTypeParams;
			activeTypeParams = typeParamMap(cls.clParams.concat(typed.cfParams));
			switch field.cffKind {
				case FVar(_, value) | FProp(_, _, _, value):
					if (value != null) typed.cfExpr = typeExpr(module, cls, value, new StringMap());
				case FFun(func):
					if (func.fExpr != null && canTypeExpression(func.fExpr)) {
						var signature = switch typed.cfType {
							case TFun(value): value;
							case _: ({args: [], ret: TDynamic(null)} : core.TType.TSignature);
						};
						typed.cfExpr = typeFunction(module, cls, field.cffName.name, func, signature);
						if (func.fType == null && field.cffName.name != "new") {
							var inferred = inferReturnType(typed.cfExpr);
							if (inferred != null) {
								signature.ret = inferred;
								typed.cfType = TFun(signature);
								typed.cfExpr.etype = typed.cfType;
								switch typed.cfExpr.eexpr {
									case TFunction(value): value.tfType = inferred;
									case _:
								}
							}
						}
					} else if (func.fExpr != null)
						throw 'Unsupported expression in ${Globals.sTypePath(module.mPath)}.${field.cffName.name}';
			}
			if (typed.cfExpr != null && switch typed.cfKind {
					case Method(MethInline): true;
					case _: false;
				}) {
				typed.cfExprUnoptimized = typed.cfExpr;
				typed.cfExpr = optimizeExpression(typed.cfExpr);
				}
			activeTypeParams = previousTypeParams;
		}
	}

	function canTypeExpression(source:Expr):Bool return switch source.expr {
		case EConst(_): true;
		case EParenthesis(value) | EThrow(value): canTypeExpression(value);
		case EArray(array, index) | EBinop(_, array, index): canTypeExpression(array) && canTypeExpression(index);
		case EField(value, _, _) | EUnop(_, _, value): canTypeExpression(value);
		case EObjectDecl(fields): core.ds.ArrayTools.foreach(fields, function(field) return canTypeExpression(field.expr));
		case EArrayDecl([value]) if (switch value.expr {
				case EFor(_, _): true;
				case _: false;
			}): true;
		case EArrayDecl(values) | EBlock(values): core.ds.ArrayTools.foreach(values, canTypeExpression);
		case ECall(value, args): canTypeExpression(value) && core.ds.ArrayTools.foreach(args, canTypeExpression);
		case ENew(_, args): core.ds.ArrayTools.foreach(args, canTypeExpression);
		case EFunction(_, func): func.fExpr == null || canTypeExpression(func.fExpr);
		case EVars(vars): core.ds.ArrayTools.foreach(vars, function(value) return value.evExpr == null || canTypeExpression(value.evExpr));
		case EIf(condition, thenExpr, elseExpr): canTypeExpression(condition) && canTypeExpression(thenExpr) && (elseExpr == null
				|| canTypeExpression(elseExpr));
		case ETernary(condition, thenExpr, elseExpr): canTypeExpression(condition) && canTypeExpression(thenExpr) && canTypeExpression(elseExpr);
		case EWhile(condition, body, _): canTypeExpression(condition) && canTypeExpression(body);
		case EReturn(value): value == null || canTypeExpression(value);
		case EBreak | EContinue: true;
		case ECast(value, _) | ECheckType(value, _): canTypeExpression(value);
		case EFor(iterator, body): canTypeExpression(iterator) && canTypeExpression(body);
		case EMeta(_, value): canTypeExpression(value);
		case EUntyped(value): canTypeExpression(value);
		case ESwitch(subject, cases, defaultCase): canTypeExpression(subject) && core.ds.ArrayTools.foreach(cases,
				function(item) return item.guard == null
					&& core.ds.ArrayTools.foreach(item.values, isSupportedPattern)
					&& (item.expr == null || canTypeExpression(item.expr))) && (defaultCase == null || defaultCase.expr == null
				|| canTypeExpression(defaultCase.expr));
		case ETry(body, catches): canTypeExpression(body) && core.ds.ArrayTools.foreach(catches,
				function(item) return canTypeExpression(item.expr));
		case EIs(value, _): canTypeExpression(value);
		case EDisplay(_, _): false;
	};

	static function isSupportedPattern(value:Expr):Bool return switch value.expr {
		case EConst(_): true;
		case ECall({expr: EConst(Ident(_))}, args): core.ds.ArrayTools.foreach(args, function(arg) return switch arg.expr {
				case EConst(Ident(_)): true;
				case _: false;
			});
		case EArrayDecl(values): core.ds.ArrayTools.foreach(values, isSupportedPattern);
		case _: false;
	};

	static function moduleTypeOf(type:T):Null<ModuleType> return switch type {
		case TInst(value, _): TClassDecl(value);
		case TEnum(value, _): TEnumDecl(value);
		case TType(value, _): TTypeDecl(value);
		case TAbstract(value, _): TAbstractDecl(value);
		case _: null;
	};

	function optimizeExpression(expression:TExpr):TExpr {
		function optimize(value:TExpr):TExpr return switch value.eexpr {
			case TFunction(func): typed(TFunction({tfArgs: func.tfArgs, tfType: func.tfType, tfExpr: optimize(func.tfExpr)}), value.etype,
					value.epos);
			case TBlock(values): typed(TBlock([for (item in values) optimize(item)]), value.etype, value.epos);
			case TBinop(op, left, right): typed(TBinop(op, optimize(left), optimize(right)), value.etype, value.epos);
			case TParenthesis(inner):
				switch inner.eexpr {
					case TIf(condition, thenExpr, elseExpr):
						var optimizedThen = optimize(thenExpr);
						var optimizedElse = elseExpr == null ? null : optimize(elseExpr);
						var thenValue = switch optimizedThen.eexpr {
							case TBlock([item]): item;
							case _: optimizedThen;
						};
						var elseValue = optimizedElse == null ? null : switch optimizedElse.eexpr {
							case TBlock([item]): item;
							case _: optimizedElse;
						};
						var optimizedCondition = optimize(condition);
						var parenthesized = typed(TParenthesis(optimizedCondition), optimizedCondition.etype, optimizedCondition.epos);
						typed(TIf(parenthesized, thenValue, elseValue), inner.etype, value.epos);
					case _: typed(TParenthesis(optimize(inner)), value.etype, value.epos);
				}
			case TIf(condition, thenExpr,
				elseExpr): typed(TIf(optimize(condition), optimize(thenExpr), elseExpr == null ? null : optimize(elseExpr)), value.etype,
					value.epos);
			case _: value;
		};
		return optimize(expression);
	}

	function makeTypeParams(module:ModuleDef, hostPath:GlobalTypePath, params:Array<TypeParam>, host:TypeParamHost):TypeParams {
		var result:TypeParams = [];
		for (param in params) {
			var cls:TClass = null;
			var typedParam:TypedTypeParam = null;
			cls = {
				clPath: {pack: hostPath.pack.concat([hostPath.name]), name: param.tpName.name},
				clModule: module,
				clPos: param.tpName.pos,
				clNamePos: param.tpName.pos,
				clPrivate: false,
				clDoc: null,
				clMeta: param.tpMeta,
				clParams: [],
				clUsing: [],
				clRestore: function() {},
				clType: TDynamic(null),
				clKind: KNormal,
				clFlags: 0,
				clSuper: null,
				clImplements: [],
				clFields: new StringMap(),
				clStatics: new StringMap(),
				clOrderedStatics: [],
				clOrderedFields: [],
				clDynamic: null,
				clArrayAccess: null,
				clConstructor: null,
				clInit: null,
				clBuild: function() return Built,
				clDescendants: []
			};
			typedParam = {
				ttpName: param.tpName.name,
				ttpClass: cls,
				ttpHost: host,
				ttpType: TDynamic(null),
				ttpConstraints: null,
				ttpDefault: null
			};
			cls.clKind = KTypeParameter(typedParam);
			cls.clType = TInst(cls, []);
			typedParam.ttpType = cls.clType;
			result.push(typedParam);
		}
		var previousTypeParams = activeTypeParams;
		activeTypeParams = new StringMap<T>();
		for (name => type in previousTypeParams) activeTypeParams.set(name, type);
		for (param in result) activeTypeParams.set(param.ttpName, param.ttpType);
		for (index in 0...params.length) {
			var source = params[index];
			var target = result[index];
			if (source.tpConstraints != null) {
				var constraints = switch source.tpConstraints.type {
					case CTIntersection(types): [for (type in types) resolveTypeHint(module, type)];
					case _: [resolveTypeHint(module, source.tpConstraints)];
				};
				target.ttpConstraints = core.ds.AtomicLazy.fromVal(constraints);
			}
			if (source.tpDefault != null) target.ttpDefault = resolveTypeHint(module, source.tpDefault);
		}
		activeTypeParams = previousTypeParams;
		return result;
	}

	static function typeParamMap(params:TypeParams):StringMap<T> {
		var result = new StringMap<T>();
		for (param in params) result.set(param.ttpName, param.ttpType);
		return result;
	}

	// Small batch-only subset of typer.ml. It deliberately preserves an unknown
	// type as Dynamic until BasicTypes and Typecore are available.
	function typeFunction(module:ModuleDef, cls:TClass, methodName:String, func:Func, signature:TSignature,
			?outerLocals:StringMap<TVar>):TExpr {
		var previousMethodName = currentMethodName;
		currentMethodName = methodName;
		var locals = new StringMap<TVar>();
		if (outerLocals != null) for (name => value in outerLocals) locals.set(name, value);
		var args = [];
		for (index in 0...func.fArgs.length) {
			var arg = func.fArgs[index];
			var variable = makeVar(arg.name.name, signature.args[index].type, TVOArgument, arg.name.pos, arg.meta);
			if (hasMetadata(arg.meta, "this")) {
				variable.vKind = VAbstractThis;
				switch cls.clKind {
					case KAbstractImpl(abs) if (hasMetadata(abs.aMeta, "coreType")):
						variable.vName = "this1";
						variable.vMeta.unshift(realPathMetadata("this"));
					case _:
				}
			} else variable.vMeta.unshift(realPathMetadata(variable.vName));
			locals.set(arg.name.name, variable);
			var defaultValue = arg.expr == null ? (arg.optional ? typed(TConst(TNull), signature.args[index].type,
				Globals.nullPos) : null) : typeExpr(module, cls, arg.expr, locals);
			args.push({variable: variable, defaultValue: defaultValue});
		}
		var body = typeExpr(module, cls, func.fExpr, locals);
		bindDeclaredReturnType(body, signature.ret);
		currentMethodName = previousMethodName;
		return typed(TFunction({tfArgs: args, tfType: signature.ret, tfExpr: body}), TFun(signature), func.fExpr.pos);
	}

	function typeLocalFunction(module:ModuleDef, cls:TClass, name:PlacedName, inlineValue:Bool, func:Func, locals:StringMap<TVar>,
			pos:Pos):TExpr {
		var fallback = TDynamic(null);
		var signature:TSignature = {
			args: [
				for (arg in func.fArgs) {
					name: arg.name.name,
					optional: arg.optional || arg.expr != null,
					type: functionArgType(module, cls, arg)
				}
			],
			ret: func.fType == null ? fallback : resolveTypeHint(module, func.fType)
		};
		var variable = makeVar(name.name, TFun(signature), TVOLocalFunction, name.pos, [realPathMetadata(name.name)]);
		locals.set(name.name, variable);
		var functionExpr = typeFunction(module, cls, currentMethodName, func, signature, locals);
		if (func.fType == null) {
			var inferred = inferReturnType(functionExpr);
			if (inferred != null) {
				signature.ret = inferred;
				variable.vType = TFun(signature);
				functionExpr.etype = variable.vType;
				switch functionExpr.eexpr {
					case TFunction(value):
						value.tfType = inferred;
					case _:
				}
			}
		}
		var inlineResult = inlineValue && func.fArgs.length == 0 ? simpleInlineResult(functionExpr) : null;
		if (inlineResult != null) {
			variable.vExtra = {vParams: [], vExpr: functionExpr};
			var empty = typed(TBlock([]), basic("Void"), pos);
			return typed(TMeta({meta: ":mergeBlock", exprs: [], pos: Globals.nullPos}, empty), basic("Void"), pos);
		}
		return typed(TVar(variable, functionExpr), basic("Void"), pos);
	}

	static function simpleInlineResult(expression:TExpr):Null<TExpr> return switch expression.eexpr {
		case TFunction(func): switch func.tfExpr.eexpr {
				case TBlock([{eexpr: TReturn(value)}]) if (value != null): value;
				case TReturn(value) if (value != null): value;
				case _: null;
			}
		case _: null;
	};

	function bindDeclaredReturnType(expression:TExpr, returnType:T):Void switch expression.eexpr {
		case TReturn(value) if (value != null):
			switch [value.eexpr, returnType] {
				case [TObjectDecl(_), TAnon(_)]: value.etype = returnType;
				case _:
			}
		case TBlock(values):
			for (value in values) bindDeclaredReturnType(value, returnType);
		case TIf(_, thenExpr, elseExpr):
			bindDeclaredReturnType(thenExpr, returnType);
			if (elseExpr != null) bindDeclaredReturnType(elseExpr, returnType);
		case _:
	}

	function typeExpr(module:ModuleDef, cls:TClass, source:Expr, locals:StringMap<TVar>):TExpr {
		var fallback = TDynamic(null);
		return switch source.expr {
			case EConst(value): switch value {
					case Int(v, _): typed(TConst(TInt(Std.parseInt(v))), basic("Int"), source.pos);
					case Float(v, _): typed(TConst(TFloat(v)), basic("Float"), source.pos);
					case String(v, _): typed(TConst(TString(v)), basic("String"), source.pos);
					case Ident("true"): typed(TConst(TBool(true)), basic("Bool"), source.pos);
					case Ident("false"): typed(TConst(TBool(false)), basic("Bool"), source.pos);
					case Ident("null"): typed(TConst(TNull), fallback, source.pos);
					case Ident(name): typeIdent(module, cls, name, locals, source.pos);
					case Regexp(pattern, options):
						var type = resolvePath(module, {
							tpackage: [],
							tname: "EReg",
							tparams: [],
							tsub: null
						});
						switch type {
							case TInst(target, []):
								var patternExpr = typed(TConst(TString(pattern)), basic("String"), source.pos);
								var optionsExpr = typed(TConst(TString(options)), basic("String"), source.pos);
								typed(TNew(target, [], [patternExpr, optionsExpr]), type, source.pos);
							case _: throw "EReg is not a class";
						}
				};
			case EParenthesis(expr):
				var value = typeExpr(module, cls, expr, locals);
				typed(TParenthesis(value), value.etype, source.pos);
			case EArrayDecl([forExpr]) if (switch forExpr.expr {
					case EFor(_, _): true;
					case _: false;
				}): typeArrayComprehension(module, cls, forExpr, locals, source.pos);
			case EArrayDecl(values):
				var typedValues = [for (value in values) typeExpr(module, cls, value, locals)];
				var arrayModule = loadModule({pack: [], name: "Array"});
				var arrayClass = switch findModuleType(arrayModule, "Array") {
					case TClassDecl(value): value;
					case _: throw "Array is not a class";
				};
				typed(TArrayDecl(typedValues), TInst(arrayClass, [typedValues.length == 0 ? TDynamic(null) : typedValues[0].etype]),
					source.pos);
			case EArray(array, index):
				var arrayExpr = typeExpr(module, cls, array, locals);
				var indexExpr = typeExpr(module, cls, index, locals);
				switch arrayExpr.etype {
					case TAbstract(abs, params):
						var underlying = applyTypeParams(abs.aThis, abs.aParams, params);
						arrayExpr = typed(TCast(arrayExpr, null), underlying, arrayExpr.epos);
					case _:
				}
				var elementType = switch arrayExpr.etype {
					case TInst(arrayClass, [element]) if (arrayClass.clPath.pack.length == 0 && arrayClass.clPath.name == "Array"): element;
					case _: fallback;
				};
				typed(TArray(arrayExpr, indexExpr), elementType, source.pos);
			case EObjectDecl(fields):
				var typedFields = [
					for (field in fields) {key: field.key, expr: typeExpr(module, cls, field.expr, locals)}
				];
				var anonymousFields = new StringMap<TClassField>();
				for (field in typedFields) anonymousFields.set(field.key.name, {
					cfName: field.key.name,
					cfType: field.expr.etype,
					cfPos: field.key.pos,
					cfNamePos: field.key.pos,
					cfDoc: null,
					cfMeta: [],
					cfKind: Var({
						vRead: AccNormal,
						vWrite: AccNormal
					}),
					cfParams: [],
					cfExpr: null,
					cfExprUnoptimized: null,
					cfOverloads: [],
					cfFlags: flag(CfPublic)
				});
				typed(TObjectDecl(typedFields), TAnon({aFields: anonymousFields, aStatus: Const}), source.pos);
			case EBinop(op, left, right):
				var l = typeExpr(module, cls, left, locals);
				var r = typeExpr(module, cls, right, locals);
				if (switch r.eexpr {
						case TConst(TNull): true;
						case _: false;
					}) r.etype = l.etype;
				if (switch op {
						case OpAdd | OpAssignOp(OpAdd): isString(l.etype) && !isString(r.etype);
						case _: false;
					}) r = stringify(module, r);
				var result = switch op {
					case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte | OpBoolAnd | OpBoolOr | OpIn: basic("Bool");
					case OpAssign: l.etype;
					case _: l.etype;
				};
				typed(TBinop(op, l, r), result, source.pos);
			case EUnop(op, flag, value):
				var operand = typeExpr(module, cls, value, locals);
				typed(TUnop(op, flag, operand), op == Not ? basic("Bool") : operand.etype, source.pos);
			case EVars(vars): typeVars(module, cls, vars, locals, source.pos);
			case EBlock(exprs):
				var values = [for (expr in exprs) typeExpr(module, cls, expr, locals)];
				var blockPos = values.length == 1 ? switch values[0].eexpr {
					case TCall(_, _): values[0].epos;
					case _: source.pos;
				} : source.pos;
				typed(TBlock(values), values.length == 0 ? basic("Void") : values[values.length - 1].etype, blockPos);
			case ECall(expr, args): var isTrace = switch expr.expr {
					case EConst(Ident("trace")): true;
					case _: false;
				}; isTrace && args.length > 0 ? typeTrace(module, cls, args, locals,
					source.pos) : typeCall(module, cls, expr, args, locals, source.pos);
			case EField(expr, name, _):
				var receiver = tryTypeExpression(module, expr);
				typeField(receiver == null ? typeExpr(module, cls, expr, locals) : receiver, name, source.pos);
			case ENew(path, args): typeNew(module, path.path, args, cls, locals, source.pos);
			case EFunction(FKNamed(name, inlineValue), func): typeLocalFunction(module, cls, name, inlineValue, func, locals, source.pos);
			case EFunction(_, func):
				var signature:TSignature = {
					args: [
						for (arg in func.fArgs) {
							name: arg.name.name,
							optional: arg.optional || arg.expr != null,
							type: functionArgType(module, cls, arg)
						}
					],
					ret: func.fType == null ? fallback : resolveTypeHint(module, func.fType)
				};
				typeFunction(module, cls, "", func, signature);
			case EReturn(expr): typed(TReturn(expr == null ? null : typeExpr(module, cls, expr, locals)), fallback, source.pos);
			case EThrow(expr): typed(TThrow(typeExpr(module, cls, expr, locals)), fallback, source.pos);
			case EBreak: typed(TBreak, fallback, source.pos);
			case EContinue: typed(TContinue, fallback, source.pos);
			case ECast(expr, hint):
				var value = typeExpr(module, cls, expr, locals);
				var targetType = hint == null ? value.etype : resolveTypeHint(module, hint);
				typed(TCast(value, hint == null ? null : moduleTypeOf(targetType)), targetType, source.pos);
			case ECheckType(expr, hint):
				var value = typeExpr(module, cls, expr, locals);
				var targetType = resolveTypeHint(module, hint);
				typed(TCast(value, null), targetType, source.pos);
			case EIs(expr, hint): typeIs(module, cls, expr, hint, locals, source.pos);
			case EMeta(meta, expr):
				var value = typeExpr(module, cls, expr, locals);
				typed(TMeta(meta, value), value.etype, source.pos);
			case EUntyped(expr): typeExpr(module, cls, expr, locals);
			case ESwitch(subject, cases, defaultCase):
				var unwrapped = subject;
				while (true) switch unwrapped.expr {
					case EParenthesis(value): unwrapped = value;
					case _: break;
				}
				switch unwrapped.expr {
					case EArrayDecl(subjects): typeArrayPatternSwitch(module, cls, subjects, cases, defaultCase, locals, source.pos);
					case _: typeGeneralSwitch(module, cls, unwrapped, cases, defaultCase, locals, source.pos);
				};
			case EIf(condition, thenExpr, elseExpr):
				var thenValue = typeExpr(module, cls, thenExpr, locals);
				var elseValue = elseExpr == null ? null : typeExpr(module, cls, elseExpr, locals);
				typed(TIf(typeCondition(module, cls, condition, locals), thenValue, elseValue),
					elseValue == null ? basic("Void") : thenValue.etype, source.pos);
			case ETernary(condition, thenExpr, elseExpr):
				var thenValue = typeExpr(module, cls, thenExpr, locals);
				var elseValue = typeExpr(module, cls, elseExpr, locals);
				typed(TIf(typeCondition(module, cls, condition, locals), typed(TBlock([thenValue]), thenValue.etype, thenExpr.pos),
					typed(TBlock([elseValue]), elseValue.etype, elseExpr.pos)),
					thenValue.etype, source.pos);
			case EWhile(condition, body,
				flag): typed(TWhile(typeCondition(module, cls, condition, locals), typeExpr(module, cls, body, locals), flag),
					basic("Void"), source.pos);
			case EFor(iterator, body): typeForLoop(module, cls, iterator, body, locals, source.pos);
			case ETry(body, catches):
				if (catches.length == 0) typeExpr(module, cls, body, locals) else {
					var typedBody = typeExpr(module, cls, body, locals);
					var typedCatches = [
						for (item in catches) {
							var catchLocals = copyLocals(locals);
							var variable = makeVar(item.name.name, item.type == null ? fallback : resolveTypeHint(module, item.type),
								TVOCatchVariable, item.name.pos, [realPathMetadata(item.name.name)]);
							catchLocals.set(variable.vName, variable);
							{variable: variable, expr: typeExpr(module, cls, item.expr, catchLocals)};
						}
					];
					typed(TTry(typedBody, typedCatches), typedBody.etype, source.pos);
				}
			case _: throw 'Unsupported expression at ${source.pos.pfile}:${source.pos.pmin}';
		};
	}

	function typeCondition(module:ModuleDef, cls:TClass, source:Expr, locals:StringMap<TVar>):TExpr {
		var condition = typeExpr(module, cls, source, locals);
		return typed(TParenthesis(condition), condition.etype, condition.epos);
	}

	function typeIs(module:ModuleDef, cls:TClass, source:Expr, hint:TypeHint, locals:StringMap<TVar>, pos:Pos):TExpr {
		var value = typeExpr(module, cls, source, locals);
		var targetType = resolveTypeHint(module, hint);
		var targetModuleType = moduleTypeOf(targetType);
		if (targetModuleType == null) throw 'Unsupported type for `is` operator at ${hint.pos.pfile}:${hint.pos.pmin}';
		var target = typed(TTypeExpr(targetModuleType), TDynamic(null), hint.pos);
		var stdModule = loadModule({pack: [], name: "Std"});
		var stdClass = switch findModuleType(stdModule, "Std") {
			case TClassDecl(value): value;
			case _: throw "Std is not a class";
		};
		var field = stdClass.clStatics.get("isOfType");
		if (field == null) throw "Std.isOfType was not loaded";
		var owner = typed(TTypeExpr(TClassDecl(stdClass)), TDynamic(null), pos);
		var callee = typed(TField(owner, FStatic(stdClass, field)), field.cfType, pos);
		return typed(TCall(callee, [value, target]), basic("Bool"), pos);
	}

	static function copyLocals(locals:StringMap<TVar>):StringMap<TVar> {
		var result = new StringMap<TVar>();
		for (name => variable in locals) result.set(name, variable);
		return result;
	}

	function tryTypeExpression(module:ModuleDef, source:Expr):Null<TExpr> {
		var names:Array<String> = [];
		var cursor = source;
		while (true) switch cursor.expr {
			case EField(parent, name, EFNormal):
				names.unshift(name);
				cursor = parent;
			case EConst(Ident(name)):
				names.unshift(name);
				break;
			case _:
				return null;
		}
		var moduleIndex = -1;
		for (index in 0...names.length) if (!Ast.isLowerIdent(names[index])) {
			moduleIndex = index;
			break;
		}
		if (moduleIndex < 0) return null;
		var loaded = tryLoadModule({pack: names.slice(0, moduleIndex), name: names[moduleIndex]});
		if (loaded == null) return null;
		var typeName = names[names.length - 1];
		var moduleType = findModuleType(loaded, typeName);
		return moduleType == null ? null : typed(TTypeExpr(moduleType), TDynamic(null), source.pos);
	}

	function typeGeneralSwitch(module:ModuleDef, cls:TClass, subjectSource:Expr, cases:Array<SwitchCase>, defaultCase:Null<SwitchDefault>,
			locals:StringMap<TVar>, pos:Pos):TExpr {
		var subject = typeExpr(module, cls, subjectSource, locals);
		if (enumFromType(subject.etype) != null || findPatternEnum(module,
			cases) != null) return typeSimpleEnumSwitch(module, cls, subjectSource, cases, defaultCase, locals, pos);
		var typedCases:Array<TSwitchCase> = [];
		var typedDefault:Null<TExpr> = defaultCase == null
			|| defaultCase.expr == null ? null : typeExpr(module, cls, defaultCase.expr, locals);
		var resultType:T = typedDefault == null ? basic("Void") : typedDefault.etype;
		for (item in cases) {
			var wildcard = false;
			var patterns:Array<TExpr> = [];
			for (pattern in item.values) switch pattern.expr {
				case EConst(Ident("_")):
					wildcard = true;
				case _:
					patterns.push(typeExpr(module, cls, pattern, locals));
			}
			var body = item.expr == null ? typed(TBlock([]), basic("Void"), item.pos) : typeExpr(module, cls, item.expr, locals);
			if (wildcard) typedDefault = body;
			else {
				if (typedCases.length == 0) resultType = body.etype;
				typedCases.push({casePatterns: patterns, caseExpr: body});
			}
		}
		return typed(TSwitch({
			switchSubject: subject,
			switchCases: typedCases,
			switchDefault: typedDefault,
			switchExhaustive: false
		}), resultType, pos);
	}

	function findPatternEnum(module:ModuleDef, cases:Array<SwitchCase>):Null<TEnum> {
		for (type in module.mTypes) switch type {
			case TEnumDecl(candidate):
				var found = false, matches = true;
				for (item in cases) for (pattern in item.values) {
					var name = enumPatternName(pattern);
					if (name != "" && name != "_") {
						found = true;
						if (!candidate.eConstrs.exists(name)) matches = false;
					}
				}
				if (found && matches) return candidate;
			case _:
		}
		return null;
	}

	function typeArrayPatternSwitch(module:ModuleDef, cls:TClass, subjectSources:Array<Expr>, cases:Array<SwitchCase>,
			defaultCase:Null<SwitchDefault>, locals:StringMap<TVar>, pos:Pos):TExpr {
		var subjects = [for (source in subjectSources) typeExpr(module, cls, source, locals)];
		var fallback = defaultCase == null
			|| defaultCase.expr == null ? typed(TConst(TBool(false)), basic("Bool"), pos) : typeExpr(module, cls, defaultCase.expr, locals);
		var result:TExpr = fallback;
		for (reverseIndex in 0...cases.length) {
			var item = cases[cases.length - 1 - reverseIndex];
			var caseLocals = new StringMap<TVar>();
			for (name => value in locals) caseLocals.set(name, value);
			var declarations:Array<TExpr> = [];
			var condition:Null<TExpr> = null;
			for (pattern in item.values) {
				var patternCondition = typePatternCondition(module, pattern, subjects, caseLocals, declarations);
				condition = condition == null ? patternCondition : typed(TBinop(OpBoolOr, condition, patternCondition), basic("Bool"),
					pattern.pos);
			}
			var body = item.expr == null ? typed(TBlock([]), basic("Void"), item.pos) : typeExpr(module, cls, item.expr, caseLocals);
			if (declarations.length > 0) {
				declarations.push(body);
				body = typed(TBlock(declarations), body.etype, item.pos);
			}
			result = typed(TIf(condition, typed(TBlock([body]), body.etype, item.pos), typed(TBlock([result]), result.etype, result.epos)),
				body.etype, item.pos);
		}
		return result;
	}

	function typePatternCondition(module:ModuleDef, pattern:Expr, subjects:Array<TExpr>, locals:StringMap<TVar>,
			declarations:Array<TExpr>):TExpr {
		return switch pattern.expr {
			case EArrayDecl(patterns):
				var condition = typed(TConst(TBool(true)), basic("Bool"), pattern.pos);
				for (index in 0...patterns.length) if (index < subjects.length) condition = typed(TBinop(OpBoolAnd, condition,
					typeSinglePatternCondition(module, patterns[index], subjects[index], locals, declarations)),
					basic("Bool"), patterns[index].pos);
				condition;
			case _: typeSinglePatternCondition(module, pattern, subjects[0], locals, declarations);
		};
	}

	function typeSinglePatternCondition(module:ModuleDef, pattern:Expr, subject:TExpr, locals:StringMap<TVar>,
			declarations:Array<TExpr>):TExpr {
		var name = enumPatternName(pattern);
		if (name == "_") return typed(TConst(TBool(true)), basic("Bool"), pattern.pos);
		if (name == "null") return typed(TBinop(OpEq, subject, typed(TConst(TNull), subject.etype, pattern.pos)), basic("Bool"),
			pattern.pos);
		var en = enumFromType(subject.etype);
		if (en == null) for (type in module.mTypes) switch type {
			case TEnumDecl(candidate) if (candidate.eConstrs.exists(name)):
				en = candidate;
			case _:
		}
		if (en == null) throw 'Could not resolve enum pattern $name';
		var field = en.eConstrs.get(name);
		if (field == null) throw 'Unknown enum constructor $name';
		switch pattern.expr {
			case ECall(_, args):
				var signatureArgs = switch field.efType {
					case TFun(signature): signature.args;
					case _: [];
				};
				for (index in 0...args.length) switch args[index].expr {
					case EConst(Ident(variableName)) if (variableName != "_"):
						var argType = index < signatureArgs.length ? signatureArgs[index].type : TDynamic(null);
						var variable = makeVar(variableName, argType, TVOPatternVariable, args[index].pos,
							[realPathMetadata(variableName)]);
						variable.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
						locals.set(variableName, variable);
						declarations.push(typed(TVar(variable, typed(TEnumParameter(subject, field, index), argType, args[index].pos)),
							argType, args[index].pos));
					case _:
				}
			case _:
		}
		var nonNull = typed(TBinop(OpNotEq, subject, typed(TConst(TNull), subject.etype, pattern.pos)), basic("Bool"), pattern.pos);
		var indexCheck = typed(TBinop(OpEq, typed(TEnumIndex(subject), basic("Int"), pattern.pos),
			typed(TConst(TInt(field.efIndex)), basic("Int"), pattern.pos)),
			basic("Bool"), pattern.pos);
		return typed(TBinop(OpBoolAnd, nonNull, indexCheck), basic("Bool"), pattern.pos);
	}

	function typeSimpleEnumSwitch(module:ModuleDef, cls:TClass, subjectSource:Expr, cases:Array<SwitchCase>,
			defaultCase:Null<SwitchDefault>, locals:StringMap<TVar>, pos:Pos):TExpr {
		var subject = typeExpr(module, cls, subjectSource, locals);
		var en = enumFromType(subject.etype);
		if (en == null) {
			for (type in module.mTypes) switch type {
				case TEnumDecl(candidate):
					var matches = true;
					for (item in cases) for (pattern in item.values) {
						var name = enumPatternName(pattern);
						if (name != "_" && !candidate.eConstrs.exists(name)) matches = false;
					}
					if (matches) {
						en = candidate;
						break;
					}
				case _:
			}
		}
		if (en == null) throw "Could not resolve enum switch subject";
		if (switch subject.etype {
				case TDynamic(_): true;
				case _: false;
			}) subject.etype = en.eType;
		var typedCases:Array<TSwitchCase> = [];
		var typedDefault:Null<TExpr> = defaultCase == null
			|| defaultCase.expr == null ? null : typeExpr(module, cls, defaultCase.expr, locals);
		var resultType:T = typedDefault == null ? basic("Void") : typedDefault.etype;
		for (item in cases) {
			var caseLocals = new StringMap<TVar>();
			for (name => value in locals) caseLocals.set(name, value);
			var declarations:Array<TExpr> = [];
			var patterns:Array<TExpr> = [];
			for (patternIndex in 0...item.values.length) {
				var pattern = item.values[patternIndex];
				var constructorName = enumPatternName(pattern);
				if (constructorName == "_") continue;
				var field = en.eConstrs.get(constructorName);
				if (field == null) throw 'Unknown enum constructor $constructorName';
				patterns.push(typed(TConst(TInt(field.efIndex)), basic("Int"), pattern.pos));
				if (patternIndex == 0) switch pattern.expr {
					case ECall(_, args):
						var signatureArgs = switch field.efType {
							case TFun(signature): signature.args;
							case _: [];
						};
						for (index in 0...args.length) switch args[index].expr {
							case EConst(Ident(name)) if (name != "_"):
								var argType = index < signatureArgs.length ? signatureArgs[index].type : TDynamic(null);
								var variable = makeVar(name, argType, TVOPatternVariable, args[index].pos, [realPathMetadata(name)]);
								variable.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
								caseLocals.set(name, variable);
								var parameter = typed(TEnumParameter(subject, field, index), argType, args[index].pos);
								declarations.push(typed(TVar(variable, parameter), argType, args[index].pos));
							case _:
						}
					case _:
				}
			}
			var body = item.expr == null ? typed(TBlock([]), basic("Void"), item.pos) : typeExpr(module, cls, item.expr, caseLocals);
			if (declarations.length > 0) {
				declarations.push(body);
				body = typed(TBlock(declarations), body.etype, item.pos);
			}
			if (typedCases.length == 0) resultType = body.etype;
			typedCases.push({casePatterns: patterns, caseExpr: body});
		}
		var exhaustive = typedDefault == null && typedCases.length == en.eNames.length;
		return typed(TSwitch({
			switchSubject: typed(TEnumIndex(subject), basic("Int"), subjectSource.pos),
			switchCases: typedCases,
			switchDefault: typedDefault,
			switchExhaustive: exhaustive
		}), resultType, pos);
	}

	static function enumPatternName(pattern:Expr):String return switch pattern.expr {
		case EConst(Ident(name)): name;
		case ECall({expr: EConst(Ident(name))}, _): name;
		case _: "";
	};

	static function enumFromType(type:T):Null<TEnum> return switch type {
		case TEnum(value, _): value;
		case TAbstract(abs, [inner]) if (abs.aPath.pack.length == 0 && abs.aPath.name == "Null"): enumFromType(inner);
		case _: null;
	};

	function inferReturnType(expression:TExpr):Null<T> return switch expression.eexpr {
		case TFunction(value): inferReturnType(value.tfExpr);
		case TReturn(value): value == null ? basic("Void") : value.etype;
		case TBlock(values):
			var result:Null<T> = null;
			for (value in values) {
				var found = inferReturnType(value);
				if (found != null) {
					result = found;
					break;
				}
			}
			result;
		case TIf(_, thenExpr, elseExpr): var result = inferReturnType(thenExpr); result == null && elseExpr != null ? inferReturnType(elseExpr) : result;
		case _: null;
	};

	function typeForLoop(module:ModuleDef, cls:TClass, iterator:Expr, body:Expr, locals:StringMap<TVar>, pos:Pos):TExpr {
		var loopName:PlacedName;
		var source:Expr;
		switch iterator.expr {
			case EBinop(OpIn, {expr: EConst(Ident(name)), pos: namePos}, value):
				loopName = {name: name, pos: namePos};
				source = value;
			case EBinop(OpIn,
				{expr: EBinop(OpArrow, {expr: EConst(Ident(key)), pos: keyPos}, {expr: EConst(Ident(value)), pos: valuePos})}, source):
				return typeKeyValueForLoop(module, cls, {name: key, pos: keyPos}, {name: value, pos: valuePos}, source, body, locals, pos);
			case EBinop(OpArrow, {expr: EConst(Ident(key)), pos: keyPos},
				{expr: EBinop(OpIn, {expr: EConst(Ident(value)), pos: valuePos}, source)}):
				return typeKeyValueForLoop(module, cls, {name: key, pos: keyPos}, {name: value, pos: valuePos}, source, body, locals, pos);
			case _:
				throw 'Only value iteration is supported at ${iterator.pos.pfile}:${iterator.pos.pmin} (got ${Type.enumConstructor(iterator.expr)})';
		}
		var bodyLocals = new StringMap<TVar>();
		for (name => value in locals) bodyLocals.set(name, value);
		var loopType:T;
		var declarations:Array<TExpr> = [];
		var condition:TExpr;
		var valueExpr:TExpr;
		var increment:TExpr;
		switch source.expr {
			case EBinop(OpInterval, startSource, endSource):
				return typeIntRangeForLoop(module, cls, loopName, startSource, endSource, body, locals, iterator.pos, pos);
			case _:
				var sourceExpr = typeExpr(module, cls, source, locals);
				switch followTypeAliases(sourceExpr.etype) {
					case TAbstract(abs, params) if (abs.aImpl != null && abs.aImpl.clStatics.get("iterator") != null):
						var field = abs.aImpl.clStatics.get("iterator");
						var owner = typed(TTypeExpr(TClassDecl(abs.aImpl)), TDynamic(null), source.pos);
						var calleeType = applyTypeParams(field.cfType, abs.aParams, params);
						var callee = typed(TField(owner, FStatic(abs.aImpl, field)), calleeType, source.pos);
						var iteratorType = switch calleeType {
							case TFun(signature): signature.ret;
							case _: TDynamic(null);
						};
						sourceExpr = typed(TCall(callee, [sourceExpr]), iteratorType, source.pos);
					case TAbstract(abs, params):
						var underlying = applyTypeParams(abs.aThis, abs.aParams, params);
						sourceExpr = typed(TCast(sourceExpr, null), underlying, sourceExpr.epos);
					case _:
				}
				switch followTypeAliases(sourceExpr.etype) {
					case TInst(arrayClass, [element]) if (arrayClass.clPath.pack.length == 0 && arrayClass.clPath.name == "Array"):
						return typeArrayForLoop(module, cls, loopName, sourceExpr, source, body, locals, arrayClass, element,
							iterator.pos, pos);
					case TAnon(anon) if (anon.aFields.get("hasNext") != null && anon.aFields.get("next") != null):
						var iteratorType = sourceExpr.etype;
						var iteratorVar = makeGeneratedVar("`", iteratorType, iterator.pos);
						iteratorVar.vMeta = generatedLoopMetadata("`", false);
						var iteratorLocal = typed(TLocal(iteratorVar), iteratorType, iterator.pos);
						declarations.push(typed(TVar(iteratorVar, sourceExpr), iteratorType, source.pos));
						var hasNext = typeField(iteratorLocal, "hasNext", iterator.pos);
						condition = typed(TCall(hasNext, []), basic("Bool"), iterator.pos);
						var next = typeField(iteratorLocal, "next", iterator.pos);
						loopType = switch next.etype {
							case TFun(signature): signature.ret;
							case _: TDynamic(null);
						};
						valueExpr = typed(TCall(next, []), loopType, iterator.pos);
						increment = null;
					case TInst(iterableClass, iterableParams):
						var iteratorField = iterableClass.clFields.get("iterator");
						if (iteratorField == null) throw "Iterable type does not define iterator()";
						var iteratorCallee = typed(TField(sourceExpr, FInstance(iterableClass, iterableParams, iteratorField)),
							applyTypeParams(iteratorField.cfType, iterableClass.clParams, iterableParams), source.pos);
						var iteratorType = switch iteratorCallee.etype {
							case TFun(signature): signature.ret;
							case _: throw "iterator is not a method";
						};
						var iteratorValue = typed(TCall(iteratorCallee, []), iteratorType, source.pos);
						var iteratorVar = makeGeneratedVar("`", iteratorType, iterator.pos);
						iteratorVar.vMeta = generatedLoopMetadata("`", false);
						var iteratorLocal = typed(TLocal(iteratorVar), iteratorType, iterator.pos);
						declarations.push(typed(TVar(iteratorVar, iteratorValue), iteratorType, source.pos));
						var hasNext = typeField(iteratorLocal, "hasNext", iterator.pos);
						condition = typed(TCall(hasNext, []), basic("Bool"), iterator.pos);
						var next = typeField(iteratorLocal, "next", iterator.pos);
						loopType = switch next.etype {
							case TFun(signature): signature.ret;
							case _: TDynamic(null);
						};
						valueExpr = typed(TCall(next, []), loopType, iterator.pos);
						increment = null;
					case TAbstract(abs,
						_): throw "Only Array, iterable, and integer-range iteration are supported (got abstract "
							+ Globals.sTypePath(abs.aPath)
							+ ") at "
							+ source.pos.pfile
							+ ":"
							+ source.pos.pmin;
					case other: throw "Only Array, iterable, and integer-range iteration are supported (got "
							+ Type.enumConstructor(other)
							+ ") at "
							+ source.pos.pfile
							+ ":"
							+ source.pos.pmin;
				}
		}
		var loopVar = makeVar(loopName.name, loopType, TVOForVariable, loopName.pos, [realPathMetadata(loopName.name)]);
		loopVar.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
		bodyLocals.set(loopName.name, loopVar);
		var loopValues = [typed(TVar(loopVar, valueExpr), loopType, loopName.pos)];
		if (increment != null) loopValues.push(increment);
		loopValues.push(typeExpr(module, cls, body, bodyLocals));
		var whileBody = typed(TBlock(loopValues), basic("Void"), body.pos);
		condition = typed(TParenthesis(condition), basic("Bool"), condition.epos);
		declarations.push(typed(TWhile(condition, whileBody, NormalWhile), basic("Void"), pos));
		return typed(TBlock(declarations), basic("Void"), pos);
	}

	function typeArrayForLoop(module:ModuleDef, cls:TClass, loopName:PlacedName, sourceExpr:TExpr, source:Expr, body:Expr,
			locals:StringMap<TVar>, arrayClass:TClass, element:T, iteratorPos:Pos, pos:Pos):TExpr {
		var loopVar = makeVar(loopName.name, element, TVOForVariable, loopName.pos, [realPathMetadata(loopName.name)]);
		loopVar.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
		var bodyLocals = copyLocals(locals);
		bodyLocals.set(loopName.name, loopVar);
		var typedBody = typeExpr(module, cls, body, bodyLocals);
		var counter = makeGeneratedVar("_g", basic("Int"), loopName.pos);
		var sourceVar = makeGeneratedVar("_g1", sourceExpr.etype, source.pos);
		counter.vMeta = generatedLoopMetadata("_g", false);
		sourceVar.vMeta = generatedLoopMetadata("_g", false);
		var counterLocal = typed(TLocal(counter), basic("Int"), iteratorPos);
		var sourceLocal = typed(TLocal(sourceVar), sourceExpr.etype, source.pos);
		var lengthField = arrayClass.clFields.get("length");
		var length = typed(TField(sourceLocal, FInstance(arrayClass, [element], lengthField)), basic("Int"), iteratorPos);
		var comparison = typed(TBinop(OpLt, counterLocal, length), basic("Bool"), iteratorPos);
		var condition = typed(TParenthesis(comparison), basic("Bool"), iteratorPos);
		var values = [
			typed(TVar(loopVar, typed(TArray(sourceLocal, counterLocal), element, iteratorPos)), basic("Void"), loopName.pos),
			typed(TUnop(Increment, Prefix, counterLocal), basic("Int"), iteratorPos)
		];
		switch typedBody.eexpr {
			case TBlock(bodyValues):
				values = values.concat(bodyValues);
			case _:
				values.push(typedBody);
		}
		return typed(TBlock([
			typed(TVar(counter, typed(TConst(TInt(0)), basic("Int"), iteratorPos)), basic("Void"), iteratorPos),
			typed(TVar(sourceVar, sourceExpr), basic("Void"), source.pos),
			typed(TWhile(condition, typed(TBlock(values), basic("Void"), body.pos), NormalWhile), basic("Void"), pos)
		]), basic("Void"), pos);
	}

	function typeIntRangeForLoop(module:ModuleDef, cls:TClass, loopName:PlacedName, startSource:Expr, endSource:Expr, body:Expr,
			locals:StringMap<TVar>, iteratorPos:Pos, pos:Pos):TExpr {
		var intType = basic("Int");
		var start = typeExpr(module, cls, startSource, locals);
		var end = typeExpr(module, cls, endSource, locals);
		var loopVar = makeVar(loopName.name, intType, TVOForVariable, loopName.pos, [realPathMetadata(loopName.name)]);
		loopVar.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
		var bodyLocals = copyLocals(locals);
		bodyLocals.set(loopName.name, loopVar);
		var typedBody = typeExpr(module, cls, body, bodyLocals);
		var counter = makeGeneratedVar("_g", intType, startSource.pos);
		var bound = makeGeneratedVar("_g1", intType, endSource.pos);
		counter.vMeta = generatedLoopMetadata("_g", false);
		bound.vMeta = generatedLoopMetadata("_g", false);
		var counterLocal = typed(TLocal(counter), intType, iteratorPos);
		var boundLocal = typed(TLocal(bound), intType, iteratorPos);
		var comparison = typed(TBinop(OpLt, counterLocal, boundLocal), basic("Bool"), iteratorPos);
		var condition = typed(TParenthesis(comparison), basic("Bool"), iteratorPos);
		var values = [
			typed(TVar(loopVar, typed(TUnop(Increment, Postfix, counterLocal), intType, iteratorPos)), basic("Void"), loopName.pos)
		];
		switch typedBody.eexpr {
			case TBlock(bodyValues):
				values = values.concat(bodyValues);
			case _:
				values.push(typedBody);
		}
		return typed(TBlock([
			typed(TVar(counter, start), basic("Void"), startSource.pos),
			typed(TVar(bound, end), basic("Void"), endSource.pos),
			typed(TWhile(condition, typed(TBlock(values), basic("Void"), body.pos), NormalWhile), basic("Void"), pos)
		]), basic("Void"), pos);
	}

	function typeKeyValueForLoop(module:ModuleDef, cls:TClass, keyName:PlacedName, valueName:PlacedName, source:Expr, body:Expr,
			locals:StringMap<TVar>, pos:Pos):TExpr {
		var method:Expr = {expr: EField(source, "keyValueIterator", EFNormal), pos: source.pos};
		var iteratorExpr = typeCall(module, cls, method, [], locals, source.pos);
		var iteratorVar = makeGeneratedVar("`", iteratorExpr.etype, source.pos);
		iteratorVar.vMeta = generatedLoopMetadata("`", false);
		var iteratorLocal = typed(TLocal(iteratorVar), iteratorExpr.etype, source.pos);
		var hasNext = typeField(iteratorLocal, "hasNext", pos);
		var hasNextCall = typed(TCall(hasNext, []), basic("Bool"), pos);
		var condition = typed(TParenthesis(hasNextCall), basic("Bool"), pos);
		var next = typeField(iteratorLocal, "next", pos);
		var entryType = switch next.etype {
			case TFun(signature): signature.ret;
			case _: TDynamic(null);
		};
		var nextValue = typed(TCall(next, []), entryType, pos);
		var entryVar = makeGeneratedVar("`", entryType, pos);
		entryVar.vMeta = generatedLoopMetadata("`", false);
		var entryLocal = typed(TLocal(entryVar), entryType, pos);
		var keyExpr = typeField(entryLocal, "key", keyName.pos);
		var valueExpr = typeField(entryLocal, "value", valueName.pos);
		var keyVar = makeVar(keyName.name, keyExpr.etype, TVOForVariable, keyName.pos, [realPathMetadata(keyName.name)]);
		var valueVar = makeVar(valueName.name, valueExpr.etype, TVOForVariable, valueName.pos, [realPathMetadata(valueName.name)]);
		var usedByTyper = 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
		keyVar.vFlags |= usedByTyper;
		valueVar.vFlags |= usedByTyper;
		var bodyLocals = new StringMap<TVar>();
		for (name => value in locals) bodyLocals.set(name, value);
		bodyLocals.set(keyName.name, keyVar);
		bodyLocals.set(valueName.name, valueVar);
		var whileBody = typed(TBlock([
			typed(TVar(entryVar, nextValue), basic("Void"), pos),
			typed(TVar(keyVar, keyExpr), basic("Void"), keyName.pos),
			typed(TVar(valueVar, valueExpr), basic("Void"), valueName.pos),
			typeExpr(module, cls, body, bodyLocals)
		]), basic("Void"), body.pos);
		return typed(TBlock([
			typed(TVar(iteratorVar, iteratorExpr), basic("Void"), source.pos),
			typed(TWhile(condition, whileBody, NormalWhile), basic("Void"), pos)
		]), basic("Void"), pos);
	}

	function typeArrayComprehension(module:ModuleDef, cls:TClass, forExpr:Expr, locals:StringMap<TVar>, arrayPos:Pos):TExpr {
		var iterator:Expr;
		var body:Expr;
		switch forExpr.expr {
			case EFor(value, valueBody):
				iterator = value;
				body = valueBody;
			case _:
				throw "Expected comprehension for-expression";
		}
		var loopName:PlacedName;
		var source:Expr;
		switch iterator.expr {
			case EBinop(OpIn, {expr: EConst(Ident(name)), pos: pos}, value):
				loopName = {name: name, pos: pos};
				source = value;
			case _:
				throw "Only value iteration is supported in array comprehensions";
		}
		var sourceExpr = typeExpr(module, cls, source, locals);
		var arrayClass:TClass;
		var elementType = switch sourceExpr.etype {
			case TInst(value, [element]) if (value.clPath.pack.length == 0 && value.clPath.name == "Array"):
				arrayClass = value;
				element;
			case _: throw "Only Array iteration is supported in array comprehensions";
		};
		var isFilter = false;
		var loopBodyPos = body.pos;
		switch body.expr {
			case EIf(_, thenExpr, null):
				isFilter = true;
				body = thenExpr;
			case _:
		}
		var loopVar = makeVar(loopName.name, elementType, TVOForVariable, loopName.pos, [
			realPathMetadata(loopName.name),
			{meta: ":forLoopVariable", exprs: [], pos: Globals.nullPos}
		]);
		loopVar.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
		var bodyLocals = new StringMap<TVar>();
		for (name => value in locals) bodyLocals.set(name, value);
		bodyLocals.set(loopVar.vName, loopVar);
		var pushedValue = typeExpr(module, cls, body, bodyLocals);
		var resultElement = isFilter ? elementType : pushedValue.etype;
		var resultType = TInst(arrayClass, [resultElement]);
		var resultVar = makeGeneratedVar("_g", resultType, arrayPos);
		// The loop variable is allocated before the iterator temporaries upstream,
		// but declarations are emitted in result/counter/source/value order.
		var resultId = resultVar.vId;
		resultVar.vId = loopVar.vId;
		loopVar.vId = resultId;
		resultVar.vMeta = generatedLoopMetadata("_g", false);
		var counterVar = makeGeneratedVar("_g1", basic("Int"), loopName.pos);
		counterVar.vMeta = generatedLoopMetadata("_g", true);
		var sourceVar = makeGeneratedVar("_g2", sourceExpr.etype, source.pos);
		sourceVar.vMeta = generatedLoopMetadata("_g", false);
		loopVar.vMeta = [realPathMetadata(loopVar.vName)];
		var resultLocal = typed(TLocal(resultVar), resultType, arrayPos);
		var counterLocal = typed(TLocal(counterVar), basic("Int"), forExpr.pos);
		var sourceLocal = typed(TLocal(sourceVar), sourceExpr.etype, source.pos);
		var lengthField = arrayClass.clFields.get("length");
		var length = typed(TField(sourceLocal, FInstance(arrayClass, [elementType], lengthField)), basic("Int"), forExpr.pos);
		var comparison = typed(TBinop(OpLt, counterLocal, length), basic("Bool"), forExpr.pos);
		var condition = typed(TParenthesis(comparison), basic("Bool"), forExpr.pos);
		var valueExpr = typed(TArray(sourceLocal, counterLocal), elementType, forExpr.pos);
		var declareValue = typed(TVar(loopVar, valueExpr), elementType, loopName.pos);
		var increment = typed(TUnop(Increment, Prefix, counterLocal), basic("Int"), forExpr.pos);
		var pushField = arrayClass.clFields.get("push");
		var pushType = arrayClass.clParams.length == 0 ? pushField.cfType : substituteType(pushField.cfType,
			arrayClass.clParams[0].ttpType, resultElement);
		var pushCallee = typed(TField(resultLocal, FInstance(arrayClass, [resultElement], pushField)), pushType, arrayPos);
		var push = typed(TCall(pushCallee, [pushedValue]), basic("Int"), body.pos);
		var loopTail:TExpr = push;
		if (isFilter) switch forExpr.expr {
			case EFor(_, originalBody):
				switch originalBody.expr {
					case EIf(test, _, null):
						var testExpr = typeExpr(module, cls, test, bodyLocals);
						loopTail = typed(TIf(typed(TParenthesis(testExpr), basic("Bool"), test.pos),
							typed(TBlock([push]), basic("Int"), push.epos), null),
							basic("Void"), originalBody.pos);
					case _:
				}
			case _:
		}
		var whileBody = typed(TBlock([declareValue, increment, loopTail]), basic("Void"), loopBodyPos);
		var loop = typed(TWhile(condition, whileBody, NormalWhile), basic("Void"), forExpr.pos);
		var setup = typed(TBlock([
			typed(TVar(counterVar, typed(TConst(TInt(0)), basic("Int"), forExpr.pos)), basic("Int"), forExpr.pos),
			typed(TVar(sourceVar, sourceExpr), sourceExpr.etype, forExpr.pos),
			loop
		]), basic("Void"), forExpr.pos);
		return typed(TBlock([
			typed(TVar(resultVar, typed(TArrayDecl([]), resultType, arrayPos)), resultType, arrayPos),
			setup,
			resultLocal
		]), resultType, arrayPos);
	}

	function substituteType(type:T, from:T, to:T):T {
		if (type == from) return to;
		switch [type, from] {
			case [TInst(typeClass, []), TInst(fromClass, [])] if (typeClass == fromClass):
				return to;
			case _:
		}
		return switch type {
			case TInst(value, params): TInst(value, [for (param in params) substituteType(param, from, to)]);
			case TEnum(value, params): TEnum(value, [for (param in params) substituteType(param, from, to)]);
			case TType(value, params): TType(value, [for (param in params) substituteType(param, from, to)]);
			case TAbstract(value, params): TAbstract(value, [for (param in params) substituteType(param, from, to)]);
			case TFun(signature): TFun({
					args: [
						for (arg in signature.args) {name: arg.name, optional: arg.optional, type: substituteType(arg.type, from, to)}
					],
					ret: substituteType(signature.ret, from, to)
				});
			case other: other;
		};
	}

	function applyTypeParams(type:T, definitions:TypeParams, values:TParams):T {
		var result = type;
		for (index in 0...definitions.length) if (index < values.length) result = substituteType(result, definitions[index].ttpType,
			values[index]);
		return result;
	}

	function makeGeneratedVar(name:String, type:T, pos:Pos):TVar return {
		vId: nextVarId++,
		vName: name,
		vType: type,
		vKind: VGenerated,
		vExtra: null,
		vMeta: [],
		vFlags: 0,
		vPos: pos
	};

	static function realPathMetadata(name:String):MetadataEntry return {
		meta: ":realPath",
		exprs: [
			{
				expr: EConst(String(name, SDoubleQuotes)),
				pos: Globals.nullPos
			}
		],
		pos: Globals.nullPos
	};

	static function generatedLoopMetadata(name:String, forLoop:Bool):Metadata {
		var result = [realPathMetadata(name), realPathMetadata("`")];
		if (forLoop) result.push({meta: ":forLoopVariable", exprs: [], pos: Globals.nullPos});
		return result;
	}

	function typeCall(module:ModuleDef, cls:TClass, source:Expr, args:Array<Expr>, locals:StringMap<TVar>, pos:Pos):TExpr {
		switch source.expr {
			case EField(receiverSource, name, _):
				var resolvedReceiver = tryTypeExpression(module, receiverSource);
				var receiver = resolvedReceiver == null ? typeExpr(module, cls, receiverSource, locals) : resolvedReceiver;
				switch receiver.etype {
					case TInst(stringBuf, []) if (stringBuf.clPath.pack.length == 0 && stringBuf.clPath.name == "StringBuf"):
						var buffer = stringBuf.clFields.get("b");
						if (buffer != null && name == "toString" && args.length == 0) return typed(TField(receiver,
							FInstance(stringBuf, [], buffer)), basic("String"), pos);
						if (buffer != null && name == "add" && args.length == 1) {
							var target = typed(TField(receiver, FInstance(stringBuf, [], buffer)), basic("String"), source.pos);
							var argument = typeExpr(module, cls, args[0], locals);
							var converted = isString(argument.etype) ? argument : stringify(module,
								typed(TCast(argument, null), argument.etype, argument.epos));
							return typed(TBinop(OpAssignOp(OpAdd), target, converted), basic("String"), pos);
						}
					case _:
				}
				switch receiver.etype {
					case TAbstract(abs, params) if (abs.aImpl != null):
						var field = abs.aImpl.clStatics.get(name);
						if (field != null) {
							var owner = typed(TTypeExpr(TClassDecl(abs.aImpl)), TDynamic(null), source.pos);
							var callee = typed(TField(owner, FStatic(abs.aImpl, field)),
								applyTypeParams(field.cfType, abs.aParams, params), source.pos);
							var values = [receiver].concat([for (arg in args) typeExpr(module, cls, arg, locals)]);
							if (field.cfParams.length > 0) callee.etype = inferMethodType(field, values);
							var result = switch callee.etype {
								case TFun(signature): signature.ret;
								case _: TDynamic(null);
							};
							return typed(TCall(callee, values), result, pos);
						}
					case _:
				}
			case _:
		}
		var callee = typeExpr(module, cls, source, locals);
		var values = [for (arg in args) typeExpr(module, cls, arg, locals)];
		switch callee.eexpr {
			case TLocal(variable) if (values.length == 0 && variable.vExtra != null && variable.vExtra.vExpr != null):
				var result = simpleInlineResult(variable.vExtra.vExpr);
				if (result != null) return typed(result.eexpr, result.etype, pos);
			case _:
		}
		var field = switch callee.eexpr {
			case TField(_, FStatic(_, value)) | TField(_, FInstance(_, _, value)): value;
			case _: null;
		};
		if (field != null && field.cfParams.length > 0) callee.etype = inferMethodType(field, values);
		var result = switch callee.etype {
			case TFun(sig): sig.ret;
			case _: TDynamic(null);
		};
		return typed(TCall(callee, values), result, pos);
	}

	function inferMethodType(field:TClassField, arguments:Array<TExpr>):T {
		var inferred = new ObjectMap<TypedTypeParam, T>();
		function match(formal:T, actual:T):Void {
			switch formal {
				case TInst(cls, []) if (switch cls.clKind {
						case KTypeParameter(param): field.cfParams.indexOf(param) != -1;
						case _: false;
					}):
					switch cls.clKind {
						case KTypeParameter(param): if (!inferred.exists(param)) inferred.set(param, actual);
						case _:
					}
				case TInst(_, formalParams) | TEnum(_, formalParams) | TType(_, formalParams) | TAbstract(_, formalParams):
					var actualParams = switch actual {
						case TInst(_, values) | TEnum(_, values) | TType(_, values) | TAbstract(_, values): values;
						case _: [];
					};
					for (index in 0...formalParams.length) if (index < actualParams.length) match(formalParams[index], actualParams[index]);
				case TFun(formalSignature):
					switch actual {
						case TFun(actualSignature):
							for (index in 0...formalSignature.args.length) if (index < actualSignature.args.length)
								match(formalSignature.args[index].type, actualSignature.args[index].type);
							match(formalSignature.ret, actualSignature.ret);
						case _:
					}
				case _:
			}
		}
		var signature = switch field.cfType {
			case TFun(value): value;
			case _: return field.cfType;
		};
		for (index in 0...signature.args.length) if (index < arguments.length) match(signature.args[index].type, arguments[index].etype);
		var result = field.cfType;
		for (param in field.cfParams) result = substituteType(result, param.ttpType,
			inferred.exists(param) ? inferred.get(param) : TDynamic(null));
		return result;
	}

	function stringify(module:ModuleDef, value:TExpr):TExpr {
		switch value.etype {
			case TAbstract(abs, params) if (abs.aImpl != null):
				var field = abs.aImpl.clStatics.get("toString");
				if (field != null) {
					var owner = typed(TTypeExpr(TClassDecl(abs.aImpl)), TDynamic(null), value.epos);
					var callee = typed(TField(owner, FStatic(abs.aImpl, field)), applyTypeParams(field.cfType, abs.aParams, params),
						value.epos);
					return typed(TCall(callee, [value]), basic("String"), value.epos);
				}
			case _:
		}
		var stdModule = loadModule({pack: [], name: "Std"});
		var stdClass = switch findModuleType(stdModule, "Std") {
			case TClassDecl(value): value;
			case _: throw "Std is not a class";
		};
		var field = stdClass.clStatics.get("string");
		var zeroPos:core.Globals.Pos = {pfile: value.epos.pfile, pmin: value.epos.pmin, pmax: value.epos.pmin};
		var stdExpr = typed(TTypeExpr(TClassDecl(stdClass)), TDynamic(null), zeroPos);
		var callee = typed(TField(stdExpr, FStatic(stdClass, field)), field.cfType, zeroPos);
		return typed(TCall(callee, [value]), basic("String"), value.epos);
	}

	static function isString(type:T):Bool return switch type {
		case TInst(cls, params): cls.clPath.pack.length == 0 && cls.clPath.name == "String" && params.length == 0;
		case TAbstract(abs, params): abs.aPath.pack.length == 0 && abs.aPath.name == "String" && params.length == 0;
		case _: false;
	}

	// Direct counterpart of typer.ml's type_call_builtin trace branch. The full
	// typer obtains these types through normal access resolution; the batch port
	// constructs the same typed shape after loading haxe.Log and PosInfos.
	function typeTrace(module:ModuleDef, cls:TClass, args:Array<Expr>, locals:StringMap<TVar>, pos:Pos):TExpr {
		var value = typeExpr(module, cls, args[0], locals);
		var logModule = loadModule({pack: ["haxe"], name: "Log"});
		var logClass = switch findModuleType(logModule, "Log") {
			case TClassDecl(value): value;
			case _: throw "haxe.Log is not a class";
		};
		var traceField = logClass.clStatics.get("trace");
		if (traceField == null) throw "haxe.Log.trace was not loaded";
		var logTypePos:core.Globals.Pos = {pfile: pos.pfile, pmin: pos.pmin, pmax: pos.pmin + 5};
		var logType = typed(TTypeExpr(TClassDecl(logClass)), TDynamic(null), logTypePos);
		var callee = typed(TField(logType, FStatic(logClass, traceField)), traceField.cfType, logTypePos);
		var stringValue = value;
		var fields:Array<{var key:{var name:String; var pos:Pos; var quote:QuoteStatus;}; var expr:TExpr;}> = [];
		fields.push({
			key: {name: "fileName", pos: Globals.nullPos, quote: NoQuotes},
			expr: typed(TConst(TString(pos.pfile)), basic("String"), logTypePos)
		});
		fields.push({
			key: {name: "lineNumber", pos: Globals.nullPos, quote: NoQuotes},
			expr: typed(TConst(TInt(lineNumber(pos.pfile, pos.pmin))), basic("Int"), logTypePos)
		});
		fields.push({
			key: {name: "className", pos: Globals.nullPos, quote: NoQuotes},
			expr: typed(TConst(TString(Globals.sTypePath(cls.clPath))), basic("String"), logTypePos)
		});
		if (currentMethodName != "") fields.push({
			key: {name: "methodName", pos: Globals.nullPos, quote: NoQuotes},
			expr: typed(TConst(TString(currentMethodName)), basic("String"), logTypePos)
		});
		if (args.length > 1) {
			var extras = [for (arg in args.slice(1)) typeExpr(module, cls, arg, locals)];
			fields.push({
				key: {name: "customParams", pos: Globals.nullPos, quote: NoQuotes},
				expr: typed(TArrayDecl(extras), TDynamic(null), logTypePos)
			});
		}
		var posInfosModule = loadModule({pack: ["haxe"], name: "PosInfos"});
		var posInfosDef = switch findModuleType(posInfosModule, "PosInfos") {
			case TTypeDecl(value): value;
			case _: throw "haxe.PosInfos is not a typedef";
		};
		var anon = switch posInfosDef.tType {
			case TAnon(value): value;
			case _: throw "haxe.PosInfos is not anonymous";
		};
		var infoExpr = typed(TObjectDecl(fields), TAnon(anon), logTypePos);
		return typed(TCall(callee, [stringValue, infoExpr]), basic("Void"), logTypePos);
	}

	function lineNumber(file:String, offset:Int):Int {
		if (!sys.FileSystem.exists(file)) return 1;
		var contents = sys.io.File.getContent(file);
		var line = 1;
		var limit = offset < contents.length ? offset : contents.length;
		for (index in 0...limit) if (contents.charCodeAt(index) == 10) line++;
		return line;
	}

	function typeVars(module:ModuleDef, cls:TClass, vars:Array<EVar>, locals:StringMap<TVar>, pos:Pos):TExpr {
		var result:Array<TExpr> = [];
		for (value in vars) {
			var initializer = value.evExpr == null ? null : typeExpr(module, cls, value.evExpr, locals);
			var type = value.evType == null ? (initializer == null ? TDynamic(null) : initializer.etype) : resolveTypeHint(module,
				value.evType);
			var metadata = value.evMeta.copy();
			metadata.unshift(realPathMetadata(value.evName.name));
			var variable = makeVar(value.evName.name, type, TVOLocalVariable, value.evName.pos, metadata);
			if (value.evFinal) variable.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VFinal");
			if (value.evStatic) variable.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VStatic");
			locals.set(variable.vName, variable);
			result.push(typed(TVar(variable, initializer), basic("Void"), pos));
		}
		return result.length == 1 ? result[0] : typed(TBlock(result), TDynamic(null), pos);
	}

	function typeIdent(module:ModuleDef, cls:TClass, name:String, locals:StringMap<TVar>, pos:Pos):TExpr {
		var local = locals.get(name);
		if (local != null) {
			switch local.vKind {
				case VAbstractThis:
				case _:
					local.vFlags |= 1 << core.TType.TType.flagTVarNames.indexOf("VUsedByTyper");
			}
			return typed(TLocal(local), local.vType, pos);
		}
		if (name == "this") return typed(TConst(TThis), cls.clType, pos);
		var field = cls.clFields.get(name);
		if (field != null) {
			var params = switch cls.clType {
				case TInst(_, values): values;
				case _: [];
			};
			return typed(TField(typed(TConst(TThis), cls.clType, pos), FInstance(cls, params, field)),
				applyTypeParams(field.cfType, cls.clParams, params), pos);
		}
		field = cls.clStatics.get(name);
		if (field != null) {
			var owner = typed(TTypeExpr(TClassDecl(cls)), TDynamic(null), pos);
			return typed(TField(owner, FStatic(cls, field)), field.cfType, pos);
		}
		var moduleType = findModuleType(module, name);
		if (moduleType == null && name.length > 0 && name.charAt(0) == name.charAt(0).toUpperCase()) {
			try moduleType = findModuleType(loadModule({pack: [], name: name}), name)
			catch (_:Dynamic) {
				try moduleType = findModuleType(loadModule({pack: module.mPath.pack, name: name}), name)
				catch (_:Dynamic) {}
			}
		}
		if (moduleType != null) return typed(TTypeExpr(moduleType), TDynamic(null), pos);
		return typed(TIdent(name), TDynamic(null), pos);
	}

	function typeField(object:TExpr, name:String, pos:Pos):TExpr {
		switch object.eexpr {
			case TTypeExpr(TClassDecl(cls)):
				var field = cls.clStatics.get(name);
				if (field != null) return typed(TField(object, FStatic(cls, field)), field.cfType, pos);
			case _:
		}
		switch object.etype {
			case TType(def, params):
				var underlying = applyTypeParams(def.tType, def.tParams, params);
				return typeField(typed(TCast(object, null), underlying, object.epos), name, pos);
			case TAnon(anon):
				var field = anon.aFields.get(name);
				if (field != null) return typed(TField(object, FAnon(field)), field.cfType, pos);
			case TInst(cls, params):
				var access = typeInstanceField(object, cls, params, name, pos);
				if (access != null) return access;
			case TAbstract(abs, params):
				if (abs.aPath.pack.length == 0 && abs.aPath.name == "Null" && params.length == 1) switch params[0] {
					case TInst(cls, classParams):
						var access = typeInstanceField(object, cls, classParams, name, pos);
						if (access != null) return access;
					case _:
				}
				var underlying = applyTypeParams(abs.aThis, abs.aParams, params);
				switch underlying {
					case TInst(cls, classParams):
						var field = cls.clFields.get(name);
						if (field != null) {
							var castExpr = typed(TCast(object, null), underlying, object.epos);
							return typed(TField(castExpr, FInstance(cls, classParams, field)),
								applyTypeParams(field.cfType, cls.clParams, classParams), pos);
						}
					case _:
				}
			case _:
		}
		return typed(TField(object, FDynamic(name)), TDynamic(null), pos);
	}

	function followTypeAliases(type:T):T return switch type {
		case TType(def, params): followTypeAliases(applyTypeParams(def.tType, def.tParams, params));
		case other: other;
	}

	function typeInstanceField(object:TExpr, cls:TClass, params:TParams, name:String, pos:Pos):Null<TExpr> {
		var field = cls.clFields.get(name);
		if (field == null) return null;
		switch field.cfKind {
			case Var(access) if (access.vRead == AccCall):
				var getter = cls.clFields.get("get_" + name);
				if (getter != null) {
					var callee = typed(TField(object, FInstance(cls, params, getter)),
						applyTypeParams(getter.cfType, cls.clParams, params), pos);
					var result = switch callee.etype {
						case TFun(signature): signature.ret;
						case _: field.cfType;
					};
					return typed(TCall(callee, []), result, pos);
				}
			case _:
		}
		return typed(TField(object, FInstance(cls, params, field)), applyTypeParams(field.cfType, cls.clParams, params), pos);
	}

	function typeNew(module:ModuleDef, path:TypePath, args:Array<Expr>, cls:TClass, locals:StringMap<TVar>, pos:Pos):TExpr {
		var type = resolvePath(module, path);
		var values = [for (arg in args) typeExpr(module, cls, arg, locals)];
		return switch type {
			case TInst(target, params):
				if (params.length == 0 && target.clParams.length == 1 && values.length > 0) switch values[0].etype {
					case TInst(arrayClass, [element]) if (arrayClass.clPath.name == "Array"):
						params = [element];
						type = TInst(target, params);
					case _:
				}
				if (params.length == 0 && target.clParams.length > 0) {
					params = [for (_ in target.clParams) TDynamic(null)];
					type = TInst(target, params);
				}
				typed(TNew(target, params, values), type, pos);
			case _: throw 'Unsupported constructor target ${path.tpackage.concat([path.tname]).join(".")}';
		};
	}

	function makeVar(name:String, type:T, origin:TVarOrigin, pos:Pos, meta:Metadata):TVar return {
		vId: nextVarId++,
		vName: name,
		vType: type,
		vKind: VUser(origin),
		vExtra: null,
		vMeta: meta,
		vFlags: 0,
		vPos: pos
	};

	static function typed(expr:TExprDef, type:T, pos:Pos):TExpr return {eexpr: expr, etype: type, epos: pos};

	function populateEnumConstructors(module:ModuleDef, en:TEnum, constructors:Array<EnumConstructor>):Void {
		for (index in 0...constructors.length) {
			var constructor = constructors[index];
			var args = [
				for (arg in constructor.ecArgs) {
					name: arg.name,
					optional: arg.optional,
					type: arg.optional ? optionalType(module, resolveTypeHint(module, arg.type)) : resolveTypeHint(module, arg.type)
				}
			];
			var typed:TEnumField = {
				efName: constructor.ecName.name,
				efType: args.length == 0 ? en.eType : TFun({args: args, ret: en.eType}),
				efPos: constructor.ecPos,
				efNamePos: constructor.ecName.pos,
				efDoc: constructor.ecDoc,
				efIndex: index,
				efParams: [],
				efMeta: constructor.ecMeta
			};
			en.eConstrs.set(typed.efName, typed);
			en.eNames.push(typed.efName);
		}
	}

	function fieldType(module:ModuleDef, cls:TClass, field:ClassField):T return switch field.cffKind {
		case FVar(type, _): type == null ? TDynamic(null) : resolveTypeHint(module, type);
		case FProp(_, _, type, _): type == null ? TDynamic(null) : resolveTypeHint(module, type);
		case FFun(func): TFun({
				args: [
					for (arg in func.fArgs) {
						name: arg.name.name,
						optional: arg.optional || arg.expr != null,
						type: functionArgType(module, cls, arg)
					}
				],
				ret: func.fType == null ? basic("Void") : resolveTypeHint(module, func.fType)
			});
	}

	function functionArgType(module:ModuleDef, cls:TClass, arg:FuncArg):T {
		if (hasMetadata(arg.meta, "this") && cls != null) switch cls.clKind {
			case KAbstractImpl(abs):
				return abs.aThis;
			case _:
		}
		var type = arg.type == null ? inferDefaultArgumentType(arg.expr) : resolveTypeHint(module, arg.type);
		return arg.optional ? nullable(module, type) : type;
	}

	function inferDefaultArgumentType(value:Null<Expr>):T return value == null ? TDynamic(null) : switch value.expr {
		case EConst(Int(_, _)): basic("Int");
		case EConst(Float(_, _)): basic("Float");
		case EConst(String(_, _)): basic("String");
		case EConst(Ident("true" | "false")): basic("Bool");
		case _: TDynamic(null);
	};

	function nullable(module:ModuleDef, inner:T):T {
		var stdTypes = loadModule({pack: [], name: "StdTypes"});
		var nullAbs = switch findModuleType(stdTypes, "Null") {
			case TAbstractDecl(value): value;
			case _: throw "Null is not an abstract";
		};
		return TAbstract(nullAbs, [inner]);
	}

	function optionalType(module:ModuleDef, inner:T):T try return nullable(module, inner)
	catch (_:Dynamic) return inner;

	function fieldKind(field:ClassField):FieldKind return switch field.cffKind {
		case FVar(_, _): Var({vRead: AccNormal, vWrite: hasAccess(field, AFinal) ? AccCtor : AccNormal});
		case FProp(get, set, _, _): Var({vRead: accessKind(get.name), vWrite: accessKind(set.name)});
		case FFun(_): Method(hasAccess(field,
				ADynamic) ? MethDynamic : hasAccess(field, AInline) ? MethInline : hasAccess(field, AMacro) ? MethMacro : MethNormal);
	}

	function resolveTypeHint(module:ModuleDef, hint:TypeHint):T return switch hint.type {
		case CTPath(path): resolvePath(module, path.path);
		case CTFunction(args, ret): TFun({
				args: [
					for (arg in args) {name: "", optional: false, type: resolveTypeHint(module, arg)}
				],
				ret: resolveTypeHint(module, ret)
			});
		case CTParent(type) | CTNamed(_, type): resolveTypeHint(module, type);
		case CTOptional(type):
			var stdTypes = loadModule({pack: [], name: "StdTypes"});
			var nullAbs = switch findModuleType(stdTypes, "Null") {
				case TAbstractDecl(value): value;
				case _: throw "Null is not an abstract";
			};
			TAbstract(nullAbs, [resolveTypeHint(module, type)]);
		case CTAnonymous(fields): TAnon(makeAnonymous(module, fields));
		case CTExtend(paths, fields): TAnon({
				aFields: makeAnonymous(module, fields).aFields,
				aStatus: Extend([for (path in paths) resolvePath(module, path.path)])
			});
		// Structural intersection merging is still outside this batch slice.
		case CTIntersection(_): TDynamic(null);
	}

	function makeAnonymous(module:ModuleDef, fields:Array<ClassField>):TAnon {
		var result = new StringMap<TClassField>();
		for (field in fields) result.set(field.cffName.name, {
			cfName: field.cffName.name,
			cfType: fieldType(module, null, field),
			cfPos: field.cffPos.pfile == "?" && field.cffName.name != "customParams" ? {
				pfile: "?",
				pmin: -1,
				pmax: 78
			} : field.cffPos,
			cfNamePos: field.cffPos.pfile == "?" && field.cffName.name != "customParams" ? Globals.nullPos : field.cffName.pos,
			cfDoc: field.cffDoc,
			cfMeta: anonymousFieldMetadata(field),
			cfKind: fieldKind(field),
			cfParams: [],
			cfExpr: null,
			cfExprUnoptimized: null,
			cfOverloads: [],
			cfFlags: flag(CfPublic)
		});
		return {aFields: result, aStatus: Closed};
	}

	static function anonymousFieldMetadata(field:ClassField):Metadata {
		var result = field.cffMeta.copy();
		var optional = switch field.cffKind {
			case FVar(type, _) | FProp(_, _, type, _): type != null && switch type.type {
					case CTOptional(_): true;
					case _: false;
				};
			case FFun(_): false;
		};
		if (optional) result.push({meta: ":optional", exprs: [], pos: Globals.nullPos});
		return result;
	}

	function resolvePath(current:ModuleDef, path:TypePath):T {
		if (path.tpackage.length == 0 && path.tsub == null && path.tparams.length == 0 && activeTypeParams.exists(path.tname)) return
			activeTypeParams.get(path.tname);
		if (path.tpackage.length == 0 && path.tsub == null && basicTypes.exists(path.tname)) return basic(path.tname);
		if (path.tpackage.length == 0 && path.tname == "Dynamic") return TDynamic(null);
		var target = current;
		var resolvedName = path.tname;
		if (path.tpackage.length != 0) {
			var moduleIndex = -1;
			for (index in 0...path.tpackage.length) if (!Ast.isLowerIdent(path.tpackage[index])) {
				moduleIndex = index;
				break;
			}
			if (moduleIndex < 0) target = loadModule({pack: path.tpackage, name: path.tname});
			else {
				target = loadModule({pack: path.tpackage.slice(0, moduleIndex), name: path.tpackage[moduleIndex]});
				resolvedName = path.tname;
			}
		} else if (findModuleType(current, path.tname) == null) {
			var imported = moduleImports.get(moduleKey(current.mPath)).get(path.tname);
			if (imported != null) {
				var importedModule = tryLoadModule(imported.modulePath);
				if (importedModule == null) imported = null
				else {
					target = importedModule;
					resolvedName = imported.typeName;
				}
			}
			if (imported == null) {
				// Unqualified standard types resolve from root standard modules even
				// while loading a package-scoped standard module such as haxe.PosInfos.
				var found = tryLoadModule({pack: [], name: path.tname});
				var depth = current.mPath.pack.length;
				while (found == null && depth > 0) {
					found = tryLoadModule({pack: current.mPath.pack.slice(0, depth), name: path.tname});
					depth--;
				}
				if (found != null) target = found;
				else {
					var stdTypes = current.mPath.pack.length == 0
						&& current.mPath.name == "StdTypes" ? null : tryLoadModule({pack: [], name: "StdTypes"});
					if (stdTypes != null && findModuleType(stdTypes, path.tname) != null) target = stdTypes;
					else return TDynamic(null);
				}
			}
		}
		var name = path.tpackage.length == 0 ? resolvedName : (path.tsub == null ? resolvedName : path.tsub);
		if (path.tpackage.length == 0 && path.tsub != null) name = path.tsub;
		var type = findModuleType(target, name);
		if (type == null) return TDynamic(null); // built-ins await BasicTypes/Typecore.
		var params = [
			for (param in path.tparams) switch param {
				case TPType(type):
					resolveTypeHint(current, type);
				case TPExpr(_):
					TDynamic(null);
			}
		];
		return switch type {
			case TClassDecl(cls): TInst(cls, params);
			case TEnumDecl(en): TEnum(en, params);
			case TTypeDecl(def): TType(def, params);
			case TAbstractDecl(abs): TAbstract(abs, params);
		};
	}

	function basic(name:String):T return basicTypes.get(name);

	function makeBasicType(name:String):T {
		var abs:TAbstract = {
			aPath: {pack: [], name: name},
			aModule: basicModule,
			aPos: {pfile: "<built-in>", pmin: 0, pmax: 0},
			aNamePos: {pfile: "<built-in>", pmin: 0, pmax: 0},
			aPrivate: false,
			aDoc: null,
			aMeta: [],
			aParams: [],
			aUsing: [],
			aRestore: function() {},
			aOps: [],
			aUnops: [],
			aImpl: null,
			aThis: TDynamic(null),
			aFrom: [],
			aFromField: [],
			aTo: [],
			aToField: [],
			aArray: [],
			aRead: null,
			aWrite: null,
			aCall: null,
			aConstructor: null,
			aExtern: true,
			aEnum: false
		};
		abs.aThis = TAbstract(abs, []);
		return abs.aThis;
	}

	function findClass(module:ModuleDef, name:String):TClass return switch findModuleType(module, name) {
		case TClassDecl(cls): cls;
		case _: throw 'Class ' + name + ' was not allocated';
	};

	function findEnum(module:ModuleDef, name:String):TEnum return switch findModuleType(module, name) {
		case TEnumDecl(en): en;
		case _: throw 'Enum ' + name + ' was not allocated';
	};

	function findAbstract(module:ModuleDef, name:String):TAbstract return switch findModuleType(module, name) {
		case TAbstractDecl(abs): abs;
		case _: throw 'Abstract ' + name + ' was not allocated';
	};

	function findModuleType(module:ModuleDef, name:String):Null<ModuleType> {
		for (type in module.mTypes) if (switch type {
				case TClassDecl(cls): cls.clPath.name == name;
				case TEnumDecl(en): en.ePath.name == name;
				case TTypeDecl(def): def.tPath.name == name;
				case TAbstractDecl(abs): abs.aPath.name == name;
			}) return type;
		return null;
	}

	static function accessKind(name:String):VarAccess return switch name {
		case "never": AccNever;
		case "null": AccNo;
		case "default": AccNormal;
		case _: AccCall;
	};

	static function hasMetadata(metadata:Metadata, name:String):Bool {
		for (entry in metadata) if (Std.string(entry.meta) == name || Std.string(entry.meta) == ":" + name) return true;
		return false;
	}

	static function fieldFlags(field:ClassField, isStatic:Bool, externClass:Bool = false):Int {
		var flags = hasAccess(field, APublic) || (externClass && !hasAccess(field, APrivate)) ? flag(CfPublic) : 0;
		if (hasAccess(field, APrivate)) flags = 0;
		if (isStatic) flags |= flag(CfStatic);
		if (hasAccess(field, AExtern)) flags |= flag(CfExtern);
		if (hasAccess(field, AFinal)) flags |= flag(CfFinal);
		if (hasAccess(field, AOverride)) flags |= flag(CfOverride);
		if (hasAccess(field, AAbstract)) flags |= flag(CfAbstract);
		if (hasAccess(field, AOverload)) flags |= flag(CfOverload);
		return flags;
	}

	static function flag(value:FlagTClassField):Int return 1 << core.TType.TType.flagTClassFieldNames.indexOf(Std.string(value));

	static function hasAccess(field:ClassField, access:Access):Bool {
		for (value in field.cffAccess) if (value.access == access) return true;
		return false;
	}

	function makeClass(module:ModuleDef, value:ClassDefinition, pos:Pos):TClass {
		var path = typePath(module, value.name.name, has(value.flags, HPrivate));
		var cls:TClass = null;
		cls = {
			clPath: path,
			clModule: module,
			clPos: pos,
			clNamePos: value.name.pos,
			clPrivate: has(value.flags, HPrivate),
			clDoc: value.doc,
			clMeta: value.meta,
			clParams: [],
			clUsing: [],
			clRestore: function() {},
			clType: TDynamic(null),
			clKind: KNormal,
			clFlags: classFlags(value.flags),
			clSuper: null,
			clImplements: [],
			clFields: new StringMap(),
			clStatics: new StringMap(),
			clOrderedStatics: [],
			clOrderedFields: [],
			clDynamic: null,
			clArrayAccess: null,
			clConstructor: null,
			clInit: null,
			clBuild: function() return Built,
			clDescendants: []
		};
		cls.clType = TInst(cls, []);
		return cls;
	}

	static function classFlags(flags:Array<ClassFlag>):Int {
		var result = 0;
		for (value in flags) switch value {
			case HExtern:
				result |= classFlag(CExtern);
			case HFinal:
				result |= classFlag(CFinal);
			case HInterface:
				result |= classFlag(CInterface);
			case HAbstract:
				result |= classFlag(CAbstract);
			case HPrivate | HExtends(_) | HImplements(_):
		}
		return result;
	}

	static function classFlag(value:FlagTClass):Int return 1 << core.TType.TType.flagTClassNames.indexOf(Std.string(value));

	function makeEnum(module:ModuleDef, value:EnumDefinition, pos:Pos):TEnum {
		var en:TEnum = {
			ePath: typePath(module, value.name.name, has(value.flags, EPrivate)),
			eModule: module,
			ePos: pos,
			eNamePos: value.name.pos,
			ePrivate: has(value.flags, EPrivate),
			eDoc: value.doc,
			eMeta: value.meta,
			eParams: [],
			eUsing: [],
			eRestore: function() {},
			eType: TDynamic(null),
			eFlags: 0,
			eConstrs: new StringMap(),
			eNames: []
		};
		en.eType = TEnum(en, []);
		return en;
	}

	function makeDef(module:ModuleDef, value:TypedefDefinition, pos:Pos):TDef {
		var def:TDef = {
			tPath: typePath(module, value.name.name, has(value.flags, TDPrivate)),
			tModule: module,
			tPos: pos,
			tNamePos: value.name.pos,
			tPrivate: has(value.flags, TDPrivate),
			tDoc: value.doc,
			tMeta: value.meta,
			tParams: [],
			tUsing: [],
			tRestore: function() {},
			tType: TDynamic(null)
		};
		def.tType = TType(def, []);
		return def;
	}

	function makeAbstract(module:ModuleDef, value:AbstractDefinition, pos:Pos):TAbstract {
		var abs:TAbstract = {
			aPath: typePath(module, value.name.name, has(value.flags, AbPrivate)),
			aModule: module,
			aPos: pos,
			aNamePos: value.name.pos,
			aPrivate: has(value.flags, AbPrivate),
			aDoc: value.doc,
			aMeta: value.meta,
			aParams: [],
			aUsing: [],
			aRestore: function() {},
			aOps: [],
			aUnops: [],
			aImpl: null,
			aThis: TDynamic(null),
			aFrom: [],
			aFromField: [],
			aTo: [],
			aToField: [],
			aArray: [],
			aRead: null,
			aWrite: null,
			aCall: null,
			aConstructor: null,
			aExtern: has(value.flags, AbExtern),
			aEnum: has(value.flags, AbEnum)
		};
		abs.aThis = TAbstract(abs, []);
		return abs;
	}

	function typePath(module:ModuleDef, name:String, privateType:Bool):GlobalTypePath return {
		pack: privateType ? module.mPath.pack.concat(["_" + module.mPath.name]) : module.mPath.pack,
		name: name
	};

	static function samePath(a:Array<String>, b:Array<String>):Bool return a.join(".") == b.join(".");

	static function moduleKey(path:GlobalTypePath):String return Globals.sTypePath(path);

	static function has<T>(values:Array<T>, value:T):Bool return values.indexOf(value) != -1;
}

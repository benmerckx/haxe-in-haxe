package context.display;

import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.display.DisplayPosition;
import compiler.CompilationCache;
import context.Common;
import context.Typecore;
import context.Typecore.Typer;
import context.TyperPass;
import typing.ModuleTyping;
import typing.Typeload;
import typing.TypeloadFields;
import core.Ast;
import core.TType;

// haxe/src/context/display/displayTexpr.ml
class DisplayTexpr {
	static inline function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	public static function findFieldByPosition(sc:Array<ClassField>, p:Pos):ClassField {
		for (cff in sc) if (posEq(cff.cffName.pos, p)) return cff;
		throw core.ds.NotFound.raise();
	}

	public static function findEnumFieldByPosition(sc:EnumDefinition, p:Pos):EnumConstructor {
		for (eff in sc.data) if (posEq(eff.ecName.pos, p)) return eff;
		throw core.ds.NotFound.raise();
	}

	public static function findClassByPosition(decls:Array<TypeDecl>, p:Pos):ClassDefinition {
		for (d in decls) switch d.definition {
			case EClass(c) if (posEq(c.name.pos, p)):
				return c;
			case _:
		}
		throw core.ds.NotFound.raise();
	}

	public static function findModuleStaticByPosition(decls:Array<TypeDecl>, p:Pos):StaticDefinition {
		for (d in decls) switch d.definition {
			case EStatic(s) if (posEq(s.name.pos, p)):
				return s;
			case _:
		}
		throw core.ds.NotFound.raise();
	}

	public static function findEnumByPosition(decls:Array<TypeDecl>, p:Pos):EnumDefinition {
		for (d in decls) switch d.definition {
			case EEnum(en) if (posEq(en.name.pos, p)):
				return en;
			case _:
		}
		throw core.ds.NotFound.raise();
	}

	public static function findTypedefByPosition(decls:Array<TypeDecl>, p:Pos):TypedefDefinition {
		for (d in decls) switch d.definition {
			case ETypedef(td) if (posEq(td.name.pos, p)):
				return td;
			case _:
		}
		throw core.ds.NotFound.raise();
	}

	public static function findAbstractByPosition(decls:Array<TypeDecl>, p:Pos):AbstractDefinition {
		for (d in decls) switch d.definition {
			case EAbstract(a) if (posEq(a.name.pos, p)):
				return a;
			case _:
		}
		throw core.ds.NotFound.raise();
	}

	public static function actuallyCheckDisplayField(ctx:Typer, c:TClass, cff:ClassField, p:Pos):Void {
		var cctx = TypeloadFields.createClassContext(c, p);
		var ctx = TypeloadFields.createTyperContextForClass(ctx, cctx, p);
		var cff = TypeloadFields.transformField(ctx, cctx, c, cff, [], cff.cffName.pos);
		var displayModifier = Typeload.checkFieldAccess(ctx, cff);
		var fctx = TypeloadFields.createFieldContext(ctx, cctx, cff, true, displayModifier);
		var cf = TypeloadFields.createClassField(cctx, cff);
		TypeloadFields.initField(ctx, cctx, fctx, cff, cf);
		Typecore.flushPass(ctx.g, PTypeField, {name: "check_display_field", path: c.clPath.pack.concat([c.clPath.name, cff.cffName.name])});
		follow(cf.cfType);
	}

	public static function checkDisplayField(ctx:Typer, sc:Array<ClassField>, c:TClass, cf:TClassField):Void {
		var cff = findFieldByPosition(sc, cf.cfNamePos);
		actuallyCheckDisplayField(ctx, c, cff, cf.cfPos);
	}

	public static function checkDisplayClass(ctx:Typer, decls:Array<TypeDecl>, c:TClass):Void {
		function checkField_(sc:Array<ClassField>, cf:TClassField):Void {
			if (!hasClassFieldFlag(cf, CfNoLookup)
				&& DisplayPosition.displayPosition.enclosedIn(cf.cfPos)) checkDisplayField(ctx, sc, c, cf);
			DisplayEmitter.checkDisplayMetadata(ctx, cf.cfMeta);
		}
		function checkField(sc:Array<ClassField>, cf:TClassField):Void {
			checkField_(sc, cf);
			for (cf in cf.cfOverloads) checkField_(sc, cf);
		}
		switch c.clKind {
			case KAbstractImpl(a):
				var sa = findAbstractByPosition(decls, c.clNamePos);
				for (cf in c.clOrderedStatics) checkField(sa.data, cf);
			case _:
				var sc = findClassByPosition(decls, c.clNamePos);
				Typeload.typeTypeParams(ctx, TPHType, c.clPath, sc.params);
				for (f in sc.flags) switch f {
					case HExtends(ptp) | HImplements(ptp) if (DisplayPosition.displayPosition.enclosedIn(ptp.posFull)):
						Typeload.loadInstance(ctx, ptp, ParamNormal, LoadNormal, true);
					case _:
				}
				for (cf in c.clOrderedStatics) checkField(sc.data, cf);
				for (cf in c.clOrderedFields) checkField(sc.data, cf);
				if (c.clConstructor != null) checkField(sc.data, c.clConstructor);
		}
	}

	public static function checkDisplayEnum(ctx:Typer, decls:Array<TypeDecl>, en:TEnum):Void {
		var se = findEnumByPosition(decls, en.eNamePos);
		Typeload.typeTypeParams(ctx, TPHType, en.ePath, se.params);
		core.ds.PMap.iter(function(_, ef:TEnumField) {
			if (DisplayPosition.displayPosition.enclosedIn(ef.efPos)) {
				var sef = findEnumFieldByPosition(se, ef.efNamePos);
				ModuleTyping.loadEnumField(ctx, en, TEnum(en, extractParamTypes(en.eParams)), {value: false}, 0, sef);
			}
		}, en.eConstrs);
	}

	public static function checkDisplayTypedef(ctx:Typer, decls:Array<TypeDecl>, td:TDef):Void {
		var st = findTypedefByPosition(decls, td.tNamePos);
		Typeload.typeTypeParams(ctx, TPHType, td.tPath, st.params);
		Typeload.loadComplexType(ctx, true, LoadNormal, st.data);
	}

	public static function checkDisplayAbstract(ctx:Typer, decls:Array<TypeDecl>, a:TAbstract):Void {
		var sa = findAbstractByPosition(decls, a.aNamePos);
		Typeload.typeTypeParams(ctx, TPHType, a.aPath, sa.params);
		for (f in sa.flags) switch f {
			case AbOver(th) | AbFrom(th) | AbTo(th) if (DisplayPosition.displayPosition.enclosedIn(th.pos)):
				Typeload.loadComplexType(ctx, true, LoadNormal, th);
			case _:
		}
	}

	public static function checkDisplayModuleFields(ctx:Typer, decls:Array<TypeDecl>, m:ModuleDef):Void {
		if (m.mStatics != null) {
			var c = m.mStatics;
			for (cf in c.clOrderedStatics) {
				if (DisplayPosition.displayPosition.enclosedIn(cf.cfPos)) {
					var cff = findModuleStaticByPosition(decls, cf.cfNamePos);
					actuallyCheckDisplayField(ctx, c, ModuleTyping.fieldOfStaticDefinition(cff, cf.cfPos), cf.cfPos);
				}
				DisplayEmitter.checkDisplayMetadata(ctx, cf.cfMeta);
			}
		}
	}

	public static function checkDisplayModule(ctx:Typer, decls:Array<TypeDecl>, m:ModuleDef):Void {
		var imports = decls.filter(d -> switch d.definition {
			case EImport(_) | EUsing(_): true;
			case _: false;
		});
		var imports = ModuleTyping.handleImportHx(ctx.com, ctx.g, m, imports, Globals.nullPos);
		var ctx = ModuleTyping.typeTypesIntoModule(ctx.com, ctx.g, m, imports, Globals.nullPos);
		for (md in m.mTypes) {
			var infos = tInfos(md);
			if (DisplayPosition.displayPosition.enclosedIn(infos.mtNamePos)) DisplayEmitter.displayModuleType(ctx, md, infos.mtNamePos);
			if (DisplayPosition.displayPosition.enclosedIn(infos.mtPos)) switch md {
				case TClassDecl(c):
					checkDisplayClass(ctx, decls, c);
				case TEnumDecl(en):
					checkDisplayEnum(ctx, decls, en);
				case TTypeDecl(td):
					checkDisplayTypedef(ctx, decls, td);
				case TAbstractDecl(a):
					checkDisplayAbstract(ctx, decls, a);
			}
			DisplayEmitter.checkDisplayMetadata(ctx, infos.mtMeta);
		}
		checkDisplayModuleFields(ctx, decls, m);
	}

	public static function checkDisplayFile(ctx:Typer, cs:Cache):Void {
		if (ctx.com.cache == null) return;
		var cc:ContextCache = ctx.com.cache;
		try {
			var p = DisplayPosition.displayPosition.get();
			var cfile = cc.findFile(ctx.com.partScope.fileKeys.get(p.pfile));
			var path:GlobalTypePath = {pack: cfile.cPackage, name: CompilationCache.getModuleNameOfCfile(p.pfile, cfile)};
			typing.SourceParser.PdiHandler.handlePdi(ctx.com, cfile.cPdi);
			// We have to go through type_module_hook because one of the module's dependencies could be
			// invalid (issue #8991).
			var m = try ctx.com.moduleLut.find(path) catch (_:core.ds.NotFound) {
				// TypeloadCacheHook.type_module_hook: the batch compiler has no module cache, so the
				// hook reports NoModule (the server installs ServerCache.type_module).
				throw core.ds.NotFound.raise();
			};
			checkDisplayModule(ctx, cfile.cDecls, m);
		} catch (_:core.ds.NotFound) {}
	}
}

package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.TType;
import core.Globals.Pos;
import core.Error;
import core.WithType;
import context.Typecore;
import context.Typecore.Typer;
import core.ds.NotFound;
import typing.TyperBase.*;
import typing.TyperBase.AccessKind;
import core.Error.TypingError;
import typing.Calls.*;
import typing.Fields.*;
import typing.Fields.TypeFieldConfig;

// haxe/src/typing/typerDotPath.ml — mechanical draft; not compile-validated.
@:structInit class DotPathResolution {
	public var access:AccessKind;
	public var rest:Array<DotPathPart>;

	public inline function new(access:AccessKind, rest:Array<DotPathPart>) {
		this.access = access;
		this.rest = rest;
	}

	public inline function clone():DotPathResolution return new DotPathResolution(access, rest);
}

class TyperDotPath {
	public static function mkDotPathPart(s:String, p:Pos):DotPathPart {
		return {name: s, caseKind: isLowerIdent(s, p) ? PLowercase : PUppercase, pos: p};
	}

	public static function sDotPath(parts:Array<DotPathPart>):String return parts.map(function(p) return p.name).join(".");

	public static function resolveModuleField(ctx:Typer, m:ModuleDef, path:Array<DotPathPart>, p:Pos, mode:AccessMode,
			withType:WithTypeValue):DotPathResolution {
		if (path.length == 0 || m.mStatics == null) throw NotFound.raise();
		var first = path[0], c = m.mStatics;
		var f = c.clStatics.get(first.name);
		if (f == null) throw NotFound.raise();
		var e = typeModuleType(ctx, TClassDecl(c), first.pos);
		return {access: fieldAccess(ctx, mode, f, FHStatic(c), e, first.pos), rest: path.slice(1)};
	}

	public static function resolveModuleType(ctx:Typer, m:ModuleDef, name:String, p:Pos):AccessKind {
		return mkModuleTypeAccess(ctx, Typeload.findTypeInModule(m, name), p);
	}

	public static function resolveInModule(ctx:Typer, m:ModuleDef, path:Array<DotPathPart>, p:Pos, mode:AccessMode,
			withType:WithTypeValue):DotPathResolution {
		try return resolveModuleField(ctx, m, path, p, mode, withType)
		catch (_:NotFound) {}
		if (path.length > 0 && path[0].caseKind == PUppercase) {
			try return {access: resolveModuleType(ctx, m, path[0].name, path[0].pos), rest: path.slice(1)} catch (_:NotFound) {}
		}
		return {access: resolveModuleType(ctx, m, m.mPath.name, p), rest: path};
	}

	public static function resolveQualified(ctx:Typer, pack:Array<String>, name:String, nextPath:Array<DotPathPart>, p:Pos,
			mode:AccessMode, withType:WithTypeValue):DotPathResolution {
		try {
			var m = Typeload.loadModule(ctx, {pack: pack, name: name}, p);
			return resolveInModule(ctx, m, nextPath, p, mode, withType);
		} catch (error:TypingError) {
			switch error.error.errMessage {
				case ModuleNotFound(path)
					if (path.name == name && path.pack.length == pack.length && path.pack.join(".") == pack.join(".")):
					var t = Typeload.findTypeInCurrentModuleContext(ctx, pack, name);
					return {access: mkModuleTypeAccess(ctx, t, p), rest: nextPath};
				case _:
					throw error;
			}
		}
	}

	public static function resolveUnqualified(ctx:Typer, name:String, nextPath:Array<DotPathPart>, p:Pos, mode:AccessMode,
			withType:WithTypeValue):DotPathResolution {
		try {
			var t = Typeload.findTypeInCurrentModuleContext(ctx, [], name);
			if (nextPath.length > 0) {
				var first = nextPath[0];
				var e = typeModuleType(ctx, t, p);
				var access = typeField(TypeFieldConfig.create(true), ctx, e, first.name, first.pos, mode, withType);
				return {access: access, rest: nextPath.slice(1)};
			}
			return {access: mkModuleTypeAccess(ctx, t, p), rest: nextPath};
		} catch (_:NotFound) {
			return Typeload.findInUnqualifiedModules(ctx, name, p, m -> resolveInModule(ctx, m, nextPath, p, mode, withType));
		}
	}

	public static function resolveDotPath(ctx:Typer, pathParts:Array<DotPathPart>, mode:AccessMode, withType:WithTypeValue):AccessKind {
		var packAcc:Array<DotPathPart> = [];
		for (i in 0...pathParts.length) {
			var part = pathParts[i];
			if (part.caseKind == PLowercase) {
				packAcc.unshift(part);
				continue;
			}
			var path = pathParts.slice(i + 1);
			var useMode = path.length <= 1 ? mode : MGet;
			var useType = path.length <= 1 ? withType : WithTypeTools.value;
			var resolved = if (packAcc.length > 0) {
				var pack = packAcc.map(function(part) return part.name);
				pack.reverse();
				resolveQualified(ctx, pack, part.name, path, part.pos, useMode, useType);
			} else resolveUnqualified(ctx, part.name, path, part.pos, useMode, useType);
			return fieldChain(ctx, resolved.rest, resolved.access, mode, withType);
		}
		throw NotFound.raise();
	}
}

package typing;

import core.Define;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions.*;
import compiler.hxb.HxbData.ModuleCache;
import context.Common;
import context.Common.CommonContext;
import context.TyperPass;

// Port of haxe/src/typing/typeloadCacheHook.ml.
enum FindModuleResult {
	GoodModule(m:ModuleDef);
	BadModule(reason:ModuleSkipReason);
	BadBinaryModule(mc:ModuleCache, reason:ModuleSkipReason);
	BinaryModule(mc:ModuleCache);
	NoModule;
}

class TypeloadCacheHook {
	public static var typeModuleHook:(com:CommonContext, delay:(TyperPass, Void->Void) -> Void, path:GlobalTypePath,
		p:Pos) -> FindModuleResult = function(_, _, _, _) return NoModule;

	public static final fakeModules:Map<String, ModuleDef> = new Map();

	public static function createFakeModule(com:CommonContext, file:String):ModuleDef {
		var key:String = com.partScope.fileKeys.get(file);
		var file = core.Path.getFullPath(file);
		var mdep = fakeModules.get(key);
		if (mdep == null) {
			mdep = {
				mId: allocMid(),
				mPath: {pack: ["$DEP"], name: file},
				mTypes: [],
				mStatics: null,
				mExtra: moduleExtra(file, Define.getSignature(com.defines), Common.fileTime(file), MFake, com.partScope.compilationStep, [])
			};
			fakeModules.set(key, mdep);
		}
		com.moduleLut.add(mdep.mPath, mdep);
		return mdep;
	}
}

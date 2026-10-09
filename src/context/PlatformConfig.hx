package context;

import core.Globals.GlobalTypePath;
import core.TType.TExpr;

// Draft mechanical translation of haxe/src/context/platformConfig.ml; unvalidated.
enum CapturePolicy {
	CPNone;
	CPWrapRef;
	CPLoopVars;
}

@:structInit class ExceptionsConfig {
	public var ecNativeThrows:Array<GlobalTypePath>;
	public var ecNativeCatches:Array<GlobalTypePath>;
	public var ecAvoidWrapping:Bool;
	public var ecWildcardCatch:GlobalTypePath;
	public var ecBaseThrow:GlobalTypePath;
	public var ecSpecialThrow:TExpr->Bool;

	public inline function new(ecNativeThrows:Array<GlobalTypePath>, ecNativeCatches:Array<GlobalTypePath>, ecAvoidWrapping:Bool,
			ecWildcardCatch:GlobalTypePath, ecBaseThrow:GlobalTypePath, ecSpecialThrow:TExpr->Bool) {
		this.ecNativeThrows = ecNativeThrows;
		this.ecNativeCatches = ecNativeCatches;
		this.ecAvoidWrapping = ecAvoidWrapping;
		this.ecWildcardCatch = ecWildcardCatch;
		this.ecBaseThrow = ecBaseThrow;
		this.ecSpecialThrow = ecSpecialThrow;
	}

	public inline function clone():ExceptionsConfig return new ExceptionsConfig(ecNativeThrows, ecNativeCatches, ecAvoidWrapping,
		ecWildcardCatch, ecBaseThrow, ecSpecialThrow);
}

enum VarScope {
	FunctionScope;
	BlockScope;
}

enum VarScopingFlags {
	VarHoisting;
	NoShadowing;
	NoCatchVarShadowing;
	ReserveCurrentTopLevelSymbol;
	ReserveAllTopLevelSymbols;
	ReserveAllTypesFlat;
	ReserveNames(names:Array<String>);
	SwitchCasesNoBlocks;
}

@:structInit class VarScopingConfig {
	public var vsFlags:Array<VarScopingFlags>;
	public var vsScope:VarScope;

	public inline function new(vsFlags:Array<VarScopingFlags>, vsScope:VarScope) {
		this.vsFlags = vsFlags;
		this.vsScope = vsScope;
	}

	public inline function clone():VarScopingConfig return new VarScopingConfig(vsFlags, vsScope);
}

@:structInit class PlatformConfig {
	public var pfStatic:Bool;
	public var pfSys:Bool;
	public var pfCapturePolicy:CapturePolicy;
	public var pfPadNulls:Bool;
	public var pfAddFinalReturn:Bool;
	public var pfOverload:Bool;
	public var pfCanSkipNonNullableArgument:Bool;
	public var pfReservedTypePaths:Array<GlobalTypePath>;
	public var pfSupportsFunctionEquality:Bool;
	public var pfUsesUtf16:Bool;
	public var pfThisBeforeSuper:Bool;
	public var pfSupportsThreads:Bool;
	public var pfSupportsUnicode:Bool;
	public var pfSupportsRestArgs:Bool;
	public var pfExceptions:ExceptionsConfig;
	public var pfScoping:VarScopingConfig;
	public var pfSupportsAtomics:Bool;

	public inline function new(pfStatic:Bool, pfSys:Bool, pfCapturePolicy:CapturePolicy, pfPadNulls:Bool, pfAddFinalReturn:Bool,
			pfOverload:Bool, pfCanSkipNonNullableArgument:Bool, pfReservedTypePaths:Array<GlobalTypePath>,
			pfSupportsFunctionEquality:Bool, pfUsesUtf16:Bool, pfThisBeforeSuper:Bool, pfSupportsThreads:Bool, pfSupportsUnicode:Bool,
			pfSupportsRestArgs:Bool, pfExceptions:ExceptionsConfig, pfScoping:VarScopingConfig, pfSupportsAtomics:Bool) {
		this.pfStatic = pfStatic;
		this.pfSys = pfSys;
		this.pfCapturePolicy = pfCapturePolicy;
		this.pfPadNulls = pfPadNulls;
		this.pfAddFinalReturn = pfAddFinalReturn;
		this.pfOverload = pfOverload;
		this.pfCanSkipNonNullableArgument = pfCanSkipNonNullableArgument;
		this.pfReservedTypePaths = pfReservedTypePaths;
		this.pfSupportsFunctionEquality = pfSupportsFunctionEquality;
		this.pfUsesUtf16 = pfUsesUtf16;
		this.pfThisBeforeSuper = pfThisBeforeSuper;
		this.pfSupportsThreads = pfSupportsThreads;
		this.pfSupportsUnicode = pfSupportsUnicode;
		this.pfSupportsRestArgs = pfSupportsRestArgs;
		this.pfExceptions = pfExceptions;
		this.pfScoping = pfScoping;
		this.pfSupportsAtomics = pfSupportsAtomics;
	}

	public inline function clone():PlatformConfig return new PlatformConfig(pfStatic, pfSys, pfCapturePolicy, pfPadNulls,
		pfAddFinalReturn, pfOverload, pfCanSkipNonNullableArgument, pfReservedTypePaths, pfSupportsFunctionEquality, pfUsesUtf16,
		pfThisBeforeSuper, pfSupportsThreads, pfSupportsUnicode, pfSupportsRestArgs, pfExceptions, pfScoping, pfSupportsAtomics);
}

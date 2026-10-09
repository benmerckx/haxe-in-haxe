package context;

// Draft mechanical translation of haxe/src/context/typerPass.ml; unvalidated.
enum TyperPass {
	PBuildModule;
	PBuildClass;
	PConnectField;
	PTypeField;
	PCheckConstraint;
	PForce;
	PFinal;
}

class TyperPassTools {
	public static final allTyperPasses:Array<TyperPass> = [
		PBuildModule,
		PBuildClass,
		PConnectField,
		PTypeField,
		PCheckConstraint,
		PForce,
		PFinal
	];
	public static final allTyperPassesLength = allTyperPasses.length;
}

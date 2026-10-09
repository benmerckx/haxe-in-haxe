package syntax;

import core.display.DisplayPosition;
import core.DisplayTypes;
import core.DisplayTypes.DisplayModeValue;
import core.Globals;
import context.Common.CommonContext;
import core.Define.DefineContext;
import syntax.Parser.ParserConfiguration;

// Draft mechanical translation of haxe/src/syntax/parserConfig.ml; unvalidated.
class ParserConfig {
	public static function defaultConfig(defines:DefineContext):ParserConfiguration return Parser.createConfig(defines, false, false,
		DMNone, false, null);

	public static function fileParserConfig(com:CommonContext, file:String):ParserConfiguration {
		var displayPosition = DisplayPosition.displayPosition;
		var inDisplay = displayPosition.get() != Globals.nullPos;
		var inDisplayFile = inDisplay && displayPosition.isInFile(core.Path.UniqueKey.create(file));
		return Parser.createConfig(com.defines, inDisplay, inDisplayFile, com.display.dmsKind, com.partScope.parserState.wasAutoTriggered,
			com.partScope.parserState.specialIdentifierFiles);
	}
}

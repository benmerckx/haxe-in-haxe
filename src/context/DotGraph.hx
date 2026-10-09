package context;

import core.Globals;
import core.Path;
import core.Define;

// haxe/src/context/dotGraph.ml — mechanical draft; not compile-validated.
class DotGraph {
	public static function platformNameMacro(com:SafeCom.SafeContext):String return Define.defined(com.defines,
		Define.Macro) ? "macro" : Globals.platformName(com.platform);

	public static function getDumpPath(com:SafeCom.SafeContext, path:core.Globals.GlobalTypePath,
			name:String):Array<String> return [com.dumpConfig.dumpPath, platformNameMacro(com)].concat(path.pack)
			.concat([path.name + "." + name]);

	public static function startGraph(basePath:Array<String>, suffix:String,
			?graphConfig:Array<String>):{channel:haxe.io.Output, close:Void->Void} {
		if (graphConfig == null) graphConfig = [];
		var ch = Path.createFile(false, suffix, [], basePath);
		ch.writeString("digraph graphname {\n");
		for (s in graphConfig) ch.writeString(s + ";\n");
		return {
			channel: ch,
			close: function() {
				ch.writeString("}\n");
				ch.close();
			}
		};
	}
}

package typing;

import core.ClassPaths.ResolvedFile;
import core.Define.DefineContext;
import core.Globals.Pos;
import core.Ast.Package;
import syntax.LegacyGrammar;

// Batch-only portion of haxe/src/typing/typeloadParse.ml.  Display parser
// state, parser caches and stdin replacement are intentionally left to the
// eventual compiler context.
@:structInit class ParsedFile {
	public var file:String;
	public var data:Package;

	public inline function new(file:String, data:Package) {
		this.file = file;
		this.data = data;
	}

	public inline function clone():ParsedFile return new ParsedFile(file, data);
}

class ParseError {
	public final message:String;
	public final pos:Pos;

	public function new(message:String, pos:Pos) {
		this.message = message;
		this.pos = pos;
	}

	public function toString():String return '$message at ${pos.pfile}:${pos.pmin}';
}

class TypeloadParse {
	public static function parseFile(defines:DefineContext, rfile:ResolvedFile):ParsedFile {
		var source:String;
		try source = sys.io.File.getContent(rfile.file)
		catch (_:Dynamic) throw new ParseError('Could not open ' + rfile.file, {pfile: rfile.file, pmin: 0, pmax: 0});
		return parseString(defines, rfile.file, source);
	}

	public static function parseString(defines:DefineContext, file:String, source:String):ParsedFile {
		try return {
			file: file,
			data: LegacyGrammar.parse(source, defines, file)
		} catch (error:syntax.LegacyGrammar.GrammarError) throw new ParseError(error.message, error.pos)
		catch (error:syntax.Lexer.LexerError) throw new ParseError(Std.string(error.message), error.pos)
		catch (error:Dynamic) throw error;
	}
}

package syntax;

import core.Ast;
import core.Ast.*;
import core.Globals.Pos;
import syntax.Lexer.LexedToken;
import syntax.Parser;
import core.ds.Stream;
import core.Warning.Warning;

// Batch-only recursive descent port of the declaration/expression path in
// haxe/src/syntax/grammar.ml.  Display recovery and XML remain parser-entry
// responsibilities and are intentionally not represented here.
class LegacyGrammar {
	public static function parseFileStream(ctx:ParserContext, s:Stream<LexedToken>):Package {
		var grammar = new LegacyGrammar([]);
		grammar.sourceStream = s;
		grammar.parserContext = ctx;
		grammar.canonicalMetadata = true;
		var result = grammar.parseFile();
		for (_ in 0...grammar.index) s.junk();
		return result;
	}

	public static function parseExpressionStream(ctx:ParserContext, s:Stream<LexedToken>):Expr {
		var grammar = new LegacyGrammar([]);
		grammar.sourceStream = s;
		grammar.parserContext = ctx;
		grammar.canonicalMetadata = true;
		var result = grammar.expression();
		for (_ in 0...grammar.index) s.junk();
		return result;
	}

	static function parseMacroIdent(ctx:ParserContext, name:String, p:Pos, s:Stream<LexedToken>):Expr {
		if (name == "display") {
			Parser.syntaxWarningWithPos(ctx, core.WarningList.fromString("WIfDisplay"), p);
			if (ctx.config.specialIdentifierFiles != null) ctx.config.specialIdentifierFiles.replace(core.Path.UniqueKey.create(p.pfile),
				name);
		}
		return {expr: EConst(Ident(name)), pos: p};
	}

	static function validateMacroCond(ctx:ParserContext, s:Stream<LexedToken>, e:Expr):Expr return switch e.expr {
		case EConst(String(_, _)), EConst(Int(_, _)), EConst(Float(_, _)): e;
		case EConst(Ident(name)): parseMacroIdent(ctx, name, e.pos, s);
		case EUnop(op, flag, e1): {expr: EUnop(op, flag, validateMacroCond(ctx, s, e1)), pos: e.pos};
		case EBinop(op, e1, e2): {expr: EBinop(op, validateMacroCond(ctx, s, e1), validateMacroCond(ctx, s, e2)), pos: e.pos};
		case EParenthesis(e1): {expr: EParenthesis(validateMacroCond(ctx, s, e1)), pos: e.pos};
		case EField(e1, name, kind): {expr: EField(validateMacroCond(ctx, s, e1), name, kind), pos: e.pos};
		case ECall({expr: EConst(Ident(_))}, args): switch e.expr {
				case ECall(callee, _): {expr: ECall(callee, args.map(function(arg) return validateMacroCond(ctx, s, arg))), pos: e.pos};
				case _: throw "unreachable";
			}
		case _: Parser.syntaxError(ctx, Custom("Invalid conditional expression"), s, ({expr: EConst(Ident("false")), pos: e.pos} : Expr),
				e.pos);
	};

	public static function parseMacroCond(ctx:ParserContext, s:Stream<LexedToken>):{token:Null<ParserToken>, expr:Expr} {
		var token = s.next();
		return switch token.token {
			case Const(Ident(name)): {token: null, expr: parseMacroIdent(ctx, name, token.pos, s)};
			case Const(String(_, _)), Const(Int(_, _)), Const(Float(_, _)): switch token.token {
					case Const(c): {token: null, expr: {expr: EConst(c), pos: token.pos}};
					case _: throw "unreachable";
				}
			case Kwd(k): {token: null, expr: parseMacroIdent(ctx, Ast.sKeyword(k), token.pos, s)};
			case Unop(op):
				var result = parseMacroCond(ctx, s);
				{token: result.token, expr: Parser.makeUnop(op, result.expr, token.pos)};
			case POpen:
				var e = parseExpressionStream(ctx, s);
				var close = s.next();
				if (close.token != PClose) throw new StreamError("Parse error.");
				{token: null, expr: {expr: EParenthesis(validateMacroCond(ctx, s, e)), pos: Ast.punion(token.pos, close.pos)}};
			case _: throw StreamFailure.raise();
		};
	}

	var pendingDeclarationDoc:Documentation = null;

	public static function parse(source:String, ?defines:core.Define.DefineContext, ?file = "?"):Package {
		var tokens = defines == null ? LegacyLexer.lex(source, file) : Preprocessor.process(source, defines, file);
		return new LegacyGrammar(tokens).parseFile();
	}

	function parseEmbeddedExpression(source:String, file:String, offset:Int):Expr {
		var tokens = LegacyLexer.lex(source, file).filter(function(token) return switch token.token {
			case Comment(_) | CommentLine(_): false;
			case _: true;
		});
		for (token in tokens) {
			token.pos.pmin += offset;
			token.pos.pmax += offset;
		}
		var grammar = new LegacyGrammar(tokens);
		grammar.canonicalMetadata = canonicalMetadata;
		return grammar.expression();
	}

	final tokens:Array<LexedToken>;
	var sourceStream:Null<Stream<LexedToken>>;
	var parserContext:Null<ParserContext>;
	var canonicalMetadata = false;

	function tokenAt(n:Int):LexedToken {
		if (sourceStream != null && n >= tokens.length) {
			var prefix = sourceStream.npeek(n + 1);
			while (tokens.length < prefix.length) tokens.push(prefix[tokens.length]);
		}
		return n < tokens.length ? tokens[n] : {token: Eof, pos: tokens.length == 0 ? core.Globals.nullPos : tokens[tokens.length - 1].pos};
	}

	function hasToken(n:Int):Bool {
		tokenAt(n);
		return n < tokens.length;
	}

	var index = 0;

	public function new(tokens) this.tokens = tokens;

	public function parseFile():Package {
		var pack:Array<String> = [];
		if (acceptKwd(Package) != null) {
			if (! is(Semicolon)) pack = path();
			expect(Semicolon);
		}
		var declarations:Array<TypeDecl> = [];
		while (! is(Eof)) declarations.push(declaration());
		return {pack: pack, declarations: declarations};
	}

	function declaration():TypeDecl {
		var doc = documentation();
		var meta = metadata();
		if (doc == null && pendingDeclarationDoc != null) doc = pendingDeclarationDoc;
		var start = current().pos;
		if (acceptKwd(Import) != null) {
			if (doc != null) pendingDeclarationDoc = doc;
			var names = [placedIdent()];
			var mode:ImportMode = INormal;
			while (accept(Dot) != null) {
				if (is(Binop(OpMult))) {
					next();
					mode = IAll;
					break;
				}
				names.push(placedIdent());
			}
			if (identText() == "as") {
				next();
				mode = IAsName(placedIdent());
			}
			expect(Semicolon);
			return decl(EImport({path: names, mode: mode}), start);
		}
		if (acceptKwd(Using) != null) {
			if (doc != null) pendingDeclarationDoc = doc;
			var p = placedPath();
			expect(Semicolon);
			return decl(EUsing(p), start);
		}
		var accesses = if (is(Kwd(Abstract)) && hasToken(index + 1) && tokenAt(index + 1).token.match(Kwd(Class))) {
			var abstractToken = next();
			([{access: AAbstract, pos: abstractToken.pos}] : Array<PlacedAccess>);
		} else access();
		if (acceptKwd(Class) != null || acceptKwd(Interface) != null) {
			start = previous().pos;
			pendingDeclarationDoc = null;
			var interfaceValue = previousKwd == Interface;
			var name = placedIdent();
			var params = typeParams();
			var flags:Array<ClassFlag> = interfaceValue ? [HInterface] : [];
			if (hasAccess(accesses, AExtern)) flags.push(HExtern);
			if (hasAccess(accesses, APrivate)) flags.push(HPrivate);
			if (hasAccess(accesses, AFinal)) flags.push(HFinal);
			if (hasAccess(accesses, AAbstract)) flags.push(HAbstract);
			while (true) {
				if (acceptKwd(Extends) != null) flags.push(HExtends(typePath()));
				else if (acceptKwd(Implements) != null) flags.push(HImplements(typePath()));
				else break;
			}
			expect(BrOpen);
			var fields = classFields();
			var end = expect(BrClose).pos;
			return decl(EClass({
				name: name,
				doc: doc,
				params: params,
				meta: meta,
				flags: flags,
				data: fields
			}), union(start, end));
		}
		var enumToken = acceptKwd(Enum);
		if (enumToken != null) {
			start = enumToken.pos;
			pendingDeclarationDoc = null;
			if (acceptKwd(Abstract) != null) return abstractDeclaration(start, doc, meta, accesses, true);
			var name = placedIdent(),
				params = typeParams(),
				flags:Array<EnumFlag> = [];
			if (hasAccess(accesses, AExtern)) flags.push(EExtern);
			if (hasAccess(accesses, APrivate)) flags.push(EPrivate);
			expect(BrOpen);
			var data = [];
			while (! is(BrClose)) data.push(enumConstructor());
			var end = expect(BrClose).pos;
			return decl(EEnum({
				name: name,
				doc: doc,
				params: params,
				meta: meta,
				flags: flags,
				data: data
			}), union(start, end));
		}
		if (acceptKwd(Typedef) != null) {
			start = previous().pos;
			pendingDeclarationDoc = null;
			var name = placedIdent(), params = typeParams();
			expect(Binop(OpAssign));
			var data = typeHint();
			var end = accept(Semicolon);
			var flags:Array<TypedefFlag> = [];
			if (hasAccess(accesses, AExtern)) flags.push(TDExtern);
			if (hasAccess(accesses, APrivate)) flags.push(TDPrivate);
			// grammar.ml consumes an optional semicolon but excludes it from the
			// declaration range.
			var declarationEnd:Pos = end == null ? data.pos : {pfile: end.pos.pfile, pmin: end.pos.pmin, pmax: end.pos.pmin};
			return decl(ETypedef({
				name: name,
				doc: doc,
				params: params,
				meta: meta,
				flags: flags,
				data: data
			}), union(start, declarationEnd));
		}
		if (acceptKwd(Abstract) != null) {
			start = previous().pos;
			pendingDeclarationDoc = null;
			return abstractDeclaration(start, doc, meta, accesses, false);
		}
		if (acceptKwd(Var) != null || hasAccess(accesses, AFinal)) {
			pendingDeclarationDoc = null;
			var name = placedIdent();
			if (accept(POpen) != null) {
				var get = placedIdent();
				expect(Comma);
				var set = placedIdent();
				expect(PClose);
				var type = typeHintOpt();
				var value = accept(Binop(OpAssign)) == null ? null : expression();
				var end = semicolon().pos;
				return decl(EStatic({
					name: name,
					doc: doc,
					params: [],
					meta: meta,
					flags: accesses,
					data: FProp(get, set, type, value)
				}), union(start, end));
			}
			var type = typeHintOpt();
			var value = accept(Binop(OpAssign)) == null ? null : expression();
			var end = semicolon().pos;
			return decl(EStatic({
				name: name,
				doc: doc,
				params: [],
				meta: meta,
				flags: accesses,
				data: FVar(type, value)
			}), union(start, end));
		}
		if (acceptKwd(Function) != null) {
			start = previous().pos;
			pendingDeclarationDoc = null;
			var name = placedIdent();
			var func = functionRest();
			var end = func.fExpr == null ? name.pos : func.fExpr.pos;
			accept(Semicolon);
			return decl(EStatic({
				name: name,
				doc: doc,
				params: func.fParams,
				meta: meta,
				flags: accesses,
				data: FFun(func)
			}), union(start, end));
		}
		fail("Expected a type declaration");
		return null;
	}

	function abstractDeclaration(start:Pos, doc:Documentation, meta:Metadata, accesses:Array<PlacedAccess>, enumAbstract:Bool):TypeDecl {
		var name = placedIdent(), params = typeParams();
		var flags:Array<AbstractFlag> = [];
		if (hasAccess(accesses, AExtern)) flags.push(AbExtern);
		if (hasAccess(accesses, APrivate)) flags.push(AbPrivate);
		if (enumAbstract) flags.push(AbEnum);
		if (accept(POpen) != null) {
			flags.push(AbOver(typeHint()));
			expect(PClose);
		}
		while (true) {
			if (identText() == "from") {
				next();
				flags.push(AbFrom(typeHint()));
			} else if (identText() == "to") {
				next();
				flags.push(AbTo(typeHint()));
			} else break;
		}
		expect(BrOpen);
		var fields = classFields();
		var end = expect(BrClose).pos;
		return decl(EAbstract({
			name: name,
			doc: doc,
			params: params,
			meta: meta,
			flags: flags,
			data: fields
		}), union(start, end));
	}

	var previousKwd:Null<Keyword>;

	function access(?field = false):Array<PlacedAccess> {
		var result:Array<PlacedAccess> = [];
		while (true) {
			var t = current();
			var a:Null<Access> = switch t.token {
				case Kwd(Public): APublic;
				case Kwd(Private): APrivate;
				case Kwd(Static): AStatic;
				case Kwd(Override): AOverride;
				case Kwd(Dynamic): ADynamic;
				case Kwd(Inline): AInline;
				case Kwd(Macro): AMacro;
				case Kwd(Final): AFinal;
				case Kwd(Extern): AExtern;
				case Kwd(Abstract) if (field || classDeclarationAhead()): AAbstract;
				case Kwd(Overload): AOverload;
				case _: null;
			};
			if (a == null) return result;
			next();
			result.push({access: a, pos: t.pos});
		}
	}

	function classDeclarationAhead():Bool {
		var cursor = index;
		while (hasToken(cursor)) switch tokenAt(cursor++).token {
			case Kwd(Public | Private | Extern | Final | Abstract):
			case Kwd(Class):
				return true;
			case _:
				return false;
		}
		return false;
	}

	function classFields():Array<ClassField> {
		var fields:Array<ClassField> = [];
		while (! is(BrClose)) {
			var field = classField();
			if (field != null) fields.push(field);
		}
		return fields;
	}

	function classField():Null<ClassField> {
		var doc = documentation(), meta = metadata();
		var start = current().pos;
		var accesses = access(true);
		// Conditional compilation can leave a documentation comment immediately
		// before the closing brace after its documented field is removed.
		if (is(BrClose)) return null;
		if (hasAccess(accesses, AFinal) && ! is(Kwd(Var)) && ! is(Kwd(Function))) {
			var name = placedIdent();
			var type = typeHintOpt();
			var value = accept(Binop(OpAssign)) == null ? null : expression();
			var end = semicolon().pos;
			return {
				cffName: name,
				cffDoc: doc,
				cffPos: union(start, end),
				cffMeta: meta,
				cffAccess: accesses,
				cffKind: FVar(type, value)
			};
		}
		if (acceptKwd(Var) != null) {
			var name = placedIdent();
			if (accept(POpen) != null) {
				var get = placedIdent();
				expect(Comma);
				var set = placedIdent();
				expect(PClose);
				var type = typeHintOpt();
				var value = accept(Binop(OpAssign)) == null ? null : expression();
				var end = semicolon().pos;
				return {
					cffName: name,
					cffDoc: doc,
					cffPos: union(start, end),
					cffMeta: meta,
					cffAccess: accesses,
					cffKind: FProp(get, set, type, value)
				};
			}
			var type = typeHintOpt();
			var value = accept(Binop(OpAssign)) == null ? null : expression();
			var end = semicolon().pos;
			return {
				cffName: name,
				cffDoc: doc,
				cffPos: union(start, end),
				cffMeta: meta,
				cffAccess: accesses,
				cffKind: FVar(type, value)
			};
		}
		if (acceptKwd(Function) != null) {
			var name = placedIdent();
			var f = functionRest();
			var end = f.fExpr == null ? previous().pos : f.fExpr.pos;
			accept(Semicolon);
			return {
				cffName: name,
				cffDoc: doc,
				cffPos: union(start, end),
				cffMeta: meta,
				cffAccess: accesses,
				cffKind: FFun(f)
			};
		}
		fail("Expected class field");
		return null;
	}

	function functionRest():Func {
		var params = typeParams();
		expect(POpen);
		var args = [];
		if (! is(PClose)) while (true) {
			args.push(functionArg());
			if (accept(Comma) == null || is(PClose)) break;
		}
		expect(PClose);
		var ret = typeHintOpt();
		var body:Null<Expr>;
		if (accept(Semicolon) != null) body = null;
		else if (is(BrOpen)) body = block();
		else body = expression();
		return {
			fParams: params,
			fArgs: args,
			fType: ret,
			fExpr: body
		};
	}

	function functionArg():FuncArg {
		var meta = metadata();
		var spread = accept(Spread);
		var optional = spread == null && accept(Question) != null;
		var name = placedIdent();
		var type = typeHintOpt();
		if (spread != null) {
			var inner:TypeHint = type == null ? {type: Ast.ctMono(), pos: core.Globals.nullPos} : type;
			var restPos = union(spread.pos, inner.pos);
			type = Ast.makePtpTh(Ast.mkTypePath(["haxe"], "Rest", [TPType(inner)]), restPos);
		}
		var value = accept(Binop(OpAssign)) == null ? null : expression();
		return {
			name: name,
			optional: optional,
			meta: meta,
			type: type,
			expr: value
		};
	}

	function expression(?min = 0):Expr {
		var left = unary();
		if (is(Arrow)) {
			var argument = switch left.expr {
				case EConst(Ident(name)): ({
						name: {name: name, pos: left.pos},
						optional: false,
						meta: [],
						type: null,
						expr: null
					} : FuncArg);
				case EParenthesis({expr: EConst(Ident(name)), pos: argumentPos}): ({
						name: {name: name, pos: argumentPos},
						optional: false,
						meta: [],
						type: null,
						expr: null
					} : FuncArg);
				case _:
					fail("Invalid arrow function argument", left.pos);
					null;
			};
			left = arrowFunction(left.pos, [argument]);
		}
		while (true) {
			if (current().token.match(Const(Ident("is")))) {
				if (8 < min) break;
				next();
				var type = typeHint();
				left = expr(EIs(left, type), union(left.pos, type.pos));
				continue;
			}
			var op = current().token.match(Kwd(In)) ? OpIn : binop(current().token);
			if (op == null || precedence(op) < min) break;
			next();
			var right = switch op {
				case OpAssign | OpAssignOp(_) | OpIn: expression();
				case _: expression(precedence(op) + 1);
			};
			left = expr(EBinop(op, left, right), union(left.pos, right.pos));
		}
		if (min == 0 && accept(Question) != null) {
			var thenExpr = expression();
			expect(DblDot);
			var elseExpr = expression();
			left = expr(ETernary(left, thenExpr, elseExpr), union(left.pos, elseExpr.pos));
		}
		return left;
	}

	function unary():Expr {
		var t = current();
		return switch t.token {
			case At:
				// Expression metadata (for example @:privateAccess value) wraps the
				// full following expression in grammar.ml (`make_meta ... secure_expr`),
				// including postfix access and assignment. Parsing only a unary
				// would drop `.field` continuations (`@:privateAccess host.top = prev`).
				var metas = metadata();
				var value = expression();
				for (i in 0...metas.length) {
					var meta = metas[metas.length - 1 - i];
					value = expr(EMeta(meta, value), union(meta.pos, value.pos));
				}
				value;
			case Unop(op):
				next();
				var e = unary();
				expr(EUnop(op, Prefix, e), union(t.pos, e.pos));
			case Spread:
				next();
				var e = unary();
				expr(EUnop(Spread, Prefix, e), union(t.pos, e.pos));
			case Binop(OpSub):
				next();
				var e = unary();
				expr(EUnop(Neg, Prefix, e), union(t.pos, e.pos));
			case Kwd(Return):
				next();
				var e = expressionEnded() ? null : expression();
				expr(EReturn(e), e == null ? t.pos : union(t.pos, e.pos));
			case Kwd(Throw):
				next();
				var e = expression();
				expr(EThrow(e), union(t.pos, e.pos));
			case Kwd(Var) | Kwd(Final):
				var finalValue = acceptKwd(Final) != null;
				if (!finalValue) next();
				var vars = [variable(finalValue)];
				while (accept(Comma) != null) vars.push(variable(finalValue));
				expr(EVars(vars),
					union(t.pos,
						vars[vars.length - 1].evExpr == null ? vars[vars.length - 1].evName.pos : vars[vars.length - 1].evExpr.pos));
			case Kwd(Static):
				next();
				var finalValue = acceptKwd(Final) != null;
				if (!finalValue) expectKwd(Var);
				var vars = [variable(finalValue)];
				while (accept(Comma) != null) vars.push(variable(finalValue));
				for (variable in vars) variable.evStatic = true;
				expr(EVars(vars),
					union(t.pos,
						vars[vars.length - 1].evExpr == null ? vars[vars.length - 1].evName.pos : vars[vars.length - 1].evExpr.pos));
			case Kwd(If):
				next();
				expect(POpen);
				var c = expression();
				expect(PClose);
				var th = statementBody();
				if (!th.expr.match(EBlock(_))) accept(Semicolon);
				var el = acceptKwd(Else) == null ? null : statementBody();
				expr(EIf(c, th, el), union(t.pos, el == null ? th.pos : el.pos));
			case Kwd(While):
				next();
				expect(POpen);
				var c = expression();
				expect(PClose);
				var b = statementBody();
				expr(EWhile(c, b, NormalWhile), union(t.pos, b.pos));
			case Kwd(For):
				next();
				expect(POpen);
				var it = expression();
				if (acceptKwd(In) != null) {
					var right = expression();
					it = expr(EBinop(OpIn, it, right), union(it.pos, right.pos));
				}
				expect(PClose);
				var b = statementBody();
				expr(EFor(it, b), union(t.pos, b.pos));
			case Kwd(Do):
				next();
				var b = statementBody();
				expectKwd(While);
				expect(POpen);
				var c = expression();
				var end = expect(PClose).pos;
				expr(EWhile(c, b, DoWhile), union(t.pos, end));
			case Kwd(Try):
				next();
				var body = statementBody();
				var catches = [];
				while (acceptKwd(Catch) != null) {
					var cp = previous().pos;
					expect(POpen);
					var n = placedIdent();
					var ty = typeHintOpt();
					expect(PClose);
					var cb = statementBody();
					catches.push(({
						name: n,
						type: ty,
						expr: cb,
						pos: union(cp, cb.pos)
					} : core.Ast.Catch));
				}
				expr(ETry(body, catches), union(t.pos, catches.length == 0 ? body.pos : catches[catches.length - 1].pos));
			case Kwd(Switch):
				next();
				parseSwitch(t.pos);
			case Kwd(Break):
				next();
				expr(EBreak, t.pos);
			case Kwd(Continue):
				next();
				expr(EContinue, t.pos);
			case Kwd(Untyped):
				next();
				var e = is(BrOpen) ? block() : expression();
				expr(EUntyped(e), union(t.pos, e.pos));
			case Kwd(Cast):
				next();
				var casted = if (accept(POpen) != null) {
					var e = expression();
					if (accept(Comma) != null) {
						var type = typeHint();
						var end = expect(PClose).pos;
						expr(ECast(e, type), union(t.pos, end));
					} else if (accept(DblDot) != null) {
						var type = typeHint();
						var end = expect(PClose).pos;
						var checked = expr(ECheckType(e, type), union(e.pos, type.pos));
						var parenthesized = expr(EParenthesis(checked), union(e.pos, end));
						expr(ECast(parenthesized, null), union(t.pos, end));
					} else {
						var end = expect(PClose).pos;
						var parenthesized = expr(EParenthesis(e), union(e.pos, end));
						expr(ECast(parenthesized, null), union(t.pos, end));
					}
				} else {
					var e = unary();
					expr(ECast(e, null), union(t.pos, e.pos));
				};
				postfix(casted);
			case _:
				var value = primary();
				// Upstream returns statement blocks directly and only continues into
				// postfix parsing for object literals. Otherwise a following prefix
				// `++`/`--` statement is attached to the preceding `}`.
				switch value.expr {
					case EBlock(_): value;
					case _: postfix(value);
				}
		};
	}

	function primary():Expr {
		var t = next();
		var e:Expr = switch t.token {
			case Const(c): expr(EConst(c), t.pos);
			case Dollar(name): expr(EConst(Ident("$" + name)), t.pos);
			case IntInterval(value):
				var left = expr(EConst(Int(value, null)), t.pos);
				var right = expression(precedence(OpInterval) + 1);
				expr(EBinop(OpInterval, left, right), union(left.pos, right.pos));
			case Kwd(True): expr(EConst(Ident("true")), t.pos);
			case Kwd(False): expr(EConst(Ident("false")), t.pos);
			case Kwd(Null): expr(EConst(Ident("null")), t.pos);
			case Kwd(This): expr(EConst(Ident("this")), t.pos);
			case POpen:
				if (parenthesizedArrowAhead()) {
					var args:Array<FuncArg> = [];
					if (! is(PClose)) while (true) {
						args.push(functionArg());
						if (accept(Comma) == null || is(PClose)) break;
					}
					expect(PClose);
					arrowFunction(t.pos, args);
				} else {
					var x = expression();
					if (accept(DblDot) != null) {
						var hint = typeHint();
						x = expr(ECheckType(x, hint), union(x.pos, hint.pos));
					}
					var end = expect(PClose).pos;
					expr(EParenthesis(x), union(t.pos, end));
				}
			case BrOpen:
				index--;
				objectOrIdentifier();
			case Kwd(New):
				var p = typePath();
				expect(POpen);
				var args = [];
				if (! is(PClose)) while (true) {
					args.push(expression());
					if (accept(Comma) == null || is(PClose)) break;
				}
				var end = expect(PClose).pos;
				expr(ENew(p, args), union(t.pos, end));
			case BkOpen:
				var values = [];
				while (! is(BkClose)) {
					values.push(expression());
					if (accept(Comma) == null) break;
				}
				var end = expect(BkClose).pos;
				expr(EArrayDecl(values), union(t.pos, end));
			case Kwd(Inline):
				if (acceptKwd(Function) != null) {
					var name:Null<PlacedName> = is(POpen) ? null : placedIdent();
					var f = functionRest();
					expr(EFunction(name == null ? FKAnonymous : FKNamed(name, true), f),
						union(t.pos, f.fExpr == null ? t.pos : f.fExpr.pos));
				} else {
					var value = unary();
					expr(EMeta({meta: metadataTag("inline", true), exprs: [], pos: t.pos}, value), union(t.pos, value.pos));
				}
			case Kwd(Macro):
				// Macro fields are rejected by the source-only typer, but their bodies
				// still have to parse so the declaration can reach that boundary.
				var value = unary();
				value.pos = union(t.pos, value.pos);
				value;
			case Kwd(Function):
				var name:Null<PlacedName> = is(POpen) || is(Binop(OpLt)) ? null : placedIdent();
				var f = functionRest();
				expr(EFunction(name == null ? FKAnonymous : FKNamed(name, false), f), union(t.pos, f.fExpr == null ? t.pos : f.fExpr.pos));
			case _:
				index--;
				objectOrIdentifier();
		};
		return e;
	}

	function parenthesizedArrowAhead():Bool {
		var depth = 0;
		var cursor = index;
		while (hasToken(cursor)) switch tokenAt(cursor++).token {
			case POpen:
				depth++;
			case PClose if (depth == 0):
				return hasToken(cursor) && tokenAt(cursor).token.match(Arrow);
			case PClose:
				depth--;
			case Eof:
				return false;
			case _:
		}
		return false;
	}

	function arrowFunction(start:Pos, args:Array<FuncArg>):Expr {
		expect(Arrow);
		var body = is(BrOpen) ? block() : expression();
		var returned = expr(EReturn(body), body.pos);
		var implicit = expr(EMeta({meta: metadataTag("implicitReturn", true), exprs: [], pos: body.pos}, returned), body.pos);
		return expr(EFunction(FKArrow, {
			fParams: [],
			fArgs: args,
			fType: null,
			fExpr: implicit
		}), union(start, body.pos));
	}

	function parseSwitch(start:Pos):Expr {
		var subject = expression();
		expect(BrOpen);
		var cases:Array<SwitchCase> = [];
		var defaultCase:Null<SwitchDefault> = null;
		while (! is(BrClose)) {
			if (acceptKwd(Case) != null) {
				var caseStart = previous().pos, values = [switchPattern()];
				while (accept(Comma) != null) values.push(switchPattern());
				var guard = acceptKwd(If) == null ? null : expression();
				expect(DblDot);
				var value = switchBody();
				cases.push({
					values: values,
					guard: guard,
					expr: value,
					pos: union(caseStart, value == null ? values[values.length - 1].pos : value.pos)
				});
			} else if (acceptKwd(Default) != null) {
				var defaultStart = previous().pos;
				expect(DblDot);
				var value = switchBody();
				defaultCase = {expr: value, pos: value == null ? defaultStart : union(defaultStart, value.pos)};
			} else fail("Expected switch case");
		}
		var end = expect(BrClose).pos;
		return expr(ESwitch(subject, cases, defaultCase), union(start, end));
	}

	function switchPattern():Expr {
		if (! is(Kwd(Var))) return expression();
		var start = next().pos;
		var name = placedIdent();
		var variable = Ast.mkEVar(name, false, false, null, null);
		return expr(EVars([variable]), union(start, name.pos));
	}

	function switchBody():Null<Expr> {
		var values:Array<Expr> = [];
		while (! is(Kwd(Case)) && ! is(Kwd(Default)) && ! is(BrClose)) {
			var value = expression();
			values.push(value);
			if (accept(Semicolon) == null && !previous().token.match(Semicolon) && ! is(Kwd(Case)) && ! is(Kwd(Default))
				&& ! is(BrClose) && requiresSemicolon(value)) fail("Expected semicolon");
		}
		if (values.length == 0) return null;
		if (values.length == 1) return values[0];
		return expr(EBlock(values), union(values[0].pos, values[values.length - 1].pos));
	}

	function objectOrIdentifier():Expr {
		var t = current();
		if (accept(BrOpen) != null) {
			// Upstream tries an object key (`$ident`, plain ident, or string
			// literal) followed by `:` first and parses a block otherwise, so
			// `{ @:meta ... }` is a block. Only treating the brace as an
			// object when the *key-shaped* token is followed by `:` keeps
			// metadata-led blocks out of the object path.
			var keyLike = switch current().token {
				case Const(Ident(_)) | Const(String(_, _)) | Dollar(_): true;
				case _: false;
			};
			if (! is(BrClose) && !(keyLike && hasToken(index + 1) && tokenAt(index + 1).token.match(DblDot))) return blockContents(t.pos);
			var fields = [];
			while (! is(BrClose)) {
				var key = switch current() {
					case {token: Const(String(name, _)), pos: pos}:
						next();
						{name: name, pos: pos, quote: DoubleQuotes};
					case _:
						var n = placedIdent();
						{name: n.name, pos: n.pos, quote: NoQuotes};
				};
				expect(DblDot);
				var value = expression();
				fields.push(({key: key, expr: value} : core.Ast.ObjectField));
				if (accept(Comma) == null) break;
			}
			var end = expect(BrClose).pos;
			return expr(EObjectDecl(fields), union(t.pos, end));
		}
		var n = placedIdent();
		return expr(EConst(Ident(n.name)), n.pos);
	}

	function postfix(e:Expr):Expr {
		while (true) {
			if (is(BrOpen) && switch e.expr {
					case EConst(Ident(name)): StringTools.startsWith(name, "$");
					case _: false;
				}) {
				var begin = next().pos;
				var parameter = expression();
				var end = expect(BrClose).pos;
				var name = switch e.expr {
					case EConst(Ident(value)): value;
					case _: "";
				};
				e = expr(EMeta({meta: metadataTag(name, false), exprs: [], pos: e.pos}, parameter), union(begin, end));
				} else if (accept(Dot) != null || accept(QuestionDot) != null) {
				var safe = previous().token.match(QuestionDot);
				var n = placedFieldName();
				e = expr(EField(e, n.name, safe ? EFSafe : EFNormal), union(e.pos, n.pos));
			} else if (accept(POpen) != null) {
				var args = [];
				if (! is(PClose)) while (true) {
					args.push(expression());
					if (accept(Comma) == null || is(PClose)) break;
				}
				var end = expect(PClose).pos;
				e = expr(ECall(e, args), union(e.pos, end));
			} else if (accept(BkOpen) != null) {
				var key = expression();
				var end = expect(BkClose).pos;
				e = expr(EArray(e, key), union(e.pos, end));
			} else if (!e.expr.match(EFunction(_, _)) && switch current().token {
				case Unop(Increment) | Unop(Decrement) | Unop(Not): true;
				case _: false;
				}) {
				var op = switch next().token {
					case Unop(v): v;
					case _: null;
				};
				e = expr(EUnop(op, Postfix, e), union(e.pos, previous().pos));
				} else return e;
		}
		return e;
	}

	function block():Expr return blockContents(expect(BrOpen).pos);

	function blockContents(begin:Pos):Expr {
		var es = [];
		while (! is(BrClose)) {
			documentation();
			if (is(BrClose)) break;
			var value = expression();
			es.push(value);
			var terminator = accept(Semicolon);
			if (terminator != null && value.expr.match(EVars(_))) value.pos = union(value.pos, terminator.pos);
			if (terminator == null && ! is(BrClose) && !previous().token.match(BrClose) && !previous().token.match(Semicolon)
				&& requiresSemicolon(value)) fail("Expected semicolon");
		}
		return expr(EBlock(es), union(begin, expect(BrClose).pos));
	}

	function statementBody():Expr return expression();

	function expressionEnded():Bool return switch current().token {
		case Semicolon | BrClose | BkClose | PClose | Comma | DblDot | Eof: true;
		case Kwd(Case) | Kwd(Default) | Kwd(Else): true;
		case _: false;
	};

	static function requiresSemicolon(value:Expr):Bool return switch value.expr {
		case EBlock(_) | EIf(_, _, _) | EWhile(_, _, _) | EFor(_, _) | ESwitch(_, _, _) | ETry(_, _) | EFunction(_, _): false;
		case EBinop(OpAssign | OpAssignOp(_), _,
			{expr: EFunction(_, {fExpr: {expr: EBlock(_) | EMeta(_, {expr: EReturn({expr: EBlock(_)})})}})}): false;
		case EVars(vars) if (vars.length > 0 && switch vars[vars.length - 1].evExpr {
				case {expr: EFunction(_, _)}: true;
				case _: false;
			}): false;
		case _: true;
	}

	function variable(finalValue = false):EVar {
		var n = placedIdent();
		var type = typeHintOpt();
		var value = accept(Binop(OpAssign)) == null ? null : expression();
		return Ast.mkEVar(n, finalValue, false, type, value);
	}

	function typeHintOpt():Null<TypeHint> return accept(DblDot) == null ? null : typeHint();

	function typeHint():TypeHint {
		var first = typeHintInner();
		if (accept(Arrow) != null) {
			var rest = typeHint();
			var functionType = switch rest.type {
				case CTFunction(args, ret): CTFunction([first].concat(args), ret);
				case _: CTFunction([first], rest);
			};
			return {type: functionType, pos: union(first.pos, rest.pos)};
		}
		if (accept(Binop(OpAnd)) == null) return first;
		var rest = typeHint();
		var types = switch rest.type {
			case CTIntersection(types): [first].concat(types);
			case _: [first, rest];
		};
		return {type: CTIntersection(types), pos: union(first.pos, rest.pos)};
	}

	function typeHintInner():TypeHint {
		var start = current().pos;
		var optional = accept(Question) != null;
		var complex:ComplexType;
		if (accept(POpen) != null) {
			var args:Array<TypeHint> = [];
			if (! is(PClose)) while (true) {
				if (is(Spread)) {
					var spread = next();
					var name = placedIdent();
					expect(DblDot);
					var value = typeHint();
					var rest = Ast.makePtpTh(Ast.mkTypePath(["haxe"], "Rest", [TPType(value)]), union(spread.pos, value.pos));
					args.push({type: CTNamed(name, rest), pos: union(spread.pos, value.pos)});
				} else if (is(Question) && hasToken(index + 2) && switch tokenAt(index + 1).token {
					case Const(Ident(_)): tokenAt(index + 2).token.match(DblDot);
					case _: false;
					}) {
					var optionalStart = next().pos;
					var name = placedIdent();
					expect(DblDot);
					var value = typeHint();
					var named:TypeHint = {type: CTNamed(name, value), pos: union(name.pos, value.pos)};
					args.push(({type: CTOptional(named), pos: union(optionalStart, value.pos)} : TypeHint));
					} else if (identText() != null && hasToken(index + 1) && tokenAt(index + 1).token.match(DblDot)) {
					var name = placedIdent();
					expect(DblDot);
					var value = typeHint();
					args.push({type: CTNamed(name, value), pos: union(name.pos, value.pos)});
				} else args.push(typeHint());
				if (accept(Comma) == null || is(PClose)) break;
			}
			var close = expect(PClose).pos;
			if (accept(Arrow) != null) {
				var result = typeHint();
				complex = CTFunction(args, result);
				return {
					type: optional ? CTOptional({
						type: complex,
						pos: union(start, result.pos)
					}) : complex,
					pos: union(start, result.pos)
				};
			}
			if (args.length != 1) fail("Expected function type arrow", close);
			complex = CTParent(args[0]);
			return {type: optional ? CTOptional({type: complex, pos: union(start, close)}) : complex, pos: union(start, close)};
		}
		if (accept(BrOpen) != null) {
			// parse_type_anonymous in grammar.ml uses the ordinary class-field
			// grammar. This is needed by StdTypes' Iterator/Iterable typedefs.
			var extensions:Array<PlacedTypePath> = [];
			while (accept(Binop(OpGt)) != null) {
				extensions.push(typePath());
				if (accept(Comma) == null) break;
			}
			var fields = [];
			while (! is(BrClose)) {
				fields.push(anonymousField());
				accept(Comma);
			}
			var end = expect(BrClose).pos;
			complex = extensions.length == 0 ? CTAnonymous(fields) : CTExtend(extensions, fields);
			return {type: optional ? CTOptional({type: complex, pos: union(start, end)}) : complex, pos: union(start, end)};
		}
		// `default` in type position means "use the default type argument"
		// (grammar.ml maps it to `$._hx_default`).
		var defaultToken = acceptKwd(Default);
		if (defaultToken != null) {
			var path = Ast.mkTypePath(["$"], "_hx_default");
			complex = CTPath(Ast.makePtp(path, union(start, defaultToken.pos)));
			return {
				type: optional ? CTOptional({
					type: complex,
					pos: union(start, defaultToken.pos)
				}) : complex,
				pos: union(start, defaultToken.pos)
			};
		}
		complex = CTPath(typePath());
		if (accept(Arrow) != null) {
			var result = typeHint();
			complex = switch result.type {
				case CTFunction(args, ret): CTFunction(([{type: complex, pos: start}] : Array<core.Ast.TypeHint>).concat(args), ret);
				case _: CTFunction([{type: complex, pos: start}], result);
			};
			return {type: optional ? CTOptional({type: complex, pos: union(start, result.pos)}) : complex, pos: union(start, result.pos)};
		}
		return {type: optional ? CTOptional({type: complex, pos: start}) : complex, pos: start};
	}

	function anonymousField():ClassField {
		var doc = documentation(),
			meta = metadata(),
			start = current().pos,
			accesses = access(true);
		if (is(Kwd(Var))) next();
		if (acceptKwd(Function) != null) {
			var name = placedIdent(), func = functionRest();
			var end = func.fExpr == null ? previous().pos : func.fExpr.pos;
			return {
				cffName: name,
				cffDoc: doc,
				cffPos: union(start, end),
				cffMeta: meta,
				cffAccess: accesses,
				cffKind: FFun(func)
			};
		}
		var optional = accept(Question) != null;
		var name = placedIdent();
		if (optional) meta.unshift({meta: metadataTag("optional", true), exprs: [], pos: core.Globals.nullPos});
		if (accept(POpen) != null) {
			var get = placedIdent();
			expect(Comma);
			var set = placedIdent();
			expect(PClose);
			expect(DblDot);
			var type = typeHint();
			var end = accept(Semicolon);
			return {
				cffName: name,
				cffDoc: doc,
				cffPos: end == null ? union(start, type.pos) : union(start, end.pos),
				cffMeta: meta,
				cffAccess: accesses,
				cffKind: FProp(get, set, type, null)
			};
		}
		expect(DblDot);
		var type = typeHint();
		var end = accept(Semicolon);
		return {
			cffName: name,
			cffDoc: doc,
			cffPos: end == null ? union(start, type.pos) : union(start, end.pos),
			cffMeta: meta,
			cffAccess: accesses,
			cffKind: FVar(type, null)
		};
	}

	function typePath():PlacedTypePath {
		var names = placedPath(), moduleIndex = -1;
		for (index in 0...names.length) if (!Ast.isLowerIdent(names[index].name)) {
			moduleIndex = index;
			break;
		}
		if (moduleIndex < 0) {
			fail("Type name should start with an uppercase letter", names[names.length - 1].pos);
			moduleIndex = names.length - 1;
		}
		if (names.length > moduleIndex + 2
			|| names.length == moduleIndex + 2
			&& Ast.isLowerIdent(names[moduleIndex + 1].name)) fail("Invalid type path", names[moduleIndex + 1].pos);
		var module = names[moduleIndex],
			sub = names.length == moduleIndex + 2 ? names[moduleIndex + 1] : null;
		var params = [], pathEnd = sub == null ? module.pos : sub.pos, end = pathEnd;
		if (accept(Binop(OpLt)) != null) {
			if (!isTypeGt()) do params.push(typePathParameter()) while (accept(Comma) != null);
			end = expectTypeGt().pos;
		}
		return Ast.makePtp(Ast.mkTypePath([for (index in 0...moduleIndex) names[index].name], module.name, params,
			sub == null ? null : sub.name),
			union(names[0].pos, end), union(names[0].pos, pathEnd));
	}

	function typePathParameter():TypeParamOrConst return switch current().token {
		case Const(Int(_,
			_) | Float(_,
				_) | String(_, _) | Regexp(_, _)) | Kwd(True | False | Null) | Binop(OpSub) | BkOpen | Dollar(_): TPExpr(expression(9));
		case _: TPType(typeHint());
	};

	function path():Array<String> return [for (n in placedPath()) n.name];

	function placedPath():Array<PlacedName> {
		var result = [placedIdent()];
		while (accept(Dot) != null) result.push(placedIdent());
		return result;
	}

	function typeParams():Array<TypeParam> {
		if (accept(Binop(OpLt)) == null) return [];
		var result = [];
		if (!isTypeGt()) do {
			var meta = metadata();
			var name = placedIdent();
			var constraints = typeHintOpt();
			var defaultValue = accept(Binop(OpAssign)) == null ? null : typeHint();
			result.push(({
				tpName: name,
				tpParams: [],
				tpConstraints: constraints,
				tpDefault: defaultValue,
				tpMeta: meta
			} : core.Ast.TypeParam));
		} while (accept(Comma) != null);
		expectTypeGt();
		return result;
	}

	function enumConstructor():EnumConstructor {
		var doc = documentation(), meta = metadata(), name = placedIdent(), params = typeParams(), args = [];
		if (accept(POpen) != null) {
			if (! is(PClose)) while (true) {
				var optional = accept(Question) != null;
				var n = placedIdent();
				var t = typeHintOpt();
				if (t == null) fail("Expected enum parameter type", n.pos);
				args.push(({name: n.name, optional: optional, type: t} : core.Ast.EnumConstructorArg));
				if (accept(Comma) == null || is(PClose)) break;
			}
			expect(PClose);
		}
		var type = typeHintOpt();
		var end = expect(Semicolon).pos;
		return {
			ecName: name,
			ecDoc: doc,
			ecMeta: meta,
			ecArgs: args,
			ecPos: union(name.pos, end),
			ecParams: params,
			ecType: type
		};
	}

	function documentation():Documentation {
		if (parserContext != null) {
			current();
			return Ast.docFromStringOpt(Parser.getDoc(parserContext, sourceStream));
		}
		var value:Null<String> = null;
		while (true) switch (current().token) {
			case Comment(v):
				next();
				if (StringTools.startsWith(v, "*")) {
					value = v.substr(1);
					// Haxe accepts the common `**/` closing style and excludes its
					// extra star from the documentation text.
					if (StringTools.endsWith(value, "*")) value = value.substr(0, value.length - 1);
				}
			case CommentLine(_):
				next();
			case _:
				return Ast.docFromStringOpt(value);
		}
	}

	// The old batch loader consumes string metadata; parser-entry consumers use upstream StrictMeta.
	function metadataTag(name:String, strict:Bool):Dynamic {
		if (!canonicalMetadata) return name;
		return strict ? core.Meta.parse(name) : core.Meta.fromString(name);
	}

	function metadata():Metadata {
		var result:Array<MetadataEntry> = [];
		while (accept(At) != null) {
			var start = previous().pos;
			var strict = accept(DblDot) != null;
			var name = placedPath();
			var values = [];
			var end = name[name.length - 1].pos;
			if (is(POpen) && current().pos.pmin == end.pmax) {
				next();
				while (! is(PClose)) {
					values.push(expression());
					if (accept(Comma) == null) break;
				}
				expect(PClose);
			}
			// grammar.ml parse_meta_entry: punion p1 p, where p is the meta name position.
			result.push({meta: metadataTag([for (n in name) n.name].join("."), strict), exprs: values, pos: union(start, end)});
		}
		return result;
	}

	function placedIdent():PlacedName {
		var t = next();
		return switch t.token {
			case Const(Ident(v)): {name: v, pos: t.pos};
			case Kwd(k): {name: Ast.sKeyword(k), pos: t.pos};
			case _:
				fail("Expected identifier", t.pos);
				null;
		};
	}

	function placedFieldName():PlacedName {
		var t = current();
		return switch t.token {
			case Dollar(name):
				next();
				{name: "$" + name, pos: t.pos};
			case _: placedIdent();
		};
	}

	function identText():Null<String> return switch current().token {
		case Const(Ident(v)): v;
		case _: null;
	}

	function decl(d:TypeDef, p:Pos):TypeDecl return {definition: d, pos: p};

	function expr(d:ExprDef, p:Pos):Expr return {expr: d, pos: p};

	function accept(t:Token):Null<LexedToken> {
		if (is(t)) return next();
		return null;
	}

	function acceptKwd(k:Keyword):Null<LexedToken> {
		if (switch current().token {
				case Kwd(v): v == k;
				case _: false;
			}) {
			previousKwd = k;
			return next();
			}
		return null;
	}

	function expect(t:Token):LexedToken {
		var r = accept(t);
		if (r == null) fail("Expected token " + Std.string(t));
		return r;
	}

	function semicolon():LexedToken {
		if (previous().token.match(BrClose)) {
			var token = accept(Semicolon);
			return token == null ? previous() : token;
		}
		return expect(Semicolon);
	}

	function isTypeGt():Bool return switch current().token {
		case Binop(OpGt | OpGte | OpShr | OpUShr | OpAssignOp(OpShr) | OpAssignOp(OpUShr)): true;
		case _: false;
	};

	function expectTypeGt():LexedToken {
		var token = current();
		return switch token.token {
			case Binop(OpGt): next();
			case Binop(OpGte):
				tokens[index] = {token: Binop(OpAssign), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin + 1, pmax: token.pos.pmax}};
				{token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin, pmax: token.pos.pmin + 1}};
			case Binop(OpShr):
				tokens[index] = {token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin + 1, pmax: token.pos.pmax}};
				{token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin, pmax: token.pos.pmin + 1}};
			case Binop(OpUShr):
				tokens[index] = {token: Binop(OpShr), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin + 1, pmax: token.pos.pmax}};
				{token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin, pmax: token.pos.pmin + 1}};
			case Binop(OpAssignOp(OpShr)):
				tokens[index] = {token: Binop(OpGte), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin + 1, pmax: token.pos.pmax}};
				{token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin, pmax: token.pos.pmin + 1}};
			case Binop(OpAssignOp(OpUShr)):
				tokens[index] = {
					token: Binop(OpAssignOp(OpShr)),
					pos: {
						pfile: token.pos.pfile,
						pmin: token.pos.pmin + 1,
						pmax: token.pos.pmax
					}
				};
				{token: Binop(OpGt), pos: {pfile: token.pos.pfile, pmin: token.pos.pmin, pmax: token.pos.pmin + 1}};
			case _:
				fail("Expected type-parameter close", token.pos);
				null;
		};
	}

	function expectKwd(k:Keyword):LexedToken {
		var r = acceptKwd(k);
		if (r == null) fail("Expected keyword " + Ast.sKeyword(k));
		return r;
	}

	inline function is(t:Token):Bool return Type.enumEq(current().token, t);

	inline function current():LexedToken return tokenAt(index);

	inline function previous():LexedToken return tokenAt(index - 1);

	inline function next():LexedToken return tokenAt(index++);

	static function binop(t:Token):Null<Binop> return switch t {
		case Binop(o): o;
		case Spread: OpInterval;
		case _: null;
	};

	// Pratt levels (higher binds tighter) mirror haxe/src/syntax/parser.ml's
	// precedence order: bitwise operators bind tighter than equality/comparison
	// operators, so `n & mask != 0` parses as `(n & mask) != 0`. Deliberate
	// deviations retained from the previous table: OpOr/OpXor/OpAnd keep
	// distinct C-like levels instead of upstream's shared level, OpMod stays
	// grouped with OpMult/OpDiv, and OpIn stays loosest to preserve the
	// existing for-loop `it` shape consumed below.
	static function precedence(o:Binop):Int return switch o {
		case OpInterval | OpArrow | OpIn: 0;
		case OpAssign | OpAssignOp(_): 1;
		case OpBoolOr: 2;
		case OpBoolAnd: 3;
		case OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte: 4;
		case OpNullCoal: 5;
		case OpOr: 6;
		case OpXor: 7;
		case OpAnd: 8;
		case OpShl | OpShr | OpUShr: 9;
		case OpAdd | OpSub: 10;
		case OpMult | OpDiv | OpMod: 11;
		case _: -1;
	};

	static function hasAccess(a:Array<PlacedAccess>, v:Access):Bool {
		for (x in a) if (x.access == v) return true;
		return false;
	}

	static function union(a:Pos, b:Pos):Pos return Ast.punion(a, b);

	function fail(message:String, ?pos:Pos):Void throw new GrammarError(message, pos == null ? current().pos : pos);
}

class GrammarError {
	public final message:String;
	public final pos:Pos;

	public function new(message, pos) {
		this.message = message;
		this.pos = pos;
	}
}

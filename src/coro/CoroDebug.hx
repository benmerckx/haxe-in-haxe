package coro;

import context.DotGraph;
import core.StringHelper;
import coro.CoroTypes;
import coro.CoroFunctions.*;

// haxe/src/coro/coroDebug.ml — mechanical draft; not compile-validated.
class CoroDebug {
	public static function createDotgraph(path:Array<String>, root:CoroBlock):Void {
		Sys.println(path.join("."));
		var graph = DotGraph.startGraph(path, ".coro");
		var ch = graph.channel;
		var pctx = core.TPrinting.printContext();
		function st(t:core.TType.T):String return core.TPrinting.sType(pctx, t);
		function se(e:core.TType.TExpr):String return core.TPrinting.sExprPretty(true, "", false, st, e);
		var edges:Array<{
			from:Int,
			to:Int,
			label:String,
			tree:Bool
		}> = [];
		function block(cb:CoroBlock):Void {
			inline function edge(label:String, target:CoroBlock):Void {
				block(target);
				edges.push({
					from: cb.cbId,
					to: target.cbId,
					label: label,
					tree: true
				});
			}
			inline function maybe(label:String, target:Null<CoroBlock>):Void if (target != null) edge(label, target);
			var s = cb.cbEl.map(se).join("\n");
			var flags = hasBlockFlag(cb, CbResumeState) ? " resume" : hasBlockFlag(cb, CbSuspendState) ? " suspend" : "";
			s = '(${cb.cbId}$flags)' + (s == "" ? "" : "\n" + s);
			var next:Null<String> = switch cb.cbNext {
				case NextUnknown: null;
				case NextBreak(n):
					edges.push({
						from: cb.cbId,
						to: n.cbId,
						label: "goto",
						tree: false
					});
					"break";
				case NextContinue(n):
					edges.push({
						from: cb.cbId,
						to: n.cbId,
						label: "goto",
						tree: false
					});
					"continue";
				case NextReturnVoid: "return";
				case NextReturn(e): "return " + se(e);
				case NextThrow(e): "throw " + se(e);
				case NextIfThen(e, a, n):
					edge("next", n);
					edge("then", a);
					"if " + se(e);
				case NextIfThenElse(e, a, b, n):
					maybe("next", n);
					edge("then", a);
					edge("else", b);
					"if " + se(e);
				case NextSwitch(sw, n):
					maybe("next", n);
					for (c in sw.csCases) edge(c.el.map(se).join(" | "), c.cb);
					maybe("default", sw.csDefault);
					"switch " + se(sw.csSubject);
				case NextWhile(e, b, n):
					maybe("next", n);
					edge("body", b);
					"while " + se(e);
				case NextTry(b, c, n):
					maybe("next", n);
					edge("try", b);
					edges.push({
						from: b.cbId,
						to: c.ccCb.cbId,
						label: "catch",
						tree: true
					});
					ch.writeString('n${c.ccCb.cbId} [shape=box,label="(${c.ccCb.cbId})"];\n');
					for (ca in c.ccCatches) {
						block(ca.cb);
						edges.push({
							from: c.ccCb.cbId,
							to: ca.cb.cbId,
							label: st(ca.v.vType),
							tree: true
						});
					}
					null;
				case NextSuspend(s, n):
					maybe("next", n);
					se(s.csFun) + "(" + s.csArgs.map(se).join(", ") + ")";
				case NextFallThrough(n):
					edges.push({
						from: cb.cbId,
						to: n.cbId,
						label: "fall-through",
						tree: false
					});
					null;
				case NextGoto(n):
					edges.push({
						from: cb.cbId,
						to: n.cbId,
						label: "goto",
						tree: false
					});
					null;
			};
			if (next != null) s = s == "" ? next : s + "\n" + next;
			ch.writeString('n${cb.cbId} [shape=box,label="${StringHelper.sEscape(s)}"];\n');
		}
		block(root);
		for (e in edges) {
			var style = e.tree ? 'style="solid",color="black"' : 'style="dashed", color="lightgray"';
			ch.writeString('n${e.from} -> n${e.to}[$style label="${StringHelper.sEscape(e.label)}"];\n');
		}
		graph.close();
	}
}

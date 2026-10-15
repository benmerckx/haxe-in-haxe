// The math functions' speed (hxmc/test/Libm.hx --bench): each over the
// same inputs, the time per call in nanoseconds (the best of five runs).
class Bench {
	// the best of five runs
	static function time(name:String, n:Int, f:Void->Float) {
		var dt = 1e9, s = 0.0;
		for (k in 0...5) {
			var t0 = haxe.Timer.stamp();
			s = f();
			var d = haxe.Timer.stamp() - t0;
			if (d < dt) dt = d;
		}
		Sys.println('${StringTools.rpad(name, " ", 6)} ${StringTools.lpad(Std.string(Math.round(dt / n * 1e10) / 10), " ", 7)} ns  (checksum $s)');
	}

	static function main() {
		var n = Std.parseInt(Sys.args()[0] ?? "2000000");
		var xs = [for (i in 0...n) (i * 0.6180339887498949) % 20 - 10]; // [-10, 10)
		var us = [for (i in 0...n) (i * 0.6180339887498949) % 2 - 1]; // [-1, 1)
		var ps = [for (i in 0...n) (i * 0.6180339887498949) % 100 + 1e-3]; // (0, 100)
		time("sin", n, () -> {var s = 0.0; for (x in xs) s += Math.sin(x); s;});
		time("cos", n, () -> {var s = 0.0; for (x in xs) s += Math.cos(x); s;});
		time("tan", n, () -> {var s = 0.0; for (x in xs) s += Math.tan(x); s;});
		time("asin", n, () -> {var s = 0.0; for (x in us) s += Math.asin(x); s;});
		time("acos", n, () -> {var s = 0.0; for (x in us) s += Math.acos(x); s;});
		time("atan", n, () -> {var s = 0.0; for (x in xs) s += Math.atan(x); s;});
		time("atan2", n, () -> {var s = 0.0; for (i in 0...n) s += Math.atan2(xs[i], us[i]); s;});
		time("exp", n, () -> {var s = 0.0; for (x in xs) s += Math.exp(x); s;});
		time("log", n, () -> {var s = 0.0; for (x in ps) s += Math.log(x); s;});
		time("pow", n, () -> {var s = 0.0; for (i in 0...n) s += Math.pow(ps[i], xs[i]); s;});
		time("fmod", n, () -> {var s = 0.0; for (i in 0...n) s += ps[i] % (us[i] + 2); s;});
	}
}

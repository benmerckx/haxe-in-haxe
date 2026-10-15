import haxe.io.Bytes;

// The checked side of hxmc/test/Libm.hx: reads the records of ref.c on
// stdin, computes each result with Math (hxmc's LibM when built by hxmc)
// and prints per function how many differ from the reference (NaNs
// compare equal whatever their sign and payload: programs print them
// alike). Differences of more than one ulp are counted apart (CORE-MATH's
// functions are correctly rounded, so any difference from glibc's
// correctly rounded results is one ulp).
//   ref 100000 | probe [--examples n] [records file (else stdin)]
class Probe {
	static var NAMES = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "pow", "fmod", "floor", "ceil", "fma", "fmahw"];

	static function bits(x:Float):haxe.Int64
		return haxe.Int64.make(haxe.io.FPHelper.doubleHigh(x), haxe.io.FPHelper.doubleLow(x));

	static function hex(x:Float):String {
		var b = bits(x);
		return StringTools.hex(b.high, 8) + StringTools.hex(b.low, 8);
	}

	// the distance in ulps of two finite doubles of the same sign (capped)
	static function ulps(a:Float, b:Float):Float {
		if ((a < 0) != (b < 0)) return 1e9;
		var d = bits(a) - bits(b);
		if (d < 0) d = -d;
		return d.high != 0 ? 1e9 : (d.low < 0 ? 1e9 : d.low);
	}

	static function compute(f:Int, x:Float, y:Float, z:Float):Float {
		return switch f {
			case 0: Math.sin(x);
			case 1: Math.cos(x);
			case 2: Math.tan(x);
			case 3: Math.asin(x);
			case 4: Math.acos(x);
			case 5: Math.atan(x);
			case 6: Math.atan2(x, y);
			case 7: Math.exp(x);
			case 8: Math.log(x);
			case 9: Math.pow(x, y);
			case 10: x % y;
			case 11: Math.ffloor(x);
			case 12: Math.fceil(x);
			case 13: hxmc.rt.LibM.fmaSoft(x, y, z);
			case 14: hxmc.rt.LibM.fma(x, y, z);
			case _: throw "bad function " + f;
		}
	}

	static function main() {
		var args = Sys.args();
		var examples = 5;
		var file = null;
		var i = 0;
		while (i < args.length) {
			if (args[i] == "--examples") examples = Std.parseInt(args[++i]);
			else file = args[i];
			i++;
		}
		var n = NAMES.length;
		var total = [for (_ in 0...n) 0], diff = [for (_ in 0...n) 0], far = [for (_ in 0...n) 0];
		var shown = [for (_ in 0...n) 0];
		var input:haxe.io.Input = file == null ? Sys.stdin() : sys.io.File.read(file);
		var size = 40 * 4096;
		var buf = Bytes.alloc(size);
		var have = 0;
		var t0 = haxe.Timer.stamp();
		while (true) {
			var got = try input.readBytes(buf, have, size - have) catch (_:haxe.io.Eof) 0;
			if (got <= 0 && have < 40) break;
			have += got;
			var p = 0;
			while (p + 40 <= have) {
				var f = buf.getInt32(p);
				var x = buf.getDouble(p + 8), y = buf.getDouble(p + 16), z = buf.getDouble(p + 24), r = buf.getDouble(p + 32);
				p += 40;
				// fma records check both the software fma and the processor's
				if (f == 13) {
					var hw = compute(14, x, y, z);
					total[14]++;
					if (!(Math.isNaN(r) ? Math.isNaN(hw) : bits(r) == bits(hw))) {
						diff[14]++;
						far[14]++;
					}
				}
				var ours = compute(f, x, y, z);
				total[f]++;
				var same = Math.isNaN(r) ? Math.isNaN(ours) : bits(r) == bits(ours);
				if (!same) {
					diff[f]++;
					var far1 = Math.isNaN(r) || Math.isNaN(ours) || ulps(r, ours) > 1;
					if (far1) far[f]++;
					if (shown[f] < examples || (far1 && shown[f] < examples + 20)) {
						shown[f]++;
						var arg = f == 13 ? '${hex(x)}, ${hex(y)}, ${hex(z)}' : f == 6 || f == 9 || f == 10 ? '${hex(x)}, ${hex(y)}' : hex(x);
						Sys.println('${NAMES[f]}($arg) = ${hex(ours)} (${ours}), reference ${hex(r)} (${r})${far1 ? " FAR" : ""}');
					}
				}
			}
			buf.blit(0, buf, p, have - p);
			have -= p;
			if (got <= 0) break;
		}
		var bad = 0;
		for (f in 0...n) {
			if (total[f] == 0) continue;
			var rate = total[f] == 0 ? 0.0 : diff[f] / total[f];
			Sys.println('${StringTools.rpad(NAMES[f], " ", 6)} ${StringTools.lpad(Std.string(diff[f]), " ", 9)} / ${StringTools.lpad(Std.string(total[f]), " ", 9)} differ (${Math.round(rate * 1e8) / 1e6} %), ${far[f]} by more than one ulp');
			bad += far[f];
		}
		Sys.println('probe: ${Math.round((haxe.Timer.stamp() - t0) * 100) / 100} s');
		Sys.exit(bad > 0 ? 1 : 0);
	}
}

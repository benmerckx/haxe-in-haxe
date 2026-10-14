package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;
import hxmc.Abi;

// hxmc's static linker for Linux: objects (the program's, the runtime
// object of tools/mkrt.sh with the C library) -> a static ELF executable
// (no dynamic section, no interpreter): symbol resolution, layout in three
// loadable segments (read-only with the headers, code, data with TLS),
// relocation, the symbols a C toolchain's linker defines (__init_array_*,
// ...).
class Link {
	static inline var BASE = 0x400000;

	var objs:Array<Obj>;
	// the segment alignment: 4K on x86-64, 64K on aarch64 (the largest page size kernels use)
	var PAGE:Int;
	var arm:Bool;
	var globals = new Map<String, Symbol>();
	var addr = new Map<Section, Int>(); // section -> address
	var symAddr:Symbol->Int;
	var tlsStart = 0;
	var tlsSize = 0;
	var tlsAlign = 1;

	public function new(objs:Array<Obj>, abi:Abi) {
		this.objs = objs;
		this.arm = abi.arm;
		PAGE = abi.segAlign;
		// port: position-independent output (PIE, shared libraries: dynamic
		// relocations, GOT/PLT, DT_NEEDED, a TLS model other than local-exec)
		// is not written yet
		if (abi.reloc != Static || abi.output != Executable) throw "hxmc: " + abi.reloc + " " + abi.output + " output is not supported yet";
	}

	// ---- symbols

	function resolve() {
		for (o in objs)
			for (s in o.symbols) {
				if (!s.global || (s.section == null && !s.abs)) continue;
				var prev = globals.get(s.name);
				if (prev == null || prev.weak && !s.weak) globals.set(s.name, s);
				else if (!prev.weak && !s.weak) throw 'hxmc: link: ${s.name} defined twice';
			}
	}

	// the definition a reference resolves to (null: undefined)
	function target(s:Symbol):Null<Symbol> {
		if (s.section != null || s.abs) return s;
		return globals.get(s.name);
	}

	// ---- layout

	// a slot per symbol reached through the global offset table (aarch64
	// GOT relocations of the C library): its address, filled by a relocation
	var got:Null<Section>;
	var gotSlot = new Map<Symbol, Int>();

	// ---- dead code: the sections of `collect` (the runtime object) that
	// nothing reaches from the entry, the other objects and the
	// initializers are left out (the runtime is compiled with a section per
	// function and per datum)
	public var collect:Null<Obj>;
	// sections of any object kept only when reached (the runtime's Haxe functions)
	public static inline var GC_PREFIX = ".text.gc.";
	var live:Null<Map<Section, Bool>>;

	function gc(entry:String) {
		if (collect == null) return;
		live = new Map();
		var work:Array<Section> = [];
		function mark(s:Section) {
			if (s != null && !live.exists(s)) {
				live.set(s, true);
				work.push(s);
			}
		}
		// (the frame descriptors keep nothing alive: frameTable drops the
		// descriptors of the functions left out)
		var frames:Null<Section> = null;
		for (o in objs)
			for (s in o.sections)
				if (s.name == StackMaps.TABLE) frames = s;
				else if ((o != collect && !StringTools.startsWith(s.name, GC_PREFIX)) || s.kind == InitArray || s.kind == FiniArray) mark(s);
		var e = globals.get(entry);
		if (e != null) mark(e.section);
		while (work.length > 0) {
			var s = work.pop();
			if (s == frames) continue; // (the runtime refers to the table)
			for (r in s.relocs) {
				var t = target(r.sym);
				if (t != null && t.section != null) mark(t.section);
			}
		}
		if (frames != null) {
			live.set(frames, true);
			frameTable(frames);
		}
	}

	// keeps the descriptors of the live functions (one relocation each, at
	// its start: StackMaps.descriptor) and moves hxmc_frames_end
	function frameTable(sec:Section) {
		var out = new Buf(sec.buf.len);
		var relocs = [];
		for (r in sec.relocs) {
			var t = target(r.sym);
			if (t == null || t.section == null || !live.exists(t.section)) continue;
			var at = out.len;
			for (k in 0...StackMaps.DESC_SIZE >> 2)
				out.u32(sec.buf.get32(r.offset + 4 * k));
			relocs.push(new Reloc(at, r.kind, r.sym, r.addend));
		}
		sec.buf = out;
		sec.relocs = relocs;
		for (o in objs)
			for (s in o.symbols)
				if (s.name == StackMaps.END && s.section == sec) s.offset = out.len;
	}

	inline function isLive(s:Section):Bool
		return live == null || live.exists(s);

	function makeGot() {
		for (o in objs)
			for (s in o.sections)
				if (isLive(s))
				for (r in s.relocs)
					if (r.kind == RA64GotPage21 || r.kind == RA64GotLo12 || r.kind == RGotPcRel32) {
						var t = target(r.sym);
						var key = t != null ? t : r.sym;
						if (!gotSlot.exists(key)) {
							if (got == null) got = new Section(".got", Data, 8);
							gotSlot.set(key, got.buf.len);
							got.relocs.push(new Reloc(got.buf.len, RAbs64, key, 0));
							got.buf.u64(0, 0);
						}
					}
		if (got != null) {
			if (live != null) live.set(got, true);
			var o = new Obj();
			o.sections.push(got);
			objs.push(o);
		}
	}

	function gotAddr(s:Symbol):Int {
		var t = target(s);
		return addr.get(got) + gotSlot.get(t != null ? t : s);
	}

	public var symbols = true; // write a symbol table of the code (profilers, debuggers)

	public function link(entry:String):Bytes {
		resolve();
		gc(entry);
		makeGot();
		// linker-defined symbols, defined below once the layout is known
		var defined = new Map<String, Int>();
		var all:Array<Section> = [];
		for (o in objs)
			for (s in o.sections)
				if (isLive(s)) all.push(s);
		var ro = [for (s in all) if (s.kind == RoData) s];
		var text = [for (s in all) if (s.kind == Text) s];
		var tdata = [for (s in all) if (s.kind == Tdata) s];
		var tbss = [for (s in all) if (s.kind == Tbss) s];
		var init = [for (s in all) if (s.kind == InitArray) s];
		var fini = [for (s in all) if (s.kind == FiniArray) s];
		var data = [for (s in all) if (s.kind == Data) s];
		var bss = [for (s in all) if (s.kind == Bss) s];
		var nph = 5; // LOAD r, LOAD rx, LOAD rw, TLS, GNU_STACK
		var headers = 64 + 56 * nph;
		var pos = BASE + headers;
		function place(list:Array<Section>) {
			for (s in list) {
				pos = align(pos, s.align);
				addr.set(s, pos);
				pos += s.size();
			}
		}
		// segment 1: headers + read-only data
		place(ro);
		var roEnd = pos;
		// segment 2: code (file offset = address - BASE: one image)
		pos = align(pos, PAGE);
		var textStart = pos;
		place(text);
		var textEnd = pos;
		// segment 3: TLS image, init/fini arrays, data, bss
		pos = align(pos, PAGE);
		var dataStart = pos;
		place(tdata);
		tlsStart = dataStart;
		var tdataEnd = pos;
		// .tbss takes no room in the segment
		var tpos = pos;
		for (s in tbss) {
			tpos = align(tpos, s.align);
			addr.set(s, tpos);
			tpos += s.size();
		}
		for (s in tdata.concat(tbss))
			if (s.align > tlsAlign) tlsAlign = s.align;
		tlsSize = tpos - tlsStart;
		pos = align(pos, 8);
		defined.set("__init_array_start", pos);
		place(init);
		defined.set("__init_array_end", pos);
		defined.set("__fini_array_start", pos);
		place(fini);
		defined.set("__fini_array_end", pos);
		place(data);
		var fileEnd = pos;
		place(bss);
		var dataEnd = pos;
		defined.set("_end", dataEnd);
		defined.set("end", dataEnd);
		defined.set("_DYNAMIC", 0);
		defined.set("__ehdr_start", BASE);
		symAddr = function(s:Symbol):Int {
			var t = target(s);
			if (t == null) {
				var d = defined.get(s.name);
				if (d != null) return d;
				if (s.weak) return 0;
				throw 'hxmc: link: undefined symbol ${s.name}';
			}
			if (t.abs) return t.offset;
			return addr.get(t.section) + t.offset;
		};
		// relocations
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss) apply(s);
		// the image
		var out = new Buf(fileEnd - BASE + 4096);
		out.zeros(fileEnd - BASE);
		for (s in all)
			if (s.kind != Bss && s.kind != Tbss) out.b.blit(addr.get(s) - BASE, s.buf.b, 0, s.buf.len);
		// ELF header
		var e = BASE + 0;
		var h = new Buf(64);
		h.u32(0x464c457f);
		h.u8(2);
		h.u8(1);
		h.u8(1);
		h.zeros(9);
		h.u16(2); // ET_EXEC
		h.u16(arm ? 183 : 62);
		h.u32(1);
		h.i64(symAddr(entrySym(entry)));
		h.i64(64); // phoff
		var shoff = symbols ? symbolTable(out, all, textStart, textEnd) : 0;
		h.i64(shoff); // shoff
		h.u32(0);
		h.u16(64);
		h.u16(56);
		h.u16(nph);
		h.u16(64);
		h.u16(symbols ? 5 : 0);
		h.u16(symbols ? 4 : 0);
		// program headers
		function ph(type:Int, flags:Int, off:Int, vaddr:Int, filesz:Int, memsz:Int, al:Int) {
			h.u32(type);
			h.u32(flags);
			h.i64(off);
			h.i64(vaddr);
			h.i64(vaddr);
			h.i64(filesz);
			h.i64(memsz);
			h.i64(al);
		}
		ph(1, 4, 0, BASE, roEnd - BASE, roEnd - BASE, PAGE);
		ph(1, 5, textStart - BASE, textStart, textEnd - textStart, textEnd - textStart, PAGE);
		ph(1, 6, dataStart - BASE, dataStart, fileEnd - dataStart, dataEnd - dataStart, PAGE);
		ph(7, 4, tlsStart - BASE, tlsStart, tdataEnd - tlsStart, tlsSize, tlsAlign);
		ph(0x6474e551, 6, 0, 0, 0, 0, 16);
		out.b.blit(0, h.b, 0, h.len);
		return out.toBytes();
	}

	// appends .symtab (the symbols of code), .strtab, .shstrtab and the
	// section headers (null, .text, .symtab, .strtab, .shstrtab) to the
	// image; returns the offset of the headers. Nothing loads them.
	function symbolTable(out:Buf, all:Array<Section>, textStart:Int, textEnd:Int):Int {
		var strtab = new Buf(1 << 16);
		strtab.u8(0);
		var symtab = new Buf(1 << 16);
		symtab.zeros(24);
		var locals = new Buf(1 << 16), globals = new Buf(1 << 16);
		var nlocal = 1, nglobal = 0;
		for (o in objs)
			for (s in o.symbols) {
				var sec = s.section;
				if (sec == null || sec.kind != Text || !addr.exists(sec) || s.abs || s.name.length == 0 || StringTools.startsWith(s.name, ".L")) continue;
				var b = s.global ? globals : locals;
				if (s.global) nglobal++ else nlocal++;
				b.u32(strtab.len);
				strtab.str(s.name);
				strtab.u8(0);
				b.u8((s.global ? 0x10 : 0) | 2); // STT_FUNC
				b.u8(0);
				b.u16(1); // .text
				b.i64(addr.get(sec) + s.offset);
				b.i64(s.size);
			}
		symtab.buf(locals);
		symtab.buf(globals);
		var shstr = new Buf(64);
		shstr.u8(0);
		var names = [];
		for (n in [".text", ".symtab", ".strtab", ".shstrtab"]) {
			names.push(shstr.len);
			shstr.str(n);
			shstr.u8(0);
		}
		out.align(8);
		var symOff = out.len;
		out.buf(symtab);
		var strOff = out.len;
		out.buf(strtab);
		var shstrOff = out.len;
		out.buf(shstr);
		out.align(8);
		var shoff = out.len;
		function sh(name:Int, type:Int, flags:Int, a:Int, off:Int, size:Int, link:Int, info:Int, al:Int, entsize:Int) {
			out.u32(name);
			out.u32(type);
			out.i64(flags);
			out.i64(a);
			out.i64(off);
			out.i64(size);
			out.u32(link);
			out.u32(info);
			out.i64(al);
			out.i64(entsize);
		}
		sh(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		sh(names[0], 1, 6, textStart, textStart - BASE, textEnd - textStart, 0, 0, 16, 0);
		sh(names[1], 2, 0, 0, symOff, symtab.len, 3, nlocal, 8, 24);
		sh(names[2], 3, 0, 0, strOff, strtab.len, 0, 0, 1, 0);
		sh(names[3], 3, 0, 0, shstrOff, shstr.len, 0, 0, 1, 0);
		return shoff;
	}

	function entrySym(name:String):Symbol {
		var s = globals.get(name);
		if (s == null) throw 'hxmc: link: no entry point $name';
		return s;
	}

	static inline function align(v:Int, a:Int):Int
		return a <= 1 ? v : (v + a - 1) & ~(a - 1);

	// the thread-pointer-relative offset of a TLS symbol (local-exec):
	// x86-64 (variant II) below the thread pointer, aarch64 (variant I) above
	// the 16-byte control block
	function tpoff(a:Int):Int {
		if (arm) return align(16, tlsAlign) + (a - tlsStart);
		return (a - tlsStart) - align(tlsSize, tlsAlign);
	}

	static function imm12(buf:Buf, at:Int, v:Int)
		buf.set32(at, (buf.get32(at) & ~(0xfff << 10)) | ((v & 0xfff) << 10));

	static function adrp(buf:Buf, at:Int, target:Int, p:Int) {
		var imm = ((target & ~0xfff) - (p & ~0xfff)) >> 12;
		var w = buf.get32(at) & ~((3 << 29) | (0x7ffff << 5));
		buf.set32(at, w | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5));
	}

	function apply(s:Section) {
		var base = addr.get(s);
		var buf = s.buf;
		for (r in s.relocs) {
			var S = symAddr(r.sym);
			var A = r.addend;
			var P = base + r.offset;
			switch r.kind {
				case RAbs64:
					var v = S + A;
					buf.set64(r.offset, v, v < 0 ? -1 : 0);
				case RAbs32 | RAbs32S:
					buf.set32(r.offset, S + A);
				case RPc32 | RCall32:
					buf.set32(r.offset, S + A - P);
				case RTpOff32:
					buf.set32(r.offset, tpoff(S) + A);
				case RGotPcRel32:
					buf.set32(r.offset, gotAddr(r.sym) + A - P);
				case RA64AdrPage21:
					adrp(buf, r.offset, S + A, P);
				case RA64GotPage21:
					adrp(buf, r.offset, gotAddr(r.sym), P);
				case RA64AddLo12:
					imm12(buf, r.offset, (S + A) & 0xfff);
				case RA64Ldst8Lo12:
					imm12(buf, r.offset, (S + A) & 0xfff);
				case RA64Ldst16Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 1);
				case RA64Ldst32Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 2);
				case RA64Ldst64Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 3);
				case RA64Ldst128Lo12:
					imm12(buf, r.offset, ((S + A) & 0xfff) >> 4);
				case RA64GotLo12:
					imm12(buf, r.offset, (gotAddr(r.sym) & 0xfff) >> 3);
				case RA64Call26 | RA64Jump26:
					var d = S + A - P;
					if (d >= (1 << 27) || d < -(1 << 27)) throw "hxmc: link: branch out of range to " + r.sym.name;
					buf.set32(r.offset, (buf.get32(r.offset) & 0xfc000000) | ((d >> 2) & 0x3ffffff));
				case RA64TlsLeHi12:
					imm12(buf, r.offset, ((tpoff(S) + A) >> 12) & 0xfff);
				case RA64TlsLeLo12Nc:
					imm12(buf, r.offset, (tpoff(S) + A) & 0xfff);
				case RA64MovwG0Nc:
					buf.set32(r.offset, (buf.get32(r.offset) & ~(0xffff << 5)) | (((S + A) & 0xffff) << 5));
				case RA64MovwG1Nc:
					buf.set32(r.offset, (buf.get32(r.offset) & ~(0xffff << 5)) | ((((S + A) >>> 16) & 0xffff) << 5));
				case _:
					throw "hxmc: link: relocation " + r.kind + " not supported yet";
			}
		}
	}
}

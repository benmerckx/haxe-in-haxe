package core;

import haxe.io.Bytes;

// The reading half of haxe/libs/ziplib/zip.ml (open_in, entries, read_entry,
// close_in), which hxbLib.ml uses. haxe/libs/ is an OCaml dependency rather
// than a module to port, so this reproduces its behaviour with Haxe APIs:
// the central directory is read when the archive is opened, and entries are
// inflated on demand with haxe.zip.Uncompress (raw DEFLATE).

enum CompressionMethod {
	Stored;
	Deflated;
}

@:structInit class ZipEntry {
	public var filename:String;
	public var extra:Bytes;
	public var comment:String;
	public var methd:CompressionMethod;
	public var crc:Int;
	public var uncompressedSize:Int;
	public var compressedSize:Int;
	public var isDirectory:Bool;
	public var fileOffset:Int;
}

class ZipError extends haxe.Exception {
	public function new(file:String, entry:String, message:String) {
		super(file + (entry == "" ? "" : " (" + entry + ")") + ": " + message);
	}
}

class ZipInput {
	public final filename:String;

	final channel:sys.io.FileInput;

	public final entries:Array<ZipEntry>;
	public final comment:String;

	function new(filename:String, channel:sys.io.FileInput, entries:Array<ZipEntry>, comment:String) {
		this.filename = filename;
		this.channel = channel;
		this.entries = entries;
		this.comment = comment;
	}

	static function filenameIsDirectory(name:String):Bool {
		return name.length > 0 && name.charAt(name.length - 1) == "/";
	}

	// read_ecd: locate the end of central directory record from the end of the file.
	static function readEcd(filename:String, ic:sys.io.FileInput):{
		entries:Int,
		size:Int,
		offset:Int,
		comment:String
	} {
		ic.seek(0, SeekEnd);
		var filelen = ic.tell();
		var start = filelen - 22 - 0xFFFF;
		if (start < 0) start = 0;
		ic.seek(start, SeekBegin);
		var buf = ic.read(filelen - start);
		var i = buf.length - 22;
		var found = -1;
		while (i >= 0) {
			if (buf.get(i) == 0x50 && buf.get(i + 1) == 0x4B && buf.get(i + 2) == 5 && buf.get(i + 3) == 6) {
				var commentLen = buf.getUInt16(i + 20);
				if (start + i + 22 + commentLen == filelen) {
					found = i;
					break;
				}
			}
			i--;
		}
		if (found < 0) throw new ZipError(filename, "", "end of central directory not found, not a ZIP file");
		var diskNo = buf.getUInt16(found + 4);
		var cdDiskNo = buf.getUInt16(found + 6);
		var cdEntries = buf.getUInt16(found + 10);
		var cdSize = buf.getInt32(found + 12);
		var cdOffset = buf.getInt32(found + 16);
		var commentLen = buf.getUInt16(found + 20);
		var comment = buf.getString(found + 22, commentLen);
		if (diskNo != 0 || cdDiskNo != 0) throw new ZipError(filename, "", "multi-disk ZIP files not supported");
		return {
			entries: cdEntries,
			size: cdSize,
			offset: cdOffset,
			comment: comment
		};
	}

	static function readCd(filename:String, ic:sys.io.FileInput, cdEntries:Int, cdOffset:Int, cdSize:Int):Array<ZipEntry> {
		ic.seek(cdOffset, SeekBegin);
		var cd = try ic.read(cdSize) catch (_:haxe.io.Eof) throw new ZipError(filename, "", "end-of-file while reading central directory");
		var pos = 0;
		var e = [];
		while (pos < cdSize) {
			if (pos + 46 > cdSize) throw new ZipError(filename, "", "end-of-file while reading central directory");
			var magic = cd.getInt32(pos);
			var flags = cd.getUInt16(pos + 8);
			var methd = cd.getUInt16(pos + 10);
			var crc = cd.getInt32(pos + 16);
			var comprSize = cd.getInt32(pos + 20);
			var uncomprSize = cd.getInt32(pos + 24);
			var nameLen = cd.getUInt16(pos + 28);
			var extraLen = cd.getUInt16(pos + 30);
			var commentLen = cd.getUInt16(pos + 32);
			var headerOffset = cd.getInt32(pos + 42);
			var name = cd.getString(pos + 46, nameLen);
			var extra = cd.sub(pos + 46 + nameLen, extraLen);
			var comment = cd.getString(pos + 46 + nameLen + extraLen, commentLen);
			pos += 46 + nameLen + extraLen + commentLen;
			if (magic != 0x02014b50) throw new ZipError(filename, name, "wrong file header in central directory");
			if (flags & 1 != 0) throw new ZipError(filename, name, "encrypted entries not supported");
			e.push(({
				filename: name,
				extra: extra,
				comment: comment,
				methd: switch methd {
					case 0: Stored;
					case 8: Deflated;
					case _: throw new ZipError(filename, name, "unknown compression method");
				},
				crc: crc,
				uncompressedSize: uncomprSize,
				compressedSize: comprSize,
				isDirectory: filenameIsDirectory(name),
				fileOffset: headerOffset
			} : ZipEntry));
		}
		if (pos != cdSize || !(cdEntries == 65535 || e.length == cdEntries)) throw "assert false";
		return e;
	}

	public static function openIn(filename:String):ZipInput {
		var ic = sys.io.File.read(filename, true);
		var ecd = readEcd(filename, ic);
		var entries = readCd(filename, ic, ecd.entries, ecd.offset, ecd.size);
		return new ZipInput(filename, ic, entries, ecd.comment);
	}

	public function closeIn():Void {
		channel.close();
	}

	function gotoEntry(e:ZipEntry):Void {
		try {
			channel.seek(e.fileOffset, SeekBegin);
			var header = channel.read(30);
			var magic = header.getInt32(0);
			var filenameLen = header.getUInt16(26);
			var extraLen = header.getUInt16(28);
			if (magic != 0x04034b50) throw new ZipError(filename, e.filename, "wrong local file header");
			channel.seek(e.fileOffset + 30 + filenameLen + extraLen, SeekBegin);
		} catch (_:haxe.io.Eof) {
			throw new ZipError(filename, e.filename, "truncated local file header");
		}
	}

	public function readEntry(e:ZipEntry):Bytes {
		gotoEntry(e);
		switch e.methd {
			case Stored:
				if (e.compressedSize != e.uncompressedSize) throw new ZipError(filename, e.filename, "wrong size for stored entry");
				return channel.read(e.uncompressedSize);
			case Deflated:
				var data = channel.read(e.compressedSize);
				var res = Bytes.alloc(e.uncompressedSize);
				var z = new haxe.zip.Uncompress(-15);
				var r = try z.execute(data, 0, res, 0) catch (_:Dynamic) {
					z.close();
					throw new ZipError(filename, e.filename, "decompression error");
				};
				z.close();
				if (r.write != e.uncompressedSize) throw new ZipError(filename, e.filename,
					"wrong size for deflated entry (not enough data)");
				if (haxe.crypto.Crc32.make(res) != e.crc) throw new ZipError(filename, e.filename, "CRC mismatch");
				return res;
		}
	}
}

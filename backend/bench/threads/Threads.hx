// Checks the hxc sys.thread package (green threads, backend/rt/rt_thread.c):
//   sh backend/build.sh backend/bench/threads Threads && bin/backend/Threads/prog_c
// Prints "ok <name>" per check and "done" at the end; exits 1 on a failure.
import sys.thread.Condition;
import sys.thread.Deque;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Semaphore;
import sys.thread.Thread;
import sys.thread.Tls;

class Threads {
	static var failures = 0;

	static function check(name:String, cond:Bool) {
		if (cond) Sys.println("ok " + name) else {
			Sys.println("FAIL " + name);
			failures++;
		}
	}

	static function main() {
		lock();
		mutex();
		deque();
		semaphore();
		condition();
		tls();
		messages();
		sleep();
		gc();
		preempt();
		stress();
		exceptions();
		sockets();
		process();
		Sys.println(failures == 0 ? "done" : failures + " failures");
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function lock() {
		var l = new Lock();
		var order = [], om = new Mutex();
		for (i in 0...3)
			Thread.create(() -> {
				om.acquire(); // OS threads: concurrent pushes would race
				order.push(i);
				om.release();
				l.release();
			});
		for (_ in 0...3) l.wait();
		order.sort(Reflect.compare);
		check("lock", order.join(",") == "0,1,2");
		var t0 = Sys.time();
		check("lock timeout", !l.wait(0.05) && Sys.time() - t0 >= 0.04);
		l.release();
		check("lock released before", l.wait(0.0));
		var l2 = new Lock();
		Thread.create(() -> {
			Sys.sleep(0.02);
			l2.release();
		});
		check("lock wait with timeout", l2.wait(5.0));
	}

	static function mutex() {
		var m = new Mutex();
		var counter = 0, done = new Lock();
		for (t in 0...4)
			Thread.create(() -> {
				for (i in 0...100) {
					m.acquire();
					var c = counter;
					Sys.sleep(0); // yield while holding the mutex
					counter = c + 1;
					m.release();
				}
				done.release();
			});
		for (_ in 0...4) done.wait();
		check("mutex", counter == 400);
		m.acquire();
		check("mutex reentrant", m.tryAcquire());
		m.release();
		var other = new Lock(), got = true;
		Thread.create(() -> {
			got = m.tryAcquire();
			other.release();
		});
		other.wait();
		check("mutex tryAcquire held elsewhere", !got);
		m.release();
	}

	static function deque() {
		var d = new Deque<Int>(), out = new Deque<Int>();
		Thread.create(() -> {
			while (true) {
				var v = d.pop(true);
				if (v < 0) break;
				out.add(v * 2);
			}
			out.add(-1);
		});
		for (i in 0...5) d.add(i);
		d.add(-1);
		var r = [];
		while (true) {
			var v = out.pop(true);
			if (v < 0) break;
			r.push(v);
		}
		check("deque", r.join(",") == "0,2,4,6,8");
		check("deque non-blocking", d.pop(false) == null);
		d.add(1);
		d.push(2);
		check("deque push", d.pop(false) == 2 && d.pop(false) == 1);
	}

	static function semaphore() {
		// (OS threads run in parallel: n is guarded, and the main thread waits
		// for the three acquisitions instead of sleeping a fixed time)
		var s = new Semaphore(0), n = 0, m = new Mutex(), acquired = new Lock();
		for (i in 0...3)
			Thread.create(() -> {
				s.acquire();
				m.acquire();
				n++;
				m.release();
				acquired.release();
			});
		Sys.sleep(0.01);
		check("semaphore blocks", n == 0);
		for (i in 0...3) s.release();
		var all = true;
		for (i in 0...3) if (!acquired.wait(10)) all = false;
		check("semaphore", all && n == 3);
		check("semaphore tryAcquire", !s.tryAcquire());
		var t0 = Sys.time();
		check("semaphore timeout", !s.tryAcquire(0.05) && Sys.time() - t0 >= 0.04);
		Thread.create(() -> s.release());
		check("semaphore tryAcquire wait", s.tryAcquire(5));
	}

	static function condition() {
		var c = new Condition(), ready = false, seen = false, done = new Lock();
		Thread.create(() -> {
			c.acquire();
			while (!ready) c.wait();
			seen = true;
			c.release();
			done.release();
		});
		Sys.sleep(0.01);
		c.acquire();
		ready = true;
		c.signal();
		c.release();
		done.wait();
		check("condition", seen);
	}

	static function tls() {
		var t = new Tls<String>();
		t.value = "main";
		var other:Null<String> = "unset", l = new Lock();
		Thread.create(() -> {
			other = t.value;
			t.value = "thread";
			l.release();
		});
		l.wait();
		check("tls", other == null && t.value == "main");
	}

	static function messages() {
		var main = Thread.current();
		var t = Thread.create(() -> {
			var m:String = Thread.readMessage(true);
			main.sendMessage(m + "!");
		});
		t.sendMessage("hi");
		check("messages", Thread.readMessage(true) == "hi!");
		check("readMessage non-blocking", Thread.readMessage(false) == null);
		check("current", Thread.current() == main && t != main);
	}

	static function sleep() {
		var log = [];
		var l = new Lock();
		Thread.create(() -> {
			Sys.sleep(0.06);
			log.push("slow");
			l.release();
		});
		Thread.create(() -> {
			Sys.sleep(0.02);
			log.push("fast");
			l.release();
		});
		var t0 = Sys.time();
		l.wait();
		l.wait();
		var dt = Sys.time() - t0;
		check("sleep", log.join(",") == "fast,slow" && dt < 0.5);
	}

	// allocation in several threads: each one's shadow stack holds live objects
	static function gc() {
		var l = new Lock(), results = [];
		for (t in 0...4)
			Thread.create(() -> {
				var keep = [for (i in 0...1000) {id: i, name: "n" + i}];
				for (round in 0...50) {
					var garbage = [for (i in 0...2000) [i, i + 1]];
					Sys.sleep(0);
					if (garbage[1999][1] != 2000) throw "bad";
				}
				var sum = 0;
				for (o in keep) if (o.name == "n" + o.id) sum += o.id;
				results.push(sum);
				l.release();
			});
		for (_ in 0...4) l.wait();
		check("gc", results.length == 4 && results.filter(s -> s == 499500).length == 4);
	}

	// a thread that spins without blocking gives way at minor collections
	static function preempt() {
		var flag = false, keep:Array<Int> = null;
		Thread.create(() -> flag = true);
		var spins = 0;
		while (!flag) keep = [spins++];
		check("preempt at allocation", flag && keep != null);
	}

	// contention with allocation everywhere: threads are switched out at minor
	// collections, also between queueing themselves and parking
	// (run with RT_MINOR_KB=8 to make that frequent)
	static function stress() {
		var m = new Mutex(), q = new Deque<Array<Int>>(), sem = new Semaphore(0), done = new Lock();
		var total = 0, n = 4, per = 3000;
		for (p in 0...n)
			Thread.create(() -> {
				for (i in 0...per) {
					m.acquire();
					var tmp = [for (k in 0...4) k];
					total += tmp.length - 3;
					m.release();
					q.add([i]);
					sem.release();
				}
				done.release();
			});
		var got = 0;
		for (c in 0...2)
			Thread.create(() -> {
				while (true) {
					sem.acquire();
					var v = q.pop(true);
					if (v[0] < 0) break;
					m.acquire(); // two consumers: with OS threads an unguarded ++ loses counts
					got++;
					m.release();
				}
				done.release();
			});
		for (_ in 0...n) done.wait();
		for (c in 0...2) {
			q.add([-1]);
			sem.release();
		}
		for (_ in 0...2) done.wait();
		check("stress", total == n * per && got == n * per);
	}

	static function exceptions() {
		var l = new Lock(), caught = "";
		Thread.create(() -> {
			try {
				Sys.sleep(0.01);
				throw "inner";
			} catch (e:String) {
				caught = e;
			}
			l.release();
		});
		try {
			Sys.sleep(0.02);
			throw "outer";
		} catch (e:String) {
			check("exception main", e == "outer");
		}
		l.wait();
		check("exception thread", caught == "inner");
		var aborted:Null<haxe.Exception> = null;
		var l2 = new Lock();
		Thread.create(() -> throw "boom", {onAbort: e -> aborted = e, onExit: () -> l2.release()});
		l2.wait();
		check("thread abort", aborted != null && aborted.message == "boom");
	}

	static function sockets() {
		var server = new sys.net.Socket();
		server.bind(new sys.net.Host("127.0.0.1"), 0);
		server.listen(4);
		var port = server.host().port;
		var done = new Lock(), got = "";
		Thread.create(() -> {
			var c = server.accept();
			var line = c.input.readLine();
			c.output.writeString(line.toUpperCase() + "\n");
			// a large reply: the writer waits for the reader
			var big = haxe.io.Bytes.alloc(4 << 20);
			big.fill(0, big.length, "x".code);
			c.output.writeFullBytes(big, 0, big.length);
			c.close();
			done.release();
		});
		var ticks = 0, ticking = true;
		Thread.create(() -> while (ticking) {
			ticks++;
			Sys.sleep(0.001);
		});
		var s = new sys.net.Socket();
		s.connect(new sys.net.Host("127.0.0.1"), port);
		Sys.sleep(0.02); // the server thread waits in accept/read meanwhile
		s.output.writeString("hello\n");
		got = s.input.readLine();
		var all = s.input.readAll();
		s.close();
		done.wait();
		ticking = false;
		check("socket echo", got == "HELLO");
		check("socket large read", all.length == 4 << 20);
		check("socket other threads ran", ticks > 0);
		// a non-blocking socket still throws Blocked
		var s2 = new sys.net.Socket();
		s2.connect(new sys.net.Host("127.0.0.1"), port);
		var c2:Null<sys.net.Socket> = null;
		var l = new Lock();
		Thread.create(() -> {
			c2 = server.accept();
			l.release();
		});
		l.wait();
		s2.setBlocking(false);
		var blocked = try {
			s2.input.readByte();
			false;
		} catch (e:haxe.io.Error) e.match(Blocked);
		check("socket non-blocking", blocked);
		var r = sys.net.Socket.select([s2], null, null, 0.05);
		check("select timeout", r.read.length == 0);
		Thread.create(() -> {
			Sys.sleep(0.02);
			c2.output.writeString("z");
		});
		s2.setBlocking(true);
		r = sys.net.Socket.select([s2], null, null, 5);
		check("select ready", r.read.length == 1 && s2.input.readByte() == "z".code);
		s2.close();
		c2.close();
		server.close();
	}

	static function process() {
		var ticks = 0, ticking = true;
		Thread.create(() -> while (ticking) {
			ticks++;
			Sys.sleep(0.001);
		});
		var p = new sys.io.Process("sh", ["-c", "sleep 0.1; echo out"]);
		var line = p.stdout.readLine();
		var code = p.exitCode();
		p.close();
		ticking = false;
		check("process", line == "out" && code == 0);
		check("process other threads ran", ticks > 10);
	}
}

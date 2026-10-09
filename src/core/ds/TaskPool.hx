package core.ds;

import sys.thread.Thread;
import sys.thread.Mutex;
import sys.thread.Lock;

// Runtime substitute for Domainslib.Task, backed by process-wide worker threads
// on HL/C (see ForJob) rather than work-stealing domains. Indexed results and
// propagation of worker exceptions are preserved.
class TaskPool {
	public final workers:Int;

	var closed = false;

	public function new(workers:Int) {
		if (workers < 0) throw new haxe.exceptions.ArgumentException("workers");
		this.workers = workers;
	}

	public static function recommendedDomainCount():Int {
		var count = Sys.getEnv("NUMBER_OF_PROCESSORS");
		if (count == null && Sys.systemName() != "Windows") {
			try {
				var process = new sys.io.Process("getconf", ["_NPROCESSORS_ONLN"]);
				count = process.stdout.readAll().toString();
				process.exitCode();
				process.close();
			} catch (_:Dynamic) {}
		}
		var parsed = count == null ? null : Std.parseInt(StringTools.trim(count));
		return parsed == null || parsed < 1 ? 1 : parsed;
	}

	public function run<A>(f:Void->A):A {
		if (closed) throw new haxe.Exception("Task pool is closed");
		return f();
	}

	public function close():Void {
		closed = true;
	}

	public function parallelFor(first:Int, last:Int, f:Int->Void, chunkSize:Int = 0):Void {
		if (closed) throw new haxe.Exception("Task pool is closed");
		if (last < first) return;
		var count = last - first + 1;
		var threads = Std.int(Math.min(workers, count - 1));
		if (threads == 0) {
			for (i in first...last + 1) f(i);
			return;
		}
		var chunk = chunkSize > 0 ? chunkSize : Std.int(Math.max(1, count / (8 * (threads + 1))));
		var job = new ForJob(first, last, chunk, f);
		#if (hlc || target.name == "hxc")
		ForJob.invite(job, threads);
		#else
		// HashLink JIT: threads stay scoped to the call. With persistent workers it
		// crashed intermittently, most likely through the races in libhl's lazy type
		// initialisation that bench/libhl-allocator.patch fixes for HL/C (the JIT
		// loads the system libhl).
		var spawned = 0;
		try {
			for (_ in 0...threads) {
				Thread.create(function() {
					job.work();
					job.exited.release();
				});
				spawned++;
			}
		} catch (e:Dynamic) {
			job.fail(e);
		}
		#end
		job.work();
		job.finish();
		#if !(hlc || target.name == "hxc")
		for (_ in 0...spawned) job.exited.wait();
		#end
	}
}

/**
	One parallelFor call. Chunks are claimed under the job's mutex by the
	calling thread and by any invited worker; the caller then waits only for
	chunks already in flight, so a nested parallelFor never waits on a ticket
	that a busy worker might not pick up.

	On HL/C, workers are process-wide threads started on first use and kept for later
	calls (Domainslib keeps its domains for the pool's lifetime): starting a
	HashLink thread registers it with the GC and blocks the caller until it
	runs, which dominated the analyzer's many small per-class loops.
**/
private class ForJob {
	static var queue:Null<sys.thread.Deque<ForJob>> = null;
	static var started = 0;
	static final startMutex = new Mutex();

	final mutex = new Mutex();
	final done = new Lock();
	final last:Int;
	final chunk:Int;
	final f:Int->Void;
	var next:Int;
	var inFlight = 0;
	var waiting = false;
	var failed = false;
	var failure:Dynamic = null;

	#if !(hlc || target.name == "hxc")
	public final exited = new Lock();
	#end

	public function new(first:Int, last:Int, chunk:Int, f:Int->Void) {
		this.next = first;
		this.last = last;
		this.chunk = chunk;
		this.f = f;
	}

	public static function invite(job:ForJob, threads:Int):Void {
		startMutex.acquire();
		if (queue == null) queue = new sys.thread.Deque();
		var q = queue;
		try {
			while (started < threads) {
				Thread.create(function() while (true) q.pop(true).work());
				started++;
			}
		} catch (e:Dynamic) {
			startMutex.release();
			throw e;
		}
		startMutex.release();
		for (_ in 0...threads) q.add(job);
	}

	public function work():Void {
		while (true) {
			mutex.acquire();
			var start = next;
			if (failed || start > last) {
				mutex.release();
				return;
			}
			next += chunk;
			inFlight++;
			mutex.release();
			var error = false, e:Dynamic = null;
			try {
				for (i in start...Std.int(Math.min(start + chunk, last + 1))) f(i);
			} catch (x:Dynamic) {
				error = true;
				e = x;
			}
			mutex.acquire();
			if (error && !failed) {
				failed = true;
				failure = e;
			}
			inFlight--;
			var wake = inFlight == 0 && waiting;
			mutex.release();
			if (wake) done.release();
			if (error) return;
		}
	}

	public function fail(e:Dynamic):Void {
		mutex.acquire();
		if (!failed) {
			failed = true;
			failure = e;
		}
		mutex.release();
	}

	public function finish():Void {
		mutex.acquire();
		if (inFlight > 0) {
			waiting = true;
			mutex.release();
			done.wait();
		} else mutex.release();
		if (failed) throw failure;
	}
}

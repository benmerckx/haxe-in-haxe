// The runtime of hxmc's programs: stack maps (hxmc/src/hxmc/StackMaps.hx).
//
// hxmc's functions keep the references they hold across GC points in root
// slots of their frames, null or valid whenever they call. Every function
// that calls has a frame record ([fp]: the caller's frame pointer, [fp + 8]:
// the return address into the caller); those with root slots (and the
// entries, below) have a descriptor, keyed by their code range: where the
// root slots are, relative to the frame pointer. A
// collection walks each thread's frames, from the record of its latest call
// of C that may collect or block (rt_last_fp, rt_last_pc: the calling
// frame's pointer and its function's address) up the chain. A function C
// calls (an entry: main, the program's body, the entries of the exported
// runtime functions) saves the record it found in its frame and restores
// it when it returns; the walk continues from the saved record, past the C
// frames below it, and ends at a null one. The C runtime keeps its own
// references on the shadow stack (RT_ROOT), scanned as before.
#include "rt_gc.h"
#include <stdio.h>
#include <stdlib.h>

RT_TLS void *rt_last_fp, *rt_last_pc;

// a descriptor as the linker leaves it (StackMaps.descriptor)
typedef struct {
	int32_t rel; // the function's address - &rel
	uint32_t len; // code bytes
	uint32_t info; // the slots: n << 18 | -(their offset from fp) / 8 | ENTRY (they are a saved record)
} rt_desc;
#define DESC_ENTRY 0x80000000u
#define DESC_N(i) (((i) >> 18) & 0x1fff)
#define DESC_OFF(i) (-(int32_t)(((i) & 0x3ffff) << 3))

// (weak where the formats allow: a program built by a tool from before stack
// maps has none, and its frames are on the shadow stack)
#ifdef _WIN32
extern const rt_desc hxmc_frames_start[], hxmc_frames_end[];
#else
extern const rt_desc hxmc_frames_start[] __attribute__((weak)), hxmc_frames_end[] __attribute__((weak));
#endif

// the descriptors by address (built at the first walk, and again after a
// registration)
typedef struct {
	uintptr_t start, end;
	int32_t off;
	uint32_t info;
} frame;
static frame *frames;
static size_t nframes;
#define MAX_REGIONS 64
static struct {
	const rt_desc *d;
	size_t n;
} regions[MAX_REGIONS];
static int nregions, built;

// adds the descriptors of a region of code (the program's at the first walk;
// code compiled at run time later). Not while a collection runs.
void rt_frames_register(const void *descs, size_t n) {
	if (nregions == MAX_REGIONS) {
		fprintf(stderr, "hxmc: too many code regions\n");
		abort();
	}
	regions[nregions].d = (const rt_desc *)descs;
	regions[nregions].n = n;
	nregions++;
	built = 0;
}

static int by_start(const void *a, const void *b) {
	uintptr_t x = ((const frame *)a)->start, y = ((const frame *)b)->start;
	return x < y ? -1 : x > y;
}

static void build(void) {
	static int program;
	if (!program) {
		program = 1;
		rt_frames_register(hxmc_frames_start, (size_t)(hxmc_frames_end - hxmc_frames_start));
	}
	size_t n = 0;
	for (int r = 0; r < nregions; r++)
		n += regions[r].n;
	frames = (frame *)realloc(frames, (n ? n : 1) * sizeof(frame));
	nframes = 0;
	for (int r = 0; r < nregions; r++)
		for (size_t i = 0; i < regions[r].n; i++) {
			const rt_desc *d = &regions[r].d[i];
			frame *f = &frames[nframes++];
			f->start = (uintptr_t)&d->rel + (intptr_t)d->rel;
			f->end = f->start + d->len;
			f->off = DESC_OFF(d->info);
			f->info = d->info;
		}
	qsort(frames, nframes, sizeof(frame), by_start);
	built = 1;
}

static const frame *lookup(uintptr_t pc) {
	size_t lo = 0, hi = nframes;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		if (frames[mid].start <= pc) lo = mid + 1;
		else hi = mid;
	}
	if (lo == 0) return NULL;
	const frame *f = &frames[lo - 1];
	return pc < f->end ? f : NULL;
}

// RT_FRAMES_STRICT=1: a frame without a descriptor is an error (programs
// built with HXMC_FRAMES=all describe every frame; others only those with
// references)
static int strict = -1;

// the references of the frames from record (fp, pc) on
void rt_frames_scan(void *fp, void *pc, void *(*fwd)(void *)) {
	if (!built) build();
	if (strict < 0) {
		const char *e = getenv("RT_FRAMES_STRICT");
		strict = e && *e == '1';
	}
	// pc: a function's address (a record) or, up the chain, a return address
	// (looked up one byte back: a call may end its function)
	int ret = 0;
	while (pc) {
		const frame *f = lookup((uintptr_t)pc - ret);
		if (!f) {
			if (strict) {
				fprintf(stderr, "hxmc: stack maps: no descriptor for %p (frame %p)\n", pc, fp);
				abort();
			}
			// a frame without references
			pc = ((void **)fp)[1];
			fp = ((void **)fp)[0];
			ret = 1;
			continue;
		}
		void **slots = (void **)((char *)fp + f->off);
		if (f->info & DESC_ENTRY) {
			fp = slots[0];
			pc = slots[1];
			ret = 0;
			continue;
		}
		uint32_t n = DESC_N(f->info);
		for (uint32_t i = 0; i < n; i++)
			if (slots[i]) slots[i] = fwd(slots[i]);
		pc = ((void **)fp)[1];
		fp = ((void **)fp)[0];
		ret = 1;
	}
}

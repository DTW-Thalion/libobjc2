#include "visibility.h"
#include "objc/runtime.h"
#include "gc_ops.h"
#include "class.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// Alignment of object allocations.  The reference-count word precedes the
// object and thus sits at the head of the block, so aligning the block to a
// cache line puts each object's reference count on its own line: two distinct
// objects are then >= one line apart and never share a line for their counts.
// That eliminates the false-sharing cliff where independent threads
// retaining/releasing adjacent small objects ping-pong a shared line
// (measured: distinct-object retain/release at 4 threads 127ns -> 24ns).
//
// The cost is memory: cache-line alignment rounds every small allocation up to
// the alignment, which roughly DOUBLES the footprint of the smallest objects
// (measured: 32 -> 64 bytes RSS for a 16-byte instance).  It is therefore
// opt-in.  The default preserves the historical alignment (and the calloc
// fast path); build with -DOBJC_ALLOC_ALIGN=64 to trade the memory for the
// multicore retain/release scaling win.
#ifndef OBJC_ALLOC_ALIGN
#  ifdef _WIN32
// Windows malloc doesn't guarantee the 32-byte alignment vector ivars need.
#    define OBJC_ALLOC_ALIGN 32
#  else
#    define OBJC_ALLOC_ALIGN 16
#  endif
#endif

static id allocate_class(Class cls, size_t extraBytes)
{
	size_t size = cls->instance_size + extraBytes + sizeof(intptr_t);
	intptr_t *addr;
#ifdef _WIN32
	addr = _aligned_malloc(size, OBJC_ALLOC_ALIGN);
	memset(addr, 0, size);
#elif OBJC_ALLOC_ALIGN > 16
	// posix_memalign gives the requested alignment without requiring `size` to
	// be a multiple of it (unlike aligned_alloc); it does not zero, so clear
	// explicitly.
	if (posix_memalign((void**)&addr, OBJC_ALLOC_ALIGN, size) != 0)
	{
		return NULL;
	}
	memset(addr, 0, size);
#else
	addr = calloc(1, size);
#endif
	return (id)(addr + 1);
}

static void free_object(id obj)
{
#ifdef _WIN32
	_aligned_free((void*)(((intptr_t*)obj) - 1));
#else
	free((void*)(((intptr_t*)obj) - 1));
#endif
}

static void *alloc(size_t size)
{
	return calloc(1, size);
}

void objc_registerThreadWithCollector(void) {}
void objc_unregisterThreadWithCollector(void) {}
void objc_assertRegisteredThreadWithCollector() {}

PRIVATE struct gc_ops gc_ops_none = 
{
	.allocate_class = allocate_class,
	.free_object    = free_object,
	.malloc         = alloc,
	.free           = free
};
PRIVATE struct gc_ops *gc = &gc_ops_none;

void objc_set_collection_threshold(size_t threshold) {}
void objc_set_collection_ratio(size_t ratio) {}
void objc_collect(unsigned long options) {}
BOOL objc_collectingEnabled(void) { return NO; }
BOOL objc_atomicCompareAndSwapPtr(id predicate, id replacement, volatile id *objectLocation)
{
	return __sync_bool_compare_and_swap(objectLocation, predicate, replacement);
}
BOOL objc_atomicCompareAndSwapPtrBarrier(id predicate, id replacement, volatile id *objectLocation)
{
	return __sync_bool_compare_and_swap(objectLocation, predicate, replacement);
}

BOOL objc_atomicCompareAndSwapGlobal(id predicate, id replacement, volatile id *objectLocation)
{
	return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation);
}
BOOL objc_atomicCompareAndSwapGlobalBarrier(id predicate, id replacement, volatile id *objectLocation)
{
	return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation);
}
BOOL objc_atomicCompareAndSwapInstanceVariable(id predicate, id replacement, volatile id *objectLocation)
{
	return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation);
}
BOOL objc_atomicCompareAndSwapInstanceVariableBarrier(id predicate, id replacement, volatile id *objectLocation)
{
	return objc_atomicCompareAndSwapPtr(predicate, replacement, objectLocation);
}

id objc_assign_strongCast(id val, id *ptr)
{
	*ptr = val;
	return val;
}

id objc_assign_global(id val, id *ptr)
{
	*ptr = val;
	return val;
}

id objc_assign_ivar(id val, id dest, ptrdiff_t offset)
{
	*(id*)((char*)dest+offset) = val;
	return val;
}

void *objc_memmove_collectable(void *dst, const void *src, size_t size)
{
	return memmove(dst, src, size);
}
id objc_read_weak(id *location)
{
	return *location;
}
id objc_assign_weak(id value, id *location)
{
	*location = value;
	return value;
}
id objc_allocate_object(Class cls, int extra)
{
	return class_createInstance(cls, extra);
}

BOOL objc_collecting_enabled(void) { return NO; }
void objc_startCollectorThread(void) {}
void objc_clear_stack(unsigned long options) {}
BOOL objc_is_finalized(void *ptr) { return NO; }
void objc_finalizeOnMainThread(Class cls) {}

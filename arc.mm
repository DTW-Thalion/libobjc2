#define _LIBCPP_NO_EXCEPTIONS 1
#define TSL_NO_EXCEPTIONS 1
// Libc++ < 13 requires this for <vector> to be header only.  It is ignored in
// libc++ >= 14
#define _LIBCPP_DISABLE_EXTERN_TEMPLATE  1
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <atomic>
#include <vector>
#include <tsl/robin_map.h>
#import "lock.h"
#import "objc/runtime.h"
#ifdef EMBEDDED_BLOCKS_RUNTIME
#import "objc/blocks_private.h"
#import "objc/blocks_runtime.h"
#else
#include <Block.h>
#include <Block_private.h>
#endif
#import "nsobject.h"
#import "class.h"
#import "selector.h"
#import "visibility.h"
#import "objc/hooks.h"
#import "objc/objc-arc.h"
#include "objc/message.h"

/**
 * Helper to send a manual message for retain / release.
 * We cannot use [object retain] and friends because recent clang will turn
 * that into a call to `objc_retain`, causing infinite recursion.
 */
#ifdef __GNUSTEP_MSGSEND__
#define ManualRetainReleaseMessage(object, selName, types) \
	((types)objc_msgSend)(object, @selector(selName))
#else
#define ManualRetainReleaseMessage(object, selName, types) \
	((types)(objc_msg_lookup(object, @selector(selName))))(object, @selector(selName))
#endif

extern "C" id (*_objc_weak_load)(id object);

#if defined(_WIN32)
// We're using the Fiber-Local Storage APIs on Windows
// because the TLS APIs won't pass app certification.
// Additionally, the FLS API surface is 1:1 mapped to
// the TLS API surface when fibers are not in use.
#	include "safewindows.h"
#	define arc_tls_store FlsSetValue
#	define arc_tls_load FlsGetValue
#	define TLS_CALLBACK(name) void WINAPI name

typedef DWORD arc_tls_key_t;
typedef void WINAPI(*arc_cleanup_function_t)(void*);
static inline arc_tls_key_t arc_tls_key_create(arc_cleanup_function_t cleanupFunction)
{
	return FlsAlloc(cleanupFunction);
}

#else // if defined(_WIN32)

#	ifndef NO_PTHREADS
#		include <pthread.h>
#		define arc_tls_store pthread_setspecific
#		define arc_tls_load pthread_getspecific
#		define TLS_CALLBACK(name) void name

typedef pthread_key_t arc_tls_key_t;
typedef void (*arc_cleanup_function_t)(void*);
static inline arc_tls_key_t arc_tls_key_create(arc_cleanup_function_t cleanupFunction)
{
	pthread_key_t key;
	pthread_key_create(&key, cleanupFunction);
	return key;
}
#	endif
#endif

#ifdef arc_tls_store
arc_tls_key_t ARCThreadKey;
#endif

#ifndef HAVE_BLOCK_USE_RR2
extern "C"
{
	extern struct objc_class _NSConcreteMallocBlock;
	extern struct objc_class _NSConcreteStackBlock;
	extern struct objc_class _NSConcreteGlobalBlock;
	extern struct objc_class _NSConcreteAutoBlock;
	extern struct objc_class _NSConcreteFinalizingBlock;
}
#endif

@interface NSAutoreleasePool
+ (Class)class;
+ (id)new;
- (void)release;
@end

#define POOL_SIZE (4096 / sizeof(void*) - (2 * sizeof(void*)))
/**
 * Structure used for ARC-managed autorelease pools.  This structure should be
 * exactly one page in size, so that it can be quickly allocated.  This does
 * not correspond directly to an autorelease pool.  The 'pool' returned by
 * objc_autoreleasePoolPush() may be an interior pointer to one of these
 * structures.
 */
struct arc_autorelease_pool
{
	/**
	 * Pointer to the previous autorelease pool structure in the chain.  Set
	 * when pushing a new structure on the stack, popped during cleanup.
	 */
	struct arc_autorelease_pool *previous;
	/**
	 * The current insert point.
	 */
	id *insert;
	/**
	 * The remainder of the page, an array of object pointers.  
	 */
	id pool[POOL_SIZE];
};

struct arc_tls
{
	struct arc_autorelease_pool *pool;
	id returnRetained;
};

/**
 * Type-safe wrapper around calloc.
 */
template<typename T>
static inline T* new_zeroed()
{
	return static_cast<T*>(calloc(1, sizeof(T)));
}

static inline struct arc_tls* getARCThreadData(void)
{
#ifndef arc_tls_store
	return NULL;
#else // !defined arc_tls_store
	auto tls = static_cast<struct arc_tls*>(arc_tls_load(ARCThreadKey));
	if (NULL == tls)
	{
		tls = new_zeroed<struct arc_tls>();
		arc_tls_store(ARCThreadKey, tls);
	}
	return tls;
#endif
}
static inline void release(id obj);

/**
 * Empties objects from the autorelease pool, stating at the head of the list
 * specified by pool and continuing until it reaches the stop point.  If the stop
 * point is NULL then all pools are cleared.
 */
static void emptyPool(struct arc_tls *tls, void *stopAt)
{
	/* Clear all pools by default. */
	struct arc_autorelease_pool *stopPool = NULL;
	void *oldPool;

	/* Are we clearing up to a given object? */
	if (stopAt != NULL)
	{
		stopPool = tls->pool;

		/* Find pool in which object to stop at is located. */
		while (stopPool != NULL)
		{
			if (stopAt >= (void *)stopPool->pool &&
			    stopAt < (void *)&stopPool->pool[POOL_SIZE])
			{
				break;
			}

			stopPool = stopPool->previous;
		}

		/* Invalid pointer, quit. */
		if (stopPool == NULL)
		{
			return;
		}
	}

	do
	{
		/* Clear all pools up to the stop pool. */
		while (tls->pool != stopPool)
		{
			while (tls->pool->insert > tls->pool->pool)
			{
				--tls->pool->insert;
				release(*tls->pool->insert);
			}

			oldPool = tls->pool;
			tls->pool = tls->pool->previous;
			free(oldPool);
		}

		/* If we cleared them all, quit. */
		if (tls->pool == NULL)
		{
			return;
		}

		/*
		 * Release objects down to the stopping point. If a new pool is
		 * pushed, never release below the pool's base.
		 */
		while (tls->pool->insert > (id *)stopAt &&
		       tls->pool->insert > tls->pool->pool)
		{
			--tls->pool->insert;
			release(*tls->pool->insert);
		}

	/* Be sure that releasing objects did not push any new pools. */
	} while (tls->pool != stopPool);
	/* fprintf(stderr, "New insert: %p.  Stop: %p\n", tls->pool->insert, stop); */
}

#ifdef arc_tls_store
static TLS_CALLBACK(cleanupPools)(struct arc_tls* tls)
{
	if (tls->returnRetained)
	{
		release(tls->returnRetained);
		tls->returnRetained = nil;
	}
	if (NULL != tls->pool)
	{
		emptyPool(tls, NULL);
		assert(NULL == tls->pool);
	}
	if (tls->returnRetained)
	{
		cleanupPools(tls);
	}
	free(tls);
}
#endif


static Class AutoreleasePool;
static IMP NewAutoreleasePool;
static IMP DeleteAutoreleasePool;
static IMP AutoreleaseAdd;

static BOOL useARCAutoreleasePool;

static const long refcount_shift = 1;
/**
 * We use the top bit of the reference count to indicate whether an object has
 * ever had a weak reference taken.  This lets us avoid acquiring the weak
 * table lock for most objects on deallocation.
 */
static const size_t weak_mask = ((size_t)1)<<((sizeof(size_t)*8)-refcount_shift);
/**
 * All of the bits other than the top bit are the real reference count.
 */
static const size_t refcount_mask = ~weak_mask;
static const size_t refcount_max = refcount_mask - 1;

extern "C" OBJC_PUBLIC size_t object_getRetainCount_np(id obj)
{
	auto *refCount = reinterpret_cast<std::atomic<uintptr_t>*>(obj) - 1;
	uintptr_t refCountVal = refCount->load(std::memory_order_relaxed);
	size_t realCount = refCountVal & refcount_mask;
	return realCount == refcount_mask ? 0 : realCount + 1;
}

static id retain_fast(id obj, BOOL isWeak)
{
	auto *refCount = reinterpret_cast<std::atomic<uintptr_t>*>(obj) - 1;
	uintptr_t refCountVal = refCount->load(std::memory_order_relaxed);
	for (;;)
	{
		size_t realCount = refCountVal & refcount_mask;
		// If this object's reference count is already less than 0, then
		// this is a spurious retain.  This can happen when one thread is
		// attempting to acquire a strong reference from a weak reference
		// and the other thread is attempting to destroy it.  The
		// deallocating thread will decrement the reference count with no
		// locks held and will then acquire the weak ref table lock and
		// attempt to zero the weak references.  The caller of this will be
		// `objc_loadWeakRetained`, which will also hold the lock.  If the
		// serialisation is such that the locked retain happens after the
		// decrement, then we return nil here so that the weak-to-strong
		// transition doesn't happen and the object is actually destroyed.
		// If the serialisation happens the other way, then the locked
		// check of the reference count will happen after we've referenced
		// this and we don't zero the references or deallocate.
		if (realCount == refcount_mask)
		{
			return isWeak ? nil : obj;
		}
		// If the reference count is saturated, don't increment it.
		if (realCount == refcount_max)
		{
			return obj;
		}
		realCount++;
		realCount |= refCountVal & weak_mask;
		uintptr_t updated = (uintptr_t)realCount;
		// Acquire/release on the exchange so reference-count updates are
		// ordered against each other on weakly-ordered targets.  On a failed
		// exchange refCountVal is refreshed with the current value.
		if (refCount->compare_exchange_weak(refCountVal, updated,
		                                    std::memory_order_acq_rel,
		                                    std::memory_order_acquire))
		{
			return obj;
		}
	}
}

extern "C" OBJC_PUBLIC id objc_retain_fast_np(id obj)
{
	return retain_fast(obj, NO);
}

__attribute__((always_inline))
static inline BOOL isPersistentObject(id obj)
{
	// No reference count manipulations on nil objects.
	if (obj == nil)
	{
		return YES;
	}
	// Small objects are never accessibly by reference
	if (isSmallObject(obj))
	{
		return YES;
	}
	// Persistent objects are persistent.  Safe to access isa directly here
	// because we've already handled the small object case separately.
	return objc_test_class_flag(obj->isa, objc_class_flag_permanent_instances);
}

static inline id retain(id obj, BOOL isWeak)
{
	if (isPersistentObject(obj)) { return obj; }
	Class cls = obj->isa;
	if (UNLIKELY(objc_test_class_flag(cls, objc_class_flag_is_block)))
	{
		return Block_copy(obj);
	}
	if (objc_test_class_flag(cls, objc_class_flag_fast_arc))
	{
		return retain_fast(obj, isWeak);
	}
	return ManualRetainReleaseMessage(obj, retain, id(*)(id, SEL));
}

extern "C" OBJC_PUBLIC BOOL objc_release_fast_no_destroy_np(id obj)
{
	auto *refCount = reinterpret_cast<std::atomic<uintptr_t>*>(obj) - 1;
	uintptr_t refCountVal = refCount->load(std::memory_order_relaxed);
	bool isWeak;
	bool shouldFree;
	for (;;)
	{
		size_t realCount = refCountVal & refcount_mask;
		// If the reference count is saturated or deallocating, don't decrement it.
		if (realCount >= refcount_max)
		{
			return NO;
		}
		realCount--;
		isWeak = (refCountVal & weak_mask) == weak_mask;
		shouldFree = realCount == -1;
		realCount |= refCountVal & weak_mask;
		uintptr_t updated = (uintptr_t)realCount;
		// Release ordering on the decrement so that writes made through the
		// references being dropped are visible to whichever thread performs
		// the final release.  refCountVal is refreshed on a failed exchange.
		if (refCount->compare_exchange_weak(refCountVal, updated,
		                                    std::memory_order_release,
		                                    std::memory_order_relaxed))
		{
			break;
		}
	}

	if (shouldFree)
	{
		// Acquire fence pairing with the release above, so this thread sees
		// every write made under the object's prior references before it
		// runs -dealloc.
		std::atomic_thread_fence(std::memory_order_acquire);
		if (isWeak)
		{
			if (!objc_delete_weak_refs(obj))
			{
				return NO;
			}
		}
		return YES;
	}
	return NO;
}

extern "C" OBJC_PUBLIC void objc_release_fast_np(id obj)
{
	if (objc_release_fast_no_destroy_np(obj))
	{
		[obj dealloc];
	}
}

static inline void release(id obj)
{
	if (isPersistentObject(obj)) { return; }
	Class cls = obj->isa;
	if (UNLIKELY(objc_test_class_flag(cls, objc_class_flag_is_block)))
	{
		if (cls == static_cast<void*>(&_NSConcreteStackBlock))
		{
			return;
		}
		_Block_release(obj);
		return;
	}
	if (objc_test_class_flag(cls, objc_class_flag_fast_arc))
	{
		objc_release_fast_np(obj);
		return;
	}
	return ManualRetainReleaseMessage(obj, release, void(*)(id, SEL));
}

static inline void initAutorelease(void)
{
	if (Nil == AutoreleasePool)
	{
		AutoreleasePool = objc_getClass("NSAutoreleasePool");
		if (Nil == AutoreleasePool)
		{
			useARCAutoreleasePool = YES;
		}
		else
		{
			useARCAutoreleasePool = (0 != class_getInstanceMethod(AutoreleasePool,
			                                                      SELECTOR(_ARCCompatibleAutoreleasePool)));
			if (!useARCAutoreleasePool)
			{
				[AutoreleasePool class];
				NewAutoreleasePool = class_getMethodImplementation(object_getClass(AutoreleasePool),
				                                                   SELECTOR(new));
				DeleteAutoreleasePool = class_getMethodImplementation(AutoreleasePool,
				                                                      SELECTOR(release));
				AutoreleaseAdd = class_getMethodImplementation(object_getClass(AutoreleasePool),
				                                               SELECTOR(addObject:));
			}
		}
	}
}

static inline id autorelease(id obj)
{
	//fprintf(stderr, "Autoreleasing %p\n", obj);
	if (useARCAutoreleasePool)
	{
		struct arc_tls *tls = getARCThreadData();
		if (NULL != tls)
		{
			struct arc_autorelease_pool *pool = tls->pool;
			if (NULL == pool || (pool->insert >= &pool->pool[POOL_SIZE]))
			{
				pool = new_zeroed<struct arc_autorelease_pool>();
				pool->previous = tls->pool;
				pool->insert = pool->pool;
				tls->pool = pool;
			}
			*pool->insert = obj;
			pool->insert++;
			return obj;
		}
	}
	if (objc_test_class_flag(classForObject(obj), objc_class_flag_fast_arc))
	{
		initAutorelease();
		if (0 != AutoreleaseAdd)
		{
			AutoreleaseAdd(AutoreleasePool, SELECTOR(addObject:), obj);
		}
		return obj;
	}
	return ManualRetainReleaseMessage(obj, autorelease, id(*)(id, SEL));
}

extern "C" OBJC_PUBLIC unsigned long objc_arc_autorelease_count_np(void)
{
	struct arc_tls* tls = getARCThreadData();
	unsigned long count = 0;
	if (!tls) { return 0; }

	for (struct arc_autorelease_pool *pool=tls->pool ;
	     NULL != pool ;
	     pool = pool->previous)
	{
		count += (((intptr_t)pool->insert) - ((intptr_t)pool->pool)) / sizeof(id);
	}
	return count;
}
extern "C" OBJC_PUBLIC unsigned long objc_arc_autorelease_count_for_object_np(id obj)
{
	struct arc_tls* tls = getARCThreadData();
	unsigned long count = 0;
	if (!tls) { return 0; }

	for (struct arc_autorelease_pool *pool=tls->pool ;
	     NULL != pool ;
	     pool = pool->previous)
	{
		for (id* o = pool->insert-1 ; o >= pool->pool ; o--)
		{
			if (*o == obj)
			{
				count++;
			}
		}
	}
	return count;
}

extern "C" OBJC_PUBLIC void *objc_autoreleasePoolPush(void)
{
	initAutorelease();
	struct arc_tls* tls = getARCThreadData();
	// If there is an object in the return-retained slot, then we need to
	// promote it to the real autorelease pool BEFORE pushing the new
	// autorelease pool.  If we don't, then it may be prematurely autoreleased.
	if ((NULL != tls) && (nil != tls->returnRetained))
	{
		autorelease(tls->returnRetained);
		tls->returnRetained = nil;
	}
	if (useARCAutoreleasePool)
	{
		if (NULL != tls)
		{
			struct arc_autorelease_pool *pool = tls->pool;
			if (NULL == pool || (pool->insert >= &pool->pool[POOL_SIZE]))
			{
				pool = new_zeroed<struct arc_autorelease_pool>();
				pool->previous = tls->pool;
				pool->insert = pool->pool;
				tls->pool = pool;
			}
			// If there is no autorelease pool allocated for this thread, then
			// we lazily allocate one the first time something is autoreleased.
			return (NULL != tls->pool) ? tls->pool->insert : NULL;
		}
	}
	initAutorelease();
	if (0 == NewAutoreleasePool) { return NULL; }
	return NewAutoreleasePool(AutoreleasePool, SELECTOR(new));
}
extern "C" OBJC_PUBLIC void objc_autoreleasePoolPop(void *pool)
{
	if (useARCAutoreleasePool)
	{
		struct arc_tls* tls = getARCThreadData();
		if (NULL != tls)
		{
			if (NULL != tls->pool)
			{
				emptyPool(tls, pool);
			}
			return;
		}
	}
	DeleteAutoreleasePool(static_cast<id>(pool), SELECTOR(release));
	struct arc_tls* tls = getARCThreadData();
	if (tls && tls->returnRetained)
	{
		release(tls->returnRetained);
		tls->returnRetained = nil;
	}
}

extern "C" OBJC_PUBLIC id objc_autorelease(id obj)
{
	if (nil != obj)
	{
		obj = autorelease(obj);
	}
	return obj;
}

extern "C" OBJC_PUBLIC id objc_autoreleaseReturnValue(id obj)
{
	if (!useARCAutoreleasePool) 
	{
		struct arc_tls* tls = getARCThreadData();
		if (NULL != tls)
		{
			objc_autorelease(tls->returnRetained);
			tls->returnRetained = obj;
			return obj;
		}
	}
	return objc_autorelease(obj);
}

extern "C" OBJC_PUBLIC id objc_retainAutoreleasedReturnValue(id obj)
{
	// If the previous object was released  with objc_autoreleaseReturnValue()
	// just before return, then it will not have actually been autoreleased.
	// Instead, it will have been stored in TLS.  We just remove it from TLS
	// and undo the fake autorelease.
	//
	// If the object was not returned with objc_autoreleaseReturnValue() then
	// we actually autorelease the fake object. and then retain the argument.
	// In tis case, this is equivalent to objc_retain().
	struct arc_tls* tls = getARCThreadData();
	if (NULL != tls)
	{
		// If we're using our own autorelease pool, just pop the object from the top
		if (useARCAutoreleasePool)
		{
			if ((NULL != tls->pool) &&
			    (*(tls->pool->insert-1) == obj))
			{
				tls->pool->insert--;
				return obj;
			}
		}
		else if (obj == tls->returnRetained)
		{
			tls->returnRetained = NULL;
			return obj;
		}
	}
	return objc_retain(obj);
}

extern "C" OBJC_PUBLIC id objc_retain(id obj)
{
	if (nil == obj) { return nil; }
	return retain(obj, NO);
}

extern "C" OBJC_PUBLIC id objc_retainAutorelease(id obj)
{
	return objc_autorelease(objc_retain(obj));
}

extern "C" OBJC_PUBLIC id objc_retainAutoreleaseReturnValue(id obj)
{
	if (nil == obj) { return obj; }
	return objc_autoreleaseReturnValue(retain(obj, NO));
}


extern "C" OBJC_PUBLIC id objc_retainBlock(id b)
{
	return static_cast<id>(_Block_copy(b));
}

extern "C" OBJC_PUBLIC void objc_release(id obj)
{
	if (nil == obj) { return; }
	release(obj);
}

extern "C" OBJC_PUBLIC id objc_storeStrong(id *addr, id value)
{
	value = objc_retain(value);
	id oldValue = *addr;
	*addr = value;
	objc_release(oldValue);
	return value;
}

////////////////////////////////////////////////////////////////////////////////
// Weak references
////////////////////////////////////////////////////////////////////////////////

static int weakref_class;

namespace {

/**
 * The weak-reference table is split into stripes.  Every weak operation keys
 * off a single object address (two, in the case of `objc_storeWeak`), so
 * sharding by object address lets weak traffic on unrelated objects proceed
 * without serialising on one global lock.
 *
 * OBJC_WEAK_SHARD_MAX is the compile-time upper bound (the storage reserved
 * for the stripe array).  OBJC_WEAK_SHARD_COUNT is the default number of
 * stripes actually used.  Both must be powers of two.  The active count can
 * be tuned per process with the OBJC_WEAK_SHARD_COUNT environment variable
 * (rounded down to a power of two, clamped to OBJC_WEAK_SHARD_MAX), so a
 * deployment can spend a little more memory for more weak throughput without
 * recompiling.
 */
#ifndef OBJC_WEAK_SHARD_MAX
#define OBJC_WEAK_SHARD_MAX 256
#endif
#ifndef OBJC_WEAK_SHARD_COUNT
#define OBJC_WEAK_SHARD_COUNT 64
#endif
static_assert((OBJC_WEAK_SHARD_MAX & (OBJC_WEAK_SHARD_MAX - 1)) == 0,
              "OBJC_WEAK_SHARD_MAX must be a power of two");
static_assert((OBJC_WEAK_SHARD_COUNT & (OBJC_WEAK_SHARD_COUNT - 1)) == 0,
              "OBJC_WEAK_SHARD_COUNT must be a power of two");
static_assert(OBJC_WEAK_SHARD_COUNT <= OBJC_WEAK_SHARD_MAX,
              "OBJC_WEAK_SHARD_COUNT must not exceed OBJC_WEAK_SHARD_MAX");

// (active stripe count - 1), used to map an object hash to a stripe.  Seeded
// with the compile-time default and finalised by init_arc() once the
// environment has been consulted.
static size_t weakShardMask = OBJC_WEAK_SHARD_COUNT - 1;

/**
 * Sentinel index meaning "no shard" for the lock guard below.
 */
static const size_t WEAK_SHARD_NONE = ~static_cast<size_t>(0);

/**
 * Map an object address to a shard.  Heap objects are at least pointer
 * aligned, so the low bits carry no entropy; fold in higher bits before
 * masking to spread addresses across shards.
 */
static inline size_t weakShardIndex(const void *obj)
{
	uintptr_t a = reinterpret_cast<uintptr_t>(obj);
	return ((a >> 4) ^ (a >> 12) ^ (a >> 20)) & weakShardMask;
}

struct WeakRef
{
	void *isa = &weakref_class;
	id obj = nullptr;
	size_t weak_count = 1;
	// The shard that owns this control block.  Set once, when the block is
	// first allocated, and never changed: a block is only ever recycled for
	// another object in the same shard (see the per-shard free list below), so
	// this stays constant for the life of the process.  That is what lets a
	// slot-first operation read it lock-free to pick the owning shard without
	// risking a use-after-free -- the block is type-stable and this field is
	// immutable.
	size_t shardIndex;
	// Free-list link, valid only while the block sits on a shard's free list.
	WeakRef *nextFree = nullptr;
	WeakRef(id o) : obj(o), shardIndex(weakShardIndex(o)) {}
};

template<typename T>
struct malloc_allocator
{
	typedef T value_type;
	T* allocate(std::size_t n)
	{
		return static_cast<T*>(malloc(sizeof(T) * n));
	}

	void deallocate(T* p, std::size_t)
	{
		free(p);
	}

	template<typename X>
	malloc_allocator &operator=(const malloc_allocator<X>&) const
	{
		return *this;
	}

	bool operator==(const malloc_allocator &) const
	{
		return true;
	}

	template<typename X>
	operator malloc_allocator<X>() const
	{
		return malloc_allocator<X>();
	}
};

using weak_ref_table = tsl::robin_pg_map<const void*,
                                         WeakRef*,
                                         std::hash<const void*>,
                                         std::equal_to<const void*>,
                                         malloc_allocator<std::pair<const void*, WeakRef*>>>;

/**
 * One stripe of the weak-reference table: an independent lock and map.
 *
 * Aligned to a cache line (and thereby padded to a whole number of them) so
 * that adjacent shards never share a line.  Without this, a thread operating
 * on shard N would invalidate the line holding part of shard N+1, reintroducing
 * false sharing between objects that the striping was meant to keep apart.
 */
struct alignas(64) WeakRefShard
{
	mutex_t lock;
	weak_ref_table table;
	// Type-stable free list of recycled control blocks for this shard.  Blocks
	// are never returned to the allocator; recycling them here keeps their
	// memory (and their immutable `shardIndex`) valid forever, so a slot-first
	// operation may read `shardIndex` without a lock to choose the shard.
	// Guarded by `lock`.
	WeakRef *freeList = nullptr;
	WeakRefShard() : table(16) { INIT_LOCK(lock); }
};

/**
 * Accessor for the shard array.  A function-local static guarantees the maps
 * are constructed and the locks initialised on first use, before any weak
 * operation can run, sidestepping static-initialisation ordering issues with
 * runtime bring-up (mirroring the previous `weakRefs()` accessor).
 */
static inline WeakRefShard *weakShards()
{
	static WeakRefShard shards[OBJC_WEAK_SHARD_MAX];
	return shards;
}

/**
 * RAII guard that locks one or two shards (`WEAK_SHARD_NONE` = none) in
 * ascending index order, de-duplicating equal indices.  The global ordering
 * means two-object operations (`objc_storeWeak`) can never deadlock against
 * one another.
 */
struct WeakLockGuard
{
	mutex_t *locks[2] = { nullptr, nullptr };
	WeakLockGuard(size_t i, size_t j = WEAK_SHARD_NONE)
	{
		size_t a = i, b = j;
		if ((a != WEAK_SHARD_NONE) && (b != WEAK_SHARD_NONE))
		{
			if (a == b) { b = WEAK_SHARD_NONE; }
			else if (a > b) { size_t t = a; a = b; b = t; }
		}
		else if (a == WEAK_SHARD_NONE) { a = b; b = WEAK_SHARD_NONE; }
		if (a != WEAK_SHARD_NONE) { locks[0] = &weakShards()[a].lock; LOCK(locks[0]); }
		if (b != WEAK_SHARD_NONE) { locks[1] = &weakShards()[b].lock; LOCK(locks[1]); }
	}
	WeakLockGuard(const WeakLockGuard&) = delete;
	WeakLockGuard &operator=(const WeakLockGuard&) = delete;
	~WeakLockGuard()
	{
		if (locks[1]) { UNLOCK(locks[1]); }
		if (locks[0]) { UNLOCK(locks[0]); }
	}
};

/**
 * If `p` is a weak-reference control block, return it without dereferencing
 * its lock-protected `obj` field, so the caller can determine the owning shard
 * before taking any lock.  Otherwise (nil or a real object) return nullptr.
 */
static inline WeakRef *asWeakRef(id p)
{
	if ((p != nil) && (classForObject(p) == (Class)&weakref_class))
	{
		return reinterpret_cast<WeakRef*>(p);
	}
	return nullptr;
}

}

#ifdef HAVE_BLOCK_USE_RR2
static const struct Block_callbacks_RR blocks_runtime_callbacks = {
		sizeof(Block_callbacks_RR),
		(void (*)(const void*))objc_retain,
		(void (*)(const void*))objc_release,
		(void (*)(const void*))objc_delete_weak_refs
	};
#endif

PRIVATE extern "C" void init_arc(void)
{
	// Let a deployment tune the weak-table stripe count.  Round the request
	// down to a power of two in [1, OBJC_WEAK_SHARD_MAX] so the index mask
	// stays valid; leave the compiled-in default in place otherwise.
	if (const char *env = getenv("OBJC_WEAK_SHARD_COUNT"))
	{
		long requested = strtol(env, nullptr, 10);
		if (requested >= 1)
		{
			size_t count = 1;
			while (((count << 1) <= static_cast<size_t>(requested)) &&
			       ((count << 1) <= OBJC_WEAK_SHARD_MAX))
			{
				count <<= 1;
			}
			weakShardMask = count - 1;
		}
	}
	// Force construction of the weak-table shards (and initialisation of their
	// locks) before any weak operation can run.
	weakShards();
#ifdef arc_tls_store
	ARCThreadKey = arc_tls_key_create((arc_cleanup_function_t)cleanupPools);
#endif
#ifdef HAVE_BLOCK_USE_RR2
	_Block_use_RR2(&blocks_runtime_callbacks);
#endif
}

/**
  * Load from a weak pointer and return whether this really was a weak
  * reference or a strong (not deallocatable) object in a weak pointer.  The
  * object will be stored in `obj` and the weak reference in `ref`, if one
  * exists.
  */
__attribute__((always_inline))
static inline BOOL loadWeakPointer(id *addr, id *obj, WeakRef **ref)
{
	id oldObj = *addr;
	if (oldObj == nil)
	{
		*ref = NULL;
		*obj = nil;
		return NO;
	}
	if (classForObject(oldObj) == (Class)&weakref_class)
	{
		*ref = (WeakRef*)oldObj;
		*obj = (*ref)->obj;
		return YES;
	}
	*ref = NULL;
	*obj = oldObj;
	return NO;
}

/**
 * Obtain a control block for `obj` in its shard, recycling one from the shard's
 * free list if available.  Caller must hold the shard lock.
 */
static inline WeakRef *allocWeakRef(id obj, size_t shard)
{
	WeakRefShard &s = weakShards()[shard];
	WeakRef *ref = s.freeList;
	if (ref != nullptr)
	{
		s.freeList = ref->nextFree;
		ref->isa = &weakref_class;
		ref->obj = obj;
		ref->weak_count = 1;
		ref->nextFree = nullptr;
		// shardIndex is already == shard and never changes.
	}
	else
	{
		ref = new WeakRef(obj);
	}
	return ref;
}

/**
 * Return a control block to its shard's free list instead of freeing it, so
 * its memory (and immutable shardIndex) stay valid for lock-free shard
 * selection.  Caller must hold the shard lock.
 */
static inline void recycleWeakRef(WeakRef *ref)
{
	WeakRefShard &s = weakShards()[ref->shardIndex];
	ref->obj = nil;
	ref->nextFree = s.freeList;
	s.freeList = ref;
}

__attribute__((always_inline))
static inline BOOL weakRefRelease(WeakRef *ref)
{
	ref->weak_count--;
	if (ref->weak_count == 0)
	{
		weakShards()[ref->shardIndex].table.erase(ref->obj);
		recycleWeakRef(ref);
		return YES;
	}
	return NO;
}

extern "C" void* block_load_weak(void *block);

static BOOL setObjectHasWeakRefs(id obj)
{
	BOOL isGlobalObject = isPersistentObject(obj);
	Class cls = isGlobalObject ? Nil : obj->isa;
	if (obj && cls && objc_test_class_flag(cls, objc_class_flag_fast_arc))
	{
		auto *refCount = reinterpret_cast<std::atomic<uintptr_t>*>(obj) - 1;
		uintptr_t refCountVal = refCount->load(std::memory_order_relaxed);
		for (;;)
		{
			size_t realCount = refCountVal & refcount_mask;
			// If this object has already been deallocated (or is in the
			// process of being deallocated) then don't bother storing it.
			if (realCount == refcount_mask)
			{
				obj = nil;
				cls = Nil;
				break;
			}
			// The weak ref flag is monotonic (it is set, never cleared) so
			// don't bother trying to re-set it.
			if ((refCountVal & weak_mask) == weak_mask)
			{
				break;
			}
			// Set the flag in the reference count to indicate that a weak
			// reference has been taken.
			//
			// We currently hold the weak ref lock, so another thread
			// racing to deallocate this object will have to wait to do so
			// if we manage to do the reference count update first.  This
			// shouldn't be possible, because `obj` should be a strong
			// reference and so it shouldn't be possible to deallocate it
			// while we're assigning it.
			//
			// Relaxed ordering suffices: the flag lives in the reference
			// count word, so the CAS in the release path (itself a
			// read-modify-write) always observes it via the location's
			// modification order.  Visibility of the weak-table entry we
			// publish next is provided by the shard lock, not by this atomic.
			uintptr_t updated = ((uintptr_t)realCount | weak_mask);
			// Acquire/release on the exchange, matching the other
			// reference-count updates.  The weak-ref lock, held here, orders
			// the weak-table entry we publish next.
			if (refCount->compare_exchange_weak(refCountVal, updated,
			                                    std::memory_order_acq_rel,
			                                    std::memory_order_acquire))
			{
				break;
			}
		}
	}
	return isGlobalObject;
}

WeakRef *incrementWeakRefCount(id obj)
{
	size_t shard = weakShardIndex(obj);
	WeakRef *&ref = weakShards()[shard].table[obj];
	if (ref == nullptr)
	{
		ref = allocWeakRef(obj, shard);
	}
	else
	{
		assert(ref->obj == obj);
		ref->weak_count++;
	}
	return ref;
}

extern "C" OBJC_PUBLIC id objc_storeWeak(id *addr, id obj)
{
	// This operation touches two objects: the one currently referenced by the
	// slot (if any) and the new one.  Lock both owning shards (ordered, and
	// de-duplicated if they coincide) for the duration.  Reading `*addr` here
	// is safe without a lock: the slot has a single owning writer, and a
	// concurrent dealloc only zeroes the control block's `obj`, never the
	// slot's pointer to that block, so the peeked shard index is stable.
	WeakRef *oldPeek = asWeakRef(*addr);
	size_t sOld = oldPeek ? oldPeek->shardIndex : WEAK_SHARD_NONE;
	size_t sNew = obj ? weakShardIndex(obj) : WEAK_SHARD_NONE;
	WeakLockGuard g(sOld, sNew);
	WeakRef *oldRef;
	id old;
	loadWeakPointer(addr, &old, &oldRef);
	// If the old and new values are the same, then we don't need to do anything
	// unless we are deleting the weak reference by storing NULL to it.
	if ((old == obj) && ((obj != NULL) || (NULL == oldRef)))
	{
		return obj;
	}
	BOOL isGlobalObject = setObjectHasWeakRefs(obj);
	// If we old ref exists, decrement its reference count.  This may also
	// delete the weak reference control block.
	if (oldRef != NULL)
	{
		weakRefRelease(oldRef);
	}
	// If we're storing nil, then just write a null pointer.
	if (nil == obj)
	{
		*addr = obj;
		return nil;
	}
	if (isGlobalObject)
	{
		// If this is a global object, it's never deallocated, so secretly make
		// this a strong reference.
		*addr = obj;
		return obj;
	}
	Class cls = classForObject(obj);
	if (UNLIKELY(objc_test_class_flag(cls, objc_class_flag_is_block)))
	{
		// Check whether the block is being deallocated and return nil if so
		if (_Block_isDeallocating(obj)) {
			*addr = nil;
			return nil;
		}
	}
	else if (object_getRetainCount_np(obj) == 0)
	{
		// If the object is being deallocated return nil.
		*addr = nil;
		return nil;
	}
	if (nil != obj)
	{
		*addr = (id)incrementWeakRefCount(obj);
	}
	return obj;
}

extern "C" OBJC_PUBLIC BOOL objc_delete_weak_refs(id obj)
{
	WeakLockGuard g(weakShardIndex(obj));
	if (objc_test_class_flag(classForObject(obj), objc_class_flag_fast_arc))
	{
		// Don't proceed if the object isn't deallocating.
		auto *refCount = reinterpret_cast<std::atomic<uintptr_t>*>(obj) - 1;
		uintptr_t refCountVal = refCount->load(std::memory_order_relaxed);
		size_t realCount = refCountVal & refcount_mask;
		if (realCount != refcount_mask)
		{
			return NO;
		}
	}
	auto &table = weakShards()[weakShardIndex(obj)].table;
	auto old = table.find(obj);
	if (old != table.end())
	{
		WeakRef *oldRef = old->second;
		// The address of obj is likely to be reused, so remove it from
		// the table so that we don't accidentally alias weak
		// references
		table.erase(old);
		// Zero the object pointer.  This prevents any other weak
		// accesses from loading from this.  This must be done after
		// removing the ref from the table, because the compare operation
		// tests the obj field.
		oldRef->obj = nil;
		// If the weak reference count is zero, then we should have
		// already removed this.
		assert(oldRef->weak_count > 0);
	}
	return YES;
}

extern "C" OBJC_PUBLIC id objc_loadWeakRetained(id* addr)
{
	// If this is really a strong reference (nil, or a non-deallocatable
	// object), just return it -- no control block, no lock needed.
	WeakRef *peek = asWeakRef(*addr);
	if (peek == nullptr)
	{
		return *addr;
	}
	// Lock the shard that owns this control block before reading its `obj`,
	// which a concurrent dealloc (holding the same shard) may be zeroing.
	WeakLockGuard g(peek->shardIndex);
	id obj;
	WeakRef *ref;
	if (!loadWeakPointer(addr, &obj, &ref))
	{
		return obj;
	}
	// The object cannot be deallocated while we hold the lock (release
	// will acquire the lock before attempting to deallocate)
	if (obj == nil)
	{
		// If the object is destroyed, drop this reference to the WeakRef
		// struct.
		if (ref != NULL)
		{
			weakRefRelease(ref);
			*addr = nil;
		}
		return nil;
	}
	Class cls = classForObject(obj);
	if (objc_test_class_flag(cls, objc_class_flag_permanent_instances))
	{
		return obj;
	}
	else if (UNLIKELY(objc_test_class_flag(cls, objc_class_flag_is_block)))
	{
		obj = static_cast<id>(block_load_weak(obj));
		if (obj == nil)
		{
			return nil;
		}
		// This is a defeasible retain operation that protects against another thread concurrently
		// starting to deallocate the block.
		if (_Block_tryRetain(obj))
		{
			return obj;
		}
		return nil;

	}
	else if (!objc_test_class_flag(cls, objc_class_flag_fast_arc))
	{
		obj = _objc_weak_load(obj);
	}
	// _objc_weak_load() can return nil
	if (obj == nil) { return nil; }
	return retain(obj, YES);
}

extern "C" OBJC_PUBLIC id objc_loadWeak(id* object)
{
	return objc_autorelease(objc_loadWeakRetained(object));
}

extern "C" OBJC_PUBLIC void objc_copyWeak(id *dest, id *src)
{
	// Don't retain or release.
	// `src` is a valid pointer to a __weak pointer or nil.
	// `dest` is a valid pointer to uninitialised memory.
	// After this operation, `dest` should contain whatever `src` contained.
	WeakRef *peek = asWeakRef(*src);
	if (peek == nullptr)
	{
		// nil or a non-deallocatable strong object: no bookkeeping to do.
		*dest = *src;
		return;
	}
	WeakLockGuard g(peek->shardIndex);
	id obj;
	WeakRef *srcRef;
	loadWeakPointer(src, &obj, &srcRef);
	*dest = *src;
	if (srcRef)
	{
		srcRef->weak_count++;
	}
}

extern "C" OBJC_PUBLIC void objc_moveWeak(id *dest, id *src)
{
	// Don't retain or release.
	// `dest` is a valid pointer to uninitialized memory.
	// `src` is a valid pointer to a __weak pointer.
	// This operation moves from *src to *dest and must be atomic with respect
	// to other stores to *src via `objc_storeWeak`.
	//
	// Lock the shard owning the moved control block (if any) so this is atomic
	// against a concurrent store to *src.  A nil/strong slot needs no lock.
	WeakRef *peek = asWeakRef(*src);
	WeakLockGuard g(peek ? peek->shardIndex : WEAK_SHARD_NONE);
	*dest = *src;
	*src = nil;
}

extern "C" OBJC_PUBLIC void objc_destroyWeak(id* obj)
{
	WeakRef *peek = asWeakRef(*obj);
	if (peek == nullptr)
	{
		// nil or a non-deallocatable strong object: nothing to release.
		return;
	}
	WeakLockGuard g(peek->shardIndex);
	WeakRef *oldRef;
	id old;
	loadWeakPointer(obj, &old, &oldRef);
	// If the old ref exists, decrement its reference count.  This may also
	// delete the weak reference control block.
	if (oldRef != NULL)
	{
		weakRefRelease(oldRef);
	}
}

extern "C" OBJC_PUBLIC id objc_initWeak(id *addr, id obj)
{
	if (obj == nil)
	{
		*addr = nil;
		return nil;
	}
	WeakLockGuard g(weakShardIndex(obj));
	BOOL isGlobalObject = setObjectHasWeakRefs(obj);
	if (isGlobalObject)
	{
		// If this is a global object, it's never deallocated, so secretly make
		// this a strong reference.
		*addr = obj;
		return obj;
	}
	// If the object is being deallocated return nil.
	if (object_getRetainCount_np(obj) == 0)
	{
		*addr = nil;
		return nil;
	}
	if (nil != obj)
	{
		*(WeakRef**)addr = incrementWeakRefCount(obj);
	}
	return obj;
}

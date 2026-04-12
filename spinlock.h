#ifdef _WIN32
#include "safewindows.h"
#else
#include <unistd.h>
#include <sched.h>
#endif

/**
 * Number of spinlocks.  This allocates one page on 32-bit platforms.
 */
#define spinlock_count (1<<10)
static const int spinlock_mask = spinlock_count - 1;
/**
 * Integers used as spinlocks for atomic property access.
 */
extern int spinlocks[spinlock_count];
/**
 * Get a spin lock from a pointer.  We want to prevent lock contention between
 * properties in the same object - if someone is stupid enough to be using
 * atomic property access, they are probably stupid enough to do it for
 * multiple properties in the same object.  We also want to try to avoid
 * contention between the same property in different objects, so we can't just
 * use the ivar offset.
 */
static inline volatile int *lock_for_pointer(const void *ptr)
{
	intptr_t hash = (intptr_t)ptr;
	// Most properties will be pointers, so disregard the lowest few bits
	hash >>= sizeof(void*) == 4 ? 2 : 8;
	intptr_t low = hash & spinlock_mask;
	hash >>= 16;
	hash |= low;
	return spinlocks + (hash & spinlock_mask);
}

/**
 * Unlocks the spinlock.  This is not an atomic operation.  We are only ever
 * modifying the lowest bit of the spinlock word, so it doesn't matter if this
 * is two writes because there is no contention among the high bit.  There is
 * no possibility of contention among calls to this, because it may only be
 * called by the thread owning the spin lock.
 */
inline static void unlock_spinlock(volatile int *spinlock)
{
	__sync_synchronize();
	*spinlock = 0;
}
/**
 * Attempts to lock a spinlock.  This is heavily optimised for the uncontended
 * case, because property access should (generally) not be contended.  In the
 * uncontended case, this is a single atomic compare and swap instruction and a
 * branch.  Atomic CAS is relatively expensive (can be a pipeline flush, and
 * may require locking a cache line in a cache-coherent SMP system, but it's a
 * lot cheaper than a system call).
 *
 * If the lock is contended, then we just sleep and then try again after the
 * other threads have run.  Note that there is no upper bound on the potential
 * running time of this function, which is one of the great many reasons that
 * using atomic accessors is a terrible idea, but in the common case it should
 * be very fast.
 */
inline static void lock_spinlock(volatile int *spinlock)
{
	int count = 0;
	// Set the spin lock value to 1 if it is 0.
	while(!__sync_bool_compare_and_swap(spinlock, 0, 1))
	{
		count++;
		if (count <= 40)
		{
			// Spin with CPU-friendly pause hint for the first 40 iterations.
#if defined(__i386__) || defined(__x86_64__)
			__builtin_ia32_pause();
#elif defined(__arm__) || defined(__aarch64__)
			__asm__ __volatile__("yield");
#endif
		}
		else
		{
			// After spinning, yield to the OS scheduler to avoid
			// priority inversion when the lock holder is preempted.
#ifdef _WIN32
			SleepEx(0, FALSE);
#else
			sched_yield();
#endif
			// Reset to 30 to allow another short spin burst before
			// yielding again, in case the lock is about to be released.
			count = 30;
		}
	}
}


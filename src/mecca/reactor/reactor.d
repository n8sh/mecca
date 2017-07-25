module mecca.reactor.reactor;

import std.exception;
import std.string;

import mecca.containers.lists;
import mecca.containers.arrays;
import mecca.containers.pools;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.lib.memory;
import mecca.lib.typedid;
import mecca.log;
import mecca.reactor.time_queue;
import mecca.reactor.fibril: Fibril;
import mecca.reactor.fls;
import core.memory: GC;
import core.sys.posix.sys.mman: munmap, mprotect, PROT_NONE;

import std.stdio;

alias TimerHandle = Reactor.TimerHandle;
alias FiberId = TypedIdentifier!("FiberId", ushort);
alias FiberIncarnation = ushort;

class ReactorTimeout : Exception {
    this(string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow @nogc {
        super("Reactor timed out on a timed suspend", file, line, next);
    }
}

class ReactorExit : Throwable {
    mixin ExceptionBody;
}

align(1) struct ReactorFiber {
    struct OnStackParams {
        Closure                 fiberBody;
        GCStackDescriptor       stackDescriptor;
        FLSArea                 flsBlock;
        ExcBuf                  currExcBuf;
    }
    enum Flags: ubyte {
        CALLBACK_SET   = 0x01,
        SPECIAL        = 0x02,
        IMMEDIATE      = 0x04,
        SCHEDULED      = 0x08,
        HAS_EXCEPTION  = 0x10,
        EXCEPTION_BT   = 0x20,
        //REQUEST_BT     = 0x40,
    }

    enum State : ubyte {
        None, Running, Sleeping, Done
    }

align(1):
    Fibril                                      fibril;
    OnStackParams*                              params;
    FiberId                                     _nextId;
    FiberId                                     _prevId;
    FiberIncarnation                            incarnationCounter;
    ubyte                                       _flags;
    State                                       state;
    LinkedListWithOwner!(ReactorFiber*)*        _owner;

    // We define this struct align(1) for the sole purpose of making the following static assert verify what it's supposed to
    static assert (this.sizeof == 32);  // keep it small and cache-line friendly

    // LinkedQueue access through property
    @property ReactorFiber* _next() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_nextId);
    }

    @property void _next(FiberId newNext) nothrow @safe @nogc {
        _nextId = newNext;
    }

    @property void _next(ReactorFiber* newNext) nothrow @safe @nogc {
        _nextId = to!FiberId(newNext);
    }

    @property ReactorFiber* _prev() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_prevId);
    }

    @property void _prev(FiberId newPrev) nothrow @safe @nogc {
        _prevId = newPrev;
    }

    @property void _prev(ReactorFiber* newPrev) nothrow @safe @nogc {
        _prevId = to!FiberId(newPrev);
    }

    void setup(void[] stackArea) nothrow @nogc {
        fibril.set(stackArea[0 .. $ - OnStackParams.sizeof], &wrapper);
        params = cast(OnStackParams*)&stackArea[$ - OnStackParams.sizeof];
        setToInit(params);

        params.stackDescriptor.bstack = params;
        params.stackDescriptor.tstack = fibril.rsp;
        params.stackDescriptor.add();

        _next = null;
        incarnationCounter = 0;
        _flags = 0;
    }

    void teardown() nothrow @nogc {
        fibril.reset();
        if (params) {
            params.stackDescriptor.remove();
            params = null;
        }
    }

    @property FiberId identity() const nothrow @safe @nogc {
        return to!FiberId(&this);
    }

    @property bool flag(string NAME)() const pure nothrow @safe @nogc {
        return (_flags & __traits(getMember, Flags, NAME)) != 0;
    }
    @property void flag(string NAME)(bool value) pure nothrow @safe @nogc {
        if (value) {
            _flags |= __traits(getMember, Flags, NAME);
        }
        else {
            _flags &= ~__traits(getMember, Flags, NAME);
        }
    }

private:
    void updateStackDescriptor() nothrow @nogc {
        params.stackDescriptor.tstack = fibril.rsp;
    }

    void wrapper() nothrow {
        while (true) {
            INFO!"wrapper on %s flags=0x%0x"(identity, _flags);

            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (state == State.Running);
            Throwable ex = null;

            try {
                params.fiberBody();
            }
            catch (ReactorExit ex2) {
                // Do nothing. The reactor is quitting
            }
            catch (Throwable ex2) {
                ex = ex2;
            }

            INFO!"wrapper finished on %s, ex=%s"(identity, ex);

            params.fiberBody.clear();
            flag!"CALLBACK_SET" = false;
            assert (state == State.Running);
            state = State.Done;
            incarnationCounter++;
            if (ex !is null) {
                theReactor.forwardExceptionToMain(ex);
            } else {
                theReactor.fiberTerminated();
            }
        }
    }

    void switchInto() @safe @nogc {
        switchCurrExcBuf( &params.currExcBuf );
        if (!flag!"SPECIAL") {
            params.flsBlock.switchTo();
        } else {
            FLSArea.switchToNone();
        }
        auto id = identity.value;
        if (id == 0) {
            logSource = "MAIN";
        }
        else if (id == 1) {
            logSource = "IDLE";
        }
        else {
            logSource[0] = "0123456789abcdef"[(id >> 12) & 0xf];
            logSource[1] = "0123456789abcdef"[(id >> 8) & 0xf];
            logSource[2] = "0123456789abcdef"[(id >> 4) & 0xf];
            logSource[3] = "0123456789abcdef"[id & 0xf];
        }

        if (flag!"HAS_EXCEPTION") {
            Throwable ex = params.currExcBuf.get();
            if (flag!"EXCEPTION_BT") {
                params.currExcBuf.setTraceback(ex);
                flag!"EXCEPTION_BT" = false;
            }

            flag!"HAS_EXCEPTION" = false;
            throw ex;
        }
    }
}


struct FiberHandle {
    FiberId identity;
    FiberIncarnation incarnation;

    this(ReactorFiber* fib) nothrow @safe @nogc {
        opAssign(fib);
    }
    auto ref opAssign(ReactorFiber* fib) nothrow @safe @nogc {
        if (fib) {
            identity = fib.identity;
            incarnation = fib.incarnationCounter;
        }
        else {
            identity = FiberId.invalid;
        }
        return this;
    }
    package @property ReactorFiber* get() const nothrow @trusted @nogc {
        if (!identity.isValid || theReactor.allFibers[identity.value].incarnationCounter != incarnation) {
            return null;
        }
        return &theReactor.allFibers[identity.value];
    }

    @property bool isValid() const nothrow @safe @nogc {
        return get() !is null;
    }
}


struct Reactor {
private:
    enum MAX_IDLE_CALLBACKS = 16;
    enum TIMER_NUM_BINS = 256;
    enum TIMER_NUM_LEVELS = 3;

    enum NUM_SPECIAL_FIBERS = 2;
    enum ZERO_DURATION = Duration.zero;

    struct Options {
        uint     numFibers = 256;
        size_t   fiberStackSize = 32*1024;
        Duration gcInterval = 30.seconds;
        Duration timerGranularity = 1.msecs;
        size_t   numTimers = 10000;
    }

    bool _open;
    bool _running;
    int criticalSectionNesting;
    ulong idleCycles;
    Options options;

    MmapBuffer fiberStacks;
    MmapArray!ReactorFiber allFibers;
    LinkedQueueWithLength!(ReactorFiber*) freeFibers;
    LinkedQueueWithLength!(ReactorFiber*) scheduledFibers;

    ReactorFiber* thisFiber;
    ReactorFiber* prevFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    alias IdleCallbackDlg = void delegate(Duration);
    FixedArray!(IdleCallbackDlg, MAX_IDLE_CALLBACKS) idleCallbacks;

    struct TimedCallback {
        TimedCallback* _next, _prev;
        timeQueue.OwnerAttrType _owner;
        TscTimePoint timePoint;
        ulong intervalCycles; // How many cycles between repeatetions. Zero means non-repeating

        Closure closure;
    }

    // TODO change to mmap pool or something
    SimplePool!(TimedCallback) timedCallbacksPool;
    CascadingTimeQueue!(TimedCallback*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue;

public:
    @property bool isOpen() const pure nothrow @nogc {
        return _open;
    }

    void setup() {
        assert (!_open, "reactor.setup called twice");
        _open = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        thisFiber = null;
        criticalSectionNesting = 0;
        idleCallbacks.length = 0;

        foreach(i, ref fib; allFibers) {
            auto stack = fiberStacks[i * stackPerFib .. (i + 1) * stackPerFib];
            //errnoEnforce(mprotect(stack.ptr, SYS_PAGE_SIZE, PROT_NONE) == 0);
            errnoEnforce(munmap(stack.ptr, SYS_PAGE_SIZE) == 0, "munmap");
            fib.setup(stack[SYS_PAGE_SIZE .. $]);

            if (i >= NUM_SPECIAL_FIBERS) {
                freeFibers.append(&fib);
            }
        }

        mainFiber = &allFibers[0];
        mainFiber.flag!"SPECIAL" = true;
        mainFiber.flag!"CALLBACK_SET" = true;
        mainFiber.state = ReactorFiber.State.Running;

        idleFiber = &allFibers[1];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.flag!"CALLBACK_SET" = true;
        idleFiber.params.fiberBody.set(&idleLoop);

        timedCallbacksPool.open(options.numTimers, true);
        timeQueue.open(options.timerGranularity);
    }

    void teardown() {
        assert(_open, "reactor teardown called on non-open reactor");
        assert(!_running, "reactor teardown called on still running reactor");
        assert(criticalSectionNesting==0);

        switchCurrExcBuf(null);

        options.setToInit();
        allFibers.free();
        fiberStacks.free();
        timeQueue.close();
        timedCallbacksPool.close();

        setToInit(freeFibers);
        setToInit(scheduledFibers);

        thisFiber = null;
        prevFiber = null;
        mainFiber = null;
        idleFiber = null;
        idleCallbacks.length = 0;
        idleCycles = 0;

        _open = false;
    }

    void registerIdleCallback(IdleCallbackDlg dg) nothrow @safe @nogc {
        // You will notice our deliberate lack of function to unregister
        idleCallbacks ~= dg;
        DEBUG!"%s idle callbacks registered"(idleCallbacks.length);
    }

    FiberHandle spawnFiber(T...)(T args) {
        auto fib = _spawnFiber(false);
        fib.params.fiberBody.set(args);
        return FiberHandle(fib);
    }

    /+FiberHandle spawnFiber(alias F)(Parameters!F args) {
        auto fib = _spawnFiber(false);
        fib.params.fiberBody.set!F(args);
        return FiberHandle(fib);
    }+/

    @property bool isIdle() pure const nothrow @safe @nogc {
        return thisFiber is idleFiber;
    }
    @property bool isMain() pure const nothrow @safe @nogc {
        return thisFiber is mainFiber;
    }
    @property bool isSpecialFiber() const nothrow @safe @nogc {
        return thisFiber.flag!"SPECIAL";
    }
    @property FiberHandle runningFiberHandle() nothrow @safe @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        assert(!isSpecialFiber, "Should not blindly get fiber handle of special fibers");
        return FiberHandle(thisFiber);
    }

    void start() {
        INFO!"Starting reactor"();
        assert( idleFiber !is null, "Reactor started without calling \"setup\" first" );
        mainloop();
    }

    void stop() {
        if (_running) {
            Throwable reactorExit = mkEx!ReactorExit("Reactor is quitting");
            foreach(ref fiber; allFibers) {
                if( !fiber.flag!"SPECIAL" && fiber.state == ReactorFiber.State.Sleeping ) {
                    throwInFiber(FiberHandle(&fiber), reactorExit);
                }
            }
            yieldThisFiber(); // Let everyone else die

            INFO!"Stopping reactor"();
            _running = false;
            if (thisFiber !is mainFiber) {
                resumeSpecialFiber(mainFiber);
            }

            if( !thisFiber.flag!"SPECIAL" )
                throw reactorExit; // We need to die too
        }
    }

    void enterCriticalSection() pure nothrow @safe @nogc {
        pragma(inline, true);
        criticalSectionNesting++;
    }

    void leaveCriticalSection() pure nothrow @safe @nogc {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }
    @property bool isInCriticalSection() const pure nothrow @safe @nogc {
        return criticalSectionNesting > 0;
    }

    @property auto criticalSection() nothrow @safe @nogc {
        pragma(inline, true);
        struct CriticalSection {
            @disable this(this);
            ~this() nothrow @trusted @nogc {theReactor.leaveCriticalSection();}
        }
        enterCriticalSection();
        return CriticalSection();
    }

    void yieldThisFiber() @safe @nogc {
        resumeFiber(thisFiber);
        suspendThisFiber();
    }

    struct TimerHandle {
    private:
        TimedCallback* callback;

    public:
        bool isValid() const @safe @nogc {
            return callback !is null;
        }
    }

    TimerHandle registerTimer(alias F)(Timeout timeout, Parameters!F params) nothrow @safe @nogc {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.closure.set(&F, params);
        callback.timePoint = timeout.expiry;
        callback.intervalCycles = 0;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    private TimedCallback* _registerRecurringTimer(Duration interval) nothrow @safe @nogc {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.intervalCycles = TscTimePoint.toCycles(interval);
        rescheduleRecurringTimer(callback);
        return callback;
    }


    TimerHandle registerRecurringTimer(Duration interval, void delegate() dg) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(dg);
        return TimerHandle(callback);
    }

    TimerHandle registerRecurringTimer(alias F)(Duration interval, Parameters!F params) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(&F, params);
        return TimerHandle(callback);
    }

    void cancelTimer(TimerHandle handle) @safe @nogc {
        if( !handle.isValid )
            return;
        timeQueue.cancel(handle.callback);
    }

    void sleep(Duration duration) @safe @nogc {
        sleep(Timeout(duration));
    }

    void sleep(Timeout until) @safe @nogc {
        assert(until != Timeout.init, "sleep argument uninitialized");
        auto timerHandle = registerTimer!resumeFiber(until, runningFiberHandle);
        scope(failure) cancelTimer(timerHandle);

        suspendThisFiber();
    }

    bool throwInFiber(FiberHandle fHandle, Throwable ex) nothrow @safe @nogc {
        ExcBuf* fiberEx = prepThrowInFiber(fHandle, false);

        if( fiberEx is null )
            return false;

        fiberEx.set(ex);
        auto fib = fHandle.get();
        resumeFiber(fib);
        return true;
    }

    bool throwInFiber(T : Throwable, string file = __FILE__, size_t line = __LINE__, A...)(FiberHandle fHandle, auto ref A args) nothrow @safe @nogc {
        pragma(inline, true);
        ExcBuf* fiberEx = prepThrowInFiber(fHandle, true);

        if( fiberEx is null )
            return false;

        fiberEx.construct!T(file, line, false, args);
        auto fib = fHandle.get();
        fib.flag!"IMMEDIATE" = true; //  this should be a parameter to resumeFiber instead
        resumeFiber(fib);
        return true;
    }

private:
    @property bool shouldRunTimedCallbacks() nothrow @safe @nogc {
        return timeQueue.cyclesTillNextEntry(TscTimePoint.now()) == 0;
    }

    void switchToNext() @trusted @nogc {
        //DEBUG!"SWITCH out of %s"(thisFiber.identity);

        // in source fiber
        {
            if (thisFiber !is mainFiber && !mainFiber.flag!"SCHEDULED" && shouldRunTimedCallbacks()) {
                resumeSpecialFiber(mainFiber);
            }
            else if (scheduledFibers.empty) {
                resumeSpecialFiber(idleFiber);
            }

            assert (!scheduledFibers.empty, "scheduledList is empty");

            prevFiber = thisFiber;
            if( prevFiber.state==ReactorFiber.State.Running )
                prevFiber.state = ReactorFiber.State.Sleeping;
            else {
                assert( prevFiber.state==ReactorFiber.State.Done );
                prevFiber.state = ReactorFiber.State.None;
            }

            thisFiber = scheduledFibers.popHead();

            assert (thisFiber.flag!"SCHEDULED");
            thisFiber.flag!"SCHEDULED" = false;
            thisFiber.state = ReactorFiber.State.Running;

            if (prevFiber !is thisFiber) {
                // make the switch
                prevFiber.fibril.switchTo(thisFiber.fibril);
            }
        }

        // in destination fiber
        {
            // note that GC cannot happen here since we disabled it in the mainloop() --
            // otherwise this might have been race-prone
            prevFiber.updateStackDescriptor();
            //DEBUG!"SWITCH into %s"(thisFiber.identity);

            // This might throw, so it needs to be the last thing we do
            thisFiber.switchInto();
        }
    }

    void fiberTerminated() nothrow {
        ASSERT!"special fibers must never terminate" (!thisFiber.flag!"SPECIAL");

        freeFibers.prepend(thisFiber);

        try {
            /+if (ex) {
                mainFiber.setException(ex);
                resumeSpecialFiber(mainFiber);
            }+/
            switchToNext();
        }
        catch (Throwable ex2) {
            ERROR!"switchToNext on dead fiber failed with exception %s"(ex2);
            assert(false);
        }
    }

    package void suspendThisFiber(Timeout timeout) @trusted @nogc {
        if (timeout == Timeout.infinite)
            return suspendThisFiber();

        assert (!isInCriticalSection);

        TimerHandle timeoutHandle;
        scope(exit) cancelTimer( timeoutHandle );
        bool timeoutExpired;

        if (timeout == Timeout.elapsed) {
            throw mkEx!ReactorTimeout;
        }

        static void resumer(FiberHandle fibHandle, TimerHandle* cookie, bool* timeoutExpired) nothrow @trusted @nogc{
            *cookie = TimerHandle.init;
            ReactorFiber* fib = fibHandle.get;
            assert( fib !is null, "Fiber disappeared while suspended with timer" );

            // Throw ReactorTimeout only if we're the ones who resumed the fiber. this prevents a race when
            // someone else had already woken the fiber, but it just didn't get time to run while the timer expired.
            // this probably indicates fibers hogging the CPU for too long (starving others)
            *timeoutExpired = ! fib.flag!"SCHEDULED";

            /+
                    if (! *timeoutExpired)
                        fib.WARN_AS!"#REACTOR fiber resumer invoked, but fiber already scheduled (starvation): %s scheduled, %s pending"(
                                theReactor.scheduledFibers.length, theReactor.pendingFibers.length);
            +/

            theReactor.resumeFiber(fib);
        }

        timeoutHandle = registerTimer!resumer(timeout, runningFiberHandle, &timeoutHandle, &timeoutExpired);
        switchToNext();

        if( timeoutExpired )
            throw mkEx!ReactorTimeout();
    }

    package void suspendThisFiber() @safe @nogc {
         assert (!isInCriticalSection);
         switchToNext();
    }

    void resumeSpecialFiber(ReactorFiber* fib) nothrow @safe @nogc {
        assert (fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");
        assert (!fib.flag!"SCHEDULED" || scheduledFibers.head is fib);

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            scheduledFibers.prepend(fib);
        }
    }

    package void resumeFiber(FiberHandle handle) nothrow @safe @nogc {
        resumeFiber(handle.get());
    }

    void resumeFiber(ReactorFiber* fib) nothrow @safe @nogc {
        assert (!fib.flag!"SPECIAL");
        ASSERT!"resumeFiber called on %s, which does not have a callback set"(fib.flag!"CALLBACK_SET", fib.identity);

        if (!fib.flag!"SCHEDULED") {
            if (fib._owner !is null) {
                // Whatever this fiber was waiting to do, it is no longer what it needs to be doing
                fib._owner.remove(fib);
            }
            fib.flag!"SCHEDULED" = true;
            if (fib.flag!"IMMEDIATE") {
                fib.flag!"IMMEDIATE" = false;
                scheduledFibers.prepend(fib);
            }
            else {
                scheduledFibers.append(fib);
            }
        }
    }

    ReactorFiber* _spawnFiber(bool immediate) {
        auto fib = freeFibers.popHead();
        assert (!fib.flag!"CALLBACK_SET");
        fib.flag!"IMMEDIATE" = immediate;
        fib.flag!"CALLBACK_SET" = true;
        fib.state = ReactorFiber.State.Sleeping;
        fib._prevId = FiberId.invalid;
        fib._nextId = FiberId.invalid;
        fib._owner = null;
        fib.params.flsBlock.reset();
        resumeFiber(fib);
        return fib;
    }

    void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            end = start = TscTimePoint.now;

            while (scheduledFibers.empty) {
                //enterCriticalSection();
                //scope(exit) leaveCriticalSection();
                end = TscTimePoint.now;
                /*
                   Since we've updated "end" before calling the timers, these timers won't count as idle time, unless....
                   after running them the scheduledFibers list is still empty, in which case they do.
                 */
                if( runTimedCallbacks(end) )
                    continue;

                // We only reach here if runTimedCallbacks did nothing, in which case "end" is recent enough
                Duration sleepDuration = timeQueue.timeTillNextEntry(end);
                if( idleCallbacks.length==1 ) {
                    //DEBUG!"idle callback called with duration %s"(sleepDuration);
                    idleCallbacks[0](sleepDuration);
                } else if ( idleCallbacks.length>1 ) {
                    foreach(cb; idleCallbacks) {
                        cb(ZERO_DURATION);
                    }
                } else {
                    DEBUG!"Idle fiber called with no callbacks, sleeping %sus"(sleepDuration.total!"usecs");
                    import core.thread; Thread.sleep(sleepDuration);
                }
            }
            idleCycles += end.diff!"cycles"(start);
            switchToNext();
        }
    }

    bool runTimedCallbacks(TscTimePoint now = TscTimePoint.now) {
        // Timer callbacks are not allowed to sleep
        auto criticalSectionContainer = criticalSection();

        bool ret;

        TimedCallback* callback;
        while ((callback = timeQueue.pop(now)) !is null) {
            callback.closure();
            if( callback.intervalCycles==0 )
                timedCallbacksPool.release(callback);
            else
                rescheduleRecurringTimer(callback);

            ret = true;
        }

        return ret;
    }

    void rescheduleRecurringTimer(TimedCallback* callback) nothrow @safe @nogc {
        ulong cycles = TscTimePoint.now.cycles + callback.intervalCycles;
        cycles -= cycles % callback.intervalCycles;
        callback.timePoint = TscTimePoint(cycles);

        timeQueue.insert(callback);
    }

    ExcBuf* prepThrowInFiber(FiberHandle fHandle, bool updateBT, bool specialOkay = false) nothrow @safe @nogc {
        ReactorFiber* fib = fHandle.get();
        ASSERT!"Cannot throw in the reactor's own fibers"( !fib.flag!"SPECIAL" || specialOkay );
        if( fib is null ) {
            WARN!"Failed to throw exception in fiber %s which is no longer valid"(fHandle);
            return null;
        }

        if( fib.flag!"HAS_EXCEPTION" ) {
            ERROR!"Tried to throw exception in fiber %s which already has an exception pending"(fHandle);
            return null;
        }

        fib.flag!"HAS_EXCEPTION" = true;
        fib.flag!"EXCEPTION_BT" = updateBT;
        return &fib.params.currExcBuf;
    }

    void forwardExceptionToMain(Throwable ex) nothrow @trusted @nogc {
        ExcBuf* fiberEx = prepThrowInFiber(FiberHandle(mainFiber), false, true);

        if( fiberEx is null )
            return;

        fiberEx.set(ex);
        resumeSpecialFiber(mainFiber);
        as!"nothrow"(&theReactor.switchToNext);
        assert(false, "switchToNext on dead system returned");
    }


    void mainloop() {
        assert (_open);
        assert (!_running);
        assert (thisFiber is null);

        _running = true;
        GC.disable();
        scope(exit) GC.enable();

        thisFiber = mainFiber;
        scope(exit) thisFiber = null;

        while (_running) {
            runTimedCallbacks();
            switchToNext();
        }
    }
}

// Expose the conversion to/from ReactorFiber only to the reactor package
package ReactorFiber* to(T : ReactorFiber*)(FiberId fid) nothrow @trusted @nogc {
    if (!fid.isValid)
        return null;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    return &theReactor.allFibers[fid.value];
}

package FiberId to(T : FiberId)(const ReactorFiber* rfp) nothrow @trusted @nogc {
    if (rfp is null)
        return FiberId.invalid;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    auto idx = rfp - theReactor.allFibers.arr.ptr;
    DBG_ASSERT!"Reactor fiber pointer not pointing to fibers pool: base %s ptr %s idx %s"(idx>=0 && idx<theReactor.allFibers.arr.length,
            &theReactor.allFibers.arr[0], rfp, idx);
    return FiberId( cast(ushort)idx );
}

__gshared Reactor theReactor;

version (unittest) {
    void testWithReactor(void delegate() dg) {
        theReactor.setup();
        scope(exit) theReactor.teardown();
        bool succ = false;

        void wrapper() {
            scope(success) {
                succ = true;
                theReactor.stop();
            }
            dg();
        }

        theReactor.spawnFiber(&wrapper);
        theReactor.start();
        assert (succ);
    }
}


unittest {
    import std.stdio;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    static void fibFunc(string name) {
        foreach(i; 0 .. 10) {
            writeln(name);
            theReactor.yieldThisFiber();
        }
        theReactor.stop();
    }

    theReactor.spawnFiber(&fibFunc, "hello");
    theReactor.spawnFiber(&fibFunc, "world");
    theReactor.start();
}

unittest {
    // Test simple timeout
    import std.stdio;
    import mecca.reactor.fd;

    theReactor.setup();
    scope(exit) theReactor.teardown();
    FD.openReactor();

    uint counter;
    TscTimePoint start;

    void fiberFunc(Duration duration) {
        INFO!"Fiber %s sleeping for %s"(theReactor.runningFiberHandle, duration);
        theReactor.sleep(duration);
        auto now = TscTimePoint.now;
        counter++;
        INFO!"Fiber %s woke up after %s, overshooting by %s counter is %s"(theReactor.runningFiberHandle, now - start,
                (now-start) - duration, counter);
    }

    void ender() {
        INFO!"Fiber %s ender is sleeping for 250ms"(theReactor.runningFiberHandle);
        theReactor.sleep(dur!"msecs"(250));
        INFO!"Fiber %s ender woke up"(theReactor.runningFiberHandle);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(10));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(100));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(150));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(20));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(30));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(200));
    theReactor.spawnFiber(&ender);

    start = TscTimePoint.now;
    theReactor.start();
    auto end = TscTimePoint.now;
    INFO!"UT finished in %s"(end - start);

    assert(counter == 6, "Not all fibers finished");
}

unittest {
    // Test suspending timeout
    import std.stdio;
    import mecca.reactor.fd;

    theReactor.setup();
    scope(exit) theReactor.teardown();
    FD.openReactor();

    void fiberFunc() {
        bool thrown;

        try {
            theReactor.suspendThisFiber( Timeout(dur!"msecs"(4)) );
        } catch(ReactorTimeout ex) {
            thrown = true;
        }

        assert(thrown);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc);
    theReactor.start();
}

unittest {
    // Test suspending timeout
    import std.stdio;
    import mecca.reactor.fd;

    theReactor.setup();
    scope(exit) theReactor.teardown();
    FD.openReactor();

    void fiberFunc() {
        TimerHandle[8] handles;
        Duration[8] timeouts = [
            dur!"msecs"(2),
            dur!"msecs"(200),
            dur!"msecs"(6),
            dur!"msecs"(120),
            dur!"msecs"(37),
            dur!"msecs"(40),
            dur!"msecs"(133),
            dur!"msecs"(8),
        ];

        ubyte a;

        static void timer(ubyte* a, TimerHandle* handle, ubyte bit) {
            (*a) |= 1<<bit;

            (*handle) = TimerHandle.init;
        }

        foreach(ubyte i, duration; timeouts) {
            handles[i] = theReactor.registerTimer!timer( Timeout(duration), &a, &handles[i], i );
        }

        uint recurringCounter;
        static void recurringTimer(uint* counter) {
            (*counter)++;
        }

        TimerHandle recurringTimerHandle = theReactor.registerRecurringTimer!recurringTimer( dur!"msecs"(7), &recurringCounter );

        theReactor.sleep(dur!"msecs"(3));

        // Cancel one expired timeout and one yet to happen
        theReactor.cancelTimer(handles[0]);
        theReactor.cancelTimer(handles[6]);

        // Wait for all timers to run
        theReactor.sleep(dur!"msecs"(200));

        assert(a == 0b1011_1111);
        ASSERT!"Recurring timer should run 29 times, ran %s"(recurringCounter==29, recurringCounter); // 203ms / 7

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc);
    theReactor.start();
}

unittest {
    import mecca.reactor.sync.event;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    Event evt1, evt2;

    class TheException : Exception {
        this() {
            super("The Exception");
        }
    }

    void fib2() {
        // Release 1
        evt1.set();

        try {
            // Wait for 1 to do its stuff
            evt2.wait();

            assert( false, "Exception not thrown" );
        } catch( Exception ex ) {
            assert( ex.msg == "The Exception" );
        }

        theReactor.stop();
    }

    void fib1() {
        auto fib = theReactor.spawnFiber(&fib2);

        evt1.wait();

        theReactor.throwInFiber(fib, new TheException);
        evt2.set();
    }

    theReactor.spawnFiber(&fib1);
    theReactor.start();
}

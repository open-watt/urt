module urt.algorithm;

import urt.meta : AliasSeq;
import urt.traits : is_some_function, lvalue_of, Parameters, ReturnType, Unqual;
import urt.util : swap;

version = SmallSize;

nothrow @nogc:


auto compare(T, U)(auto ref T a, auto ref U b)
{
    static if (__traits(compiles, a.opCmp(b)))
        return a.opCmp(b);
    else static if (__traits(compiles, b.opCmp(a)))
        return -b.opCmp(a);
    else static if (is(T : A[], A) || is(U : B[], B))
    {
        import urt.traits : is_primitive;

        static assert(is(T : A[], A) && is(U : B[], B), "TODO: compare an array with a not-array?");

        auto ai = a.ptr;
        auto bi = b.ptr;

        // first compere the pointers...
        if (ai !is bi)
        {
            size_t len = a.length < b.length ? a.length : b.length;
            static if (is_primitive!A)
            {
                // compare strings
                foreach (i; 0 .. len)
                {
                    if (ai[i] != bi[i])
                        return ai[i] < bi[i] ? -1 : 1;
                }
            }
            else
            {
                // compare arrays
                foreach (i; 0 .. len)
                {
                    if (auto cmp = compare(ai[i], bi[i]))
                        return cmp;
                }
            }
        }

        // finally, compare the lengths
        if (a.length == b.length)
            return 0;
        return a.length < b.length ? -1 : 1;
    }
    else
        return a < b ? -1 : (a > b ? 1 : 0);
}

size_t binary_search(Pred)(const void[] arr, size_t stride, const void* value, auto ref Pred pred)
    if (is_some_function!Pred && is(ReturnType!Pred == int) && is(Parameters!Pred == AliasSeq!(const void*, const void*)))
{
    const void* p = arr.ptr;
    size_t low = 0;
    size_t high = arr.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;

        // should we chase the first in a sequence of same values?
        int cmp = pred(p + mid*stride, value);
        if (cmp < 0)
            low = mid + 1;
        else
            high = mid;
    }
    if (low == arr.length)
        return arr.length;
    if (pred(p + low*stride, value) == 0)
        return low;
    return arr.length;
}

size_t binary_search(alias pred = void, T, Cmp...)(T[] arr, auto ref Cmp cmp_args)
    if (!is(Unqual!T == void))
{
    static if (is(pred == void))
        static assert (cmp_args.length == 1, "binary_search without a predicate requires exactly one comparison argument");

    T* p = arr.ptr;
    size_t low = 0;
    size_t high = arr.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;
        static if (is(pred == void))
        {
            // should we chase the first in a sequence of same values?
            if (p[mid] < cmp_args[0])
                low = mid + 1;
            else
                high = mid;
        }
        else
        {
            // should we chase the first in a sequence of same values?
            int cmp = pred(p[mid], cmp_args);
            if (cmp < 0)
                low = mid + 1;
            else
                high = mid;
        }
    }
    if (low == arr.length)
        return arr.length;
    static if (is(pred == void))
    {
        if (p[low] == cmp_args[0])
            return low;
    }
    else
    {
        if (pred(p[low], cmp_args) == 0)
            return low;
    }
    return arr.length;
}


void qsort(alias pred = void, T)(T[] arr) pure
{
    version (SmallSize)
        enum use_small_size_impl = true;
    else
        enum use_small_size_impl = false;

    if (!__ctfe && use_small_size_impl)
    {
        static if (is(pred == void))
            static if (__traits(compiles, lvalue_of!T.opCmp(lvalue_of!T)))
                static int compare(const void* a, const void* b) pure nothrow @nogc
                    => (*cast(const T*)a).opCmp(*cast(const T*)b);
            else
                static int compare(const void* a, const void* b) pure nothrow @nogc
                    => *cast(const T*)a < *cast(const T*)b ? -1 : *cast(const T*)a > *cast(const T*)b ? 1 : 0;
        else
            static int compare(const void* a, const void* b) pure nothrow @nogc
                => pred(*cast(T*)a, *cast(T*)b);

        qsort(arr[], T.sizeof, &compare, (void* a, void* b) pure nothrow @nogc {
                  swap(*cast(T*)a, *cast(T*)b);
              });
    }
    else
    {
        T* p = arr.ptr;
        if (arr.length > 1)
        {
            size_t pivotIndex = arr.length / 2;
            T* pivot = p + pivotIndex;

            size_t i = 0;
            size_t j = arr.length - 1;

            while (i <= j)
            {
                static if (is(pred == void))
                {
                    while (p[i] < *pivot) i++;
                    while (p[j] > *pivot) j--;
                }
                else
                {
                    while (pred(p[i], *pivot) < 0) i++;
                    while (pred(p[j], *pivot) > 0) j--;
                }
                if (i <= j)
                {
                    swap(p[i], p[j]);
                    i++;
                    j--;
                }
            }

            if (j > 0)
                qsort!pred(p[0 .. j + 1]);
            if (i < arr.length)
                qsort!pred(p[i .. arr.length]);
        }
    }
}

unittest
{
    struct S
    {
        int x;
        int opCmp(ref const S rh) pure const nothrow @nogc
            => x < rh.x ? -1 : x > rh.x ? 1 : 0;
    }

    int[5] arr = [3, 100, -1, 17, 30];
    qsort(arr);
    assert(arr == [-1, 3, 17, 30, 100]);

    S[5] arr2 = [ S(3), S(100), S(-1), S(17), S(30) ];
    qsort(arr2);
    foreach (i, ref s; arr2)
        assert(s.x == arr[i]);

    // test binary search, not that they're sorted...
    assert(binary_search(arr, -1) == 0);
    assert(binary_search!(s => s.x < 30 ? -1 : s.x > 30 ? 1 : 0)(arr2) == 3);
    assert(binary_search(arr, 0) == arr.length);

    int[10] rep = [1, 10, 10, 10, 10, 10, 10, 10, 10, 100];
    assert(binary_search(rep, 10) == 1);
}


private:

version (SmallSize)
{
    // just one generic implementation to minimise the code...
    // kinda slow though... look at all those multiplies!
    // maybe there's some way to make this faster :/
    void qsort(void[] arr, size_t element_size, int function(const void* a, const void* b) pure nothrow @nogc compare, void function(void* a, void* b) pure nothrow @nogc swap) pure
    {
        void* p = arr.ptr;
        size_t length = arr.length / element_size;
        if (length > 1)
        {
            size_t pivotIndex = length / 2;
            void* pivot = p + pivotIndex*element_size;

            size_t i = 0;
            size_t j = length - 1;

            while (i <= j)
            {
                while (compare(p + i*element_size, pivot) < 0) i++;
                while (compare(p + j*element_size, pivot) > 0) j--;
                if (i <= j)
                {
                    swap(p + i*element_size, p + j*element_size);
                    i++;
                    j--;
                }
            }

            if (j > 0)
                qsort(p[0 .. (j + 1)*element_size], element_size, compare, swap);
            if (i < length)
                qsort(p[i*element_size .. length*element_size], element_size, compare, swap);
        }
    }
}

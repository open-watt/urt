module urt.map;

import urt.lifetime;
import urt.kvp;
import urt.mem.allocator;
import urt.util;

nothrow @nogc:


template DefCmp(T)
{
    import urt.algorithm : compare;

//    alias DefCmp(U) = compare!(T, U); // TODO: this should work...

    ptrdiff_t DefCmp(U)(ref const T a, ref const U b)
        => compare(a, b);
}


alias Map(K, V) = AVLTree!(K, V);

struct AVLTree(K, V, alias Pred = DefCmp!K, Allocator = Mallocator)
{
@nogc:
    alias KeyType = K;
    alias ValueType = V; // TODO: . ElementType
    alias KeyValuePair = KVP!(K, V);

    // TODO: copy ctor, move ctor, etc...

//    this(KeyValuePair[] arr)
//    {
//        foreach (ref kvp; arr)
//            insert(kvp.key, kvp.value);
//    }

    ~this() nothrow
    {
        clear();
    }

    size_t length() const nothrow
        => _num_modes;
    bool empty() const nothrow
        => _num_modes == 0;

    void clear() nothrow
    {
        destroy(_root);
        _root = null;
    }

    V* insert(_K, _V)(auto ref _K key, auto ref _V val)
    {
        if (get(key))
            return null;
        return &replace(forward!key, forward!val);
    }

/+
  V& insert(K &&key, V &&val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(key), std::move(val));
  }
  V& insert(const K &key, V &&val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(key, std::move(val));
  }
  V& insert(K &&key, const V &val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(key), val);
  }
  V& insert(const K &key, const V &val)
  {
    if (get(key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(key, val);
  }

  V& insert(KVP<K, V> &&kvp)
  {
    if (get(kvp.key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(std::move(kvp));
  }
  V& insert(const KVP<K, V> &kvp)
  {
    if (get(kvp.key))
      EPTHROW_ERROR(Result::AlreadyExists, "Key already exists");
    return replace(kvp);
  }

  V& tryInsert(const K &key, const V &val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, val);
  }

  V& tryInsert(const K &key, V &&val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, std::move(val));
  }

  V& tryInsert(K &&key, const V &val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), val);
  }

  V& tryInsert(K &&key, V &&val)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), std::move(val));
  }

  V& tryInsert(const K &key, Delegate<V()> lazy)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(key, lazy());
  }

  V& tryInsert(K &&key, Delegate<V()> lazy)
  {
    V* v = get(key);
    if (v)
      return *v;
    return replace(std::move(key), lazy());
  }

  V& tryInsert(const KVP<K,V> &kvp)
  {
    V* v = get(kvp.key);
    if (v)
      return *v;
    return replace(kvp.key, kvp.value);
  }

  V& tryInsert(KVP<K, V> &&kvp)
  {
    V* v = get(kvp.key);
    if (v)
      return *v;
    return replace(std::move(kvp.key), std::move(kvp.value));
  }
+/

    ref V replace(_K, _V)(auto ref _K key, auto ref _V val)
    {
        Node* node = cast(Node*)Allocator.instance.alloc(Node.sizeof);
        emplace(&node.kvp, forward!key, forward!val);
        node._base.left = node._base.right = null;
        node._base.height = 1;
        node._base.key_offset = Node.kvp.offsetof + KVP!(K, V).key.offsetof;
        _root = insert(_root, node);
        return node.kvp.value;
    }

/+
  V& replace(K &&key, V &&val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(key), std::move(val));
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }
  V& replace(const K &key, V &&val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(key, std::move(val));
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }
  V& replace(K &&key, const V &val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(key), val);
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }
  V& replace(const K &key, const V &val)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(key, val);
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }

  V& replace(KVP<K, V> &&kvp)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(std::move(kvp));
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }
  V& replace(const KVP<K, V> &kvp)
  {
    Node* node = Allocator::get()._alloc();
    epscope(fail) { Allocator::get()._free(node); };
    epConstruct(&node.kvp) KVP<K, V>(kvp);
    node.left = node.right = null;
    node.height = 1;
    _root = insert(_root, node);
    return node.kvp.value;
  }
+/

    void remove(_K)(ref const _K key)
    {
        _root = delete_node(_root, key);
    }

    inout(V)* get(_K)(ref const _K key) inout
    {
        inout(Node)* n = find(_root, key);
        return n ? &n.kvp.value : null;
    }

    ref inout(V) opIndex(_K)(ref const _K key) inout
    {
        inout(V)* pV = get(key);
        assert(pV, "Element not found");
        return *pV;
    }

    // TODO: should an assignment expression return anything? I think not...
    void opIndexAssign(_V)(auto ref _V value, ref const K key)
    {
        replace(key, forward!value);
    }

    inout(V)* opBinaryRight(string op : "in", _K)(ref const _K key) inout
        => get(key);

    bool exists(_K)(ref const _K key) const
        => get(key) != null;
/+
    AVLTree<K, V>& operator =(const AVLTree<K, V> &rh)
    {
        if (this != &rh)
        {
            this.~AVLTree();
            epConstruct(this) AVLTree<K, V>(rh);
        }
        return *this;
    }

    AVLTree<K, V>& operator =(AVLTree<K, V> &&rval)
    {
        if (this != &rval)
        {
            this.~AVLTree();
            epConstruct(this) AVLTree<K, V>(std::move(rval));
        }
        return *this;
    }
+/

    // TODO: why don't the const overloads work properly?
    auto keys() const nothrow
        => Range!(IterateBy.Keys, true)(_root);
    auto values() nothrow
        => Range!(IterateBy.Values)(_root);
    auto values() const nothrow
        => Range!(IterateBy.Values, true)(_root);

    auto opIndex() nothrow
        => Range!(IterateBy.KVP)(_root);
    auto opIndex() const nothrow
        => Range!(IterateBy.KVP, true)(_root);

    import urt.string.format : FormatArg, formatValue;
    ptrdiff_t toString()(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        if (buffer.ptr is null)
        {
            // count the buffer size
            size_t size = 2, comma = 0;
            foreach (kvp; this)
            {
                size += comma;
                comma = 1;
                ptrdiff_t len = formatValue(kvp.key, buffer, format, formatArgs);
                if (len < 0)
                    return len;
                size += len + 1;
                len = formatValue(kvp.value, buffer, format, formatArgs);
                if (len < 0)
                    return len;
                size += len;
            }
            return size;
        }

        if (buffer.length < 2)
            return -1;
        buffer[0] = '{';

        size_t offset = 1;
        bool add_comma = false;
        foreach (kvp; this)
        {
            if (add_comma)
            {
                if (offset >= buffer.length)
                    return -1;
                buffer[offset++] = ',';
            }
            else
                add_comma = true;
            ptrdiff_t len = formatValue(kvp.key, buffer[offset .. $], format, formatArgs);
            if (len < 0)
                return len;
            offset += len;
            if (offset >= buffer.length)
                return -1;
            buffer[offset++] = ':';
            len = formatValue(kvp.value, buffer[offset .. $], format, formatArgs);
            if (len < 0)
                return len;
            offset += len;
        }

        if (offset >= buffer.length)
            return -1;
        buffer[offset++] = '}';
        return offset;
    }

    ptrdiff_t fromString()(const(char)[] s)
    {
        assert(false, "TODO");
    }

private:
nothrow:
    alias Node = AVLTreeNode!(K, V);

    size_t _num_modes = 0;
    Node* _root = null;

    static ptrdiff_t compare_node(const void* a, const void* b) pure
        => Pred(*cast(K*)a, *cast(K*)b);

    static void free_node(void* p)
    {
        Allocator.instance.freeT(cast(Node*)p);
    }

    static inout(Node)* find(_K)(inout(Node)* n, ref const _K key) pure
        => cast(inout(Node)*)find_node(n.base, (a, b) => Pred(*cast(K*)a, *cast(_K*)b), &key);

    void destroy(Node* n)
    {
        _num_modes -= destroy_node(n.base, &free_node);
    }

    Node* insert(Node* n, Node* newnode)
    {
        return cast(Node*)insert_node(n.base, newnode.base, _num_modes,
                                      &compare_node,
                                      &free_node);
    }

    Node* delete_node(_K)(Node* _pRoot, ref const _K key)
    {
        return cast(Node*).delete_node(_pRoot.base, &key, _num_modes, &compare_node, (void* from, void* to) {
            // Copy the in-order successor's data to this Node
            (cast(Node*)to).kvp.key = (cast(Node*)from).kvp.key; // we can't move the key, because delete_node still needs to be able to find it
            (cast(Node*)to).kvp.value = (cast(Node*)from).kvp.value.move;
        }, &free_node);
    }

//    static Node* clone(Node* pOld)
//    {
//        if (!pOld)
//            return null;
//
//        Node* pNew = Allocator.instance.allocT!Node(pOld.kvp);
//        pNew.height = pOld.height;
//        pNew.left = clone(pOld.left);
//        pNew.right = clone(pOld.right);
//        return pNew;
//    }

public:
    enum IterateBy
    {
        Keys,
        Values,
        KVP
    }
    struct Range(IterateBy type, bool const_ = false)
    {
    nothrow @nogc:
        import urt.array;

        static if (const_)
            alias PN = const(Node)*;
        else
            alias PN = Node*;

        PN n;
        Array!(PN) stack;

        this(PN root)
        {
            if (root)
            {
                stack.reserve(root.height - 1);
                n = getLeft(root);
            }
        }

        bool empty() const pure
            => n is null;

        static if (type == IterateBy.Keys)
        {
            ref const(K) front() const pure
                => n.kvp.key;
        }
        else
        {
            static if (const_)
            {
                ref auto front() const
                {
                    static if (type == IterateBy.Values)
                        return n.kvp.value;
                    else
                    {
                        struct KV
                        {
                            const PN n;
                            ref const(K) key() @property const pure
                                => n.kvp.key;
                            ref const(V) value() @property const pure
                                => n.kvp.value;
                        }
                        return KV(n);
                    }
                }
            }
            else
            {
                ref auto front()
                {
                    static if (type == IterateBy.Values)
                        return n.kvp.value;
                    else
                    {
                        struct KV
                        {
                            PN n;
                            ref const(K) key() @property const pure
                                => n.kvp.key;
                            ref inout(V) value() @property inout pure
                                => n.kvp.value;
                        }
                        return KV(n);
                    }
                }
            }
        }

        void popFront()
        {
            if (n.right)
                n = getLeft(n.right);
            else
                n = !stack.empty ? stack.popBack() : null;
        }

    private:
        PN getLeft(PN node)
        {
            while (node.left)
            {
                stack ~= node;
                node = node.left;
            }
            return node;
        }
    }
}
struct BaseNode
{
    BaseNode* left, right;
    ushort key_offset;
    ushort height;
}

struct AVLTreeNode(K, V)
{
nothrow @nogc:

    alias _base this;

    BaseNode _base;
    KVP!(K, V) kvp;

    inout(BaseNode)* base() inout pure @property
        => &_base;

    inout(AVLTreeNode)* left() inout pure @property
        => cast(inout(AVLTreeNode)*)_base.left;
    void left(AVLTreeNode* node) pure @property
    {
        _base.left = node.base;
    }
    inout(AVLTreeNode)* right() inout pure @property
        => cast(inout(AVLTreeNode)*)_base.right;
    void right(AVLTreeNode* node) pure @property
    {
        _base.right = node.base;
    }

    this() @disable;

//    this(AVLTreeNode rh)
//    {
//        left = rh.left;
//        right = rh.right;
//        kvp = rh.kvp.move;
//        height = rh.height;
//    }
    this(ref AVLTreeNode rh)
    {
        left = rh.left;
        right = rh.right;
        kvp = rh.kvp;
        _base.height = rh._base.height;
    }

    ref AVLTreeNode opAssign(ref AVLTreeNode rh)
    {
        this.destroy();
        emplace(&this, rh);
        return this;
    }

    ref AVLTreeNode opAssign(AVLTreeNode rh)
    {
        this.destroy();
        emplace(&this, rh.move);
        return this;
    }
}


unittest
{
    alias TestAVLTree = AVLTree!(int, int);
    alias TestAVLTreeCIP = AVLTree!(int, const(int)*);

    static assert(is(TestAVLTree.KeyType == int), "IndexType failed!");

    static assert(is(TestAVLTree.ValueType == int), "ElementType failed!");
    static assert(is(TestAVLTreeCIP.ValueType == const(int)*), "ElementType failed!");

    // Basic insertion and retrieval
    {
        TestAVLTree map;
        assert(map.empty());
        assert(map.length == 0);

        map.insert(1, 10);
        assert(!map.empty());
        assert(map.length == 1);
        assert(map.get(1) !is null && *map.get(1) == 10);
        assert(map[1] == 10);
        assert(1 in map);
        assert(map.exists(1));

        map.insert(2, 20);
        assert(map.length == 2);
        assert(map.get(2) !is null && *map.get(2) == 20);
        assert(map[2] == 20);
        assert(2 in map);

        // Test inserting duplicate key (should be ignored)
        auto pVal = map.insert(1, 11);
        assert(pVal is null); // Insert should fail if key exists
        assert(map.length == 2);
        assert(map[1] == 10); // Value should remain unchanged

        // Test non-existent key
        assert(map.get(3) is null);
        assert(3 !in map);
        assert(!map.exists(3));
    }

    // Replace and opIndexAssign
    {
        TestAVLTree map;
        map.replace(5, 50);
        assert(map.length == 1);
        assert(map[5] == 50);

        map.replace(5, 55); // Replace existing key
        assert(map.length == 1);
        assert(map[5] == 55);

        map[6] = 60; // opIndexAssign for new key
        assert(map.length == 2);
        assert(map[6] == 60);

        map[6] = 66; // opIndexAssign for existing key
        assert(map.length == 2);
        assert(map[6] == 66);
    }

    // Removal
    {
        TestAVLTree map;
        map.insert(10, 100);
        map.insert(5, 50);
        map.insert(15, 150);
        map.insert(3, 30);
        map.insert(7, 70);
        map.insert(12, 120);
        map.insert(17, 170);
        assert(map.length == 7);

        map.remove(5); // Remove node with two children
        assert(map.length == 6);
        assert(map.get(5) is null);
        assert(map.exists(3));
        assert(map.exists(7));

        map.remove(3); // Remove leaf node
        assert(map.length == 5);
        assert(map.get(3) is null);

        map.remove(17); // Remove leaf node
        assert(map.length == 4);
        assert(map.get(17) is null);

        map.remove(10); // Remove root node
        assert(map.length == 3);
        assert(map.get(10) is null);
        assert(map.exists(7));
        assert(map.exists(15));
        assert(map.exists(12));

        map.remove(15);
        assert(map.length == 2);
        assert(map.get(15) is null);

        map.remove(7);
        assert(map.length == 1);
        assert(map.get(7) is null);

        map.remove(12);
        assert(map.length == 0);
        assert(map.empty());
        assert(map.get(12) is null);

        // Remove non-existent key
        map.remove(100);
        assert(map.length == 0);
        assert(map.empty());
    }

    // Clear
    {
        TestAVLTree map;
        map.insert(1, 1);
        map.insert(2, 2);
        assert(map.length == 2);
        map.clear();
        assert(map.length == 0);
        assert(map.empty());
        assert(map.get(1) is null);
        assert(map.get(2) is null);
    }

    // Iteration (range)
    {
        TestAVLTree map;
        map.insert(3, 30);
        map.insert(1, 10);
        map.insert(2, 20);
        map.insert(4, 40);

        // Iterate key-value pairs
        int sumKeys = 0, sumValues = 0, count = 0;
        foreach (kv; map)
        {
            sumKeys += kv.key;
            sumValues += kv.value;
            count++;
        }
        assert(count == 4);
        assert(sumKeys == 1 + 2 + 3 + 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        // Iterate const key-value pairs
        ref const cmap = map;
        sumKeys = sumValues = count = 0;
        foreach (kv; cmap)
        {
            sumKeys += kv.key;
            sumValues += kv.value;
            count++;
        }
        assert(count == 4);
        assert(sumKeys == 1 + 2 + 3 + 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        // Iterate keys only
        sumKeys = 0, count = 0;
        foreach (v; map.keys)
        {
            sumKeys += v;
            count++;
        }
        assert(count == 4);
        assert(sumKeys == 1 + 2 + 3 + 4);

        // Iterate values only
        sumValues = 0, count = 0;
        foreach (v; map.values)
        {
            sumValues += v;
            count++;
        }
        assert(count == 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        // Iterate const values only
        sumValues = 0, count = 0;
        foreach (v; cmap.values)
        {
            sumValues += v;
            count++;
        }
        assert(count == 4);
        assert(sumValues == 10 + 20 + 30 + 40);

        // Test stopping iteration
        count = 0;
        foreach (k; map.keys)
        {
            count++;
            if (k == 2)
                break; // Stop when key is 2
        }
        assert(count == 2); // Should stop after 1 and 2
    }

    // Test with string keys
    {
        alias StringMap = AVLTree!(const(char)[], int);
        StringMap map;

        map.insert("banana", 1);
        map.insert("apple", 2);
        map.insert("cherry", 3);

        assert(map.length == 3);
        assert(map["apple"] == 2);
        assert(map["banana"] == 1);
        assert(map["cherry"] == 3);
        assert("banana" in map);
        assert("grape" !in map);

        map.remove("banana");
        assert(map.length == 2);
        assert("banana" !in map);
        assert(map["apple"] == 2);
        assert(map["cherry"] == 3);

        int count = 0;
        foreach (kv; map)
        {
            count++;
        }
        assert(count == 2);
    }
}


private:

alias CompFn = ptrdiff_t function(const void* a, const void* b) pure nothrow @nogc;
alias MoveFn = void function(void* from, void* to) nothrow @nogc;
alias DestroyFn = void function(void* a) nothrow @nogc;

inout(void)* node_key(inout(BaseNode)* n) pure
    => cast(inout(void)*)n + n.key_offset;

ushort height(const(BaseNode)* n) pure
{
    return n ? n.height : 0;
}

ushort max_height(const(BaseNode)* n) pure
{
    if (!n)
        return 0;
    if (n.left)
    {
        if (n.right)
            return max(n.left.height, n.right.height);
        else
            return n.left.height;
    }
    if (n.right)
        return n.right.height;
    return 0;
}

int get_balance(BaseNode* n) pure
{
    return n ? height(n.left) - height(n.right) : 0;
}

BaseNode* right_rotate(BaseNode* y) pure
{
    BaseNode* x = y.left;
    BaseNode* T2 = x.right;

    // Perform rotation
    x.right = y;
    y.left = T2;

    // Update heights
    y.height = cast(ushort)(max_height(y) + 1);
    x.height = cast(ushort)(max_height(x) + 1);

    // Return new root
    return x;
}

BaseNode* left_rotate(BaseNode* x) pure
{
    BaseNode* y = x.right;
    BaseNode* T2 = y.left;

    // Perform rotation
    y.left = x;
    x.right = T2;

    //  Update heights
    x.height = cast(ushort)(max_height(x) + 1);
    y.height = cast(ushort)(max_height(y) + 1);

    // Return new root
    return y;
}

BaseNode* rebalance(BaseNode* root) pure
{
    // If the tree had only one Node then return
    if (root is null)
        return null;

    // STEP 2: UPDATE HEIGHT OF THE CURRENT NODE
    root.height = cast(ushort)(max(height(root.left), height(root.right)) + 1);

    // STEP 3: GET THE BALANCE FACTOR OF THIS NODE (to check whether
    //  this Node became unbalanced)
    int balance = get_balance(root);

    // If this Node becomes unbalanced, then there are 4 cases

    // Left Left Case
    if (balance > 1 && get_balance(root.left) >= 0)
        return right_rotate(root);

    // Left Right Case
    if (balance > 1 && get_balance(root.left) < 0)
    {
        root.left = left_rotate(root.left);
        return right_rotate(root);
    }

    // Right Right Case
    if (balance < -1 && get_balance(root.right) <= 0)
        return left_rotate(root);

    // Right Left Case
    if (balance < -1 && get_balance(root.right) > 0)
    {
        root.right = right_rotate(root.right);
        return left_rotate(root);
    }

    return root;
}

inout(BaseNode)* find_node(inout(BaseNode)* n, CompFn pred, const void* key) pure
{
    if (n is null)
        return null;
    ptrdiff_t c = pred(node_key(n), key);
    if (c > 0)
        return find_node(n.left, pred, key);
    if (c < 0)
        return find_node(n.right, pred, key);
    return n;
}

size_t destroy_node(BaseNode* n, DestroyFn free_fun)
{
    if (n is null)
        return 0;

    size_t count = destroy_node(n.left, free_fun);
    count += destroy_node(n.right, free_fun);
    free_fun(n);
    return count + 1;
}

BaseNode* insert_node(BaseNode* n, BaseNode* newnode, ref size_t num_nodes, CompFn pred, DestroyFn free_fun)
{
    // 1.  Perform the normal BST rotation
    if (n is null)
    {
        ++num_nodes;
        return newnode;
    }

    ptrdiff_t c = pred(node_key(newnode), node_key(n));
    if (c < 0)
        n.left = insert_node(n.left, newnode, num_nodes, pred, free_fun);
    else if (c > 0)
        n.right = insert_node(n.right, newnode, num_nodes, pred, free_fun);
    else
    {
        newnode.left = n.left;
        newnode.right = n.right;
        newnode.height = n.height;

        free_fun(n);

        return newnode;
    }

    // 2. Update height of this ancestor Node
    n.height = cast(ushort)(max_height(n) + 1);

    // 3. get the balance factor of this ancestor Node to check whether
    //    this Node became unbalanced
    int balance = get_balance(n);

    // If this Node becomes unbalanced, then there are 4 cases

    if (balance > 1)
    {
        ptrdiff_t lc = pred(node_key(newnode), node_key(n.left));
        // Left Left Case
        if (lc < 0)
            return right_rotate(n);

        // Left Right Case
        if (lc > 0)
        {
            n.left = left_rotate(n.left);
            return right_rotate(n);
        }
    }

    if (balance < -1)
    {
        ptrdiff_t rc = pred(node_key(newnode), node_key(n.right));

        // Right Right Case
        if (rc > 0)
            return left_rotate(n);

        // Right Left Case
        if (rc < 0)
        {
            n.right = right_rotate(n.right);
            return left_rotate(n);
        }
    }

    // return the (unchanged) Node pointer
    return n;
}

BaseNode* delete_node(BaseNode* root, const void* key, ref size_t num_nodes, CompFn pred, MoveFn move_fun, DestroyFn free_fun)
{
    // STEP 1: PERFORM STANDARD BST DELETE

    if (root is null)
        return root;

    ptrdiff_t c = pred(node_key(root), key);

    // If the key to be deleted is smaller than the root's key,
    // then it lies in left subtree
    if (c > 0)
        root.left = delete_node(root.left, key, num_nodes, pred, move_fun, free_fun);

    // If the key to be deleted is greater than the root's key,
    // then it lies in right subtree
    else if (c < 0)
        root.right = delete_node(root.right, key, num_nodes, pred, move_fun, free_fun);

    // if key is same as root's key, then this is the Node
    // to be deleted
    else
        root = do_delete(root, num_nodes, pred, move_fun, free_fun);

    return rebalance(root);
}

BaseNode* do_delete(BaseNode* root, ref size_t num_nodes, CompFn pred, MoveFn move_fun, DestroyFn free_fun)
{
    // Node with only one child or no child
    if ((root.left is null) || (root.right is null))
    {
        BaseNode* temp = root.left ? root.left : root.right;

        // No child case
        if (temp is null)
        {
            temp = root;
            root = null;
        }
        else // One child case
        {
            // TODO: FIX THIS!!
            // this is copying the child node into the parent node because there is no parent pointer
            // DO: add parent pointer, then fix up the parent's child pointer to the child, and do away with this pointless copy!
            *root = (*temp).move; // Copy the tree structure (BaseNode fields)
            move_fun(temp, root); // Copy the key/value data
        }

        free_fun(temp);

        --num_nodes;
    }
    else
    {
        // Node with two children: we replace 'this' node with the next one in sequence...

        // get the in-order successor: the 'next' item is the far left node on the right hand side)
        BaseNode* next = root.right;
        while (next.left !is null) // find the leftmost leaf
            next = next.left;

        move_fun(next, root);

        // Delete the node we just shifted
        root.right = delete_node(root.right, node_key(next), num_nodes, pred, move_fun, free_fun);
    }

    return root;
}

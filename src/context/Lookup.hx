package context;

import core.ds.PersistentMap;
import core.ds.Hashtbl;

// Draft mechanical translation of haxe/src/context/lookup.ml; unvalidated.
interface Lookup<K, V> {
	public function add(key:K, value:V):Void;
	public function remove(key:K):Void;
	public function find(key:K):V;
	public function findOpt(key:K):Null<V>;
	public function iter(f:K->V->Void):Void;
	public function fold<A>(f:K->V->A->A, acc:A):A;
	public function mem(key:K):Bool;
	public function clear():Void;
}

class PmapLookup<K, V> implements Lookup<K, V> {
	var lut:PersistentMap<K, V>;

	public function new() lut = PersistentMap.empty();

	public function add(key:K, value:V):Void lut = lut.add(key, value);

	public function remove(key:K):Void lut = lut.remove(key);

	public function find(key:K):V return lut.find(key);

	public function findOpt(key:K):Null<V> return lut.findOpt(key);

	public function iter(f:K->V->Void):Void lut.iter(f);

	public function fold<A>(f:K->V->A->A, acc:A):A return lut.foldi(f, acc);

	public function mem(key:K):Bool return lut.mem(key);

	public function clear():Void lut = PersistentMap.empty();
}

class HashtblLookup<K, V> implements Lookup<K, V> {
	final lut:Hashtbl<K, V>;

	public function new() lut = new Hashtbl(0);

	public function add(key:K, value:V):Void lut.replace(key, value);

	public function remove(key:K):Void lut.remove(key);

	public function find(key:K):V return lut.find(key);

	public function findOpt(key:K):Null<V> return lut.findOpt(key);

	public function iter(f:K->V->Void):Void lut.iter(f);

	public function fold<A>(f:K->V->A->A, acc:A):A return lut.fold(f, acc);

	public function mem(key:K):Bool return lut.mem(key);

	public function clear():Void lut.clear();
}

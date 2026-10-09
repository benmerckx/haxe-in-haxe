package core.ds;

// Port of haxe/src/core/ds/priorityQueue.ml.
enum PriorityQueue<T> {
	Empty;
	Node(priority:Int, element:T, left:PriorityQueue<T>, right:PriorityQueue<T>);
}

class QueueIsEmpty {
	public function new() {}
}

class PriorityQueues {
	public static function empty<T>():PriorityQueue<T> {
		return Empty;
	}

	public static function insert<T>(queue:PriorityQueue<T>, priority:Int, element:T):PriorityQueue<T> {
		return switch (queue) {
			case Empty: Node(priority, element, Empty, Empty);
			case Node(currentPriority, currentElement, left, right):
				priority <= currentPriority ? Node(priority, element, insert(right, currentPriority, currentElement),
					left) : Node(currentPriority, currentElement, insert(right, priority, element), left);
		};
	}

	public static function removeTop<T>(queue:PriorityQueue<T>):PriorityQueue<T> {
		return switch (queue) {
			case Empty: throw new QueueIsEmpty();
			case Node(_, _, left, Empty): left;
			case Node(_, _, Empty, right): right;
			case Node(_, _, (left = Node(leftPriority, leftElement, _, _)), (right = Node(rightPriority, rightElement, _, _))):
				leftPriority <= rightPriority ? Node(leftPriority, leftElement, removeTop(left),
					right) : Node(rightPriority, rightElement, left, removeTop(right));
		};
	}

	public static function extract<T>(queue:PriorityQueue<T>):{priority:Int, element:T, queue:PriorityQueue<T>} {
		return switch (queue) {
			case Empty: throw new QueueIsEmpty();
			case Node(priority, element, _, _): {priority: priority, element: element, queue: removeTop(queue)};
		};
	}

	public static function isEmpty<T>(queue:PriorityQueue<T>):Bool {
		return switch (queue) {
			case Empty: true;
			case Node(_, _, _, _): false;
		};
	}

	public static function fold<T, Result>(queue:PriorityQueue<T>, callback:Result->Int->T->Result, initial:Result):Result {
		return switch (queue) {
			case Empty: initial;
			case Node(priority, element, left, Empty): fold(left, callback, callback(initial, priority, element));
			case Node(priority, element, Empty, right): fold(right, callback, callback(initial, priority, element));
			case Node(priority, element, (left = Node(leftPriority, _, _, _)), (right = Node(rightPriority, _, _, _))):
				var result = callback(initial, priority, element);
				leftPriority <= rightPriority ? fold(right, callback,
					fold(left, callback, result)) : fold(left, callback, fold(right, callback, result));
		};
	}

	public static function merge<T>(first:PriorityQueue<T>, second:PriorityQueue<T>):PriorityQueue<T> {
		return fold(first, function(queue, priority, element) return insert(queue, priority, element), second);
	}
}

package core.ds;

class OcamlInt32 {
	public static function ofString(value:String):Int return OcamlInt64.parse(value, 32).low;
}

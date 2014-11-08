package unihx._internal;
import haxe.macro.Expr;
import haxe.macro.Context.*;
import haxe.macro.Context;
import haxe.macro.Type;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using haxe.macro.TypedExprTools;
using Lambda;

class YieldGenerator
{
	var expr:TypedExpr;
	var usedVars:Map<Int, Map<ControlGraph,ControlGraph>>;

	// control flow graph
	var id = -1;
	var cfgs:Array<ControlGraph>;
	var current:ControlGraph;

	var tbool:Type;
	var tint:Type;
	var tdynamic:Type;

	var goto:TypedExpr;
	var gotoEnd:TypedExpr;
	var pos:Position;

	public function new(e:Expr)
	{
		var expr = typeExpr(macro { var __yield__:Dynamic = null; ${prepare(e)}; });
		switch(expr.expr)
		{
			case TBlock(bl):
				this.expr = bl[1];
			default: throw "assert";
		}
		trace(this.expr.toString());

		this.usedVars = new Map();
		this.cfgs = [];
		newFlow();
		this.current = cfgs[0];

		this.tbool = getType("Bool");
		this.tint = getType("Int");
		this.tdynamic = getType("Dynamic");

		this.goto = typeExpr( macro untyped __goto__ );
		this.gotoEnd = typeExpr( macro untyped __goto_end__ );
		this.pos = currentPos();
	}

	static function prepare(e:Expr):Expr
	{
		return switch(e) {
			case macro for ($v in $iterator) $block:
				var vname = switch(v.expr) {
					case EConst(CIdent(i)):
						i;
					case _: throw new Error('Identifier expected in for var declaration', v.pos);
				};
				return macro { var y_iterator = unihx._internal.Yield.getIterator($iterator); while (y_iterator.hasNext()) { var $vname = y_iterator.next(); ${prepare(block)} } };
			case macro __yield__:
				throw new Error("Reserved variable name: __yield__", e.pos);
			case macro @yield $something:
				return macro __yield__(${prepare(something)});
			case _:
				return e.map(prepare);
		}
	}

	public static function make(e:Expr):Expr
	{
		return new YieldGenerator(e).change();
	}

	public static function getIterator(e:Expr):Expr
	{
		var t = typeof(e);
		switch (t.follow())
		{
			case TAnonymous(a):
				if (a.get().fields.exists(function(cf) return cf.name == "hasNext" || cf.name == "next"))
					return e;
				else
					return macro $e.iterator();
			case TInst(t,_):
				if (t.get().findField('iterator') != null)
					return macro $e.iterator;
				else
					return e;
			case _:
				throw new Error('This expression has type $t, but an Iterable or Iterator was expected', e.pos);
		}
	}

	inline function newFlow()
	{
		var ret = { block:[], tryctx: current == null ? null : current.tryctx, id: ++id, next: null, cancelledTo: null };
		cfgs.push(ret);
		current = ret;
	}

	inline function setUsed(id:Int)
	{
		trace('setting used',id,current.id);
		var ret =usedVars[id];
		if (ret == null)
		{
			usedVars[id] = ret = new Map();
		}
		ret[current] = current;
	}

	function ensureNoYield(e:TypedExpr)
	{
		switch (e.expr)
		{
			case TCall( { expr:TLocal({ name:"__yield__" }) }, [e]):
				throw new Error('A @yield cannot be used as an expression', e.pos);
			case TLocal(v):
				setUsed(v.id);
			case TReturn(_):
				throw new Error("Cannot return inside a 'yield' context", e.pos);
			case _:
				e.iter(ensureNoYield);
		}
	}

	function mkGoto(id:Int):TypedExpr
	{
		return { expr: TCall(goto, [{ expr:TConst(TInt(id)), t:tint, pos:pos }]), t:tdynamic, pos:pos };
	}

	function mkGotoEnd(id:Int):TypedExpr
	{
		return { expr: TCall(gotoEnd, [{ expr:TConst(TInt(id)), t:tint, pos:pos }]), t:tdynamic, pos:pos };
	}

	function mkNothing():TypedExpr
	{
		return { expr: TBlock([]), t:tdynamic, pos:pos };
	}

	static function replace(from:TypedExpr, to:TypedExpr):Void
	{
		from.expr = to.expr;
		from.t = to.t;
		from.pos = to.pos;
	}

	function tryJoin(with:ControlGraph):Null<ControlGraph>
	{
		var ret = cfgs.pop();
		var cur = this.current = cfgs[cfgs.length-1];
		if (with.id != (ret.id - 1) || ret.tryctx != with.tryctx)
		{
			//cancel
			cfgs.push(ret);
			this.current = ret;
			return null;
		}

		ret.cancelledTo = with;
		this.id--;
		return ret;
	}

	function iter(e:TypedExpr)
	{
		switch(e.expr)
		{
			case TFunction(f):
				ensureNoYield(e);
				current.block.push(e);
			case TBlock(el):
				for (e in el)
					iter(e);
			case TIf(econd,eif,eelse):
				ensureNoYield(econd);

				// if(!something) goto end
				var cur = current;
				var endIf = mkNothing(),
						endElse = mkNothing();
				current.block.push( { expr: TIf(mk_not(econd), endIf, endElse), t:e.t, pos:e.pos } );
				{
					newFlow();
					var ifId = current.id;
					iter(eif);
					var j = tryJoin(cur);
					if (j != null) // can join
					{
						replace(endElse, mk_block(j.block));
					} else {
						replace(endElse, mkGoto(ifId));
					}
				}
				if (eelse != null)
				{
					newFlow();
					var elseId = current.id;
					iter(eelse);
					var j = tryJoin(cur);
					if (j != null) // can join
					{
						replace(endIf, mk_block(j.block));
					} else {
						replace(endIf, mkGoto(elseId));
					}
				}
			case TCall( { expr:TLocal({ name:"__yield__" }) }, [ev]):
				// return value
				ensureNoYield(ev);
				current.block.push( mk_assign( mk_this('value', ev.t, e.pos), ev, e.pos) );
				current.block.push( mkGotoEnd( current.id ) );
				// set to next
				current.block.push( { expr: TReturn( { expr:TConst(TBool(true)), t:tbool, pos:e.pos } ), t:tbool, pos:e.pos } );
				// break flow
				newFlow();
			case TReturn(_):
				throw new Error("Cannot return inside a 'yield' context", e.pos);

			case _:
				current.block.push(e);
		}
	}

	public function change():Expr
	{
		// create the control flow graph
		iter(expr);
		var used = new Map();
		{
			// get used vars - canonically
			for (k in usedVars.keys())
			{
				var cur = new Map();
				used[k] = cur;
				for (cfg in usedVars[k])
				{
					var cfg = cfg;
					while (cfg.cancelledTo != null)
						cfg = cfg.cancelledTo;
					cur[cfg.id] = true;
				}
			}
		}
		// get the variables that need to be changed
		var changed = new Map(),
				used = [ for (k in used.keys()) k => this.usedVars.get(k).count() ];
		trace(used);
		var external = [ for (ext in getLocalTVars()) ext.id => ext ];
		for (ext in external)
			used[ext.id] = 2; //mark as used
		function mapVars(e:TypedExpr):TypedExpr
		{
			return switch (e.expr) {
				case TLocal(v) if (used.get(v.id) > 1):
					changed[v.id] = v;
					mk_this(v.name + "__" + v.id, v.t ,e.pos);
				case TVar(v,eset) if (used.get(v.id) > 1):
					changed[v.id] = v;
					mk_assign( mk_this(v.name + "__" + v.id, v.t, e.pos), eset == null ? { expr: TConst(TNull), t:tdynamic, pos:e.pos } : mapVars(eset), e.pos);
				case _:
					e.map(mapVars);
			}
		}
		// create cases function
		var ecases = [];
		for (cfg in cfgs)
		{
			if (cfg.next != null)
			{
				//add mandatory goto next
				cfg.block.push(mkGoto(cfg.next));
			}
			//TODO tryctx
			var expr = getExprFromCg(mapVars(mk_block(cfg.block)));
			ecases.push({ values:[{ expr:EConst(CInt(cfg.id + "")), pos:pos }], expr: expr });
		}
		var eswitch = { expr:ESwitch(macro this.eip++, ecases, macro return false), pos:pos };
		trace(eswitch.toString());

		eswitch = macro while(true) $eswitch;

		var extChanged = [ for (ext in external) if (changed.exists(ext.id)) ext ];
		//create new() function
		var nf = {
			name: "new",
			kind: FFun({
				args: [ for (arg in extChanged) { name: arg.name, type: arg.t.toComplexType() } ],
				ret: null,
				expr: { expr:EBlock([ for (arg in extChanged) { var name = arg.name + "__" + arg.id; macro this.$name = $i{arg.name}; } ]), pos:pos }
			}),
			pos: pos
		};

		//create all changed fields
		var cls = macro class Something extends unihx._internal.YieldBase {
			override public function MoveNext():Bool
				$eswitch;
		};
		cls.fields.push(nf);
		for (changed in changed)
		{
			cls.fields.push({
				name:changed.name +"__" + changed.id,
				kind: FVar(changed.t.toComplexType(),null),
				pos: pos
			});
		}
		defineType(cls);
		return macro new Something();
	}

	function getExprFromCg(expr:TypedExpr):Expr
	{
		var ret = getTypedExpr(expr);
		function map(e:Expr):Expr
		{
			return switch (e) {
				case macro __goto__($i):
					// we can avoid this call if i == next
					macro this.eip = $i ;
				case macro __goto_end__($i):
					switch (i.expr)
					{
						case EConst(CInt(i)):
							var i = Std.parseInt(i);
							var theBlock = cfgs[i];
							if (theBlock.next == null)
								i = theBlock.id + 1;
							else
								i = theBlock.next;
							macro this.eip = $v{i};
						case _: throw "assert";
					}
				case _:
					e.map(map);
			}
		}
		return map(ret);
	}

	function mk_assign(e1:TypedExpr, e2:TypedExpr, pos:Position):TypedExpr
	{
		return { expr: TBinop(OpAssign, e1, e2), t: e1.t, pos:pos };
	}

	function mk_this(name:String, t:Type, pos:Position):TypedExpr
	{
		return { expr: TField({ expr:TConst(TThis), t:tdynamic, pos:pos }, FDynamic(name)), t: t, pos:pos };
	}

	static function mk_paren(e:TypedExpr):TypedExpr
	{
		return { expr: TParenthesis(e), t: e.t, pos: e.pos };
	}

	function mk_not(e:TypedExpr):TypedExpr
	{
		return { expr: TUnop(OpNot, false, mk_paren(e)), t: tbool, pos: e.pos };
	}

	function mk_block(el:Array<TypedExpr>):TypedExpr
	{
		return { expr: TBlock(el), t: tdynamic, pos: el.length > 0 ? el[0].pos : pos };
	}
}

typedef ControlGraph = { block:Array<TypedExpr>, tryctx:Null<Int>, next:Null<Int>, id:Int, cancelledTo:Null<ControlGraph> };

enum Next
{
	Next(id:Int);
	EndOf(id:Int);
}

require 'parser/current'
require 'unparser'
require 'ast'
require 'pp'

class NameTracker
  def initialize
    @var_hash = Hash.new { |h,k| h[k] = "var"+h.size.to_s }
    @spt_hash = Hash.new { |h,k| h[k] = "*vr"+h.size.to_s }
    @bar_hash = Hash.new { |h,k| h[k] = "&vr"+h.size.to_s }
    @sym_hash = Hash.new { |h,k| h[k] = ("sym"+h.size.to_s).to_sym }
    @str_hash = Hash.new { |h,k| h[k] = "str"+h.size.to_s }
    @flt_hash = Hash.new { |h,k| h[k] = 0.0+h.size.to_f }
    @int_hash = Hash.new { |h,k| h[k] = 0+h.size }
    @mapping = {
      :str => @str_hash,
      :sym => @sym_hash,
      :arg => @var_hash,
      :float => @flt_hash,
      :int => @int_hash,
      :var => @var_hash,
      :restarg => @spt_hash,
      :blockarg => @bar_hash
    }
  end
  def rename(type,id)
    @mapping[type][id]
  end
 
end

class ASTNormalizer
  attr_accessor :complexity
  def initialize
    @track = NameTracker.new
    @complexity = Hash.new { |h,k| h[k] = [] }
  end
  def update_complexity(type,val)
    @complexity[type].push(val)
  end
  def pretty_complexity
    measures, out = [:int, :str, :send, :var, :float, :sym], {}
    @complexity.select { |k,v| measures.include?(k) }.each { |k,v| out[k] = v.size }
    out
  end
  def rewrite_ast(ast)
    if ast.is_a? AST::Node
      type = ast.type
      case type
      # Variables
      when :lvar, :ivar, :gvar
        update_complexity(:var, ast.children.first)
        ast.updated(nil, ast.children.map { |child| @track.rename(:var, child) })
      # Assignment
      when :lvasgn, :gvasgn, :ivasgn, :cvasgn
        update_complexity(:assignment, ast.children.first)
        ast.updated(nil, ast.children.map.with_index { |child,i| 
          i == 0 ? @track.rename(:var,child) : rewrite_ast(child)
        }) 
      # Primatives
      when :int, :float, :str, :sym, :arg, :restarg, :blockarg
        update_complexity(type, ast.children.first)
        ast.updated(nil, ast.children.map { |child| @track.rename(type, child) })
      when :optarg
        update_complexity(:arg, ast.children.first)
        ast.updated(nil, ast.children.map.with_index { |child,i| 
          if i == 0 
            @track.rename(:var, child)
          else
            rewrite_ast(child)
          end 
        })
      # Method definitions
      when :def
        update_complexity(:def, ast.children.first)
        ast.updated(nil, ast.children.map.with_index { |child,i|
          i == 0 ? :method : rewrite_ast(child)
        }) 
      when :defs
        update_complexity(:def, ast.children.first)
        ast.updated(nil, ast.children.map.with_index { |child,i|
          i == 1 ? :method : rewrite_ast(child)
        })
      when :send
        update_complexity(:send, ast.children[1])
        ast.updated(nil, ast.children.map { |child| rewrite_ast(child) })
      else
        ast.updated(nil, ast.children.map { |child| rewrite_ast(child) })
      end
    else
      ast
    end
  end
end

class ASTProcess
  def store_nodes(ast, &block)
    if ast.is_a? Parser::AST::Node 
      type = ast.type
      yield ast, type
      ast.children.each do |child|
          store_nodes child, &block
      end
    end
  end
end

# str = IO.read(ARGV[0])
# ast = Parser::CurrentRuby.parse(str)
# modified = ASTNormalizer.new.rewrite_ast(ast)
# puts Unparser.unparse(modified)


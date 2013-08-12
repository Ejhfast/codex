require 'ruby_codex'
require 'mongoid'
require 'pp'

# Boilerplate until we set up a public API

Mongoid.load!("../test/mongoid.yaml", :development)
class ASTNodes; include Mongoid::Document; end
class ASTStats; include Mongoid::Document; end

codex = Codex.new(ASTNodes, ASTStats)

target = ARGV[0]

if target
  src = IO.read(target)
  ast = Parser::CurrentRuby.parse(src)
  messages = []
  last_line = 0
  codex.tree_walk(ast) do |node|
    q = codex.is_unlikely(node)
    if q.size > 0
      print "#{node.loc.line.to_s}:" rescue "ERR:"
      puts q.map { |x| x[:message] }.join("\n") if q.size > 0
      messages.concat q
    end
  end
  puts "#{messages.size.to_s} / #{src.split("\n").count.to_s}"
end
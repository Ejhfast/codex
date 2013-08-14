require 'ruby_codex'
require 'mongoid'
require 'pp'

# Boilerplate until we set up a public API

Mongoid.load!("../test/mongoid.yaml", :development)
class ASTNodes; include Mongoid::Document; end
class ASTStats; include Mongoid::Document; end

codex = Codex.new(ASTNodes, ASTStats)

files = Dir["#{ARGV[0]}/**/*.rb"]
unlikely_count = 0
line_count = 0

files.each_with_index do |target, i|
  src = IO.read(target)
  ast = Parser::CurrentRuby.parse(src) rescue nil
  next if ast.nil?
  line_count += src.split("\n").count
  messages = Set.new
  codex.tree_walk(ast) do |node|
    q = codex.is_unlikely(node)
    #if q.size > 0
      q.each{|x| messages << x[:message]}
      #print "#{node.loc.line.to_s}:" rescue "ERR:"
      #puts q.map { |x| x[:message] }.uniq.join("\n")
    #end
  end
  puts messages.to_a.join("\n")
  unlikely_count += messages.size
  puts "File #{i}: #{messages.size} / #{src.split("\n").count}"
  puts "Current % recommended: #{(unlikely_count.to_f/line_count).round(4)}" if i%8 == 0
end

puts "# of files:", files.size
puts "# of lines:", line_count
puts "# of unlikely lines:", unlikely_count
puts "% recommended:", unlikely_count.to_f/line_count

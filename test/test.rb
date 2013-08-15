require 'mongoid'

require 'ruby_codex'

Mongoid.load!("mongoid.yaml", :development)

class ASTNodes; include Mongoid::Document; end
class ASTStats; include Mongoid::Document; end

class String
  def to_ast
    Parser::CurrentRuby.parse(self)
  end
end

$codex = Codex.new(ASTNodes, ASTStats)

map = "function(){ emit(
          {func:this.func}},
          {amount: this.#{sum_field.to_s}}
        );
      };"
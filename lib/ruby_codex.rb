load 'data_node.rb'
require 'pp'

class Codex
  
  attr_reader :nodes
    
  def initialize(db,agg_db)
    @nodes = {}
    # helper procs
    info = Proc.new do |node|
      normal_node(node) do |n, norm|
        norm.pretty_complexity.map { |k,v| v }.reduce(:+)
      end
    end
    func_info = Proc.new do |node|
      normal_node(node) do |n, norm|
        norm.pretty_complexity[:send] || 0
      end
    end
    type = Proc.new { |node| node.is_a?(AST::Node) ? node.type.to_s : node.class.to_s }
    func_name = Proc.new do |node|
      if type.call(node.children.first) == "const" 
        node.children.first.children[1].to_s + "." + node.children[1].to_s
      else
        node.children[1].to_s
      end
    end

    key = {
      :type => type,
    }

    data_core = {
      :file => Proc.new { |node, f, p| f },
      :project => Proc.new { |node, f, p| p },
      :line => Proc.new { |node, f, p| node.loc ? node.loc.line : nil },
      :orig_code => Proc.new { |node, f, p| Unparser.unparse(node) rescue nil },
      #:norm_code => Proc.new { |node, f, p| normal_node(node){|x,y| x} },
      :terms => Proc.new { |node, f, p| Ripper.lex(Unparser.unparse(normal_node(node){|x,y| x})).select{|x|
        [:on_kw, :on_const, :on_ident].include?(x[1]) }.map{ |x| x[2] } rescue nil },
    }

    combine = {
      :files => Proc.new { |v| v.map { |x| x[:file] }.uniq },
      :file_count => Proc.new { |v| v.map { |x| x[:file] }.uniq.count },
      :projects => Proc.new { |v| v.map { |x| x[:project] }.uniq },
      :project_count => Proc.new { |v| v.map { |x| x[:project] }.uniq.count },
      :orig_code => Proc.new { |v| v.sample(10).map do |x| 
          {:code => x[:orig_code], :file => x[:file], :line => x[:line]} 
        end.uniq },
      :count => Proc.new { |v| v.map { |x| x[:orig_code] }.count },
      :raw_tf => Proc.new { |v, global|  v.first[:terms].map{|term| 1.0/Math.log(global[:raw_tcount][term])}.reduce(:+) || 0 },
      :raw_tf_density => Proc.new { |v, global|
        size = v.first[:terms].size
        if size == 0
          0
        else
          raw_tf = v.first[:terms].map{|term| 1.0/Math.log(global[:raw_tcount][term])}.reduce(:+) / size
        end  },
    }

    global = {
      :raw_tcount => Proc.new { |node, data_core, old|
        old = Hash.new(1) unless old
        data_core[:terms].each{ |term|
          old[term] += 1 }
        old
      },
    #  :file_tf => Proc.new { |node, data_core, old| },
    #  :proj_tf => Proc.new { |node, data_core, old| },
    }

    @nodes[:block] = DataNode.new(
      db, agg_db,
      Proc.new { |x| x.type == :block}, 
      key.merge({ 
        :func => Proc.new { |x| func_name.call(x.children.first) },
        :body => Proc.new { |x| normalize_nodes(x.children.last) },
        :arg_size => Proc.new { |x| x.children[1].children.size },
        :info => Proc.new { |x| info.call(block_without_caller(x)) },
        :func_info => Proc.new { |x| func_info.call(block_without_caller(x)) },
        :ret_val => Proc.new do |x| 
            body = x.children.last
            ret = type.call(body) == "begin" ? body.children.last : body
            typ = type.call(ret)
            typ == "send" ? func_name.call(ret) : typ
          end,
        :norm_code => Proc.new do |x| 
          normal_node(x) { |x| Unparser.unparse(block_without_caller(x)) rescue nil } 
        end
      }),
      data_core.merge({
        :args => Proc.new { |x| x.children[1].children.map{ |y| y.children[0].to_s }} 
      }),
      combine.merge({
        :args_list => Proc.new { |v| v.map { |x| x[:args] } }
      }),
      global,
      Proc.new { |db,keys,vals|
        query = db.where(:type => keys[:type], :func => keys[:func], :ret_val => keys[:ret_val]).first
        query_count = query.nil? ? 0 : query.count
        blocks = db.where(:type => keys[:type], :func => keys[:func]).sum(:count)
        rets = db.where(:type => keys[:type], :ret_val => keys[:ret_val]).sum(:count)
        { :keys => keys,
          :message => 
            "We've seen #{keys[:func]} blocks returning the #{keys[:ret_val]} type #{query_count.to_s} " +
            "times, and we've seen #{keys[:func]} blocks #{blocks.to_s} times and #{keys[:ret_val]} " +
            "returned #{rets.to_s} times.",
          :unlikely => Proc.new { |gt=1,bt=5,rt=5| query_count < gt && blocks > bt && rets > rt}
        }
      }
    )

    @nodes[:func] = DataNode.new(
      db, agg_db,
      Proc.new { |x| x.type == :send}, 
      key.merge({ 
        :func => Proc.new { |x| func_name.call(x) },
        :sig => Proc.new { |x| x.children.drop(2).map { |y| type.call(y) } },
        :norm_code => Proc.new do |x| 
          name = func_name.call(x)
          sig = x.children.drop(2).map { |y| type.call(y) }.join(",")
          "#{name}(#{sig})"
        end
      }),
      data_core.merge({
        :info => Proc.new { |x| info.call(without_caller(x)) },
        :func_info => Proc.new { |x| func_info.call(without_caller(x)) }
      }),
      combine,
      global,
      Proc.new do |db,keys,values| 
        primatives = ["str","int","float","array","hash"]
        all_prim = keys[:sig].all? { |x| primatives.include?(x) }
        query = db.where( :type => keys[:type], :func => keys[:func], :sig => keys[:sig]).first
        query_count = query.nil? ? 0 : query.count
        func = db.where(:type => keys[:type], :func => keys[:func], :sig => {:$ne => keys[:sig]}).sort(:count => -1).limit(1).first
        alt_text = 
          if func
            alt_count = func.count 
            "and the most common alternative #{func.func}:#{func.sig.join(",")} has appeared #{alt_count.to_s} times."
          else
            alt_count = 0
            "and we've seen no known alternative."
          end
        { :keys => keys,
          :message =>
            "Function call #{keys[:func]}:#{keys[:sig].join(",")} has appeared #{query_count.to_s} times, " +
            alt_text,
          :unlikely => Proc.new do |ac=5,t=1024| 
            all_prim && query_count == 0 && alt_count >= ac || alt_count >= t * (query_count + 1)
          end
        }
      end
    )

    @nodes[:func_chain] = DataNode.new(
      db, agg_db,
      Proc.new { |x| x.type == :send && type.call(x.children.first) == "send" }, 
      key.merge({ 
        :type => Proc.new { "func_chain" },
        :f1 => Proc.new { |x| func_name.call(x) },
        :f2 => Proc.new { |x| func_name.call(x.children.first) },
        :norm_code => Proc.new do |x|
          f1 = func_name.call(x)
          f2 = func_name.call(x.children.first)
          "#{f1}.#{f2}"
        end
      }),
      data_core,
      combine,
      global,
      Proc.new do |db,keys,data|
        query = db.where(keys).first
        query_count = query.nil? ? 0 : query.count
        fs = [:f1,:f2].map { |f| db.where(:type => "send", :func => keys[f]).sum(:count) }
        { :keys => keys, 
          :message => 
            "Function #{keys[:f1]} has appeared #{fs[0].to_s} times " +
            "and #{keys[:f2]} has appeared #{fs[1].to_s} times, and " +
            "they've appeared #{query_count} times together.",
          :unlikely => Proc.new { |gt=1, t=10| query_count < gt && fs[0] > t && fs[1] > t }
        }
      end
    )

    @nodes[:cond] = DataNode.new(
      db, agg_db,
      Proc.new { |x| x.type == :if },
      key.merge({
        :norm_code => Proc.new { |x| normalize_nodes(x) },
        :cond => Proc.new { |x| normal_node(x) { |n| Unparser.unparse(n.children.first) }},
        :iftrue => Proc.new { |x| normal_node(x) { |n| Unparser.unparse(n.children[1]) }},
        :iffalse => Proc.new { |x| normal_node(x) { |n| Unparser.unparse(n.children[2]) }},
        :info => info,
        :func_info => func_info
      }),
      data_core,
      combine,
      global
    )

    @nodes[:ident] = DataNode.new(
      db, agg_db,
      Proc.new { |x| [:lvasgn, :ivasgn, :cvasgn, :gvasgn].include?(x.type) },
      key.merge({
        :type => Proc.new { "ident" },
        :ident => Proc.new { |x| x.children.first.to_s },
        :norm_code => Proc.new { |x| x.children.first.to_s + " ="}
      }),
      data_core.merge({
        :ident_type => Proc.new { |x| type.call(x.children[1]) rescue nil }
      }),
      combine.merge({
        :ident_types => Proc.new { |v| v.group_by { |y| y[:ident_type] }.map_hash { |x| x.size } }
      }),
      global,
      Proc.new { |db, keys, data|
        #pp keys
        primatives = ["str","int","float","array","hash"]
        query = db.where(keys).first
        if query && primatives.include?(data[:ident_type])
          types = query.ident_types.select { |k,v| primatives.include? k }
          types.default = 0
          best = types.select { |k,v| k != data[:ident_type] }.sort_by{ |k,v| v*-1 }.first
          best_str = best ? "#{best[1].to_s} times as #{best[0].to_s}" : "never as anything else."
          { :keys => keys,
            :message => 
              "The identifier #{keys[:ident]} has appeared #{types[data[:ident_type]].to_s} " +
              "times as #{data[:ident_type].to_s} and #{best_str}", 
              :unlikely => Proc.new do |ac=5,t=8| 
                if best
                  (types[keys[:ident_type]] == 0 && best[1] >= ac) || (best[1] >= t * (types[keys[:ident_type]] + 1))
                else
                  false
                end
              end
          }
        else
          { :message => "Never Seen", :unlikely => Proc.new { false } }
        end
      }
    )
  end
  
  def add_ast(ast, file, project, &block)
    @nodes.each do |k,v|
      v.add_ast(ast, file, project, &block) 
    end
  end
  
  def save_all!
    @nodes.each do |k,v|
      v.save!
    end
  end
  
  def query(ast)
    @nodes.each do |k,v|
      yield k, v.query(ast)
    end
  end
  
  def is_unlikely(ast, options = Hash.new([]))
    unlikely = []
    query(ast) do |k, message|
      if message && message[:unlikely].call(*options[k])
        unlikely.push(message)
      end
    end
    unlikely
  end   
  
  def tree_walk(ast, &block)
    if ast.is_a?(AST::Node)
      yield ast if block
      ast.children.each { |node| tree_walk(node, &block) }
    end
  end
  
  def without_caller(node) 
    node.updated(nil, node.children.map.with_index do |x,i|
      i == 0 ? nil : x
    end)
  end
  
  def block_without_caller(node)
    node.updated(nil, node.children.map.with_index do |y,i| 
      i == 0 ? without_caller(y) : y
    end)
  end

  def normal_node(node)
    norm = ASTNormalizer.new
    yield norm.rewrite_ast(node), norm
  end

  def normalize_nodes(nodes)
    normal_node(nodes) do |n|
      Unparser.unparse(n) rescue nil
    end
  end
  
end

class Hash
  def map_hash
    result = {}
    self.each do |key, val|
      result[key] = yield val
    end
    result
  end
end

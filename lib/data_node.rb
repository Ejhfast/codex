require 'parser/current'
require 'unparser'
require 'ast'
require 'mongoid'
load 'normalize_ast.rb'

class DataNode
    
  def initialize(db, agg_db, type, key_procs = {}, data_procs = {}, combine = {}, global_procs = {}, query = nil)
    @type = type
    @data = Hash.new { |h,k| h[k] = [] }
    @combine = combine
    @processed = {}
    @key_procs = key_procs
    @data_procs = data_procs
    @db, @agg_db = db, agg_db
    @query = query
    @global_procs = global_procs
    @globals = {}
  end
  
  def process_node(ast, file, project, &block)
    if @type.call(ast)
      keys = {}
      data_point = {}
      @key_procs.each do |name, proc|
        keys[name] = proc.call(ast, file, project)
      end
      @data_procs.each do |name, proc|
        data_point[name] = proc.call(ast, file, project)
      end
      yield keys, data_point if block
    end
  end
        
  def add_ast(ast, file, project, &block)   
    process_node(ast, file, project) do |keys, data_point|
      #join_keys = keys.map { |k,v| v }.join("-")
      @data[keys].push(data_point)
      @global_procs.each do |name, proc|
        @globals[name] = proc.call(keys,data_point,@globals[name])
      end
      yield keys, @data[keys] if block
    end
    @data
  end
  
  def process_all_ast
    @processed = {}
    @data.each do |k,v|
      @processed[k] = collapse_data(v).merge(k)
    end
    @processed
  end
  
  def query(ast, file = "N/A", project = "N/A")
    if @query
      process_node(ast, file, project) do |keys, data|
        unlikely = @query.call(@agg_db, keys, data)
        unlikely ? unlikely : nil 
      end
    end
  end
  
  def save!
    process_all_ast
    #@db.delete_all
    #@agg_db.delete_all
    count = 0
    if !@key_procs.empty?
      @processed.each do |k,v| 
        @agg_db.new(v).save
        count += 1
        puts count
      end
    end
    # @data.each do |k,v| 
    #   v.each do |v_a|
    #     @db.new(v_a.merge(k)).save
    #     count += 1
    #     puts count
    #   end
    # end
    true
  end
    
  def collapse_data(data)
    combined = {}
    @combine.each do |k,proc|
      combined[k] = proc.call(data,@globals)
    end
    combined
  end
  
end
    

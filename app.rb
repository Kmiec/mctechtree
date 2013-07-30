require 'i18n'
require 'sinatra'
require 'rack/cache'
require 'json'

I18n.load_path += Dir[File.join(File.dirname(__FILE__), 'locale', '*.yml')]

class TechTreeApp < Sinatra::Base
  
  register Sinatra::Twitter::Bootstrap::Assets
  use Rack::CommonLogger
  use Rack::Cache

  def self.db= value
    @@db = value
  end

  def cluster_name group
    I18n.t("clusters.#{group}")
  end

  helpers do
    def count_all_recipes
      recipe_counters.map do |grp, count, subcount|
        count + subcount
      end.inject(0) { |a, b| a + b }
    end

    def recipe_counters
      rc = Hash[@@db.crafted.group_by(&:group).map {|key, g| [key, g.size]}]
      @@db.root_groups.map do |group|
        subcount = @@db.submods(group).map { |sg| rc[sg] }.inject(0) { |a, b| a+b }
        [group, rc[group], subcount]
      end
    end

    def advanced_item_groups
      @@db.crafted.group_by(&:groups).map { |key, g| [key, g.map(&:name)]}
    end

    def submodules group
      @@db.submods(group)
    end

    def all_machines
      @@db.machines
    end

    def multigroup_text groups
      groups.map{ |group| cluster_name(group) }.to_sentence
    end

  end

  error UncraftableItemError do
    haml :uncraftable, layout: :base
  end

  get '/' do
    last_modified File.mtime(__FILE__)
    haml :index, layout: :base
  end

  get '/ds/:group.json' do
    content_type :json
    # TODO: build static files
    @@db.crafted.select { |item| item.group == params[:group] }.map do |item| 
      { value: item.name, slug: item.name.downcase.gsub(/\W/, '-') }
    end.to_json
  end

  get '/suggestions.js' do
    content_type :js
    cache_control :public, max_age: 60
    'var suggestions = ' + @@db.crafted.map do |item|
      { value: item.name, data: {name: item.name, group: cluster_name(item.group)} }
    end.to_json
  end

  get '/ac' do
    content_type :json
    query = params[:query]
    { suggestions: @@db.like(query).map do |item|
      { value: item.name, data: {name: item.name, group: cluster_name(item.group)} }
    end}.to_json
  end

  post '/solve.?:format?' do
    items = params[:items].split(',').map(&:strip).select do |name| 
      @@db.find(name.gsub(/\*\d+$/, '')) # reject invalid names TODO: throw error
    end
    puts "*********** #{items.inspect}"
    solveopts = {}
    if (tier = params[:tier])
      tier = tier.to_i
      max_items_tier = items.map { |name| @@db.find(name).tier }.max
      tier = [max_items_tier - 1, tier].min
      solveopts[:min_tier] = tier
    end
    if (fm = params[:forbid_machine])
      solveopts[:forbid_machine] = fm
    end
    if (xmod = params[:exclude_cluster])
      solveopts[:exclude_cluster] = xmod
    end
    item_resolver = make_item_resolver(solveopts)
    solutions = items.map do |name|
      name = name.gsub(/\*(\d+)/, '')
      count = $1.to_i || 1
      item_resolver.new(@@db.find(name), count).resolve
    end
    solver = Solver.new(solutions, solveopts).solve

    if params[:format] == 'lua'
      mime_type 'application/lua'
      "result=#{format_lua raw: solver.raw_resources, crafts: solver.craft_sequence}"
    else
      haml :solution, layout: :base, locals: {
        raw: solver.raw_resources,
        crafts: solver.craft_sequence, 
        targets: items, 
        tier: tier,
        forbidden_machines: fm,
        excluded_mods: xmod
      }
    end
  end
end

def format_lua object
  case object
    when Numeric, true, false
      object.to_s
    when String, Symbol
      object.to_s.dump
    when nil
      "null"
    when OpenStruct
      format_lua object.marshal_dump
    when Item #specialcase
      format_lua object.name
    when Array
      format_lua Hash[(1..object.size).zip(object)]
    when Hash
      ['{',
        object.map do |key, value|
          "[#{format_lua key}]=#{format_lua value}"
        end.join(",\n"),
       '}'].join('')
    else
      format_lua object.to_serializable_hash
  end
end

def make_item_resolver options
  item_resolver_options = options.select { |key, val| Addons.item_resolver_modules.include? key.to_s }
  craft_resolver_options = options.select { |key, val| Addons.craft_resolver_modules.include? key.to_s }
  # analogicznie: wykluczanie clusterów - podmieniamy itemresolver na taki
  # który nie znajdzie itemków z zakazanego clustera

  mir, mcr = nil
  mir = Class.new(ItemResolver) do
    @@craft_constructor = Proc.new { |*args| mcr.new(*args) }
  end
  while item_resolver_options.size > 0
    mir = Addons.build_resolver :item_resolver, mir, item_resolver_options
  end

  mcr = Class.new(CraftResolver) do
    @@item_constructor = Proc.new { |*args| mir.new(*args) }
  end
  while craft_resolver_options.size > 0
    mcr = Addons.build_resolver :craft_resolver, mcr, craft_resolver_options
  end

  mir
end
